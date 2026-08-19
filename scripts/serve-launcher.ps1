<#
.SYNOPSIS
  Zero-dependency static file server for project-launcher.html (pure PowerShell,
  no Python/Node required). PWA install and the service worker both need the app
  served over http://, not opened as a file:// page.
#>
param(
  [int]$Port = 8420
)

$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

$mime = @{
  ".html"       = "text/html; charset=utf-8"
  ".js"         = "text/javascript; charset=utf-8"
  ".json"       = "application/json; charset=utf-8"
  ".webmanifest" = "application/manifest+json; charset=utf-8"
  ".svg"        = "image/svg+xml"
  ".ico"        = "image/x-icon"
}

function Get-FreePort([int]$Start) {
  for ($p = $Start; $p -lt $Start + 20; $p++) {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $p)
    try {
      $listener.Start()
      $listener.Stop()
      return $p
    } catch { }
  }
  throw "No free port found in range $Start-$($Start+20)"
}

$Port = Get-FreePort -Start $Port
$prefix = "http://localhost:$Port/"

$listener = [System.Net.HttpListener]::new()
$listener.Prefixes.Add($prefix)
$listener.Start()

Write-Host "Serving $root"
Write-Host "  -> $prefix" -ForegroundColor Cyan
Write-Host "  -> $($prefix)project-launcher.html" -ForegroundColor Cyan
Write-Host "Ctrl+C to stop."

Start-Process "$($prefix)project-launcher.html"

try {
  while ($listener.IsListening) {
    $context = $listener.GetContext()
    $request = $context.Request
    $response = $context.Response
    try {
      $reqPath = [Uri]::UnescapeDataString($request.Url.AbsolutePath)
      if ($reqPath -eq "/") { $reqPath = "/project-launcher.html" }

      $fullPath = [System.IO.Path]::GetFullPath((Join-Path $root $reqPath.TrimStart('/')))

      if (-not $fullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) {
        $response.StatusCode = 403
        $response.Close()
        continue
      }
      if (-not (Test-Path $fullPath -PathType Leaf)) {
        $response.StatusCode = 404
        $response.Close()
        continue
      }

      $ext = [System.IO.Path]::GetExtension($fullPath).ToLowerInvariant()
      $contentType = $mime[$ext]
      if (-not $contentType) { $contentType = "application/octet-stream" }
      $response.ContentType = $contentType
      # No caching: this is a local dev server, and a stale HTTP cache can feed
      # old bytes even to the service worker's own install fetch.
      $response.Headers.Add("Cache-Control", "no-store, no-cache, must-revalidate")

      $bytes = [System.IO.File]::ReadAllBytes($fullPath)
      $response.ContentLength64 = $bytes.Length
      $response.OutputStream.Write($bytes, 0, $bytes.Length)
    } catch {
      try { $response.StatusCode = 500 } catch { }
    } finally {
      $response.Close()
    }
  }
} finally {
  $listener.Stop()
  $listener.Close()
}
