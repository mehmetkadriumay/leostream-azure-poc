#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Validates the Leostream PoC deployment on Azure.

.DESCRIPTION
    Read-only checks covering infrastructure and the Leostream layer:

      Infrastructure
        * resource group, virtual network and the single subnet with the
          expected address prefix
        * NSG attached, HTTPS and SSH inbound allowed, Broker without a
          public IP address
        * Broker and Gateway are distinct virtual machines
        * both VMs running
        * Broker has a system-assigned managed identity

      Services
        * Gateway TCP/443 and TCP/22 reachable from the current machine
        * Broker HTTPS reachable from inside the VNet (via RunCommand on the
          Gateway)

.PARAMETER SkipRemoteChecks
    Only perform Azure control-plane checks (no RunCommand invocations).

.EXAMPLE
    ./Test-LeostreamPoC.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),
    [switch] $SkipRemoteChecks
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param(
        [Parameter(Mandatory)][string] $Area,
        [Parameter(Mandatory)][string] $Check,
        [Parameter(Mandatory)][ValidateSet('Pass', 'Fail', 'Warn', 'Skip')][string] $Status,
        [string] $Detail = ''
    )
    $script:results.Add([pscustomobject]@{
        Area   = $Area
        Check  = $Check
        Status = $Status
        Detail = $Detail
    })

    $colour = switch ($Status) {
        'Pass' { 'Green' }
        'Fail' { 'Red' }
        'Warn' { 'Yellow' }
        default { 'DarkGray' }
    }
    Write-Host ('[{0,-4}] {1,-16} {2}' -f $Status, $Area, $Check) -ForegroundColor $colour
    if ($Detail) { Write-Host "        $Detail" -ForegroundColor DarkGray }
}

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}

Write-Host "==> Validating Leostream PoC in resource group '$rgName'" -ForegroundColor Cyan
Write-Host ''

# --- resource group -----------------------------------------------------------
$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if ($rg) {
    Add-Result -Area 'Infrastructure' -Check 'Resource group exists' -Status Pass -Detail $rg.Location
}
else {
    Add-Result -Area 'Infrastructure' -Check 'Resource group exists' -Status Fail -Detail "'$rgName' not found"
    $script:results | Format-Table -AutoSize
    exit 1
}

