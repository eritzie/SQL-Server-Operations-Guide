# SQL Server 2022 Readiness

## Purpose

Upgrade planning and feature awareness guide for environments running SQL Server 2019 that are evaluating or beginning a move to SQL Server 2022. SQL Server 2022 (compatibility level 160) introduces significant IQP improvements, Contained Availability Groups, ledger tables, and TLS 1.3 support. The TLS changes introduced here also foreshadow breaking changes that become mandatory in SQL Server 2025.

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

SQL Server 2022 installs at compatibility level 160. Test at the new level before changing production databases.

Key behavior changes at level 160 vs. 150:

| Feature | Behavior Change |
|---|---|
| Parameter Sensitive Plan Optimization (PSPO) | Multiple plans per query for different parameter values — addresses parameter sniffing at the optimizer level |
| DOP feedback | Automatically adjusts DOP per query based on observed execution history |
| Cardinality Estimation (CE) feedback | Adjusts CE model per query based on actual vs. estimated rows |
| Memory grant feedback persistence | Feedback survives plan cache clears via Query Store |

```sql
SET NOCOUNT ON;

-- Databases not yet at level 160
SELECT
    [name],
    [compatibility_level],
    [recovery_model_desc]
FROM [sys].[databases]
WHERE [database_id] > 4
  AND [compatibility_level] < 160
ORDER BY [name];
```

### Connection String and TLS Review

SQL Server 2022 does not enforce encryption by default, but TLS 1.0 and 1.1 are deprecated. Begin the certificate and connection string audit now — it becomes a hard requirement in SQL Server 2025. See [[../Security/TLS-Configuration|TLS Configuration]] for the full certificate setup procedure.

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

PSPO is the most impactful IQP addition in SQL Server 2022. Queries that suffer from parameter sniffing can now receive multiple plans per query, selected based on statistics at compile time. PSPO activates automatically at compatibility level 160 for eligible queries — no configuration required.

Monitor via Query Store:

```sql
SET NOCOUNT ON;

-- Queries with multiple plans (potential PSPO candidates or results)
SELECT
    qsq.[query_id],
    qsqt.[query_sql_text],
    COUNT(qsp.[plan_id])        AS plan_count,
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

In SQL Server 2019, IQP feedback was lost when plans were evicted from the plan cache. SQL Server 2022 persists feedback in Query Store so adjustments survive restarts and cache clears. Requires Query Store to be enabled in `READ_WRITE` mode.

```powershell
$splatQs = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbQueryStoreOption @splatQs |
    Where-Object ActualState -ne 'ReadWrite' |
    Select-Object SqlInstance, DatabaseName, ActualState
```

### Contained Availability Groups (Enterprise Edition)

A Contained AG includes a contained `master` database that stores logins and Agent jobs within the AG itself. After any failover, logins and jobs are available on the new primary automatically — no `Copy-DbaLogin` or `Copy-DbaAgentJob` sync scripts required.

```sql
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

See [[../Disaster-Recovery/Availability-Groups|Availability Groups]] for the full AG setup runbook.

### Ledger Tables

Ledger tables use a blockchain-style hash chain to provide cryptographically verifiable proof that rows have not been modified since they were written.

| Type | Behavior |
|---|---|
| Updatable ledger table | Allows INSERT, UPDATE, DELETE; history stored in a ledger history table |
| Append-only ledger table | Allows INSERT only; no updates or deletes possible |

```sql
-- Append-only ledger table (strongest immutability guarantee)
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

Verify the hash chain has not been tampered with:

```sql
EXECUTE [sys].[sp_verify_database_ledger_from_digest_storage];
```

Ledger is not a replacement for SQL Server Audit. Ledger proves data integrity for what was written; Audit proves what events occurred and who performed them.

### Query Store Improvements

**Query Store hints** — force optimizer behavior without modifying query text. Useful for third-party applications where the SQL cannot be changed.

```sql
EXEC [sys].[sp_query_store_set_hints]
    @query_id    = <query_id>,
    @query_hints = N'OPTION(RECOMPILE)';
```

**Custom capture policies** — define exactly which queries Query Store captures:

```sql
ALTER DATABASE [TargetDatabase]
SET QUERY_STORE = ON
(
    QUERY_CAPTURE_MODE = CUSTOM,
    QUERY_CAPTURE_POLICY = (
        STALE_CAPTURE_POLICY_THRESHOLD  = 24 HOURS,
        EXECUTION_COUNT                 = 30,
        TOTAL_COMPILE_CPU_TIME_MS       = 1000,
        TOTAL_EXECUTION_CPU_TIME_MS     = 100
    )
);
```

---

## SQL Server 2022 vs. 2019 Feature Matrix

| Feature | SQL Server 2019 | SQL Server 2022 |
|---|---|---|
| IQP — Row mode memory grant feedback | Yes | Yes + persistent |
| IQP — DOP feedback | No | **Yes** + persistent |
| IQP — CE feedback | No | **Yes** + persistent |
| IQP — PSPO | No | **Yes** |
| IQP — Scalar UDF inlining | Yes | Yes (improved) |
| Query Store hints | No | **Yes** |
| Query Store custom capture | No | **Yes** |
| Ledger tables | No | **Yes** |
| Contained Availability Groups | No | **Yes** (Enterprise) |
| TLS 1.3 support | No | **Yes** |
| Resource Governor TempDB limits | No | **Yes** (Enterprise) |

---

## Edition Notes

- Basic Availability Groups remain Standard Edition only — one database per AG
- Contained AGs require Enterprise Edition
- Resource Governor requires Enterprise Edition
- DOP feedback and CE feedback are available on all editions

---

## Related Documents

- [[SQL-2025-Readiness|SQL Server 2025 Readiness]] — next upgrade path and breaking changes
- [[../Disaster-Recovery/Availability-Groups|Availability Groups]] — Contained AG setup
- [[Query-Store|Query Store]] — Query Store configuration and monitoring
- [[../Security/TLS-Configuration|TLS Configuration]] — begin certificate prep before upgrading to 2025
- [[Operations|Back to Operations]]
