# Database Configuration Baseline

## Purpose

Define the ALTER DATABASE settings that every managed database should have audited and corrected. These are the configuration hygiene items that get missed during initial deployment and accumulate silently — auto-shrink, percentage autogrowth, missing CHECKSUM, wrong compat level. This document covers what each setting does, what the correct value is, and how to detect and fix deviations across all databases.

---

## Configuration Reference

| Setting | Correct Value | Default (if wrong) | Why |
|---|---|---|---|
| `AUTO_CLOSE` | OFF | OFF (correct by default) | ON destroys connection pooling and causes plan cache churn on every connection |
| `AUTO_SHRINK` | OFF | OFF (correct by default) | ON causes perpetual shrink/grow cycles, fragmenting data and wasting CPU |
| `AUTO_CREATE_STATISTICS` | ON | ON (correct) | Needed for optimizer to build statistics on unindexed columns |
| `AUTO_UPDATE_STATISTICS` | ON | ON (correct) | Required for stale statistics correction; see [Statistics Management](Statistics-Management.md) |
| `PAGE_VERIFY` | CHECKSUM | CHECKSUM (correct on new DBs) | Detects torn page and corruption on disk read; older databases may still have TORN_PAGE_DETECTION |
| Autogrowth unit | Fixed MB | Often % on inherited databases | Percentage growth produces unpredictably large events at scale; 256 MB for data, 64 MB for log |
| `TARGET_RECOVERY_INTERVAL` | 60 seconds | 60s (SQL 2016+) | Indirect checkpoints smooth I/O; older databases on 2016+ instances retain the old 0-second value if never touched |
| Compatibility level | Match instance version | Often one version behind | Running old compat level disables CE improvements and new optimizer features |

---

## Audit Current State

```sql
SET NOCOUNT ON;

SELECT
    [d].[name]                          AS DatabaseName,
    [d].[state_desc]                    AS State,
    [d].[compatibility_level]           AS CompatLevel,
    [d].[recovery_model_desc]           AS RecoveryModel,
    [d].[page_verify_option_desc]       AS PageVerify,
    [d].[is_auto_close_on]              AS AutoClose,
    [d].[is_auto_shrink_on]             AS AutoShrink,
    [d].[is_auto_create_stats_on]       AS AutoCreateStats,
    [d].[is_auto_update_stats_on]       AS AutoUpdateStats,
    [d].[target_recovery_time_in_seconds] AS TargetRecoveryTimeSec
FROM [sys].[databases] AS d
WHERE [d].[database_id] > 4           -- exclude system databases
ORDER BY [d].[name];
```

```sql
SET NOCOUNT ON;

-- Autogrowth settings for all user database files
SELECT
    DB_NAME([mf].[database_id])     AS DatabaseName,
    [mf].[name]                     AS LogicalName,
    [mf].[type_desc]                AS FileType,
    [mf].[size] / 128               AS SizeMB,
    CASE [mf].[is_percent_growth]
        WHEN 1 THEN CAST([mf].[growth] AS varchar) + '%'
        ELSE CAST([mf].[growth] / 128 AS varchar) + ' MB'
    END                             AS AutogrowthSetting,
    [mf].[is_percent_growth]        AS IsPercentGrowth
FROM [sys].[master_files] AS mf
WHERE [mf].[database_id] > 4
ORDER BY DatabaseName, [mf].[type_desc];
```

```powershell
# Audit configuration across multiple instances
$splatAudit = @{
    SqlInstance     = $instances
    EnableException = $true
}
Get-DbaDatabase @splatAudit |
    Where-Object { $_.IsSystemObject -eq $false } |
    Select-Object SqlInstance, Name, Compatibility, RecoveryModel, PageVerify,
                  AutoClose, AutoShrink, AutoCreateStatistics, AutoUpdateStatistics |
    Sort-Object SqlInstance, Name
```

---

## Applying Corrections

### Fix Common Settings

```sql
SET NOCOUNT ON;

-- Template: apply to each database that fails the audit
-- Replace [DatabaseName] with the target database

ALTER DATABASE [DatabaseName] SET AUTO_CLOSE        OFF WITH NO_WAIT;
ALTER DATABASE [DatabaseName] SET AUTO_SHRINK       OFF WITH NO_WAIT;
ALTER DATABASE [DatabaseName] SET PAGE_VERIFY       CHECKSUM WITH NO_WAIT;
ALTER DATABASE [DatabaseName] SET TARGET_RECOVERY_TIME = 60 SECONDS;
ALTER DATABASE [DatabaseName] SET AUTO_UPDATE_STATISTICS ON WITH NO_WAIT;
ALTER DATABASE [DatabaseName] SET AUTO_CREATE_STATISTICS ON WITH NO_WAIT;
```

