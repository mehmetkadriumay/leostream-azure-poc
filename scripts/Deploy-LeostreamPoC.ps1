#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Resources, Az.Network, Az.Compute

<#
.SYNOPSIS
    Deploys the Azure infrastructure for a Leostream Platform 26 proof of concept.

.DESCRIPTION
    Creates (idempotently) the resource group, virtual network, subnets, network
    security groups, optional Azure Bastion host and three virtual machines:

        leo-broker-01   RHEL 9     private only, system-assigned managed identity
        leo-gateway-01  RHEL 9     public HTTPS endpoint
        leo-win-01      Windows 11 private only

    Broker and Gateway are deliberately separate virtual machines.

    No secrets are stored in this repository. The Windows administrator password
    is supplied as a SecureString parameter (or prompted for), and the Linux VMs
    use SSH public-key authentication only.

.PARAMETER ConfigPath
    Path to poc.config.psd1. Defaults to ../config/poc.config.psd1.

.PARAMETER WindowsAdminPassword
    SecureString password for the local administrator on leo-win-01.
    If omitted you are prompted interactively.

.PARAMETER SkipBastion
    Do not deploy the Azure Bastion host (saves cost; you then need another
    administrative path to the private VMs).

.PARAMETER WhatIf
    Show what would be created without making changes.

.EXAMPLE
    ./Deploy-LeostreamPoC.ps1

.EXAMPLE
    $pw = Read-Host -AsSecureString 'Windows admin password'
    ./Deploy-LeostreamPoC.ps1 -WindowsAdminPassword $pw -Verbose
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),

    [securestring] $WindowsAdminPassword,

    [switch] $SkipBastion
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

# --- Windows password ---------------------------------------------------------
if (-not $WindowsAdminPassword) {
    $WindowsAdminPassword = Read-Host -Prompt "Local administrator password for $($config.VirtualMachines.WindowsDesktop.Name)" -AsSecureString
}
if (-not $WindowsAdminPassword -or $WindowsAdminPassword.Length -eq 0) {
    throw 'A Windows administrator password is required.'
}

#region resource group --------------------------------------------------------

Write-Step "Resource group '$rgName' in $location"
$rg = Get-AzResourceGroup -Name $rgName -ErrorAction SilentlyContinue
if (-not $rg) {
    if ($PSCmdlet.ShouldProcess($rgName, 'Create resource group')) {
        $rg = New-AzResourceGroup -Name $rgName -Location $location -Tag $tags
        Write-Ok 'Created.'
    }
}
else {
    Write-Ok 'Already exists.'
}

#endregion

#region network security groups ----------------------------------------------

function New-PocNsgRule {
    param(
        [Parameter(Mandatory)][string]   $Name,
        [Parameter(Mandatory)][int]      $Priority,
        [Parameter(Mandatory)][string]   $Direction,
        [Parameter(Mandatory)][string]   $Access,
        [Parameter(Mandatory)][string]   $Protocol,
        [Parameter(Mandatory)][string[]] $SourceAddressPrefix,
        [Parameter(Mandatory)][string[]] $SourcePortRange,
        [Parameter(Mandatory)][string[]] $DestinationAddressPrefix,
        [Parameter(Mandatory)][string[]] $DestinationPortRange,
        [string] $Description = ''
    )

    New-AzNetworkSecurityRuleConfig `
        -Name $Name `
        -Description $Description `
        -Priority $Priority `
        -Direction $Direction `
        -Access $Access `
        -Protocol $Protocol `
        -SourceAddressPrefix $SourceAddressPrefix `
        -SourcePortRange $SourcePortRange `
        -DestinationAddressPrefix $DestinationAddressPrefix `
        -DestinationPortRange $DestinationPortRange
}

