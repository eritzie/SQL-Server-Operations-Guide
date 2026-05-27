# Linked Server Configuration and Security

## Purpose

Define standards for creating, securing, and auditing linked servers. Linked servers introduce cross-instance trust and are a common compliance finding when configured with stored SQL credentials or overly permissive security settings. Every linked server is an attack surface — configure only what is required.

---

## Naming

Format: `{HOST}_{INSTANCE}` — mirrors the instance slug convention (backslash replaced with underscore).

| Linked Server Name | Points To |
|---|---|
| `SOURCE-SQL_INST` | `SOURCE-SQL\INST` (named instance) |
| `SOURCE-SQL` | `SOURCE-SQL` (default instance) |

Use the physical host and instance name. Never use a friendly alias — the physical target must be immediately identifiable during an incident.

---

## Authentication Options

SQL Server offers four authentication modes for linked server connections. Use the highest option the target supports.

| Mode | How It Works | Use When |
|---|---|---|
| **Windows auth via caller's context** (`Be made using the login's current security context`) | Delegates the connecting login's Windows identity to the remote server via Kerberos | Both servers are in the same domain and SPNs are configured — this is the preferred option |
| **Windows auth via mapped credential** | Maps a specific local login to a specific remote Windows login | Cross-domain or when specific service account control is needed |
| **SQL login — mapped credential** | Stores a remote SQL login and password in the linked server definition | Only when the remote server does not support Windows auth — minimize use |
| **Not allowed** (`Connections will not be made`) | Blocks any login that is not explicitly mapped | Default for unmapped logins — leave this as the default for logins that should not traverse the linked server |

**Stored SQL credentials (option 3) are the highest-risk configuration.** The password is stored in `sys.syslnklgns` and is recoverable by a sysadmin. If this mode is required, use a dedicated low-privilege SQL login on the remote server, not SA or any admin account.

---

## Required Security Settings

Apply these settings to every linked server at creation time:

| Setting | Required Value | Reason |
|---|---|---|
| `RPC` | `False` | Disables remote stored procedure calls from the remote server to this one |
| `RPC Out` | `False` unless required | Limits this server initiating remote procedure calls on the target — enable only if the specific use case requires it |
| `Enable Promotion of Distributed Transactions` | `False` | Prevents MSDTC-coordinated distributed transactions, which are a common source of escalation failures and security events |
| `Collation Compatible` | Match actual collation | Set `True` only if target collation matches — incorrect setting causes silent data errors on string comparisons |

```sql
-- Set security options after creation
EXEC [sys].[sp_serveroption]
    @server     = N'<linked-server-name>',
    @optname    = N'rpc out',
    @optvalue   = N'false';

EXEC [sys].[sp_serveroption]
    @server     = N'<linked-server-name>',
    @optname    = N'rpc',
    @optvalue   = N'false';
```

---

## Creation

Use dbatools where possible. Manual T-SQL creation is acceptable for one-off setups.

```powershell
# Create a linked server using Windows auth (caller's context)
$splatLs = @{
    SqlInstance         = $instance
    LinkedServer        = '<linked-server-name>'
    ServerProduct       = 'SQL Server'
    Provider            = 'SQLNCLI'
    DataSource          = '<target-host>\<target-instance>'
    EnableException     = $true
}
New-DbaLinkedServer @splatLs
```

For Windows auth via caller's context, no login mapping is required — leave the security mapping at the default "Not be made" for unmapped logins and configure the `Be made using the login's current security context` option for the appropriate logins.

---

## Audit Queries

### All linked servers and their authentication mode

```sql
SET NOCOUNT ON;

SELECT
    s.[name]                        AS LinkedServer,
    s.[data_source]                 AS DataSource,
    s.[provider],
    s.[is_rpc_out_enabled]          AS rpc_out,
    s.[is_remote_login_enabled]     AS rpc_in,
    l.[local_principal_id],
    l.[uses_self_credential]        AS uses_caller_context,
    p.[name]                        AS local_login,
    r.[remote_name]                 AS remote_login
FROM [sys].[servers]                AS s
LEFT JOIN [sys].[linked_logins]     AS l
    ON s.[server_id]        = l.[server_id]
LEFT JOIN [sys].[server_principals] AS p
    ON l.[local_principal_id] = p.[principal_id]
LEFT JOIN [sys].[linked_logins]     AS r
    ON s.[server_id]        = r.[server_id]
WHERE s.[is_linked] = 1
ORDER BY s.[name];
```

### Linked servers using stored SQL credentials — compliance finding

```sql
SET NOCOUNT ON;

-- Any row returned here is a finding: stored password on a linked server
SELECT
    s.[name]            AS LinkedServer,
    s.[data_source]     AS DataSource,
    l.[remote_name]     AS RemoteLogin
FROM [sys].[servers]            AS s
JOIN [sys].[linked_logins]      AS l
    ON s.[server_id] = l.[server_id]
WHERE s.[is_linked]             = 1
  AND l.[uses_self_credential]  = 0
  AND l.[local_principal_id]    = 0   -- mapped for all logins
  AND l.[remote_name]           IS NOT NULL
ORDER BY s.[name];
```

```powershell
# dbatools — list all linked servers across instances
$splatLs = @{
    SqlInstance     = $instances
    EnableException = $true
}
Get-DbaLinkedServer @splatLs |
    Select-Object SqlInstance, Name, DataSource, IsLinked, Rpc, RpcOut
```

---

## When to Use a Linked Server

Linked servers are appropriate for:

- Cross-instance reporting queries that cannot be served by replication or ETL
- One-way data pulls where the consumer instance queries the producer (not bidirectional writes)
- Controlled migration periods where two instances need to share data temporarily

Avoid linked servers for:

- Application data access — applications should connect directly to their target instance
- Replacing replication or log shipping — linked server queries run synchronously and block the caller
- Any scenario where the query volume is high enough to cause contention on either end

---

## Related Documents

- [Security](../Security/Security.md) — general authentication and access control standards
- [Transactional Replication](../Operations/Replication.md) — preferred approach for ongoing cross-instance data distribution
