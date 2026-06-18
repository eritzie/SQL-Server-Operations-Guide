# Always On Availability Groups

## Purpose

Document the setup, operation, and failover procedures for SQL Server Always On Availability Groups (AGs). AGs provide automatic failover, readable secondaries (Enterprise Edition only), and a unified listener endpoint that abstracts the underlying replica from application connection strings.

This document covers both **Basic Availability Groups** (Standard Edition) and **full Availability Groups** (Enterprise Edition). The edition determines what you can do — read the capability matrix first.

---

## Edition Capability Matrix

| Capability | Basic AG (Standard Edition) | Full AG (Enterprise Edition) |
|---|---|---|
| Max replicas | 2 (1 primary + 1 secondary) | 9 (1 primary + 8 secondaries) |
| Databases per AG | **1 per AG** | Multiple |
| Readable secondary | **No** — secondary is passive | Yes — with read-intent routing |
| Automatic seeding | **No** — manual backup/restore required | Yes |
| Distributed AGs | **No** | Yes |
| Multiple listeners | **No** — one listener, one AG | Yes |
| Online secondary during failover | No — brief unavailability | Yes (synchronous replicas) |
| In-memory OLTP databases | **No** | Yes |
| Contained AG (SQL Server 2022+) | **No** | Yes — Enterprise only |

**Basic AG is essentially a managed, two-node log shipping replacement with automatic failover.** It provides high availability without Enterprise Edition licensing, but at the cost of flexibility. If a database needs more than one secondary, a readable replica, or a distributed architecture, Enterprise Edition is required.

---

## HA vs. DR Topology

| Configuration | RPO | RTO | Failover Type | Typical Use |
|---|---|---|---|---|
| Synchronous replica, same datacenter | Zero data loss | Seconds (automatic) | Automatic or manual | **HA** — primary use case |
| Asynchronous replica, remote datacenter | Potential data loss (latency-dependent) | Minutes (manual) | Manual forced failover | **DR** — secondary use case |
| Synchronous replica, remote datacenter | Zero data loss | Seconds to minutes | Manual (recommended) or automatic | **HA + DR** — requires very low WAN latency |

Basic AG supports one secondary, so it can serve either HA or DR, but not both simultaneously.

---

## Prerequisites

**Both editions:**

- [ ] Windows Server Failover Cluster (WSFC) configured — see [[../Clustering/Windows-Cluster-Setup|Windows Cluster Setup]]
- [ ] All AG databases in **FULL** recovery model
- [ ] SQL Server service accounts have `CONNECT` permission on each other's database mirroring endpoints (port 5022)
- [ ] SQL Server Agent running on all replicas
- [ ] All replicas running the same SQL Server edition and a supported version combination

**Enterprise Edition only:**

- [ ] Enterprise Edition license on all replicas that will host readable secondaries or participate in distributed AGs

```powershell
# Verify recovery model on AG database candidates
$splatRec = @{
    SqlInstance     = $primary
    EnableException = $true
}
Get-DbaDatabase @splatRec |
    Where-Object { $_.RecoveryModel -ne 'Full' -and $_.Name -notin 'master','model','msdb','tempdb' } |
    Select-Object SqlInstance, Name, RecoveryModel

# Check for existing AG endpoints
Get-DbaEndpoint -SqlInstance $primary   | Where-Object EndpointType -eq 'DatabaseMirroring'
Get-DbaEndpoint -SqlInstance $secondary | Where-Object EndpointType -eq 'DatabaseMirroring'
```

---

## Setup

### Step 1 — Create Database Mirroring Endpoints

Required on both replicas before AG creation:

```powershell
$splatEpPrimary = @{
    SqlInstance     = $primary
    Port            = 5022
    EnableException = $true
}
New-DbaEndpoint @splatEpPrimary -Type DatabaseMirroring

$splatEpSecondary = @{
    SqlInstance     = $secondary
    Port            = 5022
    EnableException = $true
}
New-DbaEndpoint @splatEpSecondary -Type DatabaseMirroring
```

### Step 2 — Basic AG Setup (Standard Edition)

One AG per database. Repeat for each database that requires AG protection.

```powershell
$splatBasicAg = @{
    Primary             = $primary
    Secondary           = $secondary
    Name                = 'AG_OrderManagement'
    Database            = 'OrderManagement'
    Basic               = $true                 # Required flag for Standard Edition
    FailoverMode        = 'Automatic'
    AvailabilityMode    = 'SynchronousCommit'
    Listener            = 'AG-OrderMgmt'
    ListenerPort        = 1433
    EnableException     = $true
}
New-DbaAvailabilityGroup @splatBasicAg
```

> **Warning:** Do not omit `-Basic` on Standard Edition. Creating a full AG on Standard Edition is unsupported and will produce an error during setup or licensing audit.

### Step 3 — Full AG Setup (Enterprise Edition)

Multiple databases per AG. Readable secondaries and more than two replicas are available.

```powershell
$splatFullAg = @{
    Primary             = $primary
    Secondary           = $secondary
    Name                = 'AG_Production'
    Database            = 'OrderManagement', 'CustomerPortal', 'Inventory'
    FailoverMode        = 'Automatic'
    AvailabilityMode    = 'SynchronousCommit'
    Listener            = 'AG-Production'
    ListenerPort        = 1433
    ReadonlyRoutingList = $secondary
    EnableException     = $true
}
New-DbaAvailabilityGroup @splatFullAg
```

For asynchronous (DR) replicas, change `AvailabilityMode = 'AsynchronousCommit'` and `FailoverMode = 'Manual'`.

---

## Seeding

