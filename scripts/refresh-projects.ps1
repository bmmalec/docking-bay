<#
.SYNOPSIS
  Manual, on-demand refresh of projects.json: SSHes to every profile in
  launcher.config.json (reusing your existing key/config — nothing new is
  provisioned) and does a read-only scan of each profile's basePath for
  devcontainer configs and the per-project titlebar colors already applied
  under the family/hue convention. Merges non-destructively: never overwrites
  emoji or a manually-set target, never silently deletes an entry. Profiles
  with no basePath (nothing to scan) are skipped.
#>
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$configPath = Join-Path $root "launcher.config.json"
$projectsPath = Join-Path $root "projects.json"

$config = Get-Content $configPath -Raw | ConvertFrom-Json
$projects = @(Get-Content $projectsPath -Raw | ConvertFrom-Json)

# Single fixed, read-only remote script. basePath arrives as $1 (bash positional
# arg, passed via `ssh ... bash -s -- <basePath>`) — never string-interpolated
# into the script text, and directory names found on the remote are only ever
# treated as data (basename/printf), never re-run as commands.
$remoteScript = @'
BASE="$1"
for d in "$BASE"/*/; do
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

function Scan-Profile($sshTarget, $basePath) {
  # Piping a multi-line string through PowerShell's pipeline to a native
  # process's stdin appends a stray \r before the final line (corrupts a
  # trailing "done" into "done\r"), so this writes raw UTF8 bytes to ssh's
  # stdin directly instead.
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = "ssh"
  $psi.ArgumentList.Add($sshTarget)
  $psi.ArgumentList.Add("bash")
  $psi.ArgumentList.Add("-s")
  $psi.ArgumentList.Add("--")
  $psi.ArgumentList.Add($basePath)
  $psi.RedirectStandardInput = $true
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
  $psi.UseShellExecute = $false

  $proc = [System.Diagnostics.Process]::Start($psi)
  $proc.StandardInput.Write($remoteScript)
  $proc.StandardInput.Close()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($proc.ExitCode -ne 0) {
    throw "ssh to $sshTarget failed (exit $($proc.ExitCode)): $stderr"
  }
  return $stdout -split "`n" | Where-Object { $_ -ne "" }
}

$existingByName = @{}
foreach ($p in $projects) { $existingByName[$p.p] = $p }

$remoteNamesByProfile = @{}
$added = @()
$colorChanged = @()

foreach ($profile in $config.profiles) {
  if (-not $profile.basePath) { continue }
  $sshTarget = "$($profile.sshUser)@$($profile.sshHost)"
  Write-Host "Scanning $($profile.basePath) on $sshTarget ($($profile.id)) ..." -ForegroundColor Cyan
  $lines = Scan-Profile -sshTarget $sshTarget -basePath $profile.basePath

  $remoteNames = New-Object System.Collections.Generic.HashSet[string]
  $remoteNamesByProfile[$profile.id] = $remoteNames

  foreach ($line in $lines) {
    if (-not $line) { continue }
    $fields = $line -split ([char]0x1F)
    if ($fields.Count -lt 6) { continue }
    $name, $hasDcStr, $wsFolder, $title, $bg, $fg = $fields
    [void]$remoteNames.Add($name)
    $hasDc = $hasDcStr -eq "1"
    $hostPath = "$($profile.basePath)/$name"

    if ($existingByName.ContainsKey($name)) {
      $proj = $existingByName[$name]

      if (-not $proj.target -or $proj.target.profile -ne $profile.id) {
        # not owned by this profile (e.g. a local/wsl entry with the same
        # folder name, or targets a different profile) — leave it alone
      } else {
        if ($hasDc -and $proj.target.kind -ne "ssh-devcontainer") {
          $proj.target = [pscustomobject]@{
            kind = "ssh-devcontainer"; profile = $profile.id; hostPath = $hostPath
            workspaceFolder = if ($wsFolder) { $wsFolder } else { "/workspace" }
          }
        } elseif ($hasDc -and $wsFolder -and $proj.target.workspaceFolder -ne $wsFolder) {
          $proj.target.workspaceFolder = $wsFolder
        }

        if ($bg -and $proj.bg -ne $bg) { $colorChanged += "$name (bg $($proj.bg) -> $bg)"; $proj.bg = $bg }
        if ($fg -and $proj.fg -ne $fg) { $colorChanged += "$name (fg $($proj.fg) -> $fg)"; $proj.fg = $fg }

        if ($proj.PSObject.Properties.Name -contains "_missing") {
          $proj.PSObject.Properties.Remove("_missing")
        }
      }
    } else {
      $target = if ($hasDc) {
        [pscustomobject]@{ kind = "ssh-devcontainer"; profile = $profile.id; hostPath = $hostPath; workspaceFolder = if ($wsFolder) { $wsFolder } else { "/workspace" } }
      } else {
        [pscustomobject]@{ kind = "ssh"; profile = $profile.id; path = $hostPath }
      }
      $newProj = [pscustomobject]@{
        p = $name
        t = $name
        e = "⚪"
        bg = if ($bg) { $bg } else { "#4B5563" }
        fg = if ($fg) { $fg } else { "#F9FAFB" }
        target = $target
        "_review" = $true
      }
      $projects += $newProj
      $existingByName[$name] = $newProj
      $added += $name
    }
  }
}

$missing = @()
foreach ($p in $projects) {
  if (-not $p.target -or -not $p.target.profile) { continue }
  $scanned = $remoteNamesByProfile[$p.target.profile]
  if (-not $scanned) { continue }
  if (-not $scanned.Contains($p.p)) {
    if (-not ($p.PSObject.Properties.Name -contains "_missing")) {
      $p | Add-Member -NotePropertyName "_missing" -NotePropertyValue $true -Force
    }
    $missing += $p.p
  }
}

$json = $projects | ConvertTo-Json -Depth 10
Set-Content -Path $projectsPath -Value $json -Encoding utf8

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "  Profiles scanned: $($remoteNamesByProfile.Keys -join ', ')"
if ($added.Count) { Write-Host "  Added (needs emoji/title review, flagged _review): $($added -join ', ')" -ForegroundColor Yellow } else { Write-Host "  Added: none" }
if ($missing.Count) { Write-Host "  Missing on disk (flagged _missing, not deleted): $($missing -join ', ')" -ForegroundColor Yellow } else { Write-Host "  Missing: none" }
if ($colorChanged.Count) { Write-Host "  Colors synced from .vscode/settings.json: $($colorChanged -join '; ')" } else { Write-Host "  Colors: no changes" }
Write-Host ""
Write-Host "projects.json updated: $projectsPath"
