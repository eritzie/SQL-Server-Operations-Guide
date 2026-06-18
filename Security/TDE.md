# Transparent Data Encryption

## Purpose

Document when and how to enable Transparent Data Encryption (TDE) for SQL Server databases requiring data-at-rest protection. Backup encryption is covered in [[Backup-and-Restore|Backup and Restore]]. TDE differs from backup encryption: it encrypts the data files, log files, and backups of the protected database at the page level, making data unreadable if the physical media is removed.

---

## GP Exclusion — Read First

> [!WARNING]
> Microsoft does not support Transparent Data Encryption on Dynamics GP databases. Do not enable TDE on DYNAMICS or any GP company database. Doing so will break GP and is not recoverable without disabling TDE and restoring from backup.

This exclusion applies regardless of compliance requirements. Address data-at-rest requirements for GP databases through alternative controls (encrypted storage volumes, BitLocker, restricted physical access).

See [[Dynamics-GP-Impact-Reference|Dynamics GP Impact Reference]] for the full list of GP-forbidden operations.

---

## When to Enable TDE

TDE is appropriate for databases that:

- Contain sensitive business data (PII, financial records, credentials) where physical media theft is a risk
- Are subject to compliance frameworks requiring encryption at rest
- Are **not** Dynamics GP databases (DYNAMICS or any GP company database)

TDE is not a substitute for access control. It protects against physical media theft — not against a compromised SQL login or OS account that can already read the data through normal SQL Server access.

---

## Setup

### Step 1 — Create the Database Master Key (server-level)

The master key encrypts the TDE certificate. Create it once per instance in the `master` database.

```sql
USE [master];

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'UseAStrongPasswordHere';
```

Verify:

```sql
SELECT [name], [is_master_key_encrypted_by_server]
FROM [sys].[symmetric_keys]
WHERE [name] = '##MS_DatabaseMasterKey##';
```

### Step 2 — Create the TDE Certificate

```sql
USE [master];

CREATE CERTIFICATE TDE_Cert
    WITH SUBJECT = 'TDE Certificate',
         EXPIRY_DATE = '2099-12-31';
```

### Step 3 — Back Up the Certificate Immediately

**This is the most critical step.** If the certificate is lost, the encrypted database cannot be restored — ever. Back up the certificate before enabling TDE on any database.

```sql
USE [master];

BACKUP CERTIFICATE TDE_Cert
    TO FILE = 'X:\CertBackup\TDE_Cert.cer'
    WITH PRIVATE KEY (
        FILE     = 'X:\CertBackup\TDE_Cert.pvk',
        ENCRYPTION BY PASSWORD = 'UseAStrongPasswordForThePrivateKey'
    );
```

Store the certificate backup and private key password in the password manager or secure credential store — not on the same server. A certificate backup on only the source instance is not a backup.

### Step 4 — Create the Database Encryption Key

```sql
USE [TargetDatabase];

CREATE DATABASE ENCRYPTION KEY
    WITH ALGORITHM = AES_256
    ENCRYPTION BY SERVER CERTIFICATE TDE_Cert;
```

### Step 5 — Enable Encryption

```sql
ALTER DATABASE [TargetDatabase] SET ENCRYPTION ON;
```

Encryption runs as a background process. Monitor progress:

```sql
SELECT
    DB_NAME([database_id])  AS [database],
    [encryption_state_desc],
    [percent_complete],
    [key_algorithm],
    [key_length]
FROM [sys].[dm_database_encryption_keys];
```

`encryption_state_desc` will show `ENCRYPTION_IN_PROGRESS` until complete, then `ENCRYPTED`.

### dbatools Alternative

```powershell
$splatTde = @{
    SqlInstance     = $instance
    Database        = $database
    EnableException = $true
}
Enable-DbaDbEncryption @splatTde
```

---

## Monitoring Encryption State

```powershell
$splatCheck = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbEncryption @splatCheck |
    Select-Object SqlInstance, DatabaseName, EncryptionState, PercentComplete
```

---

## Restore Implications

A TDE-encrypted backup **cannot be restored** to a SQL Server instance that does not have the TDE certificate installed. Before any restore of an encrypted database to a different instance:

1. Install the TDE certificate on the target instance from the certificate backup.
2. Verify the certificate is present before attempting the restore.

```sql
-- On the target instance: restore the certificate from backup
USE [master];

CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'UseAStrongPasswordHere';

CREATE CERTIFICATE TDE_Cert
    FROM FILE     = 'X:\CertBackup\TDE_Cert.cer'
    WITH PRIVATE KEY (
        FILE                = 'X:\CertBackup\TDE_Cert.pvk',
        DECRYPTION BY PASSWORD = 'UseAStrongPasswordForThePrivateKey'
    );
```

---

## Related Documents

- [[Security-Practices|Security Practices]] — general security hardening and access control
- [[Backup-and-Restore|Backup and Restore]] — backup encryption (separate from TDE)
- [[Dynamics-GP-Impact-Reference|Dynamics GP Impact Reference]] — TDE exclusion for GP databases
- [[../Index|Back to Index]]
