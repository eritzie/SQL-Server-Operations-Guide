# DNS Aliases for SQL Server Connectivity

## Purpose

DNS CNAME aliases decouple application connection strings from physical server infrastructure. Rather than connecting to a machine name or named instance, all applications connect to a logical alias that the DBA controls independently in DNS.

The advantages over named instance connection strings:

- **No SQL Browser dependency.** Named instances require SQL Browser to resolve the instance name to a port. SQL Browser is a discoverable service that must remain running and reachable. Aliases with fixed ports eliminate this dependency entirely.
- **Infrastructure changes without application changes.** When a server is migrated, rehosted, or replaced, the DBA updates a DNS record. No application teams need to modify configuration files, connection strings, or ODBC DSNs.
- **Minimal-downtime migrations via DNS flip.** Migration cutover is bounded by the TTL on the DNS record rather than by database size or restore duration. A 300-second TTL limits residual traffic to the old server to five minutes regardless of how large the database is.
- **Simplified firewall rules.** A fixed port combined with an alias means firewall rules reference a single predictable port. Named instances require SQL Browser (UDP 1434) plus a dynamically assigned TCP port, which complicates firewall maintenance.

---

## Default Instance and Fixed Port Standard

All new SQL Server instances should be built as **default instances** (`MSSQLSERVER`) using a **fixed, non-default TCP port**. Named instances should be avoided for new builds.

Reasons:

- The default instance has no instance name component in the connection string — the string carries only the alias and port.
- A fixed port allows SQL Browser to be disabled. SQL Browser resolves named-instance port assignments and is unnecessary when the port is fixed and known.
- Non-default ports reduce exposure to scanners and tooling that probe 1433 by default.

After installation, configure the fixed port in SQL Server Configuration Manager under **SQL Server Network Configuration → Protocols → TCP/IP → IP Addresses → IPAll → TCP Port**. Clear the **TCP Dynamic Ports** field and enter the fixed port number. Restart the SQL Server service for the change to take effect.

Disable SQL Browser when the instance uses a fixed port and no named instances are present on the host:

```powershell
# Disable SQL Browser — only when all instances on this host use fixed ports
Set-DbaSqlBrowser -SqlInstance $instance -Disabled
```

---

## One Alias per Logical Role

Create one DNS CNAME record per logical SQL Server role in the internal DNS zone. Alias names should reflect the workload the instance serves, not the physical host name.

Guidelines:

- Follow the [Naming Conventions](Naming-Conventions.md) standard — use the role code from the server naming table as the alias base.
- Production and test/dev roles get separate aliases. Never share an alias between environments.
- The alias resolves only within the internal DNS zone — it should not be externally resolvable.

| Alias | Role |
|---|---|
| `sql-erp.domain.local` | ERP backend (production) |
| `sql-erp-test.domain.local` | ERP backend (test) |
| `sql-rpt.domain.local` | Reporting (production) |
| `sql-dw.domain.local` | Data warehouse |
| `sql-app.domain.local` | General application database |

These are examples. Derive alias names from your environment's role codes.

---

## CNAME Target by HA Configuration

The alias target differs by HA topology, but the **connection string format is identical in all cases** — the application always connects to `alias,port`. The HA configuration is invisible to the application.

| HA Configuration | CNAME Target |
|---|---|
| Standalone server | Host A record (VM or physical hostname) |
| Basic or Full Availability Group | AG listener name |
| Failover Cluster Instance (FCI) | Cluster Virtual Network Name (VNN / CNO) |

This design means moving between HA types — or replacing a standalone server with a new one — requires only a DNS record update. No application changes are required because the alias and port remain constant.

> **Note:** For AG deployments, the CNAME points to the AG listener, which resolves to the current primary replica. The alias adds a layer above the listener: it is what connection strings reference, so if the listener is ever replaced or renamed, only the DNS record needs updating — not application configuration.

---

## Connection String Format

Use the `alias,port` format in all connection strings. Never use `SERVER\INSTANCE`.

**Before (named instance — avoid for new builds):**

```
Server=SQLSERVER01\ERP;Database=OrderManagement;Integrated Security=True;
```

**After (DNS alias with fixed port — standard format):**

```
Server=sql-erp.domain.local,54001;Database=OrderManagement;Integrated Security=True;Encrypt=True;TrustServerCertificate=False;
```

