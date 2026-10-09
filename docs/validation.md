# Validation

## Automated checks

```powershell
./Test-LeostreamPoC.ps1                    # everything
./Test-LeostreamPoC.ps1 -SkipRemoteChecks  # Azure control plane only, no RunCommand
```

The script is read-only. It prints one line per check and exits `1` if any check
fails.

| Area | Check | Pass means |
|---|---|---|
| Infrastructure | Resource group exists | `rg-leostream-poc` is present |
| Network | Virtual network exists | `vnet-leostream-poc` with the configured address space |
| Network | Subnet `snet-leostream` | Present with prefix `10.50.1.0/24` |
| Network | NSG attached to the subnet | `nsg-leostream` is bound, not dangling |
| Security | Inbound TCP/443 allowed | A rule permits user traffic to the Gateway |
| Security | Inbound TCP/22 allowed | Your administrative path exists |
| Architecture | Broker and Gateway are separate VMs | The core requirement holds |
| Compute | `leo-broker-01` running | Power state is `VM running` |
| Compute | `leo-gateway-01` running | Power state is `VM running` |
| Security | `leo-broker-01` is private only | No public IP on its NIC |
| Security | `leo-gateway-01` has the expected public IP | Exactly one, as designed |
| Identity | Broker managed identity | System-assigned identity with a principal ID |
| Network | Gateway public IP assigned | The static IP is allocated |
| Service | Gateway TCP/443 reachable | Your machine can open 443 |
| Service | Gateway TCP/22 reachable | Your machine can open 22 |
| Service | Broker HTTPS reachable from Gateway | RunCommand on the Gateway opens 443 on `10.50.1.10` |

### Interpreting non-pass results

* **Warn on TCP/443 or TCP/22** — either your IP is outside `AllowedClientCidrs`,
  or the Leostream software is not installed yet. Check the CIDR first.
* **Warn on Broker HTTPS from Gateway** — the Broker VM is up but the Leostream
  service is not listening. Re-run `Install-LeostreamBroker.ps1` or check
  `systemctl status leostream`.
* **Skip on the in-VNet check** — RunCommand could not run, usually because the
  guest agent is still starting. Wait and retry.

## Manual checks

The script cannot verify these. Do them once by hand.

### 1. Administrative access works

Run these on your own Windows PC in PowerShell, from the repository root — not
inside either VM. See
[Administrative access](../README.md#administrative-access) if anything fails.

```powershell
$cfg  = Import-PowerShellDataFile ./config/poc.config.psd1
$rg   = $cfg.Azure.ResourceGroupName
$user = $cfg.Admin.LinuxUsername
$key  = ($cfg.Admin.SshPublicKeyPath -replace '^~', $HOME -replace '\.pub$','')
$gw   = (Get-AzPublicIpAddress -ResourceGroupName $rg `
           -Name $cfg.VirtualMachines.Gateway.PublicIpName).IpAddress

$gw                # must print an IP address
Test-Path $key     # must print True

ssh -i $key $user@$gw                            # Gateway
ssh -i $key -J $user@$gw $user@10.50.1.10        # Broker
```

Both should land you at a shell prompt without a password — `[leoadmin@leo-gateway-01 ~]$`
and `[leoadmin@leo-broker-01 ~]$` respectively. `exit` returns to PowerShell.

### 2. Broker UI is reachable and only through the tunnel

```powershell
ssh -i $key -L 8443:10.50.1.10:443 $user@$gw
# leave this window open, then browse to https://localhost:8443/
```

The Leostream sign-in page should load. The default `admin` / `leo` credentials
must already have been changed.

### 3. The Gateway is registered

*Setup > Gateways* should show `leo-gateway-01` as reachable.

## Negative tests

Worth running to prove the security posture is real, not assumed.

### The Broker is not reachable from the internet

```powershell
Test-NetConnection -ComputerName $gw -Port 443   # expect success
```

There is no public address to test against for the Broker — confirm with:

```powershell
$rg = (Import-PowerShellDataFile ../config/poc.config.psd1).Azure.ResourceGroupName
(Get-AzNetworkInterface -ResourceGroupName $rg -Name nic-leo-broker-01).IpConfigurations.PublicIpAddress
```

Expected output: nothing. A public IP here is a failure.

### Traffic from outside `AllowedClientCidrs` is dropped

Temporarily set `AllowedClientCidrs` to a CIDR that is not yours, re-run
`Deploy-LeostreamPoC.ps1`, and confirm that both SSH and HTTPS now time out.
Restore your own CIDR afterwards.

```powershell
$rg = (Import-PowerShellDataFile ../config/poc.config.psd1).Azure.ResourceGroupName
Get-AzEffectiveNetworkSecurityGroup -ResourceGroupName $rg -NetworkInterfaceName nic-leo-gateway-01 |
    Select-Object -ExpandProperty EffectiveSecurityRules |
    Where-Object { $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' } |
    Format-Table Name, Protocol, SourceAddressPrefix, DestinationPortRange
```

### No secrets on disk

```powershell
git grep -nEi "password|secret|licen[cs]e key|serial" -- config scripts
```

Every hit should be a parameter name, a prompt, or a comment — never a value.

## What this PoC does not validate

No desktops are deployed, so none of the following can be tested without adding
one yourself:

* an end-to-end user session from a client, through the Gateway, to a desktop
* Leostream Agent registration and check-in
* pools, policies and assignment logic
* the Broker starting or stopping a desktop VM through its managed identity
* the Azure center discovering VMs

The last two are not covered at all. The managed identity exists and is
verified, but it holds no role assignment and no Azure center is configured,
because this PoC deploys no desktops for either to act on.

## Record your results

| Check | Date | Result | Notes |
|---|---|---|---|
| `Test-LeostreamPoC.ps1` all pass | | | |
| SSH to Gateway and Broker | | | |
| Broker UI through the tunnel | | | |
| Gateway registered in the Broker | | | |
| Broker has no public IP | | | |
| Out-of-CIDR traffic dropped | | | |
| No secrets committed | | | |
