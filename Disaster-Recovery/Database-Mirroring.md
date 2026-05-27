# Database Mirroring

## Purpose

Document database mirroring as a controlled migration tool for moving databases between SQL Server instances with minimal downtime. Mirroring is deprecated in SQL Server 2012 and later and is not used here as an ongoing HA solution — use log shipping for sustained DR. Its value is as a synchronous data-transfer mechanism for instance migrations: bring up the mirror, let it synchronize completely, then cut over with a known zero-data-loss state.

Always On Availability Groups is the preferred HA tool but requires Enterprise Edition licensing.

---

## Scope and Limitations

- Deprecated since SQL 2012; the setup wizard is removed from SQL Server 2022 but the underlying feature still functions via T-SQL.
- Requires **Standard Edition or higher** — Express Edition does not support mirroring.
- **High Safety (synchronous)** mode is the only mode to use for migrations — it guarantees zero data loss at cutover. High Performance (asynchronous) mode is not appropriate for this use case.
- Supports only one-to-one database pairing. For multiple databases, configure mirroring independently per database — there is no group failover.
- Requires **FULL** recovery model on the principal database. Simple-recovery databases cannot be mirrored.
- SQL Server 2022 targets: the mirroring endpoint must be created via T-SQL. SSMS may not expose the mirroring wizard on 2022 instances.
- Port 5022 must be open bidirectionally between principal and mirror.

---

## Prerequisites

- [ ] Both instances are running and reachable on port 5022
- [ ] Database is in FULL recovery model on the principal
- [ ] Service accounts on both instances have `CONNECT` permission on each other's mirroring endpoints
- [ ] A full backup of the database has been taken and is available for restore
- [ ] The database does not rely on objects that exist only on the principal (linked servers, cross-database queries) that would be unavailable on the mirror after cutover — document and resolve these before starting

```powershell
# Check recovery model on migration candidates
$splatRec = @{
    SqlInstance     = $principal
    EnableException = $true
}
Get-DbaDatabase @splatRec |
    Where-Object RecoveryModel -ne 'Full' |
    Select-Object SqlInstance, Name, RecoveryModel

# Check for existing mirroring endpoints
Get-DbaMirroringEndpoint -SqlInstance $principal
Get-DbaMirroringEndpoint -SqlInstance $mirror
```

---

## Setup Procedure (Migration Pattern)

### Step 1 — Create Mirroring Endpoints

```powershell
# Create endpoint on principal (if not already present)
$splatEpPrincipal = @{
    SqlInstance     = $principal
    Port            = 5022
    EnableException = $true
}
New-DbaMirroringEndpoint @splatEpPrincipal

# Create endpoint on mirror
$splatEpMirror = @{
    SqlInstance     = $mirror
    Port            = 5022
    EnableException = $true
}
New-DbaMirroringEndpoint @splatEpMirror
```

### Step 2 — Backup and Restore to Mirror

Take a full backup on the principal and restore it on the mirror with `NORECOVERY`. The mirror database must stay in `NORECOVERY` — do not bring it online.

```powershell
# Backup on principal (COPY_ONLY to preserve log chain if log shipping is also active)
$splatBackup = @{
    SqlInstance     = $principal
    Database        = $database
    Type            = 'Full'
    CopyOnly        = $true
    CompressBackup  = $true
    Checksum        = $true
    BackupDirectory = $backupPath
    EnableException = $true
}
Backup-DbaDatabase @splatBackup

# Restore on mirror WITH NORECOVERY
$splatRestore = @{
    SqlInstance     = $mirror
    Path            = $backupPath
    WithReplace     = $true
    NoRecovery      = $true
    EnableException = $true
}
Restore-DbaDatabase @splatRestore
```

Apply any transaction log backups taken after the full backup, also with `NORECOVERY`, before starting mirroring.

### Step 3 — Configure Mirroring

```powershell
$splatMirror = @{
    Primary         = $principal
    Mirror          = $mirror
    Database        = $database
    SafetyLevel     = 'Full'       # Full = synchronous (High Safety)
    EnableException = $true
}
Invoke-DbaMirroringSetup @splatMirror
```

### Step 4 — Verify Mirroring State

```powershell
Get-DbaMirror -SqlInstance $principal |
    Select-Object SqlInstance, DatabaseName, MirroringState, MirroringRole, MirroringSafetyLevel
```

Expected state: `SYNCHRONIZED` on both principal and mirror. If state is `SYNCHRONIZING`, the mirror is still catching up — wait for `SYNCHRONIZED` before any cutover planning.

---

## Monitoring Before Cutover

The redo queue (`mirroring_redo_queue_kb`) represents how much data the mirror still needs to apply. It must reach and sustain 0 KB before cutover is safe.

```sql
SET NOCOUNT ON;

SELECT
    [database_id],
    DB_NAME([database_id])          AS [database],
    [mirroring_state_desc],
    [mirroring_role_desc],
    [mirroring_safety_level_desc],
    [mirroring_redo_queue_kb],
    [mirroring_send_queue_kb]
FROM [sys].[database_mirroring]
WHERE [mirroring_state] IS NOT NULL;
```

A redo queue that is not dropping toward 0 under normal load indicates a performance bottleneck on the mirror — investigate mirror disk I/O before scheduling a cutover.

---

## Migration Cutover Procedure

> Coordinate user notifications and application downtime before starting.

1. Confirm `mirroring_redo_queue_kb = 0` and state is `SYNCHRONIZED`.
2. Stop application traffic to the principal database. Verify no active connections remain:

```sql
SET NOCOUNT ON;

SELECT [session_id], [login_name], [host_name], [program_name]
FROM [sys].[dm_exec_sessions]
WHERE [database_id] = DB_ID(N'DatabaseName')
  AND [session_id]  <> @@SPID;
```

3. Failover — run on the **principal**:

```sql
ALTER DATABASE [DatabaseName] SET PARTNER FAILOVER;
```

The former mirror is now the principal. The former principal enters a `SUSPENDED` state.

4. Verify the new principal:

```sql
SET NOCOUNT ON;

-- Run on the new principal (former mirror)
SELECT
    DB_NAME([database_id])  AS [database],
    [mirroring_role_desc],
    [mirroring_state_desc]
FROM [sys].[database_mirroring]
WHERE [mirroring_state] IS NOT NULL;
```

5. Update application connection strings to point to the new instance. Restart application services as needed.

6. Confirm application connectivity and run a smoke test.

7. Break mirroring once cutover is confirmed — run on the **new principal**:

```sql
ALTER DATABASE [DatabaseName] SET PARTNER OFF;
```

8. Recover the former principal if the server will be reused:

```sql
-- Run on the former principal (now suspended)
RESTORE DATABASE [DatabaseName] WITH RECOVERY;
```

---

## Related Documents

- [Log Shipping Setup](LogShipping.md) — preferred ongoing DR approach
- [Log Shipping Failover](LogShippingFailover.md) — log shipping failover and failback
