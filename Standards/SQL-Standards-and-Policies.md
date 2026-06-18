# SQL Standards and Policies

## Purpose

Define mandatory standards and governance controls for SQL Server operations, configuration, and documentation.

## Scope

This policy applies to all SQL Server instances, databases, jobs, availability groups, linked servers, and associated operational processes managed by Outdoor Network.

## Responsibilities

- DBA team: enforce standards, maintain documentation, approve changes.
- Operations staff: follow documented runbooks and report deviations.
- Application teams: provide requirements for recovery, availability, and performance.

## Instance and Database Configuration

- Use supported SQL Server versions and patch levels.
- Standardize service account usage and document service dependencies.
- Enable and configure instance-level security options in line with corporate policy.
- Enforce database settings according to environment purpose and compliance needs.

## Backup Policy

- Full backups at least once per day for production databases.
- Transaction log backups at an interval appropriate to recovery point objectives.
- Retain backups according to business, compliance, and legal requirements.
- Encrypt backups when storing off-site or on shared storage.

## High Availability and Disaster Recovery

- Define availability requirements for each database.
- Document AG/Failover Cluster/DR topology and failover behavior.
- Test HA/DR failover or failback at least annually.
- Keep runbooks for failover, recovery, and disaster scenarios current.

## Change Control and Deployment

- All production changes require documented approval and rollback planning.
- Use code review and version control for SQL changes and automation scripts.
- Track configuration drift and correct it with approved remediation.

## Security and Access

- Authenticate users through Windows or integrated authentication where possible.
- Restrict sysadmin-level access to authorized individuals only.
- Document every service account, login, role, and privilege assignment.
- Review high-privilege access quarterly.

## Maintenance and Housekeeping

- Schedule maintenance windows and communicate them in advance.
- Capture and retain maintenance history for each instance.
- Clean up orphaned objects, unused logins, and stale jobs on a planned basis.

## Audit and Compliance

- Record audit findings and remediation actions in the instance audit logs.
- Use standard naming and categorization for audit entries.
- Maintain compliance documentation for regulatory or corporate requirements.

## Documentation Standards

- Store operational procedures in `Operations/Documents`.
- Keep instance-level notes under `Instances/<instance>/...`.
- Use clear, concise titles and add a date/version note for major updates.
- Document exceptions with justification and approval metadata.

## Review and Exceptions

- Review this policy annually or when architecture changes.
- Exceptions must be documented, approved, and time-bound.
- Revoke expired exceptions and bring the environment into compliance.

---

## Configuration Compliance Audit

The following dbatools script checks each instance against the core configuration standards above. It does not replace the CIS Benchmark audit in [[../Security/Security-Practices|Security Practices]] — that covers security-specific controls. This script focuses on operational settings that affect reliability, recoverability, and performance.

```powershell
[CmdletBinding()]
param (
    [Parameter(Mandatory)]
    [string[]] $SqlInstance
)

$ErrorActionPreference = 'Stop'

foreach ($instance in $SqlInstance) {
    $splatConnect = @{
        SqlInstance     = $instance
        EnableException = $true
    }

    $srv = Connect-DbaInstance @splatConnect

    # Backup compression default
    $backupComp = (Get-DbaSpConfigure -SqlInstance $instance -Name DefaultBackupCompression).ConfiguredValue

    # Optimize for ad hoc workloads
    $adHoc = (Get-DbaSpConfigure -SqlInstance $instance -Name OptimizeForAdHocWorkloads).ConfiguredValue

    # Remote DAC
    $dac = (Get-DbaSpConfigure -SqlInstance $instance -Name RemoteDacConnectionsEnabled).ConfiguredValue

    # Max memory
    $memRec = Test-DbaMaxMemory -SqlInstance $instance
    $memStatus = if ($memRec.CurrentMaxValue -le $memRec.RecommendedValue) { 'OK' } else { 'OVER' }

    # MAXDOP
    $dopRec = Test-DbaMaxDop -SqlInstance $instance
    $dopStatus = if ($dopRec.CurrentInstanceMaxDop -eq $dopRec.RecommendedMaxDop) { 'OK' } else { 'DRIFT' }

    # CTFP
    $ctfp = (Get-DbaSpConfigure -SqlInstance $instance -Name CostThresholdForParallelism).ConfiguredValue
    $ctfpStatus = if ($ctfp -ge 25) { 'OK' } else { 'LOW' }

    # Databases with autoshrink on
    $autoShrink = Get-DbaDatabase -SqlInstance $instance |
        Where-Object { $_.AutoShrink -eq $true } |
        Select-Object -ExpandProperty Name

    # Databases on Simple recovery in prod context
    $simpleRecovery = Get-DbaDatabase -SqlInstance $instance -ExcludeSystemDb |
        Where-Object { $_.RecoveryModel -eq 'Simple' } |
        Select-Object -ExpandProperty Name

    [PSCustomObject]@{
        Instance          = $instance
        BackupCompression = if ($backupComp -eq 1) { 'OK' } else { 'DISABLED' }
        AdHocWorkloads    = if ($adHoc -eq 1) { 'OK' } else { 'DISABLED' }
        RemoteDAC         = if ($dac -eq 1) { 'OK' } else { 'DISABLED' }
        MaxMemory         = $memStatus
        MaxDop            = $dopStatus
        CTFP              = $ctfpStatus
        AutoShrinkDBs     = ($autoShrink -join ', ')
        SimpleRecoveryDBs = ($simpleRecovery -join ', ')
    }
}
```

Run this across the environment to identify gaps. `DRIFT`, `OVER`, `LOW`, and `DISABLED` values need review.

## See Also

- [[Development-and-Configuration-Standards|Development and Configuration Standards]]
- [[Dynamics-GP-Standards|Dynamics GP Standards]]
- [[../Security/Security-Practices|Security Practices]]
- [[Standards|Standards Index]]
