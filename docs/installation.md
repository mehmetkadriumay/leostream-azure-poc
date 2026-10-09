# Installation guide

End-to-end walkthrough, from an empty subscription to a working Leostream
control plane. Budget about 45 minutes, most of which is the Leostream installers
running inside the VMs.

## 0. Before you start

| Requirement | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7.4+ |
| Az modules | `Install-Module Az -Scope CurrentUser` |
| Azure rights | **Contributor**. User Access Administrator is *not* needed — no role assignments are created |
| Quota | ~6 vCPUs of the `Dsv5` family in your region |
| SSH key | Either reuse `~/.ssh/id_rsa.pub`, which is the config default, or generate `ssh-keygen -t ed25519 -C "leostream-poc" -f $HOME\.ssh\leostream_poc` **and** point `Admin.SshPublicKeyPath` at it |
| Leostream media | HTTPS download URLs for the Platform 26 and Gateway installers, plus an evaluation licence key |
| Your egress IP | `(Invoke-RestMethod https://api.ipify.org?format=json).ip` |

## 1. Configure

Edit `config/poc.config.psd1`. Two values matter before the first deployment:

```powershell
AllowedClientCidrs = @('203.0.113.45/32')   # your egress IP, not 0.0.0.0/0
Admin = @{
    LinuxUsername    = 'leoadmin'
    SshPublicKeyPath = '~/.ssh/id_rsa.pub'   # or your dedicated PoC key
}
```

Leaving `AllowedClientCidrs` at `0.0.0.0/0` opens both HTTPS and SSH to the
internet. The deployment script warns you, but does not stop.

`SshPublicKeyPath` decides which key ends up on both VMs, and therefore which
private key you must pass to `ssh -i` from then on. If you generated a dedicated
key such as `~/.ssh/leostream_poc.pub`, change this value **before** deploying —
changing it afterwards has no effect on VMs that already exist. Verify it now:

```powershell
$pub = (Import-PowerShellDataFile ./config/poc.config.psd1).Admin.SshPublicKeyPath
Test-Path ($pub -replace '^~', $HOME)     # must print True
```

Change `Azure.Location` if `westeurope` is not where you want the PoC, and
`Azure.ResourceGroupName` if your naming standards differ.

## 2. Sign in

```powershell
Connect-AzAccount -Tenant '<tenant-id>'
Set-AzContext -Subscription '<subscription-id>'
Get-AzContext | Format-List Name, Account, Subscription, Tenant
```

Always confirm the last line prints the subscription and tenant you expect
before deploying. Creating the PoC in the wrong subscription is easy and tedious
to unpick.

### Finding your tenant and subscription IDs

`-Tenant` is required whenever your account exists in more than one Entra ID
directory — guest accounts, partner tenants, or anyone with both a corporate and
a customer directory. Without it `Connect-AzAccount` authenticates against your
**home** tenant, which may not be the one holding the target subscription. The
symptom is a successful sign-in followed by the subscription simply not being
listed, or `Get-AzSubscription` returning nothing useful.

```powershell
# Sign in first, then list what you can actually see
Connect-AzAccount

# Every tenant your account can reach - find yours by DefaultDomain
Get-AzTenant | Format-Table Id, Name, DefaultDomain

# Subscriptions within one specific tenant
Get-AzSubscription -TenantId '<tenant-id>' | Format-Table Name, Id, TenantId, State
```

Take the `TenantId` of the subscription you want, then re-run
`Connect-AzAccount -Tenant '<that-id>'`.

> **Expect warning noise.** If your account is a guest in many directories —
> common for consultants and partner-facing staff — a bare `Get-AzSubscription`
> tries every tenant and prints
> `Unable to acquire token for tenant ... User interaction is required` for each
> one it cannot silently authenticate to. That is **not** an error with your
> setup; those are simply tenants you have not signed in to in this session.
> Scoping the call with `-TenantId`, as above, avoids the noise. The
> subscriptions that do list are still valid.

If a Conditional Access policy blocks the default browser flow, add
`-UseDeviceAuthentication` to `Connect-AzAccount`.

Alternatively set `Azure.SubscriptionId` in the config file and let the scripts
select it for you. The tenant still has to be correct at sign-in time —
`Azure.SubscriptionId` only chooses among subscriptions you are already
authenticated to see.

## 3. Deploy the infrastructure

```powershell
cd scripts
./Deploy-LeostreamPoC.ps1 -WhatIf      # preview
./Deploy-LeostreamPoC.ps1 -Verbose     # about 5 minutes
```

The script creates, in order:

1. Resource group, tagged `project=leostream-poc`
2. `nsg-leostream` with inbound 443 and 22 from `AllowedClientCidrs`
3. `vnet-leostream-poc` with the single subnet `snet-leostream`
4. `leo-broker-01` — private, system-assigned managed identity
5. `leo-gateway-01` — public IP, static, Standard SKU

Every step checks for an existing resource first, so re-running is safe. NSG
rules are rewritten on each run, which is how you apply a changed
`AllowedClientCidrs`.

It finishes by printing the Gateway's public IP and the three SSH commands you
need for administration. Keep that output.

## 4. Install Leostream Platform 26 on the Broker

```powershell
./Install-LeostreamBroker.ps1 -InstallerUri 'https://<portal>/<platform-26-installer>'
```

The script runs through the Azure RunCommand extension, so the Broker needs no
inbound connectivity. Inside the VM it updates RHEL 9, installs prerequisites,
sets the hostname, opens 443/tcp in firewalld, downloads and runs the installer,
and optionally applies a licence key.

