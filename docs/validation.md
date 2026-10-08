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
| Security | `leo-win-01` has no public IP | Public IP attached |
| Security | `leo-gateway-01` has the expected public IP | Public IP missing |
| Architecture | Broker and Gateway are separate VMs | Names identical |
| Compute | All three VMs exist and are running | VM missing (fail) or stopped (warn) |
| Identity | Broker has a system-assigned managed identity | Identity missing |
| Identity | That identity holds at least one role assignment | RBAC step not run |
| Infrastructure | Azure Bastion deployed when enabled | Warn only |
| Service | Gateway TCP/443 reachable from your machine | Warn only |
| Service | Broker TCP/443 reachable from the Gateway | Warn only |
| Service | Leostream Agent service running on `leo-win-01` | Warn only |

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

Check the Agent on the desktop:

```powershell
Invoke-AzVMRunCommand -ResourceGroupName rg-leostream-poc -VMName leo-win-01 `
    -CommandId RunPowerShellScript `
    -ScriptString 'Get-Service LeostreamAgent | Format-List Name,Status,StartType'
```

## 4. End-to-end user test

This is the real acceptance test and must be done by hand.

1. From a client whose public IP is inside `AllowedClientCidrs`, browse to
   `https://<gateway-public-ip>/`.
2. Accept the self-signed certificate warning (expected until you install a
   trusted certificate).
3. Sign in with a user that has a Leostream policy assigned.
4. Confirm the offered desktop `leo-win-01` appears.
5. Launch it and confirm the Windows 11 desktop renders through the Gateway.
6. In the Broker, check *Resources > Desktops* — the desktop status should be
   **Connected** and show the assigned user.
7. Log off and confirm the Broker releases the desktop according to the policy.

### Negative tests

| Test | Expected result |
|---|---|
| RDP directly to `10.50.10.10` from the internet | Fails — no public IP, NSG denies |
| Browse to `https://10.50.2.10/` from the internet | Fails — Broker is private |
| Browse to the Gateway from an IP outside `AllowedClientCidrs` | Connection times out |
| SSH to the Gateway public IP from the internet | Fails — firewalld restricts SSH to `10.50.0.0/16` |

## 5. Azure integration test

Confirm the Broker can drive Azure through its managed identity:

1. In the Broker, open *Setup > Centers* and select the Azure center.
2. Run **Refresh** — `leo-win-01` should be discovered.
3. Stop the desktop from the Broker and confirm with:

```powershell
Get-AzVM -ResourceGroupName rg-leostream-poc -Name leo-win-01 -Status |
    Select-Object -ExpandProperty Statuses |
    Where-Object Code -like 'PowerState/*'
```

4. Start it again from the Broker and confirm it returns to `VM running`.

If this works, the managed identity and RBAC configuration are correct and no
service-principal secret is needed anywhere.

## 6. Validation record

| Item | Result | Notes |
|---|---|---|
| `Test-LeostreamPoC.ps1` exits 0 | | |
| Only Gateway and Bastion have public IPs | | |
| Broker managed identity holds a role assignment | | |
| Broker reachable from the Gateway | | |
| Agent service running on `leo-win-01` | | |
| End-to-end desktop session succeeds | | |
| Negative tests all fail as expected | | |
| Broker can stop and start the desktop via Azure | | |
