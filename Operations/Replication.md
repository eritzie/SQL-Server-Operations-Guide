# Transactional Replication

## Purpose

Define operational standards for managing SQL Server transactional replication environments. Covers topology roles, monitoring, safe maintenance windows, subscription management, and troubleshooting. Snapshot and merge replication are not addressed here.

---

## Topology Roles

| Role | Description |
|---|---|
| **Publisher** | Source instance. Holds the publication database. Marked articles are tracked by the Log Reader Agent. |
| **Distributor** | Intermediary. Holds the distribution database. Stores transactions between publisher and subscriber. May be co-located on the publisher or on a dedicated instance. |
| **Subscriber** | Destination instance. Receives replicated transactions via the Distribution Agent. |

A dedicated distributor instance is preferred for production environments with high transaction volume — co-locating the distributor on the publisher adds contention on the publisher's log reader.

---

## Prerequisites

Before configuring replication:

- [ ] Publication database is in **FULL** recovery model — Simple recovery is not compatible with transactional replication
- [ ] Publisher and subscriber share compatible collation (`SQL_Latin1_General_CP1_CI_AS`)
- [ ] Snapshot share is accessible by both publisher and distributor service accounts (read/write)
- [ ] Distribution database is sized appropriately — undersizing causes latency accumulation under load
- [ ] SQL Server Agent is running on all three roles
- [ ] Service accounts have `db_owner` on the distribution database and appropriate access to publication databases

```powershell
# Verify recovery model on publication candidates
$splatRec = @{
    SqlInstance     = $publisher
    EnableException = $true
}
Get-DbaDatabase @splatRec |
    Where-Object RecoveryModel -ne 'Full' |
    Select-Object SqlInstance, Name, RecoveryModel
```

---

## Monitoring

### Latency — Primary Check

Replication latency is the delay between a transaction committing on the publisher and arriving at the subscriber. Monitor via the distribution database:

```sql
SET NOCOUNT ON;

SELECT
    msp.[publisher_db],
    mss.[subscriber_db],
    mss.[last_delivered_time],
    mss.[latency]           AS latency_sec,
    mss.[delivery_rate]     AS rows_per_sec,
    mss.[delivery_latency]  AS delivery_latency_ms
FROM [distribution].[dbo].[MSsubscriptions]         AS mss
JOIN [distribution].[dbo].[MSpublisher_databases]   AS msp
    ON mss.[publisher_id]   = msp.[publisher_id]
    AND mss.[publisher_db_id] = msp.[id]
ORDER BY mss.[latency] DESC;
```

```powershell
# dbatools — publication status across all publications
$splatPub = @{
    SqlInstance     = $distributor
    EnableException = $true
}
Get-DbaReplPublication @splatPub |
    Select-Object SqlInstance, PublicationName, PublicationType, Status
```

**Latency thresholds:**

| Threshold | Action |
|---|---|
| < 60 seconds | Normal |
| 60 – 300 seconds | Investigate — check Log Reader and Distribution Agent job history |
| > 300 seconds | Alert — identify root cause before latency compounds |
| Growing unbounded | Agent likely stopped or erroring — check agent jobs immediately |

### Agent Job Health

Replication relies on three SQL Agent jobs per publication/subscription: Log Reader Agent, Snapshot Agent, and Distribution Agent. Monitor their status:

```sql
SET NOCOUNT ON;

SELECT
    j.[name]            AS AgentJob,
    j.[enabled],
    h.[run_date],
    h.[run_time],
    CASE h.[run_status]
        WHEN 0 THEN 'Failed'
        WHEN 1 THEN 'Succeeded'
        WHEN 2 THEN 'Retry'
        WHEN 3 THEN 'Cancelled'
        WHEN 4 THEN 'In Progress'
    END                 AS LastStatus,
    h.[message]
FROM [msdb].[dbo].[sysjobs]         AS j
JOIN [msdb].[dbo].[sysjobhistory]   AS h
    ON j.[job_id] = h.[job_id]
WHERE j.[name] LIKE '%REPL%'
   OR j.[category_id] IN (
       SELECT [category_id]
       FROM [msdb].[dbo].[syscategories]
       WHERE [name] LIKE 'REPL%'
   )
ORDER BY h.[run_date] DESC, h.[run_time] DESC;
```

---

