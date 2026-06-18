# Extended Events

## Purpose

Extended Events (XE) is the supported replacement for SQL Profiler and server-side traces. Profiler is deprecated and removed from future SQL Server versions. This document covers two production-ready sessions: blocking detection and deadlock capture. Both are lightweight enough to leave running continuously.

---

## Blocking Detection Session

Captures queries that have been blocked for longer than a configurable threshold. Useful for identifying chronic blocking problems without running sp_WhoIsActive continuously.

### Create the Session

```sql
CREATE EVENT SESSION [DBA_BlockingDetection]
ON SERVER
ADD EVENT [sqlserver].[blocked_process_report]
(
    ACTION
    (
        [sqlserver].[sql_text],
        [sqlserver].[database_name],
        [sqlserver].[username],
        [sqlserver].[client_hostname]
    )
)
ADD TARGET [package0].[ring_buffer]
(
    SET max_memory = 51200   -- 50 MB
),
ADD TARGET [package0].[event_file]
(
    SET filename          = N'C:\XELogs\DBA_BlockingDetection.xel',
        max_file_size     = 50,     -- MB per file
        max_rollover_files = 5
)
WITH
(
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = ON
);
```

The blocking threshold is controlled by the `blocked process threshold (s)` server configuration, not by the session itself. Set it to capture blocks held longer than 5 seconds:

```sql
EXEC [sys].[sp_configure] 'blocked process threshold (s)', 5;
RECONFIGURE;
```

### Start the Session

```sql
ALTER EVENT SESSION [DBA_BlockingDetection] ON SERVER STATE = START;
```

### Read the Session Data

```powershell
$splatXe = @{
    SqlInstance = $instance
    Session     = 'DBA_BlockingDetection'
    EnableException = $true
}
Get-DbaXESession @splatXe

# Read from the target file
$splatFile = @{
    Path        = 'C:\XELogs\DBA_BlockingDetection*.xel'
    EnableException = $true
}
Read-DbaXEFile @splatFile |
    Select-Object timestamp, name, database_name, username, sql_text |
    Sort-Object timestamp -Descending
```

---

## Deadlock Capture Session

SQL Server has a built-in System Health session that captures deadlock graphs, but the data rolls off quickly under load. A dedicated deadlock session writes to a persistent file for post-incident analysis.

### Create the Session

```sql
CREATE EVENT SESSION [DBA_DeadlockCapture]
ON SERVER
ADD EVENT [sqlserver].[xml_deadlock_report]
ADD TARGET [package0].[event_file]
(
    SET filename          = N'C:\XELogs\DBA_DeadlockCapture.xel',
        max_file_size     = 50,
        max_rollover_files = 10
)
WITH
(
    MAX_DISPATCH_LATENCY = 5 SECONDS,
    STARTUP_STATE        = ON
);
```

### Start the Session

```sql
ALTER EVENT SESSION [DBA_DeadlockCapture] ON SERVER STATE = START;
```

### Read Deadlock Graphs

```powershell
$splatDead = @{
    Path        = 'C:\XELogs\DBA_DeadlockCapture*.xel'
    EnableException = $true
}
Read-DbaXEFile @splatDead |
    Select-Object timestamp, xml_deadlock_report |
    Sort-Object timestamp -Descending
```

The `xml_deadlock_report` column contains the deadlock graph XML. Open it in SSMS (paste into a new query window and save as `.xdl`) to render the visual graph showing which sessions were involved and which resources caused the deadlock.

---

## Managing Sessions

```powershell
# List all XE sessions and their state
$splatSess = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaXESession @splatSess | Select-Object SqlInstance, Name, Status, StartTime

# Stop a session
Stop-DbaXESession  -SqlInstance $instance -Session 'DBA_BlockingDetection'

# Start a session
Start-DbaXESession -SqlInstance $instance -Session 'DBA_BlockingDetection'
```

### Drop a Session

```sql
DROP EVENT SESSION [DBA_BlockingDetection] ON SERVER;
```

---

## Log Directory

XEL files should be written to a dedicated directory on the SQL data or log volume with available space. The paths in the examples above (`C:\XELogs\`) are placeholders — use an appropriate path for each instance. Ensure the SQL Server service account has write access to the target directory.

---

## System Health Session

SQL Server ships with a built-in System Health XE session that captures deadlocks, severe errors (severity 20+), and non-yielding schedulers. It writes to a ring buffer and to `%ERRORLOG%\system_health*.xel`. Do not drop or disable the System Health session.

```powershell
# Read System Health deadlock data
$splatSh = @{
    SqlInstance     = $instance
    Session         = 'system_health'
    EnableException = $true
}
Read-DbaXEFile -Path (Get-DbaXESession @splatSh).TargetFileName |
    Where-Object Name -eq 'xml_deadlock_report' |
    Select-Object timestamp, xml_deadlock_report
```

---

## Related Documents

- [[Monitoring|Monitoring]] — blocking detection via DMVs and sp_WhoIsActive
- [[Performance-Practices|Performance Practices]] — wait stats and index analysis
- [[../Index|Back to Index]]
