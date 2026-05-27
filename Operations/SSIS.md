# SQL Server Integration Services — Operations Guide

## Purpose

Operational reference for deploying and maintaining SQL Server Integration Services. Covers the SSIS Catalog (SSISDB), package deployment, SQL Agent integration, proxy accounts, and monitoring. Not a development guide — for package design, data flow patterns, and script component development, see Microsoft documentation.

---

## SSIS Catalog (SSISDB)

The SSISDB catalog is the central repository for SSIS projects and packages when using the project deployment model. It provides execution logging, parameterization via environments, version history, and execution control. The catalog is a database hosted on a SQL Server instance.

**Prerequisites:**

- CLR integration must be enabled on the instance hosting SSISDB
- SQL Server Agent must be running — catalog maintenance runs as Agent jobs created automatically during catalog creation

```sql
SET NOCOUNT ON;

-- Enable CLR (required before creating the SSISDB catalog)
EXEC [sys].[sp_configure] 'clr enabled', 1;
RECONFIGURE;
```

Create the catalog in SSMS: expand Integration Services Catalogs → right-click → Create Catalog. Check "Enable automatic execution of Integration Services stored procedure at SQL Server startup" and enter an encryption password. This password protects the SSISDB master key — store it in a secure vault. It is required to restore SSISDB to a different server.

```sql
SET NOCOUNT ON;

-- Verify the catalog is healthy after creation
SELECT
    [property_name],
    [property_value]
FROM [SSISDB].[catalog].[catalog_properties]
ORDER BY [property_name];
```

---

## Service Account and Proxy Accounts