function Set-PocNetworkSecurityGroup {
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][object[]] $Rules
    )

    $existing = Get-AzNetworkSecurityGroup -ResourceGroupName $rgName -Name $Name -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Ok "NSG '$Name' exists - updating rules."
        if ($PSCmdlet.ShouldProcess($Name, 'Update network security group')) {
            $existing.SecurityRules.Clear()
            foreach ($rule in $Rules) { $existing.SecurityRules.Add($rule) }
            return Set-AzNetworkSecurityGroup -NetworkSecurityGroup $existing
        }
        return $existing
    }

    if ($PSCmdlet.ShouldProcess($Name, 'Create network security group')) {
        Write-Ok "Creating NSG '$Name'."
        return New-AzNetworkSecurityGroup `
            -ResourceGroupName $rgName `
            -Name $Name `
            -Location $location `
            -Tag $tags `
            -SecurityRules $Rules
    }
}

$allowedClients = @($config.AllowedClientCidrs)
if ($allowedClients -contains '0.0.0.0/0') {
    Write-Warning 'AllowedClientCidrs contains 0.0.0.0/0 - the Gateway HTTPS endpoint will be reachable from the whole internet. Narrow this in config/poc.config.psd1 for anything beyond a short-lived PoC.'
    $allowedClients = @('Internet')
}

$gwSubnet   = $config.Network.Subnets.Gateway
$infraSubnet = $config.Network.Subnets.Infrastructure
$deskSubnet = $config.Network.Subnets.Desktop

Write-Step 'Network security groups'

$gatewayRules = @(
    New-PocNsgRule -Name 'Allow-HTTPS-Inbound' -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $allowedClients -SourcePortRange '*' `
        -DestinationAddressPrefix $gwSubnet.AddressPrefix -DestinationPortRange @('443') `
        -Description 'Leostream Gateway HTTPS / remote viewer traffic'
    New-PocNsgRule -Name 'Allow-Bastion-SSH' -Priority 200 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $config.Network.Subnets.Bastion.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $gwSubnet.AddressPrefix -DestinationPortRange @('22') `
        -Description 'Administrative SSH from Azure Bastion only'
    New-PocNsgRule -Name 'Deny-All-Inbound' -Priority 4000 -Direction Inbound -Access Deny -Protocol '*' `
        -SourceAddressPrefix '*' -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange '*' `
        -Description 'Explicit deny after allow rules'
)

$infraRules = @(
    New-PocNsgRule -Name 'Allow-Gateway-To-Broker-HTTPS' -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $gwSubnet.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $infraSubnet.AddressPrefix -DestinationPortRange @('443') `
        -Description 'Gateway to Broker web services'
    New-PocNsgRule -Name 'Allow-Desktop-To-Broker-HTTPS' -Priority 110 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $deskSubnet.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $infraSubnet.AddressPrefix -DestinationPortRange @('443') `
        -Description 'Leostream Agent check-in from desktops'
    New-PocNsgRule -Name 'Allow-Bastion-Admin' -Priority 200 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $config.Network.Subnets.Bastion.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $infraSubnet.AddressPrefix -DestinationPortRange @('22', '443') `
        -Description 'Administrative access from Azure Bastion'
    New-PocNsgRule -Name 'Deny-All-Inbound' -Priority 4000 -Direction Inbound -Access Deny -Protocol '*' `
        -SourceAddressPrefix '*' -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange '*' `
        -Description 'Explicit deny after allow rules'
)

$desktopRules = @(
    New-PocNsgRule -Name 'Allow-Gateway-RDP' -Priority 100 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $gwSubnet.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $deskSubnet.AddressPrefix -DestinationPortRange @('3389') `
        -Description 'RDP proxied through the Leostream Gateway'
    New-PocNsgRule -Name 'Allow-Broker-Agent' -Priority 110 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $infraSubnet.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $deskSubnet.AddressPrefix -DestinationPortRange @('443', '8080') `
        -Description 'Broker to Leostream Agent communication'
    New-PocNsgRule -Name 'Allow-Bastion-RDP' -Priority 200 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $config.Network.Subnets.Bastion.AddressPrefix -SourcePortRange '*' `
        -DestinationAddressPrefix $deskSubnet.AddressPrefix -DestinationPortRange @('3389') `
        -Description 'Administrative RDP from Azure Bastion'
    New-PocNsgRule -Name 'Deny-All-Inbound' -Priority 4000 -Direction Inbound -Access Deny -Protocol '*' `
        -SourceAddressPrefix '*' -SourcePortRange '*' `
        -DestinationAddressPrefix '*' -DestinationPortRange '*' `
        -Description 'Explicit deny after allow rules'
)

$nsgGateway = Set-PocNetworkSecurityGroup -Name $gwSubnet.NsgName    -Rules $gatewayRules
$nsgInfra   = Set-PocNetworkSecurityGroup -Name $infraSubnet.NsgName -Rules $infraRules
$nsgDesktop = Set-PocNetworkSecurityGroup -Name $deskSubnet.NsgName  -Rules $desktopRules

