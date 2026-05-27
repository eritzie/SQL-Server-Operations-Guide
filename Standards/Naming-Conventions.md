# Naming Conventions

## Purpose

Establish consistent naming standards across the SQL Server environment — from server and instance names through disk layout, service accounts, and database objects. Naming conventions are not universal — different organizations follow different styles — but consistency within an environment is non-negotiable. The conventions below reflect the Microsoft/enterprise SQL Server pattern, which is the most common in Windows-domain environments and aligns with system object naming in SQL Server itself.

The one rule that supersedes everything else: **pick a convention and apply it everywhere.** A shop that uses snake_case consistently is in better shape than one that mixes PascalCase and snake_case across databases.

---

## General Rules

- Use **PascalCase** for all database object names (tables, columns, procedures, etc.)
- **No spaces** in any object name — use underscores only in constraint and index prefixes
- **No reserved words** as object names — even when quoting makes it valid, it creates confusion
- **No Hungarian notation** — `tbl_`, `col_`, `int_` prefixes on tables and columns add noise without value
- **Be descriptive** — abbreviations are acceptable only when universally understood (`ID`, `Qty`, `Amt`)

---

## Servers and Instances

### Host Names

Format: `{ROLE}-{USAGE}-{ENV}-{SEQ}` — all uppercase, hyphen-delimited.

| Segment | Values | Notes |
|---|---|---|
| ROLE | `SQL` | Always `SQL` for SQL Server hosts — identifies the server type at a glance |
| USAGE | `ERP`, `DW`, `RPT`, `ETL`, `APP`, `ARC` | Workload the server primarily supports — see table below |
| ENV | `PROD`, `STG`, `UAT`, `TEST`, `DEV` | Use consistent abbreviations across all server types in the environment |
| SEQ | `01`, `02`, … | Zero-padded two-digit sequence |

**Usage codes:**

| Code | Workload |
|---|---|
| `ERP` | ERP system backend (Dynamics GP, SAP, etc.) |
| `DW` | Data warehouse / analytical store |
| `RPT` | Reporting (SSRS, Power BI Report Server) |
| `ETL` | ETL processing (SSIS, staging databases) |
| `APP` | Application databases — general-purpose OLTP |
| `ARC` | Archive / historical data |

```
SQL-ERP-PROD-01    Primary Dynamics GP production server
SQL-ERP-PROD-02    AG replica / secondary for ERP
SQL-DW-PROD-01     Data warehouse
SQL-RPT-PROD-01    Reporting server
SQL-APP-DEV-01     Application development
SQL-ETL-PROD-01    SSIS / ETL processing
```

> **NetBIOS limit:** Windows NetBIOS names are capped at 15 characters. `SQL-ERP-PROD-01` is exactly 15. If the environment still relies on NetBIOS name resolution (legacy systems, some older print/file services), keep all segments short — two-character ENV abbreviations (`PR`, `DV`, `TS`) can recover one character when needed. DNS names are not constrained.

### Instance Names

**Default instance** (`MSSQLSERVER`): the primary SQL Server on a host. Accessed by server name alone — `SQL-PROD-01`. Use the default instance for the main workload on a server.

**Named instances**: uppercase, descriptive of purpose. Include a named instance only when a second SQL Server is genuinely needed on the same host.

```
SQL-PROD-01\REPORTING      -- separate reporting workload
SQL-PROD-01\DW             -- data warehouse on a shared host
```

Never encode a version number in an instance name — `SQL-PROD-01\SQL2022` becomes incorrect after the next upgrade and breaks documentation and scripts that reference it.

**Connection string slug** (used in linked server names and configuration references): replace the backslash with an underscore.

```
SQL-PROD-01            →  SQL-PROD-01           (default instance, no change)
SQL-PROD-01\REPORTING  →  SQL-PROD-01_REPORTING  (named instance slug)
```

---

## Disk and Folder Layout

Consistent drive letter assignments across all SQL Server hosts allow scripts and runbooks to use the same paths everywhere without per-server configuration.

| Drive | Purpose | NTFS Allocation Unit |
|---|---|---|
| C: | OS only — no SQL files | 4 KB (default) |
| D: | SQL data files (`.mdf`, `.ndf`) | **64 KB** |
| L: | SQL log files (`.ldf`) | **64 KB** |
| T: | TempDB data and log | **64 KB** |
| B: (or UNC share) | Backups (`.bak`, `.trn`) | **64 KB** |

The 64 KB allocation unit size matches SQL Server's 64 KB extent size and eliminates partial-extent writes. See [Performance Practices](../Performance/PerformancePractices.md#disk-configurations) for the full rationale.

