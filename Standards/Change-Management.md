# Change Management

## Purpose

Define how changes reach production: classification, checklist, script conventions, rollback
requirement, and post-deployment validation. Every change that touches a production SQL Server
must go through this process. The goal is not bureaucracy — it is repeatability and a clear
record of what changed, when, and why.

Related documents: [Comment Block Standards](Comment-Blocks.md) |
[Best Practices](BestPractices.md) |
[Monitoring](../Operations/Monitoring.md)

---

## Change Classification

| Class     | Definition                                   | Examples                                                                 | Approval Required                                       |
|-----------|----------------------------------------------|--------------------------------------------------------------------------|---------------------------------------------------------|
| Standard  | Pre-approved, low risk, reversible           | Index rebuild, statistics update, `sp_configure` within approved range   | DBA review only                                         |
| Normal    | Tested change with defined rollback          | New stored procedure, table alteration, new index                        | DBA + application team sign-off                         |
| Emergency | Unplanned, production-impacting              | Hotfix for active outage, blocking query kill                            | DBA team lead verbal approval; document after           |
| Major     | Significant structural change                | New table with FK chains, large data migration, compatibility level change | Full change control board                             |

---

## Pre-Change Checklist

Every Normal and Major change must satisfy all items before a change window is scheduled.

- [ ] Change tested in development environment and passes
- [ ] Change tested in staging/UAT against a recent production data copy
- [ ] Rollback script written and tested
- [ ] Estimated duration documented (script timed in staging)
- [ ] Backup confirmed current before execution, or a new backup taken
- [ ] Affected application teams notified with expected window and impact
- [ ] Monitoring dashboard open during execution
- [ ] DBA available for the full change window plus 30 minutes post-deployment

---

## Script Standards

### 1. Idempotent

Scripts must be safe to run twice without errors or unintended side effects.

```sql
SET NOCOUNT ON;

-- Column addition (idempotent)
IF NOT EXISTS (
    SELECT 1
    FROM   [sys].[columns]
    WHERE  [object_id] = OBJECT_ID(N'dbo.Customer')
      AND  [name]      = N'IsVerified'
)
BEGIN
    ALTER TABLE [dbo].[Customer]
    ADD [IsVerified] bit NOT NULL DEFAULT 0;
END;
```

### 2. Transactional Where Possible

DDL (CREATE TABLE, ALTER TABLE, CREATE INDEX) can be wrapped in a transaction and rolled back
if validation fails. Always validate inside the transaction before committing.

```sql
SET NOCOUNT ON;

BEGIN TRANSACTION;

    ALTER TABLE [dbo].[Order] ADD [ShipRegion] nvarchar(50) NULL;

    -- Validate before committing
    IF NOT EXISTS (
        SELECT 1
        FROM   [sys].[columns]
        WHERE  [object_id] = OBJECT_ID(N'dbo.Order')
          AND  [name]      = N'ShipRegion'
    )
    BEGIN
        ROLLBACK TRANSACTION;
        RAISERROR('Column addition failed — rolling back.', 16, 1);
        RETURN;
    END;

COMMIT TRANSACTION;
```

### 3. Comment Block Header

All deployment scripts must open with the standard comment block. See
[Comment Block Standards](Comment-Blocks.md) for the full template.

```sql
/*
  OBJECT  : ALTER TABLE dbo.Order
  PURPOSE : Add ShipRegion column for multi-region shipping support
  AUTHOR  : DBA Team
  DATE    : 2026-01-15
  VERSION : 1.0
  TICKET  : CHG-4821
  TESTED  : SQL-DEV-01 (2026-01-14), SQL-STG-01 (2026-01-15)
*/
```

### 4. Default Target

Scripts must default to the development instance. They should require an explicit parameter
change or in-script confirmation before executing against a production instance.

---

## Rollback Scripts

Write the rollback at the same time as the deployment script — not after the change is
already in production. A rollback written under pressure during an incident is error-prone.

```sql
-- Deployment: Add column
ALTER TABLE [dbo].[Order] ADD [ShipRegion] nvarchar(50) NULL;
```

```sql
-- Rollback: Remove column (separate file)
SET NOCOUNT ON;

IF EXISTS (
    SELECT 1
    FROM   [sys].[columns]
    WHERE  [object_id] = OBJECT_ID(N'dbo.Order')
      AND  [name]      = N'ShipRegion'
)
BEGIN
    ALTER TABLE [dbo].[Order] DROP COLUMN [ShipRegion];
END;
```

Store deployment and rollback scripts together with clear naming:

