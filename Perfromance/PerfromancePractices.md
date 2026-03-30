# SQL Server Performance Practices

> **Environment context:** These practices were developed while managing SQL Server environments ranging from standalone instances to multi-node failover clusters, with databases up to 18TB in size.

## Table of Contents

- [Disk Configurations](#disk-configurations)
- [Instant File Initialization](#instant-file-initialization)
- [Max Server Memory](#max-server-memory)
- [Max Degree of Parallelism (MAXDOP)](#max-degree-of-parallelism-maxdop)
- [Cost Threshold for Parallelism](#cost-threshold-for-parallelism)
- [TempDB Configuration](#tempdb-configuration)
- [Missing Indexes](#missing-indexes)
- [Index Fragmentation](#index-fragmentation)

## Disk Configurations

Disk configuration is one of the most impactful performance factors for SQL Server because it is I/O intensive.

Data files, log files, TempDB files, FileStream objects, and backups should each reside on their own separate disk. The exception is a local development or test instance where consolidation is acceptable.

Beyond separation, how the disks are formatted matters significantly. Data, log, TempDB, and FileStream disks should all be formatted with a **64KB allocation unit size**. The Windows default is 4KB. SQL Server performs disk I/O in extents — an extent is 8 pages, each page is 8KB, totaling 64KB per extent. Aligning the allocation unit size to the extent size eliminates split I/O operations and significantly improves throughput. The backup disk can remain at the default 4KB or be set to 8KB.

Each disk should be initialized using **GPT** rather than MBR. While this doesn't directly impact performance, GPT removes the 2TB partition size limitation that MBR imposes.

The following dbatools command audits the disk configuration on a given SQL Server:

```powershell
Test-DbaDiskAllocation -ComputerName SqlServer01 | Select-Object * | Out-GridView
```

The output includes a `BlockSize` column (look for 65,536 which is 64KB), an `IsSqlDisk` column indicating whether the disk hosts data or log files, and an `IsBestPractice` column that flags whether the formatting meets recommendations.

There are additional factors that impact disk and SQL Server performance (RAID level, SSD vs. spinning disk, storage tiering, multipath I/O), but correct formatting is the minimum baseline and one of the easiest wins.

## Instant File Initialization

Instant File Initialization (IFI) is a free performance improvement. During SQL Server installation, you'll be prompted to **Grant Perform Volume Maintenance Task** to the SQL Server service account — check that option.

With IFI enabled, SQL Server uses a different Windows API (`SetFileValidData`) when creating or growing data files. Instead of zero-filling the allocated space (which can take minutes for large files), it marks the space as allocated immediately. This benefits any operation that creates or expands data files, including TempDB — which grows its data files frequently under normal workloads.

To verify IFI is enabled on an existing server:

```powershell
Get-DbaPrivilege -ComputerName SqlServer01
```

The output includes an `InstantFileInitializationGranted` property. If it shows `False`, the SQL Server service account needs the **Perform Volume Maintenance Tasks** local security policy right.

> **Note:** IFI applies only to data files (.mdf/.ndf), not log files (.ldf). Log files must always be zero-initialized for transactional integrity.

## Max Server Memory

Configuring SQL Server's max memory is a critical performance setting. Set it too high and the OS will issue low memory notifications, triggering SQL Server's internal memory broker to release memory — a process that causes performance dips. Set it too low and queries will spill to disk unnecessarily.

The following query checks the ring buffer for memory pressure events:

```sql
SELECT
    EventTime,
    record.value('(/Record/ResourceMonitor/Notification)[1]', 'varchar(max)') AS [Type],
    record.value('(/Record/MemoryRecord/AvailablePhysicalMemory)[1]', 'bigint') AS [Avail Phys Mem KB],
    record.value('(/Record/MemoryRecord/AvailableVirtualAddressSpace)[1]', 'bigint') AS [Avail VAS KB]
FROM (
    SELECT
        DATEADD(ss, (-1 * ((cpu_ticks / CONVERT(float, (cpu_ticks / ms_ticks))) - [timestamp]) / 1000), GETDATE()) AS EventTime,
        CONVERT(xml, record) AS record
    FROM sys.dm_os_ring_buffers
    CROSS JOIN sys.dm_os_sys_info
    WHERE ring_buffer_type = 'RING_BUFFER_RESOURCE_MONITOR'
) AS tab
ORDER BY EventTime DESC;
```

When you see `RESOURCE_MEMPHYSICAL_LOW` in the results, the max memory setting is too high and SQL Server is starving the OS.

The following dbatools command provides a recommended starting point:

```powershell
Test-DbaMaxMemory -SqlInstance SqlServer01
```

This reports total server memory, current max memory configuration, and a recommended value. As a general guideline, leave approximately **15% of total memory for the OS**. If additional services such as SSRS or SSIS are installed on the same server, increase that to **20–25%**.

Once you've determined the correct value, apply it:

```powershell
# Check current value
Get-DbaMaxMemory -SqlInstance SqlServer01

# Set to recommended value (in MB)
Set-DbaMaxMemory -SqlInstance SqlServer01 -Max 111523
```

Memory usage should be monitored over time. If low memory warnings persist in the ring buffer after adjusting the setting, the server likely needs additional physical memory.

## Max Degree of Parallelism (MAXDOP)

MAXDOP limits the number of processors SQL Server can use for a single parallel query execution. The correct setting depends on your server's NUMA topology — specifically the number of NUMA nodes and the number of logical processors per node.

Microsoft's guidelines for configuring MAXDOP:

- **Single NUMA node, ≤8 logical processors:** Set MAXDOP to the number of logical processors or fewer.
- **Single NUMA node, >8 logical processors:** Set MAXDOP to 8.
- **Multiple NUMA nodes, ≤16 logical processors per node:** Set MAXDOP to the number of logical processors per node or fewer.
- **Multiple NUMA nodes, >16 logical processors per node:** Set MAXDOP to half the logical processors per node, with a maximum of 16.

Reference: [Configure the max degree of parallelism Server Configuration Option](https://docs.microsoft.com/en-us/sql/database-engine/configure-windows/configure-the-max-degree-of-parallelism-server-configuration-option)

The following dbatools command helps determine the appropriate setting for your environment:

```powershell
Test-DbaMaxDop -SqlInstance SqlServer01 | Select-Object *
```

This reports the current MAXDOP setting, the number of NUMA nodes, processors per node, and a recommended value.

Once you've determined the correct value, apply it:

```powershell
Set-DbaMaxDop -SqlInstance SqlServer01 -MaxDop 8
```

## Cost Threshold for Parallelism

Cost Threshold for Parallelism (CTFP) works in conjunction with MAXDOP. If MAXDOP is set to 1 (serial execution only), CTFP is ignored. CTFP specifies the estimated query cost (in seconds) at which SQL Server considers generating a parallel execution plan.

The default value is **5**, which dates back to SQL Server 7.0 and is far too low for modern hardware. Most queries will exceed a cost of 5, resulting in excessive parallelism overhead for queries that don't benefit from it.

There's no universal best-practice value since it depends on workload characteristics, but **50 is a reasonable starting point** for most OLTP environments.

Check the current value and change it via dbatools:

```powershell
# Check current CTFP setting
Get-DbaSpConfigure -SqlInstance SqlServer01 -Name CostThresholdForParallelism

# Set to 50
Set-DbaSpConfigure -SqlInstance SqlServer01 -Name CostThresholdForParallelism -Value 50
```

To check for parallelism-related waits at the server level:

```powershell
Get-DbaWaitStatistic -SqlInstance SqlServer01 |
    Where-Object { $_.WaitType -in @('CXPACKET','CXCONSUMER') } |
    Select-Object WaitType, WaitCount, WaitSeconds, ResourceSeconds
```

If query performance issues persist, the following query can help identify the specific sessions experiencing parallelism waits:

```sql
SELECT
    er.session_id,
    es.program_name,
    est.text,
    er.database_id,
    eqp.query_plan,
    er.cpu_time
FROM sys.dm_exec_requests er
INNER JOIN sys.dm_exec_sessions es
    ON es.session_id = er.session_id
OUTER APPLY sys.dm_exec_sql_text(er.sql_handle) est
OUTER APPLY sys.dm_exec_query_plan(er.plan_handle) eqp
WHERE
    es.is_user_process = 1
    AND er.last_wait_type = N'CXPACKET'
ORDER BY er.session_id;
```

> **Note:** The wait type to look for is `CXPACKET` (or `CXCONSUMER` on SQL Server 2017+), which indicates parallelism waits. The original version of this document referenced `SOS_SCHEDULER_YIELD`, which indicates CPU pressure from scheduler yielding — related but a different issue. `CXPACKET` waits are the direct indicator that CTFP tuning may help.

Once you identify affected queries, verify their execution plans are efficient, then adjust CTFP incrementally until you find the sweet spot for your workload.

## TempDB Configuration

TempDB is used by most SQL Server operations — sorts, hash joins, version store, temp tables, table variables, and more. Because TempDB data files are extremely I/O intensive compared to user databases, they should reside on their own dedicated disk.

Key TempDB recommendations:

- **Number of data files:** Match the number of logical processors, up to 8. Beyond 8, add files in increments of 4 only if allocation contention (`PAGELATCH_*` waits on PFS/GAM/SGAM pages) is observed.
- **Equal file sizing:** All TempDB data files must be the same size. SQL Server uses a proportional fill algorithm — if files are different sizes, it will disproportionately use the largest file, defeating the purpose of multiple files.
- **Pre-allocate space:** Size the files to consume most of the TempDB disk upfront to avoid autogrowth events during production workloads.
- **Equal autogrowth:** All files should use the same autogrowth increment (in MB, not percentage).

The following dbatools command audits TempDB configuration against these recommendations:

```powershell
Test-DbaTempDbConfig -SqlInstance SqlServer01 | Select-Object * | Out-GridView
```

The output compares the recommended setting against the current configuration for each check.

## Missing Indexes

Indexes are one of the highest-impact performance factors. A single missing index can turn a sub-second query into one that runs for minutes.

For identifying missing indexes, [Brent Ozar's sp_BlitzIndex](https://www.brentozar.com/blitzindex) provides a comprehensive analysis:

```sql
EXEC dbo.sp_BlitzIndex @GetAllDatabases = 1;
```

The results are prioritized by estimated impact. Focus on the **High** priority items first — these typically represent an 80–90% potential performance improvement for the affected queries. Lower-priority missing indexes may still provide a 20–40% boost.

Keep in mind that indexes are not free. Each index adds overhead to INSERT, UPDATE, and DELETE operations because every index must be maintained. As a guideline, aim to keep the total number of indexes on any single table between **5 and 10**. Beyond that, write performance can degrade and the optimizer may struggle with plan selection.

Before adding new indexes, also check for duplicates and unused indexes that can be cleaned up:

```powershell
# Find duplicate or overlapping indexes across all databases
Find-DbaDbDuplicateIndex -SqlInstance SqlServer01 | Out-GridView

# Find disabled indexes that are consuming space but not being used
Find-DbaDbDisabledIndex -SqlInstance SqlServer01 | Out-GridView
```

## Index Fragmentation

Fragmentation accumulates through data modifications (INSERT, UPDATE, DELETE) as pages split and logical ordering diverges from physical ordering. On traditional spinning disks, high fragmentation forces additional I/O seeks. On SSDs, the impact is reduced but not eliminated — fragmented indexes still waste buffer pool memory with partially-filled pages.

Check fragmentation for a specific table:

```sql
SELECT
    index_type_desc,
    alloc_unit_type_desc,
    index_depth,
    index_level,
    avg_fragmentation_in_percent,
    fragment_count,
    avg_fragment_size_in_pages,
    page_count
FROM sys.dm_db_index_physical_stats(
    DB_ID(N'DatabaseName'),
    OBJECT_ID(N'SchemaName.TableName'),
    NULL,
    NULL,
    'DETAILED'
);
```

For a PowerShell-based approach, wrap the DMV query with `Invoke-DbaQuery`:

```powershell
$query = @"
SELECT
    OBJECT_SCHEMA_NAME(ips.object_id) AS SchemaName,
    OBJECT_NAME(ips.object_id) AS TableName,
    i.name AS IndexName,
    ips.index_type_desc,
    ips.avg_fragmentation_in_percent,
    ips.avg_page_space_used_in_percent,
    ips.page_count
FROM sys.dm_db_index_physical_stats(DB_ID(), NULL, NULL, NULL, 'LIMITED') ips
INNER JOIN sys.indexes i
    ON ips.object_id = i.object_id AND ips.index_id = i.index_id
WHERE ips.page_count > 1000
    AND ips.avg_fragmentation_in_percent > 5
ORDER BY ips.avg_fragmentation_in_percent DESC;
"@

Invoke-DbaQuery -SqlInstance SqlServer01 -Database DatabaseName -Query $query | Out-GridView
```

> **Note:** There is no dedicated dbatools command for index fragmentation reporting. The DMV query is the right tool here — wrapping it with `Invoke-DbaQuery` keeps it in the PowerShell pipeline if you're auditing multiple instances.

General thresholds:

| Fragmentation | Action |
|---|---|
| < 5% | No action needed |
| 5–30% | Reorganize (online, minimal locking) |
| > 30% | Rebuild (can be done online with Enterprise Edition) |

> **SSD consideration:** With modern SSD-based storage, the 30% rebuild threshold is less critical because random I/O cost is minimal. The bigger concern with fragmented indexes on SSDs is wasted buffer pool space from low page density. Monitor `avg_page_space_used_in_percent` from the same DMV to catch that.

After rebuilding or reorganizing indexes, update statistics to ensure the optimizer has accurate cardinality estimates.

[Ola Hallengren's IndexOptimize](https://ola.hallengren.com/sql-server-index-and-statistics-maintenance.html) automates this work and can be scheduled via SQL Agent:

```sql
EXECUTE dbo.IndexOptimize
    @Databases = 'USER_DATABASES',
    @FragmentationLow = NULL,
    @FragmentationMedium = 'INDEX_REORGANIZE,INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationHigh = 'INDEX_REBUILD_ONLINE,INDEX_REBUILD_OFFLINE',
    @FragmentationLevel1 = 5,
    @FragmentationLevel2 = 30,
    @UpdateStatistics = 'ALL',
    @OnlyModifiedStatistics = 'Y';
```

The comma-separated values in `@FragmentationMedium` and `@FragmentationHigh` represent a priority list — IndexOptimize will attempt each method in order and fall back to the next if the preferred method isn't available (e.g., online rebuild requires Enterprise Edition).