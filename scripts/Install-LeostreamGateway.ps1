#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute, Az.Network

<#
.SYNOPSIS
    Prepares leo-gateway-01 (RHEL 9) and installs the Leostream Gateway.

.DESCRIPTION
    Uses the Azure RunCommand extension to configure the Gateway VM:
      * OS prerequisites and time synchronisation
      * firewalld: 443/tcp open to the internet, SSH restricted to the VNet
      * kernel forwarding settings required by the Leostream Gateway
      * downloads and runs the Leostream Gateway installer from a URI you supply
      * points the Gateway at the Broker's private address

    No installers, certificates or licence material are stored in this
    repository.

.PARAMETER InstallerUri
    HTTPS URI of the Leostream Gateway installer.

.PARAMETER BrokerAddress
    Private IP or DNS name of the Broker. Defaults to the value in poc.config.psd1.

.EXAMPLE
    ./Install-LeostreamGateway.ps1 -InstallerUri 'https://<your-portal>/leostream-gateway.sh'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'poc.config.psd1'),

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string] $InstallerUri,

    [string] $BrokerAddress,

    [switch] $SkipOsUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName
$spec   = $config.VirtualMachines.Gateway

if (-not $BrokerAddress) { $BrokerAddress = $config.VirtualMachines.Broker.PrivateIp }

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}

$vm = Get-AzVM -ResourceGroupName $rgName -Name $spec.Name -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$($spec.Name)' not found in resource group '$rgName'. Run Deploy-LeostreamPoC.ps1 first."
}

$updateCmd = if ($SkipOsUpdate) { 'echo "skipping OS update"' } else { 'dnf -y update' }

$template = @'
#!/bin/bash
set -euo pipefail

echo '=== Leostream Gateway preparation ==='

__OS_UPDATE__
dnf -y install firewalld chrony curl tar ca-certificates policycoreutils-python-utils

systemctl enable --now chronyd
systemctl enable --now firewalld

echo '--- setting hostname ---'
hostnamectl set-hostname '__VM_NAME__'

echo '--- kernel settings for the gateway ---'
cat >/etc/sysctl.d/99-leostream-gateway.conf <<'SYSCTL'
net.ipv4.ip_forward = 1
net.core.somaxconn = 4096
net.ipv4.ip_local_port_range = 10000 65000
SYSCTL
sysctl --system >/dev/null

echo '--- configuring firewall ---'
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=443/tcp
# SSH only from inside the virtual network
firewall-cmd --permanent --remove-service=ssh || true
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=__VNET_CIDR__ service name=ssh accept"
firewall-cmd --reload

INSTALLER_URI='__INSTALLER_URI__'
WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo '--- downloading Leostream Gateway installer ---'
curl -fsSL -o leostream-gateway-installer "$INSTALLER_URI"
chmod +x leostream-gateway-installer

echo '--- running installer ---'
if head -c 2 leostream-gateway-installer | grep -q '#!' ; then
    ./leostream-gateway-installer
else
    dnf -y install ./leostream-gateway-installer
fi

echo '--- recording broker address ---'
mkdir -p /etc/leostream
echo 'broker_address=__BROKER_ADDRESS__' > /etc/leostream/gateway.conf
chmod 0640 /etc/leostream/gateway.conf

for svc in leostream-gateway nginx; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    fi
done

rm -rf "$WORKDIR"
echo '=== Gateway preparation complete ==='
'@

$script = $template.
    Replace('__OS_UPDATE__',      $updateCmd).
    Replace('__VM_NAME__',        $spec.Name).
    Replace('__VNET_CIDR__',      $config.Network.AddressSpace).
    Replace('__INSTALLER_URI__',  $InstallerUri).
    Replace('__BROKER_ADDRESS__', $BrokerAddress)

if ($PSCmdlet.ShouldProcess($spec.Name, 'Install Leostream Gateway')) {
    $tempFile = New-TemporaryFile
    try {
        Set-Content -Path $tempFile -Value $script -Encoding utf8NoBOM
        Write-Host "==> Running installation on $($spec.Name)." -ForegroundColor Cyan
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $rgName `
            -VMName $spec.Name `
            -CommandId 'RunShellScript' `
            -ScriptPath $tempFile

        foreach ($out in $result.Value) {
            Write-Host "--- $($out.DisplayStatus) ---" -ForegroundColor DarkGray
            Write-Host $out.Message
        }
    }
    finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }
}

$pip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $spec.PublicIpName -ErrorAction SilentlyContinue
if ($pip) {
    $endpoint = if ($pip.DnsSettings -and $pip.DnsSettings.Fqdn) { $pip.DnsSettings.Fqdn } else { $pip.IpAddress }
    Write-Host ''
    Write-Host "Gateway public endpoint: https://$endpoint/" -ForegroundColor Green
    Write-Host 'Replace the self-signed certificate with a trusted one before any real use.' -ForegroundColor Yellow
}
