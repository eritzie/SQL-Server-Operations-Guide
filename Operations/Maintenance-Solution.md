# Ola Hallengren Maintenance Solution

## Purpose

Document the installation, configuration, and scheduling of the [Ola Hallengren Maintenance Solution](https://ola.hallengren.com), which provides production-grade stored procedures and SQL Agent jobs for index optimization (`IndexOptimize`), database integrity checks (`DatabaseIntegrityCheck`), and backups (`DatabaseBackup`). This solution is referenced throughout the operations standards — this document is the setup and configuration reference.

---

## Installation

```powershell
# Install via dbatools — installs all procedures and creates Agent jobs
$splatInstall = @{
    SqlInstance     = $instance
    Database        = 'master'          # or a dedicated DBAOps database
    InstallJobs     = $true
    LogToTable      = $true
    BackupLocation  = $backupPath
    CleanupTime     = 168               # Remove backup files older than 168 hours (7 days)
    EnableException = $true
}
Install-DbaMaintenanceSolution @splatInstall
```

`LogToTable` writes job execution results to `CommandLog` in the target database. This is the preferred approach — it enables historical querying of maintenance outcomes without parsing Agent job history.

### Verify Installation

```powershell
$splatVerify = @{
    SqlInstance     = $instance
    Database        = 'master'
    EnableException = $true
}
Get-DbaDbStoredProcedure @splatVerify |
    Where-Object Name -in 'DatabaseBackup', 'DatabaseIntegrityCheck', 'IndexOptimize' |
    Select-Object SqlInstance, Database, Name, CreateDate
```

---

## Job Schedule Recommendations

The solution installs default jobs with default schedules. Adjust schedules to fit the environment before enabling.

### Production OLTP Instances

| Job | Recommended Schedule | Notes |
|---|---|---|
| `DatabaseBackup - USER_DATABASES - FULL` | Daily, 10:00 PM | After business hours |
| `DatabaseBackup - USER_DATABASES - DIFF` | Every 4 hours, 6 AM – 10 PM | Between full backups |
| `DatabaseBackup - USER_DATABASES - LOG` | Every 15 minutes | Match RPO requirement |
| `DatabaseBackup - SYSTEM_DATABASES - FULL` | Daily, 9:00 PM | Before user database backup |
| `DatabaseIntegrityCheck - USER_DATABASES` | Weekly, Sunday 1:00 AM | Off-peak; after index jobs |
| `DatabaseIntegrityCheck - SYSTEM_DATABASES` | Weekly, Sunday 12:00 AM | |
| `IndexOptimize - USER_DATABASES` | Weekly, Saturday 11:00 PM | Before integrity check |

### Test Instances

| Job | Recommended Schedule | Notes |
|---|---|---|
| `DatabaseBackup - USER_DATABASES - FULL` | Daily, 11:00 PM | Simpler schedule, no differential needed |
| `DatabaseBackup - USER_DATABASES - LOG` | Every 30 minutes | Relaxed RPO acceptable |
| `DatabaseIntegrityCheck - USER_DATABASES` | Weekly, Sunday 2:00 AM | |
| `IndexOptimize - USER_DATABASES` | Weekly, Sunday 1:00 AM | |

### GP Instance Considerations

- Do not schedule index optimization during business hours or during expected GP posting windows.
- `IndexOptimize` on GP company databases will run online index rebuilds where possible (Enterprise Edition only — Standard Edition rebuilds are offline and will block GP). Verify edition before scheduling.
- See [[Dynamics-GP-Impact-Reference|Dynamics GP Impact Reference]] for the index rebuild impact assessment.

---

## IndexOptimize — Key Parameters

The `IndexOptimize` Agent job calls the stored procedure with default parameters. For custom runs or testing:

```sql
EXECUTE [master].[dbo].[IndexOptimize]
    @Databases              = 'USER_DATABASES',
    @FragmentationLow       = NULL,             -- No action below threshold
    @FragmentationMedium    = 'INDEX_REORGANIZE',
    @FragmentationHigh      = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationLevel1    = 5,                -- Medium threshold: 5%
    @FragmentationLevel2    = 30,               -- High threshold: 30%
    @MinNumberOfPages       = 1000,             -- Skip tiny indexes
    @UpdateStatistics       = 'ALL',
    @OnlyModifiedStatistics = 'Y',
    @LogToTable             = 'Y';
```

| Parameter | Value | Reasoning |
|---|---|---|
| `FragmentationLevel1` | 5 | Reorganize above 5% — matches guidance in Performance-Practices |
| `FragmentationLevel2` | 30 | Rebuild above 30% |
| `MinNumberOfPages` | 1000 | Skip indexes under ~8 MB — fragmentation on small indexes has negligible impact |
| `UpdateStatistics` | ALL | Update both index and column statistics in the same pass |
| `OnlyModifiedStatistics` | Y | Skip statistics that have not changed since last update |

---

## Monitoring Maintenance Outcomes

Query the `CommandLog` table for recent execution history:

```sql
SET NOCOUNT ON;

SELECT TOP 100
    [DatabaseName],
    [SchemaName],
    [ObjectName],
    [ObjectType],
    [IndexName],
    [StatisticsName],
    [Command],
    [StartTime],
    [EndTime],
    DATEDIFF(SECOND, [StartTime], [EndTime]) AS duration_sec,
    [ErrorNumber],
    [ErrorMessage]
FROM [master].[dbo].[CommandLog]
WHERE [StartTime] >= DATEADD(DAY, -7, GETDATE())
ORDER BY [StartTime] DESC;
```

```powershell
# Via dbatools — last 24 hours of maintenance job runs
$splatHistory = @{
    SqlInstance     = $instance
    JobName         = 'DatabaseBackup*', 'DatabaseIntegrityCheck*', 'IndexOptimize*'
    StartDate       = (Get-Date).AddDays(-1)
    EnableException = $true
}
Get-DbaAgentJobHistory @splatHistory |
    Select-Object SqlInstance, JobName, StartDate, StopDate, Status, Message
```

---

## Related Documents

- [[Backup-and-Restore|Backup and Restore]] — manual backup procedures and restore runbooks
- [[Performance-Practices|Performance Practices]] — index fragmentation thresholds and strategy
- [[Agent-Job-Standards|SQL Agent Job Standards]] — job naming, notification, and history retention
- [[Monitoring|Monitoring]] — Agent job failure monitoring
- [[../Index|Back to Index]]
