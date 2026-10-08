# Installation guide

Step-by-step deployment of the Leostream Platform 26 proof of concept on Azure.

Estimated time: **45–75 minutes**, most of it waiting for Azure Bastion and the
Leostream installers.

---

## 1. Prerequisites

### Tooling on your workstation

| Requirement | Minimum | Check |
|---|---|---|
| PowerShell | 5.1 (7.4+ recommended) | `$PSVersionTable.PSVersion` |
| Az PowerShell modules | 11.0 | `Get-Module Az.Accounts -ListAvailable` |
| OpenSSH client | any | `ssh -V` |
| Git | 2.40 | `git --version` |

```powershell
Install-Module Az -Scope CurrentUser -Repository PSGallery -Force
```

The scripts run on both **Windows PowerShell 5.1** and **PowerShell 7.x**.
PowerShell 7 is recommended for clearer error messages and faster Az cmdlets,
but nothing in this repository requires it. On 5.1 make sure .NET Framework
4.7.2 or later is installed, which the Az modules need.

### Azure

* A subscription where you can create resource groups, VNets, VMs, Bastion and
  **role assignments** (Owner or User Access Administrator is needed for the
  RBAC step).
* Quota for at least 10 vCPUs of the `Dsv5` family in your chosen region.
* Red Hat Enterprise Linux 9 and Windows 11 marketplace images available in that
  region.

### Leostream

* A Leostream Platform 26 evaluation licence.
* Download URLs (HTTPS) for:
  * the Leostream Platform 26 installer,
  * the Leostream Gateway installer,
  * the Leostream Agent MSI.

> These URLs are passed as parameters at run time. **Never commit installers,
> licence keys or serial numbers to this repository** — `.gitignore` blocks the
> common file types, but the responsibility is yours.

### SSH key

```powershell
ssh-keygen -t ed25519 -C "leostream-poc" -f $HOME\.ssh\leostream_poc
```

Point `Admin.SshPublicKeyPath` in `config/poc.config.psd1` at the `.pub` file.

---

## 2. Clone and configure

```powershell
git clone https://github.com/mehmetkadriumay/leostream-azure-poc.git
cd leostream-azure-poc
```

Edit `config/poc.config.psd1`:

| Setting | Notes |
|---|---|
| `Azure.SubscriptionId` | Leave empty to use the current `Get-AzContext`. |
| `Azure.Location` | Region with RHEL 9 images and Dsv5 quota. |
| `AllowedClientCidrs` | **Change from `0.0.0.0/0`** to your own egress IPs. |
| `Admin.SshPublicKeyPath` | Path to your SSH public key. |
| `VirtualMachines.*.Size` | Reduce for a cheaper PoC (for example `Standard_D2s_v5`). |
| `VirtualMachines.*.SecurityType` | `Standard` by default. Set `TrustedLaunch` for secure boot and vTPM on the Gen2 RHEL images. |
| `Bastion.Enabled` | Set `$false` if you already have a jump host. |

Find your public IP for `AllowedClientCidrs`:

```powershell
(Invoke-RestMethod https://api.ipify.org?format=json).ip
```

---

## 3. Sign in to Azure

```powershell
Connect-AzAccount
Set-AzContext -Subscription '<subscription-id>'
Get-AzContext | Format-List Name, Subscription, Tenant
```

---

## 4. Deploy the infrastructure

Dry run first:

```powershell
cd scripts
./Deploy-LeostreamPoC.ps1 -WhatIf
```

Then deploy:

```powershell
./Deploy-LeostreamPoC.ps1 -Verbose
```

There is no password prompt — both VMs are Linux and accept SSH keys only.

To save time and cost during an initial test, skip Bastion:

```powershell
./Deploy-LeostreamPoC.ps1 -SkipBastion
```

What is created:

1. Resource group `rg-leostream-poc`
2. Three NSGs with role-specific rules
3. VNet `vnet-leostream-poc` with four subnets — `snet-desktop` is created but
   left empty
4. Azure Bastion (10–20 minutes)
5. `leo-broker-01` and `leo-gateway-01`

