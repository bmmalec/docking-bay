#Requires -Version 7.0
<#
.SYNOPSIS
  Shared helpers for reading/writing the launcher's data files. Dot-sourced by
  refresh-projects.ps1 and install-launcher.ps1 — not meant to be run directly.

  The data files are JSON wrapped in a single assignment
  (`window.DOCKING_BAY_X = <json>;`) so the page can load them with a plain
  <script> tag straight from disk, with no server and no fetch().
#>

function Read-DataFile([string]$Path, [string]$VarName) {
  $raw = Get-Content -LiteralPath $Path -Raw
  $m = [regex]::Match($raw, "window\.$VarName\s*=")
  if (-not $m.Success) { throw "$Path must start with 'window.$VarName = '" }
  $body = $raw.Substring($m.Index + $m.Length).Trim()
  if ($body.EndsWith(";")) { $body = $body.Substring(0, $body.Length - 1) }
  return $body | ConvertFrom-Json
}

function Write-DataFile([string]$Path, [string]$VarName, [string]$Json) {
  # Write-then-rename so the page never loads a half-written file.
  $tmp = "$Path.tmp"
  Set-Content -LiteralPath $tmp -Value "window.$VarName = $Json;" -Encoding utf8
  Move-Item -LiteralPath $tmp -Destination $Path -Force
}

# One-time upgrade from the old fetch()-based layout: a leftover projects.json /
# launcher.config.json is wrapped as-is (formatting preserved) into the matching
# .js file, and the original is kept alongside as .json.bak.
function Convert-LegacyData([string]$Root) {
  $pairs = @(
    @{ Old = "projects.json";        New = "projects.js";        Var = "DOCKING_BAY_PROJECTS" },
    @{ Old = "launcher.config.json"; New = "launcher.config.js"; Var = "DOCKING_BAY_CONFIG" }
  )
  foreach ($pair in $pairs) {
    $old = Join-Path $Root $pair.Old
    if (-not (Test-Path -LiteralPath $old -PathType Leaf)) { continue }
    $raw = (Get-Content -LiteralPath $old -Raw).Trim()
    $null = $raw | ConvertFrom-Json   # refuse to wrap something that isn't valid JSON
    Write-DataFile -Path (Join-Path $Root $pair.New) -VarName $pair.Var -Json $raw
    Move-Item -LiteralPath $old -Destination "$old.bak" -Force
    Write-Host "Migrated $($pair.Old) -> $($pair.New) (original kept as $($pair.Old).bak)" -ForegroundColor Yellow
  }
}
