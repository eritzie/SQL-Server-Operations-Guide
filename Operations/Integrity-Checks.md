# Database Integrity Checks

## Purpose

DBCC CHECKDB detects data and index corruption before it spreads or becomes unrecoverable. Corruption that is undetected at write time may not surface until a read — which could be a restore during a disaster, by which point every backup in the retention window is also corrupt. Regular integrity checks close that window.

This document covers scheduling, interpreting output, responding to errors, and offloading checks to AG secondary replicas.

---

## How Often to Run

| Database Tier | Recommended Frequency | Notes |
|---|---|---|
| Production OLTP | Weekly | Ola's DatabaseIntegrityCheck, scheduled via SQL Agent |
| Data warehouse / large databases | Weekly, off-peak | Can take hours on multi-TB databases; monitor duration |
| Dev / test instances | Monthly or before a production restore | Lower priority but corruption still invalidates backups |

Track the last successful check in MSDB — SQL Server records it in `msdb.dbo.suspect_pages` and the system health ring buffer. The simplest check:

```powershell
$splatCheck = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaLastGoodCheckDb @splatCheck |
    Select-Object SqlInstance, Database, LastGoodCheckDb, Status |
    Sort-Object LastGoodCheckDb
```

Databases with a `LastGoodCheckDb` older than 14 days need attention. A NULL result means CHECKDB has never completed successfully — or dbatools cannot find a record — investigate before assuming the database is healthy.

---

## Ola Hallengren DatabaseIntegrityCheck (Preferred)

```sql
SET NOCOUNT ON;

-- Check all user databases
EXEC [master].[dbo].[DatabaseIntegrityCheck]
    @Databases              = 'USER_DATABASES',
    @CheckCommands          = 'CHECKDB',
    @LogToTable             = 'Y';

-- Check a single database
EXEC [master].[dbo].[DatabaseIntegrityCheck]
    @Databases              = 'YourDatabase',
    @CheckCommands          = 'CHECKDB',
    @LogToTable             = 'Y';
```

`@LogToTable = 'Y'` writes results to `master.dbo.CommandLog`. Query it to review history and identify when a database was last checked and whether it passed:

```sql
SET NOCOUNT ON;

SELECT TOP 50
    [DatabaseName],
    [CommandType],
    [StartTime],
    [EndTime],
    DATEDIFF(MINUTE, [StartTime], [EndTime]) AS DurationMin,
    [ErrorNumber],
    [ErrorMessage]
FROM [master].[dbo].[CommandLog]
WHERE [CommandType] = 'DBCC_CHECKDB'
ORDER BY [StartTime] DESC;
```

See [[Maintenance-Solution|Ola Hallengren Maintenance Solution]] for installation and SQL Agent job setup.

---

## T-SQL Fallback

```sql
SET NOCOUNT ON;

-- Full check — detects logical and physical corruption, validates constraints
DBCC CHECKDB (N'YourDatabase') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Physical-only check — faster, skips logical checks and constraint validation
-- Use for very large databases where full CHECKDB is too slow
DBCC CHECKDB (N'YourDatabase') WITH PHYSICAL_ONLY, NO_INFOMSGS, ALL_ERRORMSGS;

-- Check a single table
DBCC CHECKTABLE (N'dbo.Order') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Check allocation structures only (fast, catches GAM/SGAM/PFS corruption)
DBCC CHECKALLOC (N'YourDatabase') WITH NO_INFOMSGS, ALL_ERRORMSGS;

-- Check system catalog consistency
DBCC CHECKCATALOG (N'YourDatabase');
```

`WITH NO_INFOMSGS` suppresses the informational output and returns only errors. Always include it in scheduled runs to keep logs readable.

---

## Interpreting Output

A clean run produces no output (with `NO_INFOMSGS`). Any rows returned indicate a problem.

| Output Pattern | Meaning |
|---|---|
| `CHECKDB found 0 allocation errors and 0 consistency errors` | Clean |
| Error 8928, 8929 | Row corruption in a data page |
| Error 8909, 8905 | Allocation structure inconsistency — corrupt PFS/GAM/SGAM page |
| Error 2570 | Page checksum failure — hardware I/O error or storage problem |
| Error 824 | I/O error that SQL Server retried and failed — storage layer issue |
| `Object ID X, index ID Y` with `cannot be repaired` | Extent-level corruption requiring restore |

