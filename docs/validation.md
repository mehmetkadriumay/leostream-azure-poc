# Validation guide

How to prove that the proof of concept is correct, secure and usable.

## 1. Automated checks

```powershell
cd scripts
./Test-LeostreamPoC.ps1
```

Control-plane checks only (no RunCommand calls, much faster):

```powershell
./Test-LeostreamPoC.ps1 -SkipRemoteChecks
```

The script exits with code `1` if any check reports **Fail**.

### What is checked

| Area | Check | Fails when |
|---|---|---|
| Infrastructure | Resource group exists | `rg-leostream-poc` is missing |
| Network | VNet exists with `10.50.0.0/16` | VNet missing |
| Network | Each of the four subnets exists with the expected prefix | Prefix drift or missing subnet |
| Network | NSG attached to gateway, infrastructure and desktop subnets | Any subnet unprotected |
| Network | Gateway public IP assigned | No public IP on `leo-gateway-01` |
| Security | Gateway NSG allows inbound 443 | Rule missing |
| Security | `leo-broker-01` has no public IP | Public IP attached |
| Security | `leo-gateway-01` has the expected public IP | Public IP missing |
| Architecture | Broker and Gateway are separate VMs | Names identical |
| Compute | Both VMs exist and are running | VM missing (fail) or stopped (warn) |
| Identity | Broker has a system-assigned managed identity | Identity missing |
| Identity | That identity holds at least one role assignment | RBAC step not run |
| Infrastructure | Azure Bastion deployed when enabled | Warn only |
| Service | Gateway TCP/443 reachable from your machine | Warn only |
| Service | Broker TCP/443 reachable from the Gateway | Warn only |
| Desktops | Any VM you added to `snet-desktop` has no public IP | A desktop is internet-facing (skipped when the subnet is empty) |

Service checks are warnings rather than failures because the infrastructure can
legitimately be validated before the Leostream software is installed.

## 2. Manual infrastructure spot checks

Confirm the Broker really has no public IP:

```powershell
Get-AzNetworkInterface -ResourceGroupName rg-leostream-poc -Name nic-leo-broker-01 |
    Select-Object -ExpandProperty IpConfigurations |
    Select-Object Name, PrivateIpAddress, PublicIpAddress
```

List effective NSG rules on the gateway subnet:

```powershell
(Get-AzNetworkSecurityGroup -ResourceGroupName rg-leostream-poc -Name nsg-gateway).SecurityRules |
    Sort-Object Priority |
    Format-Table Priority, Name, Direction, Access, Protocol, DestinationPortRange
```

Confirm the Broker's managed identity and its role:

```powershell
$vm = Get-AzVM -ResourceGroupName rg-leostream-poc -Name leo-broker-01
$vm.Identity | Format-List Type, PrincipalId, TenantId
Get-AzRoleAssignment -ObjectId $vm.Identity.PrincipalId |
    Format-Table RoleDefinitionName, Scope
```

Confirm only the Gateway is internet-facing:

```powershell
Get-AzPublicIpAddress -ResourceGroupName rg-leostream-poc |
    Format-Table Name, IpAddress, @{n='AttachedTo';e={ $_.IpConfiguration.Id -replace '.*/networkInterfaces/([^/]+)/.*','$1' }}
```

Expect exactly two: the Gateway IP and the Bastion IP.

## 3. Leostream service checks

From the Gateway, confirm the Broker answers:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName rg-leostream-poc -VMName leo-gateway-01 `
    -CommandId RunShellScript `
    -ScriptString 'curl -sk -o /dev/null -w "%{http_code}\n" https://10.50.2.10/'
```

Expect `200` or `302`.

Check the Gateway service state:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName rg-leostream-poc -VMName leo-gateway-01 `
    -CommandId RunShellScript `
    -ScriptString 'systemctl is-active leostream-gateway; firewall-cmd --list-all'
```

## 4. Gateway and Broker login pages

1. From a client whose public IP is inside `AllowedClientCidrs`, browse to
   `https://<gateway-public-ip>/`.
2. Accept the self-signed certificate warning (expected until you install a
   trusted certificate).
3. Confirm the Leostream login page renders through the Gateway.
4. Sign in — with no desktops deployed, expect an empty resource list. That is
   the correct result for this PoC.

### Negative tests

| Test | Expected result |
|---|---|
| Browse to `https://10.50.2.10/` from the internet | Fails — Broker is private |
| Browse to the Gateway from an IP outside `AllowedClientCidrs` | Connection times out |
| SSH to the Gateway public IP from the internet | Fails — firewalld restricts SSH to `10.50.0.0/16` |
| Any NIC exists in `snet-desktop` | None — no desktops are deployed |

## 5. Azure integration test

Because this PoC deploys no desktops, the managed identity can only be verified
**statically** — that it exists and is correctly scoped, not that the Broker can
actually power a VM.

Confirm the identity and its role assignment:

```powershell
$rg = (Import-PowerShellDataFile ../config/poc.config.psd1).Azure.ResourceGroupName
$vm = Get-AzVM -ResourceGroupName $rg -Name leo-broker-01
$vm.Identity | Format-List Type, PrincipalId, TenantId

Get-AzRoleAssignment -ObjectId $vm.Identity.PrincipalId |
    Format-Table RoleDefinitionName, Scope
```

Expect `Type = SystemAssigned` and a `Virtual Machine Contributor` assignment
scoped to the resource group.

Then, in the Broker, open *Setup > Centers*, select the Azure center and run
**Refresh**. It should authenticate without a secret and return an empty VM
list — authentication succeeding is the thing being tested here.

### Not covered without a desktop

Proving the Broker can start and stop a VM requires a desktop. To test it, add a
Windows VM to `snet-desktop`, register it with
`Install-LeostreamAgent.ps1 -VMName <name>`, then stop it from the Broker and
confirm with:

```powershell
Get-AzVM -ResourceGroupName $rg -Name <your-desktop-name> -Status |
    Select-Object -ExpandProperty Statuses |
    Where-Object Code -like 'PowerState/*'
```

Start it again from the Broker and confirm it returns to `VM running`. If that
works, the managed identity and RBAC configuration are proven end to end and no
service-principal secret is needed anywhere.

## 6. Validation record

| Item | Result | Notes |
|---|---|---|
| `Test-LeostreamPoC.ps1` exits 0 | | |
| Only Gateway and Bastion have public IPs | | |
| Broker managed identity exists and is `SystemAssigned` | | |
| Broker managed identity holds a role assignment at the expected scope | | |
| Broker reachable from the Gateway | | |
| Gateway login page renders from an allowed client IP | | |
| Azure center authenticates from the Broker without a secret | | |
| Negative tests all fail as expected | | |

The following need a desktop and are **out of scope** unless you add one: Agent
registration, pool and policy assignment, an end-to-end user session, and
Broker-driven VM power control.