**Basic AG (manual seeding only):** dbatools handles the backup and restore automatically when `-Basic` is specified in `New-DbaAvailabilityGroup`.

**Full AG (automatic or manual):**

```powershell
$splatSeed = @{
    SqlInstance       = $primary
    AvailabilityGroup = 'AG_Production'
    Database          = 'NewDatabase'
    SeedingMode       = 'Automatic'
    EnableException   = $true
}
Add-DbaAgDatabase @splatSeed
```

Automatic seeding streams the database directly from primary to secondary. It requires the secondary data directory to exist and be accessible by the SQL Server service account.

---

## Failover

### Automatic Failover

Occurs when WSFC determines the primary is unavailable and a synchronous secondary is configured for automatic failover. Verify the AG allows it:

```powershell
$splatReplica = @{
    SqlInstance       = $primary
    AvailabilityGroup = 'AG_Production'
    EnableException   = $true
}
Get-DbaAgReplica @splatReplica |
    Select-Object SqlInstance, Name, AvailabilityMode, FailoverMode, Role
```

Both replicas must show `FailoverMode = Automatic`.

### Planned Manual Failover (Zero Data Loss)

Run on the **current primary**:

```powershell
$splatFailover = @{
    SqlInstance       = $primary
    AvailabilityGroup = 'AG_Production'
    EnableException   = $true
}
Invoke-DbaAgFailover @splatFailover
```

Or via T-SQL on the **current primary**:

```sql
ALTER AVAILABILITY GROUP [AG_Production] FAILOVER;
```

### Forced Failover (Data Loss Risk)

Use only when the primary is unreachable and no synchronous secondary is available. Run on the **target secondary**:

```sql
-- WARNING: This may result in data loss if the secondary is not synchronized
ALTER AVAILABILITY GROUP [AG_Production] FORCE_FAILOVER_ALLOW_DATA_LOSS;
```

After a forced failover, the old primary will be in a `SUSPENDED` or `DISCONNECTED` state. Resolve any data loss before bringing it back online — the amount of divergence is visible in `drs.log_send_queue_size` from the monitoring DMV query above. Once reconciled, resume synchronization:

```sql
ALTER DATABASE [OrderManagement] SET HADR RESUME;
```

---

## Monitoring

```powershell
# Overall AG health
$splatAg = @{
    SqlInstance     = $primary
    EnableException = $true
}
Get-DbaAvailabilityGroup @splatAg |
    Select-Object SqlInstance, Name, PrimaryReplica, HealthState, SynchronizationHealthDescription

# Replica-level state
Get-DbaAgReplica -SqlInstance $primary |
    Select-Object AvailabilityGroup, Name, Role, AvailabilityMode, FailoverMode, ConnectionState, RollupSynchronizationState

# Database-level synchronization and queue sizes
Get-DbaAgDatabase -SqlInstance $primary |
    Select-Object AvailabilityGroup, Name, SynchronizationState, RedoQueueSize, LogSendQueueSize
```

Dashboard query — single view of all AG health:

```sql
SET NOCOUNT ON;

SELECT
    ag.[name]                               AS AvailabilityGroup,
    ar.[replica_server_name]                AS Replica,
    ars.[role_desc]                         AS Role,
    ars.[operational_state_desc]            AS OperationalState,
    ars.[synchronization_health_desc]       AS SyncHealth,
    drs.[synchronization_state_desc]        AS DbSyncState,
    drs.[redo_queue_size]                   AS RedoQueueKB,
    drs.[log_send_queue_size]               AS SendQueueKB,
    drs.[database_state_desc]               AS DatabaseState
FROM [sys].[availability_groups]                        AS ag
JOIN [sys].[availability_replicas]                      AS ar
    ON ag.[group_id] = ar.[group_id]
JOIN [sys].[dm_hadr_availability_replica_states]        AS ars
    ON ar.[replica_id] = ars.[replica_id]
LEFT JOIN [sys].[dm_hadr_database_replica_states]       AS drs
    ON ars.[replica_id] = drs.[replica_id]
ORDER BY ag.[name], ars.[role_desc] DESC;
```

---

## Server Object Synchronization

AGs protect databases but not instance-level objects. Logins, Agent jobs, linked servers, and credentials must be kept in sync manually — or automatically with SQL Server 2022 Contained AGs.

**Traditional approach (all versions):**

```powershell
$splatLogin = @{
    Source          = $primary
    Destination     = $secondary
    EnableException = $true
}
Copy-DbaLogin @splatLogin

$splatJobs = @{
    Source          = $primary
    Destination     = $secondary
    EnableException = $true
}
Copy-DbaAgentJob @splatJobs
```

Run these after any login or job changes on the primary, or schedule them as an Agent job.

**SQL Server 2022 Contained Availability Groups (Enterprise Edition only):**

A Contained AG includes a contained `master` database that stores logins and Agent jobs within the AG itself. After any failover, logins and jobs are available on the new primary automatically — no sync scripts required.

```sql
CREATE AVAILABILITY GROUP [AG_Production]
    WITH (CONTAINED)
    ...
```

See [[../Operations/SQL-2022-Readiness|SQL Server 2022 Readiness]] for Contained AG details.

---

## Related Documents

- [[../Clustering/Windows-Cluster-Setup|Windows Cluster Setup]] — WSFC prerequisite
- [[Log-Shipping-Setup|Log Shipping Setup]] — alternative HA/DR for Standard Edition without WSFC
- [[../Operations/SQL-2022-Readiness|SQL Server 2022 Readiness]] — Contained AG details
- [[../Operations/Monitoring|Monitoring]] — job monitoring and alerting
- [[Disaster-Recovery|Back to Disaster Recovery]]
