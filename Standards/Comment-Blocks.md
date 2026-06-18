# SQL Comment Block Standards

## Purpose

Define standard header blocks for all SQL Server objects committed to source control.
Use the variant that matches the object type — each section is tailored to what is actually applicable.
Do not copy the full stored procedure block onto a view.

---

## Stored Procedure / Script

Use for stored procedures, ad-hoc scripts, and maintenance scripts.

```sql
/*===============================================================================================
Copyright (C) 2026 Outdoor Network. All rights reserved.

Description:
    <Brief description of what this procedure or script does.>

Parameters:
    @ParamName   as <type>   <description>

Usage Example:
    EXEC [dbo].[usp_ProcedureName] @ParamName = <value>;

Error Codes:
    XXXXXX    SP: %s. Unexpected error: %i-%s

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

---

## Function (Scalar or Table-Valued)

Use for scalar functions, inline table-valued functions, and multi-statement table-valued functions.
Drops Error Codes; adds Returns.

```sql
/*===============================================================================================
Copyright (C) 2026 Outdoor Network. All rights reserved.

Description:
    <Brief description of what this function does.>

Parameters:
    @ParamName   as <type>   <description>

Returns:
    <type>   <description of return value or result set>

Usage Example:
    SELECT [dbo].[fn_FunctionName](@ParamName);

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

---

## View / Trigger

Use for views and DML/DDL triggers.
Parameters, Error Codes, and Usage Example are not applicable to these object types.

```sql
/*===============================================================================================
Copyright (C) 2026 Outdoor Network. All rights reserved.

Description:
    <Brief description of what this view or trigger does.>

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

---

## Table Definition

Use for CREATE TABLE scripts committed to source control.
Schema Notes captures design decisions that are not obvious from column names alone —
soft-delete patterns, denormalized columns and why, partitioning scheme, surrogate vs natural keys.
Omit the Schema Notes section if there is nothing non-obvious to document.

```sql
/*===============================================================================================
Copyright (C) 2026 Outdoor Network. All rights reserved.

Description:
    <What business entity or concept this table represents.>

Schema Notes:
    <Non-obvious design decisions. Omit this section if none.>

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

---

## SQL Agent Job Definition

Use for SQL Agent job creation scripts (T-SQL against msdb).
Steps lists each job step and its purpose. On Failure documents the notification target.
See [[Agent-Job-Standards|Agent Job Standards]] for naming and ownership requirements.

```sql
/*===============================================================================================
Copyright (C) 2026 Outdoor Network. All rights reserved.

Description:
    <Brief description of what this job does and why it exists.>

Schedule:
    <Frequency and time, e.g. "Daily at 02:00 AM" or "Every 15 minutes">

Steps:
    1. <Step name> — <what it does>
    2. <Step name> — <what it does>

On Failure:
    <Notification method and recipient, e.g. "Email DBA-Alerts operator">

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

## See Also

- [[Agent-Job-Standards|Agent Job Standards]]
- [[Naming-Conventions|Naming Conventions]]
