#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Compute, Az.Network

<#
.SYNOPSIS
    Prepares leo-broker-01 (RHEL 9) and installs Leostream Platform 26.

.DESCRIPTION
    Runs a remote shell script on the Broker VM through the Azure
    RunCommand extension (Invoke-AzVMRunCommand), so no inbound SSH from the
    internet is required.

    The script:
      * updates the OS and installs prerequisites (firewalld, chrony, policycoreutils)
      * opens 443/tcp in firewalld
      * enables EPEL, which supplies dependencies the Leostream package needs
        and which is not available in the Azure RHUI repositories
      * installs Leostream Platform 26 from an RPM or shell installer URL

    No Leostream RPMs, licence keys or serial numbers are stored in this
    repository. The installer URL in poc.config.psd1 is a public download
    location, not a credential. Supply a licence with -LicenseKey
    (SecureString) or complete licensing through the Broker web interface.

.PARAMETER ConfigPath
    Path to poc.config.psd1.

.PARAMETER InstallerUri
    HTTPS URI of the Leostream Platform 26 installer. Defaults to
    Leostream.BrokerInstallerUri in poc.config.psd1. Both a .rpm package and a
    shell installer are supported; the script detects which it received.

.PARAMETER LicenseKey
    Optional SecureString licence key. If omitted, license the Broker through
    its web interface.

.PARAMETER SkipOsUpdate
    Skip 'dnf update' to shorten the run.

.EXAMPLE
    ./Install-LeostreamBroker.ps1

.EXAMPLE
    ./Install-LeostreamBroker.ps1 -InstallerUri 'https://downloads.leostream.com/leostream-broker-26.1.6-1.x86_64.rpm'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),

    [ValidatePattern('^https://')]
    [string] $InstallerUri,

    [securestring] $LicenseKey,

    [switch] $SkipOsUpdate
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName
$spec   = $config.VirtualMachines.Broker

if (-not $InstallerUri) {
    $InstallerUri = $config.Leostream.BrokerInstallerUri
}
if (-not $InstallerUri) {
    throw 'No installer URI. Set Leostream.BrokerInstallerUri in poc.config.psd1 or pass -InstallerUri.'
}
Write-Host "==> Installer: $InstallerUri" -ForegroundColor Cyan

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}

$vm = Get-AzVM -ResourceGroupName $rgName -Name $spec.Name -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$($spec.Name)' not found in resource group '$rgName'. Run Deploy-LeostreamPoC.ps1 first."
}

$plainLicense = ''
if ($LicenseKey) {
    $plainLicense = [System.Net.NetworkCredential]::new('', $LicenseKey).Password
}

$updateCmd = if ($SkipOsUpdate) { 'echo "skipping OS update"' } else { 'dnf -y update' }

# Literal here-string so bash variables stay intact; placeholders are substituted below.
$template = @'
#!/bin/bash
set -euo pipefail

echo '=== Leostream Broker preparation ==='

__OS_UPDATE__
dnf -y install firewalld chrony policycoreutils-python-utils tar curl ca-certificates

systemctl enable --now chronyd
systemctl enable --now firewalld

echo '--- configuring firewall ---'
firewall-cmd --permanent --add-service=https
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --reload

echo '--- setting hostname ---'
hostnamectl set-hostname '__VM_NAME__'

echo '--- enabling EPEL ---'
# The Leostream packages depend on software that is not in the Azure RHUI
# repositories. CodeReady Builder is already enabled on the Azure RHEL image.
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
[ -n "$INSTALLER_FILE" ] || INSTALLER_FILE='leostream-installer'

echo "--- downloading Leostream Platform 26 installer ($INSTALLER_FILE) ---"
curl -fsSL -o "$INSTALLER_FILE" "$INSTALLER_URI"

echo '--- running installer ---'
if head -c 2 "$INSTALLER_FILE" | grep -q '#!' ; then
    chmod +x "$INSTALLER_FILE"
    "./$INSTALLER_FILE"
else
    dnf -y install "./$INSTALLER_FILE"
fi

echo '--- enabling Leostream services ---'
# postgresql is what the Platform 26 package pulls in; mariadb and nginx are
# listed for older builds. Missing units are skipped.
for svc in postgresql mariadb httpd nginx leostream; do
    if systemctl list-unit-files | grep -q "^${svc}"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    fi
done

LICENSE_KEY='__LICENSE_KEY__'
if [ -n "$LICENSE_KEY" ] && command -v leostream-license >/dev/null 2>&1 ; then
    echo '--- applying licence ---'
    leostream-license "$LICENSE_KEY" || echo 'licence activation failed - complete it in the web interface'
fi

rm -rf "$WORKDIR"
echo '=== Broker preparation complete ==='
'@

$script = $template.
    Replace('__OS_UPDATE__',     $updateCmd).
    Replace('__VM_NAME__',       $spec.Name).
    Replace('__INSTALLER_URI__', $InstallerUri).
    Replace('__LICENSE_KEY__',   $plainLicense)

if ($PSCmdlet.ShouldProcess($spec.Name, 'Install Leostream Platform 26')) {
    $tempFile = New-TemporaryFile
    try {
        # Must be UTF-8 without a BOM and with LF line endings: a BOM or a
        # stray CR breaks the shebang and bash parsing on RHEL. This also
        # works on Windows PowerShell 5.1, which has no utf8NoBOM encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile.FullName, $script.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "==> Running installation on $($spec.Name). This can take several minutes." -ForegroundColor Cyan
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
        $plainLicense = $null
        [System.GC]::Collect()
    }
}

$gatewayAddress = '<gateway-public-ip>'
$gatewayPip = Get-AzPublicIpAddress -ResourceGroupName $rgName -Name $config.VirtualMachines.Gateway.PublicIpName -ErrorAction SilentlyContinue
if ($gatewayPip -and $gatewayPip.IpAddress) { $gatewayAddress = $gatewayPip.IpAddress }

Write-Host ''
Write-Host "Broker private address: https://$($spec.PrivateIp)/" -ForegroundColor Green
Write-Host 'Reach it from a PowerShell prompt on your own PC by tunnelling through the Gateway:' -ForegroundColor Green
Write-Host "  ssh -L 8443:$($spec.PrivateIp):443 $($config.Admin.LinuxUsername)@$gatewayAddress" -ForegroundColor Green
Write-Host '  leave that window open, then browse to https://localhost:8443/' -ForegroundColor Green
Write-Host 'Default Leostream administrator account: admin / leo (change it immediately).' -ForegroundColor Yellow
