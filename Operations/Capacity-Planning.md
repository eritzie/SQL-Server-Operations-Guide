# Capacity Planning

## Purpose

Identify resource constraints weeks before they become incidents. This guide covers disk growth
trending, autogrowth event tracking, memory pressure indicators, TempDB sizing, and file
autogrowth settings. Review capacity snapshots weekly; investigate any metric that has moved
more than 10% in a single week.

Related documents: [Monitoring](Monitoring.md) |
[Performance Practices](../Performance/PerformancePractices.md) |
[Standalone Installation](StandaloneInstallation.md)

---

## Disk Capacity

### Current Disk and File Space

```powershell
# Disk free space across all volumes on the SQL Server
$splatDisk = @{
    ComputerName    = 'SqlServer01'
    EnableException = $true
}
Get-DbaDiskSpace @splatDisk |
    Select-Object Name, Label, Capacity, Free, PercentFree |
    Sort-Object PercentFree

# Database file sizes and free space
$splatFiles = @{
    SqlInstance     = 'SqlServer01'
    EnableException = $true
}
Get-DbaDbSpace @splatFiles |
    Select-Object SqlInstance, DatabaseName, FileName, UsedMB, AvailableMB, PercentUsed
```

### Database Size by File Type

Returns current allocated size broken out by data and log files. Run against each instance;
sort by TotalSizeMB to prioritize which databases need pre-allocation attention first.

```sql
SET NOCOUNT ON;

SELECT
    [db].[name]                                                             AS DatabaseName,
    SUM([mf].[size]) * 8 / 1024                                            AS TotalSizeMB,
    SUM(CASE WHEN [mf].[type] = 0 THEN [mf].[size] ELSE 0 END) * 8 / 1024 AS DataFileSizeMB,
    SUM(CASE WHEN [mf].[type] = 1 THEN [mf].[size] ELSE 0 END) * 8 / 1024 AS LogFileSizeMB
FROM [sys].[databases]    AS db
JOIN [sys].[master_files] AS mf
    ON [db].[database_id] = [mf].[database_id]
WHERE [db].[database_id] > 4
GROUP BY [db].[name]
ORDER BY TotalSizeMB DESC;
```

---

## Autogrowth Event Tracking

Autogrowth events are the early warning system for disk capacity. Each event means the file
exhausted its pre-allocated space. Frequent events indicate undersized initial allocation or
insufficient free space on the volume.

### Read Autogrowth Events from the Default Trace

The default trace is always running and requires no session setup. It captures autogrowth
events with file name, duration, and growth amount.

```sql
SET NOCOUNT ON;

DECLARE @tracefile nvarchar(500);

SELECT @tracefile = REPLACE([path], '.trc', '') + '.trc'
FROM   [sys].[traces]
WHERE  [is_default] = 1;

SELECT
    [te].[name]                    AS EventType,
    [t].[DatabaseName],
    [t].[FileName],
    [t].[Duration] / 1000          AS DurationMS,
    [t].[IntegerData] * 8          AS GrowthKB,
    [t].[StartTime]
FROM [sys].[fn_trace_gettable](@tracefile, DEFAULT) AS t
JOIN [sys].[trace_events]                           AS te
    ON [t].[EventClass] = [te].[trace_event_id]
WHERE [te].[name] IN ('Data File Auto Grow', 'Log File Auto Grow')
ORDER BY [t].[StartTime] DESC;
```

The default trace rolls over and retains only recent history (typically a few days). For
longer-term trending, capture autogrowth events via Extended Events and write to a persistent
table. See [Extended Events](Extended-Events.md) for session setup.

### Autogrowth Settings Audit

Autogrowth should be a fixed MB amount, never a percentage. Percentage-based growth causes
increasingly large stalls as the database grows (a 10% growth on a 1 TB database stalls for
minutes). Find all files still set to percentage growth:

```powershell
$splatGrowth = @{
    SqlInstance     = 'SqlServer01'
    EnableException = $true
}
Get-DbaDbFile @splatGrowth |
    Where-Object GrowthType -eq 'Percent' |
    Select-Object SqlInstance, Database, LogicalName, TypeDescription, Growth, GrowthType
```

### Recommended Autogrowth Sizes

| Database Size    | Recommended Autogrowth       | Rationale                                         |
|------------------|------------------------------|---------------------------------------------------|
| < 100 GB         | 1–5 GB                       | Infrequent but not excessive                      |
| 100 GB – 1 TB    | 10–25 GB                     | Balance between frequency and stall time          |
| > 1 TB           | 25–50 GB                     | Keep events infrequent; pre-allocate instead      |
| Log files        | 1–5 GB or 10% of data file   | Log grows faster during large transactions        |

Pre-allocate files to their expected size at creation. Autogrowth is a safety net, not a
sizing strategy.

---

## Memory Pressure Indicators

SQL Server's buffer pool should hold the working set of data pages. When it cannot, queries
read from disk on every execution instead of from memory.

### Page Life Expectancy

PLE is the average number of seconds a page stays in the buffer pool before being evicted.
A sustained drop indicates the buffer pool is too small for the current working set.