> **No desktops are deployed.** This PoC covers the Leostream control plane
> only. See [Optional: add a desktop](#optional-add-a-desktop) below.

The script prints a summary including the Gateway public IP. Note it down.

The script is idempotent: re-running it skips resources that already exist.

---

## 5. Grant the Broker its Azure permissions

```powershell
./Configure-LeostreamAzureRBAC.ps1
```

This confirms the system-assigned managed identity on `leo-broker-01` and
assigns **Virtual Machine Contributor** at resource group scope. Directory
replication can lag, so the script retries the assignment for up to two minutes.

Wider scope, if the Broker must also see VMs outside the PoC resource group:

```powershell
./Configure-LeostreamAzureRBAC.ps1 -Scope Subscription
```

---

## 6. Install Leostream Platform 26 on the Broker

```powershell
./Install-LeostreamBroker.ps1 -InstallerUri 'https://<your-portal>/<platform-26-installer>'
```

The script runs through the Azure RunCommand extension, so no inbound SSH is
needed. It updates RHEL 9, installs prerequisites, opens 443/tcp in firewalld,
sets the hostname and runs the installer.

Optionally supply the licence key as a SecureString:

```powershell
$lic = Read-Host -AsSecureString 'Leostream licence key'
./Install-LeostreamBroker.ps1 -InstallerUri 'https://...' -LicenseKey $lic
```

Otherwise complete licensing in the Broker web interface.

---

## 7. Install the Leostream Gateway

```powershell
./Install-LeostreamGateway.ps1 -InstallerUri 'https://<your-portal>/<gateway-installer>'
```

This configures firewalld (443 open to the internet, SSH restricted to
`10.50.0.0/16`), applies the kernel forwarding settings the Gateway needs, runs
the installer and records the Broker address in `/etc/leostream/gateway.conf`.

---

## 8. Optional: add a desktop

This PoC deploys no desktops, so the brokering path is not wired up out of the
box. If you want to test it, create a Windows VM in `snet-desktop`
(`10.50.10.0/24`) with **no public IP** — Windows 11 marketplace images are Gen2
and require Trusted Launch — then:

```powershell
./Install-LeostreamAgent.ps1 -VMName <your-desktop-name> `
    -InstallerUri 'https://<your-portal>/LeostreamAgent.msi'
```

This enables Remote Desktop on that VM, limits RDP to the gateway,
infrastructure and Bastion subnets, then installs the Agent silently with
`BROKER_ADDRESS` pointed at `10.50.2.10`. `nsg-desktop` already allows the
required traffic, so no network changes are needed.

Skip this step to evaluate the control plane only.

---

## 9. Configure Leostream

Open the Broker UI. It has no public IP, so create an SSH tunnel through the
Gateway:

```powershell
ssh -i $HOME\.ssh\leostream_poc -L 8443:10.50.2.10:443 leoadmin@<gateway-public-ip>
# then browse to https://localhost:8443/
```

Bastion native-client tunnelling is an alternative, but it needs
`Bastion.Sku = 'Standard'` set before deployment:

```powershell
az network bastion tunnel --name bastion-leostream-poc --resource-group rg-leostream-poc `
    --target-resource-id <leo-broker-01-resource-id> --resource-port 443 --port 8443
```

Then, in the Broker:

1. **Sign in** with the default `admin` / `leo` account and change the password
   immediately.
2. **Licence** the Broker under *System > License*.
3. **Add the Azure center** under *Setup > Centers > Add Center > Azure*:
   * Authentication: **Managed identity**
   * Subscription ID and Tenant ID: printed by `Configure-LeostreamAzureRBAC.ps1`
   * Resource group: `rg-leostream-poc`
4. **Register the Gateway** under *Setup > Gateways*:
   * Address: the Gateway public IP or FQDN
   * Private address: `10.50.1.10`
5. **Create a protocol plan** that uses RDP through the Gateway.

Steps 1–5 are the full scope of this PoC. If you added a desktop in step 8,
continue:

6. **Create a pool** under *Configuration > Pools* containing that desktop.
7. **Create a policy** that offers the pool, and assign it in
   *Configuration > Assignments*.

---

## 10. Validate

```powershell
./Test-LeostreamPoC.ps1
```

See [validation.md](validation.md) for the full list of checks and the manual
end-to-end test.

---

## 11. Tear down

```powershell
./Remove-LeostreamPoC.ps1
```

Deletes the resource group and the Broker's role assignments. Use
`-KeepResourceGroup` to keep the empty resource group, and `-Force` to skip the
confirmation prompt.
