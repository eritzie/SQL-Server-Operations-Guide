# SQL Server Security Practices

> **Environment context:** These practices were developed for SQL Server environments subject to compliance requirements including SOX and CIS Benchmark for SQL Server. The guidance applies to both standalone instances and Failover Cluster Instances across development, test, and production environments.

## Table of Contents

- [Authentication Strategy](#authentication-strategy)
  - [SQL Login Accounts](#sql-login-accounts)
  - [Windows Domain Accounts](#windows-domain-accounts)
  - [Windows Security Groups](#windows-security-groups)
- [Server and Database Roles](#server-and-database-roles)
  - [Standard Database Roles](#standard-database-roles)
  - [Environment Permission Matrix](#environment-permission-matrix)
- [SA Account Hardening](#sa-account-hardening)
- [Permission Principles](#permission-principles)
- [Surface Area Reduction](#surface-area-reduction)
- [Backup Security](#backup-security)
- [Auditing and Compliance](#auditing-and-compliance)
- [CIS Benchmark Alignment](#cis-benchmark-alignment)

## Authentication Strategy

### SQL Login Accounts

Avoid SQL login accounts whenever possible. When a server is compromised, all SQL login names and password hashes are exposed via `sys.sql_logins`. Since many organizations reuse the same account names across instances, a single breach can cascade.

SQL logins should only be used when:

- A third-party application does not support Windows Integrated Security.
- The database is containerized (Azure SQL Database, Azure SQL Managed Instance) where Windows authentication may not be available.
- A cross-domain connection cannot use Kerberos delegation.

When SQL logins are unavoidable, enforce password policy and expiration:

```sql
CREATE LOGIN [AppLogin] WITH PASSWORD = 'StrongPassword',
    CHECK_POLICY = ON,
    CHECK_EXPIRATION = ON;
```

> **CIS Benchmark reference:** CIS Microsoft SQL Server Benchmark recommends CHECK_POLICY = ON for all SQL logins (Section 3.2).

Audit existing SQL logins:

```powershell
# List all SQL logins (excludes Windows logins)
Get-DbaLogin -SqlInstance SqlServer01 -Type SQL |
    Select-Object Name, CreateDate, LastLogin, HasAccess, IsDisabled, IsLocked

# Find SQL logins with policy/expiration not enforced
$query = @"
SELECT name, is_policy_checked, is_expiration_checked, create_date, modify_date
FROM sys.sql_logins
WHERE is_policy_checked = 0 OR is_expiration_checked = 0;
"@
Invoke-DbaQuery -SqlInstance SqlServer01 -Query $query
```

### Windows Domain Accounts

Windows domain accounts are the preferred authentication method for both user connections and application connections. Credentials are managed in Active Directory where passwords are encrypted, policies are enforced centrally, and account lifecycle (creation, disablement, deletion) is handled by the identity management team.

Application connections should use a dedicated domain service account with Integrated Security in the connection string so the password is never exposed in configuration files. Each application should use its own service account — never share accounts across applications. Shared accounts make it impossible to trace activity to a specific application and create a security dependency between unrelated systems.

```powershell
# Audit Windows logins on the instance
Get-DbaLogin -SqlInstance SqlServer01 -Type Windows |
    Select-Object Name, LoginType, CreateDate, LastLogin, HasAccess, IsDisabled
```

### Windows Security Groups

Use Active Directory security groups rather than granting permissions to individual user accounts. This simplifies permission management and eliminates the need to clean up SQL Server logins when employees leave — removing the user from the AD group revokes their access automatically.

Security groups also work with Azure SQL Database and Azure SQL Managed Instance when Azure AD integration is configured.

```powershell
# List all Windows group logins
Get-DbaLogin -SqlInstance SqlServer01 -Type WindowsGroup |
    Select-Object Name, CreateDate, HasAccess

# Check members of a Windows group login
Get-ADGroupMember -Identity 'SQLServer-ReadOnly' | Select-Object Name, SamAccountName
```

## Server and Database Roles

Roles simplify permission management by grouping permissions into reusable units. Apply roles to security groups (not individual users) for maximum manageability.

### Standard Database Roles

The following custom database roles provide granular access without over-permissioning. The naming convention uses a `dr_` prefix to distinguish custom roles from built-in roles at a glance.

| Role Name | Permissions | Typical Use |
|---|---|---|
| dr_RO | SELECT | Reporting, read-only analysts |
| dr_EO | EXECUTE | Applications using stored procedure access patterns |
| dr_RE | SELECT + EXECUTE | Applications that need both read and execute |
| dr_RW | SELECT + INSERT + UPDATE | Accounts that write data but must not delete rows |
| dr_Del | DELETE (additive — combine with dr_RW or dr_RWE) | Accounts that require DELETE in addition to their base role |
| dr_RWE | SELECT + INSERT + UPDATE + EXECUTE | Application accounts that read, write, and call stored procedures |
| dr_Deploy | SELECT + INSERT + UPDATE + DELETE + EXECUTE on `deploy` schema | Deployment service accounts and tooling |

Create these roles:

```sql
-- Read-Only
CREATE ROLE [dr_RO];
GRANT SELECT TO [dr_RO];

-- Execute-Only
CREATE ROLE [dr_EO];
GRANT EXECUTE TO [dr_EO];

-- Read-Execute
CREATE ROLE [dr_RE];
GRANT SELECT TO [dr_RE];
GRANT EXECUTE TO [dr_RE];

-- Read-Write (no DELETE)
CREATE ROLE [dr_RW];
GRANT SELECT TO [dr_RW];
GRANT INSERT TO [dr_RW];
GRANT UPDATE TO [dr_RW];

-- Delete (additive — combine with dr_RW or dr_RWE when DELETE is required)
CREATE ROLE [dr_Del];
GRANT DELETE TO [dr_Del];

-- Read-Write-Execute (no DELETE — deletes handled via stored procedures)
CREATE ROLE [dr_RWE];
GRANT SELECT TO [dr_RWE];
GRANT INSERT TO [dr_RWE];
GRANT UPDATE TO [dr_RWE];
GRANT EXECUTE TO [dr_RWE];

-- Deploy (deploy schema only)
CREATE ROLE [dr_Deploy];
GRANT SELECT, INSERT, UPDATE, DELETE, EXECUTE ON SCHEMA::[deploy] TO [dr_Deploy];
```

As a best practice, inserts, updates, and deletes should be handled through stored procedures. This eliminates the need for `dr_RW` and `dr_RWE` entirely — `dr_EO` or `dr_RE` should be sufficient for well-designed applications.

### Environment Permission Matrix

Permissions should be progressively restrictive from development through production.

| Security Group | Development | Test | Production |
|---|---|---|---|
| Database Admins | sysadmin | sysadmin | sysadmin |
| Developers | db_owner (dr_RWE at minimum) | dr_RO | dr_RO |
| Application Service Accounts | dr_RE or dr_RWE | dr_RE or dr_RWE | dr_EO or dr_RE |

> **Key principle:** Developers get full access in dev, read-only everywhere else. Application accounts get only what they need, and production should be the most restrictive. sysadmin should be limited to the DBA team and the SQL Server service account.

Audit current role membership:

```powershell
# Server-level role members
Get-DbaServerRoleMember -SqlInstance SqlServer01 |
    Select-Object Role, Name, Login

# Database-level role members across all databases
$query = @"
SELECT
    DB_NAME() AS DatabaseName,
    dp.name AS RoleName,
    mp.name AS MemberName,
    mp.type_desc AS MemberType
FROM sys.database_role_members drm
INNER JOIN sys.database_principals dp ON drm.role_principal_id = dp.principal_id
INNER JOIN sys.database_principals mp ON drm.member_principal_id = mp.principal_id
ORDER BY dp.name, mp.name;
"@

Get-DbaDatabase -SqlInstance SqlServer01 -ExcludeSystem |
    ForEach-Object {
        Invoke-DbaQuery -SqlInstance SqlServer01 -Database $_.Name -Query $query
    } | Out-GridView
```

## SA Account Hardening

The SA account is the default SQL Server administrator account. Every attacker knows it exists. Disable and rename it immediately after installation.

```sql
-- Rename and disable
ALTER LOGIN [sa] WITH NAME = [DisabledSA];
ALTER LOGIN [DisabledSA] DISABLE;
```

```powershell
# Verify SA is disabled
Get-DbaLogin -SqlInstance SqlServer01 -Login sa |
    Select-Object Name, IsDisabled

# If it was already renamed, find it by SID
$query = "SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01;"
Invoke-DbaQuery -SqlInstance SqlServer01 -Query $query
```

> **CIS Benchmark reference:** CIS Microsoft SQL Server Benchmark requires the SA account to be disabled (Section 2.1) and renamed (Section 2.2).

## Permission Principles

**Least privilege, always.** Every account should have the minimum permissions needed to perform its function — nothing more.

**Application service accounts** should typically need only EXECUTE permissions. If the application uses inline queries instead of stored procedures, READ may also be needed, but this is a design compromise — not the preferred architecture.

**db_owner should be rare in production.** db_owner grants the ability to create and drop objects, which is appropriate in development but dangerous in production. If a process claims to need db_owner, investigate what specific permissions it actually requires.

**sysadmin should be limited to the DBA team and SQL Server service accounts.** sysadmin grants unrestricted access to the entire instance — every database, every configuration setting, every job. No application should ever run as sysadmin.

Audit over-permissioned accounts:

```powershell
# Find all sysadmin members (should be a short list)
Get-DbaServerRoleMember -SqlInstance SqlServer01 |
    Where-Object { $_.Role -eq 'sysadmin' } |
    Select-Object Name, Login

# Find all db_owner members across databases
$query = @"
SELECT
    DB_NAME() AS DatabaseName,
    mp.name AS MemberName,
    mp.type_desc AS MemberType
FROM sys.database_role_members drm
INNER JOIN sys.database_principals dp ON drm.role_principal_id = dp.principal_id
INNER JOIN sys.database_principals mp ON drm.member_principal_id = mp.principal_id
WHERE dp.name = 'db_owner'
    AND mp.name NOT IN ('dbo');
"@

Get-DbaDatabase -SqlInstance SqlServer01 -ExcludeSystem |
    ForEach-Object {
        Invoke-DbaQuery -SqlInstance SqlServer01 -Database $_.Name -Query $query
    } | Out-GridView
```

## Surface Area Reduction

Disable features that are not actively used. Each enabled feature is an additional attack vector.

| Feature | sp_configure Name | Default | Recommendation |
|---|---|---|---|
| xp_cmdshell | xp_cmdshell | 0 (off) | Leave off unless explicitly needed |
| OLE Automation | Ole Automation Procedures | 0 (off) | Leave off unless explicitly needed |
| OpenRowSet/OpenDataSource | Ad Hoc Distributed Queries | 0 (off) | Leave off; use linked servers instead |
| CLR Integration | clr enabled | 0 (off) | Enable only if CLR assemblies are in use |
| Remote Admin Connections | remote admin connections | 0 (off) | Consider enabling (DAC over network for DR) |

```powershell
# Audit all non-default sp_configure settings
Get-DbaSpConfigure -SqlInstance SqlServer01 |
    Where-Object { $_.ConfiguredValue -ne $_.DefaultValue } |
    Select-Object Name, ConfiguredValue, DefaultValue, Description |
    Out-GridView

# Disable a specific feature
Set-DbaSpConfigure -SqlInstance SqlServer01 -Name xp_cmdshell -Value 0
```

> **CIS Benchmark reference:** CIS requires xp_cmdshell disabled (Section 2.7), OLE Automation disabled (Section 2.8), and Ad Hoc Distributed Queries disabled (Section 2.10).

**SQL Browser Service:** Disable when running a default instance. The SQL Browser service listens on UDP 1434 and reveals instance names and port information. It's only needed when running named instances with dynamic ports.

```powershell
# Check SQL Browser status
Get-DbaService -ComputerName SqlServer01 -Type Browser |
    Select-Object ServiceName, State, StartMode

# Disable it
Set-Service -Name SQLBrowser -StartupType Disabled -ComputerName SqlServer01
Stop-Service -Name SQLBrowser -ComputerName SqlServer01 -Force
```

**Non-default SQL port:** Using a non-standard port for SQL Server adds a layer of obscurity. The default port (TCP 1433) is the first thing scanners hit. A non-default port won't stop a determined attacker, but it eliminates casual scanning noise and is a common compliance requirement.

```powershell
# Check the current port configuration
Get-DbaTcpPort -SqlInstance SqlServer01
```

## Backup Security

**Restrict access to backup folders.** Only the SQL Server service account and DBA team should have access. This prevents accidental deletion and unauthorized copying of backup files. A database backup is a complete copy of the data — if an unauthorized person can copy a `.bak` file, they can restore it anywhere and read everything.

**Encrypt backups.** Backup encryption prevents a stolen `.bak` file from being restored on an unauthorized SQL Server instance. This requires a database master key and a certificate or asymmetric key.

```sql
-- Create a master key and certificate for backup encryption
USE master;
CREATE MASTER KEY ENCRYPTION BY PASSWORD = 'StrongPassword';
CREATE CERTIFICATE BackupEncryptCert WITH SUBJECT = 'Backup Encryption Certificate';

-- Backup the certificate (store securely off-server)
BACKUP CERTIFICATE BackupEncryptCert
    TO FILE = 'X:\Certs\BackupEncryptCert.cer'
    WITH PRIVATE KEY (
        FILE = 'X:\Certs\BackupEncryptCert.pvk',
        ENCRYPTION BY PASSWORD = 'CertPrivateKeyPassword'
    );
```

```powershell
# Verify encryption certificates exist
Get-DbaDbCertificate -SqlInstance SqlServer01 -Database master |
    Select-Object Name, Subject, StartDate, ExpirationDate
```

> **Critical:** Back up the certificate and private key to a secure location separate from the SQL Server. Without the certificate, encrypted backups cannot be restored — on any server, ever.

**Store backups off-server.** Backing up to a network share ensures that a server failure that destroys the data disk doesn't also destroy the backups. Enterprise backup software typically handles this, but for manual backups, always target a network share or secondary storage.

## Auditing and Compliance

Regular auditing is essential for compliance and for catching permission drift. The following queries and commands form a baseline audit that can be scheduled and reviewed periodically.

```powershell
# Full instance security audit — logins, roles, permissions
Export-DbaLogin -SqlInstance SqlServer01 -Path X:\Audit\Logins.sql

# Identify orphaned users (database users with no matching server login)
Get-DbaDbOrphanUser -SqlInstance SqlServer01 |
    Select-Object DatabaseName, User

# Identify logins not used in the last 90 days
Get-DbaLogin -SqlInstance SqlServer01 |
    Where-Object { $_.LastLogin -lt (Get-Date).AddDays(-90) -and $_.IsDisabled -eq $false } |
    Select-Object Name, LoginType, LastLogin, CreateDate

# Check for databases with TRUSTWORTHY enabled (should generally be off)
Get-DbaDatabase -SqlInstance SqlServer01 |
    Where-Object { $_.Trustworthy -eq $true } |
    Select-Object Name, Trustworthy
```

> **CIS Benchmark reference:** CIS requires TRUSTWORTHY to be OFF for all user databases (Section 2.9). TRUSTWORTHY allows database code to access server-level resources, which can be exploited for privilege escalation.

For a comprehensive CIS Benchmark audit, see the [SQL Server Security Audit](https://github.com/eritzie/SQL-Server-Security-Audit) repository which provides scripted checks aligned to CIS Microsoft SQL Server Benchmark 2022 v1.2.1.

## CIS Benchmark Alignment

Quick-reference table of CIS Microsoft SQL Server Benchmark controls checked in this environment. All L1 controls are required; L2 controls are implemented where operationally feasible.

| Control | Section | Description | Level |
|---|---|---|---|
| 1.1 | Patching | Latest CU installed | L1 |
| 2.1 | Surface Area | xp_cmdshell = 0 | L1 |
| 2.2 | Auth | sa account disabled and renamed | L1 |
| 2.3 | Surface Area | Ole Automation Procedures = 0 | L1 |
| 2.4 | Surface Area | Ad Hoc Distributed Queries = 0 | L1 |
| 2.5 | Surface Area | Database Mail XPs = 0 | L1 |
| 2.6 | Surface Area | cross db ownership chaining = 0 | L1 |
| 2.8 | Surface Area | clr enabled = 0 (unless CLR is required) | L1 |
| 2.9 | Database | TRUSTWORTHY = OFF for all user databases | L1 |
| 2.14 | Surface Area | external scripts enabled = 0 | L1 |
| 2.17 | Surface Area | clr strict security = 1 | L2 |
| 3.1 | Auth | Contained database authentication = 0 | L1 |
| 3.2 | Auth | Guest user disabled in user databases | L1 |
| 3.3 | Auth | BUILTIN\Administrators login not present | L1 |
| 4.1 | Passwords | CHECK_POLICY = ON for all SQL logins | L1 |

### L1 Audit Script

Run this script to check all Level 1 controls in a single pass. Results are emitted as objects so they can be piped to `Export-Csv` or `Out-GridView`.

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $SqlInstance
)

$ErrorActionPreference = 'Stop'

$findings = [System.Collections.Generic.List[PSCustomObject]]::new()

function Add-Finding {
    param($Control, $Section, $Description, $Status, $Detail)
    $findings.Add([PSCustomObject]@{
        Control     = $Control
        Section     = $Section
        Description = $Description
        Status      = $Status
        Detail      = $Detail
    })
}

# --- sp_configure checks ---
$splatCfg = @{
    SqlInstance     = $SqlInstance
    EnableException = $true
}
$cfg = Get-DbaSpConfigure @splatCfg

function Get-CfgValue ($name) {
    ($cfg | Where-Object DisplayName -eq $name).RunningValue
}

$checks = @(
    @{ Control = '2.1';  Section = 'Surface Area'; Desc = 'xp_cmdshell = 0';                    Name = 'xp_cmdshell';                        Expected = 0 }
    @{ Control = '2.3';  Section = 'Surface Area'; Desc = 'Ole Automation Procedures = 0';       Name = 'Ole Automation Procedures';           Expected = 0 }
    @{ Control = '2.4';  Section = 'Surface Area'; Desc = 'Ad Hoc Distributed Queries = 0';      Name = 'Ad Hoc Distributed Queries';          Expected = 0 }
    @{ Control = '2.5';  Section = 'Surface Area'; Desc = 'Database Mail XPs = 0';               Name = 'Database Mail XPs';                   Expected = 0 }
    @{ Control = '2.6';  Section = 'Surface Area'; Desc = 'cross db ownership chaining = 0';     Name = 'cross db ownership chaining';         Expected = 0 }
    @{ Control = '2.8';  Section = 'Surface Area'; Desc = 'clr enabled = 0';                     Name = 'clr enabled';                         Expected = 0 }
    @{ Control = '2.14'; Section = 'Surface Area'; Desc = 'external scripts enabled = 0';        Name = 'external scripts enabled';            Expected = 0 }
    @{ Control = '3.1';  Section = 'Auth';         Desc = 'Contained database authentication = 0'; Name = 'contained database authentication'; Expected = 0 }
)

foreach ($c in $checks) {
    $val = Get-CfgValue $c.Name
    $status = if ($val -eq $c.Expected) { 'PASS' } else { 'FAIL' }
    Add-Finding -Control $c.Control -Section $c.Section -Description $c.Desc -Status $status -Detail "Value: $val"
}

# --- 2.2: SA disabled and renamed ---
$saLogin = Invoke-DbaQuery -SqlInstance $SqlInstance -Query `
    "SELECT name, is_disabled FROM sys.server_principals WHERE sid = 0x01;" -EnableException

$saName      = $saLogin.name
$saDisabled  = $saLogin.is_disabled
$saRenamed   = ($saName -ne 'sa')
$saStatus    = if ($saDisabled -and $saRenamed) { 'PASS' } else { 'FAIL' }
Add-Finding -Control '2.2' -Section 'Auth' -Description 'sa account disabled and renamed' `
    -Status $saStatus -Detail "Name: $saName, Disabled: $saDisabled"

# --- 2.9: TRUSTWORTHY = OFF for all user databases ---
$trustworthy = Get-DbaDatabase -SqlInstance $SqlInstance -ExcludeSystem -EnableException |
    Where-Object { $_.Trustworthy -eq $true }

$twStatus = if ($null -eq $trustworthy) { 'PASS' } else { 'FAIL' }
$twDetail  = if ($null -eq $trustworthy) { 'None' } else { ($trustworthy.Name -join ', ') }
Add-Finding -Control '2.9' -Section 'Database' -Description 'TRUSTWORTHY = OFF for all user databases' `
    -Status $twStatus -Detail "Trustworthy DBs: $twDetail"

# --- 3.2: Guest disabled in user databases ---
$guestQuery = @"
SELECT DB_NAME() AS DatabaseName, dp.name AS Principal, dp.type_desc
FROM sys.database_principals dp
WHERE dp.name = 'guest'
  AND dp.is_disabled = 0
  AND HAS_DBACCESS('guest') = 1;
"@

$guestEnabled = Get-DbaDatabase -SqlInstance $SqlInstance -ExcludeSystem -EnableException |
    ForEach-Object { Invoke-DbaQuery -SqlInstance $SqlInstance -Database $_.Name -Query $guestQuery -EnableException }

$guestStatus = if ($null -eq $guestEnabled) { 'PASS' } else { 'FAIL' }
$guestDetail = if ($null -eq $guestEnabled) { 'None' } else { ($guestEnabled.DatabaseName -join ', ') }
Add-Finding -Control '3.2' -Section 'Auth' -Description 'Guest user disabled in user databases' `
    -Status $guestStatus -Detail "Guest enabled in: $guestDetail"

# --- 3.3: BUILTIN\Administrators not present ---
$builtinAdmin = Get-DbaLogin -SqlInstance $SqlInstance -EnableException |
    Where-Object { $_.Name -like 'BUILTIN\Administrators' -or $_.Name -like 'BUILTIN\Admins' }

$baStatus = if ($null -eq $builtinAdmin) { 'PASS' } else { 'FAIL' }
$baDetail  = if ($null -eq $builtinAdmin) { 'Not present' } else { 'Present — remove immediately' }
Add-Finding -Control '3.3' -Section 'Auth' -Description 'BUILTIN\Administrators login not present' `
    -Status $baStatus -Detail $baDetail

# --- 4.1: CHECK_POLICY = ON for all SQL logins ---
$policyQuery = @"
SELECT name, is_policy_checked, is_expiration_checked
FROM sys.sql_logins
WHERE is_policy_checked = 0 OR is_expiration_checked = 0;
"@
$policyViolators = Invoke-DbaQuery -SqlInstance $SqlInstance -Query $policyQuery -EnableException

$polStatus = if ($null -eq $policyViolators -or $policyViolators.Count -eq 0) { 'PASS' } else { 'FAIL' }
$polDetail  = if ($polStatus -eq 'PASS') { 'All SQL logins have CHECK_POLICY = ON' } else { ($policyViolators.name -join ', ') }
Add-Finding -Control '4.1' -Section 'Passwords' -Description 'CHECK_POLICY = ON for all SQL logins' `
    -Status $polStatus -Detail $polDetail

# --- Output ---
$findings | Sort-Object Control
```

## Related Documents

- [[../Index|Security Index]]
- [[../../Documents/Standards/SQL-Standards-and-Policies|SQL Standards and Policies]]
