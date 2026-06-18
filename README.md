# SQL-Server-Operations-Guide

Operational reference documentation for SQL Server — covering performance tuning, disaster recovery, failover clustering, security hardening, monitoring, and development standards.

These runbooks were built from hands-on experience managing SQL Server environments at enterprise scale (1,000+ instances) and as a sole DBA responsible for 24/7 availability. They're opinionated, practical, and focused on what actually matters in production.

Every document includes both T-SQL and [dbatools](https://dbatools.io/) PowerShell approaches. Where applicable, guidance is aligned to the [CIS Microsoft SQL Server Benchmark](https://www.cisecurity.org/benchmark/microsoft_sql_server).

## Documents

### Performance

| Document | Description |
|---|---|
| [Performance Practices](Performance/Performance-Practices.md) | Disk configuration, Instant File Initialization, Max Server Memory, MAXDOP, Cost Threshold for Parallelism, TempDB configuration, index analysis, and fragmentation management. |

### Disaster Recovery

| Document | Description |
|---|---|
| [Availability Groups](Disaster-Recovery/Availability-Groups.md) | Always On AG setup for Standard Edition (Basic AG) and Enterprise Edition — edition capability matrix, HA vs. DR topology, setup, failover types, monitoring, and server object synchronization. |
| [Log Shipping Setup](Disaster-Recovery/Log-Shipping-Setup.md) | Log shipping architecture, prerequisites, SSMS and dbatools setup, server object synchronization, and monitoring. |
| [Log Shipping Failover](Disaster-Recovery/Log-Shipping-Failover.md) | Step-by-step failover and failback procedures with T-SQL and dbatools paths, plus traffic redirection strategies (DNS, config, SQL aliases). |
| [Database Mirroring](Disaster-Recovery/Database-Mirroring.md) | Deprecated feature used as a controlled migration tool for zero-data-loss instance moves. Includes setup, monitoring, and cutover procedure. |

### Clustering

| Document | Description |
|---|---|
| [Windows Cluster Setup](Clustering/Windows-Cluster-Setup.md) | WSFC preparation — disk layout, BIOS tuning, Active Directory prep, cluster creation, quorum configuration, and resource naming. |
| [SQL Cluster Installation](Clustering/SQL-Cluster-Installation.md) | SQL Server FCI installation on WSFC — key configuration decisions, post-install hardening, and utility stored procedure deployment. |

### Security

| Document | Description |
|---|---|
| [Security Practices](Security/Security-Practices.md) | Authentication strategy (SQL vs. Windows logins, AD security groups), custom database roles (dr_RO through dr_Deploy), environment permission matrix, SA hardening, surface area reduction, backup encryption, and CIS Benchmark L1 audit script. |
| [Transparent Data Encryption](Security/TDE.md) | When and how to enable TDE, certificate backup requirements, encryption monitoring, and restore implications. |
| [Always Encrypted](Security/Always-Encrypted.md) | Column-level encryption for high-sensitivity data — CMK/CEK hierarchy, deterministic vs. randomized encryption, driver requirements, and Enclave-enabled AE. |
| [SQL Server Audit](Security/SQL-Server-Audit.md) | Server and database audit specification setup, CIS Benchmark-aligned action groups, log querying, file retention, and compliance mapping. |
| [TLS Configuration](Security/TLS-Configuration.md) | Certificate requirements, forcing encryption, TLS 1.2 minimum enforcement, validating active encryption, and SQL Server 2025 breaking changes. |

### Operations

| Document | Description |
|---|---|
| [Backup and Restore](Operations/Backup-and-Restore.md) | Full, differential, and log backups with T-SQL, Ola Hallengren, and dbatools. Restore procedures including point-in-time recovery and backup verification. |
| [Monitoring](Operations/Monitoring.md) | Real-time activity monitoring, blocking detection, wait statistics, Agent job monitoring, disk space, health checks, log shipping status, and proactive alerting. |
| [Integrity Checks](Operations/Integrity-Checks.md) | DBCC CHECKDB scheduling via Ola Hallengren, output interpretation, corruption response procedures (RESTORE PAGE and last-resort REPAIR), and offloading checks to an AG secondary replica. |
| [Deadlock Analysis](Operations/Deadlock-Analysis.md) | Reading deadlock graphs from system_health and Extended Events, four common deadlock patterns with root causes, prevention strategies, and application retry guidance. |
| [Query Tuning](Operations/Query-Tuning.md) | Six-step tuning methodology, execution plan operators, missing index DMVs, statistics diagnosis, parameter sniffing identification and remediation. |
| [Capacity Planning](Operations/Capacity-Planning.md) | Disk growth trending, autogrowth event detection, memory pressure indicators, TempDB usage, CPU utilization baselines, and weekly baseline collection. |
| [Maintenance Solution](Operations/Maintenance-Solution.md) | Ola Hallengren Maintenance Solution installation, job schedule recommendations, IndexOptimize parameters, and CommandLog monitoring. |
| [Query Store](Operations/Query-Store.md) | When to enable Query Store, recommended settings, plan regression detection, and forced plan management. |
| [Extended Events](Operations/Extended-Events.md) | Blocking detection and deadlock capture sessions — creation, management, and reading XEL file output. |
| [Resource Governor](Operations/Resource-Governor.md) | Enterprise Edition workload isolation — resource pools, workload groups, classifier functions, monitoring, and SQL Server 2022 TempDB spill limits. |
| [Replication](Operations/Replication.md) | Transactional replication topology, latency monitoring, maintenance window coordination, subscription reinitialization, and troubleshooting. |
| [Linked Servers](Operations/Linked-Servers.md) | Provider selection, creation syntax, login mapping, OPENQUERY vs four-part names, Kerberos delegation, MSDTC, and troubleshooting. |
| [Standalone Installation](Operations/Standalone-Installation.md) | Pre-installation OS preparation, disk layout, service account setup, feature selection, post-installation hardening, and verification. |
| [Database Mail](Operations/Database-Mail.md) | Profile and account setup, SQL Server Agent operator configuration, multi-account failover profiles, test send, and mail queue troubleshooting. |
| [SSRS Operations](Operations/SSRS.md) | Service account configuration, initial setup, encryption key management, subscriptions, data source credentials, execution log monitoring, and backup/recovery. |
| [SSIS Operations](Operations/SSIS.md) | SSISDB catalog setup, project deployment model, proxy accounts, environments, SQL Agent integration, monitoring, SSISDB in AGs, and catalog maintenance. |
| [SQL Server 2019 Readiness](Operations/SQL-2019-Readiness.md) | Pre-upgrade checklist, compatibility level 150 behavior changes, ADR, IQP features, automatic plan correction, and Standard vs. Enterprise feature delta. |
| [SQL Server 2022 Readiness](Operations/SQL-2022-Readiness.md) | Pre-upgrade checklist, PSPO, DOP and memory grant feedback persistence, Contained AGs, Ledger tables, Query Store hints, and 2022 vs. 2019 feature matrix. |
| [SQL Server 2025 Readiness](Operations/SQL-2025-Readiness.md) | Breaking changes (Encrypt=Mandatory, TrustServerCertificate enforcement), pre-upgrade assessment, OPPO, IQP 3.0, and recommended preparation timeline. |

### Standards

| Document | Description |
|---|---|
| [SQL Standards and Policies](Standards/SQL-Standards-and-Policies.md) | Policy-level governance covering backup policy, HA/DR requirements, change control, security and access controls, maintenance housekeeping, audit and compliance, and documentation standards. |
| [Development and Configuration Standards](Standards/Development-and-Configuration-Standards.md) | Instance configuration checklist, database design standards (normalization, primary key selection, file storage), T-SQL practices (implicit conversions, parameter sniffing), indexing guidelines, and reporting database design. |
| [Database Configuration Baseline](Standards/Database-Configuration.md) | ALTER DATABASE configuration baseline: AUTO_CLOSE, AUTO_SHRINK, PAGE_VERIFY, autogrowth unit, compatibility level, recovery model, and RCSI — with audit queries, fix scripts, and multi-instance scanning. |
| [Naming Conventions](Standards/Naming-Conventions.md) | Server, instance, disk, and object naming standards — tables, columns, constraints, indexes, procedures, functions, views, triggers, variables, and service accounts. |
| [Comment Block Standards](Standards/Comment-Blocks.md) | Standard header blocks for stored procedures, functions, views, triggers, tables, and Agent job scripts. |
| [SQL Agent Job Standards](Standards/Agent-Job-Standards.md) | Job naming, required properties, step configuration, proxy accounts, history retention, and audit queries. |
| [SQL Server Audit Standards](Standards/Audit-Standards.md) | SQL Server Audit deployment standard: required server and database action groups, file target configuration, retention policy, deployment procedure, and queries for investigating login failures, security changes, and sa activity. |
| [Change Management](Standards/Change-Management.md) | Change classification, idempotent script patterns, transactional DDL, rollback scripts, schema version tracking, and DevOps pipeline integration. |
| [Statistics Management](Standards/Statistics-Management.md) | Auto-update thresholds, dynamic threshold behavior at compat 130+, detection queries, FULLSCAN vs. sampling, filtered statistics, and Ola Hallengren integration. |
| [Patch Management](Standards/Patch-Management.md) | CU inventory, change control gate, pre-patch checklist, application procedure, post-patch validation, and rollback path. |
| [Linked Server Standards](Standards/Linked-Servers.md) | Naming convention, authentication options, required security settings, creation, audit queries, and when to use linked servers. |
| [DNS Aliases](Standards/DNS-Aliases.md) | DNS CNAME alias standard for SQL Server — decoupling connection strings from physical infrastructure, default instance and fixed port standard, alias-per-role pattern, CNAME targets by HA type, and minimal-downtime migration cutover via DNS flip. |

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
