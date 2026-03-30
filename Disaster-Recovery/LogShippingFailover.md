# Log Shipping Failover and Failback Procedures

> **Environment context:** These procedures were developed for a two-site architecture with log shipping from a primary data center to a geographically separate disaster recovery site. Log shipping does not support automatic failover — all steps below are manual.

## Table of Contents

- [Failover: Recover Databases on the Secondary Server](#failover-recover-databases-on-the-secondary-server)
  - [via T-SQL](#via-t-sql)
  - [via dbatools](#via-dbatools)
- [Failback: Restore to the Primary Server](#failback-restore-to-the-primary-server)
  - [via T-SQL](#via-t-sql-1)
  - [via dbatools](#via-dbatools-1)
- [Reestablish Log Shipping](#reestablish-log-shipping)
- [Traffic Redirection](#traffic-redirection)

## Failover: Recover Databases on the Secondary Server

When an extended outage at the primary site requires bringing the secondary server online, follow one of the procedures below. Both accomplish the same result — applying any remaining transaction log backups and recovering the databases to a usable state.

### via T-SQL

The following steps must be run for each log-shipped database you need to recover.

1. Apply any unapplied transaction log backups by running the `LSRestore_` SQL Agent job for each log-shipped database.

2. Once the restore jobs complete, disable both the `LSCopy_` and `LSRestore_` SQL Agent jobs.

3. Recover each database. The `WITH RECOVERY` option is what transitions the database from restoring/standby to a fully online, readable state.

```sql
RESTORE DATABASE [DatabaseName] WITH RECOVERY;
```

4. Redirect application traffic to the secondary server (see [Traffic Redirection](#traffic-redirection)).

### via dbatools

The [`Invoke-DbaDbLogShipRecovery`](https://docs.dbatools.io/#Invoke-DbaDbLogShipRecovery) command handles the heavy lifting — it applies the last available log backup and recovers the database in a single operation. By default it recovers **all** log-shipped databases on the instance.

1. Run the recovery command:

```powershell
# Recover all log-shipped databases on the instance
Invoke-DbaDbLogShipRecovery -SqlInstance SecondaryServer01 -Force

# Recover a single database
Invoke-DbaDbLogShipRecovery -SqlInstance SecondaryServer01 -Database DatabaseName -Force
```

2. Disable all `LSCopy_` and `LSRestore_` SQL Agent jobs:

```powershell
Get-DbaAgentJob -SqlInstance SecondaryServer01 |
    Where-Object { $_.Name -like 'LSCopy_*' -or $_.Name -like 'LSRestore_*' } |
    Set-DbaAgentJob -Disabled
```

3. Redirect application traffic to the secondary server (see [Traffic Redirection](#traffic-redirection)).

## Failback: Restore to the Primary Server

After the primary site is back online, you'll need to get fresh copies of the databases back to the primary before redirecting traffic. Log shipping has no built-in failback mechanism — this is effectively a backup-and-restore operation in reverse.

### via T-SQL

The following steps must be run for each database you need to restore to the primary server.

1. Stop all application traffic to the secondary server. Coordinate with the network team to ensure no connections are active. Verify with `sp_WhoIsActive` or:

```powershell
Get-DbaProcess -SqlInstance SecondaryServer01 -Database DatabaseName -ExcludeSystemSpids |
    Select-Object Spid, Login, Host, Database, Program
```

2. Disable all backup SQL Agent jobs on the secondary server:

```powershell
Get-DbaAgentJob -SqlInstance SecondaryServer01 |
    Where-Object { $_.Name -like 'LSBackup_*' } |
    Set-DbaAgentJob -Disabled
```

3. Take a full backup of each database on the secondary server:

```sql
BACKUP DATABASE [DatabaseName]
    TO DISK = 'X:\Backups\DatabaseName_full.bak'
WITH
    COMPRESSION,
    STATS = 1;
```

```powershell
Backup-DbaDatabase -SqlInstance SecondaryServer01 -Database DatabaseName -Path X:\Backups -Type Full -CompressBackup
```

4. Restore the databases on the primary server:

```sql
RESTORE DATABASE [DatabaseName]
    FROM DISK = 'X:\Backups\DatabaseName_full.bak'
WITH
    REPLACE,
    STATS = 1;
```

```powershell
Restore-DbaDatabase -SqlInstance PrimaryServer01 -Path X:\Backups\DatabaseName_full.bak -WithReplace
```

5. Enable backup SQL Agent jobs on the primary server.

6. Redirect application traffic to the primary server (see [Traffic Redirection](#traffic-redirection)).

### via dbatools

The [`Copy-DbaDatabase`](https://docs.dbatools.io/#Copy-DbaDatabase) command handles the backup and restore in a single operation. It backs up from the source, copies to the shared path, and restores on the destination.

1. Stop all application traffic to the secondary server (see step 1 above).

2. Copy databases from the secondary back to the primary:

```powershell
# Copy all databases
Copy-DbaDatabase -Source SecondaryServer01 -Destination PrimaryServer01 `
    -BackupRestore -SharedPath '\\PrimaryServer01\Backups' `
    -AllDatabases -NoCopyOnly -Force

# Copy a single database
Copy-DbaDatabase -Source SecondaryServer01 -Destination PrimaryServer01 `
    -BackupRestore -SharedPath '\\PrimaryServer01\Backups' `
    -Database DatabaseName -NoCopyOnly -Force
```

3. Enable backup SQL Agent jobs on the primary server:

```powershell
Get-DbaAgentJob -SqlInstance PrimaryServer01 |
    Where-Object { $_.Name -like 'LSBackup_*' } |
    Set-DbaAgentJob -Enabled
```

4. Redirect application traffic to the primary server (see [Traffic Redirection](#traffic-redirection)).

## Reestablish Log Shipping

Once the primary server is taking production traffic again, rebuild log shipping to the secondary server following the standard setup procedure documented in [Log Shipping Setup](LogShipping.md).

Before reinitializing, clean up the secondary server:

```powershell
# Remove the old log shipping configuration from the secondary
Get-DbaAgentJob -SqlInstance SecondaryServer01 |
    Where-Object { $_.Name -like 'LSCopy_*' -or $_.Name -like 'LSRestore_*' } |
    Remove-DbaAgentJob -Confirm:$false
```

## Traffic Redirection

Redirecting application traffic after a failover or failback can be done through DNS or application configuration. Each approach has tradeoffs.

**DNS update:** Change the A record or CNAME for the application's connection endpoint to point to the new server's IP. This is the simplest approach and doesn't require application changes, but you need to account for DNS TTL — if the TTL is set to a long value (e.g., 24 hours), clients will continue connecting to the old IP until their cached record expires. For DR-critical endpoints, consider setting a shorter TTL (e.g., 5 minutes) proactively so that failover redirection takes effect quickly.

**Application configuration:** Update connection strings in application config files, web.config, or environment variables. This gives you immediate, deterministic control with no TTL delay, but requires restarting or redeploying the application.

**SQL Server client alias:** Create a SQL Server client alias on the application servers via SQL Server Configuration Manager or `cliconfg.exe`. The alias maps a logical server name to a physical server/IP, so applications don't need config changes — only the alias target changes. This works well in environments where multiple applications connect to the same logical name.