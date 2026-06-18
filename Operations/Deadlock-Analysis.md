# Deadlock Analysis

## Purpose

Working reference for diagnosing and resolving SQL Server deadlocks during or after an incident. Covers how to read deadlock graphs, identify the pattern, and apply the correct fix. Deadlock *capture* — creating and managing the Extended Events session that records deadlock XML — is covered in [[Extended-Events|Extended Events]].

---

## How SQL Server Handles Deadlocks

The deadlock monitor runs every 5 seconds. When it detects a cycle — two or more sessions each holding a lock that the other needs — it selects a victim and terminates that session's transaction. Victim selection follows two rules in order: lowest `DEADLOCK_PRIORITY` first, then lowest estimated rollback cost (measured by transaction log used). The victim receives error 1205 and its transaction is rolled back automatically.

The key implication: the session that did the most work is usually *not* the victim because it has the highest log cost. If you need a specific session to survive, raise its priority (`SET DEADLOCK_PRIORITY HIGH`).

---

## Capturing Deadlock Events

### system_health (Always On, No Setup Required)

The `system_health` session is enabled by default and retains approximately the last 250 deadlock events. Query it immediately after an incident.

```sql
SET NOCOUNT ON;

SELECT
    [xdr].[value]('@timestamp', 'datetime2')            AS DeadlockTime,
    [xdr].[query]('.')                                  AS DeadlockGraph
FROM (
    SELECT CAST([target_data] AS xml) AS target_data
    FROM [sys].[dm_xe_session_targets]  AS t
    JOIN [sys].[dm_xe_sessions]         AS s
        ON t.[event_session_address] = s.[address]
    WHERE s.[name] = N'system_health'
      AND t.[target_name] = N'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS xd(xdr)
ORDER BY DeadlockTime DESC;
```

Ring buffer data is lost on service restart. For persistent storage, set up a dedicated session as described in [[Extended-Events|Extended Events]].

---

## Reading a Deadlock Graph

### XML Structure

Every deadlock report contains three top-level sections:

**`<victim-list>`** — the `id` of the process SQL Server chose to roll back.

**`<process-list>`** — one `<process>` node per session. Key attributes:

| Attribute | Meaning |
|---|---|
| `spid` | Session ID |
| `loginname` | SQL login or Windows account |
| `lockMode` | Lock mode held (S, U, X, IS, IX) |
| `waitresource` | Resource this process is waiting to acquire |
| `logused` | Transaction log bytes consumed — higher = less likely to be victim |

**`<resource-list>`** — one node per contested resource, listing owners and waiters. Resource types: `<keylock>` (most common), `<pagelock>`, `<objectlock>` (lock escalation), `<ridlock>`.

### Extracting Key Details

```sql
SET NOCOUNT ON;

SELECT
    [xdr].[value]('@timestamp', 'datetime2')                                AS DeadlockTime,
    [xdr].[value]('(//victim-list/victimProcess/@id)[1]', 'varchar(50)')    AS VictimProcessId,
    [xdr].[query]('//process-list')                                         AS ProcessList,
    [xdr].[query]('//resource-list')                                        AS ResourceList
FROM (
    SELECT CAST([target_data] AS xml) AS target_data
    FROM [sys].[dm_xe_session_targets]  AS t
    JOIN [sys].[dm_xe_sessions]         AS s
        ON t.[event_session_address] = s.[address]
    WHERE s.[name] = N'system_health'
      AND t.[target_name] = N'ring_buffer'
) AS data
CROSS APPLY target_data.nodes('//RingBufferTarget/event[@name="xml_deadlock_report"]') AS xd(xdr)
ORDER BY DeadlockTime DESC;
```

### SSMS Deadlock Graph Viewer

For deadlocks captured to an `.xel` file, open it in SSMS, right-click any event row, and select **Open in Deadlock Graph**. Ovals are processes (X marks the victim), rectangles are resources, and arrow direction shows wait direction.

---

## Common Deadlock Patterns

### 1. Bookmark Lookup Deadlock

