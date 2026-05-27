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

### Group Managed Service Accounts (gMSA)

gMSA is the recommended account type for the SQL Server service itself — the account SQL Server Engine, Agent, and SSAS run as. AD manages the password automatically, rotating it every 30 days without any intervention. This eliminates service disruptions from expired passwords and removes the need to store service account passwords anywhere.

This section covers SQL Server service accounts. Application accounts that connect to SQL Server (covered above) can also be gMSA, but the primary benefit is for the service accounts.

**Prerequisites:**
- Windows Server 2012 R2 or later domain controllers
- KDS root key configured in the forest — one-time setup, requires domain admin
- An AD security group that controls which computer accounts can retrieve the gMSA password

**Supported and unsupported services:**

| SQL Server Service | gMSA Supported |
|---|---|
| SQL Server Engine (standalone instance) | Yes |
| SQL Server Engine (Availability Group node) | Yes |
| SQL Server Agent | Yes |
| SQL Server Analysis Services | Yes |
| SQL Server Integration Services | Yes |
| SQL Server Browser | No |
| SQL Server FCI service account | **No** — requires a traditional domain account |
| SQL Server Reporting Services | **No** — RS Configuration Manager does not support gMSA |

**FCI limitation:** Failover Cluster Instances require a traditional domain account. The clustering service must authenticate during failover transitions using credentials that gMSA cannot provide in that context.

**SSRS limitation:** The Reporting Services Configuration Manager does not support gMSA as the RS service account. Changing the service to gMSA via Services.msc will be overwritten the next time RS Configuration Manager applies a setting change. Use a dedicated domain account for SSRS — see [SSRS Operations](../Operations/SSRS.md).

**Setup:**

```powershell
# One-time per forest: create the KDS root key (run on a domain controller, domain admin required)
# -EffectiveImmediately bypasses the 10-hour propagation delay — acceptable in lab, not production
Add-KdsRootKey -EffectiveTime ((Get-Date).AddHours(-10))

# Create an AD group to control which servers can retrieve this gMSA's password
New-ADGroup -Name 'gMSA-SQLServer01' -GroupScope DomainLocal -Path 'OU=ServiceAccounts,DC=corp,DC=example,DC=com'
Add-ADGroupMember -Identity 'gMSA-SQLServer01' -Members 'SQLSERVER01$'   # computer account, note the $

# Create the gMSA
$splatGmsa = @{
    Name                                         = 'svc-sql01'
    SamAccountName                               = 'svc-sql01'
    DNSHostName                                  = 'svc-sql01.corp.example.com'
    PrincipalsAllowedToRetrieveManagedPassword   = 'gMSA-SQLServer01'
    Path                                         = 'OU=ServiceAccounts,DC=corp,DC=example,DC=com'
    Enabled                                      = $true
}
New-ADServiceAccount @splatGmsa

# Install the gMSA on the target SQL Server (run on the SQL Server, not a DC)
Install-ADServiceAccount -Identity 'svc-sql01'

# Verify the gMSA can be retrieved by this server
Test-ADServiceAccount -Identity 'svc-sql01'
```

**Configure SQL Server to use the gMSA:**

Use SQL Server Configuration Manager → SQL Server Services → right-click the service → Properties → Log On. Enter `DOMAIN\svc-sql01$` (trailing `$` is required). Leave the password fields blank — the system retrieves the password automatically.

```powershell
# Alternatively, via dbatools
$splatSvc = @{
    ComputerName   = 'SqlServer01'
    ServiceName    = 'MSSQLSERVER'
    ServiceAccount = 'CORP\svc-sql01$'
    SecurePassword = (New-Object System.Security.SecureString)
    EnableException = $true
}
Set-DbaService @splatSvc
```

**Replication and linked server considerations:**

When SQL Server Engine runs as a gMSA, distributed operations that use the current security context — linked server connections configured as "Be made using the login's current security context," and replication agent connections — authenticate as the gMSA. Two additional steps are required:

1. **Register SPNs for the gMSA** — without correct SPNs, Kerberos authentication fails and connections fall back to NTLM or fail entirely:

```powershell
# Run on a domain controller or with domain admin rights
# Replace port and FQDN to match the environment
setspn -S MSSQLSvc/SqlServer01.corp.example.com:1433 CORP\svc-sql01$
setspn -S MSSQLSvc/SqlServer01:1433 CORP\svc-sql01$
```

2. **Configure Kerberos constrained delegation** — if the linked server or replication distributor is on a different server, configure constrained delegation on the gMSA object in Active Directory (ADUC → gMSA account → Delegation tab → Trust this account for delegation to specified services only). Unconstrained delegation should be avoided — it allows the account to impersonate any service, which is a significant attack surface.

Replication agents (Distribution Agent, Snapshot Agent, Merge Agent) that run as separate Windows processes can themselves use gMSA accounts. Assign the appropriate gMSA to each agent's process account in the replication job step security settings.

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
| dr_RO | SELECT on all user tables and views | Reporting, read-only analysts |
| dr_EO | EXECUTE on all stored procedures and functions | Applications using stored procedure access patterns |
| dr_RE | SELECT + EXECUTE | Applications that need both read and execute |
| dr_RW | SELECT + INSERT + UPDATE + DELETE | Applications using inline queries (avoid when possible) |
| dr_RWE | SELECT + INSERT + UPDATE + DELETE + EXECUTE | Legacy applications with mixed access patterns |

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

-- Read-Write
CREATE ROLE [dr_RW];
GRANT SELECT TO [dr_RW];
GRANT INSERT TO [dr_RW];
GRANT UPDATE TO [dr_RW];
GRANT DELETE TO [dr_RW];

-- Read-Write-Execute
CREATE ROLE [dr_RWE];
GRANT SELECT TO [dr_RWE];
GRANT INSERT TO [dr_RWE];
GRANT UPDATE TO [dr_RWE];
GRANT DELETE TO [dr_RWE];
GRANT EXECUTE TO [dr_RWE];
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