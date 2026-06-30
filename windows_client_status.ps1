param(
    [string]$InstallDir = "C:\frp",
    [string]$TaskName = "frpc"
)

$ErrorActionPreference = "Continue"
$configPath = Join-Path $InstallDir "frpc.toml"

function Section($Title) {
    Write-Host ""
    Write-Host "== $Title =="
}

function Test-Tcp($HostName, $Port) {
    try {
        $client = [Net.Sockets.TcpClient]::new()
        $async = $client.BeginConnect($HostName, [int]$Port, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(2000)
        if ($ok -and $client.Connected) {
            $client.EndConnect($async)
            Write-Host "ok: $HostName`:$Port reachable"
        } else {
            Write-Host "fail: $HostName`:$Port not reachable"
        }
        $client.Close()
    } catch {
        Write-Host "fail: $HostName`:$Port not reachable"
    }
}

function Read-ConfigValue($Key) {
    if (-not (Test-Path -LiteralPath $configPath)) { return "" }
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.+)\s*$") {
            return $Matches[1].Trim().Trim('"')
        }
    }
    return ""
}

Section "scheduled task"
$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    $task | Format-List TaskName, State, TaskPath
    Get-ScheduledTaskInfo -TaskName $TaskName | Format-List LastRunTime, LastTaskResult, NextRunTime, NumberOfMissedRuns
} else {
    Write-Host "task not found: $TaskName"
}

Section "frpc process"
Get-Process frpc -ErrorAction SilentlyContinue | Format-Table Id, ProcessName, Path -AutoSize

Section "config"
if (Test-Path -LiteralPath $configPath) {
    (Get-Content -LiteralPath $configPath) -replace '(auth\.token\s*=\s*").*(")', '$1***$2'
} else {
    Write-Host "config not found: $configPath"
}

Section "server connectivity"
$serverAddr = Read-ConfigValue "serverAddr"
$serverPort = Read-ConfigValue "serverPort"
if ($serverAddr -and $serverPort) {
    Test-Tcp $serverAddr $serverPort
} else {
    Write-Host "serverAddr/serverPort not found"
}

Section "local mapped services"
if (Test-Path -LiteralPath $configPath) {
    $name = ""
    $localIP = "127.0.0.1"
    $localPort = ""
    $remotePort = ""
    foreach ($line in Get-Content -LiteralPath $configPath) {
        if ($line -match '^\s*\[\[proxies\]\]\s*$') {
            if ($name) {
                Write-Host "$name`: $localIP`:$localPort -> public:$remotePort"
                Test-Tcp $localIP $localPort
            }
            $name = ""
            $localIP = "127.0.0.1"
            $localPort = ""
            $remotePort = ""
            continue
        }
        if ($line -match '^\s*name\s*=\s*"(.+)"') { $name = $Matches[1] }
        if ($line -match '^\s*localIP\s*=\s*"(.+)"') { $localIP = $Matches[1] }
        if ($line -match '^\s*localPort\s*=\s*(\d+)') { $localPort = $Matches[1] }
        if ($line -match '^\s*remotePort\s*=\s*(\d+)') { $remotePort = $Matches[1] }
    }
    if ($name) {
        Write-Host "$name`: $localIP`:$localPort -> public:$remotePort"
        Test-Tcp $localIP $localPort
    }
}

Section "listening ports"
Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Select-Object LocalAddress, LocalPort, OwningProcess |
    Sort-Object LocalPort |
    Format-Table -AutoSize
