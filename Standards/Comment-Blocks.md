# SQL Comment Block Standards

Standard header blocks for SQL Server objects committed to source control.
Use the variant that matches the object type — each section is tailored to what is
actually applicable. Do not copy the full stored procedure block onto a view.

---

## Stored Procedure / Script

Use for: stored procedures, ad-hoc scripts, maintenance scripts.

```sql
/*===============================================================================================
Copyright (C) [YYYY] [Your Company]. All rights reserved.

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

Use for: scalar functions, inline table-valued functions, multi-statement table-valued functions.
Drops Error Codes; adds Returns.

```sql
/*===============================================================================================
Copyright (C) [YYYY] [Your Company]. All rights reserved.

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

Use for: views, DML triggers, DDL triggers.
Parameters, Error Codes, and Usage Example are not applicable.

```sql
/*===============================================================================================
Copyright (C) [YYYY] [Your Company]. All rights reserved.

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

Use for: CREATE TABLE scripts committed to source control.
Schema Notes captures design decisions that are not obvious from column names alone.

```sql
/*===============================================================================================
Copyright (C) [YYYY] [Your Company]. All rights reserved.

Description:
    <What business entity or concept this table represents.>

Schema Notes:
    <Document non-obvious design decisions: soft-delete columns, denormalization,
     partitioning scheme, surrogate vs natural keys, etc. Omit this section if none.>

Change History:
    Date        Author                           Description
    ----------  -------------------------------  ------------------------------------
    YYYY-MM-DD  <Name> (<username>)              Initial creation
===============================================================================================*/
```

---

## SQL Agent Job Definition

Use for: SQL Agent job creation scripts (T-SQL against msdb).
Steps lists each job step and its purpose. On Failure documents the notification target.

```sql
/*===============================================================================================
Copyright (C) [YYYY] [Your Company]. All rights reserved.

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
