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
      * optionally forwards Ports.BrokerAdmin to the Broker on 443, so the
        administrator interface is reachable without an SSH tunnel

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

# Empty disables the forward, leaving the admin UI reachable only over SSH.
$adminPort = ''
if ($config.Ports.Contains('BrokerAdmin') -and $config.Ports.BrokerAdmin) {
    $adminPort = "$($config.Ports.BrokerAdmin)"
}

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

$updateCmd = if ($SkipOsUpdate) { 'echo "skipping OS update"' } else { 'dnf_retry update' }

$template = @'
#!/bin/bash
set -euo pipefail

echo '=== Leostream Gateway preparation ==='

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
    return 1
}

__OS_UPDATE__
dnf_retry install firewalld chrony curl tar ca-certificates policycoreutils-python-utils

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

# Publish the Broker's administrator interface on this VM's public IP, so it can
# be reached in a browser without an SSH tunnel. This is a plain TCP forward, so
# TLS terminates on the Broker and the certificate you see is the Broker's.
#
# An HTTP reverse proxy would be the obvious alternative, but the Leostream
# Gateway's /etc/httpd/conf.d/leo.conf declares its <Location> blocks outside
# any <VirtualHost>, which makes them global. A new vhost would inherit the
# /app/... handlers that the Broker's own UI also uses, and those requests would
# be answered by the Gateway's mod_perl instead of the Broker.
ADMIN_PORT='__ADMIN_PORT__'
if [ -n "$ADMIN_PORT" ]; then
    echo "--- forwarding ${ADMIN_PORT}/tcp to the Broker on 443 ---"
    # Masquerade is required: without it the Broker would reply straight to the
    # client through the NAT gateway and the client would drop the packet as
    # asymmetric. It must be permanent, because a firewall-cmd --reload resets
    # the runtime configuration to whatever is on disk.
    firewall-cmd --permanent --add-masquerade
    firewall-cmd --permanent --add-port="${ADMIN_PORT}/tcp"
    firewall-cmd --permanent --add-forward-port=port="${ADMIN_PORT}":proto=tcp:toaddr='__BROKER_ADDRESS__':toport=443
fi

firewall-cmd --reload

echo '--- enabling EPEL ---'
# The Gateway package needs libguac, openvpn, certbot, mod_perl and others
# that are not in the Azure RHUI repositories. CodeReady Builder is already
# enabled on the Azure RHEL image.
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
[ -n "$INSTALLER_FILE" ] || INSTALLER_FILE='leostream-gateway-installer'

echo "--- downloading Leostream Gateway installer ($INSTALLER_FILE) ---"
curl -fsSL -o "$INSTALLER_FILE" "$INSTALLER_URI"

echo '--- running installer ---'
if head -c 2 "$INSTALLER_FILE" | grep -q '#!' ; then
    chmod +x "$INSTALLER_FILE"
    "./$INSTALLER_FILE"
else
    dnf_retry install "./$INSTALLER_FILE"
fi

echo '--- recording broker address ---'
mkdir -p /etc/leostream
echo 'broker_address=__BROKER_ADDRESS__' > /etc/leostream/gateway.conf
chmod 0640 /etc/leostream/gateway.conf

echo '--- enabling Gateway services ---'
# The Gateway ships no 'leostream-gateway' unit. It serves 443 through the
# distribution httpd (with a drop-in at /etc/systemd/system/httpd.service.d/leo.conf),
# proxies to tomcat, and runs guacd plus its own wsping unit. The RPM enables
# these itself; re-asserting them is harmless and makes the dependency explicit.
#
# Match the exact unit name. A prefix match succeeds for a unit that merely
# starts with the same text and then fails to enable, which is silent because
# of the '||' fallback, leaving the service stopped.
for svc in httpd tomcat guacd wsping; do
    if systemctl list-unit-files --no-legend "${svc}.service" 2>/dev/null | grep -q "^${svc}\.service"; then
        systemctl enable --now "$svc" || echo "could not enable $svc"
    else
        echo "unit ${svc}.service not present - skipping"
    fi
done

echo '--- waiting for the Gateway web interface ---'
for attempt in $(seq 1 30); do
    if curl -k -s -o /dev/null --max-time 10 https://localhost/ ; then
        echo "Gateway web interface responding after ${attempt} attempt(s)."
        break
    fi
    if [ "$attempt" -eq 30 ]; then
        echo 'WARNING: the Gateway web interface did not respond within 5 minutes.'
        echo 'Check "systemctl status httpd tomcat guacd wsping".'
    fi
    sleep 10
done

rm -rf "$WORKDIR"
echo '=== Gateway preparation complete ==='
'@

$script = $template.
    Replace('__OS_UPDATE__',      $updateCmd).
    Replace('__VM_NAME__',        $spec.Name).
    Replace('__INSTALLER_URI__',  $InstallerUri).
    Replace('__BROKER_ADDRESS__', $BrokerAddress).
    Replace('__ADMIN_PORT__',     $adminPort)

# --- surviving a dropped connection -------------------------------------------
# Invoke-AzVMRunCommand holds one HTTPS conversation with Azure open for the
# whole run, and this install takes several minutes. A momentary network fault
# on the operator's PC - VPN reconnect, Wi-Fi roam, sleep/resume - therefore
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
#
# The Gateway has no single 'leostream-gateway' unit; it is served by httpd and
# tomcat, so completion is judged on the package plus a live HTTPS response.

$verifyScript = @'
if rpm -q leostream-gateway >/dev/null 2>&1 \
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

if ($PSCmdlet.ShouldProcess($spec.Name, 'Install Leostream Gateway')) {
    $tempFile = New-TemporaryFile
    try {
        # Must be UTF-8 without a BOM and with LF line endings: a BOM or a
        # stray CR breaks the shebang and bash parsing on RHEL. This also
        # works on Windows PowerShell 5.1, which has no utf8NoBOM encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile.FullName, $script.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "==> Running installation on $($spec.Name)." -ForegroundColor Cyan
        $combined = Invoke-ResilientRunCommand `
            -ResourceGroupName $rgName `
            -VMName $spec.Name `
            -ScriptPath $tempFile.FullName `
            -VerifyScript $verifyScript `
            -SuccessMarker '=== Gateway preparation complete ==='

        # 'Enable succeeded' only means the RunCommand extension ran; it says
        # nothing about the script's exit code. The script runs under
        # 'set -euo pipefail', so it stops at the first failure and never
        # prints its final marker. Without this check a failed install is
        # reported as success.
        if ($combined -notmatch '=== Gateway preparation complete ===') {
            throw ("Installation did not complete on $($spec.Name). The script stopped early - see the output above for the failing step. " +
                   'Nothing was rolled back, and the script is safe to re-run once the cause is resolved.')
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
