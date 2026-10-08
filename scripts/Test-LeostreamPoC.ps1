#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Validates the Leostream PoC deployment on Azure.

.DESCRIPTION
    Read-only checks covering infrastructure and the Leostream layer:

      Infrastructure
        * resource group, virtual network and the four subnets with the
          expected address prefixes
        * NSGs attached, Gateway HTTPS allowed, Broker/desktop without a
          public IP address
        * Broker and Gateway are distinct virtual machines
        * all three VMs running
        * Broker has a system-assigned managed identity with a role assignment
        * Azure Bastion present (when enabled)

      Services
        * Gateway TCP/443 reachable from the current machine
        * Broker HTTPS reachable from inside the VNet (via RunCommand on the
          Gateway)
        * Leostream Agent service state on the Windows desktop

.PARAMETER SkipRemoteChecks
    Only perform Azure control-plane checks (no RunCommand invocations).

.EXAMPLE
    ./Test-LeostreamPoC.ps1
#>
[CmdletBinding()]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'poc.config.psd1'),
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

    foreach ($key in @('Gateway', 'Infrastructure', 'Desktop', 'Bastion')) {
        $expected = $config.Network.Subnets[$key]
        $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $expected.Name }
        if (-not $subnet) {
            Add-Result -Area 'Network' -Check "Subnet $($expected.Name)" -Status Fail -Detail 'missing'
            continue
        }
        if ($subnet.AddressPrefix -contains $expected.AddressPrefix) {
            Add-Result -Area 'Network' -Check "Subnet $($expected.Name)" -Status Pass -Detail $expected.AddressPrefix
        }
        else {
            Add-Result -Area 'Network' -Check "Subnet $($expected.Name)" -Status Fail -Detail "expected $($expected.AddressPrefix), found $($subnet.AddressPrefix -join ',')"
        }

        if ($key -ne 'Bastion') {
            if ($subnet.NetworkSecurityGroup) {
                Add-Result -Area 'Network' -Check "NSG on $($expected.Name)" -Status Pass
            }
            else {
                Add-Result -Area 'Network' -Check "NSG on $($expected.Name)" -Status Fail -Detail 'no NSG attached'
            }
        }
    }
}
else {
    Add-Result -Area 'Network' -Check 'Virtual network exists' -Status Fail -Detail "'$($config.Network.VNetName)' not found"
}

# --- NSG rules ----------------------------------------------------------------
$gwNsg = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $config.Network.Subnets.Gateway.NsgName -ErrorAction SilentlyContinue
if ($gwNsg) {
    $httpsRule = $gwNsg.SecurityRules | Where-Object {
        $_.Direction -eq 'Inbound' -and $_.Access -eq 'Allow' -and ($_.DestinationPortRange -contains '443')
    }
    if ($httpsRule) {
        Add-Result -Area 'Security' -Check 'Gateway HTTPS inbound allowed' -Status Pass -Detail ($httpsRule.Name -join ', ')
    }
    else {
        Add-Result -Area 'Security' -Check 'Gateway HTTPS inbound allowed' -Status Fail
    }
}

# --- virtual machines ---------------------------------------------------------
$brokerSpec  = $config.VirtualMachines.Broker
$gatewaySpec = $config.VirtualMachines.Gateway
$winSpec     = $config.VirtualMachines.WindowsDesktop

if ($brokerSpec.Name -ne $gatewaySpec.Name) {
    Add-Result -Area 'Architecture' -Check 'Broker and Gateway are separate VMs' -Status Pass -Detail "$($brokerSpec.Name) / $($gatewaySpec.Name)"
}
else {
    Add-Result -Area 'Architecture' -Check 'Broker and Gateway are separate VMs' -Status Fail
}

