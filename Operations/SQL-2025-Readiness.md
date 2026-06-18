# SQL Server 2025 Readiness

## Purpose

Forward-looking upgrade planning guide for environments evaluating a move to SQL Server 2025. SQL Server 2025 introduces two categories of change that require preparation before upgrade day: **breaking changes** that will cause application failures if not addressed in advance, and **new features** worth evaluating after upgrade.

The breaking changes — particularly mandatory encryption enforcement — are the reason to read this document before the upgrade, not after.

---

## Breaking Changes — Act Before Upgrading

### 1. Encrypt=Mandatory by Default

> **Warning:** This is the highest-impact change in SQL Server 2025 for most environments. Any client or tool that connects without a trusted server certificate will fail after upgrading.

SQL Server 2025 enforces `Encrypt=Mandatory` at the server level by default. Prior versions defaulted to `Encrypt=Optional`.

**What breaks:**
- Applications with connection strings that do not specify `Encrypt=True` or rely on `TrustServerCertificate=True`
- SSMS connections to instances without a CA-trusted certificate installed
- dbatools connections using default connection behavior
- Monitoring tools, ETL jobs, linked server connections, and any other SQL Server client

**What you must do before upgrading:**
1. Install a CA-issued certificate on every SQL Server 2025 instance — see [[../Security/TLS-Configuration|TLS Configuration]]
2. Audit all application connection strings for `TrustServerCertificate=True` and update them to trust the CA instead
3. Test all application connections against a SQL Server 2025 test instance before promoting to production
4. Update SSMS to version 22 or later

```powershell
# Audit current connections to identify those not using encryption
# Run this on SQL Server 2022 instances before upgrade to understand scope
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
JOIN [sys].[dm_exec_sessions]    AS s
    ON c.[session_id] = s.[session_id]
WHERE s.[is_user_process] = 1
  AND c.[encrypt_option] <> 'TRUE'
ORDER BY [program_name];
'@
```

Any row returned represents a connection that will fail after upgrading to SQL Server 2025.

### 2. TrustServerCertificate=False Enforced

SQL Server 2025 does not allow clients to bypass certificate validation with `TrustServerCertificate=True` when the server is configured for mandatory encryption. Connection strings that rely on this flag must be updated to trust the server certificate through the OS certificate store.

### 3. Standard Edition Core and Memory Limits

SQL Server 2025 Standard Edition caps at **32 cores** (up from 24 in SQL Server 2019/2022). Review Microsoft licensing documentation for current buffer pool memory limits before upgrade if Standard Edition is in use.

### 4. Removed Features

The Database Tuning Advisor (DTA) is removed; use Query Store recommendations and IQP instead. Run the deprecated features query before upgrade:

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

```powershell
# Collect build and edition information across all instances
$splatBuild = @{
    SqlInstance     = $instances
    EnableException = $true
}
Test-DbaBuild @splatBuild |
    Select-Object SqlInstance, Build, BuildTarget, Compliant |
    Sort-Object SqlInstance

# Supported direct upgrade paths to SQL Server 2025:
# SQL Server 2016 SP3+ → 2025
# SQL Server 2017      → 2025
# SQL Server 2019      → 2025
# SQL Server 2022      → 2025
# Older versions require an intermediate upgrade
```

---

## New Features Worth Evaluating Post-Upgrade

### Optional Parameter Plan Optimization (OPPO)

PSPO (SQL Server 2022) generates multiple plans at compile time based on statistics. OPPO goes further — it generates alternative plans at runtime for different parameter values. OPPO is disabled by default and must be enabled per database:

```sql
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SENSITIVE_PLAN_OPTIMIZATION = ON;
```

Most valuable for stored procedures with wide parameter value distributions where PSPO has not fully resolved the sniffing problem.

### IQP 3.0 at Compatibility Level 170

Compatibility level 170 activates the next generation of Intelligent Query Processing. Do not change the compatibility level until applications are tested at 170.

Key additions:
- Extended CE feedback coverage
- Improved DOP feedback granularity
- Batch mode adaptive joins — additional operators eligible for adaptive join behavior

### TempDB Resource Limits

SQL Server 2025 adds the ability to set TempDB usage limits per workload group via Resource Governor (Enterprise Edition). This prevents runaway queries from consuming all TempDB space.

```sql
CREATE WORKLOAD GROUP [BulkLoads]
    WITH (TEMPDB_SPILL_PERCENT = 20);   -- Limit to 20% of TempDB space
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
| 1 month before | Run deprecated features assessment on all production instances |
| Upgrade day | Validate all connections post-upgrade; verify Agent jobs, linked servers, monitoring tools |

---

## Related Documents

- [[../Security/TLS-Configuration|TLS Configuration]] — certificate installation and connection encryption standards
- [[SQL-2022-Readiness|SQL Server 2022 Readiness]] — prior version features and patterns
- [[../Disaster-Recovery/Availability-Groups|Availability Groups]] — Contained AG for SQL Server 2022+ Enterprise
- [[Operations|Back to Operations]]
