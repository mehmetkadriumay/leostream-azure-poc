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
| Leostream media | Nothing to download by hand. The packages come from the public URLs in `poc.config.psd1`. An evaluation licence key is still needed |
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
./Install-LeostreamBroker.ps1
```

The package version comes from `Leostream.BrokerInstallerUri` in
`poc.config.psd1`. The script prints the URL it is using before it starts. To
pin a different build for one run:

```powershell
./Install-LeostreamBroker.ps1 -InstallerUri 'https://downloads.leostream.com/leostream-broker-26.1.6-1.x86_64.rpm'
```

The script runs through the Azure RunCommand extension, so the Broker needs no
inbound connectivity. Inside the VM it updates RHEL 9, installs prerequisites,
sets the hostname, opens 443/tcp in firewalld, enables EPEL, downloads and
installs the package, and optionally applies a licence key.

To supply the licence non-interactively:

```powershell
$licence = Read-Host -AsSecureString 'Leostream licence key'
./Install-LeostreamBroker.ps1 -LicenseKey $licence
```

Allow 10–20 minutes. RunCommand streams the output back when the script finishes,
not as it runs, so a long silence is normal.

## 5. Install the Leostream Gateway

```powershell
./Install-LeostreamGateway.ps1
```

This configures firewalld (443 and 22 open), applies the kernel settings the
Gateway needs, enables EPEL, installs the package, and records the Broker's
private address so the Gateway knows where to forward. The version comes from
`Leostream.GatewayInstallerUri`, overridable with `-InstallerUri`.

Expect this one to take longer than the Broker: the Gateway pulls in roughly
400 dependency packages, around 230 MB.

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
`Identity file ... not accessible` or a hang. Variables are also per-window, so
re-run those lines in each new terminal.

`Test-Path $key` printing `True` only means *a* key is there — not that it is
the right one. The key the VMs accept is whichever one was configured when they
were **created**, which may differ if you deployed from another clone of this
repo. If SSH is refused, run the snippet in
[Checking which key is actually deployed](../README.md#checking-which-key-is-actually-deployed).

**Leave that SSH window open** — it *is* the tunnel. In a browser on the same PC,
browse to `https://localhost:8443/` and accept the self-signed certificate
warning.

