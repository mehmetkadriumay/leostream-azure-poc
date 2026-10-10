#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources

<#
.SYNOPSIS
    Prepares the Azure credentials that a Leostream Azure Center needs:
    an Entra ID application registration, a service principal, a client
    secret and a role assignment.

.DESCRIPTION
    Leostream's Azure Center can authenticate in two ways:

      Managed identity          No secret to manage, but the Broker VM's
                                identity still needs a role assignment, which
                                only Owner or User Access Administrator can
                                create. On most corporate subscriptions a
                                Contributor hits "AuthorizationFailed" here and
                                is stuck.

      Entra ID application      Tenant ID, Application (client) ID and a client
                                secret, typed into the Center. Creating the
                                application needs no Azure RBAC at all - it is a
                                Microsoft Entra operation, allowed for ordinary
                                users in a default tenant. Only the final role
                                assignment needs elevated Azure rights, and that
                                part can be handed to an administrator as a
                                single command.

    This script automates the second model. It splits the work into the part you
    can almost always do yourself (application, service principal, secret) and
    the one part that may need someone else (the role assignment), so a missing
    permission costs you one email instead of a failed deployment.

    Everything is idempotent: re-running reuses the existing application and
    role assignment rather than creating duplicates.

    The client secret is shown ONCE, on the console. It is never written to
    disk, never committed, and cannot be retrieved afterwards - rotate it with
    -RotateSecret if you lose it.

.PARAMETER ConfigPath
    Path to poc.config.psd1. Defaults to ../config/poc.config.psd1.

.PARAMETER DisplayName
    Display name for the Entra application. Defaults to
    AzureCenter.AppDisplayName in the configuration file.

.PARAMETER ApplicationId
    Reuse an existing application (client) ID instead of creating one. Use this
    when your tenant blocks self-service app registration and an administrator
    has created the application for you.

.PARAMETER RoleDefinitionName
    Role to grant the service principal. Defaults to AzureCenter.RoleName in the
    configuration file ('Contributor'), which is what Leostream needs in order
    to create, power-manage and delete desktop VMs.

.PARAMETER Scope
    'ResourceGroup' (default) grants the role on the PoC resource group only.
    'Subscription' grants it subscription-wide - broader than a PoC needs.

.PARAMETER SecretValidMonths
    Lifetime of the generated client secret in months. Defaults to
    AzureCenter.SecretValidMonths (12).

.PARAMETER RotateSecret
    When the application already exists, add a fresh secret. Without this the
    script reuses the application and tells you to rotate if you need a secret.

.PARAMETER SkipRoleAssignment
    Create the application, service principal and secret, then print the role
    assignment command for an administrator instead of attempting it.

.EXAMPLE
    ./Configure-LeostreamAzureCenter.ps1

.EXAMPLE
    ./Configure-LeostreamAzureCenter.ps1 -SkipRoleAssignment

.EXAMPLE
    ./Configure-LeostreamAzureCenter.ps1 -ApplicationId 00000000-1111-2222-3333-444444444444 -RotateSecret
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),
    [string] $DisplayName,
    [string] $ApplicationId,
    [string] $RoleDefinitionName,
    [ValidateSet('ResourceGroup', 'Subscription')]
    [string] $Scope = 'ResourceGroup',
    [ValidateRange(1, 24)]
    [int]    $SecretValidMonths = 0,
    [switch] $RotateSecret,
    [switch] $SkipRoleAssignment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step { param([string] $Message) Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string] $Message) Write-Host "    $Message" -ForegroundColor DarkGray }

#region configuration and context ---------------------------------------------

$config = Import-PowerShellDataFile -Path (Resolve-Path -Path $ConfigPath -ErrorAction Stop).Path

$centerConfig = @{
    AppDisplayName    = 'leostream-poc-azure-center'
    RoleName          = 'Contributor'
    SecretValidMonths = 12
}
if ($config.ContainsKey('AzureCenter')) {
    foreach ($key in $config.AzureCenter.Keys) { $centerConfig[$key] = $config.AzureCenter[$key] }
}

if (-not $DisplayName)        { $DisplayName        = $centerConfig.AppDisplayName }
if (-not $RoleDefinitionName) { $RoleDefinitionName = $centerConfig.RoleName }
if ($SecretValidMonths -le 0) { $SecretValidMonths  = [int] $centerConfig.SecretValidMonths }

