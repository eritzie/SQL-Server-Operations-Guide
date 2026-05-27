# SQL Server 2022 Readiness Guide

## Purpose

Upgrade planning and feature awareness guide for environments running SQL Server 2019 that are evaluating or beginning a move to SQL Server 2022. SQL Server 2022 (compatibility level 160) introduces the most significant IQP improvements since SQL Server 2017, contained availability groups, ledger tables, and tighter Azure Arc integration. The TLS changes introduced here also foreshadow the breaking changes that become mandatory in SQL Server 2025.

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

SQL Server 2022 installs at compatibility level 160. The same discipline applies as any version upgrade: test at the new level before changing production databases.

Key behavior changes at level 160 vs. 150:

| Feature | Behavior Change |
|---|---|
| Parameter Sensitive Plan Optimization (PSPO) | Multiple plans per query for different parameter values — addresses parameter sniffing at the optimizer level |
| Degree of Parallelism (DOP) feedback | Automatically adjusts DOP per query based on observed execution history |
| Cardinality Estimation (CE) feedback | Adjusts CE model per query based on actual vs. estimated rows |
| Memory grant feedback persistence | Feedback survives plan cache clears via Query Store |

```sql
SET NOCOUNT ON;

-- Review databases not yet at level 160
SELECT
    [name],
    [compatibility_level],
    [recovery_model_desc]
FROM [sys].[databases]
WHERE [database_id] > 4
  AND [compatibility_level] < 160
ORDER BY [name];
```

### Connection String / TLS Review

SQL Server 2022 does not enforce encryption by default, but TLS 1.0 and 1.1 are deprecated. Begin the certificate and connection string audit now — it becomes a hard requirement in SQL Server 2025.

See [TLS Configuration](../Security/TLS-Configuration.md) for the full certificate setup procedure.

### Deprecated Features Audit

```sql
SET NOCOUNT ON;

SELECT
    [instance_name],
    [name],
    [cntr_value] AS usage_count
FROM [sys].[dm_os_performance_counters]
WHERE [object_name] LIKE '%Deprecated%'
  AND [cntr_value] > 0
ORDER BY [cntr_value] DESC;
```

---

## New Features Worth Enabling Post-Upgrade

### Parameter Sensitive Plan Optimization (PSPO)

PSPO is the most impactful IQP addition in SQL Server 2022. Queries that suffer from parameter sniffing — where one execution plan performs well for some parameter values but poorly for others — can now receive multiple plans per query, selected based on statistics at compile time.

PSPO activates automatically at compatibility level 160 for eligible queries. No configuration required. Monitor via Query Store:

```sql
SET NOCOUNT ON;

-- Queries with multiple plans (potential PSPO candidates or results)
SELECT
    qsq.[query_id],
    qsqt.[query_sql_text],
    COUNT(qsp.[plan_id])    AS plan_count,
    MAX(qsrs.[avg_duration]) / 1000 AS max_avg_ms
FROM [sys].[query_store_query]          AS qsq
JOIN [sys].[query_store_query_text]     AS qsqt
    ON qsq.[query_text_id] = qsqt.[query_text_id]
JOIN [sys].[query_store_plan]           AS qsp
    ON qsq.[query_id] = qsp.[query_id]
JOIN [sys].[query_store_runtime_stats]  AS qsrs
    ON qsp.[plan_id] = qsrs.[plan_id]
GROUP BY qsq.[query_id], qsqt.[query_sql_text]
HAVING COUNT(qsp.[plan_id]) > 1
ORDER BY max_avg_ms DESC;
```

### DOP and Memory Grant Feedback Persistence

In SQL Server 2019, IQP feedback was lost when plans were evicted from the plan cache. SQL Server 2022 persists feedback in Query Store so adjustments survive restarts and cache clears.

Requires Query Store to be enabled and in `READ_WRITE` mode. No additional configuration needed. Verify Query Store is enabled on all databases that should benefit:

```powershell
$splatQs = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbQueryStoreOption @splatQs |
    Where-Object ActualState -ne 'ReadWrite' |
    Select-Object SqlInstance, DatabaseName, ActualState
```

### Contained Availability Groups (Enterprise Edition, SQL Server 2022+)

A Contained AG includes a contained `master` database that stores logins and Agent jobs inside the AG. After any failover, logins and jobs are automatically available on the new primary — no manual sync scripts required.

**This replaces the `Copy-DbaLogin` / `Copy-DbaAgentJob` maintenance pattern** for Enterprise Edition deployments on SQL Server 2022 and later.

