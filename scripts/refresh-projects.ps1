#Requires -Version 7.0
<#
.SYNOPSIS
  Rescans every location listed under "scans" in launcher.config.js and merges
  what it finds into projects.js. Run it by hand, from the launcher's Rescan
  button (dockingbay:// protocol), or at logon — see install-launcher.ps1.

  Three scan kinds, each looking at the immediate subfolders of its path:
    ssh    SSHes to a profile (reusing your existing key/config — nothing new is
           provisioned) and runs one fixed, read-only script.
    wsl    Runs the same script inside a WSL distro.
    local  Reads a folder on this machine directly.

  Merges non-destructively: never overwrites an emoji or title, never silently
  deletes an entry. New folders are flagged _review, vanished ones _missing.
  Takes no input from whatever launched it. A profile's legacy "basePath" is
  treated as an ssh scan of that path.
#>
param(
  [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
. (Join-Path $PSScriptRoot "launcher-data.ps1")

$configPath = Join-Path $root "launcher.config.js"
$projectsPath = Join-Path $root "projects.js"
$statusPath = Join-Path $root "scan-status.js"

# Single fixed, read-only remote script, fed to bash over stdin. The scan path
# arrives as $1 and is never string-interpolated into the script text, and
# directory names found on the remote are only ever treated as data
# (basename/printf), never re-run as commands.
$remoteScript = @'
BASE="$1"
[ -d "$BASE" ] || { echo "no such directory: $BASE" >&2; exit 3; }
for d in "$BASE"/*/; do
  [ -d "$d" ] || continue
  name="$(basename "$d")"
  [ "$name" = "lost+found" ] && continue
  dcfile="${d}.devcontainer/devcontainer.json"
  hasdc=0
  wsfolder=""
  if [ -f "$dcfile" ]; then
    hasdc=1
    wsfolder="$(grep -o '"workspaceFolder"[[:space:]]*:[[:space:]]*"[^"]*"' "$dcfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    # devcontainer.json may use VS Code's ${localWorkspaceFolderBasename} variable
    # instead of a literal path; resolve it to the real folder name here since
    # we already know it, rather than passing the unresolved template through.
    wsfolder="${wsfolder//\$\{localWorkspaceFolderBasename\}/$name}"
  fi
  settingsfile="${d}.vscode/settings.json"
  title=""
  bg=""
  fg=""
  if [ -f "$settingsfile" ]; then
    title="$(grep -o '"window.title"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    bg="$(grep -o '"titleBar.activeBackground"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
    fg="$(grep -o '"titleBar.activeForeground"[[:space:]]*:[[:space:]]*"[^"]*"' "$settingsfile" 2>/dev/null | sed -E 's/.*:[[:space:]]*"([^"]*)"/\1/' | head -n1)"
  fi
  printf '%s\x1f%s\x1f%s\x1f%s\x1f%s\x1f%s\n' "$name" "$hasdc" "$wsfolder" "$title" "$bg" "$fg"
done
'@
# On a Windows checkout this file usually has CRLF line endings, which the
# here-string inherits; bash treats the stray \r as part of each command.
$remoteScript = $remoteScript -replace "`r", ""

function Invoke-BashScan([string]$Exe, [string[]]$ExeArgs) {
  # Piping a multi-line string through PowerShell's pipeline to a native
  # process's stdin appends a stray \r before the final line (corrupts a
  # trailing "done" into "done\r"), so this writes raw UTF8 bytes to the
  # process's stdin directly instead.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $Exe
  foreach ($a in $ExeArgs) { $psi.ArgumentList.Add($a) }
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true

  $proc = [System.Diagnostics.Process]::Start($psi)
  $outTask = $proc.StandardOutput.ReadToEndAsync()
  $errTask = $proc.StandardError.ReadToEndAsync()
  $proc.StandardInput.Write($remoteScript)
  $proc.StandardInput.Close()
  if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
    try { $proc.Kill($true) } catch { }
    throw "timed out after ${TimeoutSeconds}s"
  }
  $stdout = $outTask.GetAwaiter().GetResult()
  $stderr = $errTask.GetAwaiter().GetResult()
  if ($proc.ExitCode -ne 0) {
    throw "exit $($proc.ExitCode): $($stderr.Trim())"
  }

  foreach ($line in ($stdout -split "`n")) {
    $fields = $line.TrimEnd("`r") -split ([char]0x1F)
    if ($fields.Count -lt 6) { continue }
    [pscustomobject]@{
      name = $fields[0]; hasDc = ($fields[1] -eq "1"); wsFolder = $fields[2]
      bg = $fields[4]; fg = $fields[5]
    }
  }
}

function Get-JsonString([string]$File, [string]$Key) {
  if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return "" }
  $m = [regex]::Match((Get-Content -LiteralPath $File -Raw), '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
  if ($m.Success) { return $m.Groups[1].Value }
  return ""
}

function Invoke-LocalScan([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "no such directory: $Path" }
  foreach ($dir in Get-ChildItem -LiteralPath $Path -Directory) {
    $dcFile = Join-Path $dir.FullName ".devcontainer/devcontainer.json"
    $settingsFile = Join-Path $dir.FullName ".vscode/settings.json"
    [pscustomobject]@{
      name = $dir.Name
      hasDc = (Test-Path -LiteralPath $dcFile -PathType Leaf)
      wsFolder = ""
      bg = Get-JsonString $settingsFile "titleBar.activeBackground"
      fg = Get-JsonString $settingsFile "titleBar.activeForeground"
    }
  }
}

function Invoke-Scan($Scan) {
  switch ($Scan.kind) {
    "ssh" {
      # ssh joins its trailing args into one string for the remote shell, so the
      # path is single-quoted here to survive spaces and metacharacters intact.
      # BatchMode: fail instead of waiting on a password/host-key prompt that a
      # hidden, button-launched run could never answer.
      $quoted = "'" + $Scan.path.Replace("'", "'\''") + "'"
      Invoke-BashScan "ssh" @("-o", "BatchMode=yes", "-o", "ConnectTimeout=10", $Scan.sshTarget, "bash", "-s", "--", $quoted)
    }
    "wsl" {
      # --exec skips the distro's login shell, so the path is passed verbatim.
      Invoke-BashScan "wsl.exe" @("-d", $Scan.distro, "--exec", "bash", "-s", "--", $Scan.path)
    }
    "local" { Invoke-LocalScan $Scan.path }
  }
}

# Comparable form of a folder path. Local (Windows) paths are case-insensitive
# and may be written with either slash; remote paths are compared exactly.
function Format-PathKey([string]$Source, [string]$Path) {
  $n = $Path -replace '\\', '/'
  if ($n.Length -gt 1) { $n = $n.TrimEnd('/') }
  if ($Source -eq "local") { $n = $n.ToLowerInvariant() }
  return $n
}

function Get-ParentKey([string]$PathKey) {
  $i = $PathKey.LastIndexOf('/')
  if ($i -le 0) { return "/" }
  return $PathKey.Substring(0, $i)
}

# Where a project lives: which scan source could own it, and its folder path.
function Get-TargetLocation($Target) {
  if (-not $Target) { return $null }
  $source = $null; $path = $null
  switch ($Target.kind) {
    "ssh-devcontainer" { $source = "ssh|$($Target.profile)"; $path = $Target.hostPath }
    "ssh"              { $source = "ssh|$($Target.profile)"; $path = $Target.path }
    "wsl"              { $source = "wsl|$($Target.distro)";  $path = $Target.path }
    "local"            { $source = "local";                  $path = $Target.path }
  }
  if (-not $source -or -not $path) { return $null }
  $pathKey = Format-PathKey $source $path
  return [pscustomobject]@{ source = $source; pathKey = $pathKey; key = "$source|$pathKey" }
}

function Get-Scans($Config) {
  $profilesById = @{}
  foreach ($p in @($Config.profiles)) { if ($p -and $p.id) { $profilesById[$p.id] = $p } }

  $entries = @($Config.scans | Where-Object { $_ })
  foreach ($p in @($Config.profiles)) {
    if ($p -and $p.basePath) { $entries += [pscustomobject]@{ kind = "ssh"; profile = $p.id; path = $p.basePath } }
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($e in $entries) {
    $scan = $null
    switch ($e.kind) {
      "ssh" {
        $prof = $profilesById[[string]$e.profile]
        if (-not $prof) { throw "scan refers to unknown profile '$($e.profile)'" }
        $scan = @{ kind = "ssh"; source = "ssh|$($prof.id)"; idSuffix = $prof.id
                   profile = $prof.id; sshTarget = "$($prof.sshUser)@$($prof.sshHost)"
                   label = "$($prof.id):$($e.path)" }
      }
      "wsl" {
        if (-not $e.distro) { throw "wsl scan needs a 'distro'" }
        $scan = @{ kind = "wsl"; source = "wsl|$($e.distro)"; idSuffix = $e.distro
                   distro = $e.distro; label = "wsl $($e.distro):$($e.path)" }
      }
      "local" {
        $scan = @{ kind = "local"; source = "local"; idSuffix = "local"; label = "local:$($e.path)" }
      }
      default { throw "unknown scan kind '$($e.kind)' (expected ssh, wsl or local)" }
    }
    if (-not $e.path) { throw "$($e.kind) scan needs a 'path'" }
    $scan.path = [string]$e.path
    $scan.rootKey = "$($scan.source)|$(Format-PathKey $scan.source $scan.path)"
    if ($seen.Add($scan.rootKey)) { $scan }
  }
}

function Set-Prop($Obj, [string]$Name, $Value) {
  $Obj | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}

function New-Target($Scan, [string]$FullPath, $Found) {
  switch ($Scan.kind) {
    "ssh" {
      if ($Found.hasDc) {
        [pscustomobject]@{ kind = "ssh-devcontainer"; profile = $Scan.profile; hostPath = $FullPath
                           workspaceFolder = if ($Found.wsFolder) { $Found.wsFolder } else { "/workspace" } }
      } else {
        [pscustomobject]@{ kind = "ssh"; profile = $Scan.profile; path = $FullPath }
      }
    }
    "wsl"   { [pscustomobject]@{ kind = "wsl"; distro = $Scan.distro; path = $FullPath } }
    "local" { [pscustomobject]@{ kind = "local"; path = $FullPath } }
  }
}

function Write-Status($Status) {
  Write-DataFile -Path $statusPath -VarName "DOCKING_BAY_SCAN" -Json ($Status | ConvertTo-Json -Depth 10)
}

function Get-Timestamp { (Get-Date).ToUniversalTime().ToString("o") }

# Rescan can be triggered from several places at once (button, logon, timer);
# a second run while one is in flight has nothing to add.
$mutex = [System.Threading.Mutex]::new($false, "DockingBayRefresh")
$haveMutex = $false
try { $haveMutex = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $haveMutex = $true }
if (-not $haveMutex) {
  Write-Host "Another scan is already running."
  exit 0
}

try {
  Convert-LegacyData $root

  $config = Read-DataFile $configPath "DOCKING_BAY_CONFIG"
  $projects = @(Read-DataFile $projectsPath "DOCKING_BAY_PROJECTS")
  $beforeJson = ConvertTo-Json -InputObject $projects -Depth 10
  $scans = @(Get-Scans $config)

  $byKey = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  $usedIds = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
  foreach ($p in $projects) {
    [void]$usedIds.Add([string]$p.p)
    $loc = Get-TargetLocation $p.target
    if ($loc) { $byKey[$loc.key] = $p }
  }

  $seenByRoot = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
  $scanReports = @()
  $added = @()
  $colorChanged = @()

  foreach ($scan in $scans) {
    Write-Host "Scanning $($scan.label) ..." -ForegroundColor Cyan
    try {
      $found = @(Invoke-Scan $scan)
    } catch {
      # One unreachable location must not block the others, and its projects
      # are left exactly as they were (not flagged missing).
      Write-Host "  failed: $($_.Exception.Message)" -ForegroundColor Red
      $scanReports += [ordered]@{ label = $scan.label; ok = $false; found = 0; error = [string]$_.Exception.Message }
      continue
    }
    $scanReports += [ordered]@{ label = $scan.label; ok = $true; found = $found.Count; error = $null }

    $seen = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenByRoot[$scan.rootKey] = $seen
    $displayBase = ($scan.path -replace '\\', '/').TrimEnd('/')

    foreach ($f in $found) {
      $fullPath = "$displayBase/$($f.name)"
      $key = "$($scan.source)|$(Format-PathKey $scan.source $fullPath)"
      [void]$seen.Add($key)

      if ($byKey.ContainsKey($key)) {
        $proj = $byKey[$key]

        if ($scan.kind -eq "ssh" -and $f.hasDc) {
          if ($proj.target.kind -ne "ssh-devcontainer") {
            $proj.target = New-Target $scan $fullPath $f
          } elseif ($f.wsFolder -and $proj.target.workspaceFolder -ne $f.wsFolder) {
            Set-Prop $proj.target "workspaceFolder" $f.wsFolder
          }
        }

        if ($f.bg -and $proj.bg -ne $f.bg) { $colorChanged += "$($proj.p) (bg $($proj.bg) -> $($f.bg))"; Set-Prop $proj "bg" $f.bg }
        if ($f.fg -and $proj.fg -ne $f.fg) { $colorChanged += "$($proj.p) (fg $($proj.fg) -> $($f.fg))"; Set-Prop $proj "fg" $f.fg }

        if ($proj.PSObject.Properties.Name -contains "_missing") {
          $proj.PSObject.Properties.Remove("_missing")
        }
      } else {
        # "p" is the tile's unique id. The same folder name can turn up under
        # two scan locations, so a clash gets the source appended.
        $id = $f.name
        if (-not $usedIds.Add($id)) {
          $base = "$($f.name)@$($scan.idSuffix)"
          $id = $base
          $n = 2
          while (-not $usedIds.Add($id)) { $id = "$base-$n"; $n++ }
        }
        $newProj = [pscustomobject]@{
          p = $id
          t = $f.name
          e = "⚪"
          bg = if ($f.bg) { $f.bg } else { "#4B5563" }
          fg = if ($f.fg) { $f.fg } else { "#F9FAFB" }
          target = New-Target $scan $fullPath $f
          "_review" = $true
        }
        $projects += $newProj
        $byKey[$key] = $newProj
        $added += $id
      }
    }
  }

  # A project is missing only if the folder it sits in was scanned successfully
  # this run and it wasn't there. Anything outside the scanned folders (hand-
  # added entries, other hosts) is never touched.
  $missing = @()
  foreach ($p in $projects) {
    $loc = Get-TargetLocation $p.target
    if (-not $loc) { continue }
    $rootKey = "$($loc.source)|$(Get-ParentKey $loc.pathKey)"
    if (-not $seenByRoot.ContainsKey($rootKey)) { continue }
    if (-not $seenByRoot[$rootKey].Contains($loc.key)) {
      Set-Prop $p "_missing" $true
      $missing += $p.p
    }
  }

  # Only rewrite projects.js when something changed, so hand formatting survives
  # a scan that found nothing new.
  $afterJson = ConvertTo-Json -InputObject $projects -Depth 10
  if ($afterJson -ne $beforeJson) {
    Write-DataFile -Path $projectsPath -VarName "DOCKING_BAY_PROJECTS" -Json $afterJson
  }

  Write-Status ([ordered]@{
    at = Get-Timestamp
    scans = @($scanReports)
    added = @($added)
    missing = @($missing)
    colorChanged = @($colorChanged)
  })

  $failed = @($scanReports | Where-Object { -not $_.ok })
  Write-Host ""
  Write-Host "Done." -ForegroundColor Green
  Write-Host "  Locations scanned: $($scanReports.Count - $failed.Count) of $($scanReports.Count)"
  if ($failed.Count) { Write-Host "  Failed: $(($failed | ForEach-Object { $_.label }) -join ', ')" -ForegroundColor Red }
  if ($added.Count) { Write-Host "  Added (needs emoji/title review, flagged _review): $($added -join ', ')" -ForegroundColor Yellow } else { Write-Host "  Added: none" }
  if ($missing.Count) { Write-Host "  Missing on disk (flagged _missing, not deleted): $($missing -join ', ')" -ForegroundColor Yellow } else { Write-Host "  Missing: none" }
  if ($colorChanged.Count) { Write-Host "  Colors synced from .vscode/settings.json: $($colorChanged -join '; ')" } else { Write-Host "  Colors: no changes" }
  Write-Host ""
  if ($afterJson -ne $beforeJson) { Write-Host "projects.js updated: $projectsPath" } else { Write-Host "projects.js unchanged." }
} catch {
  # Surface the failure in the page too — a button-launched run has no console.
  try { Write-Status ([ordered]@{ at = Get-Timestamp; fatal = [string]$_.Exception.Message; scans = @(); added = @(); missing = @(); colorChanged = @() }) } catch { }
  throw
} finally {
  $mutex.ReleaseMutex()
}
