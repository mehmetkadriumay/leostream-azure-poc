#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Removes the Leostream PoC from Azure.

.DESCRIPTION
    Deletes the VMs, disks, NICs, public IPs, NAT gateway, VNet and NSG created
    by Deploy-LeostreamPoC.ps1, and by default KEEPS the resource group itself.

    Keeping the group is deliberate. The Azure Center's role assignment is
    scoped to the resource group, and on most corporate subscriptions only an
    Owner or User Access Administrator can create it - frequently someone other
    than you. Deleting the group destroys that assignment, and recreating a
    group with the same name does not bring it back: you would have to ask for
    it again. Keeping an empty resource group costs nothing.

    So the usual cycle is:

        ./Remove-LeostreamPoC.ps1      # tear down, keep RG + Entra app
        ./Deploy-LeostreamPoC.ps1      # redeploy into the same RG

    and the Azure Center keeps working with the same client secret, with no
    second trip to an administrator.

    Pass -RemoveResourceGroup only when you are finished with the PoC for good.

    Role assignments held by the Broker's system-assigned managed identity are
    always removed, because that identity is deleted along with its VM and the
    assignments would otherwise be left orphaned. Nothing is lost that could
    have been preserved.

    The Entra ID application created by Configure-LeostreamAzureCenter.ps1 is a
    directory object, not an Azure resource, so no form of this teardown touches
    it unless you pass -RemoveAzureCenterApp.

    The script refuses to run against a resource group that is not tagged as
    part of this PoC unless -Force is supplied.

.PARAMETER RemoveResourceGroup
    Also delete the resource group itself. This destroys any role assignment
    scoped to it, including the Azure Center's, which then has to be granted
    again by an Owner or User Access Administrator.

.PARAMETER KeepResourceGroup
    Retained for compatibility. Keeping the resource group is now the default,
    so this switch has no effect.

.PARAMETER RemoveAzureCenterApp
    Also delete the Entra ID application registration (and with it the service
    principal, its secret and its role assignments) used by the Azure Center.
    Only do this if you will not redeploy - it is the other half of what you
    would need an administrator for.

.PARAMETER Force
    Skip the confirmation prompt and the PoC tag safety check.

.EXAMPLE
    ./Remove-LeostreamPoC.ps1

    Deletes the running resources, keeps the resource group and the Entra
    application so the next deployment needs no administrator.

.EXAMPLE
    ./Remove-LeostreamPoC.ps1 -RemoveResourceGroup -RemoveAzureCenterApp -Force

    Complete removal, including the role assignment you may have had to ask
    someone else for.
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),
    [switch] $RemoveResourceGroup,
    [switch] $KeepResourceGroup,
    [switch] $RemoveAzureCenterApp,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -Force is documented as "no prompt". The script is declared ConfirmImpact High,
# so without this every ShouldProcess call would still stop and ask.
if ($Force) { $ConfirmPreference = 'None' }

if ($KeepResourceGroup) {
    Write-Host 'Note: -KeepResourceGroup is now the default and is no longer needed.' -ForegroundColor DarkGray
    # If both are given, the safe one wins rather than the destructive one.
    if ($RemoveResourceGroup) {
        Write-Warning '-KeepResourceGroup and -RemoveResourceGroup were both supplied. Keeping the resource group.'
        $RemoveResourceGroup = $false
    }
}

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}
$context = Get-AzContext

function Remove-PocAzureCenterApp {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param()

    # The Azure Center application is a directory object, not an Azure resource,
    # so it survives deletion of the resource group and has to go separately.
    $displayName = 'leostream-poc-azure-center'
    if ($config.ContainsKey('AzureCenter') -and $config.AzureCenter.AppDisplayName) {
        $displayName = $config.AzureCenter.AppDisplayName
    }

    $apps = @(Get-AzADApplication -DisplayName $displayName -ErrorAction SilentlyContinue)
    if ($apps.Count -eq 0) {
        Write-Host "    No Entra application named '$displayName' found." -ForegroundColor DarkGray
        return
    }

    foreach ($app in $apps) {
        $sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
        if ($sp) {
            foreach ($assignment in @(Get-AzRoleAssignment -ObjectId $sp.Id -ErrorAction SilentlyContinue)) {
                if ($PSCmdlet.ShouldProcess($assignment.Scope, "Remove role assignment '$($assignment.RoleDefinitionName)'")) {
                    try {
                        Remove-AzRoleAssignment -InputObject $assignment -ErrorAction Stop | Out-Null
                        Write-Host "    Removed '$($assignment.RoleDefinitionName)' at $($assignment.Scope)." -ForegroundColor DarkGray
                    }
                    catch {
                        Write-Warning "Could not remove role assignment at $($assignment.Scope): $($_.Exception.Message)"
                    }
                }
            }
        }

        if ($PSCmdlet.ShouldProcess($app.DisplayName, 'Delete Entra ID application registration')) {
            try {
                # Deleting the application cascades to its service principal and
                # any secrets it holds.
                Remove-AzADApplication -ObjectId $app.Id -ErrorAction Stop
                Write-Host "    Deleted application '$($app.DisplayName)' ($($app.AppId))." -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Could not delete application '$($app.DisplayName)': $($_.Exception.Message)"
            }
        }
    }
}

