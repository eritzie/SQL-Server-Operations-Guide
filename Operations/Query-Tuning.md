# Query Tuning

## Purpose

A systematic process for diagnosing and fixing a slow query. Covers finding the problem query, reading the execution plan, diagnosing root causes, and validating fixes. For plan regression tracking and forced-plan management, see [[Query-Store|Query Store]].

---

## Step 1: Find the Problem Query

### Query Store — Best for Repeated Issues and Regressions

Query Store captures historical execution data and survives plan cache flushes. Use it first when a query degrades over time or after a code deploy.

```sql
SET NOCOUNT ON;

SELECT TOP 20
    [qsq].[query_id],
    [qsqt].[query_sql_text],
    [qsp].[plan_id],
    [qsrs].[count_executions],
    [qsrs].[avg_duration]       / 1000  AS avg_ms,
    [qsrs].[max_duration]       / 1000  AS max_ms,
    [qsrs].[avg_logical_io_reads]       AS avg_logical_reads,
    [qsrs].[avg_cpu_time]       / 1000  AS avg_cpu_ms
FROM [sys].[query_store_query]              AS qsq
JOIN [sys].[query_store_query_text]         AS qsqt
    ON qsq.[query_text_id] = qsqt.[query_text_id]
JOIN [sys].[query_store_plan]               AS qsp
    ON qsq.[query_id] = qsp.[query_id]
JOIN [sys].[query_store_runtime_stats]      AS qsrs
    ON qsp.[plan_id] = qsrs.[plan_id]
WHERE [qsrs].[last_execution_time] >= DATEADD(HOUR, -24, GETUTCDATE())
ORDER BY [qsrs].[avg_duration] DESC;
```

### Plan Cache — Good for Queries Currently in Cache

```sql
-- Top queries by total CPU
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'cpu';

-- Top queries by total reads
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'reads';

-- Top queries by average duration
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'duration';
```

### Real-Time — Query Currently Running Slow

```sql
EXEC [master].[dbo].[sp_WhoIsActive] @get_plans = 1;
```

---

## Step 2: Get the Execution Plan

**Estimated plan** — what the optimizer thinks will happen, without executing the query. Use it to check index usage and operator choices before committing to a run.

**Actual plan** — what actually happened. Captures real row counts at each operator, which is the primary indicator of statistics problems or parameter sniffing. Always prefer the actual plan when diagnosing a live issue.

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Paste the query here

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

For the plan of a currently-running query without re-executing it (SQL Server 2019+):

```sql
SET NOCOUNT ON;

SELECT
    [s].[session_id],
    [r].[start_time],
    [p].[query_plan]
FROM [sys].[dm_exec_requests]  AS r
JOIN [sys].[dm_exec_sessions]  AS s
    ON r.[session_id] = s.[session_id]
OUTER APPLY [sys].[dm_exec_query_plan_stats](r.[plan_handle]) AS p
WHERE [s].[is_user_process] = 1
  AND [s].[session_id] = <target_session_id>;
```

---

## Step 3: Read the Execution Plan

- Plans execute right-to-left, top-to-bottom in SSMS graphical view.
- Arrow thickness represents row count. A thin arrow into an expensive operator means the optimizer was surprised by actual volume.
- **Estimated vs actual rows discrepancy of 10x or more** is the primary signal for stale statistics or parameter sniffing.
- A yellow warning triangle always warrants investigation — it flags implicit conversions, memory spills, or statistics warnings.

### Operator Reference

| Operator | What It Means | What to Look For |
|---|---|---|
| Index Seek | Uses the index B-tree to locate specific rows | Good — the target for most WHERE lookups |
| Index Scan | Reads every row in the index | Flag for large tables |
| Key Lookup | Fetches columns missing from the nonclustered index | One per row — expensive at scale; fix with INCLUDE columns |
| Hash Match | Builds an in-memory hash table | Memory-intensive; often appears when statistics are wrong |
| Nested Loop | For each outer row, seeks into inner input | Degrades when the outer side is large |
| Merge Join | Joins two pre-sorted inputs | Efficient; requires sorted input |
| Sort | Sorts rows in memory, spilling to TempDB if grant is insufficient | Look for a covering index that satisfies the ORDER BY |
| Spill to TempDB | Sort or Hash Match overflowed memory grant | Fix with statistics update, query rewrite, or MIN_GRANT_PERCENT hint |

---

## Step 4: Diagnose Root Cause

### Missing Index

Plan shows an Index Scan where a Seek would suffice, or a Key Lookup for frequently-queried columns.

