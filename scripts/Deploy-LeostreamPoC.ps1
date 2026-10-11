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
    # Name the exact private-key path the config implies. A generic ssh-keygen
    # line would create a differently named key and fail this check again.
    $privateKeyPath = $sshKeyPath -replace '\.pub$', ''
    throw "SSH public key not found at '$sshKeyPath'. Generate the pair with: ssh-keygen -t rsa -b 4096 -C `"leostream-poc`" -f `"$privateKeyPath`""
}
$sshPublicKey = (Get-Content -Path $sshKeyPath -Raw).Trim()

# Azure rejects a malformed key with the opaque message "The value of parameter
# linuxConfiguration.ssh.publicKeys.keyData is invalid", naming neither the file
# nor what is wrong with it. Everything below is checked locally so the failure
# names the actual problem instead.
$hint = "Admin.SshPublicKeyPath in config/poc.config.psd1 currently points at '$sshKeyPath'."
if ($sshPublicKey -match '-----BEGIN .*PRIVATE KEY-----') {
    throw "'$sshKeyPath' is a PRIVATE key, not a public one. Azure needs the public half - the same path with a .pub suffix. $hint"
}
if ($sshPublicKey -match '^PuTTY-User-Key-File') {
    throw "'$sshKeyPath' is in PuTTY .ppk format, which Azure does not accept. Export it with PuTTYgen (Conversions > Export OpenSSH key) or convert the public half with: ssh-keygen -i -f '$sshKeyPath'. $hint"
}
if ([string]::IsNullOrWhiteSpace($sshPublicKey)) {
    throw "'$sshKeyPath' is empty. $hint"
}
# A valid OpenSSH public key is one line: "<type> <base64> [comment]".
$keyFields = $sshPublicKey -split '\s+'
$validTypes = @('ssh-rsa', 'ssh-ed25519', 'ecdsa-sha2-nistp256', 'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521')
if ($sshPublicKey -match '\r|\n') {
    throw "'$sshKeyPath' contains more than one line. An OpenSSH public key is a single line. $hint"
}
if ($keyFields.Count -lt 2 -or $validTypes -notcontains $keyFields[0]) {
    throw "'$sshKeyPath' does not look like an OpenSSH public key. Expected it to start with one of: $($validTypes -join ', '). It starts with '$($keyFields[0])'. $hint"
}
try { [Convert]::FromBase64String($keyFields[1]) | Out-Null }
catch { throw "The key body in '$sshKeyPath' is not valid base64, so Azure will reject it. Regenerate the key pair. $hint" }

Write-Ok "Using SSH public key: $sshKeyPath ($($keyFields[0]))"

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

# Leostream also documents inbound 80, which serves the HTTP-to-HTTPS redirect
# on the admin interface and lets certbot answer an ACME http-01 challenge when
# you replace the self-signed certificate. Neither is needed for this PoC - the
# admin UI is reached over an SSH tunnel on 443 - so it stays opt-in.
if ($config.Ports.Contains('Http') -and $config.Ports.Http) {
    $rules += New-AzNetworkSecurityRuleConfig `
        -Name 'Allow-HTTP-Inbound' `
        -Description 'HTTP-to-HTTPS redirect and ACME http-01 certificate challenges' `
        -Priority 120 -Direction Inbound -Access Allow -Protocol Tcp `
        -SourceAddressPrefix $allowedClients -SourcePortRange '*' `
        -DestinationAddressPrefix $net.SubnetPrefix -DestinationPortRange "$($config.Ports.Http)"
}

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

#region NAT gateway -----------------------------------------------------------

# The Broker has no public IP. Azure retired default outbound access on
# 30 September 2025, so without this the Broker cannot reach the package
# repositories and Install-LeostreamBroker.ps1 fails on repository timeouts.
# A NAT gateway is outbound-only, so the Broker stays unreachable from outside.
$natGateway = $null
$natEnabled = $net.Contains('NatGatewayEnabled') -and $net.NatGatewayEnabled
if ($natEnabled) {
    Write-Step "NAT gateway '$($net.NatGatewayName)' for outbound access"

    $natPip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $net.NatGatewayPublicIp -ErrorAction SilentlyContinue
    if (-not $natPip -and $PSCmdlet.ShouldProcess($net.NatGatewayPublicIp, 'Create NAT gateway public IP')) {
        # A NAT gateway requires a Standard SKU, statically allocated address.
        $natPip = New-AzPublicIpAddress `
            -ResourceGroupName $rgName `
            -Name $net.NatGatewayPublicIp `
            -Location $location `
            -AllocationMethod Static `
            -Sku Standard `
            -Tag $tags
        Write-Ok 'Public IP created.'
    }
    elseif ($natPip) {
        Write-Ok 'Public IP already exists.'
    }

    $natGateway = Get-AzNatGateway -ResourceGroupName $rgName -Name $net.NatGatewayName -ErrorAction SilentlyContinue
    if (-not $natGateway -and $natPip -and $PSCmdlet.ShouldProcess($net.NatGatewayName, 'Create NAT gateway')) {
        $natGateway = New-AzNatGateway `
            -ResourceGroupName $rgName `
            -Name $net.NatGatewayName `
            -Location $location `
            -Sku Standard `
            -PublicIpAddress $natPip `
            -IdleTimeoutInMinutes $net.NatGatewayIdleMinutes `
            -Tag $tags
        Write-Ok 'Created.'
    }
    elseif ($natGateway) {
        Write-Ok 'Already exists.'
    }
}

