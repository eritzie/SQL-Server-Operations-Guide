# Always Encrypted

## Purpose

Always Encrypted encrypts column data so that SQL Server never sees the plaintext. Encryption and decryption happen only inside the application or an SSMS session that has access to the Column Master Key. A sysadmin with direct table access sees only ciphertext — not the underlying data.

Target use cases: PII (SSN, date of birth, government IDs), PCI (credit card numbers), and HIPAA-regulated fields where the requirement is that even database administrators cannot read the data.

---

## Always Encrypted vs TDE

These are complementary controls, not alternatives. TDE protects files on disk; Always Encrypted protects specific columns from privileged database users.

| | TDE | Always Encrypted |
|---|---|---|
| Encryption level | Database files (at rest) | Individual columns |
| Who can read plaintext | Any user with database access | Only applications or sessions with the Column Master Key |
| DBAs can see data | Yes | No |
| Performance impact | Low (AES-128/256 on I/O) | Low for reads; slight additional cost for writes |
| Compliance use case | Data at rest protection | PII/PCI column protection from privileged users |
| LIKE / range queries | Not affected | Not supported on randomized encryption (use Enclave) |
| Application changes needed | None | Connection string update + compatible driver required |

---

## Key Hierarchy

**Column Master Key (CMK)** — protects the CEK. Stored *outside* SQL Server in the Windows Certificate Store, Azure Key Vault, or an HSM. SQL Server stores only CMK metadata (a location reference), never the key material itself.

**Column Encryption Key (CEK)** — encrypts the actual column data. Stored in SQL Server, but encrypted by the CMK. Without the CMK, the CEK ciphertext is useless — even a sysadmin who can read `sys.column_encryption_keys` cannot decrypt the data.

---

## Encryption Types

**Deterministic** — the same plaintext always produces the same ciphertext. Allows equality comparisons (`WHERE [SSN] = @ssn`) but ciphertext patterns can leak frequency information. Use for columns that require equality lookups.

**Randomized** — the same plaintext produces different ciphertext each time. More secure but cannot be used in WHERE clauses, GROUP BY, or non-Enclave indexes. Use for columns that are only read back to the application, never filtered in SQL.

---

## Driver Requirements

Applications must use a compatible driver with `Column Encryption Setting=Enabled` in the connection string.

| Driver | Minimum Version |
|---|---|
| Microsoft.Data.SqlClient | 2.0+ |
| ODBC Driver for SQL Server | 17+ |
| Microsoft JDBC Driver | 7.2+ |
| MSOLEDBSQL | 18.2+ |

Without `Column Encryption Setting=Enabled`, the driver passes plaintext and no encryption or decryption occurs.

---

## Setup — Step by Step

### Step 1: Create the Column Master Key

SSMS is recommended for first-time setup — it generates the certificate, stores it in the Windows Certificate Store, and registers the CMK metadata in SQL Server in one operation.

In SSMS: expand the target database → Security → Always Encrypted Keys → Column Master Keys → right-click → New Column Master Key. Select Windows Certificate Store – Current User or Local Machine. Name it `CMK_<Purpose>` (e.g., `CMK_PII`).

To register an existing certificate via T-SQL:

```sql
SET NOCOUNT ON;

CREATE COLUMN MASTER KEY [CMK_PII]
WITH
(
    KEY_STORE_PROVIDER_NAME = N'MSSQL_CERTIFICATE_STORE',
    KEY_PATH                = N'CurrentUser/My/THUMBPRINT_HERE'
);
```

### Step 2: Create the Column Encryption Key

In SSMS: Security → Always Encrypted Keys → Column Encryption Keys → right-click → New. SSMS connects to the CMK, generates a random CEK, encrypts it with the CMK, and stores the encrypted value in SQL Server.

### Step 3: Encrypt Columns on an Existing Table

Use the SSMS Always Encrypted wizard: right-click the table → Encrypt Columns. The wizard creates a staging table, copies data with encryption applied, and swaps the tables. For scripted migration, use `Set-SqlColumnEncryption` from the SqlServer PowerShell module.

