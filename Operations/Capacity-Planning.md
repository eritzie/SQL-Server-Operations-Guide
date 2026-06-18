# Capacity Planning

## Purpose

Identify resource constraints weeks before they become incidents. Covers disk growth trending, autogrowth event tracking, memory pressure indicators, TempDB sizing, and alert thresholds. Review capacity snapshots weekly; investigate any metric that has moved more than 10% in a single week.

---

## Disk Capacity

### Current Disk and File Space

```powershell
# Disk free space across all volumes on the SQL Server
$splatDisk = @{
    ComputerName    = $instance
    EnableException = $true
}
Get-DbaDiskSpace @splatDisk |
    Select-Object Name, Label, Capacity, Free, PercentFree |
    Sort-Object PercentFree

# Database file sizes and free space
$splatFiles = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbSpace @splatFiles |
    Select-Object SqlInstance, DatabaseName, FileName, UsedMB, AvailableMB, PercentUsed
```

### Database Size by File Type

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

Autogrowth events are the early warning system for disk capacity. Each event means the file exhausted its pre-allocated space. Frequent events indicate undersized initial allocation or insufficient free space on the volume.

### Read Autogrowth Events from the Default Trace

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

The default trace retains only recent history (typically a few days). For longer-term trending, capture autogrowth events via Extended Events and write to a persistent table. See [[Extended-Events|Extended Events]] for session setup.

### Autogrowth Settings Audit

Autogrowth should be a fixed MB amount, never a percentage. Percentage-based growth causes increasingly large stalls as the database grows.

```powershell
$splatGrowth = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbFile @splatGrowth |
    Where-Object GrowthType -eq 'Percent' |
    Select-Object SqlInstance, Database, LogicalName, TypeDescription, Growth, GrowthType
```

### Recommended Autogrowth Sizes

| Database Size | Recommended Autogrowth | Rationale |
|---|---|---|
| < 100 GB | 1–5 GB | Infrequent but not excessive |
| 100 GB – 1 TB | 10–25 GB | Balance between frequency and stall time |
| > 1 TB | 25–50 GB | Keep events infrequent; pre-allocate instead |
| Log files | 1–5 GB or 10% of data file | Log grows faster during large transactions |

Pre-allocate files to their expected size at creation. Autogrowth is a safety net, not a sizing strategy.

---

## Memory Pressure Indicators

### Page Life Expectancy

PLE is the average seconds a page stays in the buffer pool before eviction. A sustained drop indicates the buffer pool is too small for the current working set.

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

Establish a baseline during normal business hours. A drop of 50% or more from baseline indicates memory pressure; 75% or more is critical.

### Buffer Pool Usage by Database

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

Databases consuming disproportionate buffer pool relative to their size may have missing indexes causing full scans on large tables.

### Max Memory Configuration Check

```powershell
$splatMem = @{
    SqlInstance     = $instance
    EnableException = $true
}
Test-DbaMaxMemory @splatMem |
    Select-Object SqlInstance, MaxValue, RecommendedValue, Total
```

If `MaxValue` exceeds `RecommendedValue`, SQL Server can starve the OS of memory, causing paging.

---

## TempDB Capacity

TempDB runs out of space when version store, sort spills, or user temp tables consume all allocated space. Monitor the four usage categories:

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

A growing version store usually means long-running open transactions or ADR persistent version store (PVS) cleanup lag. Query `[sys].[dm_tran_active_snapshot_database_transactions]` to find the blocking session.

---

## CPU Trending

SQL Server retains approximately four hours of 1-minute CPU samples in the ring buffer:

```sql
SET NOCOUNT ON;

DECLARE @ts_now bigint;

SELECT @ts_now = [cpu_ticks] / ([cpu_ticks] / [ms_ticks])
FROM   [sys].[dm_os_sys_info];

SELECT TOP 100
    DATEADD(MILLISECOND, -1 * (@ts_now - [timestamp]), GETDATE())                                    AS RecordedAt,
    [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/ProcessUtilization)[1]', 'int')   AS SQL_CPU_Percent,
    [record].[value]('(./Record/SchedulerMonitorEvent/SystemHealth/SystemIdle)[1]', 'int')           AS Idle_CPU_Percent,
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

For sustained CPU tracking beyond the ring buffer, schedule a SQL Agent job to capture this data into a history table every 15–30 minutes. See [[Monitoring|Monitoring]] for Agent job setup.

---

## Capacity Planning Baseline Script

Run weekly and save output for trending:

```powershell
$ErrorActionPreference = 'Stop'

$outputPath = '\\ManagementServer\CapacitySnapshots'
$date       = Get-Date -Format 'yyyy-MM-dd'

$splatDisk = @{
    ComputerName    = $instance
    EnableException = $true
}
Get-DbaDiskSpace @splatDisk |
    Select-Object @{n='SnapshotDate';e={$date}}, Name, Label, Capacity, Free, PercentFree |
    Export-Csv "$outputPath\Disk_$date.csv" -NoTypeInformation

$splatSize = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDatabase @splatSize |
    Select-Object @{n='SnapshotDate';e={$date}}, Name, Size, SpaceAvailable |
    Export-Csv "$outputPath\DatabaseSize_$date.csv" -NoTypeInformation
```

---

## Alert Thresholds

| Resource | Warning | Critical |
|---|---|---|
| Disk free space | 25% | 10% |
| Database file free space | 20% | 10% |
| Buffer pool PLE | 50% below baseline | 75% below baseline |
| TempDB free space | 25% | 10% |
| CPU (sustained over 1 hour) | 75% | 90% |

---

## Related Documents

- [[Monitoring|Monitoring]] — alert configuration for disk and performance thresholds
- [[Extended-Events|Extended Events]] — persistent autogrowth event capture
- [[Standalone-Installation|Standalone Installation]] — disk layout and autogrowth configuration at build time
- [[../Performance/Performance-Practices|Performance Practices]] — memory and buffer pool detail
- [[Operations|Back to Operations]]