Severity 16 errors are fixable (sometimes with data loss). Severity 20+ errors are typically hardware-level corruption requiring a restore.

---

## Responding to Corruption

> **First action: do not attempt repair until you have a known-good backup.** DBCC REPAIR options remove corrupted data — you cannot undo them.

### Step 1 — Identify the scope

```sql
SET NOCOUNT ON;

-- Check suspect_pages for recent I/O errors
SELECT
    DB_NAME([database_id])  AS DatabaseName,
    [file_id],
    [page_id],
    [event_type],
    [error_count],
    [last_update_date]
FROM [msdb].[dbo].[suspect_pages]
WHERE [event_type] IN (1, 2, 3)   -- 1=823/824, 2=bad checksum, 3=torn page
ORDER BY [last_update_date] DESC;
```

### Step 2 — Attempt restore from backup

This is the preferred resolution for all corruption. Restore the database to a point before the corruption appeared. Use `RESTORE PAGE` for isolated page corruption if a full database restore is not practical:

```sql
SET NOCOUNT ON;

-- Restore a single corrupt page without taking the database offline
RESTORE DATABASE [YourDatabase]
    PAGE = '1:43528'        -- file_id:page_id from suspect_pages
    FROM DISK = N'X:\Backups\YourDatabase.bak'
WITH NORECOVERY;

-- Then restore log backups up to the current LSN to bring the page current
RESTORE LOG [YourDatabase]
    FROM DISK = N'X:\Backups\YourDatabase_log.trn'
WITH RECOVERY;
```

### Step 3 — DBCC REPAIR (last resort, data loss)

Use only when no usable backup exists. `REPAIR_ALLOW_DATA_LOSS` removes corrupt rows and pages — the data is gone.

```sql
SET NOCOUNT ON;

-- Must be in single-user mode
ALTER DATABASE [YourDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;

DBCC CHECKDB (N'YourDatabase', REPAIR_ALLOW_DATA_LOSS) WITH NO_INFOMSGS, ALL_ERRORMSGS;

ALTER DATABASE [YourDatabase] SET MULTI_USER;
```

After repair, immediately take a full backup and run CHECKDB again to confirm the database is clean.

> **After any corruption event:** check the Windows Event Log and storage subsystem logs for I/O errors (Event ID 11, 51, 157). If the storage layer is the cause, repair is futile — corruption will recur. Engage the infrastructure team to verify disk health.

---

## Offloading to an AG Secondary

In an AG environment, CHECKDB can run on the readable secondary to avoid I/O impact on the primary. SQL Server 2022 introduced the ability to run CHECKDB on a secondary and have results reflected in the primary's `LastGoodCheckDb`:

```sql
-- Run on the secondary replica
DBCC CHECKDB (N'YourDatabase') WITH NO_INFOMSGS, ALL_ERRORMSGS;
```

For Basic AGs (Standard Edition), the secondary is not readable — CHECKDB must run on the primary or on a database restored separately from backup.

---

## Scheduling via SQL Agent

Ola's DatabaseIntegrityCheck is designed to run as a SQL Agent job. Recommended schedule: weekly, Sunday during a low-traffic window, with email notification on failure.

```powershell
$splatJob = @{
    SqlInstance     = $instance
    Job             = 'DatabaseIntegrityCheck - USER_DATABASES'
    EnableException = $true
}
Get-DbaAgentJob @splatJob | Select-Object Name, IsEnabled, LastRunDate, LastRunOutcome
```

If the job has not run in more than 10 days, or the last run outcome is not `Succeeded`, investigate before assuming the databases are healthy.

---

## Related Documents

- [[Maintenance-Solution|Ola Hallengren Maintenance Solution]] — DatabaseIntegrityCheck setup and scheduling
- [[Backup-and-Restore|Backup and Restore]] — RESTORE PAGE and point-in-time restore procedures
- [[../Operations/Monitoring|Monitoring]] — DBCC CHECKDB status across instances
- [[Operations|Back to Operations]]
