#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Deploys the Azure infrastructure for a Leostream Platform 26 proof of concept.

.DESCRIPTION
    The smallest topology that demonstrates Leostream on Azure:

        resource group
        virtual network with ONE subnet
        ONE network security group
        leo-broker-01   RHEL 9, private only, system-assigned managed identity
        leo-gateway-01  RHEL 9, public IP for HTTPS and administrative SSH

    Broker and Gateway are deliberately separate virtual machines.

    There is no Azure Bastion, no desktop subnet and no jump host. You reach
    the Gateway over SSH on its public IP, and the Broker by hopping through
    the Gateway. Lock AllowedClientCidrs down to your own egress IP.

    No secrets are stored in this repository. The VMs use SSH public-key
    authentication only.

.PARAMETER ConfigPath
    Path to poc.config.psd1. Defaults to ../config/poc.config.psd1.

.PARAMETER WhatIf
    Show what would be created without making changes.

.EXAMPLE
    ./Deploy-LeostreamPoC.ps1

.EXAMPLE
    ./Deploy-LeostreamPoC.ps1 -WhatIf -Verbose
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1'))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region helpers ---------------------------------------------------------------

function Write-Step {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Write-Ok {
    param([Parameter(Mandatory)][string] $Message)
    Write-Host "    $Message" -ForegroundColor DarkGray
}

function Import-PocConfig {
    param([Parameter(Mandatory)][string] $Path)

    $resolved = (Resolve-Path -Path $Path -ErrorAction Stop).Path
    $config = Import-PowerShellDataFile -Path $resolved
    if (-not $config.Azure -or -not $config.Network -or -not $config.VirtualMachines) {
        throw "Configuration file '$resolved' is missing required sections (Azure / Network / VirtualMachines)."
    }
    return $config
}

function Connect-PocAzure {
    param([string] $SubscriptionId)

    $context = Get-AzContext -ErrorAction SilentlyContinue
    if (-not $context) {
        Write-Step 'No Azure context found - launching interactive sign-in'
        Connect-AzAccount -ErrorAction Stop | Out-Null
        $context = Get-AzContext -ErrorAction Stop
    }

    if ($SubscriptionId -and $context.Subscription.Id -ne $SubscriptionId) {
        Write-Step "Selecting subscription $SubscriptionId"
        Set-AzContext -SubscriptionId $SubscriptionId -ErrorAction Stop | Out-Null
        $context = Get-AzContext -ErrorAction Stop
    }

    Write-Ok "Subscription: $($context.Subscription.Name) ($($context.Subscription.Id))"
    return $context
}

#endregion --------------------------------------------------------------------

$config = Import-PocConfig -Path $ConfigPath

$rgName   = $config.Azure.ResourceGroupName
$location = $config.Azure.Location
$tags     = $config.Azure.Tags
$net      = $config.Network

Connect-PocAzure -SubscriptionId $config.Azure.SubscriptionId | Out-Null

# --- SSH public key -----------------------------------------------------------
$sshKeyPath = $config.Admin.SshPublicKeyPath
if ($sshKeyPath -like '~*') {
    $sshKeyPath = Join-Path $HOME ($sshKeyPath.TrimStart('~', '/', '\'))
}
if (-not (Test-Path -Path $sshKeyPath)) {
    throw "SSH public key not found at '$sshKeyPath'. Generate one with: ssh-keygen -t ed25519 -C leostream-poc"
}
$sshPublicKey = (Get-Content -Path $sshKeyPath -Raw).Trim()
Write-Ok "Using SSH public key: $sshKeyPath"

#region resource group --------------------------------------------------------

Write-Step "Resource group '$rgName' in $location"
$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($PSCmdlet.ShouldProcess($rgName, 'Create resource group')) {
        New-AzResourceGroup -Name $rgName -Location $location -Tag $tags | Out-Null
        Write-Ok 'Created.'
    }
}
else {
    Write-Ok 'Already exists.'
}

#endregion

#region network security group ------------------------------------------------

Write-Step "Network security group '$($net.NsgName)'"

$allowedClients = @($config.AllowedClientCidrs)
if ($allowedClients -contains '0.0.0.0/0') {
    Write-Warning 'AllowedClientCidrs contains 0.0.0.0/0 - the Gateway will accept HTTPS and SSH from the whole internet. Narrow this in config/poc.config.psd1.'
    $allowedClients = @('Internet')
}

# Only these two rules are needed. Azure's default rules already allow all
# traffic within the virtual network (Gateway to Broker) and deny everything
# else inbound from the internet.
$rules = @(
    New-AzNetworkSecurityRuleConfig `
        -Name 'Allow-HTTPS-Inbound' `
        -Description 'Leostream Gateway HTTPS and remote viewer traffic' `
        -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $allowedClients -SourcePortRange '*' `
        -DestinationAddressPrefix $net.SubnetPrefix -DestinationPortRange '443'

    New-AzNetworkSecurityRuleConfig `
        -Name 'Allow-SSH-Inbound' `
        -Description 'Administrative SSH to the Gateway (the Broker has no public IP)' `
        -Priority 110 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $allowedClients -SourcePortRange '*' `
        -DestinationAddressPrefix $net.SubnetPrefix -DestinationPortRange '22'
)

$nsg = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $net.NsgName -ErrorAction SilentlyContinue
if ($nsg) {
    Write-Ok 'Already exists - updating rules.'
    if ($PSCmdlet.ShouldProcess($net.NsgName, 'Update network security group')) {
        $nsg.SecurityRules.Clear()
        foreach ($rule in $rules) { $nsg.SecurityRules.Add($rule) }
        $nsg = Set-AzNetworkSecurityGroup -NetworkSecurityGroup $nsg
    }
}
elseif ($PSCmdlet.ShouldProcess($net.NsgName, 'Create network security group')) {
    $nsg = New-AzNetworkSecurityGroup `
        -ResourceGroupName $rgName `
        -Name $net.NsgName `
        -Location $location `
        -Tag $tags `
        -SecurityRule $rules
    Write-Ok 'Created.'
}

#endregion

#region virtual network -------------------------------------------------------

Write-Step "Virtual network '$($net.VNetName)' with subnet '$($net.SubnetName)'"

$vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $net.VNetName -ErrorAction SilentlyContinue
if (-not $vnet) {
    if ($PSCmdlet.ShouldProcess($net.VNetName, 'Create virtual network')) {
        $subnetConfig = New-AzVirtualNetworkSubnetConfig `
            -Name $net.SubnetName `
            -AddressPrefix $net.SubnetPrefix `
            -NetworkSecurityGroup $nsg

        $vnet = New-AzVirtualNetwork `
            -ResourceGroupName $rgName `
            -Name $net.VNetName `
            -Location $location `
            -AddressPrefix $net.AddressSpace `
            -Subnet $subnetConfig `
            -Tag $tags
        Write-Ok 'Created.'
    }
}
else {
    Write-Ok 'Already exists.'
}

if (-not $vnet) {
    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'WhatIf: the virtual network does not exist yet, so the virtual machines cannot be previewed.' -ForegroundColor Yellow
        Write-Host 'WhatIf: they would be created as leo-broker-01 and leo-gateway-01.' -ForegroundColor Yellow
        return
    }
    throw "Virtual network '$($net.VNetName)' could not be created or retrieved."
}