$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Resource group '$rgName' does not exist - nothing to do." -ForegroundColor Green
    if ($RemoveAzureCenterApp) {
        Write-Host '==> Removing the Azure Center application registration' -ForegroundColor Cyan
        Remove-PocAzureCenterApp
    }
    return
}

# --- safety check -------------------------------------------------------------
# Take the expected tag from the configuration so a renamed deployment (for
# example project=leostream-demo) still passes without needing -Force.
$expectedTag = 'leostream-poc'
if ($config.Azure.Tags -and $config.Azure.Tags.ContainsKey('project')) {
    $expectedTag = $config.Azure.Tags['project']
}
$hasPocTag = $rg.Tags -and $rg.Tags.ContainsKey('project') -and $rg.Tags['project'] -eq $expectedTag
if (-not $hasPocTag -and -not $Force) {
    throw "Resource group '$rgName' is not tagged project=$expectedTag. Re-run with -Force if you are certain."
}

Write-Host "==> Target: $rgName in subscription $($context.Subscription.Name) ($($context.Subscription.Id))" -ForegroundColor Cyan
$resources = @(Get-AzResource -ResourceGroupName $rgName)
Write-Host "    $($resources.Count) resource(s) will be removed." -ForegroundColor DarkGray
$resources | Select-Object Name, ResourceType | Format-Table -AutoSize | Out-String | Write-Host

if ($RemoveResourceGroup) {
    Write-Host '    The resource group itself will be deleted.' -ForegroundColor Yellow

    # Role assignments scoped to the resource group die with it. The Broker's
    # managed identity is expendable - it is deleted with its VM either way -
    # but anything else here was granted to a principal that outlives the
    # deployment, which on a locked-down subscription means another request to
    # an Owner or User Access Administrator.
    $brokerPrincipalId = $null
    $brokerVmForScope = Get-AzVM -ResourceGroupName $rgName -Name $config.VirtualMachines.Broker.Name -ErrorAction SilentlyContinue
    if ($brokerVmForScope -and $brokerVmForScope.Identity) { $brokerPrincipalId = $brokerVmForScope.Identity.PrincipalId }

    $rgScope = "/subscriptions/$($context.Subscription.Id)/resourceGroups/$rgName"
    $doomed = @(Get-AzRoleAssignment -Scope $rgScope -ErrorAction SilentlyContinue |
        Where-Object { $_.Scope -eq $rgScope -and $_.ObjectId -ne $brokerPrincipalId })

    if ($doomed.Count -gt 0) {
        Write-Host ''
        Write-Warning @"
Deleting this resource group also deletes $($doomed.Count) role assignment(s) scoped to it:

$(($doomed | ForEach-Object { "    $($_.RoleDefinitionName) -> $(if ($_.DisplayName) { $_.DisplayName } else { $_.ObjectId })" }) -join "`n")

Recreating a resource group with the same name does NOT restore these. If you
granted the Azure Center its role via an administrator, you will have to ask
again before the Center can see any VMs.

Press Ctrl+C now and re-run without -RemoveResourceGroup to keep them.
"@
        Write-Host ''
    }
}
else {
    Write-Host "    The resource group '$rgName' and any role assignments on it will be kept." -ForegroundColor DarkGray
}

if (-not $Force) {
    $answer = Read-Host "Type the resource group name '$rgName' to confirm"
    if ($answer -ne $rgName) {
        Write-Host 'Confirmation did not match - aborting.' -ForegroundColor Yellow
        return
    }
}

