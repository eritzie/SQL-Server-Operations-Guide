# SQL Server Monitoring

> **Environment context:** These practices were developed for monitoring SQL Server environments ranging from standalone instances to multi-node failover clusters. The approach combines real-time troubleshooting tools, proactive alerting via SQL Agent, and community-built monitoring stored procedures.

## Table of Contents

- [Real-Time Activity Monitoring](#real-time-activity-monitoring)
- [Blocking Detection](#blocking-detection)
- [Wait Statistics](#wait-statistics)
- [SQL Agent Job Monitoring](#sql-agent-job-monitoring)
- [Disk Space Monitoring](#disk-space-monitoring)
- [Database Health Checks](#database-health-checks)
- [Log Shipping Monitoring](#log-shipping-monitoring)
- [Proactive Alerting](#proactive-alerting)
- [Monitoring Tools and Resources](#monitoring-tools-and-resources)

## Real-Time Activity Monitoring

### sp_WhoIsActive

[sp_WhoIsActive](http://whoisactive.com/) is the go-to tool for real-time session monitoring. It shows currently executing queries, their resource consumption, blocking chains, and wait types — far more detail than the built-in Activity Monitor.

Install it on every instance:

```powershell
Install-DbaWhoIsActive -SqlInstance SqlServer01 -Database master
```

Basic usage:

```sql
-- Current activity with query text and wait info
EXEC sp_WhoIsActive;

-- Include the execution plan for running queries
EXEC sp_WhoIsActive @get_plans = 1;

-- Include blocking chain detail
EXEC sp_WhoIsActive @get_locks = 1;

-- Filter to a specific database
EXEC sp_WhoIsActive @filter_type = 'database', @filter = 'DatabaseName';

-- Show sleeping sessions with open transactions (potential orphaned transactions)
EXEC sp_WhoIsActive @show_sleeping_spids = 2;
```

For full parameter documentation, refer to [whoisactive.com/docs](http://whoisactive.com/docs/).

### Activity Monitor (SSMS)

SSMS includes a built-in Activity Monitor accessible by right-clicking the server name and selecting **Activity Monitor**. It provides a graphical overview of processor time, waiting tasks, database I/O, and recent expensive queries. The Processes panel can be sorted by the "Blocked By" or "Head Blocker" columns to quickly identify blocking chains.

Activity Monitor is useful for a quick visual check but lacks the flexibility and detail of sp_WhoIsActive for deeper troubleshooting.

### dbatools Session Monitoring

```powershell
# List all active sessions (equivalent to sp_who2)
Get-DbaProcess -SqlInstance SqlServer01 |
    Select-Object Spid, Login, Host, Database, Program, Status, Command |
    Out-GridView

# Find sessions for a specific database
Get-DbaProcess -SqlInstance SqlServer01 -Database DatabaseName

# Find sessions for a specific login
Get-DbaProcess -SqlInstance SqlServer01 -Login 'DOMAIN\ServiceAccount'

# Kill a blocking session (use with caution)
Stop-DbaProcess -SqlInstance SqlServer01 -Spid 52
```

## Blocking Detection

Blocking is one of the most common performance complaints. A single long-running transaction can cascade into dozens of blocked sessions.

### Quick Check

```sql
-- Find current blocking chains
SELECT
    r.session_id AS BlockedSession,
    r.blocking_session_id AS BlockingSession,
    r.wait_type,
    r.wait_time / 1000.0 AS WaitTimeSec,
    DB_NAME(r.database_id) AS DatabaseName,
    t.text AS BlockedQuery
FROM sys.dm_exec_requests r
OUTER APPLY sys.dm_exec_sql_text(r.sql_handle) t
WHERE r.blocking_session_id > 0
ORDER BY r.wait_time DESC;
```

```powershell
# Find blocked processes
Get-DbaProcess -SqlInstance SqlServer01 |
    Where-Object { $_.BlockingSpid -gt 0 } |
    Select-Object Spid, BlockingSpid, Login, Host, Database, Program, Command
```

### Head Blocker Identification

The query above shows direct blocking relationships but not the head of the chain. Use sp_WhoIsActive or the First Responder Kit for chain analysis:

```sql
-- sp_WhoIsActive with blocking detail
EXEC sp_WhoIsActive @get_locks = 1;

-- sp_BlitzWho for a point-in-time snapshot with blocking info
EXEC sp_BlitzWho;
```

For deeper analysis of blocking patterns over time, refer to [Brent Ozar's blocking troubleshooting guide](https://www.brentozar.com/archive/2018/11/how-to-troubleshoot-blocking-and-deadlocking-with-scripts-and-tools/).

## Wait Statistics

Wait statistics tell you what SQL Server is spending its time waiting on. They're the starting point for any performance investigation.

```sql
-- Top 10 waits by total wait time (excludes idle/background waits)
SELECT TOP 10
    wait_type,
    waiting_tasks_count,
    wait_time_ms / 1000.0 AS wait_time_sec,
    signal_wait_time_ms / 1000.0 AS signal_wait_sec,
    (wait_time_ms - signal_wait_time_ms) / 1000.0 AS resource_wait_sec
FROM sys.dm_os_wait_stats
WHERE wait_type NOT IN (
    'SLEEP_TASK', 'BROKER_TASK_STOP', 'BROKER_TO_FLUSH',
    'SQLTRACE_BUFFER_FLUSH', 'CLR_AUTO_EVENT', 'CLR_MANUAL_EVENT',
    'LAZYWRITER_SLEEP', 'CHECKPOINT_QUEUE', 'WAITFOR',
    'XE_TIMER_EVENT', 'XE_DISPATCHER_WAIT', 'FT_IFTS_SCHEDULER_IDLE_WAIT',
    'LOGMGR_QUEUE', 'DIRTY_PAGE_POLL', 'HADR_FILESTREAM_IOMGR_IOCOMPLETION',
    'SP_SERVER_DIAGNOSTICS_SLEEP', 'BROKER_EVENTHANDLER', 'BROKER_RECEIVE_WAITFOR',
    'REQUEST_FOR_DEADLOCK_SEARCH', 'SQLTRACE_INCREMENTAL_FLUSH_SLEEP',
    'ONDEMAND_TASK_QUEUE', 'QDS_CLEANUP_STALE_QUERIES_TASK_MAIN_LOOP_SLEEP',
    'QDS_PERSIST_TASK_MAIN_LOOP_SLEEP'
)
ORDER BY wait_time_ms DESC;
```

```powershell
# Top waits via dbatools
Get-DbaWaitStatistic -SqlInstance SqlServer01 -Threshold 95 |
    Select-Object WaitType, WaitCount, WaitSeconds, ResourceSeconds, Percentage |
    Format-Table -AutoSize
```

For a comprehensive wait analysis, use sp_BlitzFirst:

```sql
-- Point-in-time performance snapshot
EXEC sp_BlitzFirst @SinceStartup = 1;

-- What's happening right now (10-second sample)
EXEC sp_BlitzFirst;
```

Common waits and what they indicate:

| Wait Type | Indicates | Investigation |
|---|---|---|
| CXPACKET / CXCONSUMER | Parallelism waits | Check MAXDOP and CTFP settings |
| PAGEIOLATCH_* | Disk I/O pressure | Check disk latency, missing indexes |
| LCK_M_* | Lock contention / blocking | Identify blocking chains |
| SOS_SCHEDULER_YIELD | CPU pressure | Check for plan regressions, missing indexes |
| WRITELOG | Transaction log write latency | Check log disk performance |
| PAGELATCH_* on PFS/GAM/SGAM | TempDB contention | Add TempDB data files |

## SQL Agent Job Monitoring

Failed Agent jobs can silently break backup chains, index maintenance, and log shipping. Monitor them proactively.

```powershell
# Find all failed jobs from the last 24 hours
Get-DbaAgentJobHistory -SqlInstance SqlServer01 -StartDate (Get-Date).AddDays(-1) |
    Where-Object { $_.Status -eq 'Failed' } |
    Select-Object Job, StepName, RunDate, Message |
    Out-GridView

# Check job run durations (catch jobs that are running longer than expected)
Get-DbaAgentJobHistory -SqlInstance SqlServer01 -StartDate (Get-Date).AddDays(-1) |
    Select-Object Job, StepName, RunDate, Duration |
    Sort-Object Duration -Descending |
    Out-GridView

# Get currently running Agent jobs
Get-DbaRunningJob -SqlInstance SqlServer01
```

```sql
-- Failed jobs in the last 24 hours
SELECT
    j.name AS JobName,
    h.step_name AS StepName,
    h.run_date,
    h.run_time,
    h.message
FROM msdb.dbo.sysjobhistory h
INNER JOIN msdb.dbo.sysjobs j ON h.job_id = j.job_id
WHERE h.run_status = 0  -- 0 = Failed
    AND CAST(CAST(h.run_date AS CHAR(8)) AS DATE) >= DATEADD(DAY, -1, CAST(GETDATE() AS DATE))
ORDER BY h.run_date DESC, h.run_time DESC;
```

## Disk Space Monitoring

Running out of disk space causes database autogrowth failures, backup failures, and in the worst case, database corruption.

```powershell
# Check disk free space on the SQL Server
Get-DbaDiskSpace -ComputerName SqlServer01 |
    Select-Object Name, Label, Capacity, Free, PercentFree |
    Format-Table -AutoSize

# Check database file sizes and growth settings
Get-DbaDbFile -SqlInstance SqlServer01 |
    Select-Object Database, LogicalName, TypeDescription, Size, UsedSpace, Growth, GrowthType |
    Out-GridView

# Find databases with autogrowth set to percentage (should be fixed MB)
Get-DbaDbFile -SqlInstance SqlServer01 |
    Where-Object { $_.GrowthType -eq 'Percent' } |
    Select-Object Database, LogicalName, TypeDescription, Growth, GrowthType
```

```sql
-- Database file sizes and free space
SELECT
    DB_NAME(database_id) AS DatabaseName,
    name AS LogicalName,
    type_desc,
    size / 128.0 AS SizeMB,
    FILEPROPERTY(name, 'SpaceUsed') / 128.0 AS UsedMB,
    (size - FILEPROPERTY(name, 'SpaceUsed')) / 128.0 AS FreeMB,
    growth,
    CASE is_percent_growth WHEN 1 THEN 'Percent' ELSE 'MB' END AS GrowthType
FROM sys.master_files
ORDER BY DatabaseName, type_desc;
```

## Database Health Checks

Run periodic health checks to catch issues before they become outages.

```powershell
# Comprehensive instance health check
Invoke-DbaQuery -SqlInstance SqlServer01 -Query "EXEC sp_Blitz @CheckServerInfo = 1;"

# DBCC CHECKDB status — find databases that haven't been checked recently
Get-DbaLastGoodCheckDb -SqlInstance SqlServer01 |
    Select-Object Database, LastGoodCheckDb, DataPurityEnabled, Status |
    Out-GridView
```

sp_Blitz (from the First Responder Kit) checks for over 100 common configuration issues and returns prioritized findings. Run it after any instance build, after upgrades, and periodically as a health audit.

```sql
-- Full instance health check
EXEC sp_Blitz @CheckServerInfo = 1;

-- Targeted check for a specific database
EXEC sp_Blitz @DatabaseName = 'DatabaseName';
```

## Log Shipping Monitoring

For environments using log shipping as a DR strategy, monitor the backup, copy, and restore chain to catch failures before they become a data loss risk.

```powershell
# Check for log shipping errors
Get-DbaDbLogShipError -SqlInstance SecondaryServer01

# Monitor restore latency
Invoke-DbaQuery -SqlInstance SecondaryServer01 -Database msdb -Query @"
SELECT
    secondary_database,
    last_copied_file,
    last_copied_date,
    last_restored_file,
    last_restored_date,
    last_restored_latency
FROM dbo.log_shipping_monitor_secondary
ORDER BY last_restored_latency DESC;
"@
```

Watch for `last_restored_latency` climbing beyond the configured alert threshold. See [Log Shipping Setup](LogShipping.md#monitoring-log-shipping) for additional detail.

## Proactive Alerting

Don't wait for someone to notice a problem. Configure SQL Agent alerts for critical conditions.

```powershell
# Create alerts for critical severity errors (severity 17-25)
17..25 | ForEach-Object {
    $params = @{
        SqlInstance  = 'SqlServer01'
        Alert        = "Severity $_ Error"
        Severity     = $_
        NotifyMethod = 'NotifyEmail'
        NotifyOperator = 'DBA-Team'
    }
    New-DbaAgentAlert @params
}

# Verify alerts are configured
Get-DbaAgentAlert -SqlInstance SqlServer01 |
    Select-Object Name, Severity, IsEnabled, HasNotification |
    Format-Table -AutoSize
```

At minimum, configure alerts for:

- **Severity 17–25 errors** — these indicate resource issues (17–19) and fatal hardware/software errors (20–25).
- **Error 823, 824, 825** — I/O errors that indicate disk or storage problems. Error 825 is a "successful retry" which means the disk is starting to fail but hasn't fully yet — this is your early warning.
- **Job failures** for critical jobs (backups, log shipping, index maintenance).

```sql
-- Alert for Error 825 (I/O retry success — early disk failure warning)
EXEC msdb.dbo.sp_add_alert
    @name = N'IO Error 825 - Successful Retry',
    @message_id = 825,
    @severity = 0,
    @enabled = 1,
    @notification_message = N'Disk I/O retry detected. Investigate storage health immediately.';
```

Ensure database mail is configured and a DBA operator exists to receive notifications:

```powershell
# Check if database mail is configured
Get-DbaDbMailProfile -SqlInstance SqlServer01

# Check operators
Get-DbaAgentOperator -SqlInstance SqlServer01 |
    Select-Object Name, EmailAddress, Enabled
```

## Monitoring Tools and Resources

### Installed Tools

These should be installed on every managed SQL Server instance:

| Tool | Purpose | Install Command |
|---|---|---|
| [First Responder Kit](https://www.brentozar.com/first-aid/) | Health checks, index analysis, cache analysis, wait stats | `Install-DbaFirstResponderKit` |
| [sp_WhoIsActive](http://whoisactive.com/) | Real-time activity monitoring | `Install-DbaWhoIsActive` |
| [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/) | Backup, index, and statistics maintenance | `Install-DbaMaintenanceSolution` |

### External References

| Resource | URL |
|---|---|
| SQL Server build list (version tracking) | [sqlserverbuilds.blogspot.com](https://sqlserverbuilds.blogspot.com/) |
| SQL Server Management Studio (latest) | [learn.microsoft.com/sql/ssms](https://learn.microsoft.com/en-us/sql/ssms/) |
| SQL Server community blog | [blog.sqlauthority.com](https://blog.sqlauthority.com/) |
| SQL Community Slack | [sqlcommunity.slack.com](https://sqlcommunity.slack.com/) |
| dbatools documentation | [docs.dbatools.io](https://docs.dbatools.io/) |