To supply the licence non-interactively:

```powershell
$licence = Read-Host -AsSecureString 'Leostream licence key'
./Install-LeostreamBroker.ps1 -InstallerUri 'https://...' -LicenseKey $licence
```

Allow 10–20 minutes. RunCommand streams the output back when the script finishes,
not as it runs, so a long silence is normal.

## 5. Install the Leostream Gateway

```powershell
./Install-LeostreamGateway.ps1 -InstallerUri 'https://<portal>/<gateway-installer>'
```

This configures firewalld (443 and 22 open), applies the kernel settings the
Gateway needs, runs the installer, and records the Broker's private address so
the Gateway knows where to forward.

The host firewall deliberately leaves SSH open: `nsg-leostream` is the single
place that restricts who can reach it, and since the Gateway is your only way in,
a second, independently configured restriction is a good way to lock yourself
out.

The Broker address defaults to `VirtualMachines.Broker.PrivateIp` from config.
Override it with `-BrokerAddress` if you changed the addressing.

## 6. Configure Leostream

### Reaching the Broker console

The Broker has no public IP, so forward a local port to it through the Gateway.

**Run this on your own Windows PC, in PowerShell** — not in Cloud Shell and not
inside either VM. `-L` is an instruction to your local SSH client, and your
private key only exists on your PC. If you see an error mentioning a path like
`/home/leoadmin.sshleostream_poc`, you are in a bash shell inside a VM; type
`exit` first.

```powershell
cd C:\path\to\leostream-azure-poc

$cfg  = Import-PowerShellDataFile ./config/poc.config.psd1
$rg   = $cfg.Azure.ResourceGroupName
$user = $cfg.Admin.LinuxUsername
$key  = ($cfg.Admin.SshPublicKeyPath -replace '^~', $HOME -replace '\.pub$','')
$gw   = (Get-AzPublicIpAddress -ResourceGroupName $rg `
           -Name $cfg.VirtualMachines.Gateway.PublicIpName).IpAddress

$gw                # must print an IP address
Test-Path $key     # must print True

ssh -i $key -L 8443:10.50.1.10:443 $user@$gw
```

Check both values every time. PowerShell expands an unset variable to an empty
string rather than failing, which surfaces later as a confusing error such as
`Invalid -J argument` or `Identity file ... not accessible`. Variables are also
per-window, so re-run those lines in each new terminal.

**Leave that SSH window open** — it *is* the tunnel. In a browser on the same PC,
browse to `https://localhost:8443/` and accept the self-signed certificate
warning.

Full details, including the `ssh -J` form for a Broker shell and a
symptom-by-symptom troubleshooting table, are in the
[Administrative access](../README.md#administrative-access) section of the README.

1. **Sign in** as `admin` / `leo`, then change the password immediately.
2. **System > License** — apply your evaluation licence.
3. **Setup > Gateways** — add `leo-gateway-01`. Clients connect to the public
   address; the Broker talks to it on `10.50.1.20`.
4. **Configuration > Protocol Plans** — create a plan that uses RDP through the
   Gateway.

That is the full extent of what this PoC configures. Do **not** add an Azure
center: a center discovers and power-manages desktop VMs, and there are none
here. Pools, policies and assignments likewise require at least one desktop.

## 7. Validate

```powershell
./Test-LeostreamPoC.ps1
```

See [validation.md](validation.md) for what each check means and for the manual
tests the script cannot perform.

## 8. Adding a desktop later (optional)

This PoC deploys none. To exercise the full brokering path:

1. Create a Windows 11 VM in `snet-leostream` with no public IP.
2. Install the Leostream Agent on it, pointing at the Broker on `10.50.1.10`.
3. Ask a subscription **Owner** or **User Access Administrator** to grant the
   Broker's managed identity **Virtual Machine Contributor** on
   `rg-leostream-poc`, then add an Azure center under *Setup > Centers* using
   **Managed identity** authentication.
4. In the Broker UI, create a pool containing the VM, a policy that offers it,
   and an assignment that maps your user to that policy.
5. Connect to the Gateway's public address and sign in as that user.

Bear in mind the VM will be in the same subnet as the Broker and Gateway, and
`nsg-leostream` allows SSH and HTTPS inbound to the whole subnet from
`AllowedClientCidrs` — so give the desktop no public IP, and keep the CIDR tight.

## Common failures

| Error | Cause | Fix |
|---|---|---|
| `SSH public key not found` | Wrong `SshPublicKeyPath` | Generate the key or fix the path |
| `SkuNotAvailable` | VM size not offered in the region | Change `Size` or `Location` |
| `OperationNotAllowed ... quota` | Not enough vCPU quota | Request an increase or use smaller sizes |
| `Forbidden` / `AuthorizationFailed` creating a role assignment | You are granting the Broker identity a role, which needs User Access Administrator or Owner. Many subscriptions also apply an ABAC condition restricting *which* roles you may assign | Not needed for this PoC — no role assignment is required. Only relevant when adding desktops; ask a subscription Owner |
| RunCommand times out | Guest agent not ready yet | Wait a few minutes after VM creation, then retry |
| Installer download fails in the VM | URL expired or needs authentication | Generate a fresh pre-signed HTTPS URL |
| SSH connection hangs | Your IP is not in `AllowedClientCidrs` | Add it and re-run `Deploy-LeostreamPoC.ps1` |
