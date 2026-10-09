#Requires -Version 5.1
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
    HTTPS URI of the Leostream Gateway installer. Defaults to
    Leostream.GatewayInstallerUri in poc.config.psd1. Both a .rpm package and a
    shell installer are supported; the script detects which it received.

.PARAMETER BrokerAddress
    Private IP or DNS name of the Broker. Defaults to the value in poc.config.psd1.

.EXAMPLE
    ./Install-LeostreamGateway.ps1

.EXAMPLE
    ./Install-LeostreamGateway.ps1 -InstallerUri 'https://downloads.leostream.com/leostream-gateway-2026.1.1-2.x86_64.rpm'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),

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

if (-not $InstallerUri) {
    $InstallerUri = $config.Leostream.GatewayInstallerUri
}
if (-not $InstallerUri) {
    throw 'No installer URI. Set Leostream.GatewayInstallerUri in poc.config.psd1 or pass -InstallerUri.'
}
Write-Host "==> Installer: $InstallerUri" -ForegroundColor Cyan

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
# SSH stays open here on purpose. This is the only administrative way into the
# deployment, and nsg-leostream already restricts the source to
# AllowedClientCidrs. Narrowing it again here would only risk locking you out.
firewall-cmd --permanent --add-service=ssh
firewall-cmd --reload

echo '--- enabling EPEL ---'
# The Gateway package needs libguac, openvpn, certbot, mod_perl and others
# that are not in the Azure RHUI repositories. CodeReady Builder is already
# enabled on the Azure RHEL image.
if ! dnf -y install epel-release 2>/dev/null; then
    dnf -y install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
fi

INSTALLER_URI='__INSTALLER_URI__'
WORKDIR=$(mktemp -d)
cd "$WORKDIR"

# Keep the upstream file name. dnf only treats a local path as a package when
# it ends in .rpm - otherwise it reads it as a package name and fails with
# "No match for argument". Drop the query string of a pre-signed URL, then the
# scheme and host, and fall back if what is left has no file component.
INSTALLER_PATH="${INSTALLER_URI%%\?*}"
INSTALLER_PATH="${INSTALLER_PATH#*://}"
INSTALLER_FILE=''
case "$INSTALLER_PATH" in
    */)  : ;;
    */*) INSTALLER_FILE="${INSTALLER_PATH##*/}" ;;
esac
[ -n "$INSTALLER_FILE" ] || INSTALLER_FILE='leostream-gateway-installer'

echo "--- downloading Leostream Gateway installer ($INSTALLER_FILE) ---"
curl -fsSL -o "$INSTALLER_FILE" "$INSTALLER_URI"

echo '--- running installer ---'
if head -c 2 "$INSTALLER_FILE" | grep -q '#!' ; then
    chmod +x "$INSTALLER_FILE"
    "./$INSTALLER_FILE"
else
    dnf -y install "./$INSTALLER_FILE"
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
    Replace('__INSTALLER_URI__',  $InstallerUri).
    Replace('__BROKER_ADDRESS__', $BrokerAddress)

if ($PSCmdlet.ShouldProcess($spec.Name, 'Install Leostream Gateway')) {
    $tempFile = New-TemporaryFile
    try {
        # Must be UTF-8 without a BOM and with LF line endings: a BOM or a
        # stray CR breaks the shebang and bash parsing on RHEL. This also
        # works on Windows PowerShell 5.1, which has no utf8NoBOM encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile.FullName, $script.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "==> Running installation on $($spec.Name)." -ForegroundColor Cyan
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $rgName `
            -VMName $spec.Name `
            -CommandId 'RunShellScript' `
            -ScriptPath $tempFile.FullName

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
