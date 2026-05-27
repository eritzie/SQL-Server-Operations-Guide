# Resource Governor

> **Enterprise Edition only.** Resource Governor is not available in Standard, Express, or Developer Edition. All configuration shown here requires Enterprise Edition. The SQL Server 2022 TempDB spill limits referenced at the end of this document have the same requirement.

## Purpose

Resource Governor lets you define CPU, memory grant, and I/O boundaries by workload classification. Without it, a single runaway SSRS report or ETL job can consume all available CPU and memory grants, starving OLTP transactions. Resource Governor divides the instance into named pools with hard ceilings and assigns sessions to those pools automatically at connect time.

Primary use cases: capping report query CPU at a fixed percentage so OLTP is unaffected; limiting ETL CPU during business hours with full access off-hours; isolating development queries on a shared instance from production workloads; throttling ad hoc queries from unrecognized applications.

---

## Architecture

Resource Governor uses a three-layer hierarchy. Every session lands in exactly one workload group, which belongs to exactly one resource pool.

```
Connection → Classifier Function → Workload Group → Resource Pool → CPU/Memory/IO limits
```

**Resource Pool** — defines physical resource boundaries for a set of workload groups. Key settings:

| Setting | Description |
|---|---|
| `MIN_CPU_PERCENT` | Guaranteed CPU percentage when the instance is under load |
| `MAX_CPU_PERCENT` | Hard ceiling on CPU percentage |
| `MIN_MEMORY_PERCENT` | Guaranteed memory grant percentage |
| `MAX_MEMORY_PERCENT` | Ceiling on memory grants available to this pool |

Two built-in pools exist and cannot be dropped: `internal` (system threads) and `default` (any session not matched by the classifier).

**Workload Group** — a logical classification within a pool. Multiple groups can share one pool, but each group belongs to exactly one pool. Key settings:

| Setting | Description |
|---|---|
| `IMPORTANCE` | Relative scheduling priority within the pool (LOW, MEDIUM, HIGH) |
| `MAX_DOP` | Maximum degree of parallelism for requests in this group |
| `GROUP_MAX_REQUESTS` | Maximum concurrent requests; additional requests queue |

**Classifier Function** — a scalar T-SQL function in the `master` database that runs for every new connection. It returns a `sysname` value that must match an existing workload group name. SQL Server evaluates it once at connect time; existing sessions are not reclassified when the function changes.

---

## Common Use Cases

| Scenario | Pool Config | Group Config |
|---|---|---|
| Cap SSRS queries at 25% CPU | `MAX_CPU_PERCENT = 25` | `IMPORTANCE = LOW` |
| ETL full CPU off-hours, 50% cap during business hours | Two pools; classifier checks time of day | Separate groups per pool |
| Limit ad hoc queries from unknown apps | Catch-all pool with low resource ceiling | Classifier uses `APP_NAME()` |
| Separate dev from prod on shared instance | Dev pool `MAX_CPU_PERCENT = 20` | Classifier checks login or hostname |

---

## Setup — Step by Step

### Step 1: Create Resource Pools

```sql
SET NOCOUNT ON;

-- Pool for reporting workloads — capped at 25% CPU, 20% memory grants
CREATE RESOURCE POOL [ReportingPool]
WITH
(
    MIN_CPU_PERCENT     = 0,
    MAX_CPU_PERCENT     = 25,
    MIN_MEMORY_PERCENT  = 0,
    MAX_MEMORY_PERCENT  = 20
);

-- Pool for ETL — capped at 50% CPU, 30% memory grants
CREATE RESOURCE POOL [ETLPool]
WITH
(
    MIN_CPU_PERCENT     = 0,
    MAX_CPU_PERCENT     = 50,
    MIN_MEMORY_PERCENT  = 0,
    MAX_MEMORY_PERCENT  = 30
);
```

### Step 2: Create Workload Groups

```sql
SET NOCOUNT ON;

CREATE WORKLOAD GROUP [ReportingGroup]
WITH
(
    IMPORTANCE          = LOW,
    MAX_DOP             = 4,
    GROUP_MAX_REQUESTS  = 10
)
USING [ReportingPool];

CREATE WORKLOAD GROUP [ETLGroup]
WITH
(
    IMPORTANCE  = MEDIUM,
    MAX_DOP     = 8
)
USING [ETLPool];
```

### Step 3: Create the Classifier Function

The classifier function must follow strict constraints: no table access, no external stored procedure calls, no non-deterministic functions that take locks. Built-in metadata functions (`APP_NAME()`, `SUSER_SNAME()`, `HOST_NAME()`, `GETDATE()`) are allowed. Keep the function as a simple chain of `IF`/`RETURN` statements — complexity here causes connection latency for every session.

```sql
SET NOCOUNT ON;

CREATE FUNCTION [dbo].[fn_RGClassifier]()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    -- Classify SSRS connections
    IF APP_NAME() LIKE '%ReportingServices%'
        RETURN N'ReportingGroup';

    -- Classify ETL service account
    IF SUSER_SNAME() = N'CORP\svc-etl'
        RETURN N'ETLGroup';

    -- Everything else goes to the default group
    RETURN N'default';
END;
GO
```

### Step 4: Register the Classifier and Activate