## Maintenance Windows

Certain DBA operations require coordination before being performed on published databases.

### Index Rebuilds on Published Tables

Index rebuilds on published tables are logged operations and generate a large volume of log records that the Log Reader Agent must process. This can spike latency significantly.

- Schedule index rebuilds on publisher databases **off-hours only**.
- Monitor latency during and after the rebuild window until it returns to baseline.
- Do not rebuild multiple published tables simultaneously.

### Log Backups

Transaction log backups on the publisher truncate the log only after the Log Reader Agent has read and forwarded all transactions to the distributor. If the Log Reader Agent is stopped or lagging, log backups will not shrink the active log — the log grows until the agent catches up.

If log growth is unexpectedly high:
1. Check Log Reader Agent status and latency.
2. Resolve the agent issue before taking corrective action on the log file.
3. Do not set recovery model to SIMPLE as a workaround — this drops the publication.

### Schema Changes on Published Tables

Schema changes on published articles must be replicated to subscribers. SQL Server handles DDL replication automatically for supported changes, but some changes require manual intervention or subscription reinitialization.

Before making schema changes to published tables:
1. Confirm the change is in the list of DDL changes supported by transactional replication.
2. Test the change on the test replication environment first.
3. Coordinate timing with a low-latency window.
4. Monitor agent jobs immediately after the change for errors.

---

## Reinitializing Subscriptions

Reinitialize when a subscription is out of sync and latency cannot be resolved by letting the distribution agent catch up.

### When to Reinitialize

- Subscription is marked as inactive or unsubscribed due to extended latency
- Log Reader Agent shows unresolvable errors related to missing log records
- Schema mismatch between publisher and subscriber article tables

### With a New Snapshot

```powershell
# Generate a new snapshot and reinitialize
$splatReinit = @{
    SqlInstance     = $publisher
    Database        = $publicationDb
    PublicationName = $publicationName
    EnableException = $true
}
Invoke-DbaReplPublicationRebuild @splatReinit
```

For large publications, snapshot generation can take significant time and will increase publisher disk and I/O load. Schedule during a low-activity window.

### Without a New Snapshot (Existing Snapshot)

Use only if the existing snapshot is recent and subscriber schema matches:

```sql
-- On the distributor
EXEC [distribution].[dbo].[sp_reinitsubscription]
    @publication     = N'PublicationName',
    @subscriber      = N'<subscriber-instance>',
    @destination_db  = N'<subscriber-database>',
    @invalidate_snapshot = 0;   -- 0 = use existing snapshot
```

---

## Troubleshooting

### Common Errors and Resolutions

| Error | Likely Cause | Resolution |
|---|---|---|
| Log Reader Agent: "Could not find log record" | Log backup ran before Log Reader processed records | Check Log Reader latency; if log was backed up with `COPY_ONLY` this should not occur — verify backup type |
| Distribution Agent: deadlock on subscriber | Concurrent writes on subscriber conflicting with replication | Identify conflicting process; replication agents retry deadlocks automatically up to the configured retry count |
| Snapshot Agent failure | Snapshot share permissions or disk space | Verify service account access to snapshot share; check free disk space |
| Subscription marked inactive | Latency exceeded the `max_distrib_retention` threshold | Reinitialize the subscription |
| "The process could not execute 'sp_replcmds'" | Log Reader Agent lacks permission on publication DB | Verify Log Reader Agent account has `db_owner` or explicit `EXECUTE` on `sp_replcmds` |

### Replication Monitor

Replication Monitor (SSMS > Replication > Launch Replication Monitor) provides a graphical view of all publications, latency history, and agent job logs. Use it for initial diagnosis before querying distribution tables directly.

### Agent Error Log Detail

```sql
SET NOCOUNT ON;

-- Last 50 error messages from all replication agents
SELECT TOP 50
    [time],
    [error_code],
    [error_text],
    [xact_seqno]
FROM [distribution].[dbo].[MSrepl_errors]
ORDER BY [time] DESC;
```

---

## Related Documents

- [Monitoring](Monitoring.md) — general job monitoring procedures
- [SQL Agent Job Standards](../Standards/Agent-Job-Standards.md) — replication agent job naming and configuration
- [Log Shipping Setup](../Disaster-Recovery/LogShipping.md) — alternative DR approach for non-published databases