#endregion

#region virtual network -------------------------------------------------------

Write-Step "Virtual network '$($config.Network.VNetName)'"

$subnetConfigs = @(
    New-AzVirtualNetworkSubnetConfig -Name $gwSubnet.Name          -AddressPrefix $gwSubnet.AddressPrefix          -NetworkSecurityGroup $nsgGateway
    New-AzVirtualNetworkSubnetConfig -Name $infraSubnet.Name       -AddressPrefix $infraSubnet.AddressPrefix       -NetworkSecurityGroup $nsgInfra
    New-AzVirtualNetworkSubnetConfig -Name $deskSubnet.Name        -AddressPrefix $deskSubnet.AddressPrefix        -NetworkSecurityGroup $nsgDesktop
    New-AzVirtualNetworkSubnetConfig -Name $config.Network.Subnets.Bastion.Name -AddressPrefix $config.Network.Subnets.Bastion.AddressPrefix
)

$vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $config.Network.VNetName -ErrorAction SilentlyContinue
if (-not $vnet) {
    if ($PSCmdlet.ShouldProcess($config.Network.VNetName, 'Create virtual network')) {
        $vnet = New-AzVirtualNetwork `
            -ResourceGroupName $rgName `
            -Name $config.Network.VNetName `
            -Location $location `
            -AddressPrefix $config.Network.AddressSpace `
            -Subnet $subnetConfigs `
            -Tag $tags
        Write-Ok 'Created.'
    }
}
else {
    Write-Ok 'Already exists - verifying subnets.'
    $changed = $false
    foreach ($sc in $subnetConfigs) {
        $current = $vnet.Subnets | Where-Object { $_.Name -eq $sc.Name }
        if (-not $current) {
            $vnet.Subnets.Add($sc)
            $changed = $true
            Write-Ok "Adding missing subnet '$($sc.Name)'."
        }
    }
    if ($changed -and $PSCmdlet.ShouldProcess($vnet.Name, 'Update virtual network')) {
        $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
    }
}

if (-not $vnet) {
    if ($WhatIfPreference) {
        Write-Host ''
        Write-Host 'WhatIf: the virtual network does not exist yet, so the virtual machines cannot be previewed.' -ForegroundColor Yellow
        Write-Host 'WhatIf: they would be created as leo-broker-01, leo-gateway-01 and leo-win-01.' -ForegroundColor Yellow
        return
    }
    throw "Virtual network '$($config.Network.VNetName)' could not be created or retrieved."
}

function Get-PocSubnetId {
    param([Parameter(Mandatory)][string] $SubnetKey)
    $name = $config.Network.Subnets[$SubnetKey].Name
    $subnet = $vnet.Subnets | Where-Object { $_.Name -eq $name }
    if (-not $subnet) { throw "Subnet '$name' not found in VNet '$($vnet.Name)'." }
    return $subnet.Id
}

#endregion

#region bastion ---------------------------------------------------------------

