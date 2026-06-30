param(
    [string]$ServerAddr = "",
    [int]$ServerPort = 7000,
    [string]$Token = "",
    [string[]]$Map = @(),
    [string]$Archive = "",
    [string]$InstallDir = "C:\frp",
    [string]$TaskName = "frpc",
    [switch]$Yes
)

$ErrorActionPreference = "Stop"

function Read-Required($Prompt) {
    while ($true) {
        $value = Read-Host $Prompt
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }
    }
}

function Read-Default($Prompt, $Default) {
    $value = Read-Host "$Prompt [$Default]"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value.Trim()
}

function Test-PortValue($Value) {
    $port = 0
    return [int]::TryParse([string]$Value, [ref]$port) -and $port -ge 1 -and $port -le 65535
}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultArch {
    if ([Environment]::Is64BitOperatingSystem) {
        if ($env:PROCESSOR_ARCHITECTURE -match "ARM64" -or $env:PROCESSOR_ARCHITEW6432 -match "ARM64") {
            return @("arm64", "aarch64")
        }
        return @("amd64", "x86_64")
    }
    return @("386", "i386", "x86")
}

function Find-FrpArchive {
    param([string[]]$ArchCandidates)
    $matches = @()
    foreach ($arch in $ArchCandidates) {
        $matches += Get-ChildItem -LiteralPath $PSScriptRoot -Filter "frp_*_windows_$arch.zip" -File -ErrorAction SilentlyContinue
    }
    if ($matches.Count -eq 0) {
        throw "No matching Windows FRP archive found in $PSScriptRoot. Put frp_*_windows_amd64.zip or frp_*_windows_arm64.zip here, or pass -Archive."
    }
    if ($matches.Count -gt 1) {
        throw "Multiple matching Windows FRP archives found. Pass -Archive explicitly."
    }
    return $matches[0].FullName
}

function Parse-Map {
    param([string]$Raw)
    $parts = $Raw.Split(":")
    if ($parts.Count -lt 3 -or $parts.Count -gt 4) {
        throw "Invalid map '$Raw'. Expected name:local_port:remote_port[:local_ip]."
    }
    $name = $parts[0]
    $localPort = $parts[1]
    $remotePort = $parts[2]
    $localIP = if ($parts.Count -eq 4 -and $parts[3]) { $parts[3] } else { "127.0.0.1" }
    if ($name -notmatch "^[A-Za-z0-9_-]+$") {
        throw "Invalid map name '$name'. Use letters, numbers, _ or -."
    }
    if (-not (Test-PortValue $localPort)) {
        throw "Invalid local port in map '$Raw'."
    }
    if (-not (Test-PortValue $remotePort)) {
        throw "Invalid remote port in map '$Raw'."
    }
    [pscustomobject]@{
        Name = $name
        LocalIP = $localIP
        LocalPort = [int]$localPort
        RemotePort = [int]$remotePort
    }
}

if (-not (Test-IsAdmin)) {
    throw "Please run PowerShell as Administrator."
}

if (-not $Yes) {
    if ([string]::IsNullOrWhiteSpace($ServerAddr)) {
        $ServerAddr = Read-Required "Public server IP or hostname"
    }
    $ServerPort = [int](Read-Default "FRP control port on public server" $ServerPort)
    if ([string]::IsNullOrWhiteSpace($Token)) {
        $Token = Read-Required "FRP token, must match public frps"
    }
    if ($Map.Count -eq 0) {
        $useViewer = Read-Default "Add viewer mapping 8765->18080? y/n" "y"
        if ($useViewer -match "^(y|yes)$") {
            $Map += "viewer:8765:18080"
        }
        $useRdp = Read-Default "Add Windows RDP mapping 3389->13389? y/n" "n"
        if ($useRdp -match "^(y|yes)$") {
            $Map += "rdp:3389:13389"
        }
        while ($true) {
            $more = Read-Default "Add another port mapping? y/n" "n"
            if ($more -notmatch "^(y|yes)$") { break }
            $name = Read-Required "Mapping name"
            $localPort = Read-Required "Local Windows service port"
            $remotePort = Read-Required "Public remote port on server"
            $localIP = Read-Default "Local IP" "127.0.0.1"
            $Map += "$name`:$localPort`:$remotePort`:$localIP"
        }
    }
}

