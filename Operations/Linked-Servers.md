# Linked Servers — Operations Guide

## Purpose

Operational reference for creating, configuring, and troubleshooting linked servers. For naming conventions, authentication mode decisions, and security settings, see [Linked Server Standards](../Standards/Linked-Servers.md). This guide covers provider selection, full creation syntax, login mapping, distributed query behavior, Kerberos delegation, MSDTC, and troubleshooting.

---

## Provider Selection

The OLE DB provider determines how SQL Server communicates with the remote server. Use the most current supported provider for the remote system type.

| Remote System | Recommended Provider | Notes |
|---|---|---|
| SQL Server (any version) | `MSOLEDBSQL` | Current Microsoft OLE DB Driver — download separately from the SQL Server installer |
| SQL Server (legacy, no MSOLEDBSQL) | `SQLNCLI11` | SQL Server Native Client 11 — deprecated, no longer receiving updates |
| Oracle | `OraOLEDB.Oracle` | Oracle OLE DB driver — must be installed on the SQL Server host |
| Excel / flat file (one-off) | `Microsoft.ACE.OLEDB.12.0` | Avoid for anything recurring — fragile and 32/64-bit sensitive |

**SQLNCLI and SQLNCLI11 are deprecated.** New linked servers should use `MSOLEDBSQL`. Existing linked servers using deprecated providers will continue to function but should be migrated during the next maintenance window — Microsoft has signaled end-of-support for the native client.

