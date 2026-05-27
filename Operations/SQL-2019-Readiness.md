# SQL Server 2019 Readiness Guide

## Purpose

Upgrade planning and feature awareness guide for environments running SQL Server 2016 or 2017 that are moving to SQL Server 2019, or for shops already on 2019 that have not yet evaluated newer capabilities introduced with this version. SQL Server 2019 (compatibility level 150) introduced several IQP features, Accelerated Database Recovery, and security improvements that are worth enabling deliberately rather than discovering accidentally.

---

## Pre-Upgrade Checklist

### Collect Current Build Baseline

```powershell
$splatBuild = @{
    SqlInstance     = $instances
    EnableException = $true
}
Test-DbaBuild @splatBuild |
    Select-Object SqlInstance, Build, BuildTarget, Compliant, SPTarget, CUTarget |
    Sort-Object SqlInstance
```

### Compatibility Level Assessment

SQL Server 2019 installs with compatibility level 150 for new databases. Upgraded databases retain their previous level. **Do not change the compatibility level until you have tested the application at that level** — many IQP features activate at level 150 and can change query plan behavior.

```sql
SET NOCOUNT ON;

-- Check current compatibility levels across all user databases
SELECT
    [name],
    [compatibility_level],
    [recovery_model_desc],
    [state_desc]
FROM [sys].[databases]
WHERE [database_id] > 4
ORDER BY [name];
```

Key behavior changes at compatibility level 150 vs. 140:

| Feature | Behavior Change |
|---|---|
| Row mode memory grant feedback | Active — queries with spills may get larger grants automatically |
| Table variable deferred compilation | Active — eliminates the "table variable has 1 row" cardinality assumption |
| Batch mode on rowstore | Active — analytic queries on rowstore tables may use batch mode |
| Scalar UDF inlining | Active — eligible scalar functions are inlined into the calling query |

### Deprecated and Removed Features

```sql
SET NOCOUNT ON;

-- Features in use that are deprecated in SQL Server 2019
SELECT
    [instance_name],
    [name],
    [cntr_value]                AS usage_count
FROM [sys].[dm_os_performance_counters]
WHERE [object_name] LIKE '%Deprecated%'
  AND [cntr_value] > 0
ORDER BY [cntr_value] DESC;
```

Notable removals in SQL Server 2019:
- Machine Learning Services (R and Python) replaces the older R Services — scripts may need path updates
- `SET ANSI_NULLS OFF` and `SET ANSI_PADDING OFF` are deprecated — check stored procedures

---

## New Features Worth Enabling Post-Upgrade

### Accelerated Database Recovery (ADR)

Introduced in SQL Server 2019. ADR changes the recovery architecture so that recovery time is constant regardless of transaction log size. Long-running transactions no longer extend instance recovery time.

**Enable per database — not instance-wide:**

```sql
ALTER DATABASE [TargetDatabase] SET ACCELERATED_DATABASE_RECOVERY = ON;
```

**When to enable:** Databases with long-running transactions, frequent rollbacks of large transactions, or where recovery time after a crash is a concern.

**Tradeoff:** ADR creates a Persistent Version Store (PVS) in the database. The PVS consumes space and requires a cleanup process. Monitor PVS size:

```sql
SET NOCOUNT ON;

SELECT
    DB_NAME([database_id])  AS [database],
    [pvs_size_kb]           AS pvs_size_kb,
    [pvs_off_row_count]     AS off_row_count
FROM [sys].[dm_tran_persistent_version_store_stats]
ORDER BY [pvs_size_kb] DESC;
```

**When to skip:** Databases with very high version store activity (e.g., heavy RCSI workloads already generating a large version store) — ADR adds to that overhead.

### Intelligent Query Processing (IQP) at Level 150

IQP is a set of adaptive query processing features that activate at compatibility level 150. Most are enabled automatically when the level is set — no configuration required.

