# SQL Server Standalone Installation

## Purpose

Step-by-step guide for installing and hardening a standalone SQL Server instance. Covers pre-installation OS preparation, installation configuration, and post-installation settings. For Failover Cluster Instance installation, see [[../Clustering/Windows-Cluster-Setup|Windows Cluster Setup]] and [[../Clustering/SQL-Cluster-Installation|SQL Server Cluster Installation]].

---

## Pre-Installation Checklist

Complete all of the following before running SQL Server Setup. Installation mistakes (wrong collation, wrong directories, wrong service accounts) are expensive to fix after the fact.

### OS Configuration

```powershell
# Verify Windows version and edition
Get-ComputerInfo | Select-Object WindowsProductName, OsVersion, TotalPhysicalMemory

# Power plan — SQL Server requires High Performance, not Balanced
# Balanced throttles CPU frequency, which degrades query performance
powercfg -setactive 8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c

# Verify the active plan
powercfg -getactivescheme
```

**Disk configuration:** Format all SQL Server data volumes with 64 KB allocation unit size. The default 4 KB NTFS cluster size causes excessive I/O for SQL Server's 64 KB and 128 KB write patterns.

```powershell
# Check current allocation unit size (target: Bytes Per Cluster : 65536)
fsutil fsinfo ntfsinfo D: | Select-String "Bytes Per Cluster"

# Format a new volume at 64 KB
Format-Volume -DriveLetter D -FileSystem NTFS -AllocationUnitSize 65536 -NewFileSystemLabel 'SQLData' -Confirm:$false
```

**Recommended disk layout:**

| Volume | Purpose | Notes |
|---|---|---|
| C: | OS only | Do not put SQL Server binaries or data here |
| D: | SQL data files (.mdf, .ndf) | Separate from logs |
| L: | SQL log files (.ldf) | Sequential write, benefits from isolation |
| T: | TempDB data and log | High I/O — isolate from user databases |
| B: (or UNC share) | Backups | Never on the same spindle as data |

TempDB on its own volume is especially important on high-concurrency servers. Version store and sort spills go to TempDB — contention here affects the entire instance.

### Antivirus Exclusions

Configure antivirus to exclude SQL Server file types and directories before installation. Scanning SQL data files mid-write causes I/O errors and corruption.