Full details, including how to open a Broker *shell* through the Gateway and a
symptom-by-symptom troubleshooting table, are in the
[Administrative access](../README.md#administrative-access) section of the README.
Note that the obvious `ssh -i $key -J $user@$gw ...` does **not** work with a
non-default key name — the README explains why and gives two forms that do.

1. **Sign in** as `admin` / `leo`, then change the password immediately.
2. **System > License** — apply your evaluation licence.
3. **Setup > Gateways** — add `leo-gateway-01`. Clients connect to the public
   address; the Broker talks to it on `10.50.1.20`.
4. **Configuration > Protocol Plans** — create a plan that uses RDP through the
   Gateway.

That is the full extent of what this PoC configures. Do **not** add an Azure
center yet: a center discovers and power-manages desktop VMs, and there are none
here. Pools, policies and assignments likewise require at least one desktop.

When you are ready to go further,
[leostream-configuration.md](leostream-configuration.md) walks through the
center form, image preparation, pools, provisioning, plans, policies and the
Test Login check, field by field.

## 7. Validate

```powershell
./Test-LeostreamPoC.ps1
```

See [validation.md](validation.md) for what each check means and for the manual
tests the script cannot perform.

## 8. Azure Center credentials (optional)

An Azure Center lets the Broker see, create, start and stop Azure VMs. Skip this
if you only want the control plane.

```powershell
./Configure-LeostreamAzureCenter.ps1
```

This creates an Entra ID application, its service principal and a client secret,
then tries to grant the service principal `Contributor` on `rg-leostream-poc`.
It prints the four values to type into *Setup > Centers > Add Center >
Microsoft Azure*:

```
Subscription ID         : ...
Tenant / Directory ID   : ...
Application (client) ID : ...
Client secret           : ...
```

**Copy the secret immediately.** Azure reveals it once, and the script
deliberately does not write it to disk. If you lose it, run
`./Configure-LeostreamAzureCenter.ps1 -RotateSecret` for a replacement.

### If you are only a Contributor

Creating the application and the secret needs no Azure RBAC — those are
Microsoft Entra operations. Only the role assignment needs **Owner** or **User
Access Administrator**. When that step fails the script keeps everything it has
already created and prints the command to delegate:

```powershell
New-AzRoleAssignment -ObjectId <sp-object-id> -RoleDefinitionName 'Contributor' `
    -Scope '/subscriptions/<sub-id>/resourceGroups/rg-leostream-poc'
```

Use `-SkipRoleAssignment` to collect that command without attempting the call.
Until it is run, the Center authenticates but lists no virtual machines.

If your tenant blocks self-service app registration, have an administrator
create a bare application (no API permissions, no redirect URI) and run
`./Configure-LeostreamAzureCenter.ps1 -ApplicationId <client-id>`.

Re-running the script is safe: it reuses an existing application, service
principal and role assignment instead of creating duplicates.

### You only need the administrator once

The role assignment is scoped to `rg-leostream-poc`, and both it and the Entra
application outlive the VMs. So as long as you keep the resource group, a
redeployment inherits the grant and the same client secret keeps working:

```powershell
./Remove-LeostreamPoC.ps1     # deletes the VMs, disks, IPs and NAT gateway; keeps the RG
./Deploy-LeostreamPoC.ps1     # redeploys into the same RG
```

That is the default behaviour — an empty resource group is free, and keeping it
is what saves you a second request to an Owner or User Access Administrator.
`Deploy-LeostreamPoC.ps1` reports at the end whether the application and its
role assignment survived.

Two things undo it, both opt-in: `-RemoveResourceGroup` (the assignment is
scoped to the group, so it dies with it, and a new group of the same name does
not inherit it) and `-RemoveAzureCenterApp` (deletes the application, service
principal and secret). Use them only when you are finished for good.

### What the center needs from the network

The Broker calls the Azure management API itself, over `natgw-leostream`. It
needs outbound 443 to `login.microsoftonline.com`, `management.azure.com` and
`*.blob.core.windows.net`, all of which change IP address between calls.
`./Test-LeostreamPoC.ps1` probes these from inside the Broker and verifies the
TLS handshake completes, which catches an intercepting proxy that would pass a
plain connectivity test and then break the API.

Set *Authentication* to **Application Key** and *Region* to the value in
`Azure.Location`. A center manages exactly one region and can provision only
into resource groups in that region.

## 9. Adding a desktop later (optional)

This PoC deploys none. To exercise the full brokering path:

1. Create a Windows 11 VM in `snet-leostream` with no public IP.
2. Install the Leostream Agent on it, pointing at the Broker on `10.50.1.10`.
3. Add the Azure Center from step 8 under *Setup > Centers*.
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
| `Forbidden` / `AuthorizationFailed` creating a role assignment | Granting a role needs User Access Administrator or Owner. Many subscriptions also apply an ABAC condition restricting *which* roles you may assign | Not needed for the base deployment. For an Azure Center, the application and secret are still created — forward the printed `New-AzRoleAssignment` command to a subscription Owner |
| `Authorization_RequestDenied` creating the application | The tenant has disabled self-service app registration | Have an administrator create a bare app registration, then `./Configure-LeostreamAzureCenter.ps1 -ApplicationId <client-id>` |
| `PrincipalNotFound` on the role assignment | Entra has not yet replicated the new service principal | The script retries six times over a minute; re-run it if it still fails |
| RunCommand times out | Guest agent not ready yet | Wait a few minutes after VM creation, then retry |
| Installer download fails in the VM | The pinned version was withdrawn, or a custom URL expired | Verify with `Invoke-WebRequest -Method Head <uri>`, then pass a current one via `-InstallerUri` |
| `No match for argument: ./leostream-...` | dnf only treats a local file as a package when the name ends in `.rpm` | The scripts preserve the upstream file name, so this only appears with a URL that has no file component |
| `nothing provides libguac` / `openvpn` / `certbot` / `mod_perl` | EPEL missing — these are not in the Azure RHUI repositories | The scripts enable EPEL automatically. By hand: `dnf -y install epel-release` |
| SSH connection hangs | Your IP is not in `AllowedClientCidrs` | Add it and re-run `Deploy-LeostreamPoC.ps1` |
