# Windows Failover Cluster Setup

> **Environment context:** These procedures were developed for building Windows Server Failover Clusters (WSFC) to support SQL Server Failover Cluster Instances (FCI) on Windows Server 2016+. The guidance focuses on the infrastructure preparation — disk layout, BIOS tuning, network configuration, and cluster creation — that precedes the SQL Server installation.

## Table of Contents

- [Disk Recommendations](#disk-recommendations)
- [Server Hardware Preparation](#server-hardware-preparation)
- [Active Directory Preparation](#active-directory-preparation)
- [Enable the Failover Clustering Feature](#enable-the-failover-clustering-feature)
- [Create the Windows Failover Cluster](#create-the-windows-failover-cluster)
- [Configure the Cluster Quorum](#configure-the-cluster-quorum)
- [Rename Cluster Resources](#rename-cluster-resources)
- [Post-Cluster Configuration](#post-cluster-configuration)

## Disk Recommendations

All disks should be initialized with **GPT** partition type to avoid the 2TB size limitation of MBR.

A mapped disk scheme is recommended for manageability — it uses a single drive letter mount point and is easier to maintain than assigning individual drive letters as disk count grows. The drive letter scheme below is a good starting point if mapped disks aren't feasible. The key is **consistency across all servers and environments**.

| Purpose | Drive | Label | Block Size | Suggested Size | Notes |
|---|---|---|---|---|---|
| Programs | E:\ | Programs | 4KB (default) | 450GB SSD | SQL Server binaries and tools |
| Scripts/Files | F:\ | FILE01 | 4KB (default) | 20GB | Maintenance scripts, output files |
| Data | H:\ | DATA01 | **64KB** | 700GB | SQL data files (.mdf, .ndf) |
| Logs | I:\ | LOG01 | **64KB** | 250GB | SQL log files (.ldf) |
| TempDB | T:\ | TEMPDB01 | **64KB** | 250GB | TempDB data files only; TempDB log goes on the Log disk |
| Backups | X:\ | BACKUP01 | 4KB (default) | 250GB | SQL backup files |
| Quorum | Q:\ | Quorum | 4KB (default) | 2GB | Cluster quorum witness |

The 64KB block size for Data, Log, and TempDB disks aligns with SQL Server's extent size (8 pages × 8KB = 64KB). See the [Performance Practices](PerformancePractices.md#disk-configurations) document for a detailed explanation of why this matters.

Verify disk configuration after setup:

```powershell
Test-DbaDiskAllocation -ComputerName ClusterNode01 | Select-Object * | Out-GridView
```

## Server Hardware Preparation

These BIOS and hardware settings should be configured on **all cluster nodes** before building the cluster.

**Disable Automatic System Recovery (ASR)** in the RBSU/BIOS settings. ASR can clear diagnostic data needed to determine the root cause of a failure — you want the crash dump preserved for analysis, not auto-cleared on reboot.

**Set CPU Power Management to Maximum Performance.** Power-saving modes introduce latency variability that can affect SQL Server response times and cluster heartbeat reliability.

**Set the BIOS clock source to local system time.** The OS should manage time synchronization via NTP/Windows Time Service, not the BIOS. Mixed time sources can cause cluster validation warnings and log correlation headaches.

## Active Directory Preparation

Pre-create the following objects in the target Active Directory OU before running the cluster creation wizard:

- **Cluster Name Object (CNO)** — the computer account for the cluster itself.
- **Virtual Computer Objects (VCO)** — one for each clustered role (e.g., the SQL Server FCI network name).

Set the CNO as the owner of the VCOs, then **disable** the VCOs. The cluster creation process will enable them when it takes ownership. Pre-creating and pre-permissioning these objects avoids the most common cluster creation failures related to AD permissions.

```powershell
# Verify the CNO and VCO exist and are in the expected OU
Get-ADComputer -Identity 'ClusterName' -Properties DistinguishedName, Enabled
Get-ADComputer -Identity 'SqlFciName' -Properties DistinguishedName, Enabled
```

## Enable the Failover Clustering Feature

The Failover Clustering feature must be installed on **every node** that will participate in the cluster.

```powershell
# Install on a single node
Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools

# Install on multiple nodes remotely
$nodes = @('ClusterNode01', 'ClusterNode02')
$nodes | ForEach-Object {
    Install-WindowsFeature -Name Failover-Clustering -IncludeManagementTools -ComputerName $_
}
```

A reboot may be required after installation.

## Create the Windows Failover Cluster

### Validate the Configuration

Always run the cluster validation wizard before creating the cluster. This catches hardware, network, and storage issues that would cause problems later.

```powershell
# Run all validation tests
Test-Cluster -Node ClusterNode01, ClusterNode02 -Verbose

# Review the validation report (HTML) — output path is displayed in the console
```

It's normal for the validation to return warnings, especially if shared storage is not yet presented or if you're using Storage Spaces Direct. **Errors** must be resolved before proceeding. Warnings should be reviewed and understood — the report will indicate if any are blocking.

### Create the Cluster

```powershell
New-Cluster -Name ClusterName -Node ClusterNode01, ClusterNode02 `
    -StaticAddress 10.0.0.50 -NoStorage
```

- `-StaticAddress` — the IP address for the cluster management endpoint. Use an IP on the LAN/client network, not the heartbeat network.
- `-NoStorage` — skips automatic storage import. Add storage deliberately after creation to maintain control over disk assignments.

Ensure the DNS and Active Directory entries for the cluster name resolve correctly after creation.

## Configure the Cluster Quorum

The quorum configuration determines how the cluster maintains consensus when nodes fail. The default is Node Majority, which works for two-node clusters with a witness.

For a two-node cluster, use a **file share witness** or **cloud witness** (Azure blob storage, available on Windows Server 2016+):

```powershell
# File share witness
Set-ClusterQuorum -NodeAndFileShareMajority '\\FileServer01\ClusterWitness'

# Cloud witness (Azure)
Set-ClusterQuorum -CloudWitness `
    -AccountName 'storageaccountname' `
    -AccessKey 'storageaccountkey' `
    -Endpoint 'core.windows.net'
```

If using a disk witness instead (requires shared storage):

```powershell
# The disk must already be added to the cluster
Set-ClusterQuorum -NodeAndDiskMajority 'Cluster Disk 1'
```

## Rename Cluster Resources

Rename shared storage resources and network adapters **before** installing SQL Server. Default names like "Cluster Disk 1" and "Cluster Network 1" are meaningless during troubleshooting at 2 AM.

### Shared Disks

Rename disks to match their purpose. The disk number in Failover Cluster Manager corresponds to the disk number in Disk Management — verify you're renaming the correct disk, especially when multiple disks share the same size.

```powershell
# List current cluster disks
Get-ClusterResource | Where-Object { $_.ResourceType -eq 'Physical Disk' } |
    Select-Object Name, State, OwnerGroup

# Rename a cluster disk
(Get-ClusterResource 'Cluster Disk 1').Name = 'DATA01'
(Get-ClusterResource 'Cluster Disk 2').Name = 'LOG01'
(Get-ClusterResource 'Cluster Disk 3').Name = 'TEMPDB01'
(Get-ClusterResource 'Cluster Disk 4').Name = 'BACKUP01'
```

### Cluster Networks

Rename network adapters to identify their purpose. The LAN adapter (Cluster and Client) carries client traffic. The heartbeat adapter (Cluster Only) carries intra-cluster communication.

```powershell
# List current cluster networks
Get-ClusterNetwork | Select-Object Name, Role, Address

# Rename
(Get-ClusterNetwork 'Cluster Network 1').Name = 'LAN'
(Get-ClusterNetwork 'Cluster Network 2').Name = 'Heartbeat'
```

Network roles:
- **Cluster and Client (Role = 3)** — LAN adapter. Carries client connections and cluster traffic.
- **Cluster Only (Role = 1)** — Heartbeat adapter. Carries only intra-cluster communication.
- **None (Role = 0)** — Excluded from cluster use (e.g., backup network, iSCSI).

## Post-Cluster Configuration

These settings should be applied on **all cluster nodes** after the cluster is built.

**Disable Volume Shadow Copy (VSS)** if not actively used. VSS snapshots on cluster shared disks can cause unexpected I/O latency and disk space consumption.

```powershell
Set-Service -Name VSS -StartupType Disabled -ComputerName ClusterNode01
Set-Service -Name VSS -StartupType Disabled -ComputerName ClusterNode02
```

**Configure the page file** to a fixed size. Auto-managed page files can grow unexpectedly and consume disk space on the OS drive. A fixed size of 30GB is a common starting point for servers with 128GB+ RAM, but the right size depends on your memory dump configuration.

**Set the OS to optimize for background services.** Under Advanced System Settings → Performance → Advanced tab → Processor Scheduling, select "Background services."

**Configure memory dump to Full Dump.** Under Advanced System Settings → Startup and Recovery, set the dump type to Complete Memory Dump. Kernel dumps are smaller but may not capture enough state for cluster-related failures.

**Verify firewall rules.** Ensure the following ports are open in the Windows Firewall for inbound traffic:

| Port | Protocol | Purpose |
|---|---|---|
| 1433 | TCP | SQL Server default instance |
| 5022 | TCP | Database mirroring / AG endpoint |
| 1434 | UDP | SQL Browser (disable if not needed) |

If a non-default port is used for SQL Server (recommended for security — see [Security Practices](Security.md)), substitute that port for 1433 and ensure the firewall rules match.

```powershell
# Verify existing SQL-related firewall rules
Get-NetFirewallRule | Where-Object { $_.DisplayName -like '*SQL*' } |
    Get-NetFirewallPortFilter | Select-Object Protocol, LocalPort
```

**Set TCP autotuning to normal:**

```powershell
netsh int tcp set global autotuninglevel=normal

# Verify
netsh int tcp show global
```

**Set OS power plan to High Performance:**

```powershell
powercfg /setactive SCHEME_MIN

# Verify
powercfg /getactivescheme
```

After completing all configuration, proceed to [SQL Server Cluster Installation](SQLClusterInstallation.md).