if ([string]::IsNullOrWhiteSpace($ServerAddr)) { throw "-ServerAddr is required." }
if ([string]::IsNullOrWhiteSpace($Token)) { throw "-Token is required." }
if (-not (Test-PortValue $ServerPort)) { throw "-ServerPort must be 1-65535." }
if ($Map.Count -eq 0) { $Map = @("viewer:8765:18080") }

$parsedMaps = @($Map | ForEach-Object { Parse-Map $_ })

if ([string]::IsNullOrWhiteSpace($Archive)) {
    $Archive = Find-FrpArchive -ArchCandidates (Get-DefaultArch)
}
if (-not (Test-Path -LiteralPath $Archive)) {
    throw "Archive not found: $Archive"
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
}
Get-Process frpc -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 2

$tmp = Join-Path $env:TEMP ("frp-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $tmp | Out-Null
try {
    Expand-Archive -LiteralPath $Archive -DestinationPath $tmp -Force
    $frpc = Get-ChildItem -LiteralPath $tmp -Recurse -Filter frpc.exe -File | Select-Object -First 1
    if (-not $frpc) { throw "frpc.exe not found in archive." }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    Copy-Item -LiteralPath $frpc.FullName -Destination (Join-Path $InstallDir "frpc.exe") -Force
}
finally {
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

$configPath = Join-Path $InstallDir "frpc.toml"
$lines = @(
    "serverAddr = `"$ServerAddr`"",
    "serverPort = $ServerPort",
    "",
    "auth.method = `"token`"",
    "auth.token = `"$($Token.Replace('"', '\"'))`"",
    ""
)

foreach ($item in $parsedMaps) {
    $lines += @(
        "[[proxies]]",
        "name = `"$($item.Name)`"",
        "type = `"tcp`"",
        "localIP = `"$($item.LocalIP)`"",
        "localPort = $($item.LocalPort)",
        "remotePort = $($item.RemotePort)",
        ""
    )
}

[IO.File]::WriteAllText($configPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

$exePath = Join-Path $InstallDir "frpc.exe"
$logPath = Join-Path $InstallDir "frpc.log"
$runnerPath = Join-Path $InstallDir "run-frpc.ps1"
$runner = @(
    '$ErrorActionPreference = "Stop"',
    "Set-Location -LiteralPath '$($InstallDir.Replace("'", "''"))'",
    "`$exe = '$($exePath.Replace("'", "''"))'",
    "`$config = '$($configPath.Replace("'", "''"))'",
    "`$log = '$($logPath.Replace("'", "''"))'",
    '"==== $(Get-Date -Format o) starting frpc ====" | Out-File -FilePath $log -Append -Encoding utf8',
    '& $exe -c $config *>> $log',
    'exit $LASTEXITCODE'
)
Set-Content -LiteralPath $runnerPath -Value $runner -Encoding UTF8

$action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$runnerPath`"" -WorkingDirectory $InstallDir
$trigger = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
Start-ScheduledTask -TaskName $TaskName

Write-Host ""
Write-Host "Done. Windows frpc is configured."
Write-Host "Install dir: $InstallDir"
Write-Host "Config: $configPath"
Write-Host "Log: $logPath"
Write-Host "Scheduled task: $TaskName"
Write-Host "Public addresses:"
foreach ($item in $parsedMaps) {
    Write-Host "  $($item.Name): $ServerAddr`:$($item.RemotePort) -> $($item.LocalIP):$($item.LocalPort)"
}
