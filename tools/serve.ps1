# Minimal static file server for local preview.
# Usage: powershell -ExecutionPolicy Bypass -File tools\serve.ps1 [-Port 8099] [-Root <dir>]

param(
  [int]$Port = 8099,
  [string]$Root = (Split-Path -Parent $PSScriptRoot)
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path $Root).Path

$mime = @{
  '.html' = 'text/html; charset=utf-8'
  '.htm'  = 'text/html; charset=utf-8'
  '.css'  = 'text/css; charset=utf-8'
  '.js'   = 'text/javascript; charset=utf-8'
  '.mjs'  = 'text/javascript; charset=utf-8'
  '.json' = 'application/json; charset=utf-8'
  '.svg'  = 'image/svg+xml'
  '.png'  = 'image/png'
  '.jpg'  = 'image/jpeg'
  '.jpeg' = 'image/jpeg'
  '.gif'  = 'image/gif'
  '.webp' = 'image/webp'
  '.avif' = 'image/avif'
  '.ico'  = 'image/x-icon'
  '.woff' = 'font/woff'
  '.woff2'= 'font/woff2'
  '.ttf'  = 'font/ttf'
  '.otf'  = 'font/otf'
  '.pdf'  = 'application/pdf'
  '.txt'  = 'text/plain; charset=utf-8'
  '.map'  = 'application/json; charset=utf-8'
}

$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
try {
  $listener.Start()
} catch {
  Write-Output "FAILED to bind http://localhost:$Port/ -- $($_.Exception.Message)"
  exit 1
}

Write-Output "Serving $Root at http://localhost:$Port/"

while ($listener.IsListening) {
  try {
    $ctx = $listener.GetContext()
  } catch {
    break
  }

  $req = $ctx.Request
  $res = $ctx.Response

  try {
    $rel = [System.Uri]::UnescapeDataString($req.Url.AbsolutePath).TrimStart('/')
    if ([string]::IsNullOrWhiteSpace($rel)) { $rel = 'index.html' }
    $rel = $rel -replace '/', '\'

    $full = Join-Path $Root $rel

    # Directory -> index.html inside it
    if ((Test-Path -LiteralPath $full) -and ((Get-Item -LiteralPath $full).PSIsContainer)) {
      $full = Join-Path $full 'index.html'
    }

    # Refuse to escape the root
    $resolved = $null
    try { $resolved = (Resolve-Path -LiteralPath $full).Path } catch { $resolved = $null }

    if ($null -eq $resolved -or -not $resolved.StartsWith($Root, [StringComparison]::OrdinalIgnoreCase)) {
      $res.StatusCode = 404
      $bytes = [System.Text.Encoding]::UTF8.GetBytes("404 Not Found: /$rel")
      $res.ContentType = 'text/plain; charset=utf-8'
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      Write-Output "404 $($req.Url.AbsolutePath)"
    } else {
      $ext = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
      $ct = $mime[$ext]
      if (-not $ct) { $ct = 'application/octet-stream' }

      $bytes = [System.IO.File]::ReadAllBytes($resolved)
      $res.StatusCode = 200
      $res.ContentType = $ct
      # Always revalidate so edits show up on reload
      $res.Headers.Add('Cache-Control', 'no-store, must-revalidate')
      $res.ContentLength64 = $bytes.Length
      $res.OutputStream.Write($bytes, 0, $bytes.Length)
      Write-Output "200 $($req.Url.AbsolutePath) ($($bytes.Length) bytes)"
    }
  } catch {
    try {
      $res.StatusCode = 500
      $msg = [System.Text.Encoding]::UTF8.GetBytes("500 $($_.Exception.Message)")
      $res.ContentType = 'text/plain; charset=utf-8'
      $res.ContentLength64 = $msg.Length
      $res.OutputStream.Write($msg, 0, $msg.Length)
    } catch {}
    Write-Output "500 $($req.Url.AbsolutePath) -- $($_.Exception.Message)"
  } finally {
    try { $res.OutputStream.Close() } catch {}
  }
}