```
CHG-4821_Add_ShipRegion_DEPLOY.sql
CHG-4821_Add_ShipRegion_ROLLBACK.sql
```

---

## Online vs Offline Operations

Large tables require online operations to avoid blocking application queries during business
hours. Online operations require Enterprise Edition.

```sql
-- Online index rebuild — does not block reads or writes
ALTER INDEX [IX_Order_CustomerID] ON [dbo].[Order]
REBUILD WITH (ONLINE = ON);

-- Online column addition with default (SQL Server 2012+) — does not block
ALTER TABLE [dbo].[Order]
ADD [ProcessedFlag] bit NOT NULL
    CONSTRAINT [DF_Order_ProcessedFlag] DEFAULT 0
    WITH VALUES;
```

Operations that cannot be done online and always require a maintenance window:

- Adding a NOT NULL column without a default to a table with existing rows
- Changing a column's data type in a way that requires a table rebuild
- Enabling TDE for the first time (encrypting existing data blocks I/O during initial scan)
- Enabling or disabling RCSI (acquires a schema modification lock briefly at the moment of
  the state change)

---

## Database Version Tracking

Maintain a version table in each managed database to track applied changes. This provides an
audit trail without relying solely on source control history.

```sql
SET NOCOUNT ON;

-- Create the version tracking table (run once per database)
IF NOT EXISTS (
    SELECT 1
    FROM   [sys].[tables]
    WHERE  [name]      = 'SchemaVersion'
      AND  [schema_id] = SCHEMA_ID('dbo')
)
BEGIN
    CREATE TABLE [dbo].[SchemaVersion]
    (
        [VersionID]    int           NOT NULL IDENTITY(1,1),
        [Version]      nvarchar(20)  NOT NULL,
        [Description]  nvarchar(500) NOT NULL,
        [AppliedDate]  datetime2(0)  NOT NULL DEFAULT GETUTCDATE(),
        [AppliedBy]    nvarchar(128) NOT NULL DEFAULT SUSER_SNAME(),
        [TicketNumber] nvarchar(50)  NULL,
        CONSTRAINT [PK_SchemaVersion] PRIMARY KEY ([VersionID])
    );
END;

-- Record a change after deployment
INSERT INTO [dbo].[SchemaVersion] ([Version], [Description], [TicketNumber])
VALUES ('1.4.2', 'Add ShipRegion column to dbo.Order', 'CHG-4821');
```

Migration tools (Flyway, Liquibase, DbUp) can automate this tracking. If using a migration
tool, do not modify the version table manually — the tool owns it.

---

## Post-Deployment Validation

Verify expected state before closing the change window. Do not assume the script succeeded
because it ran without errors — confirm the object state in the catalog.

```sql
SET NOCOUNT ON;

-- Verify column was added
SELECT
    [c].[name]              AS ColumnName,
    [t].[name]              AS DataType,
    [c].[max_length],
    [c].[is_nullable],
    [c].[default_object_id]
FROM [sys].[columns] AS c
JOIN [sys].[types]   AS t
    ON [c].[user_type_id] = [t].[user_type_id]
WHERE [c].[object_id] = OBJECT_ID(N'dbo.Order')
  AND [c].[name]      = N'ShipRegion';

-- Verify application can connect and execute key queries
EXEC [dbo].[usp_OrderGetById] @orderId = 1;
```

Confirm with the application team that affected functionality is working before the DBA
stands down from the change window.

---

## DevOps Pipeline Integration

Automated pipelines enforce these standards consistently and eliminate the risk of a manual
step being skipped under time pressure.

- Scripts must pass a T-SQL linter or style check before a pull request can be merged
- Migrations run automatically against dev and staging environments on pull request creation
- Production deployments require a manual approval gate in the pipeline
- The pipeline verifies that a rollback script exists alongside every deployment script before
  approving the production run

Tools in common use: SSDT (SQL Server Data Tools) for schema comparison deployments, Flyway
or DbUp for migration-based deployments with automatic version tracking.

---

## Emergency Change Process

When production is down, the process is abbreviated — not skipped.

1. Get verbal approval from the DBA team lead before making any change.
2. Take a targeted backup if time permits. At minimum, record the exact current state of the
   affected objects (scripted table definition, current `sp_configure` values, etc.).
3. Apply the fix.
4. Document the change immediately after the incident is resolved: what was applied, when, by
   whom, and why.
5. Conduct a post-incident review within 48 hours. Determine whether a follow-up Normal change
   is required — for example, an index added as an emergency hotfix should be formally reviewed,
   tested for regressions, and documented through the standard process.
