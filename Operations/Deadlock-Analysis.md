# Deadlock Analysis

## Purpose

This document is a working reference for diagnosing and resolving SQL Server deadlocks during or after an incident. It covers how to read deadlock graphs, identify the pattern, and apply the correct fix. Deadlock *capture* — creating and managing the Extended Events session that records deadlock XML — is covered in [Extended-Events.md](../Operations/Extended-Events.md).

---

## How SQL Server Handles Deadlocks

The deadlock monitor runs every 5 seconds. When it detects a cycle — two or more sessions each holding a lock that the other needs — it selects a victim and terminates that session's transaction. Victim selection follows two rules in order: lowest `DEADLOCK_PRIORITY` first, then lowest estimated rollback cost (measured by transaction log used). The victim receives error 1205 and its transaction is rolled back automatically. The surviving session's lock request is then granted and it continues.

The key implication: the session that did the most work is usually *not* the victim, because it has the highest log cost. If you need a specific session to survive, raise its `DEADLOCK_PRIORITY` (`SET DEADLOCK_PRIORITY HIGH`).

---

## Capturing Deadlock Events

### system_health (Always On, No Setup Required)

The `system_health` session is enabled by default on every SQL Server instance. It captures deadlock XML in a ring buffer and retains approximately the last 250 deadlock events. No configuration is needed — query it immediately after an incident.

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

Ring buffer data is lost on service restart. For persistent storage across restarts, set up a dedicated session as described in [Extended-Events.md](../Operations/Extended-Events.md).

### Dedicated Extended Events Session

A dedicated XE session writes deadlock XML to `.xel` files on disk, surviving restarts and retaining as much history as disk space allows. See [Extended-Events.md](../Operations/Extended-Events.md) for the session definition and file management.

---

## Reading a Deadlock Graph

### XML Structure

Every deadlock report contains three top-level sections:

**`<victim-list>`** — lists the `id` attribute of the process SQL Server chose to roll back. Match this `id` to a `<process>` node in the process list.

**`<process-list>`** — one `<process>` node per session involved. Key attributes:
- `id` — internal process identifier, used to cross-reference the victim list and resource list
- `spid` — session ID (matches `sys.dm_exec_sessions.session_id`)
- `loginname` — SQL login or Windows account
- `hostname` — client machine name
- `currentdb` — database ID of the current database
- `lockMode` — the lock mode this process holds (S = shared, U = update, X = exclusive, IS = intent shared, IX = intent exclusive)
- `waitresource` — the resource this process is waiting to acquire
- `trancount` — open transaction count
- `logused` — bytes of transaction log consumed. Higher log used means more expensive rollback, so SQL Server is *less* likely to pick this process as the victim.
- `<executionStack>` / `<frame>` — the T-SQL or stored procedure line currently executing

**`<resource-list>`** — one node per contested resource. Each resource lists the processes that own it and the processes waiting for it. Resource types include:
- `<keylock>` — a row-level lock on an index key (most common)
- `<pagelock>` — a page-level lock
- `<objectlock>` — a table-level lock (typically from lock escalation)
- `<ridlock>` — a heap row identifier lock

### Extracting Key Details with T-SQL

This query pulls the victim ID, process list XML, and resource list XML from the most recent deadlocks. Paste the XML column output into SSMS's XML viewer for easier navigation.

