# SQL Server Reporting Services — Operations Guide

## Purpose

Operational reference for installing, configuring, and maintaining SQL Server Reporting Services. This guide covers the Report Server service — not report authoring, RDLC development, or DAX model design.

SSRS 2017 and later ships as a standalone installer separate from the SQL Server setup media. SSRS 2016 and earlier are installed as a SQL Server feature. All content below applies to SSRS 2017 and later unless noted.

---

## Service Account

SSRS requires a dedicated domain service account. **Group Managed Service Accounts (gMSA) are not supported** — the Reporting Services Configuration Manager does not recognize gMSA accounts, and changes made via Services.msc are overwritten when RS Configuration Manager applies any subsequent setting. See [Security Practices](../Security/Security.md#group-managed-service-accounts-gmsa) for the full gMSA compatibility matrix.

Use a standard domain account with a managed password policy. Minimum rights:

- **Log on as a service** (granted automatically during installation)
- No local administrator rights required
- No SQL Server login required on the instance hosting the Report Server database — the installer grants the necessary permissions automatically

---

## Initial Configuration

After installing SSRS, open the Reporting Services Configuration Manager (`RSConfigTool.exe`) and work through each section in order.

| Step | What to Configure |
|---|---|
| Service Account | Domain account for the RS Windows service |
| Web Service URL | Endpoint applications connect to — configure HTTPS before going to production |
| Database | Create or connect to an existing ReportServer database |
| Web Portal URL | Browser-based management interface |
| Email Settings | SMTP server for subscription delivery |
| Encryption Keys | Export immediately after initial configuration (see below) |

RS Configuration Manager is also the tool for any subsequent changes to these settings. Direct edits to `RSReportServer.config` are supported for advanced settings not exposed in the UI, but the Config Manager UI is authoritative for the settings it manages.

---

## Report Server Database

SSRS creates two databases: `ReportServer` and `ReportServerTempDB`. Both are standard SQL Server databases and can be hosted on any reachable SQL Server instance — they do not need to live on the same instance as the data sources.

Placement recommendations:

- Avoid hosting on a heavily loaded production OLTP instance
- `ReportServer` should use the Full recovery model — it holds subscription schedules, report definitions, and execution history that warrant point-in-time recovery
- `ReportServerTempDB` can use Simple recovery model; it is rebuilt automatically if lost

```powershell
# Verify recovery models on the RS databases
$splatDb = @{
    SqlInstance     = 'SqlServer01'
    EnableException = $true
}
Get-DbaDatabase @splatDb |
    Where-Object Name -in 'ReportServer', 'ReportServerTempDB' |
    Select-Object Name, RecoveryModel, Status
```

---

## Encryption Key — Critical

SSRS encrypts stored credentials (data source passwords) and subscription delivery addresses using a symmetric key stored on the server. If this key is lost, all encrypted content is permanently unrecoverable — every data source using stored credentials and every email subscription must be reconfigured manually.

**Export the encryption key immediately after initial configuration and after any service account change.**

```powershell
# Export the encryption key (run on the SSRS server)
# Store the .snk file and password in a secure vault — both are required for restoration
rskeymgmt -e -f 'X:\SSRS\Keys\ReportServer_Key_2025-01-01.snk' -p 'StrongEncryptionKeyPassword'
```

To restore the key on a replacement or scale-out server:

```powershell
rskeymgmt -a -f 'X:\SSRS\Keys\ReportServer_Key_2025-01-01.snk' -p 'StrongEncryptionKeyPassword'
```

If the key is lost and cannot be restored, delete all encrypted content as a last resort — this allows SSRS to start clean, but all stored credentials and subscriptions must be re-entered:

```powershell
# Last resort only — permanently removes all encrypted content
rskeymgmt -d
```

---

## URL Configuration

SSRS registers its URLs directly with HTTP.SYS — it does not use IIS. Two URLs are configured:

- **Web Service URL** — `https://MachineName/ReportServer` — the endpoint for SSMS, applications, and API clients
- **Web Portal URL** — `https://MachineName/Reports` — the browser-based management and report browsing interface

For production, configure HTTPS before deploying reports:

1. Install a CA-issued certificate on the SSRS server matching the FQDN users will connect to
2. In RS Configuration Manager → Web Service URL → Advanced → Add HTTPS binding → select the certificate
3. Repeat for Web Portal URL
4. Remove or leave the HTTP bindings — HTTP.SYS does not support automatic HTTP-to-HTTPS redirection natively; if HTTP must be blocked, remove the HTTP reservation via `netsh http delete urlacl`

---

## Subscriptions

Subscriptions are scheduled report deliveries to email, file share, or SharePoint. SQL Server Agent handles the scheduling — **Agent must be running and the RS-created Agent jobs must not be disabled or deleted.** SSRS creates Agent jobs prefixed with `RSSubscriptions` automatically when subscriptions are created.

Email delivery requires SMTP configuration in RS Configuration Manager → Email Settings. SSRS has its own SMTP client and is independent of Database Mail — configuring Database Mail on the SQL Server instance does not affect SSRS subscriptions.

Data-driven subscriptions (Enterprise Edition only) drive recipient lists, delivery parameters, and report parameters from a query result rather than fixed values. This is useful for "burst" reporting — delivering personalized report slices to a large list of recipients from a single subscription definition.

```sql
SET NOCOUNT ON;

-- Subscription status and recent execution results
SELECT
    [rs].[SubscriptionID],
    [c].[Name]                  AS ReportName,
    [rs].[Description],
    [rs].[DeliveryExtension],
    [rs].[LastStatus],
    [rs].[LastRunTime],
    [rs].[NextRunTime]
FROM [ReportServer].[dbo].[Subscriptions]   AS rs
JOIN [ReportServer].[dbo].[Catalog]         AS c
    ON rs.[Report_OID] = c.[ItemID]
ORDER BY [rs].[LastRunTime] DESC;
```

---

## Data Source Credentials

| Credential Mode | Behavior | When to Use |
|---|---|---|
| Stored credentials | Username and password saved in SSRS (encrypted with the RS key) | Subscriptions and scheduled snapshots — required for unattended execution |
| Windows integrated | Report executes as the authenticated browser user | Interactive reports where row-level security is enforced at the database layer |
| Prompt for credentials | User enters credentials at render time | Ad hoc access to sensitive sources |
| No credentials | Connection string handles authentication | Avoid — credentials in the connection string are effectively plaintext |

The most common production issue with Windows integrated credentials is the Kerberos double-hop: the browser authenticates to SSRS, but SSRS cannot forward that identity to SQL Server without delegation. Solutions:

- Use stored credentials for any report that runs on a schedule or as a subscription
- For interactive reports requiring Windows auth passthrough, configure Kerberos constrained delegation from the SSRS service account to the target SQL Server's SPN

---

## Execution Log and Monitoring

SSRS writes execution data to the ReportServer database. The `ExecutionLog3` view is the primary monitoring target — it joins the raw log tables and exposes the most useful columns.

```sql
SET NOCOUNT ON;

-- Reports with errors in the last 7 days
SELECT TOP 50
    [ReportPath],
    [UserName],
    [Format],
    [TimeStart],
    [TimeEnd],
    DATEDIFF(SECOND, [TimeStart], [TimeEnd])    AS DurationSeconds,
    [Status],
    [ByteCount],
    [RowCount]
FROM [ReportServer].[dbo].[ExecutionLog3]
WHERE [TimeStart] >= DATEADD(DAY, -7, GETUTCDATE())
  AND [Status] <> 'rsSuccess'
ORDER BY [TimeStart] DESC;

-- Slowest reports over the last 30 days
SELECT TOP 20
    [ReportPath],
    COUNT(*)                                            AS ExecutionCount,
    AVG(DATEDIFF(SECOND, [TimeStart], [TimeEnd]))       AS AvgDurationSeconds,
    MAX(DATEDIFF(SECOND, [TimeStart], [TimeEnd]))       AS MaxDurationSeconds
FROM [ReportServer].[dbo].[ExecutionLog3]
WHERE [TimeStart] >= DATEADD(DAY, -30, GETUTCDATE())
  AND [Status] = 'rsSuccess'
GROUP BY [ReportPath]
ORDER BY AvgDurationSeconds DESC;

-- Daily execution volume
SELECT
    CAST([TimeStart] AS date)                           AS ExecutionDate,
    COUNT(*)                                            AS TotalExecutions,
    SUM(CASE WHEN [Status] <> 'rsSuccess' THEN 1 ELSE 0 END) AS Failures
FROM [ReportServer].[dbo].[ExecutionLog3]
WHERE [TimeStart] >= DATEADD(DAY, -30, GETUTCDATE())
GROUP BY CAST([TimeStart] AS date)
ORDER BY ExecutionDate DESC;
```

---

## Report Caching and Snapshots

Two mechanisms reduce repeated data source queries for heavily-used reports:

**Cached reports** — SSRS stores the rendered output for a defined time window. All users who run the report within that window receive the cached result without hitting the database. Configured per-report in the Web Portal → Report Properties → Caching.

**Execution snapshots** — SSRS runs the report on a schedule (via SQL Agent) and stores the result. Users always see the snapshot from the last scheduled run. Useful for expensive reports where data freshness to-the-minute is not required. Configured per-report in the Web Portal → Report Properties → History or Snapshot.

Both features require the data source to use stored credentials — Windows integrated credentials cannot be used for unattended execution.

---

## Scale-Out Deployment

Multiple SSRS servers sharing a single ReportServer database provide load balancing and eliminate single points of failure (Enterprise Edition only). Each node must have the same encryption key installed via `rskeymgmt -a`. URLs are fronted by a hardware or software load balancer.

Join additional nodes via RS Configuration Manager → Scale-out Deployment → add the server to the deployment using the shared ReportServer database.

Standard Edition SSRS is single-node only. The ReportServer database can be placed in an Availability Group for database-level HA regardless of edition — this protects the data but does not provide SSRS application-level redundancy without scale-out.

---

## Backup and Recovery

| Component | Method | Frequency |
|---|---|---|
| ReportServer database | SQL Server backup (Full + Log) | Per standard backup schedule |
| ReportServerTempDB | SQL Server backup or allow auto-recreate on restore | As needed |
| Encryption key | `rskeymgmt -e` export | After initial config and after any service account change |
| RSReportServer.config | File copy | After any configuration change |

The configuration file (`RSReportServer.config`) is in the SSRS install directory — typically `C:\Program Files\Microsoft SQL Server Reporting Services\SSRS\ReportServer\`. It contains the connection string to the ReportServer database, URL reservations, and extension configuration.

To restore SSRS to a new server:

1. Install SSRS on the replacement server
2. In RS Configuration Manager → Database → change to point to the existing ReportServer database (do not create a new one)
3. Restore the encryption key: `rskeymgmt -a -f <keyfile> -p <password>`
4. Verify subscriptions are active and data sources resolve

---

## Related Documents

- [Security Practices](../Security/Security.md) — service account requirements and gMSA limitations
- [Database Mail](Database-Mail.md) — SSRS uses its own SMTP client, separate from Database Mail
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — placing the ReportServer database in an AG
- [SQL Agent Job Standards](../Standards/Agent-Job-Standards.md) — RS subscription jobs run as Agent jobs
