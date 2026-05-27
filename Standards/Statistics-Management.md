# Statistics Management

## Purpose

Statistics are histograms that tell the query optimizer how data is distributed in a table or
index. The optimizer uses them to estimate row counts at each plan operator, and those estimates
drive every plan choice — join order, join type, index selection, memory grant size. Bad
statistics produce bad plans. Auto-update covers most cases; this document covers the scenarios
where it fails and how to intervene.

---

## How Auto-Update Works

SQL Server automatically updates statistics when a threshold of row modifications is exceeded:

- **SQL Server 2014 and earlier**: 20% of table rows + 500 rows modified.
- **SQL Server 2016+ at compat level 130+**: dynamic threshold — approximately
  `SQRT(1000 * table_rows)`. This is much lower for large tables.

The dynamic threshold is the primary reason to be on compatibility level 130 or higher. At the
old 20% threshold, a 50-million-row table would need 10 million row changes before auto-update
fires. At the dynamic threshold, approximately 223,000 changes trigger it — an order of magnitude
more sensitive.

---

## AUTO_UPDATE_STATISTICS_ASYNC

By default, statistics updates are synchronous: the query that triggered the update waits for
the update to complete before the query executes. Setting ASYNC to ON allows the query to run
with the current (stale) stats while the update happens in the background.

Trade-off: one query execution uses stale statistics, but it does not pay the update latency.
For high-concurrency OLTP, async is generally preferable. Do not enable it during an active
incident — the first query after the update fires still uses stale stats, delaying relief.

```sql
ALTER DATABASE [YourDatabase] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
```

---

## When Auto-Update Fails

### 1. After a Large Data Load

Inserting 500,000 rows into a 10-million-row table represents 5% of rows — below the legacy 20%
threshold and potentially below the dynamic threshold depending on timing. The newly loaded data's
distribution won't be reflected in the histogram until the threshold is crossed by subsequent
modifications. Manual update immediately after ETL loads is the correct pattern.

### 2. Skewed Data Distributions

A statistics histogram has at most 200 steps. For highly skewed data — for example, 90% of orders
with `Status = 'Complete'` and 1% with `Status = 'Pending'` — the histogram may not have enough
steps to accurately represent the rare values. The optimizer under-estimates rows for the rare
value and generates a plan suited for a small result set, which then scans far more rows than
expected. Filtered statistics solve this by building a dedicated histogram for the subset.

### 3. Ascending Key Problem

A column like `OrderDate` where new rows always have dates beyond the current histogram maximum.
The histogram has no step for future dates, so the optimizer estimates 1 row for any query
filtering on recent dates — regardless of how many rows actually exist. The resulting plan is
typically a Nested Loop against what the optimizer believes is a tiny range, when in fact it is
scanning thousands or millions of rows.

Fix: update statistics after bulk loads on tables with ascending key columns. SQL Server 2016+
with the new CE and dynamic threshold partially addresses this, but it does not eliminate it
for large tables between update cycles.

### 4. Temp Tables and Table Variables

Temp tables get auto-created statistics when queries reference them, but they do not benefit from
background auto-update within a session's scope. Table variables have no statistics at all — the
optimizer always assumes 1 row. For temp tables used in complex multi-step procedures, create and
update statistics explicitly after loading data and before executing joins.

---

## Detecting Stale Statistics

```sql
SET NOCOUNT ON;

-- Statistics age, sample rate, and modification count for all user tables
SELECT
    [obj].[name]                        AS TableName,
    [s].[name]                          AS StatisticName,
    [s].[auto_created],
    [s].[user_created],
    [sp].[last_updated],
    [sp].[rows],
    [sp].[rows_sampled],
    CAST(100.0 * [sp].[rows_sampled] / NULLIF([sp].[rows], 0) AS decimal(5,1))
                                        AS SamplePct,
    [sp].[modification_counter]         AS RowChangesSinceLastUpdate
FROM [sys].[objects]    AS obj
JOIN [sys].[stats]      AS s
    ON obj.[object_id] = s.[object_id]
CROSS APPLY [sys].[dm_db_stats_properties](s.[object_id], s.[stats_id]) AS sp
WHERE [obj].[type] = 'U'
  AND [sp].[rows] > 0
ORDER BY [sp].[modification_counter] DESC;
```

High `modification_counter` values relative to `rows` indicate statistics that have not been
updated since many rows changed. A low `SamplePct` on a large table means the histogram may
not reflect outlier values — consider a FULLSCAN update.

To read the actual histogram for a specific statistic:

```sql
-- View the histogram steps: RANGE_HI_KEY, RANGE_ROWS, EQ_ROWS,
-- DISTINCT_RANGE_ROWS, AVG_RANGE_ROWS
DBCC SHOW_STATISTICS (N'dbo.Order', N'IX_Order_CustomerID') WITH HISTOGRAM;
```

