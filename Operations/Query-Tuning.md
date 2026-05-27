# Query Tuning Methodology

## Purpose

A systematic process for diagnosing and fixing a slow query. Covers finding the problem query,
reading the execution plan, identifying root causes, and applying targeted fixes. This document
is not a replacement for Query Store — see [Query-Store.md](Query-Store.md) for plan regression
tracking and forced-plan management. This document covers the diagnostic and fix methodology.

---

## Step 1: Find the Problem Query

Three sources, ranked by usefulness:

### 1. Query Store — Best for Repeated Issues and Regressions

Query Store captures historical execution data and survives plan cache flushes. Use it first
when a query degrades over time or after a code deploy.

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

### 2. Plan Cache — Good for Queries Currently in Cache

Use [sp_BlitzCache](https://github.com/BrentOzarULTD/SQL-Server-First-Responder-Kit) from the
First Responder Kit. It surfaces the worst offenders across several dimensions and annotates
common problems directly in the output.

```sql
-- Top queries by total CPU
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'cpu';

-- Top queries by total reads
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'reads';

-- Top queries by average duration
EXEC [master].[dbo].[sp_BlitzCache] @SortOrder = 'duration';
```

### 3. Real-Time — Query Currently Running Slow

Use [sp_WhoIsActive](http://whoisactive.com) to capture what is executing right now. The
`@get_plans = 1` parameter includes the execution plan for each active request.

```sql
EXEC [master].[dbo].[sp_WhoIsActive] @get_plans = 1;
```

---

## Step 2: Get the Execution Plan

Two plan types matter:

**Estimated plan** — what the optimizer thinks will happen, produced without executing the query.
Use it to check index usage, operator choices, and cost estimates before committing to a run.

**Actual plan** — what actually happened during execution. Captures the real row counts at each
operator, which is the primary indicator of statistics problems or parameter sniffing. Always
prefer the actual plan when diagnosing a live issue.

To capture IO and time stats alongside the actual plan:

```sql
SET STATISTICS IO ON;
SET STATISTICS TIME ON;

-- Paste the query here

SET STATISTICS IO OFF;
SET STATISTICS TIME OFF;
```

For plans of queries that are currently running without executing the query again (SQL Server 2019+):

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

Key principles:

- Plans execute right-to-left, top-to-bottom in the SSMS graphical view.
- Arrow thickness between operators represents the relative row count flowing through. A thin
  arrow leading into an expensive operator is a sign the optimizer was surprised by actual volume.
- **Estimated vs actual rows**: a discrepancy of 10x or more is the primary signal for stale
  statistics or parameter sniffing. It means the optimizer built the plan for a different data
  distribution than it encountered at runtime.
- Operator cost % is each operator's share of total estimated plan cost. Start investigation with
  the highest-cost operators.
- A yellow warning triangle on an operator always warrants investigation — it flags implicit
  conversions, memory spills, or statistics warnings.

### Operator Reference

| Operator | What It Means | What to Look For |
|---|---|---|
| Index Seek | Uses the index B-tree to locate specific rows | Good — the target for most WHERE clause lookups |
| Index Scan | Reads every row in the index | May be appropriate for small tables; flag for large tables |
| Key Lookup | Fetches columns missing from the nonclustered index from the clustered index | One lookup per row — becomes expensive at scale; fix with INCLUDE columns |
| Hash Match | Builds an in-memory hash table to join or aggregate | Often appears when statistics are wrong or joins are large; memory-intensive |
| Nested Loop | For each row in the outer input, seeks into the inner input | Efficient when the outer input is small; degrades when the outer side is large |
| Merge Join | Joins two pre-sorted inputs | Efficient; requires sorted input or a covering index in the right order |
| Sort | Sorts rows in memory, spilling to TempDB if the grant is insufficient | Expensive; look for a covering index whose column order satisfies the ORDER BY |
| Spill to TempDB | Sort or Hash Match couldn't fit within the memory grant | Fix with a statistics update (so the grant is sized correctly), query rewrite, or MIN_GRANT_PERCENT hint |

---

## Step 4: Diagnose Root Cause

### 1. Missing Index

The plan shows an Index Scan where a Seek would suffice, or a Key Lookup for columns that are
frequently queried. Both are flags that a covering index is absent.

Check the missing index DMVs for the current database:

```sql
SET NOCOUNT ON;

SELECT TOP 20
    [mid].[statement]                                       AS TableName,
    [mid].[equality_columns],
    [mid].[inequality_columns],
    [mid].[included_columns],
    [migs].[unique_compiles],
    [migs].[user_seeks],
    [migs].[avg_total_user_cost] * [migs].[avg_user_impact] * ([migs].[user_seeks] + [migs].[user_scans])
                                                            AS ImpactScore
FROM [sys].[dm_db_missing_index_details]    AS mid
JOIN [sys].[dm_db_missing_index_groups]     AS mig
    ON mid.[index_handle] = mig.[index_handle]
JOIN [sys].[dm_db_missing_index_group_stats] AS migs
    ON mig.[index_group_handle] = migs.[group_handle]
WHERE [mid].[database_id] = DB_ID()
ORDER BY ImpactScore DESC;
```

Missing index suggestions are a starting point, not a prescription. Always evaluate a suggestion
against existing indexes — duplicating or near-duplicating an index wastes write overhead.
Use `sp_BlitzIndex` for a fuller picture of index usage and redundancy.

### 2. Stale Statistics / Row Count Mismatch

Estimated rows in the plan differ greatly from actual rows. The optimizer built the wrong plan
because it believed there were far fewer (or more) rows than reality.

Check statistics age and modification count for the table in question:

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

Fix: `UPDATE STATISTICS` or run Ola Hallengren `StatisticsOptimize`. See
[Statistics-Management.md](../Standards/Statistics-Management.md) for the full remediation
workflow.

### 3. Parameter Sniffing

The plan was compiled for one parameter value and is being reused for very different values.
Symptoms: the query runs fast sometimes and slow other times with no code change; actual vs
estimated rows mismatch correlates with which parameter value was sniffed at compile time.

Diagnose by running the query with `OPTION (OPTIMIZE FOR UNKNOWN)` and comparing the plan and
duration against the cached plan. If the plan shape or row estimates change significantly, sniffing
is the cause.

Fix options, in order of preference:

1. `OPTION (OPTIMIZE FOR UNKNOWN)` — instructs the optimizer to use the column's statistical
   average rather than the sniffed value. Low overhead; good default starting point.
2. `OPTION (RECOMPILE)` — recompiles on every execution using the current parameter values.
   Eliminates stale sniffing but adds per-execution compile cost. Reserve for infrequent or
   highly variable queries.
3. Query Store forced plan — force the last known good plan while a permanent fix is developed.
   See [Query-Store.md](Query-Store.md).
4. PSPO (Parameter Sensitive Plan Optimization, SQL Server 2022+, compat level 160) — the engine
   may generate multiple plan variants for the same query automatically, resolving sniffing without
   hints.

---

## Step 5: Apply the Fix

### Adding a Covering Index (Eliminates Key Lookup)

```sql
-- Before: index on CustomerID only; query also needs OrderDate and Status
-- Plan shows: Index Seek + Key Lookup per row — expensive at scale

-- After: add INCLUDE columns to cover the query without a lookup
CREATE NONCLUSTERED INDEX [IX_Order_CustomerID_Covering]
ON [dbo].[Order] ([CustomerID])
INCLUDE ([OrderDate], [Status], [TotalAmount]);
```

### Updating Statistics (Fixes Row Count Mismatch)

```sql
UPDATE STATISTICS [dbo].[Order] WITH FULLSCAN;
```

### Forcing a Good Plan via Query Store

```sql
-- Identify the plan_id of the good plan from Query Store first, then force it
EXEC [sys].[sp_query_store_force_plan]
    @query_id   = <query_id>,
    @plan_id    = <good_plan_id>;
```

---

## Step 6: Validate the Fix

Compare STATISTICS IO output before and after the change. The key metric is logical reads — a
reduction there is a real improvement regardless of wall-clock time variance.

```
-- Before: Table 'Order'. Scan count 1, logical reads 42381
-- After:  Table 'Order'. Scan count 1, logical reads 8
```

For Query Store environments, compare `avg_duration` before and after from
`[sys].[query_store_runtime_stats]`, filtered to the same `query_id` and the relevant time
windows. A reduction in both average and max duration confirms the fix held across executions.

---

## Common Anti-Patterns

| Anti-Pattern | Why It's Slow | Fix |
|---|---|---|
| Function on an indexed column in WHERE: `WHERE YEAR([OrderDate]) = 2025` | Prevents index seek; scans the entire index | Rewrite as range: `WHERE [OrderDate] >= '2025-01-01' AND [OrderDate] < '2026-01-01'` |
| Implicit type conversion: `WHERE [CustomerCode] = @nvarcharParam` when the column is VARCHAR | Engine converts every row before comparing; full scan | Match parameter type to column type, or add an explicit CAST on the parameter |
| Leading wildcard: `WHERE [Name] LIKE '%Smith'` | Cannot use an index; full scan always | Evaluate full-text search if this access pattern is required |
| NOLOCK everywhere | Dirty reads and phantom reads produce wrong results | Use RCSI (`READ_COMMITTED_SNAPSHOT`) at the database level instead |
| Scalar UDF on every row | Row-by-row execution, blocks parallelism | Rewrite as an inline TVF, or rely on scalar UDF inlining (SQL Server 2019+ at compat 150) |
| `SELECT *` in production code | Fetches unnecessary columns; breaks silently on schema changes | Always list columns explicitly |

---

## Related Documents

- [Query-Store.md](Query-Store.md) — plan regression tracking and forced plans
- [../Standards/Statistics-Management.md](../Standards/Statistics-Management.md) — stale statistics remediation
- [Deadlock-Analysis.md](Deadlock-Analysis.md) — blocking and deadlock patterns
- [../Performance/PerformancePractices.md](../Performance/PerformancePractices.md) — index analysis