**SSIS service account:** The SSIS Windows service (MsDtsServer160 for SQL Server 2022) can run as a gMSA — unlike SSRS, there are no known limitations. Configure via SQL Server Configuration Manager or Services.msc. See [Security Practices](../Security/Security.md#group-managed-service-accounts-gmsa) for gMSA setup.

**Package execution accounts:** When packages run as SQL Agent job steps, they execute under the Agent service account by default. Use proxy accounts to run packages under a different Windows identity — for example, a package that writes to a file share, connects to an SFTP server, or accesses a database where the Agent account has no rights.

```powershell
# Create a Windows credential to back the proxy
$splatCred = @{
    SqlInstance     = 'SqlServer01'
    Name            = 'SSIS_ETL_Credential'
    Identity        = 'CORP\svc-ssis-etl'
    SecurePassword  = (Read-Host -AsSecureString 'Enter password for CORP\svc-ssis-etl')
    EnableException = $true
}
New-DbaCredential @splatCred

# Create the Agent proxy backed by that credential
$splatProxy = @{
    SqlInstance     = 'SqlServer01'
    ProxyName       = 'SSIS ETL Proxy'
    Credential      = 'SSIS_ETL_Credential'
    SubSystem       = 'SSIS'
    EnableException = $true
}
New-DbaAgentProxy @splatProxy
```

---

## Project Deployment Model

SQL Server 2012 and later support the project deployment model — `.ispac` files deployed to SSISDB. This is the current standard. The legacy package deployment model (individual `.dtsx` files deployed to the file system or msdb) should only be used when required by legacy tooling that cannot be updated.

**Deploy a project:**

```powershell
# Deploy an .ispac file to SSISDB
$splatDeploy = @{
    SqlInstance     = 'SqlServer01'
    FolderName      = 'ETL'
    ProjectFilePath = 'C:\Deploy\MyProject.ispac'
    EnableException = $true
}
Publish-DbaIspac @splatDeploy
```

Or via SSMS: Integration Services Catalogs → SSISDB → expand the target folder → right-click Projects → Deploy Project → select the `.ispac` file.

Each deployment creates a new project version in SSISDB. Prior versions are retained up to the configured maximum and can be used to roll back a deployment.

---

## Environments and Parameters

Environments allow the same project to execute with different parameter values (connection strings, file paths, flags) without redeployment. The standard pattern is one environment per deployment tier.

```sql
SET NOCOUNT ON;

-- Create a folder and environment
EXEC [SSISDB].[catalog].[create_folder]
    @folder_name = N'ETL';

EXEC [SSISDB].[catalog].[create_environment]
    @folder_name      = N'ETL',
    @environment_name = N'Production';

-- Add a variable to the environment
EXEC [SSISDB].[catalog].[create_environment_variable]
    @folder_name      = N'ETL',
    @environment_name = N'Production',
    @variable_name    = N'SourceConnectionString',
    @data_type        = N'String',
    @sensitive        = 0,
    @value            = N'Data Source=SQL-SOURCE;Initial Catalog=SourceDB;Integrated Security=True';

-- Reference the environment from the project (relative reference — same folder)
EXEC [SSISDB].[catalog].[create_environment_reference]
    @folder_name      = N'ETL',
    @project_name     = N'MyProject',
    @environment_name = N'Production',
    @reference_type   = 'R';
```

---

## Package Protection Levels

SSIS packages encrypt sensitive data (connection string passwords, etc.) according to a protection level set in the package properties. This matters most when packages are moved between environments or stored outside SSISDB.

| Protection Level | Behavior | Use When |
|---|---|---|
| `DontSaveSensitive` | Sensitive values stripped on save | All credentials managed via project parameters and SSISDB environments |
| `EncryptSensitiveWithPassword` | Sensitive values encrypted with a password | Packages distributed outside SSISDB |
| `EncryptAllWithPassword` | Entire package encrypted with a password | Packages stored on file system requiring full protection |
| `EncryptSensitiveWithUserKey` | Encrypted with the current Windows user's key | Development only — breaks when a different account opens the package |
| `ServerStorage` | Encryption delegated to SSISDB | Standard choice for project deployment model |

For packages deployed to SSISDB, `ServerStorage` or `DontSaveSensitive` (with all sensitive values supplied via environments) are the correct choices. `EncryptSensitiveWithUserKey` will cause failures when packages execute under a service account.

---

## SQL Agent Integration

Packages deployed to SSISDB are executed via SQL Agent job steps of type "SQL Server Integration Services Package."

Key job step settings:

| Setting | Value |
|---|---|
| Package source | SSIS Catalog |
| Server | SQL Server instance hosting SSISDB |
| Package path | `/FolderName/ProjectName/PackageName.dtsx` |
| Environment | Select the environment reference to apply |
| Run as | Set to the SSIS proxy if the step needs non-Agent credentials |
| Logging level | Basic for production; Verbose for active troubleshooting only |

```powershell
# Create an Agent job to execute an SSIS package
$splatJob = @{
    SqlInstance     = 'SqlServer01'
    Job             = 'ETL - Daily Load'
    Description     = 'Nightly ETL load from source system'
    Category        = 'Data Warehouse'
    EnableException = $true
}
New-DbaAgentJob @splatJob

# Add an SSIS package step
# The Command for SSIS Catalog steps is the package path — the Agent subsystem handles the rest
$splatStep = @{
    SqlInstance      = 'SqlServer01'
    Job              = 'ETL - Daily Load'
    StepName         = 'Execute MainPackage'
    SubSystem        = 'SSIS'
    Command          = '/ISSERVER "\SSISDB\ETL\MyProject\MainPackage.dtsx" /SERVER "SqlServer01" /ENVREFERENCE 1 /X86 False /REPORTING E'
    ProxyName        = 'SSIS ETL Proxy'
    EnableException  = $true
}
New-DbaAgentJobStep @splatStep
```

---

## Monitoring

```sql
SET NOCOUNT ON;

-- Currently running executions
SELECT
    [execution_id],
    [folder_name],
    [project_name],
    [package_name],
    [status],
    [start_time],
    DATEDIFF(SECOND, [start_time], GETUTCDATE())    AS running_seconds
FROM [SSISDB].[catalog].[executions]
WHERE [status] = 2   -- 2 = Running
ORDER BY [start_time];

-- Recent failures (last 7 days)
SELECT TOP 50
    [execution_id],
    [folder_name],
    [project_name],
    [package_name],
    [status],
    [start_time],
    [end_time],
    DATEDIFF(SECOND, [start_time], [end_time])      AS duration_seconds
FROM [SSISDB].[catalog].[executions]
WHERE [status] = 4   -- 4 = Failed
  AND [start_time] >= DATEADD(DAY, -7, GETUTCDATE())
ORDER BY [start_time] DESC;

-- Error and warning messages for a specific execution
SELECT
    [message_time],
    [message_type],
    [message_source_name],
    [message]
FROM [SSISDB].[catalog].[event_messages]
WHERE [operation_id] = <execution_id>
  AND [message_type] IN (120, 130)   -- 120 = Error, 130 = Task Failed
ORDER BY [message_time];
```

Execution status codes: 1 = Created, 2 = Running, 3 = Cancelled, 4 = Failed, 5 = Pending, 7 = Succeeded, 9 = Completed.

---

## SSISDB Maintenance

The catalog creates two Agent jobs during initialization:

- **SSIS Server Maintenance Job** — cleans up execution history and event messages per the retention policy. Runs daily.
- **SSIS Server Stop Operation** — stops executions that exceed the maximum duration. Runs every minute.

Do not disable these jobs. If execution history is growing faster than the retention policy removes it, reduce the retention window or increase the job frequency via the job schedule.

```sql
SET NOCOUNT ON;

-- Set execution history retention (days) — default is 365
EXEC [SSISDB].[catalog].[configure_catalog]
    @property_name  = N'RETENTION_WINDOW',
    @property_value = 30;

-- Set maximum stored versions per project — older versions are purged automatically
EXEC [SSISDB].[catalog].[configure_catalog]
    @property_name  = N'MAX_PROJECT_VERSIONS',
    @property_value = 10;
```

```powershell
# Monitor SSISDB size — the internal version and log tables can grow large over time
$splatSize = @{
    SqlInstance     = 'SqlServer01'
    Database        = 'SSISDB'
    EnableException = $true
}
Get-DbaDbSpace @splatSize | Select-Object DatabaseName, FileName, UsedMB, AvailableMB
```

---

## SSISDB in Always On Availability Groups

SSISDB can be added to an AG for database-level high availability, but it requires additional steps beyond a standard user database because of its internal CLR objects and Agent job dependencies.

Key considerations:

- Add SSISDB to the AG using the standard process (backup → restore with NORECOVERY → join). The database will synchronize normally.
- The SSIS catalog maintenance Agent jobs (SSIS Server Maintenance Job, SSIS Server Stop Operation) exist only on the server where the catalog was created. They must be recreated on AG secondaries so they are available after failover. On SQL Server 2022 Enterprise with a Contained AG, jobs synchronize automatically.
- After a failover, SSIS execution continues against the new primary without redeployment. Active executions at the time of failover do not resume and must be restarted.
- Connection strings in SSISDB environments that reference the old primary server name must point to the AG listener, not the node name, to function after failover.

```powershell
# Verify SSISDB is synchronizing correctly in the AG
$splatAg = @{
    SqlInstance     = 'SqlServer01'
    AvailabilityGroup = 'AG_Production'
    EnableException = $true
}
Get-DbaAgDatabase @splatAg |
    Where-Object DatabaseName -eq 'SSISDB' |
    Select-Object AvailabilityGroup, DatabaseName, SynchronizationState, SynchronizationHealth
```

---

## Backup

```powershell
# SSISDB is a standard user database — back it up on the same schedule as other production databases
$splatBackup = @{
    SqlInstance     = 'SqlServer01'
    Database        = 'SSISDB'
    Type            = 'Full'
    BackupDirectory = '\\BackupShare\SQLBackups\SSISDB'
    CompressBackup  = $true
    EnableException = $true
}
Backup-DbaDatabase @splatBackup
```

The SSISDB master key password (set during catalog creation) is required to restore SSISDB to a different server. Store it in a secure vault alongside the backup files — losing it makes the backup unrestorable on a new instance.

---

## Related Documents

- [Security Practices](../Security/Security.md) — service accounts, gMSA, and proxy credential security
- [SQL Agent Job Standards](../Standards/Agent-Job-Standards.md) — job naming, step configuration, and proxy accounts
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — SSISDB AG placement and post-failover steps
- [Monitoring](Monitoring.md) — instance-level monitoring that complements SSISDB execution monitoring