Compare `EQ_ROWS` and `RANGE_ROWS` against what you know about the actual data distribution.
If the histogram shows 10 rows for a value you know has 50,000, that statistic is the cause of
the bad plan.

---

## Updating Statistics

Three levels of scope:

```sql
-- Update a specific statistic with a full table scan (most accurate)
UPDATE STATISTICS [dbo].[Order] [IX_Order_CustomerID] WITH FULLSCAN;

-- Update all statistics on a table
UPDATE STATISTICS [dbo].[Order] WITH FULLSCAN;

-- Update all statistics in the database using row-count sampling
-- (faster, but may miss outliers in skewed data — not a substitute for FULLSCAN on problem tables)
EXEC [sys].[sp_updatestats];
```

FULLSCAN reads every row and produces the most accurate histogram. The default sampled update
is faster but can miss low-frequency values in skewed distributions. Use FULLSCAN when diagnosing
an active query plan problem or on tables with known data skew.

### Ola Hallengren StatisticsOptimize (Preferred for Scheduled Maintenance)

```sql
EXEC [master].[dbo].[StatisticsOptimize]
    @Databases              = 'YourDatabase',
    @FragmentationLow       = NULL,
    @FragmentationMedium    = NULL,
    @FragmentationHigh      = NULL,
    @UpdateStatistics       = 'ALL',
    @OnlyModifiedStatistics = 'Y';
```

`@OnlyModifiedStatistics = 'Y'` skips statistics that haven't changed since the last update,
which keeps maintenance windows short. See
[Maintenance-Solution.md](../Operations/Maintenance-Solution.md) for the full Ola Hallengren setup and job
scheduling.

---

## Filtered Statistics

When a query consistently filters on a specific value and the global histogram doesn't represent
that subset accurately, a filtered statistic provides a dedicated histogram for that slice of data.

```sql
-- Filtered statistic covering only pending orders
CREATE STATISTICS [stat_Order_Pending]
ON [dbo].[Order] ([CustomerID], [OrderDate])
WHERE [Status] = 'Pending'
WITH FULLSCAN;
```

The optimizer will use the filtered statistic when the query's WHERE clause matches the filter
predicate. Update filtered statistics the same way as regular statistics:

```sql
UPDATE STATISTICS [dbo].[Order] [stat_Order_Pending] WITH FULLSCAN;
```

Filtered statistics are most valuable when the column has high cardinality relative to the rare
values you care about — a status column with one dominant value and several rare ones is the
classic case.

---

## Statistics on Temp Tables

Temp tables get auto-created statistics on first reference, but those statistics are not
automatically refreshed when the temp table is populated with new data. For temp tables
that participate in complex joins or filtering, update statistics explicitly after loading:

```sql
CREATE TABLE [#OrderStaging]
(
    [OrderID]       int         NOT NULL,
    [CustomerID]    int         NOT NULL,
    [OrderDate]     date        NOT NULL
);

-- ... populate the temp table ...

-- Update statistics before executing joins against this temp table
UPDATE STATISTICS [#OrderStaging] WITH FULLSCAN;
```

Table variables have no statistics at all. For any table variable used in joins, consider
converting to a temp table if row counts are non-trivial. The optimizer always assumes 1 row
for a table variable, which produces Nested Loop plans that fall apart at scale.

---

## Trace Flag 2371 (Legacy)

On SQL Server 2014 and earlier, Trace Flag 2371 enables the dynamic statistics threshold
(equivalent to the behavior built into compat level 130+). It is not needed on SQL Server 2016+
and has no effect there. Do not carry TF 2371 as a startup flag on modern instances — it adds
noise to diagnostic output without benefit.

---

## Statistics Maintenance Schedule

| Table Characteristic | Recommended Frequency | Method |
|---|---|---|
| High-volume OLTP tables (>1M rows, frequent writes) | Daily | Ola StatisticsOptimize, OnlyModified=Y |
| Data warehouse fact tables | After each ETL load | UPDATE STATISTICS FULLSCAN |
| Reference and lookup tables (infrequent changes) | Weekly | Ola StatisticsOptimize |
| Tables with ascending key columns (date, identity) | Daily or after large loads | UPDATE STATISTICS FULLSCAN |

---

## Related Documents

- [Maintenance-Solution.md](../Operations/Maintenance-Solution.md) — Ola Hallengren StatisticsOptimize setup and job scheduling
- [Query-Tuning.md](../Operations/Query-Tuning.md) — using statistics to diagnose query plan problems
- [Query-Store.md](../Operations/Query-Store.md) — feedback mechanisms that adapt to statistics quality
- [../Performance/PerformancePractices.md](../Performance/PerformancePractices.md) — index analysis