**Folder structure — single instance (default):**

```
D:\MSSQL\
    Data\           user database data files
    System\         system database data files (master, model, msdb)
L:\MSSQL\
    Logs\           user database log files
T:\MSSQL\
    TempDB\         TempDB data and log files
B:\MSSQL\
    Backups\
        Full\
        Diff\
        Log\
```

**Multi-instance servers:** include the instance name in the path to prevent collisions.

```
D:\MSSQL\MSSQLSERVER\Data\      default instance
D:\MSSQL\REPORTING\Data\        named instance REPORTING
L:\MSSQL\MSSQLSERVER\Logs\
L:\MSSQL\REPORTING\Logs\
```

---

## Logins and Accounts

### Windows Service Accounts

Format: `svc-{role}-{host}` — all lowercase, hyphen-delimited. Scope to a single host when possible so that a compromised service account cannot be used across multiple servers.

| Service | Account Pattern | Example |
|---|---|---|
| SQL Server Engine | `svc-sql-{host}` | `svc-sql-prod01` |
| SQL Server Agent | `svc-sqlagent-{host}` | `svc-sqlagent-prod01` |
| SSRS | `svc-ssrs-{host}` | `svc-ssrs-rpt01` |
| SSIS | `svc-ssis-{host}` | `svc-ssis-prod01` |
| Application service account | `svc-{application}` | `svc-webapp`, `svc-etl` |

gMSA accounts follow the same naming pattern. SQL Server references them as `DOMAIN\svc-sql-prod01$` (trailing `$`) — the name in Active Directory does not include the `$`.

### Active Directory Security Groups

Groups grant SQL Server access to sets of users without managing individual logins. Format: `SQL-{Instance}-{Role}` — uppercase, hyphen-delimited.

| Group | Maps To | Who |
|---|---|---|
| `SQL-PROD-DBA` | sysadmin | DBA team only |
| `SQL-PROD-ReadOnly` | db_datareader | Analysts and reporting consumers |
| `SQL-PROD-Developers` | db_datareader (prod) | Dev team — read-only in production |
| `SQL-DEV-Developers` | db_owner (dev) | Dev team — full access in development |

If the environment uses a prefix convention for all AD groups (e.g., `GRP-` for groups), apply it consistently: `GRP-SQL-PROD-DBA`.

### SQL Logins (SQL Authentication)

SQL logins should be rare — use Windows authentication whenever possible. When a SQL login is unavoidable (third-party tool without Windows auth support):

- All lowercase, hyphen-delimited
- Purpose-descriptive, not person-named
- Pattern: `svc-{application}` (mirrors service account convention)

```sql
-- Acceptable
svc-reporting-tool
svc-monitoring-agent

-- Not acceptable
sa                 -- reserved; disable and rename
admin              -- generic, targeted by credential stuffing
sqluser            -- meaningless
JohnSmith          -- person-named login, not an account
```

### Custom Database Roles

