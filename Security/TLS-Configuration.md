# TLS Configuration and Encryption in Transit

## Purpose

Document how to configure SQL Server to encrypt connections between clients and the server. Encryption in transit protects credentials and query data from interception on the network. TLS configuration is increasingly required by compliance frameworks and becomes a breaking-change requirement starting with SQL Server 2025, where `Encrypt=Mandatory` is enforced by default.

---

## How SQL Server Connection Encryption Works

SQL Server supports two levels of connection encryption:

| Mode | What It Encrypts | When It Applies |
|---|---|---|
| **Login packet only** (default, pre-2025) | Authentication handshake only | Always — even without a certificate |
| **Full session encryption** | All traffic between client and server | When forced at the server or requested by the client |

Full session encryption requires a valid certificate installed on the SQL Server machine. Without a certificate, SQL Server generates a self-signed certificate at startup for login packet encryption only.

---

## Certificate Requirements

SQL Server uses the machine certificate store. The certificate must meet all of the following:

- [ ] Issued to the server's fully qualified domain name (FQDN) — e.g., `sql01.yourdomain.com`
- [ ] Placed in the **Local Computer > Personal** certificate store
- [ ] The SQL Server service account has **read permission** on the certificate's private key
- [ ] Not expired
- [ ] Enhanced Key Usage includes **Server Authentication** (OID 1.3.6.1.5.5.7.3.1)

**CA-issued vs. self-signed:**

| Certificate Type | Pros | Cons |
|---|---|---|
| CA-issued (domain or public CA) | Trusted by all domain clients automatically | Requires certificate lifecycle management |
| Self-signed | Easy to create, no cost | Clients must explicitly trust it or use `TrustServerCertificate=True` — a compliance finding |

For production environments, use a CA-issued certificate. Self-signed is acceptable for dev/test instances where client connection strings can be controlled.

---

## Generate a Self-Signed Certificate (Dev/Test Only)

```powershell
# Create self-signed cert valid for 3 years, placed in LocalMachine\My
$splatCert = @{
    DnsName           = $env:COMPUTERNAME, "$env:COMPUTERNAME.yourdomain.com"
    CertStoreLocation = 'Cert:\LocalMachine\My'
    KeyUsage          = 'KeyEncipherment', 'DataEncipherment'
    FriendlyName      = 'SQL Server TLS'
    NotAfter          = (Get-Date).AddYears(3)
}
$cert = New-SelfSignedCertificate @splatCert
Write-Output "Thumbprint: $($cert.Thumbprint)"
```

---

## Grant the SQL Service Account Access to the Certificate

The SQL Server service account must be able to read the certificate's private key. Without this, SQL Server fails to start or silently falls back to the auto-generated self-signed certificate.

```powershell
# Get the service account name
$splatSvc = @{
    ComputerName    = $instance
    EnableException = $true
}
$serviceAccount = (Get-DbaService @splatSvc |
    Where-Object ServiceType -eq 'Engine').StartName

# Grant read access to the private key
$splatPrivKey = @{
    ComputerName    = $instance
    Thumbprint      = '<certificate-thumbprint>'
    ServiceAccount  = $serviceAccount
    EnableException = $true
}
Set-DbaPrivateKeyAccess @splatPrivKey
```

---

## Configure SQL Server to Use the Certificate

Use SQL Server Configuration Manager (GUI) or set via registry. The registry path varies by instance:

- Default instance: `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL{version}.MSSQLSERVER\MSSQLServer\SuperSocketNetLib`
- Named instance: `HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\MSSQL{version}.{InstanceName}\MSSQLServer\SuperSocketNetLib`

```powershell
# dbatools handles the registry path automatically
$splatTls = @{
    SqlInstance     = $instance
    Thumbprint      = '<certificate-thumbprint>'
    EnableException = $true
}
Set-DbaNetworkCertificate @splatTls
```

Restart the SQL Server service for the certificate change to take effect.

---

## Force Encryption for All Connections

Once the certificate is in place, force all connections to encrypt. This setting is in SQL Server Configuration Manager under **SQL Server Network Configuration > Protocols > Force Encryption**.

```powershell
# Enable forced encryption
$splatForce = @{
    SqlInstance     = $instance
    EnableException = $true
}
Enable-DbaForceNetworkEncryption @splatForce
```

After enabling, restart the SQL Server service. All clients that connect without `Encrypt=True` in their connection string will fail — test with a non-production instance first and validate that all application connection strings are updated.

---

## Enforce TLS 1.2 Minimum (Disable TLS 1.0 and 1.1)