```sql
SET NOCOUNT ON;

-- Extract victim, sessions, and wait resources from recent deadlocks
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

For deadlocks captured to an `.xel` file, SSMS renders a visual graph. Open the `.xel` file in SSMS, right-click any deadlock event row, and select **Open in Deadlock Graph**.

Reading the graph:
- **Oval** = process (session). The oval marked with an X is the victim.
- **Rectangle** = resource (index key, page, object).
- **Arrow direction** = wait direction. An arrow from an oval to a rectangle means that process is waiting to acquire a lock on that resource.
- Each oval shows the spid, login, and the SQL statement executing at the time of the deadlock.

The visual graph is faster for simple two-process deadlocks. The XML is more useful for multi-process cycles or when you need to compare `logused` values across participants.

---

## Common Deadlock Patterns

### 1. Bookmark Lookup Deadlock

**Cause.** A query uses a nonclustered index to find rows, then follows the bookmark (row locator) back to the clustered index to retrieve columns not covered by the nonclustered index. Two concurrent transactions each hold a lock on one of the two index structures and wait for the lock held by the other.

Process A holds a shared lock on a nonclustered index key and needs the corresponding clustered index key (the lookup). Process B holds an update lock on the clustered index row that A needs, and is also waiting to acquire a lock on the nonclustered index row that A holds.

**How to identify.** In `<resource-list>`, you will see two `<keylock>` nodes: one on the nonclustered index (identified by its `indexname` attribute) and one on the clustered index. Each is owned by one process and waited on by the other.

**Fix.** Add a covering index that includes the columns the query needs in its `INCLUDE` clause, eliminating the lookup entirely. Alternatively, rewrite the query to retrieve all needed columns directly from the clustered index. Either approach breaks the two-lock cycle because only one index is accessed.

---

### 2. Read-Write Cycle Deadlock

**Cause.** Two transactions each read one row and then attempt to update a row held by the other. Shared locks acquired during reads block the other transaction's update attempts, creating a cycle.

Process A holds a shared lock on row 1 and waits for row 2. Process B holds a shared lock on row 2 and waits for row 1. Neither can proceed.

**How to identify.** Both processes show `lockMode="S"` in their `<process>` nodes but `waitMode="U"` or `waitMode="X"` in the resource list — they read before they wrote, and the read locks were not released.

**Fix.** Ensure all transactions access tables and rows in a consistent order across the application. When a transaction will read a row and then update it in the same transaction, acquire the lock as an update lock upfront using the `UPDLOCK` hint, which prevents another session from acquiring a conflicting shared lock on the same row.

---

### 3. Escalation Deadlock

**Cause.** SQL Server escalates a large number of row-level locks to a single table-level lock. The escalation request must acquire an exclusive lock on the object. If other sessions hold row-level locks on rows within that table at the same time, their locks are incompatible with the table lock, and a deadlock cycle forms.

**How to identify.** In `<resource-list>`, one resource node is an `<objectlock>` with `lockMode="X"`. Other nodes are `<keylock>` or `<pagelock>` entries on the same object, owned by the sessions that the escalating transaction is blocked by.

**Fix.** Break large batch operations into smaller chunks so the row lock count stays below the escalation threshold (by default, escalation triggers at 5,000 locks per table or when lock memory exceeds 40% of the lock manager's allocation). Enabling `READ_COMMITTED_SNAPSHOT` (RCSI) on the database reduces lock-related escalation conflicts because readers use row versioning instead of shared locks.

---

### 4. Cascade / Foreign Key Deadlock

**Cause.** An `INSERT` or `UPDATE` on a child table triggers a referential integrity check on the parent table's primary key — SQL Server acquires a shared lock on the parent row to verify it exists. Concurrently, a `DELETE` on the parent table tries to acquire an exclusive lock on that same parent row. If the child table operation is also holding a lock that the parent delete needs (such as a lock on the child table's FK index), a cycle forms.

**How to identify.** The process list shows one session running an `INSERT` or `UPDATE` and another running a `DELETE`. The resource list shows contention on the parent table's clustered index key alongside contention on the child table's index.

**Fix.** Ensure indexes exist on the foreign key columns in child tables. Without an index, SQL Server scans the child table during FK checks, acquiring more locks and taking longer, which widens the window for a deadlock. With an index seek, the shared lock is acquired and released quickly. Also sequence operations so parent deletes and child inserts do not run concurrently within the same transaction boundaries.

---

## Application Retry Logic

Error 1205 is a retriable error. The victim's transaction was rolled back cleanly — the application can safely retry the failed operation. Deadlocks are expected in concurrent systems; the measure of a good fix is reducing their *frequency*, not eliminating every theoretical possibility.

Retry pattern (pseudocode):

```
maxRetries = 3
retryCount = 0

while retryCount < maxRetries:
    try:
        begin transaction
        -- execute the operation
        commit transaction
        break

    catch error 1205:
        retryCount++
        if retryCount >= maxRetries:
            raise  -- propagate after exhausting retries
        wait briefly (e.g., 100–500ms with optional jitter)
        continue

    catch other error:
        rollback transaction
        raise
```

Keep retry waits short — deadlock victims are retried quickly in practice. Add jitter if multiple clients may be retrying simultaneously to avoid synchronized thundering herd behavior.

---

## Reducing Deadlock Frequency

**Keep transactions short.** The longer a transaction holds locks, the larger the window for a cycle to form. Acquire locks late, release them early. Never include user interaction or network calls inside a transaction.

**Access objects in a consistent order.** If every transaction that touches tables A and B always accesses A before B, a two-process deadlock cycle between them cannot form. Enforce this in code review and stored procedure design.

**Use READ_COMMITTED_SNAPSHOT (RCSI).** Under RCSI, readers use row versioning from TempDB instead of acquiring shared locks. This eliminates reader-writer deadlocks (pattern 2 above) and reduces overall lock contention significantly. Enable it per database:

```sql
SET NOCOUNT ON;

ALTER DATABASE [YourDatabase] SET READ_COMMITTED_SNAPSHOT ON;
```

Risk: TempDB version store usage increases. Monitor TempDB growth after enabling.

**Cover queries to eliminate bookmark lookups.** Every bookmark lookup is a second lock acquisition on a second index structure. Covering indexes that include all columns the query needs eliminate the lookup and collapse two lock points into one.

**Index foreign key columns.** Unindexed FK columns cause table scans on the child table during referential integrity checks. Each scan holds more locks for longer.

**Avoid user interaction inside transactions.** Never wait for user input, a web service response, or a file system operation while a transaction is open. Hold locks only for the duration of database work.

---

## Monitoring Deadlock Rate

Use the performance counter to track deadlocks per second over time. This resets when the SQL Server service restarts, so it is most useful for comparing before and after a fix within the same uptime window.

```sql
SET NOCOUNT ON;

-- Deadlock rate from performance counters (resets on service restart)
SELECT
    [cntr_value]    AS DeadlocksPerSecond
FROM [sys].[dm_os_performance_counters]
WHERE [object_name]     LIKE '%SQLServer:Locks%'
  AND [counter_name]    = 'Number of Deadlocks/sec'
  AND [instance_name]   = '_Total';
```

For trend data across restarts, capture this counter on a schedule and write results to a history table, or use a monitoring tool that logs performance counter history. See [Monitoring.md](../Operations/Monitoring.md) for the broader monitoring approach used in this environment.

---

## Related Documents

- [Extended-Events.md](../Operations/Extended-Events.md) — deadlock capture session setup and XEL file management
- [Monitoring.md](../Operations/Monitoring.md) — blocking detection and real-time session monitoring
- [Query-Tuning.md](Query-Tuning.md) — covering indexes, query rewrites, and execution plan analysis