| IQP Feature | What It Does | Notes |
|---|---|---|
| **Row mode memory grant feedback** | Adjusts memory grants based on actual row counts observed in prior executions | Can reduce spills and over-allocation |
| **Table variable deferred compilation** | Defers compilation of queries referencing table variables until first execution | Eliminates the "1 row" estimate that causes poor plans |
| **Batch mode on rowstore** | Allows columnstore-style batch mode on regular B-tree tables for analytical queries | Enabled automatically for eligible queries |
| **Scalar UDF inlining** | Inlines eligible scalar functions into the calling query as subqueries | Verify no behavioral changes in UDFs with side effects |

Monitor IQP activity via Query Store. Plans that received feedback show a `QDS_PLAN_HINT` in the query plan:

```sql
SET NOCOUNT ON;

-- Queries that have received memory grant feedback
SELECT TOP 20
    qsq.[query_id],
    qsqt.[query_sql_text],
    qsp.[plan_id],
    qsp.[is_forced_plan],
    qsrs.[avg_duration]     / 1000 AS avg_ms,
    qsrs.[avg_query_max_used_memory] AS avg_grant_pages
FROM [sys].[query_store_plan]               AS qsp
JOIN [sys].[query_store_query]              AS qsq
    ON qsp.[query_id] = qsq.[query_id]
JOIN [sys].[query_store_query_text]         AS qsqt
    ON qsq.[query_text_id] = qsqt.[query_text_id]
JOIN [sys].[query_store_runtime_stats]      AS qsrs
    ON qsp.[plan_id] = qsrs.[plan_id]
WHERE qsp.[has_compile_replay_script] = 1   -- Plans with feedback
ORDER BY qsrs.[avg_duration] DESC;
```

### Lightweight Query Profiling (Always On)

SQL Server 2019 enables lightweight query profiling infrastructure by default at the instance level. This replaces the need for server-side traces or extended events sessions to capture last actual execution plans.

```sql
SET NOCOUNT ON;

-- Get last actual execution plan for running queries (no trace required)
SELECT
    s.[session_id],
    s.[login_name],
    r.[start_time],
    r.[status],
    r.[command],
    p.[query_plan]
FROM [sys].[dm_exec_requests]       AS r
JOIN [sys].[dm_exec_sessions]       AS s
    ON r.[session_id] = s.[session_id]
OUTER APPLY [sys].[dm_exec_query_plan_stats](r.[plan_handle]) AS p
WHERE s.[is_user_process] = 1
ORDER BY r.[start_time];
```

### Automatic Plan Correction

Query Store can automatically force the last known good plan when a regression is detected. Enable per database:

```sql
ALTER DATABASE [TargetDatabase]
SET AUTOMATIC_TUNING (FORCE_LAST_GOOD_PLAN = ON);
```

Review what the tuning system has corrected:

```sql
SET NOCOUNT ON;

SELECT
    [reason],
    [score],
    [details]
FROM [sys].[dm_db_tuning_recommendations]
WHERE [state] = 'Verifying'
   OR [state] = 'Success'
ORDER BY [score] DESC;
```

---

## Standard vs. Enterprise Feature Delta (SQL Server 2019)

| Feature | Standard | Enterprise |
|---|---|---|
| Accelerated Database Recovery | Yes | Yes |
| IQP (all features) | Yes | Yes |
| Basic Availability Groups | Yes (1 DB, 2 replicas) | N/A — use full AGs |
| Full Availability Groups | No | Yes |
| Readable AG secondaries | No | Yes |
| Online index operations | Limited | Full |
| Database compression | Yes | Yes |
| Resource Governor | No | Yes |
| In-memory OLTP | Yes (limited) | Full |
| Columnstore indexes | Yes | Yes |

---

## Related Documents

- [SQL Server 2022 Readiness](SQL-2022-Readiness.md) — next upgrade path
- [Query Store](Query-Store.md) — plan regression detection and feedback monitoring
- [Performance Practices](../Performance/PerformancePractices.md) — IQP interacts with index fragmentation and statistics
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — Basic AG setup for Standard Edition