```sql
SET NOCOUNT ON;

SELECT TOP 20
    [mid].[statement]                                                                               AS TableName,
    [mid].[equality_columns],
    [mid].[inequality_columns],
    [mid].[included_columns],
    [migs].[user_seeks],
    [migs].[avg_total_user_cost] * [migs].[avg_user_impact] * ([migs].[user_seeks] + [migs].[user_scans])
                                                                                                    AS ImpactScore
FROM [sys].[dm_db_missing_index_details]        AS mid
JOIN [sys].[dm_db_missing_index_groups]         AS mig
    ON mid.[index_handle] = mig.[index_handle]
JOIN [sys].[dm_db_missing_index_group_stats]    AS migs
    ON mig.[index_group_handle] = migs.[group_handle]
WHERE [mid].[database_id] = DB_ID()
ORDER BY ImpactScore DESC;
```

Missing index suggestions are a starting point, not a prescription. Always evaluate against existing indexes — duplicating or near-duplicating one wastes write overhead.

### Stale Statistics

Estimated rows differ greatly from actual rows. The optimizer built the wrong plan because it believed there were far fewer (or more) rows than reality.

```sql
SET NOCOUNT ON;

SELECT
    [s].[name]          AS StatisticName,
    [sp].[last_updated],
    [sp].[rows],
    [sp].[rows_sampled],
    [sp].[modification_counter]
FROM [sys].[stats]      AS s
CROSS APPLY [sys].[dm_db_stats_properties]([s].[object_id], [s].[stats_id]) AS sp
WHERE [s].[object_id] = OBJECT_ID(N'dbo.YourTable')
ORDER BY [sp].[last_updated];
```

Fix: `UPDATE STATISTICS` or run Ola Hallengren `StatisticsOptimize`. See [[Statistics-Management|Statistics Management]] for the full remediation workflow.

### Parameter Sniffing

The plan was compiled for one parameter value and is being reused for very different values. Symptoms: the query runs fast sometimes and slow other times with no code change.

Diagnose by running the query with `OPTION (OPTIMIZE FOR UNKNOWN)` and comparing the plan against the cached plan. If the plan shape changes significantly, sniffing is the cause.

Fix options in order of preference:

1. `OPTION (OPTIMIZE FOR UNKNOWN)` — uses the column's statistical average instead of the sniffed value. Low overhead; good default.
2. `OPTION (RECOMPILE)` — recompiles every execution. Reserve for infrequent or highly variable queries.
3. Query Store forced plan — force the last known good plan while a permanent fix is developed. See [[Query-Store|Query Store]].
4. PSPO (SQL Server 2022+ at compat level 160) — the engine may generate multiple plan variants automatically.

---

## Step 5: Apply the Fix

### Adding a Covering Index

```sql
-- Before: index on CustomerID only; query also needs OrderDate and Status
-- Plan shows: Index Seek + Key Lookup per row

-- After: INCLUDE columns cover the query without a lookup
CREATE NONCLUSTERED INDEX [IX_Order_CustomerID_Covering]
ON [dbo].[Order] ([CustomerID])
INCLUDE ([OrderDate], [Status], [TotalAmount]);
```

### Updating Statistics

```sql
UPDATE STATISTICS [dbo].[Order] WITH FULLSCAN;
```

### Forcing a Good Plan via Query Store

```sql
EXEC [sys].[sp_query_store_force_plan]
    @query_id   = <query_id>,
    @plan_id    = <good_plan_id>;
```

---

## Step 6: Validate the Fix

Compare `STATISTICS IO` output before and after. Logical reads reduction is the real indicator.

```
-- Before: Table 'Order'. Scan count 1, logical reads 42381
-- After:  Table 'Order'. Scan count 1, logical reads 8
```

For Query Store environments, compare `avg_duration` from `[sys].[query_store_runtime_stats]` filtered to the same `query_id` across the relevant time windows.

---

## Common Anti-Patterns

| Anti-Pattern | Why It's Slow | Fix |
|---|---|---|
| `WHERE YEAR([OrderDate]) = 2025` | Function prevents index seek; scans entire index | Rewrite: `WHERE [OrderDate] >= '2025-01-01' AND [OrderDate] < '2026-01-01'` |
| `WHERE [CustomerCode] = @nvarcharParam` (column is VARCHAR) | Implicit conversion causes full scan | Match parameter type to column type |
| `WHERE [Name] LIKE '%Smith'` | Leading wildcard; cannot use an index | Evaluate full-text search |
| `NOLOCK` on every query | Dirty reads and phantom reads produce wrong results | Enable RCSI at the database level instead |
| Scalar UDF on every row | Row-by-row execution; blocks parallelism | Rewrite as inline TVF (or use UDF inlining at compat 150+) |
| `SELECT *` in production code | Fetches unnecessary columns; breaks on schema changes | Always list columns explicitly |

---

## Related Documents

- [[Query-Store|Query Store]] — plan regression tracking and forced plans
- [[Statistics-Management|Statistics Management]] — stale statistics remediation
- [[Deadlock-Analysis|Deadlock Analysis]] — blocking and deadlock patterns
- [[../Performance/Performance-Practices|Performance Practices]] — index analysis
- [[Operations|Back to Operations]]
