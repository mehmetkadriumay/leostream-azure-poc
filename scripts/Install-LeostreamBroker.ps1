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

$updateCmd = if ($SkipOsUpdate) { 'echo "skipping OS update"' } else { 'dnf_retry update' }

# Literal here-string so bash variables stay intact; placeholders are substituted below.
$template = @'
#!/bin/bash
set -euo pipefail

echo '=== Leostream Broker preparation ==='

# Azure's RHUI mirrors intermittently time out fetching repository metadata,
# which aborts the whole install under 'set -e'. Be patient and retry; only if
# a repo is still unreachable after that, let dnf skip it rather than fail.
cat >> /etc/dnf/dnf.conf <<'DNFCONF'
timeout=60
retries=5
minrate=0
DNFCONF

dnf_retry() {
    attempt=1
    while [ "$attempt" -le 3 ]; do
        if dnf -y "$@"; then
            return 0
        fi
        echo "--- dnf $1 failed (attempt $attempt of 3), retrying in 15s ---"
        sleep 15
        attempt=$((attempt + 1))
    done
    echo "--- dnf $1 failed after 3 attempts ---"
    echo '--- If this is a repository timeout, the Broker has no outbound internet.'
    echo '--- It has no public IP, and Azure retired default outbound access in'
    echo '--- September 2025, so the subnet needs a NAT gateway. Check with:'
    echo '---   curl -s -o /dev/null -w "%{http_code}" --max-time 20 https://www.microsoft.com/'
    echo '--- A result of 000 means no outbound path. Re-run Deploy-LeostreamPoC.ps1,'
    echo '--- which creates the NAT gateway when Network.NatGatewayEnabled is $true.'
    return 1
}

__OS_UPDATE__
dnf_retry install firewalld chrony policycoreutils-python-utils tar curl ca-certificates

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
    dnf_retry install https://dl.fedoraproject.org/pub/epel/epel-release-latest-9.noarch.rpm
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
    dnf_retry install "./$INSTALLER_FILE"
fi

echo '--- enabling Leostream services ---'
# The Platform 26 unit is 'leostream-broker', not 'leostream', and it pulls in
# postgresql. Match on the exact unit name: a prefix match finds
# leostream-broker.service but then tries to enable a 'leostream' unit that
# does not exist, which used to fail silently and leave the Broker stopped.
# Leostream bundles its own httpd and redis under /opt/leostream, so no
# separate web server package is required.
for svc in postgresql leostream-broker; do
    if systemctl list-unit-files --no-legend "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    else
        echo "unit ${svc}.service not present - skipping"
    fi
done

echo '--- waiting for the Broker web interface ---'
# control.pl returns as soon as it has forked its workers, so the listener is
# not up yet when systemd reports the unit active. Poll rather than guess.
for attempt in $(seq 1 30); do
    if curl -k -s -o /dev/null --max-time 10 https://localhost/ ; then
        echo "Broker web interface responding after ${attempt} attempt(s)."
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        echo 'WARNING: the Broker web interface did not respond within 5 minutes.'
        echo 'Check "systemctl status leostream-broker" and /opt/leostream/logs/.'
    fi
    sleep 10
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

# --- surviving a dropped connection -------------------------------------------
# Invoke-AzVMRunCommand holds one HTTPS conversation with Azure open for the
# whole run, and this install takes 10-20 minutes. A momentary network fault on
# the operator's PC - VPN reconnect, Wi-Fi roam, sleep/resume - therefore
# surfaces as "The SSL connection could not be established" even though
# RunCommand executes *on the VM*, where the installation carries on to
# completion. Failing there is wrong twice over: it reports a successful
# install as broken, and it invites a blind re-run while the first is still
# going.
#
# So on a transient client-side fault, ask the VM what actually happened rather
# than give up. Azure runs one RunCommand per VM at a time, so this
# verification call queues behind an install still in progress and only answers
# once that install has finished - which is exactly the wait we want.

$verifyScript = @'
if rpm -q leostream-broker >/dev/null 2>&1 \
   && systemctl is-active --quiet leostream-broker \
   && curl -sk -o /dev/null --max-time 10 https://127.0.0.1/ ; then
    echo LEOSTREAM_VERIFY_OK
else
    echo LEOSTREAM_VERIFY_INCOMPLETE
fi
'@

