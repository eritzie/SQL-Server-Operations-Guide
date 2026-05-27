# SQL Server Audit

## Purpose

Document the creation and management of SQL Server Audit, the native mechanism for tracking security-relevant events. SQL Server Audit is the preferred auditing approach for CIS Benchmark compliance, SOC 2, HIPAA, and PCI-DSS requirements — it is more reliable and granular than SQL Profiler traces or Extended Events for this purpose. This document covers server-level and database-level audit specifications, log management, and querying audit data.

---

## Architecture Overview

SQL Server Audit has three components that work together:

| Component | Scope | Purpose |
|---|---|---|
| **Server Audit** | Instance | Defines where events are written (file, Windows event log) |
| **Server Audit Specification** | Instance | Defines *which* server-level events to capture |
| **Database Audit Specification** | Database | Defines *which* database-level events to capture |

A single Server Audit (the destination) can receive events from both a Server Audit Specification and multiple Database Audit Specifications. You must create the Server Audit first.

---

## Step 1 — Create the Server Audit (Destination)

```sql
SET NOCOUNT ON;

USE [master];

CREATE SERVER AUDIT [DBA_SecurityAudit]
TO FILE
(
    FILEPATH               = N'C:\AuditLogs\',
    MAXSIZE                = 100 MB,
    MAX_ROLLOVER_FILES     = 10,
    RESERVE_DISK_SPACE     = OFF
)
WITH
(
    QUEUE_DELAY    = 1000,      -- milliseconds; 0 = synchronous (performance impact)
    ON_FAILURE     = CONTINUE   -- CONTINUE keeps the instance running if audit write fails
                                -- SHUTDOWN stops the instance -- use only if audit loss is unacceptable
);

ALTER SERVER AUDIT [DBA_SecurityAudit] WITH (STATE = ON);
```

`ON_FAILURE = CONTINUE` is the safe default for most environments. `SHUTDOWN` is appropriate only when regulatory requirements demand that the instance stops rather than operates without auditing.

Verify the audit is active:

```powershell
$splatAudit = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaServerAudit @splatAudit |
    Select-Object SqlInstance, Name, Enabled, FilePath, MaxFileSize
```

---

## Step 2 — Server Audit Specification

Captures instance-level security events. These are the CIS Benchmark-recommended action groups:

```sql
SET NOCOUNT ON;

USE [master];

CREATE SERVER AUDIT SPECIFICATION [DBA_ServerSpec]
FOR SERVER AUDIT [DBA_SecurityAudit]
ADD (FAILED_LOGIN_GROUP),             -- All failed login attempts
ADD (SUCCESSFUL_LOGIN_GROUP),         -- All successful logins
ADD (LOGOUT_GROUP),                   -- All logouts
ADD (SERVER_ROLE_MEMBER_CHANGE_GROUP),-- Changes to server role membership
ADD (SERVER_PRINCIPAL_CHANGE_GROUP),  -- Login creates, drops, alters
ADD (DATABASE_CHANGE_GROUP),          -- Database create, drop, alter
ADD (SCHEMA_OBJECT_CHANGE_GROUP),     -- DDL on schemas and objects
ADD (AUDIT_CHANGE_GROUP),             -- Changes to audit configuration itself
ADD (SERVER_PERMISSION_CHANGE_GROUP)  -- GRANT/DENY/REVOKE at server level
WITH (STATE = ON);
```

> **Note:** `SUCCESSFUL_LOGIN_GROUP` generates high volume on busy instances. If log storage is constrained, replace it with `FAILED_LOGIN_GROUP` only and track successful logins via a lighter mechanism (e.g., session count DMVs). CIS Level 1 requires failed logins; Level 2 requires both.

---

## Step 3 — Database Audit Specification

Captures database-level events. Create one per database that needs auditing. Replace `[TargetDatabase]` with the actual database name.

```sql
USE [TargetDatabase];

CREATE DATABASE AUDIT SPECIFICATION [DBA_DatabaseSpec]
FOR SERVER AUDIT [DBA_SecurityAudit]
ADD (DATABASE_ROLE_MEMBER_CHANGE_GROUP),  -- Changes to database role membership
ADD (DATABASE_PRINCIPAL_CHANGE_GROUP),    -- User creates, drops, alters
ADD (DATABASE_PERMISSION_CHANGE_GROUP),   -- GRANT/DENY/REVOKE at database level
ADD (SCHEMA_OBJECT_PERMISSION_CHANGE_GROUP), -- Object-level permission changes
ADD (DATABASE_OBJECT_CHANGE_GROUP)        -- DDL within the database
WITH (STATE = ON);
```

