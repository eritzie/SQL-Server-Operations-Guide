# SQL Server Development and Configuration Standards

> **Environment context:** These standards were developed for SQL Server environments supporting both OLTP and reporting workloads. They cover database design, T-SQL development practices, and instance configuration baselines. For security-specific guidance, see [Security Practices](Security.md). For performance tuning, see [Performance Practices](PerformancePractices.md).

## Table of Contents

- [Instance Configuration Baseline](#instance-configuration-baseline)
- [Database Design Standards](#database-design-standards)
- [T-SQL Development Practices](#t-sql-development-practices)
- [Stored Procedures over Inline Queries](#stored-procedures-over-inline-queries)
- [Indexing Guidelines](#indexing-guidelines)
- [Reporting Database Design](#reporting-database-design)
- [Configuration Audit](#configuration-audit)

## Instance Configuration Baseline

Every SQL Server instance should have these settings verified after installation. They're covered in detail in the referenced docs — this section serves as a quick-reference checklist.

| Setting | Recommended Value | Reference |
|---|---|---|
| Max Server Memory | ~85% of total RAM (more if SSRS/SSIS coexist) | [Performance Practices](PerformancePractices.md#max-server-memory) |
| MAXDOP | Based on NUMA topology | [Performance Practices](PerformancePractices.md#max-degree-of-parallelism-maxdop) |
| Cost Threshold for Parallelism | 50 (starting point) | [Performance Practices](PerformancePractices.md#cost-threshold-for-parallelism) |
| Instant File Initialization | Enabled | [Performance Practices](PerformancePractices.md#instant-file-initialization) |
| SA Account | Renamed and disabled | [Security Practices](Security.md#sa-account-hardening) |
| xp_cmdshell | Disabled | [Security Practices](Security.md#surface-area-reduction) |
| Data/Log/TempDB disk block size | 64KB | [Performance Practices](PerformancePractices.md#disk-configurations) |
| Backup compression default | Enabled | See below |
| Optimize for ad hoc workloads | Enabled | See below |
| Remote admin connections (DAC) | Enabled | See below |

Settings not covered elsewhere:

```powershell
# Enable backup compression by default (reduces backup size 60-80%, minimal CPU overhead on modern hardware)
Set-DbaSpConfigure -SqlInstance SqlServer01 -Name DefaultBackupCompression -Value 1

# Enable optimize for ad hoc workloads (prevents single-use plans from bloating the plan cache)
Set-DbaSpConfigure -SqlInstance SqlServer01 -Name OptimizeForAdHocWorkloads -Value 1

# Enable remote DAC (allows emergency connections when the instance is unresponsive)
Set-DbaSpConfigure -SqlInstance SqlServer01 -Name RemoteDacConnectionsEnabled -Value 1
```

## Database Design Standards

### Normalization for OLTP

OLTP databases should be normalized (3NF as a baseline). Smaller, well-structured tables with clear relationships perform better for transactional workloads than wide denormalized tables. Normalization reduces data redundancy, simplifies update logic, and keeps indexes narrow and efficient.

That said, normalization is a guideline, not a religion. There are cases where a controlled denormalization (e.g., storing a computed total on an order header to avoid a SUM on every read) is the right tradeoff. Document the decision and the reasoning when you deviate.

### Primary Key Selection

Use narrow data types for primary keys. Integer types (`INT`, `BIGINT`) are preferred because they're compact, sort efficiently, and make good clustered index keys. SQL Server processes narrow keys faster in joins, lookups, and index traversals.

Avoid wide or variable-length primary keys (`VARCHAR(50)`, `NVARCHAR`, composite keys with many columns) on high-volume tables. Every nonclustered index on the table carries a copy of the clustered index key — a wide key multiplies storage and I/O across every index.

`UNIQUEIDENTIFIER` (GUID) primary keys are common in distributed systems but perform poorly as clustered index keys due to their random nature, which causes excessive page splits. If GUIDs are required, use `NEWSEQUENTIALID()` instead of `NEWID()` for the clustered index, or use a separate `INT IDENTITY` as the clustered key with the GUID as an alternate unique index.

### Image and File Storage

Store file paths or URLs in the database rather than the files themselves. Binary data in database columns increases database size, backup size, backup duration, and memory pressure. The database becomes a bottleneck for what is fundamentally a file storage problem.

If binary storage in SQL Server is required, use FILESTREAM or FileTable for files over 1MB. For smaller files (thumbnails, icons), `VARBINARY(MAX)` is acceptable but should be isolated in a separate filegroup so it doesn't fragment the primary data filegroup.

### Recovery Model

| Environment | Recovery Model | Rationale |
|---|---|---|
| Production (OLTP) | Full | Point-in-time recovery, log shipping support |
| Production (Reporting/DW) | Simple or Bulk-Logged | Depends on RPO requirements and ETL patterns |
| Test | Simple | No point-in-time recovery needed |
| Development | Simple | No point-in-time recovery needed |

```powershell
# Audit recovery models across all instances
Get-DbaDbRecoveryModel -SqlInstance SqlServer01 -ExcludeSystemDb |
    Select-Object Name, RecoveryModel |
    Sort-Object RecoveryModel, Name
```

## T-SQL Development Practices

### Use Explicit Column Lists

Always specify column names in SELECT statements. `SELECT *` forces SQL Server to resolve all columns at execution time, pulls unnecessary data across the network, and breaks application code when table schemas change.

```sql
-- Avoid
SELECT * FROM dbo.Orders;

-- Prefer
SELECT OrderId, CustomerId, OrderDate, TotalAmount
FROM dbo.Orders;
```

This also applies to `INSERT` statements — always include the column list so the statement doesn't break when columns are added to the table.

### JOIN Selection

JOINs are generally the preferred approach for combining data from multiple tables. The query optimizer handles JOINs well and can choose from multiple physical join strategies (nested loop, hash, merge) based on data distribution and available indexes.

Subqueries and CTEs are not inherently slower — the optimizer often produces identical plans for a correlated subquery and an equivalent JOIN. Choose whichever makes the intent clearer. Where subqueries and CTEs genuinely underperform is when they force the optimizer into a less efficient strategy, which typically happens with:

- Correlated subqueries executed row-by-row against large tables with no supporting index.
- CTEs referenced multiple times in the same query (CTEs are not materialized — each reference re-executes the definition).

CROSS JOINs have a legitimate place in query design. They're the correct tool for generating grid/matrix results — for example, crossing a date dimension with a product dimension to produce a row for every combination, then LEFT JOINing to fact data to fill in actuals with zeros for gaps. The key is to keep the CROSS JOIN inputs small and intentional.

### Avoid Implicit Conversions

Implicit type conversions in WHERE clauses and JOIN predicates prevent index seeks and cause full scans. The most common offender is comparing a `VARCHAR` column to an `NVARCHAR` parameter (or vice versa) — SQL Server must convert every row to match.

```sql
-- Implicit conversion (index scan, slow)
-- @param is NVARCHAR, column is VARCHAR
SELECT * FROM dbo.Customers WHERE CustomerCode = @param;

-- Explicit match (index seek, fast)
SELECT * FROM dbo.Customers WHERE CustomerCode = CAST(@param AS VARCHAR(20));
```

Check for implicit conversion warnings in execution plans — they appear as yellow warning triangles on the affected operators.

### Parameter Sniffing Awareness

Stored procedures compile their execution plan based on the parameter values provided on the first execution. If the first call uses an atypical value (e.g., a date range that returns 1 row when the typical call returns 100,000), the cached plan will be wrong for subsequent calls.

Mitigation strategies, in order of preference:

1. **`OPTIMIZE FOR UNKNOWN`** — tells the optimizer to use average statistics rather than the sniffed value.
2. **`OPTION (RECOMPILE)`** — forces a fresh plan on every execution. Use sparingly on high-frequency queries due to compilation overhead.
3. **Local variables** — assigning parameters to local variables prevents sniffing but also prevents the optimizer from using statistics effectively. Use as a last resort.

```sql
-- Option 1: Optimize for unknown
CREATE PROCEDURE dbo.usp_GetOrders
    @StartDate DATE,
    @EndDate DATE
AS
BEGIN
    SELECT OrderId, CustomerId, OrderDate, TotalAmount
    FROM dbo.Orders
    WHERE OrderDate BETWEEN @StartDate AND @EndDate
    OPTION (OPTIMIZE FOR UNKNOWN);
END;
```

### Naming Conventions

Consistent naming makes code easier to read, maintain, and search. These conventions are recommendations — the most important thing is consistency within an environment.

| Object | Convention | Example |
|---|---|---|
| Tables | PascalCase, singular noun | `Customer`, `OrderDetail` |
| Stored procedures | `usp_` prefix, PascalCase | `usp_GetCustomerOrders` |
| Functions | `ufn_` prefix, PascalCase | `ufn_CalculateTax` |
| Views | `vw_` prefix, PascalCase | `vw_ActiveCustomers` |
| Indexes | `IX_TableName_Column(s)` | `IX_Orders_CustomerId` |
| Primary keys | `PK_TableName` | `PK_Customer` |
| Foreign keys | `FK_ChildTable_ParentTable` | `FK_OrderDetail_Order` |
| Default constraints | `DF_TableName_Column` | `DF_Customer_CreatedDate` |

## Stored Procedures over Inline Queries

Applications should use stored procedures rather than inline SQL queries. The advantages compound:

**Security:** Granting EXECUTE on stored procedures means the application account never needs direct table access. This is a smaller attack surface — even if the account is compromised, the attacker can only call existing procedures, not write arbitrary queries. It also eliminates SQL injection risk if the procedures use parameterized queries internally.

**Performance:** Stored procedures have cached execution plans that are reused across calls. While parameterized inline queries also benefit from plan caching, ad hoc queries with concatenated strings do not — each unique string generates a new plan and pollutes the plan cache.

**Maintainability:** Business logic changes can be deployed by altering a stored procedure without redeploying the application. This is especially valuable in environments where application deployments require change control windows but database changes can be deployed independently.

**Troubleshooting:** When a performance issue appears in sp_WhoIsActive or the plan cache, a stored procedure name is immediately identifiable. An inline query is an anonymous text blob that requires tracing back to the application code.

## Indexing Guidelines

Indexes are covered in depth in [Performance Practices](PerformancePractices.md#missing-indexes), but these design-time guidelines are worth calling out separately.

**Favor integer columns for indexed columns.** Integer comparisons are faster than string comparisons. If you're filtering or joining on a string column frequently, consider whether a surrogate integer key would be more efficient.

**Keep indexes narrow.** An index with 6 columns is wide — every level of the B-tree carries all 6 values. A narrow index on the most selective column with INCLUDEd columns for coverage is usually a better design.

**Don't over-index.** Each index must be maintained on every INSERT, UPDATE, and DELETE. As a guideline, keep the total index count per table between 5 and 10 for OLTP workloads. Reporting tables can tolerate more since they're write-infrequent.

**Design indexes for your queries, not for your tables.** Review the actual query patterns (sp_BlitzIndex, Query Store, plan cache analysis) and build indexes that support them. Guessing at indexes based on table structure alone leads to bloat.

```powershell
# Identify unused indexes (candidates for removal)
Find-DbaDbDuplicateIndex -SqlInstance SqlServer01 | Out-GridView

# Analyze index usage across all databases
Invoke-DbaQuery -SqlInstance SqlServer01 -Query "EXEC sp_BlitzIndex @GetAllDatabases = 1;" |
    Out-GridView
```

## Reporting Database Design

Reporting workloads have fundamentally different access patterns than OLTP. What makes a good OLTP schema (normalized, narrow tables, minimal indexes) often makes a terrible reporting schema (many joins, slow aggregations, index-starved scans).

**Denormalize for reporting.** Use ETL processes (SSIS, stored procedures, or dbatools-driven scripts) to transform and load data from the normalized OLTP schema into a denormalized reporting schema. Star or snowflake schemas with fact and dimension tables are the standard pattern for analytical workloads.

**Separate the reporting workload.** Run reports against a dedicated reporting database or a read-only secondary (log shipping standby, AG readable secondary) rather than against the production OLTP database. This eliminates reader/writer contention and allows you to optimize indexes and statistics for analytical queries without impacting transactional performance.

**Pre-aggregate where possible.** If a report summarizes millions of rows into a handful of totals every time it runs, consider building a summary table that's refreshed on a schedule. The report reads from the summary table in milliseconds instead of scanning the fact table for minutes.

## Configuration Audit

Run this periodically to catch configuration drift across instances.

```powershell
# Compare sp_configure settings across two instances
$primary = Get-DbaSpConfigure -SqlInstance SqlServer01
$secondary = Get-DbaSpConfigure -SqlInstance SqlServer02

Compare-Object -ReferenceObject $primary -DifferenceObject $secondary `
    -Property Name, ConfiguredValue -PassThru |
    Select-Object Name, ConfiguredValue, SideIndicator |
    Out-GridView

# Full instance configuration audit
$instances = @('SqlServer01', 'SqlServer02', 'SqlServer03')
$instances | ForEach-Object {
    [PSCustomObject]@{
        Instance = $_
        MaxMemory = (Get-DbaMaxMemory -SqlInstance $_).MaxValue
        MaxDop = (Get-DbaSpConfigure -SqlInstance $_ -Name MaxDegreeOfParallelism).ConfiguredValue
        CTFP = (Get-DbaSpConfigure -SqlInstance $_ -Name CostThresholdForParallelism).ConfiguredValue
        BackupCompression = (Get-DbaSpConfigure -SqlInstance $_ -Name DefaultBackupCompression).ConfiguredValue
    }
} | Format-Table -AutoSize
```