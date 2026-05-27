# SQL Server 2025 Readiness Guide

## Purpose

Forward-looking upgrade planning guide for environments running SQL Server 2022 that are evaluating a move to SQL Server 2025. SQL Server 2025 introduces two categories of change that require preparation before upgrade day: **breaking changes** that will cause application failures if not addressed in advance, and **new features** worth evaluating after upgrade.

The breaking changes — particularly the mandatory encryption enforcement — are the reason to read this document before the upgrade, not after.

---

## Breaking Changes — Act Before Upgrading

### 1. Encrypt=Mandatory by Default

> **Warning:** This is the highest-impact change in SQL Server 2025 for most environments. Any client or tool that connects without a trusted server certificate will fail after upgrading.

SQL Server 2025 enforces `Encrypt=Mandatory` at the server level by default. Prior versions defaulted to `Encrypt=Optional`, where the client controlled whether the connection was encrypted.

**What breaks:**
- Applications with connection strings that do not specify `Encrypt=True` or rely on `TrustServerCertificate=True`
- SSMS connections to instances without a CA-trusted certificate installed
- dbatools connections using default connection behavior
- Monitoring tools, ETL jobs, linked server connections, and any other SQL Server client

**What you must do before upgrading:**
1. Install a CA-issued certificate on every SQL Server 2025 instance — see [TLS Configuration](../Security/TLS-Configuration.md)
2. Audit all application connection strings for `TrustServerCertificate=True` and update them to trust the CA instead
3. Test all application connections against a SQL Server 2025 test instance before promoting to production
4. Update SSMS to version 22 or later — it handles the new encryption defaults correctly

```powershell
# Audit current connections to identify those not using encryption
# Run this on your SQL Server 2022 instances before upgrade to understand scope
$splatAudit = @{
    SqlInstance     = $instance
    EnableException = $true
}
Invoke-DbaQuery @splatAudit -Query @'
SET NOCOUNT ON;

SELECT
    [session_id],
    [login_name],
    [host_name],
    [program_name],
    [encrypt_option]
FROM [sys].[dm_exec_connections] AS c
JOIN [sys].[dm_exec_sessions]   AS s
    ON c.[session_id] = s.[session_id]
WHERE s.[is_user_process] = 1
  AND c.[encrypt_option] <> 'TRUE'
ORDER BY [program_name];
'@
```

Any row returned in that query represents a connection that will fail after upgrading to SQL Server 2025 with default settings.

### 2. TrustServerCertificate=False Enforced

Related to the encryption change: SQL Server 2025 does not allow clients to bypass certificate validation with `TrustServerCertificate=True` when the server is configured for mandatory encryption. Connection strings that rely on this flag must be updated to use a connection that trusts the server certificate through the OS certificate store.

### 3. Standard Edition Core and Memory Limits

SQL Server 2025 Standard Edition caps at **32 cores** (up from 24 in SQL Server 2019/2022) and adjusts buffer pool memory limits. Review the [Microsoft Licensing documentation](https://www.microsoft.com/en-us/sql-server/sql-server-2025) for current limits before upgrade if Standard Edition is in use.

### 4. Removed Features

- The Database Tuning Advisor (DTA) is deprecated and removed; use Query Store recommendations and IQP instead
- Some DMV columns added deprecated status — run the deprecated features query before upgrade

```sql
SET NOCOUNT ON;

SELECT
    [instance_name],
    [name],
    [cntr_value] AS usage_count
FROM [sys].[dm_os_performance_counters]
WHERE [object_name] LIKE '%Deprecated%'
  AND [cntr_value] > 0
ORDER BY [cntr_value] DESC;
```

---

## Pre-Upgrade Assessment

Microsoft provides an assessment tool integrated into SSMS 22+ (Migration Component) that evaluates compatibility issues before upgrade.

```powershell
# Collect build and edition information across all instances before planning
$splatBuild = @{
    SqlInstance     = $instances
    EnableException = $true
}
Test-DbaBuild @splatBuild |
    Select-Object SqlInstance, Build, BuildTarget, Compliant |
    Sort-Object SqlInstance

# Supported direct upgrade paths to SQL Server 2025:
# SQL Server 2016 SP3+ → 2025
# SQL Server 2017 → 2025
# SQL Server 2019 → 2025
# SQL Server 2022 → 2025
# Anything older requires an intermediate version upgrade
```

---

## New Features Worth Evaluating Post-Upgrade

### Optional Parameter Plan Optimization (OPPO)

PSPO (introduced in SQL Server 2022) generates multiple plans at compile time based on statistics. OPPO goes further: it generates alternative plans at runtime for different parameter values, operating at the optimizer level rather than the compilation level.

OPPO is disabled by default and must be enabled per database:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
```

OPPO is most valuable for stored procedures with wide parameter value distributions where PSPO has not fully resolved the sniffing problem. Monitor via Query Store to identify before/after plan behavior.

### IQP 3.0 at Compatibility Level 170

Compatibility level 170 activates the next generation of Intelligent Query Processing improvements. As with prior versions, do not change the compatibility level until applications are tested at 170.

Key additions at level 170:
- Extended CE feedback coverage — more query patterns receive cardinality feedback
- Improved DOP feedback granularity
- Batch mode adaptive joins — additional operators eligible for adaptive join behavior

### TempDB Resource Limits

SQL Server 2025 adds the ability to set resource limits on individual TempDB usage per session or workload group via Resource Governor. This prevents runaway queries from consuming all TempDB space and impacting other sessions.

Configuration requires Resource Governor (Enterprise Edition):

```sql
CREATE WORKLOAD GROUP [BulkLoads]
    WITH (TEMPDB_SPILL_PERCENT = 20);   -- Limit this group to 20% of TempDB space
```

---

## SQL Server 2025 vs. 2022 Feature Matrix

| Feature | SQL Server 2022 | SQL Server 2025 |
|---|---|---|
| Encrypt=Mandatory default | No (optional) | **Yes — breaking change** |
| TrustServerCertificate bypass | Allowed | **Blocked** |
| PSPO | Yes | Yes (improved) |
| OPPO | No | **Yes** |
| IQP compatibility level | 160 | **170** |
| TempDB resource limits | No | **Yes** (Enterprise) |
| TLS 1.3 support | Yes | Yes |
| Standard Edition max cores | 24 | **32** |

---

## Recommended Preparation Timeline

| Timeframe | Action |
|---|---|
| 6+ months before upgrade | Install CA-issued certificates on all target instances |
| 4 months before | Audit all application connection strings |
| 3 months before | Upgrade SSMS to version 22+ on all DBA workstations |
| 2 months before | Deploy SQL Server 2025 to a test environment; connect all application stacks |
| 1 month before | Run pre-upgrade deprecated features assessment on all production instances |
| Upgrade day | Validate all connections post-upgrade; verify Agent jobs, linked servers, monitoring tools |

---

## Related Documents

- [TLS Configuration](../Security/TLS-Configuration.md) — certificate installation and connection encryption standards
- [SQL Server 2022 Readiness](SQL-2022-Readiness.md) — prior version features and patterns
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — Contained AG for SQL 2022+ Enterprise
