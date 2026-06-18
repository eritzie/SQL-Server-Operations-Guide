---
title: "SQL Server Audit Standards"
tags:
  - audit
  - security
  - compliance
  - login
  - standards
category: "Standards"
summary: "Defines the SQL Server Audit standard for all managed instances: required action groups, file configuration, retention, deployment patterns, and querying audit data."
---

# SQL Server Audit Standards

## Purpose

Define the standard for capturing security and operational events across all managed SQL
Server instances using SQL Server Audit. Establishes which events are captured, how audit
data is stored and retained, when to use SQL Server Audit versus Extended Events, and how
to query audit output for investigation and compliance purposes.

## Scope

Applies to all managed SQL Server instances. Deployment scripts are maintained in the
DBAOps project (`ServerAudit\` folder). Audit files are written to a dedicated directory
on each instance.

---

## SQL Server Audit vs Extended Events

| Concern | SQL Server Audit | Extended Events |
|---|---|---|
| Login and logout capture | Preferred | Redundant |
| Tamper evidence | Yes — `AUDIT_CHANGE_GROUP` records changes to the audit | No |
| Compliance-grade record | Yes | Not typically accepted |
| Query-level detail (sa activity) | Use sparingly — high volume | Preferred for targeted capture |
| SP execution telemetry | Unsuitable — volume is prohibitive | Preferred |
| Blocked process, deadlock capture | Unsuitable | Preferred |

Use SQL Server Audit for identity and access events (logins, role changes, permission
changes, DDL). Use Extended Events for query-level diagnostics and performance telemetry.
Do not use both for the same event type — pick the right tool and consolidate.

---

## Naming Conventions

| Object | Pattern | Example |
|---|---|---|
| Server Audit | `DBAOps_ServerAudit` | `DBAOps_ServerAudit` |
| Server Audit Specification | `DBAOps_ServerAudit_Spec` | `DBAOps_ServerAudit_Spec` |
| Database Audit Specification (baseline) | `DBAOps_DatabaseAudit_Baseline_Spec` | `DBAOps_DatabaseAudit_Baseline_Spec` |
| Database Audit Specification (enhanced) | `DBAOps_DatabaseAudit_<Purpose>_Spec` | `DBAOps_DatabaseAudit_GP_Spec` |

One server audit per instance. All audit specifications (server and database) bind to
the same `DBAOps_ServerAudit` object and write to the same file target.

---

## Server-Level Audit

### File Target Configuration

| Setting | Value | Notes |
|---|---|---|
| Path | `E:\Audit\` | Separate from XE files at `E:\XEvents\`; verify path exists before deploying |
| `MAXSIZE` | 100 MB | Per rollover file |
| `MAX_ROLLOVER_FILES` | 10 | 1 GB max on disk; adjust for retention needs |
| `QUEUE_DELAY` | 1000 ms | Default; increase if audit write I/O impacts workload |
| `ON_FAILURE` | `CONTINUE` | SQL Server keeps running if audit target is unavailable |

`ON_FAILURE = FAIL_OPERATION` is the stricter setting — SQL Server blocks all audited
operations when the target cannot be written. Use it only when compliance policy
explicitly requires it; it will take the instance offline if the audit volume fills the
disk or the path becomes unavailable.

The SQL Server service account requires write access to `E:\Audit\`:

```powershell
# Default instance
icacls "E:\Audit" /grant "NT SERVICE\MSSQLSERVER:(OI)(CI)F"

# Named instance (replace ENT with the instance name)
icacls "E:\Audit" /grant "NT SERVICE\MSSQL$ENT:(OI)(CI)F"
```

### Required Action Groups

All instances must have the following action groups in `DBAOps_ServerAudit_Spec`:

| Action Group | What It Captures |
|---|---|
| `SUCCESSFUL_LOGIN_GROUP` | Every successful login to the instance |
| `FAILED_LOGIN_GROUP` | Every failed login attempt |
| `SERVER_PRINCIPAL_CHANGE_GROUP` | Logins created, altered, or dropped |
| `SERVER_ROLE_MEMBER_CHANGE_GROUP` | Sysadmin and other server role membership changes |
| `AUDIT_CHANGE_GROUP` | Changes to the audit itself — required for tamper evidence |
| `DATABASE_CHANGE_GROUP` | Databases created, altered, or dropped |
| `BACKUP_RESTORE_GROUP` | Backup and restore operations |

### Excluded Action Groups

`LOGOUT_GROUP` is intentionally excluded from the baseline. Logout events add volume
without proportional security value — login timestamp alone is sufficient to establish
session context for most investigations. Add it if session duration tracking is a
compliance requirement.

`SQL_BATCH_COMPLETED_GROUP` and `RPC_COMPLETED_GROUP` are excluded at the server level.
Query-level telemetry at that scale is prohibitive in audit files. Use Extended Events
(`DBAOps_SpExecutionCapture`, `DBAOps_SaActivityMonitor`) for targeted query capture.

---

## Database-Level Audit

### Baseline Specification

Deploy `DBAOps_DatabaseAudit_Baseline_Spec` to every user database. This specification
captures DDL and access control events within each database.

| Action Group | What It Captures |
|---|---|
| `SCHEMA_OBJECT_CHANGE_GROUP` | Tables, views, procedures, indexes: CREATE, ALTER, DROP |
| `DATABASE_PERMISSION_CHANGE_GROUP` | GRANT, REVOKE, DENY within the database |
| `DATABASE_ROLE_MEMBER_CHANGE_GROUP` | Database role membership changes |

The baseline specification does not capture data reads or writes. Table-level data access
auditing belongs in an enhanced specification scoped to specific databases.

System databases (`master`, `model`, `msdb`, `tempdb`) do not need this specification —
server-level action groups cover the significant events on system databases.

### Enhanced Specification (Sensitive Databases)

For databases containing sensitive, regulated, or financially significant data (GP
company databases, financial reporting databases), add a separate enhanced specification
targeting specific tables:

```sql
CREATE DATABASE AUDIT SPECIFICATION [DBAOps_DatabaseAudit_GP_Spec]
FOR SERVER AUDIT [DBAOps_ServerAudit]
ADD (SELECT, INSERT, UPDATE, DELETE ON [dbo].[SomeTable] BY PUBLIC)
WITH (STATE = ON);
```

Scope enhanced specifications narrowly. Broad data access auditing (all tables, all
users) generates volume that will fill audit files and degrade query performance.
Identify the specific tables and principals that justify enhanced capture before
deploying.

---

## Deployment

### Server Audit (per instance)

1. Create `E:\Audit\` on the instance and grant write access to the SQL Server service
   account (see File Target Configuration above).
2. Enable SQLCMD mode in SSMS (Query > SQLCMD Mode).
3. Set `:setvar AuditPath` to the correct path.
4. Run `ServerAudit\DBAOps_ServerAudit.sql` from the DBAOps project.
5. Verify with the queries at the bottom of the script.

### Database Audit Specification (per database, per instance)

The DBAOps_ServerAudit server audit must exist and be running before deploying database
audit specifications.

1. Enable SQLCMD mode.
2. Set `:setvar DatabaseName` to the target database.
3. Run `ServerAudit\DBAOps_DatabaseAudit_Baseline.sql` from the DBAOps project.
4. Repeat for each user database on the instance.

To identify which databases are missing the specification:

```powershell
$splatCheck = @{
    SqlInstance = 'SQL-DEV-01'
    Query       = "SELECT [name] FROM sys.database_audit_specifications
                   WHERE [name] = N'DBAOps_DatabaseAudit_Baseline_Spec'"
}
Get-DbaDatabase -SqlInstance $splatCheck.SqlInstance -ExcludeSystem |
    ForEach-Object {
        $result = Invoke-DbaQuery @splatCheck -Database $_.Name
        [PSCustomObject]@{
            Database = $_.Name
            HasSpec  = $null -ne $result
        }
    } |
    Where-Object { -not $_.HasSpec }
```

---

## Querying Audit Files

Audit files are read with `sys.fn_get_audit_file`. The glob pattern
`N'E:\Audit\DBAOps_ServerAudit*.sqlaudit'` covers all rollover files for the session.

### Identify sa Logins (Application Remediation)

```sql
SELECT
    [event_time],
    [server_principal_name],
    [client_ip],
    [application_name],
    [host_name],
    [database_name],
    [succeeded]
FROM sys.fn_get_audit_file(
    N'E:\Audit\DBAOps_ServerAudit*.sqlaudit', DEFAULT, DEFAULT
)
WHERE [server_principal_name] = N'sa'
  AND [succeeded]             = 1
ORDER BY [event_time] DESC;
```

### Failed Login Report

```sql
SELECT
    [server_principal_name],
    [client_ip],
    [application_name],
    [host_name],
    COUNT(*)       AS FailureCount,
    MIN([event_time]) AS FirstSeen,
    MAX([event_time]) AS LastSeen
FROM sys.fn_get_audit_file(
    N'E:\Audit\DBAOps_ServerAudit*.sqlaudit', DEFAULT, DEFAULT
)
WHERE [succeeded] = 0
GROUP BY
    [server_principal_name],
    [client_ip],
    [application_name],
    [host_name]
ORDER BY FailureCount DESC;
```

### Security Change Report

```sql
SELECT
    [event_time],
    [server_principal_name]  AS ChangedBy,
    [audit_action_name]      AS Action,
    [object_name],
    [target_server_principal_name] AS AffectedPrincipal,
    [statement]
FROM sys.fn_get_audit_file(
    N'E:\Audit\DBAOps_ServerAudit*.sqlaudit', DEFAULT, DEFAULT
)
WHERE [audit_action_name] NOT IN (N'LOGIN', N'FAILED_LOGIN', N'BACKUP', N'RESTORE')
ORDER BY [event_time] DESC;
```

---

## Compliance Verification

Verify audit deployment across all managed instances:

```sql
-- On each instance: confirm audit is running
SELECT
    [name]             AS AuditName,
    [is_state_enabled] AS Running,
    [type_desc]        AS TargetType
FROM sys.server_audits
WHERE [name] = N'DBAOps_ServerAudit';

-- Confirm all required action groups are present
SELECT
    d.[audit_action_name] AS ActionGroup
FROM sys.server_audit_specification_details d
JOIN sys.server_audit_specifications        s ON d.[server_specification_id] = s.[server_specification_id]
WHERE s.[name] = N'DBAOps_ServerAudit_Spec'
ORDER BY d.[audit_action_name];
```

```powershell
# Fleet-wide: report audit state on all instances
$instances = @('SQL-PROD-01', 'SQL-PROD-02', 'SQL-RPT-01', 'SQL-DEV-01')

$splatQuery = @{
    Query = "SELECT @@SERVERNAME AS Instance, [name], [is_state_enabled]
             FROM sys.server_audits
             WHERE [name] = N'DBAOps_ServerAudit'"
}
foreach ($inst in $instances) {
    Invoke-DbaQuery -SqlInstance $inst @splatQuery
}
```

---

## Retention

Audit files roll over at 100 MB with a maximum of 10 files (1 GB per instance). This is
the floor — adjust `MAX_ROLLOVER_FILES` upward on instances with high login volume or
where compliance policy mandates a longer on-disk window.

For long-term retention beyond what fits on disk, archive `.sqlaudit` files to a network
share or cold storage before they are overwritten. SQL Server does not manage off-disk
archival — this requires a scheduled job or OS-level task.

---

## See Also

- [[Standards/Naming-Conventions|Naming Conventions]] — audit object naming rules
- [[Standards/Agent-Job-Standards|SQL Agent Job Standards]] — scheduling audit-related jobs
- [[Standards/SQL-Standards-and-Policies|SQL Standards and Policies]] — security policy context
- [[../Index|Back to Index]]
