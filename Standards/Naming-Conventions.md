# Naming Conventions

## Purpose

Define forward-looking naming standards for SQL Server hosts, instances, databases, SQL objects, Agent jobs, logins, and linked servers. These standards apply to all new objects. Legacy names that predate this standard are documented in SQL-Inventory and should not be renamed without a coordinated change across all dependent applications, connection strings, and configurations.

---

## Server and Host Naming

Format: `SQL-{ROLE}-{ENV}[-{NN}]`

| Segment | Values | Notes |
|---|---|---|
| `SQL` | Literal prefix | Identifies the host as a SQL Server |
| `ROLE` | ERP, RPL, WMS, PMA, RPT, DEV | Describes the primary workload |
| `ENV` | *(omit for prod)*, TEST, DEV | Omit entirely for production hosts |
| `NN` | 01, 02, ... | Optional zero-padded sequence for additional nodes |

**Examples:**

| Host Name | Meaning |
|---|---|
| `SQL-ERP` | Production ERP host |
| `SQL-ERP-TEST` | Test ERP host |
| `SQL-RPL` | Production replication host |
| `SQL-WMS-TEST` | Test WMS host |
| `SQL-RPT` | Production reporting host |
| `SQL-ERP-02` | Second production ERP node |

**Non-conforming patterns to avoid on new builds:**

- Role-prefix naming where a product or vendor name replaces the `SQL` prefix
- Role-position inversion where `SQL` appears after the role segment
- Environment-prefix naming where `TEST` or `DEV` appears before the role segment

---

## SQL Instance Naming

### Standalone Servers

Use a **default instance** for standalone single-purpose production servers. This eliminates the SQL Browser service dependency and simplifies connection strings. Use a named instance only when a second SQL Server installation is planned at build time.

### FCI Cluster Nodes

Named instances are always required for Failover Cluster Instances — the instance name is part of the cluster resource group identity. Use the role code from the table below as the instance name.

### Approved Instance Name Codes

| Instance Name | Role |
|---|---|
| `ENT` | ERP / Dynamics GP |
| `RPL` | Replication distributor or publisher |
| `WMS` | Warehouse management |
| `PMA` | Parts management |
| `RPT` | Reporting |
| `DEV` | Development or sandbox |

Do not use organization prefixes in instance names — they are redundant when the host name already encodes the role.

---

## Database Naming

### By Ownership Category

| Category | Standard | Notes |
|---|---|---|
| Vendor system databases | Preserve exactly | master, model, msdb, tempdb, SSISDB — never rename |
| Vendor application databases | Preserve as vendor assigns | kratos, asbackup, asmonitor, SolarWindsOrion — never rename without vendor guidance |
| GP system database | Preserve exactly | DYNAMICS — GP depends on this exact name |
| GP company databases | GP assigns; preserve exactly | GP tracks company DB names in `DYNAMICS.dbo.SY01500` — renaming breaks GP entirely |
| ODN-owned shared databases | `ALLCAPS`; `ODN` prefix | ODN prefix signals data shared across multiple applications |
| ODN-owned application databases | `ALLCAPS`; role abbreviation, no ODN prefix | ODN prefix omitted when data is single-application |
| Staging copies | `{SOURCE}_STG` | Examples: `ARI_STG`, `PIES_STG` |
| Test or dev copies | `{SOURCE}_TEST` or `{SOURCE}_DEV` | Must be on non-production instances only |

### Rules

- ODN-owned database names: ALLCAPS, no underscores except in `_STG`, `_TEST`, `_DEV` suffixes.
- Legacy lowercase or mixed-case names are vendor-assigned or pre-standard — do not rename without a documented migration plan coordinated with the application team.
- Never create a test or staging copy of a database on a production instance.

---

## SQL Object Naming

T-SQL object naming standards are defined in [[Development-and-Configuration-Standards|Development and Configuration Standards]]. Quick reference:

| Object Type | Convention | Example |
|---|---|---|
| Tables | PascalCase | `CustomerOrder` |
| Stored procedures | `usp_` prefix | `usp_GetOrderHistory` |
| Functions | `ufn_` prefix | `ufn_CalcTax` |
| Views | `vw_` prefix | `vw_ActiveCustomers` |
| Primary key indexes | `PK_` prefix | `PK_CustomerOrder` |
| Non-clustered indexes | `IX_` prefix | `IX_CustomerOrder_OrderDate` |
| Foreign keys | `FK_` prefix | `FK_OrderLine_CustomerOrder` |
| Default constraints | `DF_` prefix | `DF_CustomerOrder_CreatedDate` |
| Unique constraints | `UC_` prefix | `UC_Customer_Email` |

