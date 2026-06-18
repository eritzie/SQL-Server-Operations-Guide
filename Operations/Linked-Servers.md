# Linked Servers — Operations Guide

## Purpose

Operational reference for creating, configuring, and troubleshooting linked servers. For naming conventions, authentication mode decisions, security settings, and audit queries, see [[../Standards/Linked-Servers|Linked Server Standards]]. This guide covers provider selection, full creation syntax, login mapping, distributed query behavior, Kerberos delegation, MSDTC, and troubleshooting.

---

## Provider Selection

The OLE DB provider determines how SQL Server communicates with the remote server. Use the most current supported provider for the remote system type.

| Remote System | Recommended Provider | Notes |
|---|---|---|
| SQL Server (any version) | `MSOLEDBSQL` | Current Microsoft OLE DB Driver — download separately from the SQL Server installer |
| SQL Server (legacy, no MSOLEDBSQL) | `SQLNCLI11` | SQL Server Native Client 11 — deprecated, no longer receiving updates |
| Oracle | `OraOLEDB.Oracle` | Oracle OLE DB driver — must be installed on the SQL Server host |
| Excel / flat file (one-off) | `Microsoft.ACE.OLEDB.12.0` | Avoid for anything recurring — fragile and 32/64-bit sensitive |

**SQLNCLI and SQLNCLI11 are deprecated.** New linked servers should use `MSOLEDBSQL`. Existing linked servers using deprecated providers will continue to function but should be migrated during the next maintenance window.