function Test-TransientAzureError {
    [OutputType([bool])]
    param([Parameter(Mandatory)] $ErrorRecord)

    $text = @()
    $ex = $ErrorRecord.Exception
    while ($ex) {
        $text += $ex.Message
        $ex = $ex.InnerException
    }

    $pattern = 'SSL connection could not be established|' +
               'Unable to read data from the transport connection|' +
               'An error occurred while sending the request|' +
               'The operation was canceled|A task was canceled|' +
               'HttpClient\.Timeout|forcibly closed|' +
               'Unable to connect to the remote server|' +
               'The remote name could not be resolved'

    return [bool](($text -join ' ') -match $pattern)
}

function Get-VmCompletionState {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $VerifyScript
    )

    for ($i = 1; $i -le 5; $i++) {
        try {
            $probe = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
                -CommandId 'RunShellScript' -ScriptString $VerifyScript -ErrorAction Stop
            return (($probe.Value | ForEach-Object { $_.Message }) -join "`n")
        }
        catch {
            if (-not (Test-TransientAzureError $_) -or $i -eq 5) { return '' }
            Start-Sleep -Seconds 20
        }
    }
    return ''
}

function Invoke-ResilientRunCommand {
    [OutputType([string])]
    param(
        [Parameter(Mandatory)] [string] $ResourceGroupName,
        [Parameter(Mandatory)] [string] $VMName,
        [Parameter(Mandatory)] [string] $ScriptPath,
        [Parameter(Mandatory)] [string] $VerifyScript,
        [Parameter(Mandatory)] [string] $SuccessMarker,
        [int] $MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            $result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroupName -VMName $VMName `
                -CommandId 'RunShellScript' -ScriptPath $ScriptPath -ErrorAction Stop

            $text = ''
            foreach ($out in $result.Value) {
                Write-Host "--- $($out.DisplayStatus) ---" -ForegroundColor DarkGray
                Write-Host $out.Message
                $text += $out.Message
            }
            return $text
        }
        catch {
            if (-not (Test-TransientAzureError $_)) { throw }

            Write-Warning "Lost the connection to Azure while the command was running on $VMName."
            Write-Warning "  $($_.Exception.Message)"
            Write-Host '    RunCommand runs on the VM, so the work probably continued. Asking the VM...' -ForegroundColor Yellow

            $state = Get-VmCompletionState -ResourceGroupName $ResourceGroupName -VMName $VMName -VerifyScript $VerifyScript
            if ($state -match 'LEOSTREAM_VERIFY_OK') {
                Write-Host '    It finished on the VM despite the dropped connection.' -ForegroundColor Green
                return $SuccessMarker
            }

            if ($attempt -ge $MaxAttempts) { break }
            Write-Host "    Not finished yet. Retrying (attempt $($attempt + 1) of $MaxAttempts)..." -ForegroundColor Yellow
            Start-Sleep -Seconds 15
        }
    }

    throw ("Lost the connection to Azure $MaxAttempts time(s) while installing on $VMName, and the VM does not report a " +
           'finished installation. This script is idempotent - check your network and run it again.')
}

if ($PSCmdlet.ShouldProcess($spec.Name, 'Install Leostream Platform 26')) {
    $tempFile = New-TemporaryFile
    try {
        # Must be UTF-8 without a BOM and with LF line endings: a BOM or a
        # stray CR breaks the shebang and bash parsing on RHEL. This also
        # works on Windows PowerShell 5.1, which has no utf8NoBOM encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile.FullName, $script.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "==> Running installation on $($spec.Name). This can take several minutes." -ForegroundColor Cyan
        $combined = Invoke-ResilientRunCommand `
            -ResourceGroupName $rgName `
            -VMName $spec.Name `
            -ScriptPath $tempFile.FullName `
            -VerifyScript $verifyScript `
            -SuccessMarker '=== Broker preparation complete ==='

        # 'Enable succeeded' only means the RunCommand extension ran; it says
        # nothing about the script's exit code. The script runs under
        # 'set -euo pipefail', so it stops at the first failure and never
        # prints its final marker. Without this check a failed install is
        # reported as success.
        if ($combined -notmatch '=== Broker preparation complete ===') {
            throw ("Installation did not complete on $($spec.Name). The script stopped early - see the output above for the failing step. " +
                   'Nothing was rolled back, and the script is safe to re-run once the cause is resolved.')
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