$subnet = $vnet.Subnets | Where-Object { $_.Name -eq $net.SubnetName }
if (-not $subnet) { throw "Subnet '$($net.SubnetName)' not found in VNet '$($vnet.Name)'." }
$subnetId = $subnet.Id

#endregion

#region virtual machines ------------------------------------------------------

function New-PocVirtualMachine {
    [CmdletBinding(SupportsShouldProcess = $true)]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute(
        'PSAvoidUsingConvertToSecureStringWithPlainText', '',
        Justification = 'Set-AzVMOperatingSystem -Linux requires a PSCredential even when password authentication is disabled. A random, never-used value is supplied; the VM accepts SSH keys only.')]
    param(
        [Parameter(Mandatory)][hashtable] $Spec,
        [Parameter(Mandatory)][string]    $SubnetId,
        [Parameter(Mandatory)][string]    $SshKey
    )

    $vmName = $Spec.Name

    $existing = Get-AzVM -ResourceGroupName $rgName -Name $vmName -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "VM '$vmName' already exists - skipping."
        return $existing
    }

    # ---- public IP (Gateway only) -------------------------------------------
    $publicIp = $null
    if ($Spec.PublicIp) {
        $pipName = $Spec.PublicIpName
        $publicIp = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $pipName -ErrorAction SilentlyContinue
        if (-not $publicIp -and $PSCmdlet.ShouldProcess($pipName, 'Create public IP')) {
            $pipParams = @{
                ResourceGroupName = $rgName
                Name              = $pipName
                Location          = $location
                AllocationMethod  = 'Static'
                Sku               = 'Standard'
                Tag               = $tags
            }
            if ($Spec.ContainsKey('DnsLabelPrefix') -and $Spec.DnsLabelPrefix) {
                $pipParams['DomainNameLabel'] = $Spec.DnsLabelPrefix
            }
            $publicIp = New-AzPublicIpAddress @pipParams
        }
    }

    # ---- NIC -----------------------------------------------------------------
    $nicName = "nic-$vmName"
    $nic = Get-AzNetworkInterface -ResourceGroupName $rgName -Name $nicName -ErrorAction SilentlyContinue
    if (-not $nic -and $PSCmdlet.ShouldProcess($nicName, 'Create network interface')) {
        $nicParams = @{
            ResourceGroupName = $rgName
            Name              = $nicName
            Location          = $location
            SubnetId          = $SubnetId
            PrivateIpAddress  = $Spec.PrivateIp
            Tag               = $tags
        }
        if ($publicIp) { $nicParams['PublicIpAddressId'] = $publicIp.Id }
        $nic = New-AzNetworkInterface @nicParams
    }

    if (-not $nic) { return $null }

    # ---- VM configuration ----------------------------------------------------
    $vmConfigParams = @{
        VMName = $vmName
        VMSize = $Spec.Size
    }
    if ($Spec.ManagedIdentity) {
        # The Broker authenticates to Azure with a system-assigned managed
        # identity, so no service-principal secret is ever needed.
        $vmConfigParams['IdentityType'] = 'SystemAssigned'
    }
    $vmConfig = New-AzVMConfig @vmConfigParams

    $placeholder = ConvertTo-SecureString -String ([guid]::NewGuid().ToString() + '!Aa1') -AsPlainText -Force
    $cred = [pscredential]::new($config.Admin.LinuxUsername, $placeholder)

    $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux `
        -ComputerName $vmName `
        -Credential $cred `
        -DisablePasswordAuthentication

    $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig `
        -KeyData $SshKey `
        -Path "/home/$($config.Admin.LinuxUsername)/.ssh/authorized_keys"

    $vmConfig = Set-AzVMSourceImage -VM $vmConfig `
        -PublisherName $Spec.Image.Publisher `
        -Offer $Spec.Image.Offer `
        -Skus $Spec.Image.Sku `
        -Version $Spec.Image.Version

    $vmConfig = Add-AzVMNetworkInterface -VM $vmConfig -Id $nic.Id

    $vmConfig = Set-AzVMOSDisk -VM $vmConfig `
        -Name "osdisk-$vmName" `
        -CreateOption FromImage `
        -StorageAccountType $Spec.OsDiskType `
        -DiskSizeInGB $Spec.OsDiskSizeGb

    $vmConfig = Set-AzVMBootDiagnostic -VM $vmConfig -Disable

    if ($PSCmdlet.ShouldProcess($vmName, 'Create virtual machine')) {
        Write-Ok "Creating VM '$vmName' ($($Spec.Size))."
        New-AzVM -ResourceGroupName $rgName -Location $location -VM $vmConfig -Tag $tags -ErrorAction Stop | Out-Null
        Write-Ok "VM '$vmName' created."
        return Get-AzVM -ResourceGroupName $rgName -Name $vmName
    }
}

Write-Step 'Virtual machines'

$brokerSpec  = $config.VirtualMachines.Broker
$gatewaySpec = $config.VirtualMachines.Gateway

if ($brokerSpec.Name -eq $gatewaySpec.Name) {
    throw 'Broker and Gateway must be deployed as separate virtual machines.'
}

New-PocVirtualMachine -Spec $brokerSpec  -SubnetId $subnetId -SshKey $sshPublicKey | Out-Null
New-PocVirtualMachine -Spec $gatewaySpec -SubnetId $subnetId -SshKey $sshPublicKey | Out-Null

#endregion

#region summary ---------------------------------------------------------------

Write-Step 'Deployment summary'

$gatewayPip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $gatewaySpec.PublicIpName -ErrorAction SilentlyContinue

$gatewayPublicIp = '(not provisioned)'
$gatewayFqdn     = '(none)'
if ($gatewayPip) {
    if ($gatewayPip.IpAddress) { $gatewayPublicIp = $gatewayPip.IpAddress }
    if ($gatewayPip.DnsSettings -and $gatewayPip.DnsSettings.Fqdn) { $gatewayFqdn = $gatewayPip.DnsSettings.Fqdn }
}

[pscustomobject]@{
    ResourceGroup    = $rgName
    Location         = $location
    VNet             = "$($net.VNetName) ($($net.AddressSpace))"
    Subnet           = "$($net.SubnetName) ($($net.SubnetPrefix))"
    BrokerPrivateIp  = $brokerSpec.PrivateIp
    GatewayPrivateIp = $gatewaySpec.PrivateIp
    GatewayPublicIp  = $gatewayPublicIp
    GatewayFqdn      = $gatewayFqdn
} | Format-List

$user = $config.Admin.LinuxUsername

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Green
Write-Host '  1. ./Configure-LeostreamAzureRBAC.ps1   # grant the Broker managed identity access'
Write-Host '  2. ./Install-LeostreamBroker.ps1        # install Leostream Platform 26 on leo-broker-01'
Write-Host '  3. ./Install-LeostreamGateway.ps1       # install the Leostream Gateway on leo-gateway-01'
Write-Host '  4. ./Test-LeostreamPoC.ps1              # validate the deployment'
Write-Host ''
Write-Host 'Administrative access:' -ForegroundColor Green
Write-Host "  Gateway shell : ssh $user@$gatewayPublicIp"
Write-Host "  Broker shell  : ssh -J $user@$gatewayPublicIp $user@$($brokerSpec.PrivateIp)"
Write-Host "  Broker web UI : ssh -L 8443:$($brokerSpec.PrivateIp):443 $user@$gatewayPublicIp"
Write-Host '                  then browse to https://localhost:8443/'

#endregion