`dr_` prefix, followed by a short permissions abbreviation. Defined in [Security Practices](../Security/Security.md#standard-database-roles).

| Role | Permissions |
|---|---|
| `dr_RO` | SELECT |
| `dr_EO` | EXECUTE |
| `dr_RE` | SELECT + EXECUTE |
| `dr_RW` | SELECT + INSERT + UPDATE + DELETE |
| `dr_RWE` | SELECT + INSERT + UPDATE + DELETE + EXECUTE |

### SQL Server Agent Proxies

No prefix convention — proxy names appear in the Agent UI and job step properties and must be self-explanatory to the person reading them.

```
SSIS ETL Proxy
PowerShell DBA Proxy
CmdExec Backup Proxy
```

---

## Databases and Schemas

**Databases:** PascalCase, descriptive of purpose. Avoid generic names like `Data` or `App`.

```
OrderManagement
CustomerPortal
DataWarehouse
```

**Schemas:** Use schemas to group objects by ownership or domain, not by object type.

```sql
-- Good — domain-based schema separation
[sales].[Order]
[hr].[Employee]
[dbo].[SystemConfig]   -- dbo for shared/utility objects

-- Bad — type-based schema separation (creates cross-schema dependencies)
[tables].[Order]
[procs].[usp_OrderGet]
```

---

## Tables

- **Singular noun** — `Customer`, not `Customers`; `Order`, not `Orders`
- PascalCase
- No `tbl_` prefix

```sql
[dbo].[Customer]
[dbo].[OrderLine]
[dbo].[ProductCategory]
```

---

## Columns

- PascalCase
- **Primary key:** TableName + `ID` — `CustomerID`, `OrderID`. Using just `ID` makes join conditions harder to read.
- **Foreign keys:** Match the primary key name of the referenced table — `CustomerID` in the `Order` table references `CustomerID` in `Customer`
- **Booleans:** `Is` or `Has` prefix — `IsActive`, `IsDeleted`, `HasDiscount`
- **Dates:** Descriptive suffix — `CreatedDate`, `ModifiedDate`, `ShippedDate`
- **Avoid generic column names** without context: `Name`, `Value`, `Data`, `Description` are acceptable only when the table name makes them unambiguous

```sql
-- Good
[CustomerID]    int           NOT NULL,
[FirstName]     nvarchar(100) NOT NULL,
[LastName]      nvarchar(100) NOT NULL,
[EmailAddress]  nvarchar(255) NOT NULL,
[IsActive]      bit           NOT NULL DEFAULT 1,
[CreatedDate]   datetime2(0)  NOT NULL DEFAULT GETUTCDATE()

-- Bad
[ID]            int           NOT NULL,   -- ambiguous in joins
[name]          nvarchar(100) NOT NULL,   -- wrong case
[Active]        bit           NOT NULL,   -- missing Is prefix
[dt]            datetime      NOT NULL    -- opaque abbreviation
```

---

## Constraints

Constraint names must be explicit — SQL Server generates names for unnamed constraints, but those names are unreadable in error messages and impossible to reference in scripts.

| Constraint Type | Pattern | Example |
|---|---|---|
| Primary key | `PK_TableName` | `PK_Customer` |
| Foreign key | `FK_Table_ReferencedTable` | `FK_Order_Customer` |
| Unique constraint | `UQ_TableName_Column` | `UQ_Customer_EmailAddress` |
| Check constraint | `CK_TableName_Column` | `CK_Order_Status` |
| Default constraint | `DF_TableName_Column` | `DF_Customer_IsActive` |

```sql
ALTER TABLE [dbo].[Order]
ADD CONSTRAINT [FK_Order_Customer]
    FOREIGN KEY ([CustomerID])
    REFERENCES [dbo].[Customer] ([CustomerID]);
```

---

## Indexes

| Index Type | Pattern | Example |
|---|---|---|
| Non-clustered | `IX_TableName_Column[_Column]` | `IX_Order_CustomerID` |
| Unique non-clustered | `UX_TableName_Column` | `UX_Customer_EmailAddress` |
| Filtered | `FX_TableName_Column_Filter` | `FX_Order_ShippedDate_Active` |

Include covered columns in the name only if the index has a small number and the name remains readable. For wide covering indexes, omit the include columns from the name.

```sql
CREATE NONCLUSTERED INDEX [IX_Order_CustomerID]
ON [dbo].[Order] ([CustomerID])
INCLUDE ([OrderDate], [Status]);

CREATE UNIQUE NONCLUSTERED INDEX [UX_Customer_EmailAddress]
ON [dbo].[Customer] ([EmailAddress])
WHERE [IsActive] = 1;   -- filtered: add FX_ prefix instead
```

---

## Stored Procedures

- `usp_` prefix — distinguishes user-created procs from system procs (`sp_`) in searches and audits
- PascalCase action-noun format: `usp_{Noun}{Verb}` or `usp_{Noun}_{Verb}`
- Common verbs: `Get`, `Insert`, `Update`, `Delete`, `Merge`, `Search`, `Validate`

```sql
[dbo].[usp_CustomerGetById]
[dbo].[usp_CustomerInsert]
[dbo].[usp_OrderSearch]
[dbo].[usp_OrderLineDelete]
```

---

## Functions

| Function Type | Prefix | Example |
|---|---|---|
| Scalar | `fn_` | `[dbo].[fn_FormatPhoneNumber]` |
| Inline table-valued | `tvf_` | `[dbo].[tvf_GetOrdersByDate]` |
| Multi-statement table-valued | `tvf_` | `[dbo].[tvf_CustomerHierarchy]` |

```sql
-- Scalar
SELECT [dbo].[fn_FormatPhoneNumber]([PhoneNumber]) FROM [dbo].[Customer];

-- Table-valued
SELECT o.[OrderID], o.[OrderDate]
FROM [dbo].[tvf_GetOrdersByDate]('2025-01-01', '2025-12-31') AS o;
```

---

## Views

- `vw_` prefix
- PascalCase, descriptive of what the view returns

```sql
[dbo].[vw_CustomerSummary]
[dbo].[vw_OrdersByRegion]
[dbo].[vw_ActiveProductCatalog]
```

---

## Triggers

- `tr_` prefix
- Pattern: `tr_{TableName}_{Timing}{Event}` where timing is `After` or `Instead`

```sql
[dbo].[tr_Order_AfterInsert]
[dbo].[tr_Customer_AfterUpdate]
[dbo].[tr_OrderLine_InsteadOfDelete]
```

---

## Variables and Parameters

- `@` prefix (required by SQL Server syntax)
- camelCase
- Descriptive, not abbreviated — `@customerId` not `@cid`, `@orderDate` not `@dt`
- Output parameters: suffix with `Out` — `@totalCountOut`

```sql
DECLARE @customerId     int;
DECLARE @orderDateFrom  date;
DECLARE @isActiveFlag   bit;
```

---

## Temp Tables and CTEs

**Temp tables:** `#` prefix (local) or `##` (global — use only when truly necessary). Same PascalCase naming as permanent tables.

```sql
CREATE TABLE [#OrderStaging]
(
    [OrderID]      int           NOT NULL,
    [CustomerID]   int           NOT NULL,
    [ImportedDate] datetime2(0)  NOT NULL DEFAULT GETUTCDATE()
);
```

**CTEs:** PascalCase, descriptive of what the CTE represents. Avoid `CTE` as a suffix — it adds no information.

```sql
WITH [OrderTotals] AS
(
    SELECT [CustomerID], SUM([Amount]) AS TotalAmount
    FROM [dbo].[Order]
    GROUP BY [CustomerID]
),
[ActiveCustomers] AS
(
    SELECT [CustomerID], [EmailAddress]
    FROM [dbo].[Customer]
    WHERE [IsActive] = 1
)
SELECT ...
```

---

## SQL Agent Jobs

Format: `{Category} - {Action} - {Scope}`

| Segment | Purpose | Examples |
|---|---|---|
| Category | Identifies job owner or type | DBA, APP, MAINT, REPL, ETL |
| Action | What the job does | Backup, Monitor, Archive, Rebuild, Purge |
| Scope | What it acts on | Full, Log, All, UserDatabases |

**Examples:**

| Job Name | Notes |
|---|---|
| `DBA - Backup - Full` | Full database backup job |
| `DBA - Backup - Log` | Transaction log backup job |
| `MAINT - IndexOptimize - All` | Ola Hallengren index job |
| `REPL - Monitor - Latency` | Replication latency check |
| `ETL - Load - DataWarehouse` | ETL load job |

**Required job properties before production deployment:**

| Property | Requirement |
|---|---|
| Name | Follows naming convention above |
| Category | Set to an approved category |
| Description | One or more sentences stating what the job does and who owns it |
| Notification operator | Required on any job that modifies data or runs longer than 15 minutes |
| Owner | DBA service account — never SA |

**Exception:** Ola Hallengren Maintenance Solution and SQL Server replication agent jobs retain their default names. They are well-known, searchable, and referenced in external documentation — renaming causes operational confusion.

See [SQL Agent Job Standards](Agent-Job-Standards.md) for full job configuration requirements.

---

## Linked Servers

Format: `{HOST}_{INSTANCE}` — mirrors the instance slug convention (backslash replaced with underscore).

| Linked Server Name | Points To |
|---|---|
| `SQL-PROD-01_REPORTING` | `SQL-PROD-01\REPORTING` |
| `SQL-PROD-01` | `SQL-PROD-01` (default instance) |

Use the physical host and instance name. Avoid friendly display names that hide the target server identity — operational troubleshooting requires knowing the physical target immediately.

See [Linked Server Standards](Linked-Servers.md) for full configuration requirements.

---

## What Not to Do

| Anti-pattern | Why |
|---|---|
| `tbl_Customer`, `col_Name` | Type-based prefixes on tables and columns — noise with no value |
| `SELECT * FROM customers` | Plural table name, unquoted, SELECT * |
| `[ID]` as a primary key column | Ambiguous in joins; use `CustomerID` |
| `sp_GetCustomer` | `sp_` prefix is reserved for system procedures — can cause resolution issues |
| Spaces in names: `[Order Date]` | Requires quoting everywhere; error-prone |
| Mixed conventions in one database | Worse than any single convention |
| Abbreviations only you know: `[cst_nm]` | Unreadable six months later |

---

## A Note on snake_case

snake_case (`customer_id`, `order_date`) is common in PostgreSQL, MySQL, and Python-adjacent SQL Server shops. It is not wrong — many mature SQL Server environments use it successfully. The above conventions follow the PascalCase pattern used in SQL Server system tables, Microsoft documentation examples, and most Windows-domain enterprise environments. If your environment uses snake_case, apply it consistently to everything — the principle is the same.
