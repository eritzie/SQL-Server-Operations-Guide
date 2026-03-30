# SQL-Server-Operations-Guide

Operational reference documentation for SQL Server — covering performance tuning, disaster recovery, failover clustering, security hardening, monitoring, and development standards.

These runbooks were built from hands-on experience managing SQL Server environments at enterprise scale (1,000+ instances) and as a sole DBA responsible for 24/7 availability. They're opinionated, practical, and focused on what actually matters in production.

Every document includes both T-SQL and [dbatools](https://dbatools.io/) PowerShell approaches. Where applicable, guidance is aligned to the [CIS Microsoft SQL Server Benchmark](https://www.cisecurity.org/benchmark/microsoft_sql_server).

## Documents

### Performance

| Document | Description |
|---|---|
| [Performance Practices](PerformancePractices.md) | Disk configuration, Instant File Initialization, Max Server Memory, MAXDOP, Cost Threshold for Parallelism, TempDB configuration, index analysis, and fragmentation management. |

### Disaster Recovery

| Document | Description |
|---|---|
| [Log Shipping Setup](LogShipping.md) | Log shipping architecture, prerequisites, SSMS and dbatools setup, server object synchronization, and monitoring. |
| [Log Shipping Failover](LogShippingFailover.md) | Step-by-step failover and failback procedures with T-SQL and dbatools paths, plus traffic redirection strategies (DNS, config, SQL aliases). |

### Clustering

| Document | Description |
|---|---|
| [Windows Cluster Setup](WindowsClusterSetup.md) | WSFC preparation — disk layout, BIOS tuning, Active Directory prep, cluster creation, quorum configuration, and resource naming. |
| [SQL Cluster Installation](SQLClusterInstallation.md) | SQL Server FCI installation on WSFC — key configuration decisions, post-install hardening, and utility stored procedure deployment. |

### Security

| Document | Description |
|---|---|
| [Security Practices](Security.md) | Authentication strategy, custom database roles, environment permission matrix, SA hardening, surface area reduction, backup encryption, and compliance auditing. |

### Operations

| Document | Description |
|---|---|
| [Backup and Restore](BackupRestore.md) | Full, differential, and log backups with T-SQL, Ola Hallengren, and dbatools. Restore procedures including point-in-time recovery and backup verification. |
| [Monitoring](Monitoring.md) | Real-time activity monitoring, blocking detection, wait statistics, Agent job monitoring, disk space, health checks, log shipping status, and proactive alerting. |

### Standards

| Document | Description |
|---|---|
| [Development and Configuration Standards](BestPractices.md) | Instance configuration baseline, database design standards, T-SQL development practices, naming conventions, indexing guidelines, and reporting database design. |

## Tools Referenced

These community and Microsoft tools are referenced throughout the runbooks:

| Tool | Purpose |
|---|---|
| [dbatools](https://dbatools.io/) | PowerShell module with 500+ commands for SQL Server administration |
| [Ola Hallengren Maintenance Solution](https://ola.hallengren.com/) | Backup, index, and statistics maintenance stored procedures |
| [Brent Ozar First Responder Kit](https://www.brentozar.com/first-aid/) | sp_Blitz, sp_BlitzIndex, sp_BlitzCache, sp_BlitzFirst, sp_BlitzWho |
| [sp_WhoIsActive](http://whoisactive.com/) | Real-time activity monitoring stored procedure |

## Related Repositories

| Repository | Description |
|---|---|
| [SQL-Server-Security-Audit](https://github.com/eritzie/SQL-Server-Security-Audit) | Scripted security audit checks aligned to CIS Microsoft SQL Server Benchmark 2022 v1.2.1 |
| [DBAOps](https://github.com/eritzie/DBAOps) | SQL Server utility database and CI/CD deployment toolkit |
| [SQL-Patching-Jupyter-Notebook](https://github.com/eritzie/SQL-Patching-Jupyter-Notebook) | Interactive SQL Server patching runbook using .NET Interactive notebooks |

## License

This project is licensed under the [MIT License](LICENSE).

## Disclaimer

These runbooks reflect practices from specific SQL Server environments and may need adaptation for yours. Configuration values, schedules, and architecture decisions were tuned for the workloads and SLAs in those environments — treat them as a starting point, not a prescription. Always test in a non-production environment before applying changes.

Contributions, corrections, and suggestions are welcome via issues or pull requests.