### Step 4: Define Encrypted Columns in New Tables

```sql
SET NOCOUNT ON;

CREATE TABLE [dbo].[PatientRecord]
(
    [PatientID]   int           NOT NULL IDENTITY(1,1),
    [FirstName]   nvarchar(100) NOT NULL,
    [LastName]    nvarchar(100) NOT NULL,
    -- Deterministic: allows equality lookups on SSN
    [SSN]         char(11)      COLLATE Latin1_General_BIN2
                  ENCRYPTED WITH
                  (
                      ENCRYPTION_TYPE       = DETERMINISTIC,
                      ALGORITHM             = 'AEAD_AES_256_CBC_HMAC_SHA_256',
                      COLUMN_ENCRYPTION_KEY = [CEK_PII]
                  ) NOT NULL,
    -- Randomized: DOB is never filtered in SQL, only displayed
    [DateOfBirth] date
                  ENCRYPTED WITH
                  (
                      ENCRYPTION_TYPE       = RANDOMIZED,
                      ALGORITHM             = 'AEAD_AES_256_CBC_HMAC_SHA_256',
                      COLUMN_ENCRYPTION_KEY = [CEK_PII]
                  ) NULL
);
```

Encrypted character columns require `BIN2` collation for deterministic encryption.

---

## Limitations

| Operation | Supported |
|---|---|
| Equality comparison on deterministic column | Yes |
| Range comparison (`>`, `<`, `BETWEEN`) | No (unless using Enclave) |
| `LIKE` on encrypted column | No (unless using Enclave) |
| `GROUP BY` on encrypted column | No (unless using Enclave) |
| Index on randomized column | No (unless using Enclave) |
| `IS NULL` check | Yes |

**Always Encrypted with Secure Enclaves** (SQL Server 2019+, Enterprise Edition) lifts most of these restrictions. The CMK and CEK must be Enclave-enabled at creation time — retrofitting requires key rotation.

---

## CMK Backup and Management

> **Critical:** If the certificate is lost, all data encrypted under it is permanently unrecoverable. There is no recovery path.

```powershell
# Export the CMK certificate from the Windows Certificate Store
$cert = Get-ChildItem Cert:\CurrentUser\My |
    Where-Object Subject -like '*CMK_PII*'

$splatExport = @{
    Cert        = $cert
    FilePath    = 'X:\Certs\CMK_PII_Backup.pfx'
    Password    = (Read-Host -AsSecureString 'PFX export password')
    ChainOption = 'BuildChain'
}
Export-PfxCertificate @splatExport
```

Store the PFX file and its password in separate secure locations. Without both, encrypted columns cannot be decrypted.

### Key Rotation

Rotate CMKs on a scheduled basis or immediately if a key may have been compromised. SSMS provides a Rotate Column Master Key wizard that re-encrypts the CEK with the new CMK without touching the column data itself.

---

## Auditing Encrypted Columns

```sql
SET NOCOUNT ON;

SELECT
    [t].[name]                  AS TableName,
    [c].[name]                  AS ColumnName,
    [c].[encryption_type_desc],
    [cek].[name]                AS EncryptionKeyName,
    [cmk].[name]                AS MasterKeyName
FROM [sys].[columns]                AS c
JOIN [sys].[tables]                 AS t
    ON [c].[object_id] = [t].[object_id]
JOIN [sys].[column_encryption_keys] AS cek
    ON [c].[column_encryption_key_id] = [cek].[column_encryption_key_id]
JOIN [sys].[column_master_keys]     AS cmk
    ON [cek].[column_master_key_id] = [cmk].[column_master_key_id]
ORDER BY [t].[name], [c].[name];
```

Run this after any schema deployment touching tables with PII or PCI columns to verify encryption metadata matches the design specification.

---

## Related Documents

- [[TDE|Transparent Data Encryption]] — file-level encryption (complementary to Always Encrypted)
- [[Security-Practices|Security Practices]] — authentication and access control standards
- [[SQL-Server-Audit|SQL Server Audit]] — audit trail for access to encrypted tables
- [[Security|Back to Security]]