### Fix Percentage Autogrowth

Correct autogrowth to fixed MB values. These are starting points — size to your environment.

```sql
SET NOCOUNT ON;

-- Data file: 256 MB fixed growth
ALTER DATABASE [DatabaseName]
MODIFY FILE
(
    NAME = N'LogicalDataFileName',
    FILEGROWTH = 262144KB    -- 256 MB
);

-- Log file: 64 MB fixed growth
ALTER DATABASE [DatabaseName]
MODIFY FILE
(
    NAME = N'LogicalLogFileName',
    FILEGROWTH = 65536KB     -- 64 MB
);
```

For high-volume OLTP data files, increase to 512 MB or 1 GB to avoid frequent autogrowth events. The goal is that autogrowth fires rarely — it should be a safety net, not routine operation.

### Fix Compatibility Level

```sql
SET NOCOUNT ON;

-- Check current compat levels
SELECT [name], [compatibility_level]
FROM   [sys].[databases]
WHERE  [database_id] > 4
ORDER BY [name];

-- Raise to SQL Server 2019 (150)
ALTER DATABASE [DatabaseName] SET COMPATIBILITY_LEVEL = 150;
```

| SQL Server Version | Compatibility Level |
|---|---|
| 2016 | 130 |
| 2017 | 140 |
| 2019 | 150 |
| 2022 | 160 |

Change compatibility level only after reviewing the query regression risk. Run a query workload baseline before and after in development. Query Store makes this manageable — see [Query Store](../Operations/Query-Store.md).

---

## Recovery Model

| Recovery Model | Log Backup Required | Point-in-Time Restore | Typical Use |
|---|---|---|---|
| FULL | Yes | Yes | Production OLTP, anything with a DR requirement |
| BULK_LOGGED | Yes | Limited | ETL load windows — switch back to FULL after the load |
| SIMPLE | No | No | Dev/test, databases where data loss is acceptable |

Production databases must be in FULL recovery model. A database in SIMPLE recovery cannot participate in log shipping or an AG.

```sql
SET NOCOUNT ON;

ALTER DATABASE [DatabaseName] SET RECOVERY FULL;

-- After changing to FULL, take a full backup immediately.
-- Without a full backup, the log will not truncate and will grow unbounded.
```

---

## Read Committed Snapshot Isolation (RCSI)

RCSI changes the behavior of the default READ COMMITTED isolation level. Without RCSI, readers take shared locks and can block writers (and vice versa). With RCSI, readers read from the row version store in TempDB and never block writers.

**When to enable:**
- High concurrency OLTP with frequent reader-writer blocking
- As a prerequisite for deadlock reduction on tables with mixed read/write patterns
- On any database where `LCK_M_S` waits are a regular occurrence

**Trade-offs:**
- TempDB version store grows proportionally to the amount of in-flight row changes. Size TempDB accordingly before enabling.
- Slightly higher write overhead — SQL Server must maintain row version records.
- `SELECT @@VERSION` queries against RCSI-enabled databases may see slightly stale data — the row version reflects the committed state at the start of the statement.

```sql
SET NOCOUNT ON;

-- Enable RCSI — requires brief exclusive access (kicks open connections)
-- Run during a low-traffic window
ALTER DATABASE [DatabaseName] SET READ_COMMITTED_SNAPSHOT ON WITH ROLLBACK IMMEDIATE;

-- Verify
SELECT [name], [is_read_committed_snapshot_on]
FROM   [sys].[databases]
WHERE  [name] = N'DatabaseName';
```

---

## Applying Settings at Scale

```powershell
$ErrorActionPreference = 'Stop'

$targetDatabases = Get-DbaDatabase -SqlInstance $instance |
    Where-Object { -not $_.IsSystemObject }

foreach ($db in $targetDatabases) {
    [PSCustomObject]@{
        SqlInstance   = $db.SqlInstance
        Database      = $db.Name
        AutoClose     = $db.AutoClose
        AutoShrink    = $db.AutoShrink
        PageVerify    = $db.PageVerify
        RecoveryModel = $db.RecoveryModel
        CompatLevel   = $db.Compatibility
    }
}
```

Use the output to build a targeted list of databases to correct rather than applying changes blindly to all databases. Some databases — third-party vendor databases — may have intentional deviations.

---

## Related Documents

- [Statistics Management](Statistics-Management.md) — AUTO_UPDATE_STATISTICS behavior and manual update patterns
- [Query Store](../Operations/Query-Store.md) — managing compat level changes with query regression safety net
- [Deadlock Analysis](../Operations/Deadlock-Analysis.md) — RCSI as a deadlock mitigation
- [Capacity Planning](../Operations/Capacity-Planning.md) — TempDB sizing for version store