```sql
SET NOCOUNT ON;

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = [dbo].[fn_RGClassifier]);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

`RECONFIGURE` applies all pending changes — new pool definitions, group definitions, and the classifier function — in one operation. New connections are classified immediately. Existing sessions remain in their current group until they disconnect and reconnect.

---

## Modifying Configuration

To change pool or group settings, use `ALTER RESOURCE POOL` or `ALTER WORKLOAD GROUP`, then run `ALTER RESOURCE GOVERNOR RECONFIGURE`. To swap the classifier function, create the new function first, then point Resource Governor at it with `ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = ...)` followed by `RECONFIGURE`.

Changes take effect for new connections only. Existing sessions are not moved.

To remove the classifier function and revert all sessions to the default pool:

```sql
SET NOCOUNT ON;

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

---

## Disabling Resource Governor

```sql
SET NOCOUNT ON;

ALTER RESOURCE GOVERNOR DISABLE;
```

Disabling routes all sessions to the default pool immediately, including existing sessions. Resource Governor can be re-enabled with `ALTER RESOURCE GOVERNOR RECONFIGURE`.

---

## Monitoring

### Pool and Group Utilization

```sql
SET NOCOUNT ON;

-- Current resource pool utilization
SELECT
    [rp].[name]                 AS PoolName,
    [rp].[max_cpu_percent],
    [rp].[max_memory_percent],
    [rps].[total_cpu_usage_ms],
    [rps].[active_memgrant_count],
    [rps].[active_memgrant_kb]
FROM [sys].[dm_resource_governor_resource_pools]    AS rp
JOIN [sys].[dm_resource_governor_resource_pools_runtime_stats]    AS rps
    ON [rp].[pool_id] = [rps].[pool_id]
ORDER BY [rp].[name];

-- Active workload groups and request counts
SELECT
    [wg].[name]                 AS GroupName,
    [rp].[name]                 AS PoolName,
    [wgs].[total_request_count],
    [wgs].[active_request_count],
    [wgs].[blocked_task_count],
    [wgs].[total_cpu_usage_ms]
FROM [sys].[dm_resource_governor_workload_groups]   AS wg
JOIN [sys].[dm_resource_governor_workload_groups_runtime_stats]   AS wgs
    ON [wg].[group_id] = [wgs].[group_id]
JOIN [sys].[dm_resource_governor_resource_pools]    AS rp
    ON [wg].[pool_id] = [rp].[pool_id]
ORDER BY [wg].[name];

-- Which sessions are in which group right now
SELECT
    [s].[session_id],
    [s].[login_name],
    [s].[program_name],
    [wg].[name]     AS WorkloadGroup,
    [rp].[name]     AS ResourcePool
FROM [sys].[dm_exec_sessions]                       AS s
JOIN [sys].[dm_resource_governor_workload_groups]   AS wg
    ON [s].[group_id] = [wg].[group_id]
JOIN [sys].[dm_resource_governor_resource_pools]    AS rp
    ON [wg].[pool_id] = [rp].[pool_id]
WHERE [s].[is_user_process] = 1
ORDER BY [wg].[name], [s].[session_id];
```

---

## Testing the Classifier

After activating Resource Governor, verify that a new connection lands in the expected group. Connect using the target login or application, then run:

```sql
SET NOCOUNT ON;

-- Check which group the current session landed in
SELECT
    [s].[session_id],
    [wg].[name] AS WorkloadGroup,
    [rp].[name] AS ResourcePool
FROM [sys].[dm_exec_sessions]                       AS s
JOIN [sys].[dm_resource_governor_workload_groups]   AS wg
    ON [s].[group_id] = [wg].[group_id]
JOIN [sys].[dm_resource_governor_resource_pools]    AS rp
    ON [wg].[pool_id] = [rp].[pool_id]
WHERE [s].[session_id] = @@SPID;
```

If the session lands in `default` when you expected a specific group, the classifier function did not match. Use `SELECT APP_NAME()`, `SELECT SUSER_SNAME()`, and `SELECT HOST_NAME()` in that connection to see what values the classifier would have evaluated, then compare against your `IF` conditions.

---

## SQL Server 2022 TempDB Limits

SQL Server 2022 adds the `TEMPDB_SPILL_PERCENT` workload group setting, which limits the percentage of TempDB that a workload group can consume for spill operations. This prevents a single heavy sort or hash join from exhausting TempDB at the expense of other workloads. Like all Resource Governor features, it requires Enterprise Edition. See [SQL-2025-Readiness.md](../Operations/SQL-2025-Readiness.md) for more detail on SQL Server 2022 and 2025 feature readiness in this environment.

---

## Related Documents

- [SSRS.md](../Operations/SSRS.md) — reporting services configuration; Resource Governor is a primary tool for capping SSRS resource consumption
- [SSIS.md](../Operations/SSIS.md) — ETL workload management; ETL pool setup applies directly to SSIS execution accounts
- [Monitoring.md](../Operations/Monitoring.md) — session monitoring and blocking detection; use alongside the workload group DMV queries above
- [SQL-2025-Readiness.md](../Operations/SQL-2025-Readiness.md) — SQL Server 2022/2025 feature readiness, including TempDB spill limits
