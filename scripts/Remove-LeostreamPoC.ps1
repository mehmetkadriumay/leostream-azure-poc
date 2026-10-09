#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Removes the Leostream PoC from Azure.

.DESCRIPTION
    Deletes the whole PoC resource group (the default) or, with
    -KeepResourceGroup, only the resources created by Deploy-LeostreamPoC.ps1.

    Role assignments granted to the Broker's managed identity at subscription
    scope are removed as well, because deleting the VM alone leaves orphaned
    assignments behind.

    The script refuses to run against a resource group that is not tagged as
    part of this PoC unless -Force is supplied.

.PARAMETER KeepResourceGroup
    Delete the VMs, disks, NICs, public IP, VNet and NSG but keep the
    resource group itself.

.PARAMETER Force
    Skip the confirmation prompt and the PoC tag safety check.

.EXAMPLE
    ./Remove-LeostreamPoC.ps1

.EXAMPLE
    ./Remove-LeostreamPoC.ps1 -KeepResourceGroup -Force
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),
    [switch] $KeepResourceGroup,
    [switch] $Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}
$context = Get-AzContext

$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    Write-Host "Resource group '$rgName' does not exist - nothing to do." -ForegroundColor Green
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

if (-not $Force) {
    $answer = Read-Host "Type the resource group name '$rgName' to confirm deletion"
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

# --- delete -------------------------------------------------------------------
if ($KeepResourceGroup) {
    Write-Host '==> Deleting individual resources (resource group retained)' -ForegroundColor Cyan

    # Order matters: compute first, then NICs/public IPs, then VNet/NSG.
    $order = @(
        'Microsoft.Compute/virtualMachines',
        'Microsoft.Compute/disks',
        'Microsoft.Network/networkInterfaces',
        'Microsoft.Network/publicIPAddresses',
        'Microsoft.Network/virtualNetworks',
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

    $remaining = Get-AzResource -ResourceGroupName $rgName
    foreach ($resource in $remaining) {
        if ($PSCmdlet.ShouldProcess($resource.Name, "Delete $($resource.ResourceType)")) {
            Write-Host "    Deleting leftover $($resource.Name)" -ForegroundColor DarkGray
            Remove-AzResource -ResourceId $resource.ResourceId -Force -ErrorAction Continue | Out-Null
        }
    }

    Write-Host '==> Resources removed; resource group retained.' -ForegroundColor Green
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
