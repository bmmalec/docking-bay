#Requires -Version 7.0
<#
.SYNOPSIS
  One-time Windows setup for the current user (no admin needed). Everything it
  creates lives under your own profile and is removed again by -Uninstall:

    - a Startup-folder shortcut that rescans at logon (skip with -NoLogonScan),
      plus an optional repeating scan (-EveryMinutes 60).
    - with -NodeHelper: the optional Node helper (helper/server.js) as a Startup
      shortcut, started now. It runs the same scan as a local service on
      127.0.0.1, which makes the page's Rescan button a one-click rescan, and it
      replaces the PowerShell logon/timer scan. Needs Node 18+.
    - a desktop shortcut that opens the launcher in its own app window (skip
      with -NoDesktopShortcut).

  Without the helper, the Rescan button shows the command to run by hand:
  pwsh scripts/refresh-projects.ps1

.EXAMPLE
  pwsh scripts/install-launcher.ps1
  pwsh scripts/install-launcher.ps1 -EveryMinutes 60
  pwsh scripts/install-launcher.ps1 -NodeHelper -EveryMinutes 60
  pwsh scripts/install-launcher.ps1 -Uninstall
#>
param(
  [switch]$Uninstall,
  [int]$EveryMinutes = 0,
  [switch]$NoLogonScan,
  [switch]$NodeHelper,
  [switch]$NoDesktopShortcut,
  [switch]$NoScan
)

$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "install-launcher.ps1 is Windows-only. Elsewhere, open project-launcher.html directly and run refresh-projects.ps1 (or node helper/server.js --once) by hand." }

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "launcher-data.ps1")

$refreshScript = Join-Path $PSScriptRoot "refresh-projects.ps1"
$helperScript = Join-Path $root "helper\server.js"
$htmlPath = Join-Path $root "project-launcher.html"
$iconPath = Join-Path $root "launcher-icon.ico"
$pwshExe = (Get-Process -Id $PID).Path
$scanArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$refreshScript`""

# Older versions registered a dockingbay:// URL protocol for the Rescan button.
# Nothing uses it any more, so install and uninstall both remove it.
$protocolKey = "HKCU:\Software\Classes\dockingbay"
$startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) "Docking Bay rescan.lnk"
$helperLink = Join-Path ([Environment]::GetFolderPath("Startup")) "Docking Bay helper.lnk"
$desktopLink = Join-Path ([Environment]::GetFolderPath("Desktop")) "Docking Bay.lnk"
$taskName = "Docking Bay rescan"

function New-Shortcut([string]$LinkPath, [string]$Target, [string]$Arguments, [int]$WindowStyle = 1) {
  $shell = New-Object -ComObject WScript.Shell
  $link = $shell.CreateShortcut($LinkPath)
  $link.TargetPath = $Target
  $link.Arguments = $Arguments
  $link.WorkingDirectory = $root
  $link.WindowStyle = $WindowStyle
  if (Test-Path -LiteralPath $iconPath) { $link.IconLocation = "$iconPath,0" }
  $link.Save()
}

function Remove-LegacyProtocol {
  if (Test-Path $protocolKey) { Remove-Item $protocolKey -Recurse -Force; return $true }
  return $false
}

# The helper is a plain node process; find it by its command line.
function Stop-Helper {
  $found = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($helperScript) })
  foreach ($p in $found) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  return $found.Count -gt 0
}

function Remove-RescanTask {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    return $true
  }
  return $false
}

if ($Uninstall) {
  if (Remove-LegacyProtocol) { Write-Host "Removed dockingbay:// protocol" }
  if (Stop-Helper) { Write-Host "Stopped the running helper" }
  foreach ($link in @($startupLink, $helperLink, $desktopLink)) {
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force; Write-Host "Removed $link" }
  }
  if (Remove-RescanTask) { Write-Host "Removed scheduled task '$taskName'" }
  Write-Host "Done. Your project files were not touched." -ForegroundColor Green
  return
}

Convert-LegacyData $root

if (Remove-LegacyProtocol) { Write-Host "Removed the old dockingbay:// protocol handler (no longer used)" }

# --- optional Node helper: one-click Rescan, and it does the logon/timer scans ---
if ($NodeHelper) {
  $node = (Get-Command node -ErrorAction SilentlyContinue).Source
  if (-not $node) { throw "-NodeHelper needs Node.js 18 or newer on PATH (https://nodejs.org). Install it, or run without -NodeHelper." }
  $nodeMajor = [int](& $node -p "process.versions.node.split('.')[0]")
  if ($nodeMajor -lt 18) { throw "-NodeHelper needs Node.js 18 or newer; found $(& $node --version)." }

  $helperArgs = "`"$helperScript`""
  if ($EveryMinutes -gt 0) { $helperArgs += " --every $EveryMinutes" }
  Stop-Helper | Out-Null
  New-Shortcut -LinkPath $helperLink -Target $node -Arguments $helperArgs -WindowStyle 7
  Write-Host "Helper at logon: $helperLink"
} elseif (Test-Path -LiteralPath $helperLink) {
  Remove-Item -LiteralPath $helperLink -Force
  Stop-Helper | Out-Null
  Write-Host "Removed the helper (no -NodeHelper given)"
}

# --- rescan at logon / on a timer (the helper covers this itself when installed) ---
if ($NoLogonScan -or $NodeHelper) {
  if (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink -Force }
} else {
  New-Shortcut -LinkPath $startupLink -Target $pwshExe -Arguments $scanArgs -WindowStyle 7
  Write-Host "Rescan at logon: $startupLink"
}

if ($EveryMinutes -gt 0 -and -not $NodeHelper) {
  $action = New-ScheduledTaskAction -Execute $pwshExe -Argument $scanArgs
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($EveryMinutes) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
  Write-Host "Rescan every $EveryMinutes min: scheduled task '$taskName'"
} elseif (Remove-RescanTask) {
  Write-Host "Removed repeating scan task"
}

# --- desktop shortcut: the page in a chromeless app window, straight from disk ---
if (-not $NoDesktopShortcut) {
  $browser = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1

  if ($browser) {
    $fileUrl = ([Uri]$htmlPath).AbsoluteUri
    New-Shortcut -LinkPath $desktopLink -Target $browser -Arguments "--app=`"$fileUrl`""
  } else {
    # No Edge/Chrome found: fall back to opening the page in the default browser.
    New-Shortcut -LinkPath $desktopLink -Target $htmlPath -Arguments ""
  }
  Write-Host "Desktop shortcut: $desktopLink"
}

Write-Host ""
Write-Host "Installed." -ForegroundColor Green
if ($NodeHelper) {
  Write-Host "The Rescan button now rescans in one click (the helper listens on 127.0.0.1 only)."
  Start-Process -FilePath $node -ArgumentList $helperArgs -WorkingDirectory $root -WindowStyle Hidden
} else {
  Write-Host "The Rescan button shows the command to run: pwsh scripts/refresh-projects.ps1"
  Write-Host "(or re-run this with -NodeHelper for a one-click button)."
  Write-Host ""
  if (-not $NoScan) { & $refreshScript }
}
