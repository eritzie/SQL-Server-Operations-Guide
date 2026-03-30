# SQL Server Failover Cluster Instance Installation

> **Environment context:** These procedures cover installing SQL Server on a Windows Server Failover Cluster as a Failover Cluster Instance (FCI). The WSFC must already be built and configured before proceeding — see [Windows Failover Cluster Setup](WindowsClusterSetup.md).

## Table of Contents

- [Prerequisites](#prerequisites)
- [Install SQL Server on the Initial Node](#install-sql-server-on-the-initial-node)
- [Add the Secondary Node](#add-the-secondary-node)
- [Post-Installation Configuration](#post-installation-configuration)
- [Additional Components](#additional-components)

## Prerequisites

Before launching the SQL Server installer, confirm:

- The WSFC is built, validated, and healthy. All nodes show as **Up** in Failover Cluster Manager.
- Shared disks are presented, renamed, and formatted correctly (64KB for Data/Log/TempDB).
- The SQL Server service account (domain account) is created and has local admin rights on all nodes.
- The Cluster Name Object (CNO) owns the Virtual Computer Object (VCO) for the SQL Server network name in Active Directory.
- Firewall rules are in place for the SQL Server port on all nodes.

```powershell
# Quick cluster health check
Get-ClusterNode | Select-Object Name, State
Get-ClusterResource | Select-Object Name, State, ResourceType, OwnerGroup
Test-DbaDiskAllocation -ComputerName ClusterNode01 | Select-Object * | Out-GridView
```

## Install SQL Server on the Initial Node

Launch `Setup.exe` and select **New SQL Server failover cluster installation** from the Installation blade.

The installer walks through product key, license, feature selection, and cluster configuration. The key decisions during installation are documented below — the rest of the wizard is standard click-through.

### Feature Selection

At a minimum, select:

- **Database Engine Services** — the core SQL Server engine.
- **Client Tools Connectivity** — required for remote management tools to connect.

Only install SSIS, SSAS, or Full-Text Search if there is a confirmed need. Each additional feature increases the attack surface and consumes resources.

### Instance Configuration

Provide the **SQL Server Network Name** — this is the virtual name that clients will use to connect. It must match the VCO pre-created in Active Directory.

Use a **Default Instance** unless a named instance is specifically required. Named instances add complexity (SQL Browser dependency, dynamic ports) that is rarely justified unless multiple instances will run on the same cluster.

### Cluster Disk Selection

Select the shared disks that were prepared during WSFC setup. At minimum: Data, Log, TempDB, and Backup disks. The installer will add these as dependencies for the SQL Server cluster resource group.

### Network Configuration

Enter the static IP address and subnet mask for the SQL Server FCI. This IP must be on the LAN/client network — not the heartbeat network. Deselect the DHCP checkbox; cluster IPs should always be static.

### Service Accounts

Use a **domain service account** for the SQL Server Database Engine and SQL Server Agent services. Both should use the same account unless security requirements dictate separation.

Check **Grant Perform Volume Maintenance Task** to enable Instant File Initialization — see [Performance Practices](PerformancePractices.md#instant-file-initialization) for why this matters.

### Server Configuration

Select **Mixed Mode** authentication and set a strong SA password. Even though the SA account should be disabled post-installation (see [Security Practices](Security.md)), a strong password is required during setup.

Add the SQL Server service account and the **Database Admins** security group to the SQL Server Administrators list.

### Data Directories

Map each directory to the appropriate shared disk. This is one of the most critical configuration steps — getting it wrong means data and log files land on the same disk, killing performance.

| Directory | Target Disk | Example Path |
|---|---|---|
| Data root directory | Data disk | H:\Data01 |
| User database directory | Data disk | H:\Data01 |
| User database log directory | Log disk | I:\Log01 |
| Backup directory | Backup disk | X:\Backup01 |

### TempDB Configuration

On the TempDB tab:

- **Data directories:** Point to the TempDB disk (T:\TempDB01). Remove the default directory if it points elsewhere.
- **Log directory:** Point to the Log disk (I:\Log01). TempDB log files go with the other log files, not on the TempDB data disk.
- **Number of files:** The installer will default to a number based on processor count (up to 8). Accept this or adjust per [Performance Practices](PerformancePractices.md#tempdb-configuration).

After reviewing the summary, click **Install**. At completion, verify in Failover Cluster Manager that SQL Server (MSSQLSERVER) appears under Roles and all dependencies show as **Online**.

## Add the Secondary Node

On the second cluster node, launch `Setup.exe` and select **Add node to a SQL Server failover cluster** from the Installation blade.

The wizard will detect the existing FCI configuration. Verify the instance information is correct, provide the same service account credentials used on the first node, and check **Grant Perform Volume Maintenance Task** again.

After installation completes, verify:

```powershell
# Confirm both nodes are registered as possible owners
Get-ClusterGroup 'SQL Server (MSSQLSERVER)' | Get-ClusterResource |
    Select-Object Name, State, OwnerNode

# Validate by performing a manual failover
Move-ClusterGroup 'SQL Server (MSSQLSERVER)' -Node ClusterNode02

# Verify SQL Server is accessible on the new node
Test-DbaConnection -SqlInstance SqlFciName

# Fail back to the original node
Move-ClusterGroup 'SQL Server (MSSQLSERVER)' -Node ClusterNode01
```

## Post-Installation Configuration

### Max Server Memory

Configure max memory immediately. The default is 2,147,483,647 MB (all available memory), which will starve the OS.

```powershell
# Check the recommendation
Test-DbaMaxMemory -SqlInstance SqlFciName

# Apply it
Set-DbaMaxMemory -SqlInstance SqlFciName -Max <RecommendedValueMB>
```

Leave at least **15% of total memory for the OS**. If SSRS or SSIS are installed on the same cluster, increase that to **20–25%**. See [Performance Practices](PerformancePractices.md#max-server-memory) for details.

### TempDB File Sizing

Pre-allocate TempDB data files to equal sizes that consume most of the TempDB disk. This avoids autogrowth events during production workloads.

```powershell
# Audit current TempDB configuration against best practices
Test-DbaTempDbConfig -SqlInstance SqlFciName | Select-Object * | Out-GridView
```

All data files must be the same size with the same autogrowth increment. See [Performance Practices](PerformancePractices.md#tempdb-configuration) for the full set of recommendations.

### MAXDOP and Cost Threshold for Parallelism

```powershell
# Check recommended MAXDOP
Test-DbaMaxDop -SqlInstance SqlFciName | Select-Object *

# Apply it
Set-DbaMaxDop -SqlInstance SqlFciName -MaxDop <RecommendedValue>

# Set Cost Threshold for Parallelism (default of 5 is too low)
Set-DbaSpConfigure -SqlInstance SqlFciName -Name CostThresholdForParallelism -Value 50
```

### Install Utility Stored Procedures

Install the following community tools for monitoring, troubleshooting, and index analysis:

- [Brent Ozar's First Responder Kit](https://www.brentozar.com/first-aid/) — includes sp_Blitz, sp_BlitzIndex, sp_BlitzCache, sp_BlitzFirst, and sp_BlitzWho.
- [sp_WhoIsActive](http://whoisactive.com/) — real-time activity monitoring.
- [Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/) — backup, index, and statistics maintenance.

```powershell
# Install the First Responder Kit via dbatools
Install-DbaFirstResponderKit -SqlInstance SqlFciName -Database master

# Install sp_WhoIsActive
Install-DbaWhoIsActive -SqlInstance SqlFciName -Database master

# Install Ola Hallengren's Maintenance Solution
Install-DbaMaintenanceSolution -SqlInstance SqlFciName -Database master `
    -InstallJobs -CleanupTime 168 -LogToTable
```

### Disable the SA Account

```powershell
# Rename and disable the SA account
$query = @"
ALTER LOGIN [sa] WITH NAME = [DisabledSA];
ALTER LOGIN [DisabledSA] DISABLE;
"@
Invoke-DbaQuery -SqlInstance SqlFciName -Query $query
```

### Verify the Installation

Run a comprehensive check to confirm everything is configured correctly:

```powershell
# Overall instance configuration audit
$results = @()

# Memory
$results += Test-DbaMaxMemory -SqlInstance SqlFciName
# MAXDOP
$results += Test-DbaMaxDop -SqlInstance SqlFciName
# TempDB
$results += Test-DbaTempDbConfig -SqlInstance SqlFciName
# Disk allocation
$results += Test-DbaDiskAllocation -ComputerName ClusterNode01

$results | Out-GridView

# Connectivity test
Test-DbaConnection -SqlInstance SqlFciName
```

## Additional Components

Starting with SQL Server 2016, SSMS and SSRS are separate downloads from the SQL Server installer.

**SQL Server Management Studio (SSMS):** Download the latest version from Microsoft. SSMS is now version-independent — a single current release works with SQL Server 2012 through the latest version.

> [Download SQL Server Management Studio (SSMS)](https://learn.microsoft.com/en-us/sql/ssms/download-sql-server-management-studio-ssms)

**SQL Server Reporting Services (SSRS):** If SSRS is needed, download and install it separately. The installer is independent of the SQL Server version.

> [Download SQL Server Reporting Services](https://www.microsoft.com/en-us/download/details.aspx?id=100122)

**SQL Server Integration Services (SSIS):** SSIS is still installed through the main SQL Server installer — check the feature during initial setup. If developing SSIS packages, install SQL Server Data Tools (SSDT) as a Visual Studio extension.

> [Download SQL Server Data Tools (SSDT)](https://learn.microsoft.com/en-us/sql/ssdt/download-sql-server-data-tools-ssdt)

> **Note:** SSMS, SSRS, and SSDT follow their own release cadences. Always install the latest available version regardless of which SQL Server version the instance runs.