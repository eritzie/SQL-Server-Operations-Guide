# Query Store

## Purpose

Document when to enable Query Store, what settings to use, and how to use it for plan regression detection and performance troubleshooting. Query Store captures query plans and runtime statistics over time, making it possible to identify when a plan changed and force a prior good plan without code changes.

---

## GP Exception — Read First

> [!WARNING]
> Do not enable Query Store on DYNAMICS or GP company databases without explicit testing in a GP test environment first. GP has historically been sensitive to Query Store in specific versions. Validate on a GP test instance before enabling on any production GP database.

If Query Store causes issues on GP databases, disable it immediately:

```sql
ALTER DATABASE [GPDatabase] SET QUERY_STORE = OFF;
```

---

## When to Enable

Enable Query Store on:

- OLTP production databases where plan regressions are a concern
- Databases that have experienced sudden unexplained performance degradation
- Databases undergoing active development where index or statistics changes are frequent

Query Store is not necessary on:

- Tempdb (not supported)
- Read-only databases (Query Store cannot write)
- Very small or low-activity databases where overhead is not justified

---

## Recommended Settings for OLTP

```sql
ALTER DATABASE [TargetDatabase]
SET QUERY_STORE = ON
(
    OPERATION_MODE              = READ_WRITE,
    CLEANUP_POLICY              = (STALE_QUERY_THRESHOLD_DAYS = 30),
    DATA_FLUSH_INTERVAL_SECONDS = 900,
    MAX_STORAGE_SIZE_MB         = 1024,
    INTERVAL_LENGTH_MINUTES     = 60,
    SIZE_BASED_CLEANUP_MODE     = AUTO,
    QUERY_CAPTURE_MODE          = AUTO
);
```

| Setting | Value | Reasoning |
|---|---|---|
| `STALE_QUERY_THRESHOLD_DAYS` | 30 | Retain 30 days of history for trend analysis |
| `DATA_FLUSH_INTERVAL_SECONDS` | 900 | Flush to disk every 15 minutes — balances data loss risk vs. I/O |
| `MAX_STORAGE_SIZE_MB` | 1024 | 1 GB is adequate for most OLTP databases; increase if running out |
| `SIZE_BASED_CLEANUP_MODE` | AUTO | Let SQL Server clean up old data when approaching the size cap |
| `QUERY_CAPTURE_MODE` | AUTO | Capture only significant queries — avoids flooding the store with trivial ad-hoc queries |

---

## Monitoring Query Store State

```powershell
$splatQs = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbQueryStoreOption @splatQs |
    Select-Object SqlInstance, DatabaseName, ActualState, CurrentStorageSizeKb, MaxStorageSizeKb
```

If `ActualState` shows `READ_ONLY`, Query Store has hit the storage cap. Either increase `MAX_STORAGE_SIZE_MB` or force cleanup:

```sql
ALTER DATABASE [TargetDatabase] SET QUERY_STORE CLEAR;
```

---

## Detecting Plan Regressions

The primary use case: a query was fast, then something changed (statistics update, index change, parameter sniffing) and it is now slow. Query Store lets you see both the old plan and the new plan.

### Find Top Regressed Queries

```sql
SET NOCOUNT ON;

SELECT TOP 20
    qsq.[query_id],
    qsqt.[query_sql_text],
    qsrs.[avg_duration]     / 1000 AS avg_ms_recent,
    qsrs.[count_executions]        AS executions_recent,
    qsrs_prev.[avg_duration] / 1000 AS avg_ms_prior,
    qsp.[plan_id]
FROM [sys].[query_store_query]              AS qsq
JOIN [sys].[query_store_query_text]         AS qsqt
    ON qsq.[query_text_id]  = qsqt.[query_text_id]
JOIN [sys].[query_store_plan]               AS qsp
    ON qsq.[query_id]       = qsp.[query_id]
JOIN [sys].[query_store_runtime_stats]      AS qsrs
    ON qsp.[plan_id]        = qsrs.[plan_id]
JOIN [sys].[query_store_runtime_stats_interval] AS qsrsi
    ON qsrs.[runtime_stats_interval_id] = qsrsi.[runtime_stats_interval_id]
JOIN [sys].[query_store_runtime_stats]      AS qsrs_prev
    ON qsp.[plan_id]        = qsrs_prev.[plan_id]
WHERE qsrsi.[start_time] >= DATEADD(HOUR, -24, GETUTCDATE())
  AND qsrs.[avg_duration] > qsrs_prev.[avg_duration] * 2   -- 2x slower than prior interval
ORDER BY (qsrs.[avg_duration] - qsrs_prev.[avg_duration]) DESC;
```

### Force a Known-Good Plan

Once a prior good plan is identified by `plan_id`:

```sql
EXEC [sys].[sp_query_store_force_plan]
    @query_id = <query_id>,
    @plan_id  = <good_plan_id>;
```

### Remove a Forced Plan

After the underlying issue is resolved (statistics rebuilt, index added, etc.):

```sql
EXEC [sys].[sp_query_store_unforce_plan]
    @query_id = <query_id>,
    @plan_id  = <forced_plan_id>;
```

---

## SSMS Query Store Reports

SSMS provides built-in Query Store reports under the database node:

- **Regressed Queries** — queries where the plan changed and performance worsened
- **Top Resource Consuming Queries** — ranked by CPU, duration, I/O, or memory
- **Queries with Forced Plans** — shows which plans are currently forced

Use these reports for routine review. The T-SQL queries above are for programmatic or ad-hoc investigation.

---

## Related Documents

- [[Performance-Practices|Performance Practices]] — indexing, wait stats, and broader performance guidance
- [[Monitoring|Monitoring]] — real-time activity and blocking detection
- [[Dynamics-GP-Impact-Reference|Dynamics GP Impact Reference]] — GP exception details
- [[../Index|Back to Index]]