if ($config.Bastion.Enabled -and -not $SkipBastion) {
    Write-Step "Azure Bastion '$($config.Bastion.Name)'"

    $bastion = Get-AzBastion -ResourceGroupName $rgName -Name $config.Bastion.Name -ErrorAction SilentlyContinue
    if (-not $bastion) {
        $bastionPip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $config.Bastion.PublicIpName -ErrorAction SilentlyContinue
        if (-not $bastionPip -and $PSCmdlet.ShouldProcess($config.Bastion.PublicIpName, 'Create Bastion public IP')) {
            $bastionPip = New-AzPublicIpAddress `
                -ResourceGroupName $rgName `
                -Name $config.Bastion.PublicIpName `
                -Location $location `
                -AllocationMethod Static `
                -Sku Standard `
                -Tag $tags
        }

        if ($PSCmdlet.ShouldProcess($config.Bastion.Name, 'Create Azure Bastion (takes 10+ minutes)')) {
            Write-Ok 'Creating Bastion host - this typically takes 10 to 20 minutes.'
            New-AzBastion `
                -ResourceGroupName $rgName `
                -Name $config.Bastion.Name `
                -PublicIpAddress $bastionPip `
                -VirtualNetwork $vnet `
                -Sku $config.Bastion.Sku `
                -ErrorAction Stop | Out-Null
            Write-Ok 'Created.'
        }
    }
    else {
        Write-Ok 'Already exists.'
    }
}
else {
    Write-Ok 'Bastion deployment skipped.'
}

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
        [securestring] $WindowsPassword,
        [string] $SshKey
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
            ResourceGroupName              = $rgName
            Name                           = $nicName
            Location                       = $location
            SubnetId                       = $SubnetId
            PrivateIpAddress               = $Spec.PrivateIp
            Tag                            = $tags
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

    if ($Spec.OsType -eq 'Linux') {
        $placeholder = ConvertTo-SecureString -String ([guid]::NewGuid().ToString() + '!Aa1') -AsPlainText -Force
        $cred = [pscredential]::new($config.Admin.LinuxUsername, $placeholder)

        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Linux `
            -ComputerName $vmName `
            -Credential $cred `
            -DisablePasswordAuthentication

        $vmConfig = Add-AzVMSshPublicKey -VM $vmConfig `
            -KeyData $SshKey `
            -Path "/home/$($config.Admin.LinuxUsername)/.ssh/authorized_keys"
    }
    else {
        $cred = [pscredential]::new($config.Admin.WindowsUsername, $WindowsPassword)
        $vmConfig = Set-AzVMOperatingSystem -VM $vmConfig -Windows `
            -ComputerName $vmName `
            -Credential $cred `
            -ProvisionVMAgent `
            -EnableAutoUpdate
    }

    # Windows 11 marketplace images are Gen2 and require Trusted Launch.
    if ($Spec.ContainsKey('SecurityType') -and $Spec.SecurityType -eq 'TrustedLaunch') {
        $vmConfig = Set-AzVMSecurityProfile -VM $vmConfig -SecurityType 'TrustedLaunch'
        $vmConfig = Set-AzVMUefi -VM $vmConfig -EnableVtpm $true -EnableSecureBoot $true
    }

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
        Write-Ok "Creating VM '$vmName' ($($Spec.OsType), $($Spec.Size))."
        New-AzVM -ResourceGroupName $rgName -Location $location -VM $vmConfig -Tag $tags -ErrorAction Stop | Out-Null
        Write-Ok "VM '$vmName' created."
        return Get-AzVM -ResourceGroupName $rgName -Name $vmName
    }
}

Write-Step 'Virtual machines'

$brokerSpec  = $config.VirtualMachines.Broker
$gatewaySpec = $config.VirtualMachines.Gateway
$winSpec     = $config.VirtualMachines.WindowsDesktop

if ($brokerSpec.Name -eq $gatewaySpec.Name) {
    throw 'Broker and Gateway must be deployed as separate virtual machines.'
}

New-PocVirtualMachine -Spec $brokerSpec  -SubnetId (Get-PocSubnetId $brokerSpec.Subnet)  -SshKey $sshPublicKey | Out-Null
New-PocVirtualMachine -Spec $gatewaySpec -SubnetId (Get-PocSubnetId $gatewaySpec.Subnet) -SshKey $sshPublicKey | Out-Null
New-PocVirtualMachine -Spec $winSpec     -SubnetId (Get-PocSubnetId $winSpec.Subnet)     -WindowsPassword $WindowsAdminPassword | Out-Null

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
    VNet             = $config.Network.VNetName
    BrokerPrivateIp  = $brokerSpec.PrivateIp
    GatewayPrivateIp = $gatewaySpec.PrivateIp
    GatewayPublicIp  = $gatewayPublicIp
    GatewayFqdn      = $gatewayFqdn
    WindowsPrivateIp = $winSpec.PrivateIp
    BastionDeployed  = ($config.Bastion.Enabled -and -not $SkipBastion)
} | Format-List

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Green
Write-Host '  1. ./Configure-LeostreamAzureRBAC.ps1   # grant the Broker managed identity access'
Write-Host '  2. ./Install-LeostreamBroker.ps1        # install Leostream Platform 26 on leo-broker-01'
Write-Host '  3. ./Install-LeostreamGateway.ps1       # install the Leostream Gateway on leo-gateway-01'
Write-Host '  4. ./Install-LeostreamAgent.ps1         # install the Leostream Agent on leo-win-01'
Write-Host '  5. ./Test-LeostreamPoC.ps1              # validate the deployment'

#endregion
