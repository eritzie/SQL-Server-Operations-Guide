# DNS Alias Standard for SQL Server Connectivity

All SQL Server instances should be reachable through a stable DNS alias rather than a physical server name or `SERVER\INSTANCE` format. This standard defines how aliases are named, what they point to, and how applications must reference them.

## Purpose

Connecting applications directly to a physical server name couples them to the infrastructure. Every hardware refresh, migration, or HA reconfiguration then requires finding and updating every connection string before the cutover window. DNS aliases break that coupling.

- The alias name reflects the logical role, not the physical host — the alias outlives any single server.
- Migrating an instance to new hardware requires only a DNS flip; application configuration is unchanged.
- SQL Browser is eliminated — the alias carries a fixed TCP port, so dynamic port resolution is never needed.
- TLS certificate binding and firewall rules are simplified because the port is known and stable.

## Instance Type Standard

All new SQL Server instances should be built as **default instances** (no instance name suffix) listening on a **fixed non-default TCP port**.

- Named instances require SQL Browser to resolve dynamic ports. SQL Browser adds a network exposure and a failure mode. Default instances with a fixed port eliminate both.
- Choose a port that does not conflict with other services on the host. Document the assigned port in SQL-Inventory for each instance.
- Once a fixed port is assigned, disable SQL Browser unless a legacy named instance on the same host still requires it.
- When migrating an existing named instance to this standard, the transition can be staged: add the alias pointing to `SERVERNAME\INSTANCENAME` initially, then rebuild as a default instance and retarget the alias without changing any application connection strings.

## DNS Alias Naming

One CNAME record per logical SQL Server role in the internal DNS zone.

- Alias names reflect the business role, not the physical server: `sql-erp`, `sql-pma`, `sql-wms`, `sql-rpl`.
- Production and test roles receive separate aliases with a `-test` suffix on the non-production name: `sql-erp` (production) and `sql-erp-test` (test).
- Alias names are lowercase, hyphenated, and registered in the internal DNS zone (not in hosts files).
- Never embed version numbers, hardware names, or datacenter identifiers in the alias — those details belong in the CNAME target, not the alias name itself.

## CNAME Target by HA Configuration

The alias target differs depending on how the instance is deployed. The connection string format `alias,port` is identical in all three cases — HA type is transparent to applications.

| HA Configuration | CNAME Target |
|---|---|
| Standalone instance | VM or host A record |
| Basic Availability Group | AG listener name |
| Failover Cluster Instance (FCI) | Cluster Virtual Network Name (VNN / CNO) |

This indirection means moving an instance from standalone to a Basic AG, or from a Basic AG to an FCI, requires only a CNAME retarget. No application changes and no workstation changes are needed for the migration.

## Connection String Format Standard

Applications must connect using `alias,port` format. `SERVER\INSTANCE` format is not permitted in new connection strings and should be replaced during any planned maintenance window.

All connection strings must include encryption attributes consistent with the TLS standard:

```
Server=sql-erp,1450;Database=CompanyDB;Integrated Security=SSPI;Encrypt=True;TrustServerCertificate=False;
```

Before/after example for an existing named-instance connection string:

```
# Before — physical server name, named instance, dynamic port
Server=APP-DB-01\SQLPROD;Database=CompanyDB;Integrated Security=SSPI;

# After — role alias, fixed port, encryption enforced
Server=sql-erp,1450;Database=CompanyDB;Integrated Security=SSPI;Encrypt=True;TrustServerCertificate=False;
```

The `TrustServerCertificate=False` setting is required whenever `Encrypt=True` is set. If a self-signed certificate is still in place, the correct resolution is to install a CA-issued certificate (see [[../Security/TLS-Configuration|TLS Configuration]]), not to set `TrustServerCertificate=True`.

## TTL Recommendation

Alias records should carry a TTL of **300 seconds** (5 minutes).

Low TTL is deliberate. During a migration, the final cutover step is updating the CNAME to point at the new server. Clients that have cached the old record will continue sending traffic to the old server until their cached entry expires. With a 300-second TTL, all clients drain to the new target within 5 minutes of the DNS update. A higher TTL (e.g., 3600 seconds or 86400 seconds) would extend that residual traffic window to hours or a full day, requiring a longer application downtime or overlap period.

Lower TTL where the DNS infrastructure supports it (e.g., 60 seconds) is acceptable and reduces the drain window further, but 300 seconds is a practical minimum for most environments.

## Migration Cutover Pattern

DNS aliases allow the actual migration-day cutover to be isolated to the final database sync, with no application reconfiguration under pressure.

1. Create the alias in DNS pointing at the **current** server. Set TTL to 300 seconds.
2. Update all application connection strings and ODBC DSNs to use `alias,port` format. Deploy and validate against the current server — the alias still points at it, so nothing changes from the application's perspective.
3. Prepare the new server. Confirm the alias,port connection string works against the new server directly (bypassing DNS) by using the host A record or IP in a test connection.
4. On migration day, apply the final log backup (or fail over the AG/FCI). When the new server is ready to accept connections, update the CNAME to point at the new target.
5. Within 300 seconds, all clients resolve to the new server. Monitor for connection errors and confirm traffic has shifted before decommissioning the old server.

No step in this sequence requires touching application configuration files during the outage window.

## Dynamics GP Considerations

Dynamics GP stores the SQL Server connection in `Dex.ini` and in ODBC DSNs configured on each workstation. These are updated once to use `alias,port` format. After that, future SQL Server migrations do not require any workstation-level changes — the DNS flip is the only action needed.

- `Dex.ini` key: `SQLServer=sql-erp,1450`
- ODBC DSN: set the server field to `sql-erp,1450` and disable named instance resolution.
- After updating to alias format, document the alias name and port in SQL-Inventory under the GP instance record so future maintenance can reference it.

Refer to [[Dynamics-GP-Standards|Dynamics GP Standards]] for GP-specific change procedures, including the GP Service Account and workstation deployment considerations.

## Audit and Validation

### Verify DNS Resolution

```powershell
Resolve-DnsName -Name sql-erp -Type CNAME
```

Confirm the CNAME record exists, the target A record resolves to the expected IP, and TTL is set to 300 seconds.

```powershell
nslookup sql-erp
```

Use from multiple client locations to confirm there are no stale cached records or split-horizon DNS issues.

### Verify SQL Server Port Availability

```powershell
Test-DbaConnection -SqlInstance sql-erp,1450
```

Confirms that the alias resolves, the TCP port is reachable, and SQL Server accepts the connection. Run this from a representative application host, not only from a DBA workstation.

### Verify No Legacy Connection String Format Remains

Search known configuration file types for `SERVER\INSTANCE` patterns before and after migration:

```powershell
Get-ChildItem -Path 'C:\inetpub' -Recurse -Include '*.config','*.ini','*.xml' |
    Select-String -Pattern '\\\\'
```

Review any matches and update to `alias,port` format. Scope the search path to the application directories relevant to each system.

## Related Documents

- [[Linked-Servers|Linked Server Configuration and Security]]
- [[Naming-Conventions|Naming Conventions]]
- [[../Security/TLS-Configuration|TLS Configuration]]
- [[Standards|Back to Standards]]
