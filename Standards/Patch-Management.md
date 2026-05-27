# Patch Management

## Purpose

Define the process for applying SQL Server Cumulative Updates (CUs) across all environments. This process must be followed for all production instances regardless of CU severity.

---

## Current Build Inventory

Before any patching work, collect current build numbers across all instances:

```powershell
$splatBuild = @{
    SqlInstance     = $instances
    Property        = 'BuildNumber', 'BuildClr', 'VersionString', 'Edition'
    EnableException = $true
}
Get-DbaInstanceProperty @splatBuild |
    Select-Object SqlInstance, PropertyName, Value |
    Sort-Object SqlInstance, PropertyName
```

Cross-reference build numbers against the [SQL Server Build Reference](https://sqlserverbuilds.blogspot.com) to determine current patch level for each instance.

```powershell
# Quick pending-update check via dbatools
Test-DbaBuild -SqlInstance $instances
```

---

## Change Control Gate

All CU applications to production instances require:

1. Documented change approval with a rollback plan.
2. CU applied to test instances first.
3. Minimum two-week soak period on test before production.
4. Health validation completed during the soak period — see Post-Patch Validation below.
5. Maintenance window scheduled — SQL Server services restart during CU application.

---

## Application Procedure

### Pre-Patch Checklist

- [ ] Change approval obtained and recorded
- [ ] Third-party application compatibility verified for any co-located software
- [ ] Test instance patched and soaked for at least two weeks
- [ ] No active user connections expected during the window
- [ ] No SQL Agent jobs running at patch start time
- [ ] Full `COPY_ONLY` backup taken immediately before patching

```powershell
# Take a pre-patch COPY_ONLY backup
$splatBackup = @{
    SqlInstance     = $instance
    Type            = 'Full'
    CopyOnly        = $true
    CompressBackup  = $true
    Checksum        = $true
    BackupDirectory = $backupPath
    EnableException = $true
}
Backup-DbaDatabase @splatBackup
```

### Apply the Update

```powershell
# Confirm what update will be applied
$splatCheck = @{
    SqlInstance     = $instance
    EnableException = $true
}
Test-DbaBuild @splatCheck

# Apply
$splatPatch = @{
    SqlInstance     = $instance
    EnableException = $true
}
Update-DbaInstance @splatPatch
```

`Update-DbaInstance` downloads and installs the latest CU for the installed SQL Server version and will restart the SQL Server service. Confirm the maintenance window covers the restart and any downstream dependency restarts (replication agents, linked server consumers, application connection pool recovery).

---

## Post-Patch Validation

Run immediately after the instance returns online:

```powershell
# Confirm new build number
$splatVer = @{
    SqlInstance     = $instance
    Property        = 'BuildNumber', 'VersionString'
    EnableException = $true
}
Get-DbaInstanceProperty @splatVer | Select-Object SqlInstance, PropertyName, Value

# Confirm all databases are online
Get-DbaDatabase -SqlInstance $instance |
    Where-Object Status -ne 'Normal' |
    Select-Object SqlInstance, Name, Status

# Confirm SQL Agent is running and jobs are scheduled
Get-DbaAgentJob -SqlInstance $instance |
    Where-Object { $_.IsEnabled -and $_.LastRunOutcome -eq 'Failed' } |
    Select-Object SqlInstance, Name, LastRunDate, LastRunOutcome

# Replication instances — confirm distributor and agents are healthy
Get-DbaReplDistributor -SqlInstance $instance
```

Manual validation steps:

- [ ] SQL Server service online and accepting connections
- [ ] All user databases in ONLINE status
- [ ] SQL Agent service running and jobs scheduled
- [ ] Replication agents running (replication instances only)
- [ ] Log shipping jobs running (DR-configured instances only)

---

## Rollback

CU rollback via Windows Update uninstall is unreliable and Microsoft does not support rolling back CUs on production SQL Server instances.

**Preferred rollback path:**

1. If the instance is virtualized and a VM snapshot was taken immediately before patching: revert the snapshot.
2. If no snapshot is available: restore databases from the pre-patch `COPY_ONLY` backup to a new or rebuilt instance, redirect application traffic, and rebuild the patched instance clean.

This is why the pre-patch `COPY_ONLY` backup is mandatory — not optional.

---

## Related Documents

- [Backup and Restore](../Operations/BackupRestore.md) — backup procedures including `COPY_ONLY`
