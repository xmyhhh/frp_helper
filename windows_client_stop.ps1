param(
    [string]$TaskName = "frpc",
    [switch]$Disable
)

$ErrorActionPreference = "Continue"

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

if (-not (Test-IsAdmin)) {
    throw "Please run PowerShell as Administrator."
}

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($task) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($Disable) {
        Disable-ScheduledTask -TaskName $TaskName | Out-Null
    }
} else {
    Write-Host "task not found: $TaskName"
}

Get-Process frpc -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host ""
if ($Disable) {
    Write-Host "frpc stopped and scheduled task disabled."
} else {
    Write-Host "frpc stopped. Auto-start is unchanged."
}

Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue | Format-List TaskName, State