Download: [Microsoft OLE DB Driver for SQL Server](https://learn.microsoft.com/en-us/sql/connect/oledb/download-oledb-driver-for-sql-server)

---

## Creation

### T-SQL

```sql
SET NOCOUNT ON;

-- Step 1: Create the linked server definition
EXEC [sys].[sp_addlinkedserver]
    @server     = N'SOURCE-SQL_INST',          -- linked server name (see naming standard)
    @srvproduct = N'SQL Server',               -- use 'SQL Server' for SQL targets
    @provider   = N'MSOLEDBSQL',
    @datasrc    = N'SOURCE-SQL\INST';          -- actual host\instance

-- Step 2: Configure login mapping
-- Option A: Pass through current Windows identity (preferred — requires Kerberos, see below)
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'True',
    @locallogin     = NULL,
    @rmtuser        = NULL,
    @rmtpassword    = NULL;

-- Option B: Map a specific local login to a specific remote login
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'False',
    @locallogin     = N'CORP\svc-app01',
    @rmtuser        = N'CORP\svc-remote-ro',
    @rmtpassword    = NULL;                    -- NULL for Windows auth

-- Step 3: Block unmapped logins (verify the default is set correctly)
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'False',
    @locallogin     = NULL,                    -- NULL = applies to all other logins
    @rmtuser        = NULL,
    @rmtpassword    = NULL;                    -- NULL + useself=False = not allowed

-- Step 4: Apply security settings per standard
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'rpc',     @optvalue = N'false';
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'rpc out', @optvalue = N'false';
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'data access', @optvalue = N'true';
```

### dbatools

```powershell
$splatLs = @{
    SqlInstance     = $instance
    LinkedServer    = 'SOURCE-SQL_INST'
    ServerProduct   = 'SQL Server'
    Provider        = 'MSOLEDBSQL'
    DataSource      = 'SOURCE-SQL\INST'
    EnableException = $true
}
New-DbaLinkedServer @splatLs

# Add self-credential login mapping
$splatLogin = @{
    SqlInstance     = $instance
    LinkedServer    = 'SOURCE-SQL_INST'
    Useself         = $true
    EnableException = $true
}
New-DbaLinkedServerLogin @splatLogin
```

---

## Login Mapping Detail

| Mode | Description | Use When |
|---|---|---|
| Self-credential | Caller's Windows identity forwarded via Kerberos | Same domain, SPNs configured — preferred |
| Explicit Windows mapping | Local login mapped to a specific remote Windows identity | Cross-domain or need specific service account on remote |
| Explicit SQL login | Local login mapped to a remote SQL login with stored password | Remote server does not support Windows auth — minimize use |
| Not allowed (default for unmapped) | Blocks logins not explicitly mapped | Correct default — leave in place |

**Stored SQL credentials are the highest-risk configuration.** The password is stored in `sys.syslnklgns` and is recoverable by a sysadmin. If required, use a dedicated low-privilege SQL login on the remote server — never SA or any admin account.

---

## Querying Through a Linked Server

Two syntaxes exist. They have meaningfully different performance characteristics.

### Four-Part Names

```sql
SELECT
    [o].[OrderID],
    [o].[CustomerID],
    [o].[OrderDate]
FROM [SOURCE-SQL_INST].[OrderManagement].[dbo].[Order] AS o
WHERE [o].[OrderDate] >= '2025-01-01';
```

SQL Server may pull the entire table and apply the WHERE clause locally, depending on query complexity and provider capabilities. Check the execution plan — a `Remote Query` operator with a predicate means the filter is pushed to the remote server. A `Remote Scan` means the full table is transferred and filtered locally.

### OPENQUERY

```sql
-- Passes the entire query to the remote server — more predictable for performance
SELECT
    [o].[OrderID],
    [o].[CustomerID],
    [o].[OrderDate]
FROM OPENQUERY(
    [SOURCE-SQL_INST],
    'SELECT OrderID, CustomerID, OrderDate
     FROM OrderManagement.dbo.[Order]
     WHERE OrderDate >= ''2025-01-01'''
) AS o;
```

Use OPENQUERY when the four-part name plan shows a `Remote Scan` instead of a `Remote Query`, or when the remote table is large enough that transferring it locally would be prohibitive.

OPENQUERY takes a literal string — parameters cannot be passed directly. Use `sp_executesql` when parameterization is required:

```sql
SET NOCOUNT ON;

DECLARE @sql        nvarchar(1000);
DECLARE @orderDate  date = '2025-01-01';

SET @sql = N'SELECT OrderID, CustomerID, OrderDate
             FROM OrderManagement.dbo.[Order]
             WHERE OrderDate >= ''' + CONVERT(nvarchar(10), @orderDate, 120) + '''';

EXEC [sys].[sp_executesql]
    N'SELECT [o].[OrderID], [o].[CustomerID], [o].[OrderDate]
      FROM OPENQUERY([SOURCE-SQL_INST], @q) AS o',
    N'@q nvarchar(1000)',
    @q = @sql;
```

---

## Kerberos and Delegation

Self-credential login mapping requires Kerberos. NTLM cannot perform delegation across a double-hop — the identity stops at the first server.

**Requirements:**

1. SPNs registered on the remote SQL Server's service account:

```powershell
# Verify SPNs for the remote instance (run with domain admin rights)
setspn -L CORP\svc-sql-source
# Expected output includes:
# MSSQLSvc/SOURCE-SQL.corp.example.com:1433
# MSSQLSvc/SOURCE-SQL:1433
```

2. Constrained delegation configured on the local SQL Server's service account — in Active Directory, on the service account properties, Delegation tab → Trust this account for delegation to specified services only → add the remote SQL Server's `MSSQLSvc` SPN.

If Kerberos delegation is not feasible (cross-domain, complex AD), use explicit Windows login mapping with a shared domain service account that has appropriate access on both servers.

---

## Distributed Transactions (MSDTC)

Linked server queries that write data (INSERT, UPDATE, DELETE, MERGE) automatically enlist in a distributed transaction coordinated by MSDTC. The [[../Standards/Linked-Servers|Linked Server Standards]] recommend disabling distributed transaction promotion for linked servers that do not require it.

If write operations through a linked server are required:

```powershell
# Check MSDTC service status
$splatSvc = @{
    ComputerName = 'SqlServer01', 'SOURCE-SQL'
    Type         = 'MSDTC'
}
Get-DbaService @splatSvc | Select-Object ComputerName, ServiceName, State, StartMode

# Test DTC connectivity between two servers
Test-DtcNetworkSetting -ComputerName 'SqlServer01' -RemoteComputerName 'SOURCE-SQL'
```

Common MSDTC failure symptoms: "The partner transaction manager has disabled its support for remote/network transactions." Root causes: MSDTC network access disabled in Component Services, Windows Firewall blocking RPC (port 135) between servers, or mismatched MSDTC authentication settings.

---

## Testing and Verification

```sql
SET NOCOUNT ON;

-- Test basic connectivity
EXEC [sys].[sp_testlinkedserver] N'SOURCE-SQL_INST';

-- Verify data access returns results
SELECT TOP 1
    [name]
FROM [SOURCE-SQL_INST].[master].[sys].[databases];
```

```powershell
$splatTest = @{
    SqlInstance     = $instance
    EnableException = $true
}
Test-DbaLinkedServerConnection @splatTest |
    Select-Object SqlInstance, LinkedServer, Status, IsConnected
```

---

## Troubleshooting

| Error | Likely Cause | Resolution |
|---|---|---|
| Login failed for user 'NT AUTHORITY\ANONYMOUS LOGON' | Kerberos not working — falling back to anonymous | Register SPNs; configure constrained delegation; or switch to explicit login mapping |
| Cannot obtain the required interface ("IID_IDBCreateCommand") | Provider not installed or wrong bitness | Install `MSOLEDBSQL`; verify 64-bit provider is in use |
| Linked server is not configured for data access | `data access` option is off | `EXEC sp_serveroption @server=N'...', @optname=N'data access', @optvalue=N'true'` |
| Login timeout expired | Network connectivity or firewall | Verify TCP 1433 is open; check SQL Browser for named instances |
| Unable to begin a distributed transaction | MSDTC not configured or blocked | Configure MSDTC network access; open port 135 between servers |
| Access is denied | Login mapping blocks the calling login | Add an explicit login mapping for that login |

---

## Related Documents

- [[../Standards/Linked-Servers|Linked Server Standards]] — naming, authentication options, security settings, audit queries
- [[../Security/Security-Practices|Security Practices]] — Kerberos and service account guidance
- [[Replication|Transactional Replication]] — preferred approach for ongoing cross-instance data distribution
- [[Operations|Back to Operations]]
