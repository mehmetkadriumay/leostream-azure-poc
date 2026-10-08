#Requires -Version 5.1
#Requires -Modules Az.Accounts, Az.Compute

<#
.SYNOPSIS
    Installs the Leostream Agent on leo-win-01 (Windows 11) and registers it
    with the Broker.

.DESCRIPTION
    Uses Invoke-AzVMRunCommand with CommandId 'RunPowerShellScript' so the
    desktop VM never needs a public IP address.

    The script:
      * enables Remote Desktop and the matching Windows Firewall rules
      * allows RDP only from the Gateway subnet
      * downloads the Leostream Agent MSI from a URI you supply
      * installs it silently and points it at the Broker

    No MSI files or licence material are stored in this repository.

.PARAMETER InstallerUri
    HTTPS URI of the Leostream Agent MSI.

.PARAMETER BrokerAddress
    Broker private IP or DNS name. Defaults to poc.config.psd1.

.EXAMPLE
    ./Install-LeostreamAgent.ps1 -InstallerUri 'https://<your-portal>/LeostreamAgent.msi'
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string] $ConfigPath = (Join-Path (Join-Path $PSScriptRoot '..') (Join-Path 'config' 'poc.config.psd1')),

    [Parameter(Mandatory)]
    [ValidatePattern('^https://')]
    [string] $InstallerUri,

    [string] $BrokerAddress,

    [string] $VMName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$config = Import-PowerShellDataFile -Path (Resolve-Path $ConfigPath).Path
$rgName = $config.Azure.ResourceGroupName
$spec   = $config.VirtualMachines.WindowsDesktop

if (-not $VMName)        { $VMName = $spec.Name }
if (-not $BrokerAddress) { $BrokerAddress = $config.VirtualMachines.Broker.PrivateIp }

if (-not (Get-AzContext -ErrorAction SilentlyContinue)) {
    Connect-AzAccount | Out-Null
}

$vm = Get-AzVM -ResourceGroupName $rgName -Name $VMName -ErrorAction SilentlyContinue
if (-not $vm) {
    throw "VM '$VMName' not found in resource group '$rgName'. Run Deploy-LeostreamPoC.ps1 first."
}

$template = @'
$ErrorActionPreference = 'Stop'

Write-Output '=== Leostream Agent installation ==='

Write-Output '--- enabling Remote Desktop ---'
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 0
Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name 'UserAuthentication' -Value 1
Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'

Write-Output '--- restricting RDP to the gateway subnet ---'
Get-NetFirewallRule -DisplayGroup 'Remote Desktop' |
    Where-Object { $_.Enabled -eq 'True' } |
    Set-NetFirewallRule -RemoteAddress @('__GATEWAY_CIDR__', '__BASTION_CIDR__', '__INFRA_CIDR__')

$installerUri = '__INSTALLER_URI__'
$brokerAddress = '__BROKER_ADDRESS__'
$workDir = Join-Path $env:TEMP ('leostream-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $workDir -Force | Out-Null
$msiPath = Join-Path $workDir 'LeostreamAgent.msi'

try {
    Write-Output '--- downloading Leostream Agent ---'
    Invoke-WebRequest -Uri $installerUri -OutFile $msiPath -UseBasicParsing

    Write-Output '--- installing Leostream Agent ---'
    $logPath = Join-Path $workDir 'agent-install.log'
    $msiArgs = @(
        '/i', "`"$msiPath`"",
        '/qn', '/norestart',
        "BROKER_ADDRESS=$brokerAddress",
        '/l*v', "`"$logPath`""
    )
    $proc = Start-Process -FilePath 'msiexec.exe' -ArgumentList $msiArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0 -and $proc.ExitCode -ne 3010) {
        throw "msiexec failed with exit code $($proc.ExitCode). See $logPath"
    }

    Write-Output '--- verifying agent service ---'
    $svc = Get-Service -Name 'LeostreamAgent' -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -ne 'Running') { Start-Service -Name 'LeostreamAgent' }
        Set-Service -Name 'LeostreamAgent' -StartupType Automatic
        Write-Output "Leostream Agent service status: $((Get-Service -Name 'LeostreamAgent').Status)"
    }
    else {
        Write-Output 'Leostream Agent service not found - check the MSI log.'
    }
}
finally {
    Remove-Item -Path $workDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Output '=== Leostream Agent installation complete ==='
'@

$script = $template.
    Replace('__GATEWAY_CIDR__',   $config.Network.Subnets.Gateway.AddressPrefix).
    Replace('__BASTION_CIDR__',   $config.Network.Subnets.Bastion.AddressPrefix).
    Replace('__INFRA_CIDR__',     $config.Network.Subnets.Infrastructure.AddressPrefix).
    Replace('__INSTALLER_URI__',  $InstallerUri).
    Replace('__BROKER_ADDRESS__', $BrokerAddress)

if ($PSCmdlet.ShouldProcess($VMName, 'Install Leostream Agent')) {
    $tempFile = New-TemporaryFile
    try {
        # Must be UTF-8 without a BOM and with LF line endings: a BOM or a
        # stray CR breaks the shebang and bash parsing on RHEL. This also
        # works on Windows PowerShell 5.1, which has no utf8NoBOM encoding.
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [System.IO.File]::WriteAllText($tempFile.FullName, $script.Replace("`r`n", "`n"), $utf8NoBom)
        Write-Host "==> Running installation on $VMName." -ForegroundColor Cyan
        $result = Invoke-AzVMRunCommand `
            -ResourceGroupName $rgName `
            -VMName $VMName `
            -CommandId 'RunPowerShellScript' `
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

Write-Host ''
Write-Host "Register '$VMName' in the Broker under > Resources > Centers (Azure) or Uncategorized Desktops." -ForegroundColor Green