TLS 1.0 and 1.1 are deprecated. PCI-DSS requires TLS 1.2 minimum. Configure via Windows registry — this affects all SCHANNEL consumers on the machine, not just SQL Server.

```powershell
$ErrorActionPreference = 'Stop'

# Disable TLS 1.0
$tls10Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0'
New-Item -Path "$tls10Path\Server" -Force | Out-Null
New-Item -Path "$tls10Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls10Path\Server" -Name 'Enabled'      -Value 0 -Type DWord
Set-ItemProperty -Path "$tls10Path\Server" -Name 'DisabledByDefault' -Value 1 -Type DWord
Set-ItemProperty -Path "$tls10Path\Client" -Name 'Enabled'      -Value 0 -Type DWord
Set-ItemProperty -Path "$tls10Path\Client" -Name 'DisabledByDefault' -Value 1 -Type DWord

# Disable TLS 1.1
$tls11Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1'
New-Item -Path "$tls11Path\Server" -Force | Out-Null
New-Item -Path "$tls11Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls11Path\Server" -Name 'Enabled'      -Value 0 -Type DWord
Set-ItemProperty -Path "$tls11Path\Server" -Name 'DisabledByDefault' -Value 1 -Type DWord
Set-ItemProperty -Path "$tls11Path\Client" -Name 'Enabled'      -Value 0 -Type DWord
Set-ItemProperty -Path "$tls11Path\Client" -Name 'DisabledByDefault' -Value 1 -Type DWord

# Explicitly enable TLS 1.2 (enabled by default on Windows Server 2012 R2+, but be explicit)
$tls12Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
New-Item -Path "$tls12Path\Server" -Force | Out-Null
New-Item -Path "$tls12Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls12Path\Server" -Name 'Enabled'      -Value 1 -Type DWord
Set-ItemProperty -Path "$tls12Path\Server" -Name 'DisabledByDefault' -Value 0 -Type DWord
Set-ItemProperty -Path "$tls12Path\Client" -Name 'Enabled'      -Value 1 -Type DWord
Set-ItemProperty -Path "$tls12Path\Client" -Name 'DisabledByDefault' -Value 0 -Type DWord
```

A machine restart is required for SCHANNEL changes to take effect.

---

## Validate Encryption is Active

```sql
SET NOCOUNT ON;

-- Check whether current connections are encrypted
SELECT
    [session_id],
    [login_name],
    [host_name],
    [program_name],
    [encrypt_option],
    [auth_scheme]
FROM [sys].[dm_exec_connections] AS c
JOIN [sys].[dm_exec_sessions]   AS s
    ON c.[session_id] = s.[session_id]
WHERE s.[is_user_process] = 1
ORDER BY [login_name];
```

`encrypt_option` should show `TRUE` for all connections once force encryption is enabled.

```powershell
# Check certificate and encryption state via dbatools
$splatCheck = @{
    SqlInstance     = $instance
    EnableException = $true
}
Get-DbaComputerCertificate @splatCheck |
    Where-Object SqlInstance -ne $null |
    Select-Object SqlInstance, FriendlyName, Thumbprint, NotAfter, DnsNameList
```

---

## SQL Server 2025 Breaking Change

> **Warning:** SQL Server 2025 enforces `Encrypt=Mandatory` and validates the server certificate by default. Any client connection string that does not specify a trusted certificate — or that relies on `TrustServerCertificate=True` — will fail after upgrading to SQL Server 2025.

Before upgrading to SQL Server 2025:

1. Install a CA-issued certificate on every SQL Server instance.
2. Audit all application connection strings for `TrustServerCertificate=True` and update them to trust the CA instead.
3. Validate that SSMS, dbatools, and any monitoring tools connect successfully with the new certificate.
4. See [SQL Server 2025 Readiness](../Operations/SQL-2025-Readiness.md) for the full pre-upgrade checklist.

---

## Client Connection String Reference

| Scenario | Connection String Setting |
|---|---|
| Enforce encryption, trust CA cert | `Encrypt=True;TrustServerCertificate=False` |
| Enforce encryption, bypass cert check (dev only) | `Encrypt=True;TrustServerCertificate=True` |
| No encryption (legacy, not recommended) | `Encrypt=False` |
| SQL Server 2025 default (no override needed) | `Encrypt=Mandatory` enforced server-side |

---

## Related Documents

- [Security](Security.md) — authentication and access control standards
- [SQL Server 2025 Readiness](../Operations/SQL-2025-Readiness.md) — breaking changes and pre-upgrade checklist
