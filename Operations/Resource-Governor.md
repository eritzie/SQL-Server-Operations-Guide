# Resource Governor

> **Enterprise Edition only.** Resource Governor is not available in Standard, Express, or Developer Edition.

## Purpose

Resource Governor lets you define CPU, memory grant, and I/O boundaries by workload classification. Without it, a single runaway report or ETL job can consume all available CPU and memory grants, starving OLTP transactions. Resource Governor divides the instance into named pools with hard ceilings and assigns sessions to those pools automatically at connect time.

Primary use cases: capping report query CPU at a fixed percentage so OLTP is unaffected; limiting ETL CPU during business hours with full access off-hours; isolating development queries on a shared instance from production workloads.

---

## Architecture

Every session lands in exactly one workload group, which belongs to exactly one resource pool.

```
Connection → Classifier Function → Workload Group → Resource Pool → CPU/Memory limits
```

**Resource Pool** — defines physical resource boundaries. Key settings:

| Setting | Description |
|---|---|
| `MIN_CPU_PERCENT` | Guaranteed CPU percentage when the instance is under load |
| `MAX_CPU_PERCENT` | Hard ceiling on CPU percentage |
| `MIN_MEMORY_PERCENT` | Guaranteed memory grant percentage |
| `MAX_MEMORY_PERCENT` | Ceiling on memory grants available to this pool |

Two built-in pools exist and cannot be dropped: `internal` (system threads) and `default` (any unmatched session).

**Workload Group** — a logical classification within a pool. Multiple groups can share one pool.

| Setting | Description |
|---|---|
| `IMPORTANCE` | Relative scheduling priority within the pool (LOW, MEDIUM, HIGH) |
| `MAX_DOP` | Maximum degree of parallelism for requests in this group |
| `GROUP_MAX_REQUESTS` | Maximum concurrent requests; additional requests queue |

**Classifier Function** — a scalar T-SQL function in `master` that runs for every new connection, returning a workload group name. SQL Server evaluates it once at connect time; existing sessions are not reclassified when the function changes.

---

## Common Use Cases

| Scenario | Pool Config | Group Config |
|---|---|---|
| Cap report queries at 25% CPU | `MAX_CPU_PERCENT = 25` | `IMPORTANCE = LOW` |
| ETL full CPU off-hours, 50% cap during business hours | Two pools; classifier checks time of day | Separate groups per pool |
| Limit ad hoc queries from unknown apps | Low-resource catch-all pool | Classifier uses `APP_NAME()` |
| Separate dev from prod on shared instance | Dev pool `MAX_CPU_PERCENT = 20` | Classifier checks login or hostname |

---

## Setup — Step by Step

### Step 1: Create Resource Pools

```sql
SET NOCOUNT ON;

-- Pool for reporting workloads
CREATE RESOURCE POOL [ReportingPool]
WITH
(
    MIN_CPU_PERCENT     = 0,
    MAX_CPU_PERCENT     = 25,
    MIN_MEMORY_PERCENT  = 0,
    MAX_MEMORY_PERCENT  = 20
);

-- Pool for ETL
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

The classifier function has strict constraints: no table access, no external stored procedure calls, no non-deterministic functions that take locks. Allowed: `APP_NAME()`, `SUSER_SNAME()`, `HOST_NAME()`, `GETDATE()`. Keep the function as a simple chain of `IF`/`RETURN` statements — complexity here causes connection latency for every session.

```sql
SET NOCOUNT ON;

CREATE FUNCTION [dbo].[fn_RGClassifier]()
RETURNS sysname
WITH SCHEMABINDING
AS
BEGIN
    IF APP_NAME() LIKE '%ReportingServices%'
        RETURN N'ReportingGroup';

    IF SUSER_SNAME() = N'CORP\svc-etl'
        RETURN N'ETLGroup';

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

`RECONFIGURE` applies all pending changes in one operation. New connections are classified immediately. Existing sessions remain in their current group until they disconnect.

---

## Modifying Configuration

Use `ALTER RESOURCE POOL` or `ALTER WORKLOAD GROUP`, then run `ALTER RESOURCE GOVERNOR RECONFIGURE`. Changes take effect for new connections only.

To remove the classifier and revert all sessions to the default pool:

```sql
SET NOCOUNT ON;

ALTER RESOURCE GOVERNOR WITH (CLASSIFIER_FUNCTION = NULL);
ALTER RESOURCE GOVERNOR RECONFIGURE;
```

To disable Resource Governor entirely (routes all sessions to default pool immediately):

```sql
ALTER RESOURCE GOVERNOR DISABLE;
```

---

## Monitoring

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
FROM [sys].[dm_resource_governor_resource_pools]                        AS rp
JOIN [sys].[dm_resource_governor_resource_pools_runtime_stats]          AS rps
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
FROM [sys].[dm_resource_governor_workload_groups]                       AS wg
JOIN [sys].[dm_resource_governor_workload_groups_runtime_stats]         AS wgs
    ON [wg].[group_id] = [wgs].[group_id]
JOIN [sys].[dm_resource_governor_resource_pools]                        AS rp
    ON [wg].[pool_id] = [rp].[pool_id]
ORDER BY [wg].[name];

-- Which sessions are in which group right now
SELECT
    [s].[session_id],
    [s].[login_name],
    [s].[program_name],
    [wg].[name]     AS WorkloadGroup,
    [rp].[name]     AS ResourcePool
FROM [sys].[dm_exec_sessions]                                           AS s
JOIN [sys].[dm_resource_governor_workload_groups]                       AS wg
    ON [s].[group_id] = [wg].[group_id]
JOIN [sys].[dm_resource_governor_resource_pools]                        AS rp
    ON [wg].[pool_id] = [rp].[pool_id]
WHERE [s].[is_user_process] = 1
ORDER BY [wg].[name], [s].[session_id];
```

---

## Testing the Classifier

After activating Resource Governor, verify a new connection lands in the expected group:

```sql
SET NOCOUNT ON;

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

If the session lands in `default` when you expected a specific group, use `SELECT APP_NAME()`, `SELECT SUSER_SNAME()`, and `SELECT HOST_NAME()` in that connection to see what values the classifier would have evaluated.

---

## SQL Server 2022 TempDB Limits

SQL Server 2022 adds the `TEMPDB_SPILL_PERCENT` workload group setting, which limits the percentage of TempDB that a workload group can consume for spill operations. This prevents a single heavy sort or hash join from exhausting TempDB at the expense of other workloads.

```sql
CREATE WORKLOAD GROUP [BulkLoads]
    WITH (TEMPDB_SPILL_PERCENT = 20);   -- Limit this group to 20% of TempDB space
```

See [[SQL-2022-Readiness|SQL Server 2022 Readiness]] for additional SQL Server 2022 feature context.

---

## Related Documents

- [[Monitoring|Monitoring]] — session monitoring and blocking detection
- [[SQL-2022-Readiness|SQL Server 2022 Readiness]] — SQL Server 2022 feature readiness
- [[Operations|Back to Operations]]
