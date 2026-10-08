#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Compute

<#
.SYNOPSIS
    Grants the Broker's system-assigned managed identity the Azure permissions
    needed to manage the PoC desktop virtual machines.

.DESCRIPTION
    Leostream Platform 26 can use an Azure managed identity instead of a service
    principal with a client secret. This script:

      * verifies that leo-broker-01 has a system-assigned managed identity
        (enabling it if required)
      * assigns the configured role (default: Virtual Machine Contributor) at
        the resource group or subscription scope
      * is idempotent - an existing assignment is left untouched

    No client secrets or credentials are created or stored.

.PARAMETER Scope
    'ResourceGroup' (default) or 'Subscription'. Overrides poc.config.psd1.

.PARAMETER RoleDefinitionName
    Azure RBAC role to assign. Overrides poc.config.psd1.

.EXAMPLE
    ./Configure-LeostreamAzureRBAC.ps1

.EXAMPLE
    ./Configure-LeostreamAzureRBAC.ps1 -Scope Subscription -RoleDefinitionName 'Contributor'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),

    [ValidateSet('ResourceGroup', 'Subscription')]
    [string] $Scope,

    [string] $RoleDefinitionName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName
$spec   = $config.VirtualMachines.Broker

if (-not $Scope)              { $Scope = $config.Rbac.Scope }
if (-not $RoleDefinitionName) { $RoleDefinitionName = $config.Rbac.RoleDefinitionName }

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}
$context = Get-AzContext

$vm = Get-AzVM -ResourceGroupName $rgName -Name $spec.Name -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$($spec.Name)' not found in resource group '$rgName'. Run Deploy-LeostreamPoC.ps1 first."
}

# --- ensure the system-assigned managed identity exists -----------------------
$principalId = $null
if ($vm.Identity -and $vm.Identity.PrincipalId) {
    $principalId = $vm.Identity.PrincipalId
    Write-Host "==> Managed identity already enabled on $($spec.Name)." -ForegroundColor Cyan
}
else {
    if ($PSCmdlet.ShouldProcess($spec.Name, 'Enable system-assigned managed identity')) {
        Write-Host "==> Enabling system-assigned managed identity on $($spec.Name)." -ForegroundColor Cyan
        Update-AzVM -ResourceGroupName $rgName -VM $vm -IdentityType SystemAssigned | Out-Null
        $vm = Get-AzVM -ResourceGroupName $rgName -Name $spec.Name
        $principalId = $vm.Identity.PrincipalId
    }
}

if (-not $principalId) {
    throw "Could not determine the managed identity principal ID for '$($spec.Name)'."
}
Write-Host "    Principal ID: $principalId" -ForegroundColor DarkGray

# --- determine scope ----------------------------------------------------------
if ($Scope -eq 'Subscription') {
    $scopeId = "/subscriptions/$($context.Subscription.Id)"
}
else {
    $rg = Get-AzResourceGroup -Name $rgName
    $scopeId = $rg.ResourceId
}
Write-Host "    Scope: $scopeId" -ForegroundColor DarkGray

# --- assign role (idempotent) -------------------------------------------------
$existing = Get-AzRoleAssignment -ObjectId $principalId -Scope $scopeId -ErrorAction SilentlyContinue |
    Where-Object { $_.RoleDefinitionName -eq $RoleDefinitionName -and $_.Scope -eq $scopeId }

if ($existing) {
    Write-Host "==> Role '$RoleDefinitionName' is already assigned at this scope." -ForegroundColor Green
}
elseif ($PSCmdlet.ShouldProcess($scopeId, "Assign role '$RoleDefinitionName' to the Broker managed identity")) {
    # Azure AD replication can lag behind identity creation - retry briefly.
    $attempt = 0
    while ($true) {
        $attempt++
        try {
            New-AzRoleAssignment `
                -ObjectId $principalId `
                -RoleDefinitionName $RoleDefinitionName `
                -Scope $scopeId `
                -ErrorAction Stop | Out-Null
            Write-Host "==> Assigned '$RoleDefinitionName' at $scopeId." -ForegroundColor Green
            break
        }
        catch {
            if ($attempt -ge 6) { throw }
            Write-Host "    Assignment attempt $attempt failed (directory replication?). Retrying in 20s." -ForegroundColor Yellow
            Start-Sleep -Seconds 20
        }
    }
}

Write-Host ''
Write-Host 'In the Leostream Broker, create an Azure center using:' -ForegroundColor Green
Write-Host "  Authentication : Managed Identity (system-assigned on $($spec.Name))"
Write-Host "  Subscription   : $($context.Subscription.Id)"
Write-Host "  Tenant         : $($context.Tenant.Id)"
Write-Host "  Resource group : $rgName"
