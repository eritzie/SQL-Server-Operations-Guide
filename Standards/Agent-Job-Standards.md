# SQL Agent Job Standards

## Purpose

Define standards for creating, naming, configuring, and auditing SQL Server Agent jobs. Job monitoring procedures (checking failures, identifying long-running jobs, reviewing history) are in [Monitoring](../Operations/Monitoring.md). This document covers how jobs must be built before they go to production.

---

## Naming

Format: `{Category} - {Action} - {Scope}`

| Category | Use For |
|---|---|
| `DBA` | DBA-owned maintenance and operational jobs |
| `APP` | Application-owned jobs deployed by the app team |
| `MAINT` | Maintenance Solution jobs (Ola Hallengren) |
| `REPL` | Replication agent jobs |

**Exception:** Ola Hallengren Maintenance Solution and SQL Server replication agent jobs retain their default names. They are well-known, widely referenced in external documentation, and searchable by name — renaming them creates operational confusion.

---

## Required Properties

Every job must have these properties set before deployment to production:

| Property | Requirement |
|---|---|
| Name | Follows naming convention |
| Category | Set to an approved category — never `[Uncategorized (Local)]` |
| Description | One or more sentences stating what the job does and who owns it |
| Notification operator | Required on any job that modifies data or is expected to run longer than 15 minutes |
| Owner | DBA service account — never SA |

---

## Step Configuration

- Every step must have an explicit **On Failure** action. Do not rely on the default behavior.
- For multi-step jobs, define whether failure on a given step stops the job or continues to a cleanup or notification step.
- T-SQL steps must include `SET NOCOUNT ON` and handle errors with `TRY/CATCH`.
- PowerShell steps must set `$ErrorActionPreference = 'Stop'` at the top of the script.
- Avoid `xp_cmdshell` in job steps. Use a proxy account with a mapped Windows credential instead — see Proxy Accounts below.

---

## Proxy Accounts

Any job step that requires OS-level access (file system, network shares, PowerShell with elevated rights) must use a proxy account mapped to a Windows credential. Enabling `xp_cmdshell` as a substitute is not permitted.

```sql
-- Verify configured proxy accounts
SELECT
    p.[name]                        AS ProxyName,
    c.[name]                        AS CredentialName,
    c.[credential_identity]         AS WindowsAccount,
    p.[enabled]
FROM [msdb].[dbo].[sysproxies]      AS p
JOIN [sys].[credentials]            AS c
    ON p.[credential_id] = c.[credential_id]
ORDER BY p.[name];
```

---

## History Retention

The SQL Server Agent default history limits (1,000 rows per job, 10,000 rows total) are too low for environments with active maintenance schedules. Increase limits immediately after installation or if jobs are losing history:

```sql
SET NOCOUNT ON;

EXEC [msdb].[dbo].[sp_set_sqlagent_properties]
    @jobhistory_max_rows         = 50000,
    @jobhistory_max_rows_per_job = 5000;
```

Verify current settings:

```sql
SET NOCOUNT ON;

SELECT
    [maximum_history_rows],
    [maximum_job_history_rows]
FROM [msdb].[dbo].[syssqlagentproperties];
```

---

## Audit Queries

### Jobs with no failure notification

```sql
SET NOCOUNT ON;

SELECT
    j.[name]                        AS JobName,
    j.[description],
    j.[enabled],
    SUSER_SNAME(j.[owner_sid])      AS JobOwner
FROM [msdb].[dbo].[sysjobs]         AS j
WHERE j.[enabled] = 1
  AND j.[notify_level_email]  = 0   -- 0 = Never
  AND j.[notify_level_netsend] = 0
  AND j.[notify_level_page]   = 0
ORDER BY j.[name];
```

### Jobs in the uncategorized category

```sql
SET NOCOUNT ON;

SELECT
    j.[name]    AS JobName,
    c.[name]    AS Category,
    j.[enabled]
FROM [msdb].[dbo].[sysjobs]         AS j
JOIN [msdb].[dbo].[syscategories]   AS c
    ON j.[category_id] = c.[category_id]
WHERE j.[enabled] = 1
  AND c.[name] = '[Uncategorized (Local)]'
ORDER BY j.[name];
```

### Jobs owned by SA

```sql
SET NOCOUNT ON;

SELECT
    j.[name]    AS JobName,
    j.[description],
    j.[enabled]
FROM [msdb].[dbo].[sysjobs] AS j
WHERE j.[owner_sid] = 0x01   -- SA SID is always 0x01
ORDER BY j.[name];
```

### Jobs with no description

```sql
SET NOCOUNT ON;

SELECT
    j.[name]    AS JobName,
    j.[enabled],
    SUSER_SNAME(j.[owner_sid]) AS JobOwner
FROM [msdb].[dbo].[sysjobs] AS j
WHERE j.[enabled] = 1
  AND (j.[description] IS NULL OR LTRIM(RTRIM(j.[description])) = '')
ORDER BY j.[name];
```

### dbatools — all audit queries at once

```powershell
$splatJobs = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaAgentJob @splatJobs |
    Where-Object {
        $_.IsEnabled -and (
            $_.OwnerLoginName -eq 'sa' -or
            $_.Category       -eq '[Uncategorized (Local)]' -or
            [string]::IsNullOrWhiteSpace($_.Description)
        )
    } |
    Select-Object SqlInstance, Name, Category, OwnerLoginName, Description
```

---

## Related Documents

- [Monitoring](../Operations/Monitoring.md) — checking job history, failures, and long-running jobs
- [Ola Hallengren Maintenance Solution](../Operations/Maintenance-Solution.md) — maintenance job setup and scheduling