`MSOLEDBSQL` must be downloaded and installed separately: [Microsoft OLE DB Driver for SQL Server](https://learn.microsoft.com/en-us/sql/connect/oledb/download-oledb-driver-for-sql-server).

---

## Creation

### T-SQL

```sql
SET NOCOUNT ON;

-- Step 1: Create the linked server definition
EXEC [sys].[sp_addlinkedserver]
    @server     = N'SOURCE-SQL_INST',          -- linked server name (see naming standard)
    @srvproduct = N'SQL Server',               -- product name — use 'SQL Server' for SQL targets
    @provider   = N'MSOLEDBSQL',              -- OLE DB provider
    @datasrc    = N'SOURCE-SQL\INST';          -- actual host\instance

-- Step 2: Configure login mapping
-- Option A: Use the caller's Windows identity (preferred — requires Kerberos, see below)
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'True',                 -- pass through current Windows identity
    @locallogin     = NULL,                    -- NULL applies to all local logins
    @rmtuser        = NULL,
    @rmtpassword    = NULL;

-- Option B: Map a specific local login to a specific remote login (cross-domain or service account scenarios)
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'False',
    @locallogin     = N'CORP\svc-app01',       -- local login being mapped
    @rmtuser        = N'CORP\svc-remote-ro',   -- remote Windows login
    @rmtpassword    = NULL;                    -- NULL for Windows auth — password not stored

-- Step 3: Block unmapped logins (default is already 'Not be made' — verify it explicitly)
EXEC [sys].[sp_addlinkedsrvlogin]
    @rmtsrvname     = N'SOURCE-SQL_INST',
    @useself        = N'False',
    @locallogin     = NULL,                    -- NULL = applies to all other logins
    @rmtuser        = NULL,
    @rmtpassword    = NULL;                    -- NULL + useself=False = connections not allowed

-- Step 4: Apply security settings per standard
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'rpc',     @optvalue = N'false';
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'rpc out', @optvalue = N'false';
EXEC [sys].[sp_serveroption] @server = N'SOURCE-SQL_INST', @optname = N'data access', @optvalue = N'true';
```

### dbatools

```powershell
# Create the linked server
$splatLs = @{
    SqlInstance     = 'SqlServer01'
    LinkedServer    = 'SOURCE-SQL_INST'
    ServerProduct   = 'SQL Server'
    Provider        = 'MSOLEDBSQL'
    DataSource      = 'SOURCE-SQL\INST'
    EnableException = $true
}
New-DbaLinkedServer @splatLs

# Add login mapping (self-credential / caller's context)
$splatLogin = @{
    SqlInstance     = 'SqlServer01'
    LinkedServer    = 'SOURCE-SQL_INST'
    Useself         = $true
    EnableException = $true
}
New-DbaLinkedServerLogin @splatLogin
```

---

## Login Mapping Detail

Login mapping determines what identity is presented to the remote server.

**Self-credential (caller's context):** The connecting login's Windows identity is forwarded to the remote server via Kerberos. No password is stored anywhere. This is the security-correct option when both servers are in the same domain and SPNs are configured. See [Kerberos and Delegation](#kerberos-and-delegation) below.

**Explicit Windows mapping:** A local login is mapped to a specific remote Windows identity. Use this when the caller's identity should not be forwarded — for example, mapping a low-privilege application login to a specific read-only service account on the remote server.

**Explicit SQL login mapping:** A local login is mapped to a remote SQL login with a stored password. The password is stored in `sys.syslnklgns` and is recoverable by a sysadmin. Use only when the remote server does not support Windows authentication. Never map to a high-privilege remote login.

**Not allowed (default for unmapped):** Any login not explicitly mapped is blocked from using the linked server. This is the correct default — connections should be allowed only for the specific logins that need them.

---

## Querying Through a Linked Server

Two syntaxes exist for querying remote objects. They have meaningfully different performance characteristics.

### Four-Part Names

```sql
-- Syntax: [LinkedServerName].[Database].[Schema].[Object]
SELECT
    [o].[OrderID],
    [o].[CustomerID],
    [o].[OrderDate]
FROM [SOURCE-SQL_INST].[OrderManagement].[dbo].[Order] AS o
WHERE [o].[OrderDate] >= '2025-01-01';
```

Four-part names are evaluated by the remote server, but SQL Server may pull the entire table and apply the WHERE clause locally, depending on the query complexity and provider capabilities. Use execution plans to verify whether predicates are being pushed to the remote server (`Remote Query` operator with a predicate) or applied locally after a full table pull (`Remote Scan`).

### OPENQUERY

```sql
-- OPENQUERY passes the entire query to the remote server for execution
-- The remote server processes the WHERE clause and returns only the matching rows
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

**OPENQUERY is more predictable for performance** — the entire query string is sent to and executed on the remote server. Use OPENQUERY when:
- The query involves large tables on the remote server
- Predicates must execute on the remote server to avoid transferring large result sets
- The four-part name plan shows a `Remote Scan` instead of a `Remote Query`

Limitation: OPENQUERY takes a literal string — parameters cannot be passed directly. Use dynamic SQL when parameterization is required:

```sql
SET NOCOUNT ON;

DECLARE @sql        nvarchar(1000);
DECLARE @orderDate  date = '2025-01-01';

SET @sql = N'SELECT OrderID, CustomerID, OrderDate
             FROM OrderManagement.dbo.[Order]
             WHERE OrderDate >= ''' + CONVERT(nvarchar(10), @orderDate, 120) + '''';

EXEC [sys].[sp_executesql]
    N'SELECT o.OrderID, o.CustomerID, o.OrderDate
      FROM OPENQUERY([SOURCE-SQL_INST], @q) AS o',
    N'@q nvarchar(1000)',
    @q = @sql;
```

---

## Kerberos and Delegation

Self-credential login mapping (passing the caller's Windows identity to the remote server) requires Kerberos. NTLM cannot perform delegation across a double-hop — the identity stops at the first server.

Requirements for Kerberos to work through a linked server:

1. **SPNs registered on the remote SQL Server** — without a correct SPN, Kerberos cannot locate the service:

```powershell
# Verify SPNs for the remote instance (run with domain admin rights)
setspn -L CORP\svc-sql-source    # service account of the remote SQL Server
# Expected output should include:
# MSSQLSvc/SOURCE-SQL.corp.example.com:1433
# MSSQLSvc/SOURCE-SQL:1433
```

2. **Constrained delegation configured on the local SQL Server's service account** — the account under which the local SQL Server runs must be trusted in AD to delegate to the remote SQL Server's SPN. Configure in Active Directory Users and Computers → service account → Delegation tab → Trust this account for delegation to specified services only → add the remote SQL Server's `MSSQLSvc` SPN.

If Kerberos delegation is not feasible (cross-domain, complex AD environment), use explicit Windows login mapping with a shared domain service account that has appropriate access on both servers.

---

## Distributed Transactions (MSDTC)

Linked server queries that modify data on the remote server (INSERT, UPDATE, DELETE, MERGE through a linked server) automatically enlist in a distributed transaction coordinated by MSDTC. The [Linked Server Standards](../Standards/Linked-Servers.md) recommend disabling distributed transaction promotion (`Enable Promotion of Distributed Transactions = False`) for linked servers that do not require it.

If a linked server use case requires write operations and MSDTC is enabled, verify MSDTC is configured correctly on both servers:

```powershell
# Check MSDTC service status on both servers
Get-DbaService -ComputerName 'SqlServer01', 'SOURCE-SQL' -Type MSDTC |
    Select-Object ComputerName, ServiceName, State, StartMode

# Test DTC connectivity between two servers
Test-DtcNetworkSetting -ComputerName 'SqlServer01' -RemoteComputerName 'SOURCE-SQL'
```

MSDTC failures are a common linked server incident. Symptoms include errors like "The partner transaction manager has disabled its support for remote/network transactions." Root causes:

- MSDTC network access disabled in Component Services
- Windows Firewall blocking RPC (port 135) between servers
- Mismatched MSDTC authentication settings (Mutual Auth Required vs. No Auth Required)

---

## Testing and Verification

```sql
SET NOCOUNT ON;

-- Test basic connectivity (returns error if the linked server cannot connect)
EXEC [sys].[sp_testlinkedserver] N'SOURCE-SQL_INST';

-- Verify the linked server is reachable and returns data
SELECT TOP 1
    [name]
FROM [SOURCE-SQL_INST].[master].[sys].[databases];

-- Test that unmapped logins are blocked (run as a non-mapped login)
-- Should return: "Login <login> does not have access to server 'SOURCE-SQL_INST'"
SELECT TOP 1 1 FROM [SOURCE-SQL_INST].[master].[sys].[databases];
```

```powershell
# Test all linked servers on an instance
$splatTest = @{
    SqlInstance     = 'SqlServer01'
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
| Linked Server is not configured for data access | `data access` option is off | `EXEC sp_serveroption @server = N'...', @optname = N'data access', @optvalue = N'true'` |
| OLE DB provider returned message: Login timeout expired | Network connectivity or firewall | Verify TCP 1433 (or custom port) is open between servers; check SQL Browser if named instance |
| The operation could not be performed because OLE DB provider ... was unable to begin a distributed transaction | MSDTC not configured or blocked | Configure MSDTC network access; open port 135 between servers |
| Access is denied | Login mapping blocks the calling login | Add an explicit login mapping for that login, or change the operation to use a mapped login |

---

## Related Documents

- [Linked Server Standards](../Standards/Linked-Servers.md) — naming conventions, authentication options, security settings, and audit queries
- [Security Practices](../Security/Security.md) — gMSA and Kerberos delegation for service accounts
- [Replication](Replication.md) — preferred approach for ongoing cross-instance data distribution