```sql
-- T-SQL syntax for a Contained AG
CREATE AVAILABILITY GROUP [AG_Production]
    WITH
    (
        CONTAINED,
        AUTOMATED_BACKUP_PREFERENCE = PRIMARY,
        ...
    )
    FOR DATABASE [OrderManagement], [CustomerPortal]
    REPLICA ON
        N'PrimaryServer' WITH (...),
        N'SecondaryServer' WITH (...);
```

Limitations: Contained AGs do not support distributed AGs, merge replication, or databases with cross-database dependencies that extend outside the AG.

See [Availability Groups](../Disaster-Recovery/Availability-Groups.md) for the full AG setup runbook.

### Ledger Tables

Ledger tables use a blockchain-style hash chain to provide cryptographically verifiable proof that rows have not been modified since they were written. The hash chain is stored alongside the data and can be verified at any time.

Two types:

| Type | Behavior |
|---|---|
| **Updatable ledger table** | Allows INSERT, UPDATE, DELETE; history is stored in a ledger history table |
| **Append-only ledger table** | Allows INSERT only; no updates or deletes possible |

```sql
-- Create an append-only ledger table (strongest immutability guarantee)
CREATE TABLE [dbo].[AuditEvent]
(
    [EventID]       int           NOT NULL IDENTITY(1,1),
    [EventDate]     datetime2(0)  NOT NULL DEFAULT GETUTCDATE(),
    [UserName]      nvarchar(128) NOT NULL,
    [Action]        nvarchar(100) NOT NULL,
    [Details]       nvarchar(max) NULL
)
WITH (LEDGER = ON (APPEND_ONLY = ON));
```

Verify the ledger hash chain has not been tampered with:

```sql
EXECUTE [sys].[sp_verify_database_ledger_from_digest_storage];
```

**Ledger is not a replacement for SQL Server Audit.** Ledger proves data integrity for what was written; SQL Server Audit proves what events occurred and who performed them. Use both together for full compliance coverage.

### Query Store Improvements

SQL Server 2022 adds two significant Query Store enhancements:

**Query Store hints:** Force optimizer behavior without modifying query text. Useful for third-party applications where the SQL cannot be changed.

```sql
-- Force a query to use a specific plan (replaces USE HINT or OPTION(RECOMPILE) in app code)
EXEC [sys].[sp_query_store_set_hints]
    @query_id   = <query_id>,
    @query_hints = N'OPTION(RECOMPILE)';
```

**Custom capture policies:** Define exactly which queries Query Store captures rather than relying on AUTO mode.

```sql
ALTER DATABASE [TargetDatabase]
SET QUERY_STORE = ON
(
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY = (
        STALE_CAPTURE_POLICY_THRESHOLD = 24 HOURS,
        EXECUTION_COUNT  = 30,
        TOTAL_COMPILE_CPU_TIME_MS = 1000,
        TOTAL_EXECUTION_CPU_TIME_MS = 100
    )
);
```

---

## SQL Server 2022 vs. 2019 Feature Matrix

| Feature | SQL Server 2019 | SQL Server 2022 |
|---|---|---|
| IQP — Row mode memory grant feedback | Yes | Yes + persistent |
| IQP — DOP feedback | No | Yes + persistent |
| IQP — CE feedback | No | Yes + persistent |
| IQP — PSPO | No | **Yes** |
| IQP — Scalar UDF inlining | Yes | Yes (improved) |
| Query Store hints | No | **Yes** |
| Query Store custom capture | No | **Yes** |
| Accelerated Database Recovery | Yes | Yes (improved PVS cleanup) |
| Ledger tables | No | **Yes** |
| Contained Availability Groups | No | **Yes** (Enterprise) |
| Azure Arc integration | Limited | Improved |
| TLS 1.3 support | No | **Yes** |
| JSON improvements | Partial | **Yes** (`JSON_OBJECT`, `JSON_ARRAY`) |

---

## Edition Notes (SQL Server 2022)

- Basic Availability Groups remain Standard Edition only — same one-database-per-AG limitation
- Contained AGs require Enterprise Edition
- Resource Governor requires Enterprise Edition
- DOP feedback and CE feedback are available on all editions

---

## Related Documents

- [SQL Server 2019 Readiness](SQL-2019-Readiness.md) — prior version features
- [SQL Server 2025 Readiness](SQL-2025-Readiness.md) — next upgrade path and breaking changes
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — Contained AG setup
- [Query Store](Query-Store.md) — Query Store configuration and monitoring
- [TLS Configuration](../Security/TLS-Configuration.md) — begin certificate prep before upgrading to 2025
