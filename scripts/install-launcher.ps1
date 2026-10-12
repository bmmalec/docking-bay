#Requires -Version 7.0
<#
.SYNOPSIS
  One-time Windows setup for the current user (no admin needed). Everything it
  creates lives under your own profile and is removed again by -Uninstall:

    - the dockingbay:// URL protocol, which is what the launcher's Rescan button
      opens. It runs refresh-projects.ps1 and nothing else: the URL itself is
      never passed to the script, so a link can trigger a scan but cannot feed
      it any input.
    - a Startup-folder shortcut that rescans at logon (skip with -NoLogonScan),
      plus an optional repeating scan (-EveryMinutes 60).
    - a desktop shortcut that opens the launcher in its own app window (skip
      with -NoDesktopShortcut).

.EXAMPLE
  pwsh scripts/install-launcher.ps1
  pwsh scripts/install-launcher.ps1 -EveryMinutes 60
  pwsh scripts/install-launcher.ps1 -Uninstall
#>
param(
  [switch]$Uninstall,
  [int]$EveryMinutes = 0,
  [switch]$NoLogonScan,
  [switch]$NoDesktopShortcut,
  [switch]$NoScan
)

$ErrorActionPreference = "Stop"
if (-not $IsWindows) { throw "install-launcher.ps1 is Windows-only. Elsewhere, open project-launcher.html directly and run refresh-projects.ps1 by hand." }

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "launcher-data.ps1")

$refreshScript = Join-Path $PSScriptRoot "refresh-projects.ps1"
$htmlPath = Join-Path $root "project-launcher.html"
$iconPath = Join-Path $root "launcher-icon.ico"
$pwshExe = (Get-Process -Id $PID).Path
$scanArgs = "-NoProfile -NonInteractive -WindowStyle Hidden -File `"$refreshScript`""

$protocolKey = "HKCU:\Software\Classes\dockingbay"
$startupLink = Join-Path ([Environment]::GetFolderPath("Startup")) "Docking Bay rescan.lnk"
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

function Remove-RescanTask {
  if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    return $true
  }
  return $false
}

if ($Uninstall) {
  if (Test-Path $protocolKey) { Remove-Item $protocolKey -Recurse -Force; Write-Host "Removed dockingbay:// protocol" }
  foreach ($link in @($startupLink, $desktopLink)) {
    if (Test-Path -LiteralPath $link) { Remove-Item -LiteralPath $link -Force; Write-Host "Removed $link" }
  }
  if (Remove-RescanTask) { Write-Host "Removed scheduled task '$taskName'" }
  Write-Host "Done. Your project files were not touched." -ForegroundColor Green
  return
}

Convert-LegacyData $root

# --- dockingbay:// protocol (no "%1": the URL is deliberately not forwarded) ---
New-Item -Path "$protocolKey\shell\open\command" -Force | Out-Null
Set-Item -Path $protocolKey -Value "URL:Docking Bay"
New-ItemProperty -Path $protocolKey -Name "URL Protocol" -Value "" -PropertyType String -Force | Out-Null
Set-Item -Path "$protocolKey\shell\open\command" -Value "`"$pwshExe`" $scanArgs"
Write-Host "Registered dockingbay:// -> refresh-projects.ps1"

# --- rescan at logon / on a timer ---
if ($NoLogonScan) {
  if (Test-Path -LiteralPath $startupLink) { Remove-Item -LiteralPath $startupLink -Force }
} else {
  New-Shortcut -LinkPath $startupLink -Target $pwshExe -Arguments $scanArgs -WindowStyle 7
  Write-Host "Rescan at logon: $startupLink"
}

if ($EveryMinutes -gt 0) {
  $action = New-ScheduledTaskAction -Execute $pwshExe -Argument $scanArgs
  $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes($EveryMinutes) -RepetitionInterval (New-TimeSpan -Minutes $EveryMinutes)
  Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
  Write-Host "Rescan every $EveryMinutes min: scheduled task '$taskName'"
} elseif (Remove-RescanTask) {
  Write-Host "Removed repeating scan (no -EveryMinutes given)"
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
Write-Host "The first time you press Rescan, the browser asks whether to open the"
Write-Host "dockingbay link - allow it (and tick 'always allow' to skip the prompt)."
Write-Host ""

if (-not $NoScan) {
  & $refreshScript
}