foreach ($spec in @($brokerSpec, $gatewaySpec, $winSpec)) {
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

# --- managed identity and RBAC ------------------------------------------------
$brokerVm = Get-AzVM -ResourceGroupName $rgName -Name $brokerSpec.Name -ErrorAction SilentlyContinue
if ($brokerVm) {
    if ($brokerVm.Identity -and $brokerVm.Identity.PrincipalId) {
        Add-Result -Area 'Identity' -Check 'Broker system-assigned managed identity' -Status Pass -Detail $brokerVm.Identity.PrincipalId

        $assignments = Get-AzRoleAssignment -ObjectId $brokerVm.Identity.PrincipalId -ErrorAction SilentlyContinue
        if ($assignments) {
            Add-Result -Area 'Identity' -Check 'Broker identity role assignment' -Status Pass -Detail (($assignments.RoleDefinitionName | Select-Object -Unique) -join ', ')
        }
        else {
            Add-Result -Area 'Identity' -Check 'Broker identity role assignment' -Status Fail -Detail 'run Configure-LeostreamAzureRBAC.ps1'
        }
    }
    else {
        Add-Result -Area 'Identity' -Check 'Broker system-assigned managed identity' -Status Fail
    }
}

# --- bastion ------------------------------------------------------------------
if ($config.Bastion.Enabled) {
    $bastion = Get-AzBastion -ResourceGroupName $rgName -Name $config.Bastion.Name -ErrorAction SilentlyContinue
    if ($bastion) {
        Add-Result -Area 'Infrastructure' -Check 'Azure Bastion deployed' -Status Pass -Detail $bastion.Sku.Name
    }
    else {
        Add-Result -Area 'Infrastructure' -Check 'Azure Bastion deployed' -Status Warn -Detail 'not found (deployed with -SkipBastion?)'
    }
}

# --- gateway reachability -----------------------------------------------------
$pip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $gatewaySpec.PublicIpName -ErrorAction SilentlyContinue
if ($pip -and $pip.IpAddress -and $pip.IpAddress -ne 'Not Assigned') {
    Add-Result -Area 'Network' -Check 'Gateway public IP assigned' -Status Pass -Detail $pip.IpAddress

    if (-not $SkipRemoteChecks) {
        $tcp = Test-NetConnection -ComputerName $pip.IpAddress -Port $config.Ports.LeostreamGatewayHttps -WarningAction SilentlyContinue
        if ($tcp.TcpTestSucceeded) {
            Add-Result -Area 'Service' -Check 'Gateway TCP/443 reachable' -Status Pass -Detail $pip.IpAddress
        }
        else {
            Add-Result -Area 'Service' -Check 'Gateway TCP/443 reachable' -Status Warn -Detail 'no response - Gateway software may not be installed yet, or your IP is not in AllowedClientCidrs'
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

    try {
        $agentProbe = @'
$svc = Get-Service -Name 'LeostreamAgent' -ErrorAction SilentlyContinue
if ($svc) { Write-Output "AGENT_STATUS=$($svc.Status)" } else { Write-Output 'AGENT_STATUS=NotInstalled' }
'@
        $res = Invoke-AzVMRunCommand -ResourceGroupName $rgName -VMName $winSpec.Name `
            -CommandId 'RunPowerShellScript' -ScriptString $agentProbe -ErrorAction Stop
        $message = ($res.Value | ForEach-Object { $_.Message }) -join "`n"
        if ($message -match 'AGENT_STATUS=Running') {
            Add-Result -Area 'Service' -Check 'Leostream Agent running on the desktop' -Status Pass
        }
        elseif ($message -match 'AGENT_STATUS=NotInstalled') {
            Add-Result -Area 'Service' -Check 'Leostream Agent running on the desktop' -Status Warn -Detail 'run Install-LeostreamAgent.ps1'
        }
        else {
            Add-Result -Area 'Service' -Check 'Leostream Agent running on the desktop' -Status Warn -Detail $message.Trim()
        }
    }
    catch {
        Add-Result -Area 'Service' -Check 'Leostream Agent running on the desktop' -Status Skip -Detail $_.Exception.Message
    }
}

# --- summary ------------------------------------------------------------------
Write-Host ''
Write-Host '==> Summary' -ForegroundColor Cyan
$script:results | Group-Object Status | ForEach-Object {
    Write-Host ("    {0,-5} {1}" -f $_.Name, $_.Count)
}

$failCount = ($script:results | Where-Object Status -eq 'Fail').Count
if ($failCount -gt 0) {
    Write-Host ''
    Write-Host "$failCount check(s) failed." -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'All critical checks passed.' -ForegroundColor Green
