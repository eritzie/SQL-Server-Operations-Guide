# Database Backup and Restore

> **Environment context:** These procedures were developed for SQL Server environments where production backups are managed by enterprise backup software and offloaded to a centralized infrastructure team. Manual backups are performed by the DBA team for ad-hoc needs such as pre-change snapshots, migrations, and local development restores.

## Table of Contents

- [Automated Backups](#automated-backups)
- [Manual Backups](#manual-backups)
  - [Full Backups via T-SQL](#full-backups-via-t-sql)
  - [Full Backups via Ola Hallengren](#full-backups-via-ola-hallengren)
  - [Full Backups via dbatools](#full-backups-via-dbatools)
  - [Differential Backups](#differential-backups)
  - [Transaction Log Backups](#transaction-log-backups)
- [Backup Verification](#backup-verification)
- [Database Restores](#database-restores)
  - [Restore via T-SQL](#restore-via-t-sql)
  - [Restore via dbatools](#restore-via-dbatools)
  - [Point-in-Time Restore](#point-in-time-restore)
- [Important Notes](#important-notes)

## Automated Backups

Production databases are backed up daily by the infrastructure team using enterprise backup software. Backups are stored offsite. The DBA team does not manage the backup schedule or retention for these — that is owned by the infrastructure team.

For any production restore needs, coordinate with the infrastructure team to retrieve the backup from the enterprise system.

## Manual Backups

Manual backups are needed for pre-change safety nets, refreshing development environments, and troubleshooting. To protect the integrity of configured log shipping, **always use COPY_ONLY** for manual backups. A regular full backup resets the differential base and breaks the log shipping chain, requiring a full reinitialization.

### Full Backups via T-SQL

```sql
-- Full Copy-Only backup to local disk
BACKUP DATABASE [DatabaseName]
    TO DISK = N'X:\Backups\Full\DatabaseName.bak'
WITH
    FORMAT,
    COMPRESSION,
    CHECKSUM,
    COPY_ONLY,
    STATS = 1;

-- Full Copy-Only backup to network share
BACKUP DATABASE [DatabaseName]
    TO DISK = N'\\BackupShare\DatabaseName.bak'
WITH
    FORMAT,
    COMPRESSION,
    CHECKSUM,
    COPY_ONLY,
    STATS = 1;
```

### Full Backups via Ola Hallengren

[Ola Hallengren's Maintenance Solution](https://ola.hallengren.com/) wraps the native backup commands with additional functionality such as standardized file naming, cleanup of old backups, and logging.

```sql
EXECUTE master.dbo.DatabaseBackup
    @Databases = 'DatabaseName',
    @Directory = 'X:\Backups\Full',
    @BackupType = 'FULL',
    @Compress = 'Y',
    @CopyOnly = 'Y',
    @CheckSum = 'Y',
    @Verify = 'Y',
    @CleanupTime = 168; -- Remove backups older than 7 days (in hours)
```

The default file naming convention produces files like `ServerName_DatabaseName_FULL_20260330_120000.bak`. Override with the `@FileName` parameter if your environment requires a different naming scheme.

### Full Backups via dbatools

```powershell
# Full Copy-Only backup to local disk
Backup-DbaDatabase -SqlInstance ServerName01 -Database DatabaseName `
    -Path X:\Backups\Full -Type Full -CopyOnly -CompressBackup -Checksum

# Full Copy-Only backup to network share
Backup-DbaDatabase -SqlInstance ServerName01 -Database DatabaseName `
    -Path \\BackupShare -Type Full -CopyOnly -CompressBackup -Checksum

# Backup all user databases
Backup-DbaDatabase -SqlInstance ServerName01 -ExcludeSystem `
    -Path X:\Backups\Full -Type Full -CopyOnly -CompressBackup -Checksum
```

### Differential Backups

Differentials capture changes since the last full backup. They're useful for reducing restore time — restore the full, then just the most recent differential, then any subsequent log backups.

```sql
BACKUP DATABASE [DatabaseName]
    TO DISK = N'X:\Backups\Diff\DatabaseName_diff.bak'
WITH
    DIFFERENTIAL,
    FORMAT,
    COMPRESSION,
    CHECKSUM,
    STATS = 1;
```

```powershell
Backup-DbaDatabase -SqlInstance ServerName01 -Database DatabaseName `
    -Path X:\Backups\Diff -Type Differential -CompressBackup -Checksum
```

> **Note:** Do not use `COPY_ONLY` with differential backups — it would produce a differential that is not based on the current differential base and would be unusable for restore chains.

### Transaction Log Backups

Log backups capture all transactions since the last log backup. They enable point-in-time recovery and are essential for databases in Full or Bulk-Logged recovery model.

```sql
BACKUP LOG [DatabaseName]
    TO DISK = N'X:\Backups\Log\DatabaseName_log.trn'
WITH
    FORMAT,
    COMPRESSION,
    CHECKSUM,
    STATS = 1;
```

```powershell
Backup-DbaDatabase -SqlInstance ServerName01 -Database DatabaseName `
    -Path X:\Backups\Log -Type Log -CompressBackup -Checksum
```

> **Note:** If log shipping is configured, manual log backups (without `COPY_ONLY`) will break the log chain. Use `COPY_ONLY` for manual log backups in log-shipped environments:

```sql
BACKUP LOG [DatabaseName]
    TO DISK = N'X:\Backups\Log\DatabaseName_log.trn'
WITH
    FORMAT,
    COMPRESSION,
    CHECKSUM,
    COPY_ONLY,
    STATS = 1;
```

```powershell
Backup-DbaDatabase -SqlInstance ServerName01 -Database DatabaseName `
    -Path X:\Backups\Log -Type Log -CopyOnly -CompressBackup -Checksum
```

## Backup Verification

Taking a backup is only half the job — an unverified backup is not a backup. Use `RESTORE VERIFYONLY` to confirm the backup file is structurally sound and the checksum is valid.

```sql
RESTORE VERIFYONLY
    FROM DISK = N'X:\Backups\Full\DatabaseName.bak'
WITH CHECKSUM;
```

```powershell
Test-DbaLastBackup -SqlInstance ServerName01 -Database DatabaseName
```

`Test-DbaLastBackup` goes further than `VERIFYONLY` — it actually restores the backup to a temporary location, runs `DBCC CHECKDB` against it, then drops the restored copy. This confirms not just that the backup file is readable, but that the data inside is consistent. It's more resource-intensive, so schedule it during maintenance windows rather than running it after every backup.

## Database Restores

Production restores from the enterprise backup system must be coordinated with the infrastructure team. The procedures below are for restoring from manual backups.

### Restore via T-SQL

```sql
-- Restore from local disk
RESTORE DATABASE [DatabaseName]
    FROM DISK = N'X:\Backups\Full\DatabaseName.bak'
WITH
    REPLACE,
    CHECKSUM,
    STATS = 1;

-- Restore from network share
RESTORE DATABASE [DatabaseName]
    FROM DISK = N'\\BackupShare\DatabaseName.bak'
WITH
    REPLACE,
    CHECKSUM,
    STATS = 1;
```

If you need to relocate the data and log files during restore (common when restoring to a server with a different disk layout):

```sql
-- Check the logical file names in the backup
RESTORE FILELISTONLY FROM DISK = N'X:\Backups\Full\DatabaseName.bak';

-- Restore with file relocation
RESTORE DATABASE [DatabaseName]
    FROM DISK = N'X:\Backups\Full\DatabaseName.bak'
WITH
    MOVE N'DatabaseName' TO N'H:\Data01\DatabaseName.mdf',
    MOVE N'DatabaseName_log' TO N'I:\Log01\DatabaseName_log.ldf',
    REPLACE,
    CHECKSUM,
    STATS = 1;
```

### Restore via dbatools

```powershell
# Restore from local disk
Restore-DbaDatabase -SqlInstance ServerName01 -Path X:\Backups\Full\DatabaseName.bak

# Restore from network share
Restore-DbaDatabase -SqlInstance ServerName01 -Path \\BackupShare\DatabaseName.bak

# Restore with file relocation (dbatools handles this automatically
# by mapping files to the instance's default data and log directories)
Restore-DbaDatabase -SqlInstance ServerName01 -Path X:\Backups\Full\DatabaseName.bak -UseDestinationDefaultDirectories

# Restore with a new database name (useful for dev/test copies)
Restore-DbaDatabase -SqlInstance ServerName01 -Path X:\Backups\Full\DatabaseName.bak `
    -DatabaseName DatabaseName_Copy -UseDestinationDefaultDirectories
```

### Point-in-Time Restore

To restore to a specific point in time, you need the full backup, the most recent differential (if available), and all transaction log backups up to the target time. Restore the full and differential with `NORECOVERY`, then the final log backup with `STOPAT`.

```sql
-- Step 1: Restore full with NORECOVERY
RESTORE DATABASE [DatabaseName]
    FROM DISK = N'X:\Backups\Full\DatabaseName.bak'
WITH
    NORECOVERY,
    REPLACE,
    CHECKSUM,
    STATS = 1;

-- Step 2: Restore differential with NORECOVERY (if available)
RESTORE DATABASE [DatabaseName]
    FROM DISK = N'X:\Backups\Diff\DatabaseName_diff.bak'
WITH
    NORECOVERY,
    CHECKSUM,
    STATS = 1;

-- Step 3: Restore log with STOPAT to the target time
RESTORE LOG [DatabaseName]
    FROM DISK = N'X:\Backups\Log\DatabaseName_log.trn'
WITH
    RECOVERY,
    CHECKSUM,
    STOPAT = '2026-03-30T14:30:00';
```

```powershell
# dbatools can handle the full restore chain with point-in-time
Restore-DbaDatabase -SqlInstance ServerName01 `
    -Path X:\Backups\Full\DatabaseName.bak, X:\Backups\Diff\DatabaseName_diff.bak, X:\Backups\Log\DatabaseName_log.trn `
    -RestoreTime (Get-Date '2026-03-30T14:30:00')
```

## Important Notes

- **Always use COPY_ONLY** for manual ad-hoc backups in environments with log shipping or third-party backup software. Regular full backups reset the differential base and can break backup chains managed by other tools.
- **Always include CHECKSUM** on both backup and restore operations. This adds minimal overhead but catches corruption that would otherwise go undetected until you need the backup.
- **Test your restores regularly.** `Test-DbaLastBackup` automates this with a full restore and `DBCC CHECKDB` cycle. An untested backup is an assumption, not a recovery plan.
- **Backup to a network share** when possible so backups are not stored on the same physical host as the database. A server failure that takes out the data disk will also take out local backups.