$rgName = $config.Azure.ResourceGroupName

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Write-Step 'No Azure context found - launching interactive sign-in'
    Connect-AzAccount -ErrorAction Stop | Out-Null
}
if ($config.Azure.SubscriptionId) {
    $current = Get-AzContext
    if ($current.Subscription.Id -ne $config.Azure.SubscriptionId) {
        Set-AzContext -SubscriptionId $config.Azure.SubscriptionId -ErrorAction Stop | Out-Null
    }
}
$context  = Get-AzContext -ErrorAction Stop
$tenantId = $context.Tenant.Id
$subId    = $context.Subscription.Id

Write-Ok "Tenant:       $tenantId"
Write-Ok "Subscription: $($context.Subscription.Name) ($subId)"

$scopeId = if ($Scope -eq 'Subscription') {
    "/subscriptions/$subId"
} else {
    "/subscriptions/$subId/resourceGroups/$rgName"
}

#endregion

#region application registration ----------------------------------------------

Write-Step 'Entra ID application registration'

$app = $null
if ($ApplicationId) {
    $app = Get-AzADApplication -ApplicationId $ApplicationId -ErrorAction SilentlyContinue
    if (-not $app) {
        throw "No application with client ID '$ApplicationId' is visible in tenant $tenantId. Check the ID, or omit -ApplicationId to create a new one."
    }
    Write-Ok "Reusing application '$($app.DisplayName)' ($($app.AppId))."
}
else {
    $app = Get-AzADApplication -DisplayName $DisplayName -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($app) {
        Write-Ok "Application '$DisplayName' already exists ($($app.AppId)) - reusing it."
    }
    elseif ($PSCmdlet.ShouldProcess($DisplayName, 'Create Entra ID application registration')) {
        try {
            # SignInAudience AzureADMyOrg: single tenant. The Center is a
            # daemon-style client, so no reply URL or redirect URI is needed.
            $app = New-AzADApplication -DisplayName $DisplayName -SignInAudience 'AzureADMyOrg' -ErrorAction Stop
            Write-Ok "Created application '$DisplayName' ($($app.AppId))."
        }
        catch {
            throw @"
Could not create the application registration: $($_.Exception.Message)

If this says Authorization_RequestDenied, your tenant has turned off
self-service app registration. Ask an administrator to create an app
registration (no API permissions and no redirect URI are required) and
re-run with:

    ./Configure-LeostreamAzureCenter.ps1 -ApplicationId <client-id>
"@
        }
    }
}

if (-not $app) { Write-Host 'No application available (-WhatIf?) - stopping here.' -ForegroundColor Yellow; return }

#endregion

#region service principal -------------------------------------------------------

Write-Step 'Service principal'

$sp = Get-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction SilentlyContinue
if ($sp) {
    Write-Ok "Service principal already exists (object ID $($sp.Id))."
}
elseif ($PSCmdlet.ShouldProcess($app.AppId, 'Create service principal')) {
    # The application object is the definition; the service principal is the
    # identity that actually holds role assignments in this subscription.
    $sp = New-AzADServicePrincipal -ApplicationId $app.AppId -ErrorAction Stop
    Write-Ok "Created service principal (object ID $($sp.Id))."
}

#endregion

#region client secret -----------------------------------------------------------

Write-Step 'Client secret'

$existingCreds = @(Get-AzADAppCredential -ApplicationId $app.AppId -ErrorAction SilentlyContinue)
$secretText    = $null
$secretExpiry  = $null

$needSecret = ($existingCreds.Count -eq 0) -or $RotateSecret

if (-not $needSecret) {
    Write-Ok "$($existingCreds.Count) credential(s) already exist and -RotateSecret was not given."
    Write-Ok 'A client secret can never be read back after creation. Re-run with -RotateSecret if you need a new one.'
}
elseif ($PSCmdlet.ShouldProcess($app.AppId, "Create client secret valid for $SecretValidMonths month(s)")) {
    $end = (Get-Date).AddMonths($SecretValidMonths)
    $cred = New-AzADAppCredential -ApplicationId $app.AppId -EndDate $end -ErrorAction Stop
    $secretText   = $cred.SecretText
    $secretExpiry = $cred.EndDateTime
    Write-Ok "Secret created, expires $($end.ToString('yyyy-MM-dd'))."
}

#endregion

#region role assignment ----------------------------------------------------------

Write-Step "Role assignment ($RoleDefinitionName at $Scope scope)"