# --- remove role assignments for the Broker managed identity ------------------
$brokerSpec = $config.VirtualMachines.Broker
$brokerVm = Get-AzVM -ResourceGroupName $rgName -Name $brokerSpec.Name -ErrorAction SilentlyContinue
if ($brokerVm -and $brokerVm.Identity -and $brokerVm.Identity.PrincipalId) {
    $principalId = $brokerVm.Identity.PrincipalId
    Write-Host "==> Removing role assignments for the Broker managed identity ($principalId)" -ForegroundColor Cyan
    $assignments = Get-AzRoleAssignment -ObjectId $principalId -ErrorAction SilentlyContinue
    foreach ($assignment in $assignments) {
        if ($PSCmdlet.ShouldProcess($assignment.Scope, "Remove role assignment '$($assignment.RoleDefinitionName)'")) {
            try {
                Remove-AzRoleAssignment -InputObject $assignment -ErrorAction Stop | Out-Null
                Write-Host "    Removed '$($assignment.RoleDefinitionName)' at $($assignment.Scope)." -ForegroundColor DarkGray
            }
            catch {
                Write-Warning "Could not remove role assignment at $($assignment.Scope): $($_.Exception.Message)"
            }
        }
    }
}

# --- remove the Azure Center application registration --------------------------
if ($RemoveAzureCenterApp) {
    Write-Host '==> Removing the Azure Center application registration' -ForegroundColor Cyan
    Remove-PocAzureCenterApp
}
else {
    Write-Host '    Entra application left in place. Re-run with -RemoveAzureCenterApp to delete it.' -ForegroundColor DarkGray
}

# --- delete -------------------------------------------------------------------
if (-not $RemoveResourceGroup) {
    Write-Host '==> Deleting individual resources (resource group retained)' -ForegroundColor Cyan

    # Order matters, and every link has to be broken before its target can go:
    # a NIC holds the VM's subnet and public IP, the subnet holds the NAT
    # gateway and NSG, and the NAT gateway holds its own public IP. Deleting the
    # VNet is what releases the NAT gateway, so it has to precede it - and both
    # public IPs can only go once nothing references them.
    $order = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Compute/disks',
        'Microsoft.Network/networkInterfaces',
        'Microsoft.Network/virtualNetworks',
        'Microsoft.Network/natGateways',
        'Microsoft.Network/publicIPAddresses',
        'Microsoft.Network/networkSecurityGroups'
    )

    foreach ($type in $order) {
        foreach ($resource in ($resources | Where-Object { $_.ResourceType -eq $type })) {
            if ($PSCmdlet.ShouldProcess($resource.Name, "Delete $type")) {
                Write-Host "    Deleting $($resource.Name) ($type)" -ForegroundColor DarkGray
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue | Out-Null
            }
        }
    }

    # Under -WhatIf nothing was actually deleted, so a sweep would just rediscover
    # every resource and report a failure that did not happen.
    if ($WhatIfPreference) {
        Write-Host '==> (-WhatIf) Resource group would be retained.' -ForegroundColor Green
        return
    }

    # Anything not in the ordered list, plus anything whose dependency had not
    # finished deleting on the first attempt. Two passes clear the usual
    # "still in use by" races without needing explicit dependency tracking.
    for ($pass = 1; $pass -le 2; $pass++) {
        $remaining = @(Get-AzResource -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
        if ($remaining.Count -eq 0) { break }

        foreach ($resource in $remaining) {
            if ($PSCmdlet.ShouldProcess($resource.Name, "Delete $($resource.ResourceType)")) {
                Write-Host "    Deleting leftover $($resource.Name) ($($resource.ResourceType))" -ForegroundColor DarkGray
                Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue | Out-Null
            }
        }
    }

    $stillThere = @(Get-AzResource -ResourceGroupName $rgName -ErrorAction SilentlyContinue)
    if ($stillThere.Count -gt 0) {
        Write-Warning "$($stillThere.Count) resource(s) could not be deleted:"
        $stillThere | Select-Object Name, ResourceType | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host '    Re-run the script - a dependency may simply not have finished deleting yet.' -ForegroundColor Yellow
    }
    else {
        Write-Host '==> Resources removed; resource group retained.' -ForegroundColor Green
        Write-Host "    './Deploy-LeostreamPoC.ps1' will redeploy into '$rgName' and reuse any role assignment on it." -ForegroundColor DarkGray
    }
}
else {
    if ($PSCmdlet.ShouldProcess($rgName, 'Delete resource group and all contained resources')) {
        Write-Host "==> Deleting resource group '$rgName'. This can take 10+ minutes." -ForegroundColor Cyan
        Remove-AzResourceGroup -Name $rgName -Force -ErrorAction Stop | Out-Null
        Write-Host '==> Resource group deleted.' -ForegroundColor Green
    }
}

Write-Host ''
Write-Host 'Remember to release any Leostream licence seats used by this PoC.' -ForegroundColor Yellow