Always include `Encrypt=True;TrustServerCertificate=False` — this enforces TLS and validates the server certificate. See [TLS Configuration](../Security/TLS-Configuration.md) for certificate requirements.

The connection string does not change when the underlying server is migrated, rehosted, or replaced. Only the DNS record changes.

---

## TTL Recommendation

Set the CNAME TTL to **300 seconds** permanently — not just at migration time.

DNS clients cache records for the TTL duration. A 300-second TTL ensures that when the CNAME is updated during a migration cutover, residual traffic from clients that cached the old record drains within five minutes. If the TTL is left at a longer default value (3600 or 86400 seconds are common), clients continue routing to the old server for up to an hour or a day after the flip.

Setting 300 seconds permanently means:

- There is no "remember to lower the TTL before the migration" step. It is already correct.
- The TTL is low enough for rapid recovery if the record needs to be changed urgently outside of a planned migration.
- DNS cache overhead is negligible — modern resolvers handle short TTLs without issue.

Confirm the TTL is in effect:

```powershell
Resolve-DnsName -Name sql-erp.domain.local -Type CNAME
```

The `TimeToLive` field in the response should show 300.

---

## Migration Cutover Pattern

The DNS alias enables minimal-downtime migration when combined with Log Shipping or another log-forwarding mechanism. The key principle: **application downtime equals TTL drain, not database restore time**.

1. **Create the alias pointing to the current server.** If no alias exists yet, create the CNAME record now and update all application connection strings to the alias format. Test thoroughly while the alias still points to the current server — confirm all applications connect successfully through the alias before proceeding.

2. **Build the new server** and establish Log Shipping to keep it in sync. The new server receives transaction logs continuously throughout the migration window.

3. **Lower the TTL to 300 seconds** at least 24 hours before the planned cutover window. This ensures DNS caches have expired and the reduced TTL is in effect before the flip.

4. **Cutover:**
   - Stop application writes (put the application in maintenance mode or stop the app tier).
   - Apply the final transaction log backup to the new server `WITH RECOVERY` to bring it online.
   - Flip the CNAME record to point to the new server (or its AG listener / VNN).
   - Bring the application back online.
   - Total application downtime: maintenance overhead + final log apply + TTL drain (≤ 300 seconds for residual cached connections).

5. **Keep the old server available** as a rollback path for 24–48 hours. If a critical issue is found post-cutover, flip the CNAME back. No data migration is required for rollback — Log Shipping kept the old server in sync up to the cutover point.

---

## Application Configuration Note

Applications that store the SQL Server connection target in a configuration file (e.g., `Dex.ini`, ODBC DSNs, `app.config`, `web.config`, `.env`) should be updated to the alias format once. After that initial change, future server migrations do not require touching those files — only the DNS record changes.

Establish a record of all connection strings that reference SQL Server by physical name or named instance before beginning the alias transition. Use the validation queries in the next section to locate them systematically.

---

## Validation

```powershell
# Verify DNS resolution — confirm the CNAME and its A record chain
Resolve-DnsName -Name sql-erp.domain.local -Type CNAME

# Verify SQL Server is reachable on the expected port via the alias
Test-DbaConnection -SqlInstance 'sql-erp.domain.local,54001'

# Find legacy SERVER\INSTANCE connection strings in config files
Get-ChildItem -Path 'C:\inetpub' -Recurse -Include *.config,*.ini |
    Select-String -Pattern '\\\\'
```

Scan other common paths as appropriate — application root directories, `C:\Program Files`, and any shared locations where DSN or configuration files are stored.

---

## Related Documents

- [Naming Conventions](Naming-Conventions.md) — server role codes used for alias base names
- [Linked Server Standards](Linked-Servers.md) — connection standards for cross-instance queries
- [Log Shipping Setup](../Disaster-Recovery/LogShipping.md) — log forwarding mechanism used in the migration cutover pattern
- [Availability Groups](../Disaster-Recovery/Availability-Groups.md) — AG listener as a CNAME target for AG deployments
- [SQL Cluster Installation](../Clustering/SqlClusterInstallation.md) — FCI Virtual Network Name as a CNAME target for clustered instances
- [TLS Configuration](../Security/TLS-Configuration.md) — certificate requirements for `Encrypt=True` connections