```sql
SET NOCOUNT ON;

SELECT
    [object_name],
    [counter_name],
    [instance_name],
    [cntr_value] AS PLE_Seconds
FROM [sys].[dm_os_performance_counters]
WHERE [counter_name] = 'Page life expectancy'
  AND [object_name]  LIKE '%Buffer Manager%';
```

A steady value of 300+ is commonly cited as a floor, but establish your own baseline during
normal business hours. A drop of 50% or more from baseline during normal operations indicates
memory pressure. A drop of 75% or more is critical.

### Buffer Pool Usage by Database

Identify which databases are consuming the most buffer pool pages. Databases consuming
disproportionate buffer pool relative to their size may have missing indexes causing full
scans on large tables.

```sql
SET NOCOUNT ON;

SELECT
    DB_NAME([database_id])  AS DatabaseName,
    COUNT(*) * 8 / 1024     AS BufferPoolMB
FROM [sys].[dm_os_buffer_descriptors]
WHERE [database_id] > 4
GROUP BY [database_id]
ORDER BY BufferPoolMB DESC;
```

### Max Memory Configuration Check

```powershell
$splatMem = @{
    SqlInstance     = 'SqlServer01'
    EnableException = $true
}
Test-DbaMaxMemory @splatMem |
    Select-Object SqlInstance, MaxValue, RecommendedValue, Total
```

If MaxValue exceeds RecommendedValue, SQL Server can starve the OS of memory, causing paging.
If MaxValue is far below RecommendedValue, the buffer pool is unnecessarily constrained.

---

## TempDB Capacity

TempDB runs out of space when version store, sort spills, or user temp tables consume all
allocated space. Monitor the four usage categories: user objects, internal objects (sort
spills, hash joins), version store (row versioning / RCSI), and free space.

```sql
SET NOCOUNT ON;

SELECT
    [SUM_user_object_reserved_page_count]     * 8 / 1024 AS UserObjectsMB,
    [SUM_internal_object_reserved_page_count] * 8 / 1024 AS InternalObjectsMB,
    [SUM_version_store_reserved_page_count]   * 8 / 1024 AS VersionStoreMB,
    [SUM_unallocated_extent_page_count]       * 8 / 1024 AS FreeMB
FROM [sys].[dm_db_file_space_usage]
WHERE [database_id] = 2;
```

A growing version store usually means long-running open transactions or Accelerated Database
Recovery (ADR) persistent version store (PVS) cleanup lag. Query
`[sys].[dm_tran_active_snapshot_database_transactions]` to find the blocking session.

---

## CPU Trending

SQL Server does not retain long-term CPU history natively. The ring buffer holds approximately
four hours of 1-minute samples.

```sql
SET NOCOUNT ON;

DECLARE @ts_now bigint;

SELECT @ts_now = [cpu_ticks] / ([cpu_ticks] / [ms_ticks])
FROM   [sys].[dm_os_sys_info];

SELECT TOP 100
    DATEADD(MILLISECOND, -1 * (@ts_now - [timestamp]), GETDATE())                                AS RecordedAt,
    [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int') AS SQL_CPU_Percent,
    [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')         AS Idle_CPU_Percent,
    100
        - [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')
        - [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')
                                                                                                  AS Other_CPU_Percent
FROM (
    SELECT [timestamp], CAST([record] AS xml) AS record
    FROM   [sys].[dm_os_ring_buffers]
    WHERE  [ring_buffer_type] = N'RING_BUFFER_SCHEDULER_MONITOR'
) AS ring_data
ORDER BY RecordedAt DESC;
```

For sustained CPU tracking beyond the ring buffer, schedule a SQL Agent job to capture this
data into a table every 15–30 minutes. See [Monitoring](Monitoring.md) for Agent job setup.

---

## Capacity Planning Baseline Script

Run weekly and save output for trending. Comparing snapshots over time reveals growth
trajectories before they become emergencies.

```powershell
$ErrorActionPreference = 'Stop'

$instance   = 'SqlServer01'
$outputPath = '\\ManagementServer\CapacitySnapshots'
$date       = Get-Date -Format 'yyyy-MM-dd'

# Disk space snapshot
$splatDisk = @{
    ComputerName    = $instance
    EnableException = $true
}
Get-DbaDiskSpace @splatDisk |
    Select-Object @{n='SnapshotDate';e={$date}}, Name, Label, Capacity, Free, PercentFree |
    Export-Csv "$outputPath\Disk_$date.csv" -NoTypeInformation

# Database size snapshot
$splatSize = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDatabase @splatSize |
    Select-Object @{n='SnapshotDate';e={$date}}, Name, Size, SpaceAvailable |
    Export-Csv "$outputPath\DatabaseSize_$date.csv" -NoTypeInformation
```

---

## Thresholds and Alert Recommendations

| Resource                        | Warning Threshold        | Critical Threshold       |
|---------------------------------|--------------------------|--------------------------|
| Disk free space                 | 25%                      | 10%                      |
| Database file free space        | 20%                      | 10%                      |
| Buffer pool PLE                 | 50% below baseline       | 75% below baseline       |
| TempDB free space               | 25%                      | 10%                      |
| CPU (sustained over 1 hour)     | 75%                      | 90%                      |

Configure SQL Agent alerts for disk thresholds using WMI or a monitoring agent. See
[Monitoring](Monitoring.md) for alert configuration steps.