For databases subject to stricter compliance (PII, financial data), add DML auditing on specific tables. This generates significant volume — target only the tables that require it:

```sql
-- Add to the database audit specification above (or a separate specification)
ADD (SELECT ON OBJECT::[dbo].[SensitiveTable] BY [public]),
ADD (INSERT ON OBJECT::[dbo].[SensitiveTable] BY [public]),
ADD (UPDATE ON OBJECT::[dbo].[SensitiveTable] BY [public]),
ADD (DELETE ON OBJECT::[dbo].[SensitiveTable] BY [public])
```

---

## Managing Audit State

```powershell
# List all audits and their state
$splatAudit = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaServerAudit @splatAudit | Select-Object SqlInstance, Name, Enabled

# List all database audit specifications
$splatDbSpec = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbAuditSpecification @splatDbSpec |
    Select-Object SqlInstance, Database, Name, IsEnabled
```

Disable and re-enable an audit for maintenance:

```sql
ALTER SERVER AUDIT [DBA_SecurityAudit] WITH (STATE = OFF);
-- perform maintenance --
ALTER SERVER AUDIT [DBA_SecurityAudit] WITH (STATE = ON);
```

---

## Querying Audit Logs

```sql
SET NOCOUNT ON;

-- Read from the audit file target
SELECT TOP 500
    [event_time],
    [action_id],
    [server_principal_name],
    [database_name],
    [object_name],
    [statement],
    [succeeded],
    [client_ip]
FROM [sys].[fn_get_audit_file]
(
    N'C:\AuditLogs\DBA_SecurityAudit*.sqlaudit',
    DEFAULT,
    DEFAULT
)
ORDER BY [event_time] DESC;
```

```sql
SET NOCOUNT ON;

-- Filter for failed logins in the last 24 hours
SELECT
    [event_time],
    [server_principal_name],
    [client_ip],
    [additional_information]
FROM [sys].[fn_get_audit_file]
(
    N'C:\AuditLogs\DBA_SecurityAudit*.sqlaudit',
    DEFAULT,
    DEFAULT
)
WHERE [action_id] = 'LGIF'                      -- Login Failed
  AND [event_time] >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY [event_time] DESC;
```

Common `action_id` values:

| action_id | Event |
|---|---|
| `LGIS` | Login Succeeded |
| `LGIF` | Login Failed |
| `LGLO` | Logout |
| `CRL` | Create Login |
| `DRL` | Drop Login |
| `AL` | Alter Login |
| `CR` | Create object (DDL) |
| `DR` | Drop object (DDL) |
| `SL` | SELECT |
| `IN` | INSERT |
| `UP` | UPDATE |
| `DL` | DELETE |

---

## Log File Management

The audit files accumulate over time. The `MAX_ROLLOVER_FILES` setting controls how many `.sqlaudit` files are kept, but the total size cap is `MAXSIZE × MAX_ROLLOVER_FILES`. Archive older files off-server before they consume disk.

Check current audit file sizes:

```powershell
$splatFiles = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaServerAudit @splatFiles |
    Select-Object SqlInstance, Name, FilePath |
    ForEach-Object {
        Get-ChildItem "$($_.FilePath)\*.sqlaudit" |
            Select-Object Name, @{N='SizeMB'; E={[math]::Round($_.Length/1MB, 2)}}, LastWriteTime
    }
```

---

## CIS Benchmark Alignment

The CIS Microsoft SQL Server Benchmark (available at cisecurity.org) maps specific recommendations to audit action groups. Key CIS sections addressed by the above configuration:

| CIS Recommendation | Covered By |
|---|---|
| 3.1 — Ensure 'Server Audit' is set to 'On' | `CREATE SERVER AUDIT` + `STATE = ON` |
| 3.2 — Ensure 'Failed Logins' are audited | `FAILED_LOGIN_GROUP` |
| 3.3 — Ensure 'Login Auditing' includes both success and failure | `SUCCESSFUL_LOGIN_GROUP` + `FAILED_LOGIN_GROUP` |
| 4.1 — Ensure the audit specification captures DDL changes | `SCHEMA_OBJECT_CHANGE_GROUP` + `DATABASE_OBJECT_CHANGE_GROUP` |

---

## Related Documents

- [Security](Security.md) — authentication strategy, roles, and access control
- [Extended Events](../Operations/Extended-Events.md) — lightweight event capture for performance and blocking (separate from compliance auditing)