**Cause.** A query uses a nonclustered index to find rows, then follows the bookmark back to the clustered index for uncovered columns. Two concurrent transactions each hold a lock on one index structure and wait for the other's lock.

**Identify.** Two `<keylock>` nodes in `<resource-list>`: one on the nonclustered index, one on the clustered index, each owned by one process and waited on by the other.

**Fix.** Add a covering index with `INCLUDE` columns, eliminating the lookup and collapsing two lock points into one.

---

### 2. Read-Write Cycle Deadlock

**Cause.** Two transactions each read one row and then attempt to update a row held by the other.

**Identify.** Both processes show `lockMode="S"` but `waitMode="U"` or `waitMode="X"` — they read before they wrote and the read locks were not released.

**Fix.** Ensure all transactions access rows in a consistent order. When a transaction will read then update the same row, acquire the lock upfront with the `UPDLOCK` hint.

---

### 3. Escalation Deadlock

**Cause.** SQL Server escalates row-level locks to a single table lock. The escalation requires an exclusive lock on the object, which conflicts with row locks held by other sessions.

**Identify.** One `<objectlock>` with `lockMode="X"` alongside `<keylock>` or `<pagelock>` entries on the same object.

**Fix.** Break large batch operations into smaller chunks to stay below the escalation threshold (5,000 locks per table by default). Enabling RCSI (`READ_COMMITTED_SNAPSHOT`) eliminates many escalation conflicts because readers use row versioning instead of shared locks.

---

### 4. Foreign Key Deadlock

**Cause.** An `INSERT` or `UPDATE` on a child table triggers a referential integrity check that acquires a shared lock on the parent row. Concurrently, a `DELETE` on the parent needs an exclusive lock on that same row — and also needs the child table's FK index, which the inserting transaction holds.

**Identify.** One session running INSERT/UPDATE and another running DELETE; contention on both the parent clustered index key and the child table's index.

**Fix.** Ensure indexes exist on foreign key columns in child tables. Without an index, SQL Server scans the child table during FK checks, acquiring more locks for longer.

---

## Application Retry Logic

Error 1205 is retriable. The victim's transaction was rolled back cleanly — the application can safely resubmit.

```
maxRetries = 3, retryCount = 0

while retryCount < maxRetries:
    try:
        execute operation in transaction
        break
    catch error 1205:
        retryCount++
        if retryCount >= maxRetries: raise
        wait 100–500 ms (add jitter for multi-client scenarios)
    catch other error:
        rollback, raise
```

---

## Reducing Deadlock Frequency

- **Keep transactions short.** Acquire locks late, release early. Never include user interaction or network calls inside a transaction.
- **Consistent access order.** If every transaction accessing tables A and B always touches A before B, a cycle between them cannot form.
- **Enable RCSI.** Readers use row versioning from TempDB instead of shared locks, eliminating reader-writer deadlocks entirely. Monitor TempDB growth after enabling.

```sql
SET NOCOUNT ON;

ALTER DATABASE [YourDatabase] SET READ_COMMITTED_SNAPSHOT ON;
```

- **Cover queries.** Covering indexes eliminate bookmark lookups and their second lock point.
- **Index FK columns.** Unindexed foreign key columns cause table scans during integrity checks.

---

## Monitoring Deadlock Rate

```sql
SET NOCOUNT ON;

SELECT
    [cntr_value]    AS DeadlocksPerSecond
FROM [sys].[dm_os_performance_counters]
WHERE [object_name]     LIKE '%SQLServer:Locks%'
  AND [counter_name]    = 'Number of Deadlocks/sec'
  AND [instance_name]   = '_Total';
```

This counter resets on service restart. For trending across restarts, capture on a schedule via a SQL Agent job.

---

## Related Documents

- [[Extended-Events|Extended Events]] — deadlock capture session setup and XEL file management
- [[Monitoring|Monitoring]] — blocking detection and real-time session monitoring
- [[Query-Tuning|Query Tuning]] — covering indexes, query rewrites, and execution plan analysis
- [[Operations|Back to Operations]]