# --- virtual network and subnets ---------------------------------------------
$vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $config.Network.VNetName -ErrorAction SilentlyContinue
if ($vnet) {
    Add-Result -Area 'Network' -Check 'Virtual network exists' -Status Pass -Detail ($vnet.AddressSpace.AddressPrefixes -join ', ')

    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $config.Network.SubnetName }
    if (-not $subnet) {
        Add-Result -Area 'Network' -Check "Subnet $($config.Network.SubnetName)" -Status Fail -Detail 'missing'
    }
    elseif ($subnet.AddressPrefix -contains $config.Network.SubnetPrefix) {
        Add-Result -Area 'Network' -Check "Subnet $($config.Network.SubnetName)" -Status Pass -Detail $config.Network.SubnetPrefix

        if ($subnet.NetworkSecurityGroup) {
            Add-Result -Area 'Network' -Check 'NSG attached to the subnet' -Status Pass
        }
        else {
            Add-Result -Area 'Network' -Check 'NSG attached to the subnet' -Status Fail -Detail 'no NSG attached'
        }

        # Without an outbound path the private Broker cannot reach the package
        # repositories, which surfaces only as repository timeouts during
        # installation. Check it here instead.
        if ($config.Network.Contains('NatGatewayEnabled') -and $config.Network.NatGatewayEnabled) {
            if ($subnet.NatGateway) {
                $natName = ($subnet.NatGateway.Id -split '/')[-1]
                Add-Result -Area 'Network' -Check 'NAT gateway attached (Broker outbound)' -Status Pass -Detail $natName
            }
            else {
                Add-Result -Area 'Network' -Check 'NAT gateway attached (Broker outbound)' -Status Fail `
                    -Detail 'no NAT gateway on the subnet - the Broker has no outbound internet, so installation will fail'
            }
        }
    }
    else {
        Add-Result -Area 'Network' -Check "Subnet $($config.Network.SubnetName)" -Status Fail -Detail "expected $($config.Network.SubnetPrefix), found $($subnet.AddressPrefix -join ',')"
    }
}
else {
    Add-Result -Area 'Network' -Check 'Virtual network exists' -Status Fail -Detail "'$($config.Network.VNetName)' not found"
}

# --- NSG rules ----------------------------------------------------------------
$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $config.Network.NsgName -ErrorAction SilentlyContinue
if ($nsg) {
    foreach ($port in @("$($config.Ports.Https)", "$($config.Ports.Ssh)")) {
        $rule = @($nsg.SecurityRules | Where-Object {
            $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' -and ($_.DestinationPortRange -contains $port)
        })
        if ($rule.Count -gt 0) {
            Add-Result -Area 'Security' -Check "Inbound TCP/$port allowed" -Status Pass -Detail ($rule.Name -join ', ')
        }
        else {
            Add-Result -Area 'Security' -Check "Inbound TCP/$port allowed" -Status Fail
        }
    }
}
else {
    Add-Result -Area 'Security' -Check "NSG $($config.Network.NsgName) exists" -Status Fail
}

# --- virtual machines ---------------------------------------------------------
$brokerSpec  = $config.VirtualMachines.Broker
$gatewaySpec = $config.VirtualMachines.Gateway

if ($brokerSpec.Name -ne $gatewaySpec.Name) {
    Add-Result -Area 'Architecture' -Check 'Broker and Gateway are separate VMs' -Status Pass -Detail "$($brokerSpec.Name) / $($gatewaySpec.Name)"
}
else {
    Add-Result -Area 'Architecture' -Check 'Broker and Gateway are separate VMs' -Status Fail
}

foreach ($spec in @($brokerSpec, $gatewaySpec)) {
    $vm = Get-AzVM -ResourceGroupName $rgName -Name $spec.Name -Status -ErrorAction SilentlyContinue
    if (-not $vm) {
        Add-Result -Area 'Compute' -Check "VM $($spec.Name)" -Status Fail -Detail 'not found'
        continue
    }

    $powerState = ($vm.Statuses | Where-Object { $_.Code -like 'PowerState/*' } | Select-Object -First 1).DisplayStatus
    if ($powerState -eq 'VM running') {
        Add-Result -Area 'Compute' -Check "VM $($spec.Name) running" -Status Pass -Detail $powerState
    }
    else {
        Add-Result -Area 'Compute' -Check "VM $($spec.Name) running" -Status Warn -Detail $powerState
    }

    # public IP exposure
    $nic = Get-AzNetworkInterface -ResourceGroupName $rgName -Name "nic-$($spec.Name)" -ErrorAction SilentlyContinue
    $hasPublic = $false
    if ($nic) {
        $hasPublic = [bool]($nic.IpConfigurations | Where-Object { $_.PublicIpAddress })
    }

    if ($spec.PublicIp) {
        if ($hasPublic) {
            Add-Result -Area 'Security' -Check "$($spec.Name) has the expected public IP" -Status Pass
        }
        else {
            Add-Result -Area 'Security' -Check "$($spec.Name) has the expected public IP" -Status Fail
        }
    }
    else {
        if ($hasPublic) {
            Add-Result -Area 'Security' -Check "$($spec.Name) is private only" -Status Fail -Detail 'unexpected public IP attached'
        }
        else {
            Add-Result -Area 'Security' -Check "$($spec.Name) is private only" -Status Pass
        }
    }
}

# --- managed identity ---------------------------------------------------------
# The identity is created ready for use but is deliberately left with no role
# assignment: this PoC has no desktop VMs for the Broker to power-manage.
$brokerVm = Get-AzVM -ResourceGroupName $rgName -Name $brokerSpec.Name -ErrorAction SilentlyContinue
if ($brokerVm) {
    if ($brokerVm.Identity -and $brokerVm.Identity.PrincipalId) {
        Add-Result -Area 'Identity' -Check 'Broker system-assigned managed identity' -Status Pass -Detail $brokerVm.Identity.PrincipalId
    }
    else {
        Add-Result -Area 'Identity' -Check 'Broker system-assigned managed identity' -Status Fail
    }
}

# --- Azure Center credentials -------------------------------------------------
# Optional: only meaningful once Configure-LeostreamAzureCenter.ps1 has run, so
# a missing application is a Skip rather than a failure.
$centerAppName = $null
if ($config.ContainsKey('AzureCenter') -and $config.AzureCenter.AppDisplayName) {
    $centerAppName = $config.AzureCenter.AppDisplayName
}

if ($centerAppName) {
    $centerApp = Get-AzADApplication -DisplayName $centerAppName -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $centerApp) {
        Add-Result -Area 'AzureCenter' -Check "Entra application '$centerAppName'" -Status Skip `
            -Detail 'not created - run ./Configure-LeostreamAzureCenter.ps1 if you want an Azure Center'
    }
    else {
        Add-Result -Area 'AzureCenter' -Check "Entra application '$centerAppName'" -Status Pass -Detail $centerApp.AppId

        $centerSp = Get-AzADServicePrincipal -ApplicationId $centerApp.AppId -ErrorAction SilentlyContinue
        if ($centerSp) {
            Add-Result -Area 'AzureCenter' -Check 'Service principal' -Status Pass -Detail $centerSp.Id

            $creds = @(Get-AzADAppCredential -ApplicationId $centerApp.AppId -ErrorAction SilentlyContinue)
            $live  = @($creds | Where-Object { $_.EndDateTime -and $_.EndDateTime -gt (Get-Date) })
            if ($live.Count -gt 0) {
                $soonest = ($live | Sort-Object EndDateTime | Select-Object -First 1).EndDateTime
                Add-Result -Area 'AzureCenter' -Check 'Client secret valid' -Status Pass -Detail "earliest expiry $($soonest.ToString('yyyy-MM-dd'))"
            }
            elseif ($creds.Count -gt 0) {
                Add-Result -Area 'AzureCenter' -Check 'Client secret valid' -Status Fail -Detail 'all credentials have expired - re-run Configure-LeostreamAzureCenter.ps1 -RotateSecret'
            }
            else {
                Add-Result -Area 'AzureCenter' -Check 'Client secret valid' -Status Warn -Detail 'no credential on the application'
            }

            $centerRole = 'Contributor'
            if ($config.AzureCenter.ContainsKey('RoleName') -and $config.AzureCenter.RoleName) {
                $centerRole = $config.AzureCenter.RoleName
            }
            $assignments = @(Get-AzRoleAssignment -ObjectId $centerSp.Id -ErrorAction SilentlyContinue |
                Where-Object { $_.RoleDefinitionName -eq $centerRole })
            if ($assignments.Count -gt 0) {
                Add-Result -Area 'AzureCenter' -Check "'$centerRole' role assigned" -Status Pass -Detail $assignments[0].Scope
            }
            else {
                Add-Result -Area 'AzureCenter' -Check "'$centerRole' role assigned" -Status Warn `
                    -Detail 'the Center will authenticate but see no VMs - an Owner or User Access Administrator must grant the role'
            }
        }
        else {
            Add-Result -Area 'AzureCenter' -Check 'Service principal' -Status Fail -Detail 'application exists but has no service principal in this tenant'
        }
    }
}

# --- gateway reachability -----------------------------------------------------
$pip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $gatewaySpec.PublicIpName -ErrorAction SilentlyContinue
if ($pip -and $pip.IpAddress -and $pip.IpAddress -ne 'Not Assigned') {
    Add-Result -Area 'Network' -Check 'Gateway public IP assigned' -Status Pass -Detail $pip.IpAddress

    if (-not $SkipRemoteChecks) {
        $tcp = Test-NetConnection -ComputerName $pip.IpAddress -Port $config.Ports.Https -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Add-Result -Area 'Service' -Check 'Gateway TCP/443 reachable' -Status Pass -Detail $pip.IpAddress
        }
        else {
            Add-Result -Area 'Service' -Check 'Gateway TCP/443 reachable' -Status Warn -Detail 'no response - Gateway software may not be installed yet, or your IP is not in AllowedClientCidrs'
        }

        $ssh = Test-NetConnection -ComputerName $pip.IpAddress -Port $config.Ports.Ssh -WarningAction SilentlyContinue
        if ($ssh.TcpTestSucceeded) {
            Add-Result -Area 'Service' -Check 'Gateway TCP/22 reachable' -Status Pass -Detail 'administrative SSH path is open'
        }
        else {
            Add-Result -Area 'Service' -Check 'Gateway TCP/22 reachable' -Status Warn -Detail 'no response - your IP is probably not in AllowedClientCidrs'
        }
    }
}
else {
    Add-Result -Area 'Network' -Check 'Gateway public IP assigned' -Status Fail
}

# --- in-VNet checks via RunCommand -------------------------------------------
if (-not $SkipRemoteChecks) {
    Write-Host ''
    Write-Host '==> Running in-VNet checks (this takes a minute)' -ForegroundColor Cyan

    try {
        $probe = "timeout 10 bash -c '</dev/tcp/$($brokerSpec.PrivateIp)/443' && echo BROKER_443_OPEN || echo BROKER_443_CLOSED"
        $res = Invoke-AzVMRunCommand -ResourceGroupName $rgName -VMName $gatewaySpec.Name `
            -CommandId 'RunShellScript' -ScriptString $probe -ErrorAction Stop
        $message = ($res.Value | ForEach-Object { $_.Message }) -join "`n"
        if ($message -match 'BROKER_443_OPEN') {
            Add-Result -Area 'Service' -Check 'Broker HTTPS reachable from Gateway' -Status Pass
        }
        else {
            Add-Result -Area 'Service' -Check 'Broker HTTPS reachable from Gateway' -Status Warn -Detail 'Broker software may not be installed yet'
        }
    }
    catch {
        Add-Result -Area 'Service' -Check 'Broker HTTPS reachable from Gateway' -Status Skip -Detail $_.Exception.Message
    }

}

# --- summary ------------------------------------------------------------------
Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
$script:results | Group-Object Status | ForEach-Object {
    Write-Host ("    {0,-5} {1}" -f $_.Name, $_.Count)
}

# @() matters: on Windows PowerShell 5.1 a single result is a scalar whose
# .Count is $null, which would hide exactly one failure.
$failCount = @($script:results | Where-Object Status -eq 'Fail').Count
if ($failCount -gt 0) {
    Write-Host ''
    Write-Host "$failCount check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All critical checks passed.' -ForegroundColor Green