#endregion

#region virtual network -------------------------------------------------------

Write-Step "Virtual network '$($net.VNetName)' with subnet '$($net.SubnetName)'"

$vnet = Get-AzVirtualNetwork -ResourceGroupName $rgName -Name $net.VNetName -ErrorAction SilentlyContinue
if (-not $vnet) {
    if ($PSCmdlet.ShouldProcess($net.VNetName, 'Create virtual network')) {
        $subnetParams = @{
            Name                 = $net.SubnetName
            AddressPrefix        = $net.SubnetPrefix
            NetworkSecurityGroup = $nsg
        }
        if ($natGateway) { $subnetParams['NatGateway'] = $natGateway }
        $subnetConfig = New-AzVirtualNetworkSubnetConfig @subnetParams

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

    # Attach the NAT gateway to a subnet that predates it, so an existing
    # deployment gains outbound access without being torn down.
    if ($natGateway) {
        $existingSubnet = $vnet.Subnets | Where-Object { $_.Name -eq $net.SubnetName }
        $attachedId = $null
        if ($existingSubnet -and $existingSubnet.NatGateway) { $attachedId = $existingSubnet.NatGateway.Id }

        if ($existingSubnet -and $attachedId -ne $natGateway.Id) {
            if ($PSCmdlet.ShouldProcess($net.SubnetName, 'Attach NAT gateway to subnet')) {
                $existingSubnet.NatGateway = $natGateway
                $vnet = Set-AzVirtualNetwork -VirtualNetwork $vnet
                Write-Ok "NAT gateway attached to subnet '$($net.SubnetName)'."
            }
        }
        elseif ($attachedId) {
            Write-Ok 'NAT gateway already attached to the subnet.'
        }
    }
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

$user      = $config.Admin.LinuxUsername
$brokerIp  = $brokerSpec.PrivateIp
$key       = $config.Admin.SshPublicKeyPath -replace '^~', $HOME -replace '\.pub$', ''

# A redeployment into a retained resource group inherits the Azure Center's role
# assignment, which is the one part of this PoC you may have needed someone else
# to create. Say so explicitly, so it is obvious whether a second request to an
# administrator is needed.
$centerName = 'leostream-poc-azure-center'
if ($config.ContainsKey('AzureCenter') -and $config.AzureCenter.AppDisplayName) {
    $centerName = $config.AzureCenter.AppDisplayName
}
$centerApp = Get-AzADApplication -DisplayName $centerName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($centerApp) {
    $centerSp = Get-AzADServicePrincipal -ApplicationId $centerApp.AppId -ErrorAction SilentlyContinue
    $centerRole = 'Contributor'
    if ($config.AzureCenter.ContainsKey('RoleName') -and $config.AzureCenter.RoleName) {
        $centerRole = $config.AzureCenter.RoleName
    }

    Write-Host ''
    Write-Host "Azure Center application '$centerName' already exists ($($centerApp.AppId))." -ForegroundColor Green

    if ($centerSp) {
        $held = @(Get-AzRoleAssignment -ObjectId $centerSp.Id -ErrorAction SilentlyContinue |
            Where-Object { $_.RoleDefinitionName -eq $centerRole })
        if ($held.Count -gt 0) {
            Write-Host "  '$centerRole' is still assigned at $($held[0].Scope)." -ForegroundColor Green
            Write-Host '  Nothing to re-request - reuse the existing client secret in the Center.' -ForegroundColor DarkGray
        }
        else {
            Write-Host "  No '$centerRole' assignment found for its service principal." -ForegroundColor Yellow
            Write-Host '  Run ./Configure-LeostreamAzureCenter.ps1 to assign it, or to print the' -ForegroundColor Yellow
            Write-Host '  command for an administrator.' -ForegroundColor Yellow
        }
    }
}

Write-Host ''
Write-Host 'Next steps:' -ForegroundColor Green
Write-Host '  1. ./Install-LeostreamBroker.ps1        # install Leostream Platform 26 on leo-broker-01'
Write-Host '  2. ./Install-LeostreamGateway.ps1       # install the Leostream Gateway on leo-gateway-01'
Write-Host '  3. ./Test-LeostreamPoC.ps1              # validate the deployment'
Write-Host ''
Write-Host 'Administrative access (run on this PC, not inside a VM):' -ForegroundColor Green
Write-Host "  Gateway shell : ssh -i `"$key`" $user@$gatewayPublicIp"
$proxyOpt = '-o "ProxyCommand=ssh -i `"' + $key + '`" -W %h:%p ' + "$user@$gatewayPublicIp" + '"'
Write-Host "  Broker shell  : ssh -i `"$key`" $proxyOpt $user@$brokerIp"
Write-Host "  Broker web UI : ssh -i `"$key`" -L 8443:${brokerIp}:443 $user@$gatewayPublicIp"
Write-Host '                  then browse to https://localhost:8443/'
Write-Host ''
Write-Host '  The Broker command avoids "-J" on purpose: with -J the -i key is not' -ForegroundColor DarkGray
Write-Host '  offered to the Gateway, so the hop is refused. See the README section' -ForegroundColor DarkGray
Write-Host '  "Administrative access" for a tidier ~/.ssh/config alternative.' -ForegroundColor DarkGray

#endregion
