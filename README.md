# Leostream Platform 26 on Azure — Proof of Concept

PowerShell automation for the smallest useful **Leostream Platform 26** proof of
concept on Microsoft Azure: **two virtual machines in one subnet.** A private
Connection Broker and a separate internet-facing Leostream Gateway. Nothing else.

> **No secrets, installers or licence material live in this repository.**
> Linux access is SSH-key only, the Broker uses a system-assigned managed
> identity, and Leostream media is downloaded at run time from URLs you supply.

---

## Contents

- [Architecture](#architecture)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Quick start](#quick-start)
- [Configuration](#configuration)
- [Deployment](#deployment)
- [Administrative access](#administrative-access)
- [Leostream configuration](#leostream-configuration)
- [Azure Center credentials](#azure-center-credentials)
- [Validation](#validation)
- [Troubleshooting](#troubleshooting)
- [Teardown](#teardown)
- [Cost](#cost)
- [Security notes](#security-notes)
- [Licence](#licence)

---

## Architecture

```mermaid
flowchart LR
    user([Remote user]) -->|HTTPS 443| gw
    admin([You]) -->|SSH 22| gw

    subgraph rg["rg-leostream-poc · vnet-leostream-poc 10.50.0.0/16"]
        subgraph sn["snet-leostream 10.50.1.0/24 · nsg-leostream"]
            gw["leo-gateway-01<br/>RHEL 9 · public IP<br/>10.50.1.20"]
            broker["leo-broker-01<br/>RHEL 9 · private only<br/>10.50.1.10"]
        end
    end

    gw -->|443| broker
    broker -->|managed identity| arm([Azure Resource Manager])
```

| Component | Resource | OS | Exposure |
|---|---|---|---|
| Connection Broker | `leo-broker-01` | RHEL 9 | Private only, system-assigned managed identity |
| Gateway | `leo-gateway-01` | RHEL 9 | Public IP: TCP/443 for users, TCP/22 for you |

Everything sits in one subnet, `snet-leostream` (`10.50.1.0/24`), protected by one
network security group, `nsg-leostream`, with exactly two inbound rules — 443 and
22, both restricted to `AllowedClientCidrs`. Azure's built-in rules already allow
Gateway-to-Broker traffic inside the VNet and deny everything else from the
internet, so no further rules are needed.

Broker and Gateway are **always separate virtual machines** — the deployment and
validation scripts both enforce this.

**No desktops are deployed.** This PoC covers the Leostream control plane only.
That means the end-to-end user session, Agent registration, pools, policies and
the Broker starting/stopping a desktop VM are not exercised out of the box.

To let the Broker create and power-manage desktop VMs, add an **Azure Center**.
`Configure-LeostreamAzureCenter.ps1` prepares the credentials for you — see
[Azure Center credentials](#azure-center-credentials).

**No Azure Bastion.** You administer over SSH to the Gateway's public IP and hop
to the Broker from there. See [Administrative access](#administrative-access).

Full detail: [docs/architecture.md](docs/architecture.md).

---

## Repository layout

```
leostream-azure-poc/
├── README.md
├── LICENSE
├── .gitignore
├── config/
│   └── poc.config.psd1              # single source of truth, no secrets
├── docs/
│   ├── architecture.md              # design, topology, traffic flows
│   ├── installation.md              # step-by-step deployment guide
│   ├── leostream-configuration.md   # centers, pools, provisioning, policies
│   └── validation.md                # acceptance checks and negative tests
└── scripts/
    ├── Deploy-LeostreamPoC.ps1          # RG, VNet, 1 subnet, 1 NSG, 2 VMs
    ├── Install-LeostreamBroker.ps1      # Platform 26 on leo-broker-01
    ├── Install-LeostreamGateway.ps1     # Gateway on leo-gateway-01
    ├── Configure-LeostreamAzureCenter.ps1  # Entra app + secret + role for a Center
    ├── Test-LeostreamPoC.ps1            # validation
    └── Remove-LeostreamPoC.ps1          # teardown
```

---

## Prerequisites

| Requirement | Minimum |
|---|---|
| PowerShell | Windows PowerShell **5.1** or PowerShell **7.4+** (7.x recommended) |
| Az modules | `Az.Accounts`, `Az.Resources`, `Az.Network`, `Az.Compute` (11.0+) |
| Azure permissions | **Contributor** on the subscription or resource group is enough to deploy. Only the optional Azure Center *role assignment* needs Owner or User Access Administrator, and that step degrades gracefully — see [Azure Center credentials](#azure-center-credentials) |
| Azure quota | ~6 vCPUs of the `Dsv5` family in the target region |
| SSH key pair | For the two RHEL 9 VMs |
| Leostream | An evaluation licence. The installer packages download automatically from the public URLs in `poc.config.psd1` |

```powershell
Install-Module Az -Scope CurrentUser -Repository PSGallery -Force
```

For the SSH key you have two options:

```powershell
# Option A - reuse your existing default key. Nothing else to change;
# poc.config.psd1 already points at ~/.ssh/id_rsa.pub.
Get-ChildItem $HOME\.ssh\id_rsa.pub

# Option B - generate a key dedicated to this PoC...
ssh-keygen -t ed25519 -C "leostream-poc" -f $HOME\.ssh\leostream_poc
# ...and then set this in config/poc.config.psd1 BEFORE deploying:
#   SshPublicKeyPath = '~/.ssh/leostream_poc.pub'
```

Whichever you choose, `Admin.SshPublicKeyPath` in the config must point at the
**public** key (`.pub`), and the matching **private** key is what you pass to
`ssh -i` later. If the two disagree you will deploy one key and authenticate with
another, which fails with `Permission denied (publickey)`.

---

## Quick start

```powershell
git clone https://github.com/mehmetkadriumay/leostream-azure-poc.git
cd leostream-azure-poc

# 1. Edit config/poc.config.psd1 - at minimum set AllowedClientCidrs and SshPublicKeyPath
code config/poc.config.psd1

# 2. Sign in. -Tenant matters if your account is in more than one directory
Connect-AzAccount -Tenant '<tenant-id>'
Set-AzContext -Subscription '<subscription-id>'

cd scripts

# 3. Preview, then deploy the infrastructure (about 5 minutes)
./Deploy-LeostreamPoC.ps1 -WhatIf
./Deploy-LeostreamPoC.ps1 -Verbose

# 4. Install the Leostream software. Versions come from poc.config.psd1;
#    override with -InstallerUri to test a different build.
./Install-LeostreamBroker.ps1
./Install-LeostreamGateway.ps1

# 5. Validate
./Test-LeostreamPoC.ps1

# 6. Optional - credentials for a Leostream Azure Center (pools and desktops)
./Configure-LeostreamAzureCenter.ps1
```

---

## Configuration

Everything is centralised in [`config/poc.config.psd1`](config/poc.config.psd1).

| Key | Default | Change this when |
|---|---|---|
| `Azure.SubscriptionId` | `''` (current context) | Targeting a specific subscription |
| `Azure.Location` | `westeurope` | Different region |
| `Azure.ResourceGroupName` | `rg-leostream-poc` | Naming standards differ |
| `Network.AddressSpace` | `10.50.0.0/16` | Overlaps existing networks |
| `Network.SubnetPrefix` | `10.50.1.0/24` | Address plan differs |
| `AllowedClientCidrs` | `0.0.0.0/0` | **Always** — narrow to your egress IP |
| `VirtualMachines.*.Size` | `D4s_v5` / `D2s_v5` | Cost or performance tuning |
| `Admin.SshPublicKeyPath` | `~/.ssh/id_rsa.pub` | Your key lives elsewhere |
| `Leostream.BrokerInstallerUri` | Platform `26.1.6-1` | Testing a different Broker build |
| `Leostream.GatewayInstallerUri` | Gateway `2026.1.1-2` | Testing a different Gateway build |
| `AzureCenter.AppDisplayName` | `leostream-poc-azure-center` | Naming standards differ |
| `AzureCenter.RoleName` | `Contributor` | A narrower custom role is required |
| `AzureCenter.SecretValidMonths` | `12` | Secret lifetime policy differs |

The deployment script prints a warning if `AllowedClientCidrs` still contains
`0.0.0.0/0`. That default leaves SSH open to the internet — change it.

### What is never stored here

* Linux credentials — password auth is disabled, SSH public key only
* Leostream licence keys and serial numbers — passed as a `SecureString` or
  entered in the Broker UI
* Leostream RPMs — never committed; downloaded at run time from the public
  URLs in `poc.config.psd1`, which are version pointers, not credentials
* Azure credentials and service-principal secrets — the Broker ships with a
  system-assigned managed identity, and the optional Azure Center secret created
  by `Configure-LeostreamAzureCenter.ps1` is printed once and never persisted

---

## Deployment

### 1. Infrastructure — `Deploy-LeostreamPoC.ps1`

Creates, idempotently:

1. Resource group `rg-leostream-poc` with PoC tags
2. One NSG, `nsg-leostream`, allowing inbound 443 and 22 from `AllowedClientCidrs`
3. VNet `vnet-leostream-poc` with one subnet, `snet-leostream`
4. `leo-broker-01` (private, managed identity) and `leo-gateway-01` (public IP)

```powershell
./Deploy-LeostreamPoC.ps1 -WhatIf     # preview
./Deploy-LeostreamPoC.ps1 -Verbose
```

Re-running skips anything that already exists. It finishes by printing the
Gateway's public IP and the exact SSH commands for administration.

### 2–3. Software installation

The installers run through the **Azure RunCommand extension**, so the Broker
never needs inbound connectivity from the internet.

| Script | Does |
|---|---|
| `Install-LeostreamBroker.ps1` | Updates RHEL 9, installs prerequisites, opens 443/tcp, sets hostname, enables EPEL, installs Platform 26, optionally applies a licence key |
| `Install-LeostreamGateway.ps1` | Configures firewalld (443 and 22 open, with `nsg-leostream` restricting the source), applies gateway kernel settings, enables EPEL, installs the Gateway, records the Broker address |

Both default to the URLs in `Leostream.*InstallerUri`. Pass `-InstallerUri` to
pin a different build:

```powershell
./Install-LeostreamBroker.ps1 -InstallerUri 'https://downloads.leostream.com/leostream-broker-26.1.6-1.x86_64.rpm'
```

A `.rpm` and a shell installer are both accepted — the script inspects the
downloaded file and either runs it or hands it to `dnf`.

**Why EPEL.** The Leostream packages depend on software Red Hat does not ship
in the Azure RHUI repositories — the Gateway alone needs `libguac`, `openvpn`,
`certbot`, `mod_perl` and `libvncserver`. Both scripts enable EPEL first, which
resolves every dependency. CodeReady Builder is already enabled on the Azure
RHEL 9 image.

Full walkthrough: [docs/installation.md](docs/installation.md).

---

## Administrative access

There is no Bastion and no jump host. The Gateway's public IP is the single way
in, and it only accepts connections from `AllowedClientCidrs`.

### Where to run these commands

**Run everything in this section on your own Windows PC, in PowerShell.** Not in
the Azure portal's Cloud Shell, and not inside either VM.

| Command type | Where it runs | Prompt looks like |
|---|---|---|
| `.ps1` scripts, `Get-Az*`, and every `ssh` command below | Your Windows PC, PowerShell | `PS C:\Users\you\leostream-azure-poc>` |
| `systemctl`, `firewall-cmd`, `dnf` | Inside a VM, after you have SSH'd in | `[leoadmin@leo-gateway-01 ~]$` |

This matters more than it sounds. `-J` and `-L` are instructions to *your local*
SSH client about how to route a connection out of your machine, so they only make
sense there. Your private key also only exists on your PC and should never be
copied to a VM.

Two symptoms that mean you are in the wrong shell:

| Error | What happened |
|---|---|
| `Identity file /home/leoadmin.sshleostream_poc not accessible` | You ran it inside a VM. Bash expanded `$HOME` to the Linux home directory and silently ate the `\` characters in the Windows path. Type `exit` to get back to PowerShell. |
| `ssh: Could not resolve hostname $gw` | You ran it in a bash shell, where PowerShell variables do not exist. |

### Prerequisites on your PC

* **OpenSSH client** — built into Windows 10 1803+ and Windows 11. Check with
  `ssh -V`; you need 7.3 or newer for `-J`. Windows 11 ships 9.x.
* **The private key whose public half you deployed.** This is whatever
  `Admin.SshPublicKeyPath` pointed at when you ran `Deploy-LeostreamPoC.ps1`,
  minus the `.pub` suffix. With the shipped default that is
  `C:\Users\<you>\.ssh\id_rsa`. Step 1 below works it out for you.
* **Your current public IP inside `AllowedClientCidrs`.** If your ISP changed it,
  update the config and re-run `Deploy-LeostreamPoC.ps1` to refresh the NSG.

### Step 1 — set up your variables

Do not hard-code or retype the Gateway address or the key path. Derive both from
the config and from Azure, so they cannot drift apart. Run this from the
repository root:

```powershell
cd C:\path\to\leostream-azure-poc

$cfg  = Import-PowerShellDataFile ./config/poc.config.psd1
$rg   = $cfg.Azure.ResourceGroupName
$user = $cfg.Admin.LinuxUsername

# private key = the configured public key, minus the .pub suffix
$key = ($cfg.Admin.SshPublicKeyPath -replace '^~', $HOME -replace '\.pub$','')
$gw  = (Get-AzPublicIpAddress -ResourceGroupName $rg `
          -Name $cfg.VirtualMachines.Gateway.PublicIpName).IpAddress

# ALWAYS check these before using them
$gw                       # must print an IP address
Test-Path $key            # must print True
```

Both checks matter:

* **`$gw` blank** — the public IP does not exist yet, or you are signed in to the
  wrong subscription. Stop and fix it. An unset variable in PowerShell expands to
  an empty string rather than raising an error, which surfaces later as a
  baffling `Invalid -J argument`.
* **`Test-Path $key` is False** — you are about to pass `ssh -i` a file that does
  not exist, and you will get `Identity file ... not accessible`. The usual cause
  is generating a key under one name while `Admin.SshPublicKeyPath` still points
  at another. The config default is `~/.ssh/id_rsa.pub`, so unless you changed
  it, the private key is `~/.ssh/id_rsa` — **not** `leostream_poc`.

PowerShell variables are **per window**. Open a new terminal and they are all
empty again, so re-run this block each time.

### Step 2 — open a shell on the Gateway

```powershell
ssh -i $key $user@$gw
```

Expect a host-key prompt on first connection; type `yes`. You should land at
`[leoadmin@leo-gateway-01 ~]$` with no password prompt. Type `exit` to return.

If you are using your default key (`~/.ssh/id_rsa`), `-i $key` is optional —
OpenSSH tries that key automatically. It is kept in these examples so they work
whichever key you configured.

Get this working before trying anything below — the other two commands both
depend on it.

### Step 3 — open a shell on the Broker

The Broker has no public IP, so SSH hops through the Gateway. Run this **on your
PC**, not on the Gateway:

```powershell
ssh -i $key -o "ProxyCommand=ssh -i `"$key`" -W %h:%p $user@$gw" $user@10.50.1.10
```

You should land at `[leoadmin@leo-broker-01 ~]$`. Your key is used twice, for
both hops, and is never copied to the Gateway.

> **Do not SSH to the Gateway first and then run `ssh leoadmin@10.50.1.10` from
> its shell.** That is the natural thing to try, and it always fails with
> `Permission denied (publickey,gssapi-keyex,gssapi-with-mic)` followed by
> `Connection closed by UNKNOWN port 65535`.
>
> The reason is that there is no private key on the Gateway, and there should
> not be. The deployment installs only your **public** key, into
> `/home/leoadmin/.ssh/authorized_keys` on each VM. Both VMs get the same public
> key, so the Gateway can *prove nothing* to the Broker — it has no private half
> to authenticate with. You can confirm this on the Gateway:
>
> ```bash
> ls -la ~/.ssh/          # authorized_keys only; no id_* and no leostream_poc
> ```
>
> The `ProxyCommand` above exists precisely to avoid this. The Gateway merely
> forwards the raw TCP stream (`-W`); the key stays on your PC and your PC
> authenticates directly to the Broker through that tunnel.
>
> Copying your private key onto the Gateway would "fix" it, but don't: the
> Gateway is the one internet-facing machine here, and a private key there is a
> single compromise away from granting access to everything else. If you really
> want to hop from inside the Gateway, use agent forwarding (`ssh -A`) instead,
> which keeps the key on your PC — this needs the `ssh-agent` service running
> and your key added with `ssh-add`.

> **Why not the shorter `ssh -i $key -J $user@$gw $user@10.50.1.10`?**
> Because `-i` applies only to the **final** connection. The jump host is a
> separate SSH process that does not inherit it, so it falls back to the default
> key names (`id_rsa`, `id_ed25519`). If your key is called anything else, the
> jump fails with `Permission denied (publickey...)` — confusingly pointing at
> the *Gateway* address even though your key is fine. Specifying
> `-o IdentityFile=` instead does not help; it has the same scope. `-J` is only
> safe when your key has a default name or is loaded into `ssh-agent`.

#### Easier: name the hosts once

Rather than retyping the above, add this to `~\.ssh\config` (create the file if
it does not exist, no extension). Set `IdentityFile` to your key and `HostName`
to the Gateway's current public IP:

```sshconfig
Host leo-gateway
    HostName 20.0.0.1
    User leoadmin
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes

Host leo-broker
    HostName 10.50.1.10
    User leoadmin
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
    ProxyJump leo-gateway
```

Then both hosts are reachable by name, from any directory, with no variables:

```powershell
ssh leo-gateway
ssh leo-broker
ssh -L 8443:10.50.1.10:443 leo-gateway    # the web UI tunnel
```

`ProxyJump` works correctly here because the config supplies `IdentityFile` to
each host in its own right. Remember to update `HostName` if you redeploy and
the Gateway's public IP changes.

### Step 4 — reach the Broker web UI

The Broker's console is on port 443 of a private address, so forward a local port
through the Gateway with `-L`:

```powershell
ssh -i $key -L 8443:10.50.1.10:443 $user@$gw
```

**Leave that window open** — closing it closes the tunnel. In a browser on the
same PC, go to:

```
https://localhost:8443/
```

Accept the self-signed certificate warning. `-L 8443:10.50.1.10:443` reads as:
listen on port 8443 on this PC, and forward anything arriving there to
`10.50.1.10:443` as seen from the Gateway. Use a different local port if 8443 is
already taken.

### If something fails

| Symptom | Cause | Fix |
|---|---|---|
| `Invalid -J argument` | `$gw` is empty | Re-run step 1 and confirm `$gw` prints an IP |
| `Identity file ... not accessible: No such file or directory` | The key named in `-i` does not exist. Usually you generated `leostream_poc` but left `Admin.SshPublicKeyPath` at the default `~/.ssh/id_rsa.pub`, or the reverse | `Get-ChildItem $HOME\.ssh` to see what you actually have, then make the config and the `-i` path agree. Step 1 derives `$key` correctly |
| Connection hangs, then times out | Your IP is not in `AllowedClientCidrs` | Check with `(Invoke-RestMethod https://api.ipify.org?format=json).ip`, add it to the config, re-run `Deploy-LeostreamPoC.ps1` |
| `Permission denied (publickey)` | You are offering a different key from the one deployed, or the wrong username | Compare them — see *Checking which key is actually deployed* below |
| `Permission denied (publickey)` naming the **Gateway** even though step 2 works | You used `-J`, and `-i` does not reach the jump host | Use the `ProxyCommand` form or the `~\.ssh\config` entry in step 3 |
| `Permission denied (publickey,gssapi-keyex,gssapi-with-mic)` then `Connection closed by UNKNOWN port 65535`, when run **from the Gateway's shell** | There is no private key on the Gateway, by design — only your public key in `authorized_keys`. The Gateway cannot authenticate to the Broker on your behalf | Don't hop from inside the Gateway. Run the step 3 `ProxyCommand` from your PC instead. See the callout in step 3 |
| You went looking for your key in `/home/leoadmin/.ssh` on a VM and it isn't there | Correct and expected. Private keys never leave your PC; VMs hold only `authorized_keys` | Nothing to fix — use step 3 from your PC |
| Key works on one VM but not the other | The VMs were deployed at different times, or from different clones of this repo, with different `SshPublicKeyPath` values | Compare both VMs with the snippet below. Changing the config does **not** re-key an existing VM |
| `Identity file ... not accessible` with a mangled path like `/home/leoadmin.sshleostream_poc` | Running in bash inside a VM, not PowerShell. Bash expanded `$HOME` to the Linux home and ate the `\` characters | `exit` back to PowerShell |
| Step 2 works but step 3 hangs | Broker VM is stopped or still booting | `Get-AzVM -ResourceGroupName $rg -Name leo-broker-01 -Status` |
| Browser shows `ERR_CONNECTION_REFUSED` on localhost:8443 | Tunnel window closed, or the Broker software is not installed yet | Reopen the tunnel; check `systemctl status leostream` on the Broker |
| `WARNING: UNPROTECTED PRIVATE KEY FILE` | Key file permissions too open | `icacls $key /inheritance:r /grant:r "$($env:USERNAME):(R)"` |

### Checking which key is actually deployed

The public key is written into the VM **when it is created**. Editing
`Admin.SshPublicKeyPath` afterwards changes nothing on a VM that already
exists, and `Deploy-LeostreamPoC.ps1` skips VMs it finds — so a redeploy will
not re-key them either. If you have more than one clone of this repo, each with
its own config, it is easy to end up with VMs that expect different keys.

This compares every VM against every key you hold and tells you which to use:

```powershell
$rg = (Import-PowerShellDataFile ./config/poc.config.psd1).Azure.ResourceGroupName

foreach ($vm in Get-AzVM -ResourceGroupName $rg) {
    $deployed = @($vm.OSProfile.LinuxConfiguration.Ssh.PublicKeys)[0].KeyData.Trim()
    $match = Get-ChildItem $HOME\.ssh -Filter *.pub |
        Where-Object { (Get-Content $_.FullName -Raw).Trim() -eq $deployed } |
        Select-Object -First 1

    $useKey = 'NO LOCAL MATCH'
    if ($match) { $useKey = $match.FullName -replace '\.pub$', '' }

    [pscustomobject]@{
        VM     = $vm.Name
        User   = $vm.OSProfile.AdminUsername
        UseKey = $useKey
    }
}
```

If a VM reports `NO LOCAL MATCH`, you do not hold its private key. Either find
the key it was built with, or delete and redeploy that VM.

If you would rather not open port 22 at all, delete the `Allow-SSH-Inbound` rule
and drive both VMs with `Invoke-AzVMRunCommand`, which reaches them through the
Azure control plane and needs no inbound access:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName leo-broker-01 `
    -CommandId RunShellScript -ScriptString 'systemctl status leostream --no-pager'
```

You then lose the Broker web UI, which you need for the initial Leostream setup,
so this suits an already-configured deployment rather than a fresh one.

---

## Leostream configuration

Open the Broker UI through the SSH tunnel above, then:

1. Sign in as `admin` / `leo` and **change the password immediately**.
2. *System > License* — apply your evaluation licence.
3. *Setup > Gateways* — register `leo-gateway-01` (public address for clients,
   `10.50.1.20` privately).
4. *Configuration > Protocol Plans* — RDP via the Gateway.

Steps 1–4 are all this PoC exercises.

Going further — an Azure center, desktop images, pools, provisioning, plans,
policies and user assignment — is covered field by field in
[docs/leostream-configuration.md](docs/leostream-configuration.md), which
follows Leostream's Azure quick-start guide and notes where this PoC's network
layout changes the answer.

> **Entra ID is not an Active Directory authentication server.** *Setup >
> Authentication Servers* speaks LDAP; Entra ID is a SAML identity provider to
> Leostream and is configured separately. Pointing the Active Directory form at
> Entra ID fails with bind errors.

---

## Azure Center credentials

A Leostream **Center** (*Setup > Centers*) is what lets the Broker see, create,
start and stop Azure VMs. The base PoC deploys no desktops, so it configures no
Center — but the moment you want pools and real desktops, you need one.

Leostream accepts two authentication models, and the difference is entirely
about *who has to approve what*:

| Model | What it needs | Who can do it |
|---|---|---|
| Managed identity | A role assignment on the Broker VM's identity | **Owner** or **User Access Administrator** only |
| Entra ID application | Tenant ID, application (client) ID, client secret — plus one role assignment for the service principal | Any user can create the app and secret; only the role assignment is elevated |

The managed-identity route looks cleaner but fails early and hard on most
corporate subscriptions: a Contributor cannot create role assignments, so the
whole thing stops with `AuthorizationFailed` and no partial progress.

The application route splits that wall in two. Creating an app registration, its
service principal and a client secret is a **Microsoft Entra** operation and
needs no Azure RBAC at all — it works for an ordinary user in a default tenant.
Only the last step, granting the service principal a role, needs elevated
rights, and that is a single command you can hand to an administrator.

```powershell
./Configure-LeostreamAzureCenter.ps1
```

The script, idempotently:

1. Creates (or reuses) the Entra application `leostream-poc-azure-center`.
2. Creates (or reuses) its service principal.
3. Issues a client secret valid for `AzureCenter.SecretValidMonths` months.
4. Assigns `AzureCenter.RoleName` (`Contributor`) on `rg-leostream-poc`,
   retrying while Entra replicates the new principal.
5. Prints the four values the Azure Center dialog asks for.

**If step 4 fails with `AuthorizationFailed`, nothing is lost.** The app, the
service principal and the secret are already created; the script prints the
exact command for an administrator and carries on:

```powershell
New-AzRoleAssignment -ObjectId <sp-object-id> -RoleDefinitionName 'Contributor' `
    -Scope '/subscriptions/<sub-id>/resourceGroups/rg-leostream-poc'
```

You can also skip the attempt entirely and collect the command up front:

```powershell
./Configure-LeostreamAzureCenter.ps1 -SkipRoleAssignment
```

If your tenant blocks self-service app registration (`Authorization_RequestDenied`),
ask an administrator to create a bare app registration — no API permissions, no
redirect URI — and point the script at it:

```powershell
./Configure-LeostreamAzureCenter.ps1 -ApplicationId <client-id>
```

Other options:

| Option | Effect |
|---|---|
| `-RotateSecret` | Issue a fresh secret on an existing application. The only way back if you lose the printed one |
| `-Scope Subscription` | Grant the role subscription-wide instead of on the resource group |
| `-RoleDefinitionName` | Use a narrower role than `Contributor` |
| `-SecretValidMonths` | Secret lifetime, 1–24 months |
| `-WhatIf` | Preview without touching the directory |

> **The client secret is printed once and never written to disk.** It is not
> stored in `poc.config.psd1`, not logged, and cannot be read back from Azure.
> Put it straight into the Broker UI or Key Vault; if you lose it, re-run with
> `-RotateSecret`.

Then, in the Broker UI: *Setup > Centers > Add Center > Microsoft Azure*, set
*Authentication* to **Application Key**, pick the region matching
`Azure.Location`, and enter subscription ID, tenant ID, application ID and the
secret. The full form — and what to do next with pools, provisioning, plans and
policies — is in
[docs/leostream-configuration.md](docs/leostream-configuration.md).

A center only ever sees one region, and can only provision into resource groups
that exist in that region. `rg-leostream-poc` is created in `Azure.Location`, so
keep the two in step.

The Broker reaches the Azure API directly through `natgw-leostream` and needs
outbound 443 to `login.microsoftonline.com`, `management.azure.com` and
`*.blob.core.windows.net`. These resolve to different addresses on every call,
so an IP allow-list will not hold. `./Test-LeostreamPoC.ps1` probes this from
inside the Broker. Where that egress is genuinely impossible, the Leostream
Gateway can forward the Azure API instead — *Use a Leostream Gateway to
communicate with this Center*.

The Broker's system-assigned managed identity is still deployed and verified, so
you can switch to the managed-identity model later if someone grants it a role.

---

## Validation

```powershell
./Test-LeostreamPoC.ps1                    # full validation
./Test-LeostreamPoC.ps1 -SkipRemoteChecks  # Azure control plane only
```

Checks the resource group, VNet and subnet prefix, NSG attachment and both
inbound rules, that Broker and Gateway are separate VMs, that both are running,
that only the Gateway is internet-facing, that the Broker has a managed
identity, and that the Gateway responds on 443 and 22 while the Broker responds
on 443 from inside the VNet. Exits `1` on any failure.

If `Configure-LeostreamAzureCenter.ps1` has been run, it also reports the Entra
application, its service principal, whether a client secret is still valid and
whether the role assignment landed. A missing application is reported as `Skip`
(the Center is optional) and a missing role assignment as `Warn` — that is the
state where the Center authenticates but sees no VMs.

Manual end-to-end and negative tests: [docs/validation.md](docs/validation.md).

---

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Target subscription missing after sign-in, or `Set-AzContext` cannot find it | You authenticated against your home tenant, but the subscription lives in another | `Get-AzSubscription \| Format-Table Name, Id, TenantId`, then re-run `Connect-AzAccount -Tenant '<that-id>'` |
| `SSH public key not found at ...` | `Admin.SshPublicKeyPath` is wrong | Generate a key or correct the path in `poc.config.psd1` |
| `New-AzVM: ... SkuNotAvailable` | VM size unavailable in the region | Change `VirtualMachines.*.Size` or `Azure.Location` |
| `OperationNotAllowed ... quota` | Insufficient vCPU quota | Request a quota increase or use smaller sizes |
| `Invoke-AzVMRunCommand` times out | VM agent not ready | Wait a few minutes after VM creation and retry |
| Installer download fails inside the VM | The pinned version was withdrawn, or a custom URL expired or needs auth | Check `Leostream.*InstallerUri` resolves with `Invoke-WebRequest -Method Head`, then pass a current URL via `-InstallerUri` |
| `No match for argument: ./leostream-...` | dnf only accepts a local package whose name ends in `.rpm` | Fixed — the scripts keep the upstream file name. Only occurs with a URL that has no file component |
| `nothing provides libguac` / `openvpn` / `mod_perl` | EPEL is not enabled, so the Leostream dependencies cannot resolve | The install scripts enable EPEL automatically; if you installed by hand, run `dnf -y install epel-release` first |
| SSH to the Gateway hangs | Your IP is not in `AllowedClientCidrs` | Add it, then re-run `Deploy-LeostreamPoC.ps1` to update the NSG |
| Gateway page unreachable from your browser | Same cause as above, or the Gateway software is not installed yet | Fix the CIDR, then check `systemctl status leostream-gateway` |
| Cannot SSH to the Broker directly | Working as designed — it has no public IP | Use `ssh -J` through the Gateway |
| Certificate warning on the Gateway | Self-signed certificate | Install a trusted certificate before any real use |
| No desktops offered to any user | Working as designed — this PoC deploys none | Add a VM to the subnet and install the Leostream Agent |
| Broker cannot see Azure VMs | No Azure Center is configured, or its service principal has no role assignment | Run `./Configure-LeostreamAzureCenter.ps1`, then check the `AzureCenter` rows in `./Test-LeostreamPoC.ps1` |
| `AuthorizationFailed` creating the role assignment | Contributor cannot grant access; that needs Owner or User Access Administrator | The app and secret were still created. Send the printed `New-AzRoleAssignment` command to an administrator |
| `Authorization_RequestDenied` creating the application | The tenant blocks self-service app registration | Have an administrator create a bare app registration, then `./Configure-LeostreamAzureCenter.ps1 -ApplicationId <client-id>` |
| `PrincipalNotFound` on the role assignment | Entra has not replicated the brand-new service principal | The script already retries six times over a minute; just re-run it |
| Azure Center stops working after some months | The client secret expired | `./Configure-LeostreamAzureCenter.ps1 -RotateSecret`, then update the Center |
| Lost the printed client secret | Azure shows a secret only once, by design | `./Configure-LeostreamAzureCenter.ps1 -RotateSecret` |

Useful diagnostics:

```powershell
$rg = (Import-PowerShellDataFile ./config/poc.config.psd1).Azure.ResourceGroupName

# Gateway service and firewall
Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName leo-gateway-01 `
    -CommandId RunShellScript -ScriptString 'systemctl status leostream-gateway --no-pager; firewall-cmd --list-all'

# Broker service
Invoke-AzVMRunCommand -ResourceGroupName $rg -VMName leo-broker-01 `
    -CommandId RunShellScript -ScriptString 'systemctl status leostream --no-pager; ss -lntp | grep :443'

# Effective NSG rules
Get-AzEffectiveNetworkSecurityGroup -ResourceGroupName $rg -NetworkInterfaceName nic-leo-gateway-01
```

---

## Teardown

```powershell
./Remove-LeostreamPoC.ps1                        # delete the resources, keep the RG (default)
./Remove-LeostreamPoC.ps1 -RemoveResourceGroup   # also delete the resource group
./Remove-LeostreamPoC.ps1 -RemoveAzureCenterApp  # also delete the Entra application
./Remove-LeostreamPoC.ps1 -Force                 # no prompt (use carefully)
```

**The resource group is kept by default, on purpose.** Everything billable — the
VMs, disks, public IPs and the NAT gateway — is deleted, so an empty resource
group costs nothing. What it preserves is the Azure Center's role assignment,
which is scoped to the group and is the one step that usually needs an Owner or
User Access Administrator. Delete the group and that assignment goes with it;
recreating a group with the same name does **not** bring it back.

So the repeatable cycle is:

```powershell
./Remove-LeostreamPoC.ps1     # tear down
./Deploy-LeostreamPoC.ps1     # redeploy into the same resource group
```

`Deploy-LeostreamPoC.ps1` reuses an existing resource group rather than
recreating it, and reports at the end whether the Azure Center application and
its role assignment are still in place. If they are, reuse the same client
secret in the Broker — there is nothing to re-request.

Use `-RemoveResourceGroup` only when you are finished for good. Before deleting,
the script lists any role assignments scoped to the group that are about to be
destroyed, so you get a last chance to reconsider.

The script refuses to touch a resource group that is not tagged
`project=leostream-poc` unless `-Force` is given.

Role assignments held by the Broker's **managed identity** are always removed.
That identity is deleted along with its VM, so the assignments would be left
orphaned either way — nothing is lost that could have been kept.

The Azure Center application is a **directory** object, not an Azure resource,
so no form of this teardown removes it unless you ask. `-RemoveAzureCenterApp`
strips its role assignments and deletes the application, taking the service
principal and the secret with it. That is the other half of what you would need
an administrator for, so leave it alone if you intend to redeploy.

Release your Leostream licence seats afterwards.

---

## Cost

Rough guide for `westeurope`, pay-as-you-go, running continuously:

| Resource | Approximate monthly cost |
|---|---|
| `leo-broker-01` (D4s_v5) | high |
| `leo-gateway-01` (D2s_v5) | medium |
| NAT gateway (hourly + data processed) | low–medium, around USD 32 |
| Managed disks, two public IPs | low |

Two VMs, a NAT gateway and two public IPs are the entire bill — there is no
Bastion host and no desktop, which are the two largest line items in a typical
Leostream PoC.

The NAT gateway exists because the Broker has no public IP and Azure
[retired default outbound access](https://learn.microsoft.com/azure/virtual-network/ip-services/default-outbound-access)
on 30 September 2025. Without it the Broker cannot reach the RHEL, EPEL or
Leostream download endpoints and `Install-LeostreamBroker.ps1` fails with
repository timeouts. It is outbound-only, so the Broker stays unreachable from
the internet. If you have another outbound path, such as a firewall or a
pre-existing NAT gateway on the subnet, set `Network.NatGatewayEnabled = $false`.

Keep it cheaper still by using `Standard_D2s_v5` for both VMs, deallocating them
when idle, and running `Remove-LeostreamPoC.ps1` as soon as the evaluation is
finished. Always confirm current prices with the
[Azure pricing calculator](https://azure.microsoft.com/pricing/calculator/).

---

## Security notes

This is a **proof of concept**, and a deliberately minimal one. Before anything
resembling production use:

* Narrow `AllowedClientCidrs` — never leave `0.0.0.0/0`, which exposes SSH to the
  internet.
* Replace the public SSH path with Azure Bastion or a VPN, and split the Gateway
  and Broker back into separate subnets with their own NSGs.
* Install a trusted TLS certificate on the Gateway.
* Change the default Broker credentials immediately and enable MFA.
* Add diagnostic settings, Microsoft Defender for Cloud and Azure Monitor.
* Replace the single Broker and Gateway with an HA pair behind a load balancer.
* Store any operational secrets in Azure Key Vault.
* Review the role granted to the Broker identity and reduce it to the minimum
  your Leostream features actually require.
* For the Azure Center, prefer a short secret lifetime and a custom role over
  `Contributor` scoped to the resource group — Leostream only needs to read,
  create, start, stop and delete VMs there. Rotate with `-RotateSecret` on a
  schedule, and delete the application with
  `Remove-LeostreamPoC.ps1 -RemoveAzureCenterApp` when the PoC ends.

---

## Licence

[MIT](LICENSE). Leostream Platform, Leostream Gateway and Leostream Agent are
products of Leostream Corporation and are licensed separately; this repository
contains none of their software, licence keys or serial numbers.
