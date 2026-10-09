# Installation guide

End-to-end walkthrough, from an empty subscription to a working Leostream
control plane. Budget about 45 minutes, most of which is the Leostream installers
running inside the VMs.

## 0. Before you start

| Requirement | Detail |
|---|---|
| PowerShell | Windows PowerShell 5.1 or PowerShell 7.4+ |
| Az modules | `Install-Module Az -Scope CurrentUser` |
| Azure rights | Contributor **and** User Access Administrator (or Owner) |
| Quota | ~6 vCPUs of the `Dsv5` family in your region |
| SSH key | `ssh-keygen -t ed25519 -C "leostream-poc" -f $HOME\.ssh\leostream_poc` |
| Leostream media | HTTPS download URLs for the Platform 26 and Gateway installers, plus an evaluation licence key |
| Your egress IP | `(Invoke-RestMethod https://api.ipify.org?format=json).ip` |

## 1. Configure

Edit `config/poc.config.psd1`. Two values matter before the first deployment:

```powershell
AllowedClientCidrs = @('203.0.113.45/32')   # your egress IP, not 0.0.0.0/0
Admin = @{
    LinuxUsername    = 'leoadmin'
    SshPublicKeyPath = '~/.ssh/leostream_poc.pub'
}
```

Leaving `AllowedClientCidrs` at `0.0.0.0/0` opens both HTTPS and SSH to the
internet. The deployment script warns you, but does not stop.

Change `Azure.Location` if `westeurope` is not where you want the PoC, and
`Azure.ResourceGroupName` if your naming standards differ.

## 2. Sign in

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'
Get-AzContext | Format-List Name, Account, Subscription, Tenant
```

Alternatively set `Azure.SubscriptionId` in the config file and let the scripts
select it for you.

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

## 4. Grant the Broker its Azure role

```powershell
./Configure-LeostreamAzureRBAC.ps1
```

This confirms the system-assigned managed identity on `leo-broker-01`, enabling
it if it is somehow missing, and assigns **Virtual Machine Contributor** at
resource group scope. New identities take a short while to replicate through
Entra ID, so the script retries for about two minutes before giving up.

Record the subscription ID, tenant ID and resource group name it prints — you
type them into the Broker UI in step 7.

To let the Broker manage VMs outside the resource group:

```powershell
./Configure-LeostreamAzureRBAC.ps1 -Scope Subscription
```

## 5. Install Leostream Platform 26 on the Broker

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

## 6. Install the Leostream Gateway

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

## 7. Configure Leostream

Open the Broker UI through an SSH tunnel on the Gateway:

```powershell
$gw = '<gateway-public-ip>'
ssh -i $HOME\.ssh\leostream_poc -L 8443:10.50.1.10:443 leoadmin@$gw
```

Leave that session open and browse to `https://localhost:8443/`. Accept the
self-signed certificate warning.

1. **Sign in** as `admin` / `leo`, then change the password immediately.
2. **System > License** — apply your evaluation licence.
3. **Setup > Centers > Add Center > Azure** — choose authentication
   **Managed identity**, and enter the subscription, tenant and resource group
   from step 4. Save, then confirm the center lists your VMs.
4. **Setup > Gateways** — add `leo-gateway-01`. Clients connect to the public
   address; the Broker talks to it on `10.50.1.20`.
5. **Configuration > Protocol Plans** — create a plan that uses RDP through the
   Gateway.

That is the full extent of what this PoC configures. Pools, policies and
assignments require at least one desktop.

## 8. Validate

```powershell
./Test-LeostreamPoC.ps1
```

See [validation.md](validation.md) for what each check means and for the manual
tests the script cannot perform.

## 9. Adding a desktop later (optional)

This PoC deploys none. To exercise the full brokering path:

1. Create a Windows 11 VM in `snet-leostream` with no public IP.
2. Install the Leostream Agent on it, pointing at the Broker on `10.50.1.10`.
3. In the Broker UI, create a pool containing the VM, a policy that offers it,
   and an assignment that maps your user to that policy.
4. Connect to the Gateway's public address and sign in as that user.

Bear in mind the VM will be in the same subnet as the Broker and Gateway, and
`nsg-leostream` allows SSH and HTTPS inbound to the whole subnet from
`AllowedClientCidrs` — so give the desktop no public IP, and keep the CIDR tight.

## Common failures

| Error | Cause | Fix |
|---|---|---|
| `SSH public key not found` | Wrong `SshPublicKeyPath` | Generate the key or fix the path |
| `SkuNotAvailable` | VM size not offered in the region | Change `Size` or `Location` |
| `OperationNotAllowed ... quota` | Not enough vCPU quota | Request an increase or use smaller sizes |
| `AuthorizationFailed` on role assignment | Missing User Access Administrator | Get the role, or ask someone who has it to run step 4 |
| RunCommand times out | Guest agent not ready yet | Wait a few minutes after VM creation, then retry |
| Installer download fails in the VM | URL expired or needs authentication | Generate a fresh pre-signed HTTPS URL |
| SSH connection hangs | Your IP is not in `AllowedClientCidrs` | Add it and re-run `Deploy-LeostreamPoC.ps1` |