Exclude from real-time scanning:
- All `.mdf`, `.ndf`, `.ldf` files
- All `.bak`, `.trn` backup files
- SQL Server binary directory (`C:\Program Files\Microsoft SQL Server\`)
- TempDB directory
- SQL Server error log directory

### Service Accounts

Create service accounts in Active Directory before running Setup. SQL Server Setup cannot create domain accounts.

| Service | Account | Type |
|---|---|---|
| SQL Server Engine | `svc-sql-<host>` | gMSA (preferred) or domain account |
| SQL Server Agent | `svc-sqlagent-<host>` | gMSA (preferred) or domain account |
| SSRS (if installing) | `svc-ssrs-<host>` | Domain account — gMSA not supported |
| SSIS (if installing) | `svc-ssis-<host>` | gMSA (preferred) or domain account |

See [[../Security/Security-Practices|Security Practices]] for gMSA setup. For gMSA accounts, enter `DOMAIN\svc-sql-host$` (trailing `$`) in Setup and leave the password blank.

### Firewall

```powershell
# Open SQL Server default port
New-NetFirewallRule -DisplayName 'SQL Server' -Direction Inbound -Protocol TCP -LocalPort 1433 -Action Allow

# SQL Server Browser — needed only for named instances with dynamic ports
New-NetFirewallRule -DisplayName 'SQL Server Browser' -Direction Inbound -Protocol UDP -LocalPort 1434 -Action Allow

# DAC port — restrict to DBA management hosts only
New-NetFirewallRule -DisplayName 'SQL Server DAC' -Direction Inbound -Protocol TCP -LocalPort 1434 -Action Allow -RemoteAddress '10.0.0.0/24'
```

---

## Installation

### Feature Selection

Install only features that are actively used. Every installed feature is an attack surface and adds maintenance overhead.

| Feature | Install? | Notes |
|---|---|---|
| Database Engine Services | Always | The core engine |
| SQL Server Replication | Only if needed | Adds replication system tables to every database |
| Full-Text and Semantic Search | Only if needed | Consumes memory even when idle |
| SQL Server Agent | Always | Required for maintenance jobs, backups, and monitoring |
| SQL Server Browser | Named instances only | Disable after install on default instances |
| SSRS | Separate installer (2017+) | Do not install on the same server as the engine unless resources are dedicated |
| SSIS | Only if this server runs ETL | SSIS is a runtime, not tied to a specific database |
| Management Tools | No | Install SSMS separately on management workstations |

### Collation

Set collation during Setup — changing it afterward requires rebuilding the system databases.

- **`SQL_Latin1_General_CP1_CI_AS`** — case-insensitive, accent-sensitive, matches SQL Server system object collation. Use this unless the application has documented requirements for a different collation.
- **`Latin1_General_100_CI_AS_SC`** — supplementary character aware; use for environments with multilingual data.

Do not use case-sensitive collations (`_CS_`) unless the application explicitly requires it.

### Data Directories

Set these during Setup. Accept no defaults for data file locations.

| Setting | Value |
|---|---|
| Data root directory | `D:\MSSQL` |
| User database directory | `D:\MSSQL\Data` |
| User database log directory | `L:\MSSQL\Logs` |
| TempDB data directory | `T:\MSSQL\TempDB` |
| TempDB log directory | `T:\MSSQL\TempDB` |
| Backup directory | `B:\MSSQL\Backups` (or UNC share) |

### TempDB Configuration

SQL Server 2016+ Setup allows configuring TempDB file count during installation. Set the number of TempDB data files to match the number of logical CPU cores, up to 8. All files must be the same initial size with equal growth increments — unequal files cause proportional fill to route all allocations to the larger file.

### Authentication Mode

Select **Windows Authentication Mode** only. Mixed Mode enables SQL logins by default, including SA with a password. Add SQL logins explicitly after installation only if applications require them.

---

## Post-Installation Configuration

Apply all of the following immediately after installation. Do not connect applications to a newly installed instance before this is complete.

```powershell
$instance = 'SqlServer01'   # replace with actual instance name

# Max Server Memory — set to ~80% of RAM; tune based on server role and total RAM
$totalRamMb = (Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1MB
$splatMem = @{
    SqlInstance     = $instance
    Max             = [int]($totalRamMb * 0.80)
    EnableException = $true
}
Set-DbaMaxMemory @splatMem

# MAXDOP — starting point for single NUMA node: half of logical CPUs, max 8
$splatMaxdop = @{
    SqlInstance     = $instance
    Name            = 'MaxDegreeOfParallelism'
    Value           = 4
    EnableException = $true
}
Set-DbaSpConfigure @splatMaxdop

# Cost Threshold for Parallelism — 50 is a reasonable starting point for OLTP
$splatCtfp = @{
    SqlInstance     = $instance
    Name            = 'CostThresholdForParallelism'
    Value           = 50
    EnableException = $true
}
Set-DbaSpConfigure @splatCtfp

# Backup compression default
$splatBackupComp = @{
    SqlInstance     = $instance
    Name            = 'DefaultBackupCompression'
    Value           = 1
    EnableException = $true
}
Set-DbaSpConfigure @splatBackupComp

# Optimize for ad hoc workloads
$splatAdHoc = @{
    SqlInstance     = $instance
    Name            = 'OptimizeForAdHocWorkloads'
    Value           = 1
    EnableException = $true
}
Set-DbaSpConfigure @splatAdHoc

# Remote DAC — allows emergency connections when the instance is unresponsive
$splatDac = @{
    SqlInstance     = $instance
    Name            = 'RemoteDacConnectionsEnabled'
    Value           = 1
    EnableException = $true
}
Set-DbaSpConfigure @splatDac
```

### Security Hardening

```powershell
# Disable and rename SA account
$splatSa = @{
    SqlInstance     = $instance
    Login           = 'sa'
    NewName         = 'DisabledSA'
    Disable         = $true
    EnableException = $true
}
Rename-DbaLogin @splatSa

# Disable xp_cmdshell
$splatXp = @{
    SqlInstance     = $instance
    Name            = 'xp_cmdshell'
    Value           = 0
    EnableException = $true
}
Set-DbaSpConfigure @splatXp

# Disable OLE Automation Procedures
$splatOle = @{
    SqlInstance     = $instance
    Name            = 'Ole Automation Procedures'
    Value           = 0
    EnableException = $true
}
Set-DbaSpConfigure @splatOle
```

### SQL Server Agent Configuration

```powershell
# Set Agent to auto-start
$splatAgent = @{
    ComputerName    = $instance
    ServiceName     = 'SQLSERVERAGENT'
    StartType       = 'Automatic'
    EnableException = $true
}
Set-DbaService @splatAgent

Start-DbaService -ComputerName $instance -ServiceName 'SQLSERVERAGENT'

# Increase history retention (default 1000 rows per job is too low)
$splatHistory = @{
    SqlInstance           = $instance
    MaximumHistoryRows    = 10000
    MaximumJobHistoryRows = 500
    EnableException       = $true
}
Set-DbaAgentServer @splatHistory
```

### Instant File Initialization

IFI allows SQL Server to skip zeroing data file pages during growth events, significantly reducing growth latency. Grant it by adding the SQL Server service account to the `Perform Volume Maintenance Tasks` local security policy.

```powershell
$splatIfi = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaPrivilege @splatIfi | Where-Object Privilege -eq 'SeManageVolumePrivilege'
```

If not enabled, grant via `secpol.msc` → Local Policies → User Rights Assignment → Perform volume maintenance tasks → add the SQL Server service account. Restart the SQL Server service.

### TLS Configuration

Configure a CA-issued certificate before opening the instance to applications. See [[../Security/TLS-Configuration|TLS Configuration]] for the full procedure.

---

## Verification

```powershell
$instance = 'SqlServer01'

# Instance version, edition, and collation
Get-DbaInstanceProperty -SqlInstance $instance |
    Where-Object Name -in 'ProductVersion', 'Edition', 'Collation' |
    Select-Object Name, Value

# Key configuration settings
$splatCfg = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaSpConfigure @splatCfg |
    Where-Object Name -in 'max server memory (MB)', 'max degree of parallelism',
                          'cost threshold for parallelism', 'backup compression default',
                          'optimize for ad hoc workloads', 'xp_cmdshell', 'remote admin connections' |
    Select-Object Name, ConfiguredValue, RunningValue

# SA is disabled
Get-DbaLogin -SqlInstance $instance |
    Where-Object { $_.Sid -eq 0x01 } |
    Select-Object Name, IsDisabled

# Agent is running
Get-DbaService -ComputerName $instance -Type Agent |
    Select-Object ServiceName, State, StartMode

# Test backup path and compression
$splatBackup = @{
    SqlInstance     = $instance
    Database        = 'master'
    Type            = 'Full'
    BackupDirectory = 'B:\MSSQL\Backups'
    CompressBackup  = $true
    EnableException = $true
}
Backup-DbaDatabase @splatBackup
```

```sql
SET NOCOUNT ON;

-- Verify database file locations are on the correct volumes
SELECT
    [db].[name]             AS DatabaseName,
    [mf].[type_desc]        AS FileType,
    [mf].[physical_name]    AS PhysicalPath,
    [mf].[size] * 8 / 1024  AS SizeMB
FROM [sys].[master_files]   AS mf
JOIN [sys].[databases]      AS db
    ON mf.[database_id] = db.[database_id]
ORDER BY [db].[name], [mf].[type_desc];
```

---

## Related Documents

- [[../Performance/Performance-Practices|Performance Practices]] — MAXDOP, Max Server Memory, TempDB, and IFI detail
- [[../Security/Security-Practices|Security Practices]] — SA hardening, surface area reduction, gMSA setup
- [[../Security/TLS-Configuration|TLS Configuration]] — certificate installation and encryption enforcement
- [[Backup-and-Restore|Backup and Restore]] — backup schedule and verification
- [[../Clustering/Windows-Cluster-Setup|Windows Cluster Setup]] — FCI alternative to standalone installation
- [[Operations|Back to Operations]]
