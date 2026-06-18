# Database Mail

## Purpose

Setup and configuration of Database Mail, which is the notification infrastructure for SQL Server Agent job alerts, operator emails, and custom T-SQL notifications. Every Agent job notification and alert depends on Database Mail being configured correctly before it will work.

---

## Prerequisites

- [ ] Database Mail XP surface area feature enabled (disabled by default)
- [ ] Network access from the SQL Server service account to an SMTP relay or mail server
- [ ] An operator email address to test against
- [ ] Firewall rules allowing outbound SMTP (default port 25, or 587 for TLS-authenticated SMTP)

---

## Enable Database Mail XP

```sql
EXEC [sys].[sp_configure] 'Database Mail XPs', 1;
RECONFIGURE;
```

Verify it is enabled:

```sql
SET NOCOUNT ON;

SELECT
    [name],
    [value_in_use]
FROM [sys].[configurations]
WHERE [name] = 'Database Mail XPs';
```

---

## Setup via dbatools

```powershell
$ErrorActionPreference = 'Stop'

# Create a mail account (connects to the SMTP server)
$splatAccount = @{
    SqlInstance     = $instance
    Account         = 'DBA-Alerts'
    Description     = 'Primary SMTP account for SQL Server Agent notifications'
    EmailAddress    = 'sqlalerts@yourdomain.com'
    ReplyToAddress  = 'sqlalerts@yourdomain.com'
    DisplayName     = 'SQL Server Alerts'
    MailServer      = 'smtp.yourdomain.com'
    EnableException = $true
}
New-DbaDbMailAccount @splatAccount

# Create a profile and associate the account
$splatProfile = @{
    SqlInstance     = $instance
    Profile         = 'DBA-Alerts'
    Description     = 'Default profile for SQL Server Agent notifications'
    Account         = 'DBA-Alerts'
    EnableException = $true
}
New-DbaDbMailProfile @splatProfile
```

---

## T-SQL Fallback

Use if dbatools is unavailable or fine-grained control is needed:

```sql
SET NOCOUNT ON;

-- Step 1: Create account
EXEC [msdb].[dbo].[sysmail_add_account_sp]
    @account_name        = N'DBA-Alerts',
    @description         = N'Primary SMTP account for SQL Server Agent notifications',
    @email_address       = N'sqlalerts@yourdomain.com',
    @replyto_address     = N'sqlalerts@yourdomain.com',
    @display_name        = N'SQL Server Alerts',
    @mailserver_name     = N'smtp.yourdomain.com';

-- Step 2: Create profile
EXEC [msdb].[dbo].[sysmail_add_profile_sp]
    @profile_name = N'DBA-Alerts',
    @description  = N'Default profile for SQL Server Agent notifications';

-- Step 3: Associate account with profile (sequence_number = priority order)
EXEC [msdb].[dbo].[sysmail_add_profileaccount_sp]
    @profile_name    = N'DBA-Alerts',
    @account_name    = N'DBA-Alerts',
    @sequence_number = 1;

-- Step 4: Grant profile access to the msdb public role
EXEC [msdb].[dbo].[sysmail_add_principalprofile_sp]
    @profile_name   = N'DBA-Alerts',
    @principal_name = N'public',
    @is_default     = 1;
```

---

## Multi-Account Failover Profile

For environments requiring reliability, configure a second account as a fallback. Database Mail tries accounts in sequence_number order:

```sql
SET NOCOUNT ON;

EXEC [msdb].[dbo].[sysmail_add_account_sp]
    @account_name    = N'DBA-Alerts-Fallback',
    @description     = N'Fallback SMTP account',
    @email_address   = N'sqlalerts@yourdomain.com',
    @display_name    = N'SQL Server Alerts',
    @mailserver_name = N'smtp-backup.yourdomain.com';

EXEC [msdb].[dbo].[sysmail_add_profileaccount_sp]
    @profile_name    = N'DBA-Alerts',
    @account_name    = N'DBA-Alerts-Fallback',
    @sequence_number = 2;
```

---

## SQL Server Agent Operator Configuration

Agent job notifications require an operator. Create one after the profile is configured:

```powershell
$splatOp = @{
    SqlInstance     = $instance
    Operator        = 'DBA-Team'
    EmailAddress    = 'dba@yourdomain.com'
    EnableException = $true
}
New-DbaAgentOperator @splatOp
```

Then configure Agent to use the Database Mail profile:

```sql
EXEC [msdb].[dbo].[sp_set_sqlagent_properties]
    @email_save_in_sent_folder = 1,
    @databasemail_profile      = N'DBA-Alerts';
```

Alternatively, set this in SSMS: SQL Server Agent → Properties → Alert System → Enable mail profile.

---

## Send a Test Email

```sql
EXEC [msdb].[dbo].[sp_send_dbmail]
    @profile_name  = N'DBA-Alerts',
    @recipients    = N'dba@yourdomain.com',
    @subject       = N'Database Mail Test',
    @body          = N'Database Mail is configured and working.';
```

```powershell
$splatMail = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaDbMailLog @splatMail |
    Select-Object -First 10 LogDate, EventType, Description
```

---

## Troubleshooting

### Check the mail log

```sql
SET NOCOUNT ON;

SELECT TOP 50
    [log_date],
    [event_type],
    [description]
FROM [msdb].[dbo].[sysmail_event_log]
ORDER BY [log_date] DESC;
```

### Check for failed items

```sql
SET NOCOUNT ON;

SELECT TOP 20
    [sent_date],
    [recipients],
    [subject],
    [sent_status],
    [last_mod_date]
FROM [msdb].[dbo].[sysmail_faileditems]
ORDER BY [last_mod_date] DESC;
```

### Check the mail queue

```sql
SET NOCOUNT ON;

SELECT
    [mailitem_id],
    [sent_date],
    [recipients],
    [subject],
    [sent_status]
FROM [msdb].[dbo].[sysmail_allitems]
WHERE [sent_status] IN ('unsent', 'retrying')
ORDER BY [sent_date] DESC;
```

### Restart the mail queue if stuck

```sql
EXEC [msdb].[dbo].[sysmail_start_sp];
```

If messages are stuck in `unsent` status with no send attempts in the log, the Database Mail external program (`DatabaseMail.exe`) has stopped. Running `sysmail_start_sp` restarts it without restarting SQL Server.

---

## Related Documents

- [[../Standards/Agent-Job-Standards|SQL Agent Job Standards]] — notification operator requirements per job
- [[Monitoring|Monitoring]] — alert configuration for severity errors and job failures
- [[Operations|Back to Operations]]
