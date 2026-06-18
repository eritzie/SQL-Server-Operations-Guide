# Statistics Management

## Purpose

Statistics are histograms that tell the query optimizer how data is distributed in a table or index. The optimizer uses them to estimate row counts at each plan operator, and those estimates drive every plan choice — join order, join type, index selection, memory grant size. Bad statistics produce bad plans. Auto-update covers most cases; this document covers the scenarios where it fails and how to intervene.

---

## How Auto-Update Works

SQL Server automatically updates statistics when a threshold of row modifications is exceeded:

- **SQL Server 2014 and earlier:** 20% of table rows + 500 rows modified.
- **SQL Server 2016+ at compat level 130+:** dynamic threshold — approximately `SQRT(1000 * table_rows)`.

The dynamic threshold is the primary reason to be on compatibility level 130 or higher. At the old 20% threshold, a 50-million-row table would need 10 million row changes before auto-update fires. At the dynamic threshold, approximately 223,000 changes trigger it — an order of magnitude more sensitive.

---

## AUTO_UPDATE_STATISTICS_ASYNC

By default, statistics updates are synchronous: the query that triggered the update waits for it to complete. Setting ASYNC to ON allows the query to run with current (stale) stats while the update happens in the background.

Trade-off: one query execution uses stale statistics, but it does not pay the update latency. For high-concurrency OLTP, async is generally preferable. Do not enable it during an active incident — the first query after the update fires still uses stale stats, delaying relief.

```sql
ALTER DATABASE [YourDatabase] SET AUTO_UPDATE_STATISTICS_ASYNC ON;
```

---

## When Auto-Update Fails

### 1. After a Large Data Load

Inserting 500,000 rows into a 10-million-row table represents 5% of rows — potentially below the dynamic threshold depending on timing. The newly loaded data's distribution won't be reflected until the threshold is crossed. Manual update immediately after ETL loads is the correct pattern.

### 2. Skewed Data Distributions

A statistics histogram has at most 200 steps. For highly skewed data — 90% of orders with `Status = 'Complete'` and 1% with `Status = 'Pending'` — the histogram may not have enough steps to accurately represent rare values. The optimizer under-estimates rows for the rare value and generates a plan suited for a small result set, which then scans far more rows than expected. Filtered statistics solve this by building a dedicated histogram for the subset.

### 3. Ascending Key Problem

A column like `OrderDate` where new rows always have dates beyond the current histogram maximum. The histogram has no step for future dates, so the optimizer estimates 1 row for any query filtering on recent dates. The resulting plan is typically a Nested Loop that falls apart at scale.

Fix: update statistics after bulk loads on tables with ascending key columns. SQL Server 2016+ with the dynamic threshold partially addresses this, but does not eliminate it for large tables between update cycles.

### 4. Temp Tables and Table Variables

Temp tables get auto-created statistics on first reference but do not benefit from background auto-update within a session's scope. Table variables have no statistics at all — the optimizer always assumes 1 row. For temp tables used in complex multi-step procedures, update statistics explicitly after loading and before executing joins.

---

## Detecting Stale Statistics

```sql
SET NOCOUNT ON;

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

High `modification_counter` relative to `rows` indicates statistics not updated since many rows changed. A low `SamplePct` on a large table means the histogram may not reflect outlier values — consider a FULLSCAN update.

To read the actual histogram for a specific statistic:

```sql
DBCC SHOW_STATISTICS (N'dbo.Order', N'IX_Order_CustomerID') WITH HISTOGRAM;
```

Compare `EQ_ROWS` and `RANGE_ROWS` against what you know about the actual data distribution.

---

## Updating Statistics

```sql
-- Update a specific statistic with a full table scan (most accurate)
UPDATE STATISTICS [dbo].[Order] [IX_Order_CustomerID] WITH FULLSCAN;

-- Update all statistics on a table
UPDATE STATISTICS [dbo].[Order] WITH FULLSCAN;

-- Update all statistics in the database using row-count sampling
-- (faster, but may miss outliers in skewed data)
EXEC [sys].[sp_updatestats];
```

FULLSCAN reads every row and produces the most accurate histogram. Use it when diagnosing an active query plan problem or on tables with known data skew. The default sampled update can miss low-frequency values in skewed distributions.

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

`@OnlyModifiedStatistics = 'Y'` skips statistics that haven't changed since the last update, keeping maintenance windows short. See [[Maintenance-Solution|Ola Hallengren Maintenance Solution]] for setup and job scheduling.

---

## Filtered Statistics

When a query consistently filters on a specific value and the global histogram doesn't represent that subset accurately, a filtered statistic provides a dedicated histogram for that slice:

```sql
-- Filtered statistic covering only pending orders
CREATE STATISTICS [stat_Order_Pending]
ON [dbo].[Order] ([CustomerID], [OrderDate])
WHERE [Status] = 'Pending'
WITH FULLSCAN;
```

The optimizer uses the filtered statistic when the query's WHERE clause matches the filter predicate. Update it the same way as regular statistics:

```sql
UPDATE STATISTICS [dbo].[Order] [stat_Order_Pending] WITH FULLSCAN;
```

---

## Statistics on Temp Tables

Update temp table statistics explicitly after loading, before executing joins:

```sql
CREATE TABLE [#OrderStaging]
(
    [OrderID]    int  NOT NULL,
    [CustomerID] int  NOT NULL,
    [OrderDate]  date NOT NULL
);

-- ... populate the temp table ...

UPDATE STATISTICS [#OrderStaging] WITH FULLSCAN;
```

Table variables have no statistics — the optimizer always assumes 1 row. For any table variable used in joins, convert to a temp table if row counts are non-trivial.

---

## Trace Flag 2371 (Legacy)

On SQL Server 2014 and earlier, Trace Flag 2371 enables the dynamic statistics threshold. It is not needed on SQL Server 2016+ and has no effect there. Do not carry TF 2371 as a startup flag on modern instances.

---

## Statistics Maintenance Schedule

| Table Characteristic | Recommended Frequency | Method |
|---|---|---|
| High-volume OLTP (> 1M rows, frequent writes) | Daily | Ola StatisticsOptimize, OnlyModified=Y |
| Data warehouse fact tables | After each ETL load | UPDATE STATISTICS FULLSCAN |
| Reference and lookup tables (infrequent changes) | Weekly | Ola StatisticsOptimize |
| Tables with ascending key columns | Daily or after large loads | UPDATE STATISTICS FULLSCAN |

---

## Related Documents

- [[Maintenance-Solution|Ola Hallengren Maintenance Solution]] — StatisticsOptimize setup and job scheduling
- [[Query-Tuning|Query Tuning]] — using statistics to diagnose query plan problems
- [[Query-Store|Query Store]] — feedback mechanisms that adapt to statistics quality
- [[../Performance/Performance-Practices|Performance Practices]] — index analysis
- [[Standards|Back to Standards]]