---

## SQL Agent Job Naming

Format: `{Category} - {Action} - {Scope}`

| Segment | Purpose | Examples |
|---|---|---|
| Category | Identifies job owner or type | DBA, APP, MAINT, REPL, GP |
| Action | What the job does | Backup, Monitor, Archive, Rebuild, Purge |
| Scope | What it acts on | Full, Log, All, ODND, TransactionHistory |

**Examples:**

| Job Name | Category | Notes |
|---|---|---|
| `DBA - Backup - Full` | DBA | Full database backup job |
| `DBA - Backup - Log` | DBA | Transaction log backup job |
| `MAINT - IndexOptimize - All` | MAINT | Ola Hallengren index job |
| `REPL - Monitor - Latency` | REPL | Replication latency check |
| `GP - Archive - TransactionHistory` | GP | GP-specific archiving job |

**Exception:** Ola Hallengren Maintenance Solution and SQL Server replication agent jobs retain their default names. They are well-known, searchable, and referenced in external documentation — renaming causes operational confusion.

**Exception:** DBAOps utility jobs use `DBAOps - {Action} - {Scope}` format, where `DBAOps` identifies the owning system rather than a personnel category. Examples: `DBAOps - Capture - Deadlocks`, `DBAOps - Capture - WaitStats`, `DBAOps - Capture - SaActivity`.

### Required Job Properties

All jobs must have these properties set before deployment to production:

| Property | Requirement |
|---|---|
| Name | Follows naming convention above |
| Category | Set to an approved category |
| Description | One or more sentences stating what the job does and who owns it |
| Notification operator | Required on any job that modifies data or runs longer than 15 minutes |
| Owner | DBA service account — never SA |

See [[Agent-Job-Standards|SQL Agent Job Standards]] for full job configuration requirements.

---

## Login and Role Naming

| Object Type | Convention | Example | Notes |
|---|---|---|---|
| SQL Server service account | `svc-sql-{app}` | `svc-sql-erp`, `svc-sql-wms` | Domain account; Windows auth preferred |
| Application SQL login | `app-{appcode}` | `app-pma`, `app-ari` | SQL login only when Windows auth is not possible |
| DBA personal logins | Windows accounts only | `DOMAIN\firstname.lastname` | No SQL logins for DBA staff |
| Custom database roles | `dr_` prefix | `dr_RO`, `dr_EO`, `dr_RE`, `dr_RW` | See [[Security-Practices|Security Practices]] for role definitions |

Never create shared SQL logins. Each application and service must have its own dedicated login.

---

## Extended Events Session Naming

Format: `DBAOps_PascalCase`

| Segment | Purpose | Examples |
|---|---|---|
| `DBAOps` | Identifies the owning system | Consistent with DBAOps job naming pattern |
| `_` | Required separator | |
| `PascalCase` | Describes the session purpose | `SaActivityMonitor`, `SpExecutionCapture`, `BlockedProcess` |

**Examples:**

| Session Name | Purpose |
|---|---|
| `DBAOps_SaActivityMonitor` | sa login activity capture |
| `DBAOps_SpExecutionCapture` | SP execution tracking via ring buffer |
| `DBAOps_BlockedProcess` | Blocked process report capture |
| `DBAOps_LongRunningQueries` | Long-running query capture |

**File naming:** Script files in `XESessions\` should match the session name they define: `DBAOps_SaActivityMonitor.sql`. When a single file defines multiple sessions (e.g., `XEventSessions.sql`), use a descriptive PascalCase name for the file.

**Non-conforming patterns to avoid on new sessions:**

- snake_case names without the `DBAOps` prefix (e.g., `sa_activity_monitor`)
- Freeform names with no owning-system identifier

---

## Linked Server Naming

Format: `{HOST}_{INSTANCE}` — mirrors the instance slug convention (backslash replaced with underscore).

| Linked Server Name | Points To |
|---|---|
| `SQL-RPL-NEW_RPL` | `SQL-RPL-NEW\RPL` |
| `SQL-ERP` | `SQL-ERP` (default instance) |

Use the physical host and instance name. Avoid friendly display names that hide the target server identity — operational troubleshooting requires knowing the physical target immediately.

---

## Related Documents

- [[Development-and-Configuration-Standards|Development and Configuration Standards]] — full T-SQL object naming detail
- [[Security-Practices|Security Practices]] — `dr_` role definitions and login standards
- [[Agent-Job-Standards|SQL Agent Job Standards]] — full job configuration requirements
- [[../Index|Back to Index]]
