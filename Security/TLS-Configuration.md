# TLS Configuration

## Purpose

Configuring SQL Server to encrypt connections between clients and the server. Encryption in transit protects credentials and query data from interception. TLS configuration is required by compliance frameworks and becomes a breaking-change requirement starting with SQL Server 2025, where `Encrypt=Mandatory` is enforced by default.

---

## How SQL Server Connection Encryption Works

| Mode | What It Encrypts | When It Applies |
|---|---|---|
| Login packet only (default, pre-2025) | Authentication handshake only | Always — even without a certificate |
| Full session encryption | All traffic between client and server | When forced at the server or requested by the client |

Full session encryption requires a valid certificate installed on the SQL Server machine. Without a certificate, SQL Server generates a self-signed certificate at startup for login packet encryption only.

---

## Certificate Requirements

The certificate must meet all of the following:

- [ ] Issued to the server's fully qualified domain name (FQDN)
- [ ] Placed in the **Local Computer > Personal** certificate store
- [ ] The SQL Server service account has **read permission** on the certificate's private key
- [ ] Not expired
- [ ] Enhanced Key Usage includes **Server Authentication** (OID 1.3.6.1.5.5.7.3.1)

| Certificate Type | Pros | Cons |
|---|---|---|
| CA-issued (domain or public CA) | Trusted by all domain clients automatically | Requires certificate lifecycle management |
| Self-signed | Easy to create, no cost | Clients must explicitly trust it or use `TrustServerCertificate=True` — a compliance finding |

Use a CA-issued certificate in production. Self-signed is acceptable for dev/test instances where client connection strings can be controlled.

---

## Generate a Self-Signed Certificate (Dev/Test Only)

```powershell
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

The SQL Server service account must be able to read the certificate's private key. Without this, SQL Server silently falls back to the auto-generated self-signed certificate.

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

Once the certificate is in place, force all connections to encrypt:

```powershell
$splatForce = @{
    SqlInstance     = $instance
    EnableException = $true
}
Enable-DbaForceNetworkEncryption @splatForce
```

After enabling, restart the SQL Server service. Test with a non-production instance first — all clients that connect without `Encrypt=True` in their connection string will fail.

---

## Enforce TLS 1.2 Minimum

Disable TLS 1.0 and 1.1 via Windows registry. This affects all SCHANNEL consumers on the machine, not just SQL Server.

```powershell
$ErrorActionPreference = 'Stop'

# Disable TLS 1.0
$tls10Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.0'
New-Item -Path "$tls10Path\Server" -Force | Out-Null
New-Item -Path "$tls10Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls10Path\Server" -Name 'Enabled'           -Value 0 -Type DWord
Set-ItemProperty -Path "$tls10Path\Server" -Name 'DisabledByDefault' -Value 1 -Type DWord
Set-ItemProperty -Path "$tls10Path\Client" -Name 'Enabled'           -Value 0 -Type DWord
Set-ItemProperty -Path "$tls10Path\Client" -Name 'DisabledByDefault' -Value 1 -Type DWord

# Disable TLS 1.1
$tls11Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.1'
New-Item -Path "$tls11Path\Server" -Force | Out-Null
New-Item -Path "$tls11Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls11Path\Server" -Name 'Enabled'           -Value 0 -Type DWord
Set-ItemProperty -Path "$tls11Path\Server" -Name 'DisabledByDefault' -Value 1 -Type DWord
Set-ItemProperty -Path "$tls11Path\Client" -Name 'Enabled'           -Value 0 -Type DWord
Set-ItemProperty -Path "$tls11Path\Client" -Name 'DisabledByDefault' -Value 1 -Type DWord

# Explicitly enable TLS 1.2
$tls12Path = 'HKLM:\SYSTEM\CurrentControlSet\Control\SecurityProviders\SCHANNEL\Protocols\TLS 1.2'
New-Item -Path "$tls12Path\Server" -Force | Out-Null
New-Item -Path "$tls12Path\Client" -Force | Out-Null
Set-ItemProperty -Path "$tls12Path\Server" -Name 'Enabled'           -Value 1 -Type DWord
Set-ItemProperty -Path "$tls12Path\Server" -Name 'DisabledByDefault' -Value 0 -Type DWord
Set-ItemProperty -Path "$tls12Path\Client" -Name 'Enabled'           -Value 1 -Type DWord
Set-ItemProperty -Path "$tls12Path\Client" -Name 'DisabledByDefault' -Value 0 -Type DWord
```

A machine restart is required for SCHANNEL changes to take effect.

---

## Validate Encryption is Active

```sql
SET NOCOUNT ON;

SELECT
    [session_id],
    [login_name],
    [host_name],
    [program_name],
    [encrypt_option],
    [auth_scheme]
FROM [sys].[dm_exec_connections] AS c
JOIN [sys].[dm_exec_sessions]    AS s
    ON c.[session_id] = s.[session_id]
WHERE s.[is_user_process] = 1
ORDER BY [login_name];
```

`encrypt_option` should show `TRUE` for all connections once force encryption is enabled.

```powershell
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

> **Warning:** SQL Server 2025 enforces `Encrypt=Mandatory` and validates the server certificate by default. Any connection string that does not specify a trusted certificate — or relies on `TrustServerCertificate=True` — will fail after upgrading.

Before upgrading to SQL Server 2025:
1. Install a CA-issued certificate on every SQL Server instance.
2. Audit all application connection strings and update them to trust the CA.
3. Validate that SSMS, dbatools, and monitoring tools connect successfully with the new certificate.

See [[../Operations/SQL-2025-Readiness|SQL Server 2025 Readiness]] for the full pre-upgrade checklist.

---

## Client Connection String Reference

| Scenario | Connection String Setting |
|---|---|
| Enforce encryption, trust CA cert | `Encrypt=True;TrustServerCertificate=False` |
| Enforce encryption, bypass cert check (dev only) | `Encrypt=True;TrustServerCertificate=True` |
| No encryption (legacy, not recommended) | `Encrypt=False` |
| SQL Server 2025 default | `Encrypt=Mandatory` enforced server-side |

---

## Related Documents

- [[Security-Practices|Security Practices]] — authentication and access control standards
- [[../Operations/SQL-2025-Readiness|SQL Server 2025 Readiness]] — breaking changes and pre-upgrade checklist
- [[Security|Back to Security]]
