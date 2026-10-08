#Requires -Version 7.0
#Requires -Modules Az.Accounts, Az.Compute

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
      * optionally registers the system with Red Hat Subscription Manager
      * installs Leostream Platform 26 from a repository URL or an installer
        URL that YOU provide at run time

    No Leostream RPMs, licence keys or serial numbers are stored in this
    repository. Supply them with -InstallerUri / -LicenseKey (SecureString) or
    complete licensing through the Broker web interface after installation.

.PARAMETER ConfigPath
    Path to poc.config.psd1.

.PARAMETER InstallerUri
    HTTPS URI of the Leostream Platform 26 installer or YUM repository file.
    Obtain this from your Leostream portal / support contact.

.PARAMETER LicenseKey
    Optional SecureString licence key. If omitted, license the Broker through
    its web interface.

.PARAMETER SkipOsUpdate
    Skip 'dnf update' to shorten the run.

.EXAMPLE
    ./Install-LeostreamBroker.ps1 -InstallerUri 'https://<your-portal>/leostream-platform-26.sh'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path $PSScriptRoot '..' 'config' 'poc.config.psd1'),

    [Parameter(Mandatory)]
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

INSTALLER_URI='__INSTALLER_URI__'
WORKDIR=$(mktemp -d)
cd "$WORKDIR"

echo '--- downloading Leostream Platform 26 installer ---'
curl -fsSL -o leostream-installer "$INSTALLER_URI"
chmod +x leostream-installer

echo '--- running installer ---'
if head -c 2 leostream-installer | grep -q '#!' ; then
    ./leostream-installer
else
    dnf -y install ./leostream-installer
fi

echo '--- enabling Leostream services ---'
for svc in leostream httpd mariadb; do
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
        Set-Content -Path $tempFile -Value $script -Encoding utf8NoBOM
        Write-Host "==> Running installation on $($spec.Name). This can take several minutes." -ForegroundColor Cyan
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
        $plainLicense = $null
        [System.GC]::Collect()
    }
}

Write-Host ''
Write-Host "Broker private address: https://$($spec.PrivateIp)/" -ForegroundColor Green
Write-Host 'Reach it from the Windows desktop or a jump host via Azure Bastion.' -ForegroundColor Green
Write-Host 'Default Leostream administrator account: admin / leo (change it immediately).' -ForegroundColor Yellow