$manualCommand = "New-AzRoleAssignment -ObjectId $(if ($sp) { $sp.Id } else { '<service-principal-object-id>' }) -RoleDefinitionName '$RoleDefinitionName' -Scope '$scopeId'"
$roleAssigned  = $false

if (-not $sp) {
    Write-Warning 'No service principal available - skipping role assignment.'
}
elseif ($SkipRoleAssignment) {
    Write-Ok 'Skipped at your request. An administrator can run:'
    Write-Host "      $manualCommand" -ForegroundColor Yellow
}
else {
    $existing = Get-AzRoleAssignment -ObjectId $sp.Id -Scope $scopeId -ErrorAction SilentlyContinue |
        Where-Object { $_.RoleDefinitionName -eq $RoleDefinitionName -and $_.Scope -eq $scopeId }

    if ($existing) {
        Write-Ok "Already assigned '$RoleDefinitionName' at $scopeId."
        $roleAssigned = $true
    }
    elseif ($PSCmdlet.ShouldProcess($scopeId, "Assign '$RoleDefinitionName' to $($app.DisplayName)")) {
        # A brand-new service principal is not immediately visible to Azure RBAC;
        # the first attempts fail with PrincipalNotFound until Entra replicates.
        $attempt = 0
        while (-not $roleAssigned -and $attempt -lt 6) {
            $attempt++
            try {
                New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $RoleDefinitionName -Scope $scopeId -ErrorAction Stop | Out-Null
                $roleAssigned = $true
                Write-Ok "Assigned '$RoleDefinitionName' at $scopeId."
            }
            catch {
                $message = $_.Exception.Message
                if ($message -match 'PrincipalNotFound|does not exist in the directory' -and $attempt -lt 6) {
                    Write-Ok "Directory has not replicated the principal yet - retrying in 10s ($attempt/6)."
                    Start-Sleep -Seconds 10
                }
                elseif ($message -match 'RoleAssignmentExists') {
                    $roleAssigned = $true
                    Write-Ok 'Role assignment already exists.'
                }
                elseif ($message -match 'AuthorizationFailed|does not have authorization|Forbidden') {
                    Write-Host ''
                    Write-Warning @"
You do not have permission to create role assignments.

This is the one step Contributor cannot do - granting access requires Owner
or User Access Administrator. The application, service principal and secret
above were still created successfully, so nothing is lost.

Send this single command to an administrator:

    $manualCommand

Or, in the portal: $rgName > Access control (IAM) > Add role assignment >
$RoleDefinitionName > Members > User, group, or service principal >
'$($app.DisplayName)'.

Until that is done, the Leostream Azure Center will authenticate but see no
virtual machines.
"@
                    break
                }
                else {
                    throw
                }
            }
        }
    }
}

#endregion

#region summary -------------------------------------------------------------------

Write-Host ''
Write-Host 'Leostream > Setup > Centers > Add Center > Microsoft Azure' -ForegroundColor Green
Write-Host '--------------------------------------------------------------------'
Write-Host ("  Subscription ID         : {0}" -f $subId)
Write-Host ("  Tenant / Directory ID   : {0}" -f $tenantId)
Write-Host ("  Application (client) ID : {0}" -f $app.AppId)
if ($secretText) {
    Write-Host ("  Client secret           : {0}" -f $secretText) -ForegroundColor Yellow
    Write-Host ("  Secret expires          : {0}" -f $secretExpiry)
    Write-Host ''
    Write-Host '  Copy the secret now. Azure will not show it again, and this script' -ForegroundColor Yellow
    Write-Host '  deliberately does not write it to disk. Lost it? Re-run with' -ForegroundColor Yellow
    Write-Host '  -RotateSecret to issue a replacement.' -ForegroundColor Yellow
}
else {
    Write-Host '  Client secret           : (not issued in this run - use -RotateSecret)'
}
Write-Host ("  Resource group          : {0}" -f $rgName)
Write-Host ("  Role                    : {0} at {1}" -f $RoleDefinitionName, $scopeId)
Write-Host ("  Role assignment         : {0}" -f $(if ($roleAssigned) { 'in place' } else { 'OUTSTANDING - see above' })) `
    -ForegroundColor $(if ($roleAssigned) { 'Green' } else { 'Yellow' })
Write-Host '--------------------------------------------------------------------'
Write-Host ''
Write-Host 'Teardown: ./Remove-LeostreamPoC.ps1 -RemoveAzureCenterApp' -ForegroundColor DarkGray

#endregion
