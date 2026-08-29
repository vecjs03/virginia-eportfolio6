# One-shot converter: Claude Design canvas bundle -> plain static site.
#
# Reads the bundled export (a single huge .html whose real page lives in a
# JSON-escaped string, with every image/font/script base64'd beside it) and
# writes a normal, hand-editable site:
#
#   index.html          the page, with real relative asset paths
#   assets/img/*        photos, named after the slot they fill
#   assets/fonts/*      woff2 subsets
#   assets/js/*         dc-runtime, image-slot, react, react-dom
#
# This is kept for provenance / re-running against a fresh canvas export.
# Day-to-day editing happens directly in index.html.
#
# Usage: powershell -ExecutionPolicy Bypass -File tools\unpack-bundle.ps1 `
#          -Bundle index.html.html -OutDir .

param(
  [string]$Bundle = "index.html.html",
  [string]$OutDir = "."
)

$ErrorActionPreference = 'Stop'
$Bundle = (Resolve-Path $Bundle).Path
$OutDir = (Resolve-Path $OutDir).Path

$extForMime = @{
  'image/jpeg'      = '.jpg'
  'image/png'       = '.png'
  'image/webp'      = '.webp'
  'image/gif'       = '.gif'
  'image/svg+xml'   = '.svg'
  'image/avif'      = '.avif'
  'font/woff2'      = '.woff2'
  'font/woff'       = '.woff'
  'text/javascript' = '.js'
  'text/css'        = '.css'
}

function Get-Slug([string]$s) {
  $s = $s.ToLowerInvariant() -replace "[^a-z0-9]+", "-"
  return $s.Trim('-')
}

function Expand-Gzip([byte[]]$bytes) {
  $ms  = New-Object System.IO.MemoryStream(, $bytes)
  $gz  = New-Object System.IO.Compression.GZipStream($ms, [System.IO.Compression.CompressionMode]::Decompress)
  $out = New-Object System.IO.MemoryStream
  $gz.CopyTo($out)
  $gz.Dispose(); $ms.Dispose()
  return $out.ToArray()
}

# ---------------------------------------------------------------- read bundle
Write-Output "Reading $Bundle ..."
$lines = [System.IO.File]::ReadAllLines($Bundle)

function Get-IslandJson([string]$type) {
  for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match ('<script type="__bundler/' + [regex]::Escape($type) + '">')) {
      return $lines[$i + 1]
    }
  }
  throw "Could not find bundler island '$type'"
}

$manifest     = Get-IslandJson 'manifest'     | ConvertFrom-Json
$extResources = Get-IslandJson 'ext_resources' | ConvertFrom-Json
$template     = Get-IslandJson 'template'      | ConvertFrom-Json

Write-Output ("  template: {0} chars" -f $template.Length)
Write-Output ("  assets:   {0}" -f @($manifest.PSObject.Properties).Count)

# ------------------------------------------------------------- build name map
# uuid -> "assets/<sub>/<name><ext>"
$names = @{}   # uuid -> base name (no extension)
$folder = @{}  # uuid -> img | fonts | js

# 1. Images filling a named <image-slot id="v2-foo-bar" src="uuid">
foreach ($m in [regex]::Matches($template, '<image-slot\b[^>]*>')) {
  $id  = [regex]::Match($m.Value, 'id="([^"]*)"').Groups[1].Value
  $uid = [regex]::Match($m.Value, 'src="([^"]*)"').Groups[1].Value
  if ($uid -and $id) {
    $names[$uid]  = Get-Slug ($id -replace '^v2-', '')
    $folder[$uid] = 'img'
  }
}

# 2. Deck images: <img src="uuid" alt="Slide N">
foreach ($m in [regex]::Matches($template, '<img\b[^>]*>')) {
  $uid = [regex]::Match($m.Value, 'src="([^"]*)"').Groups[1].Value
  $alt = [regex]::Match($m.Value, 'alt="([^"]*)"').Groups[1].Value
  if ($uid -and -not $names.ContainsKey($uid)) {
    if ($alt -match '^Slide\s+(\d+)$') {
      $names[$uid] = 'deck-slide-{0:d2}' -f [int]$Matches[1]
    } elseif ($alt) {
      $names[$uid] = Get-Slug $alt
    }
    $folder[$uid] = 'img'
  }
}

# 3. Fonts: family/style/weight/subset from each @font-face block.
#    A single woff2 is often shared across weights (e.g. Karla 400/500/600),
#    so drop the weight from the name when it is not what distinguishes files.
$faces = @{}   # uuid -> list of @{family;style;weight;subset}
foreach ($m in [regex]::Matches($template, '(?:/\*\s*([a-z\-]+)\s*\*/\s*)?@font-face\s*\{[^}]*\}')) {
  $uid = [regex]::Match($m.Value, 'url\("([^"]*)"\)').Groups[1].Value
  if (-not $uid) { continue }
  if (-not $faces.ContainsKey($uid)) { $faces[$uid] = @() }
  $faces[$uid] += ,@{
    family = [regex]::Match($m.Value, "font-family:\s*'([^']*)'").Groups[1].Value
    style  = [regex]::Match($m.Value, 'font-style:\s*([a-z]+)').Groups[1].Value
    weight = [regex]::Match($m.Value, 'font-weight:\s*([0-9]+)').Groups[1].Value
    subset = $m.Groups[1].Value
  }
}
foreach ($uid in $faces.Keys) {
  $f = $faces[$uid]
  $first = $f[0]
  $weights = ($f | ForEach-Object { $_.weight } | Sort-Object -Unique)
  $parts = @((Get-Slug $first.family))
  if ($first.style -and $first.style -ne 'normal') { $parts += $first.style }
  if (@($weights).Count -eq 1) { $parts += $first.weight }
  if ($first.subset) { $parts += $first.subset }
  $names[$uid]  = ($parts -join '-')
  $folder[$uid] = 'fonts'
}

# 4. Scripts pulled from a CDN keep their published filename.
foreach ($e in $extResources) {
  $names[$e.uuid]  = [System.IO.Path]::GetFileNameWithoutExtension(($e.id -split '/')[-1])
  $folder[$e.uuid] = 'js'
}

# 5. The two local runtime scripts.
$known = @{
  'a264599c-fa8a-4ea6-b120-8120dd344b57' = 'dc-runtime'
  '8860ef81-ce40-470a-a1d0-4011735959ba' = 'image-slot'
}
foreach ($k in $known.Keys) {
  if ($manifest.PSObject.Properties.Name -contains $k) {
    $names[$k]  = $known[$k]
    $folder[$k] = 'js'
  }
}

# 6. Anything left over: fall back to mime + short uuid.
foreach ($p in $manifest.PSObject.Properties) {
  if ($names.ContainsKey($p.Name)) { continue }
  $kind = ($p.Value.mime -split '/')[0]
  $names[$p.Name]  = "$kind-" + $p.Name.Substring(0, 8)
  $folder[$p.Name] = if ($kind -eq 'image') { 'img' } elseif ($kind -eq 'font') { 'fonts' } else { 'js' }
  Write-Output ("  note: unnamed asset {0} -> {1}" -f $p.Name, $names[$p.Name])
}

# ------------------------------------------------------------- write assets
foreach ($sub in @('img', 'fonts', 'js')) {
  $d = Join-Path $OutDir "assets\$sub"
  if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d | Out-Null }
}

$paths = @{}   # uuid -> relative path used in the HTML
$used  = @{}   # guard against two assets claiming one filename
foreach ($p in $manifest.PSObject.Properties) {
  $uid   = $p.Name
  $entry = $p.Value
  $ext   = $extForMime[$entry.mime]
  if (-not $ext) { $ext = '.bin' }

  $base = $names[$uid]
  $name = $base + $ext
  if ($used.ContainsKey($name)) {
    $name = $base + '-' + $uid.Substring(0, 8) + $ext
  }
  $used[$name] = $true

  $bytes = [Convert]::FromBase64String($entry.data)
  if ($entry.compressed) { $bytes = Expand-Gzip $bytes }

  $rel = "assets/" + $folder[$uid] + "/" + $name
  [System.IO.File]::WriteAllBytes((Join-Path $OutDir ($rel -replace '/', '\')), $bytes)
  $paths[$uid] = $rel
}
Write-Output ("Wrote {0} asset files." -f $paths.Count)

# ----------------------------------------------------------- rewrite template
# The bundler swapped each uuid for a blob: URL by plain string replace; we do
# the same, but with a real relative path.
foreach ($uid in $paths.Keys) {
  $template = $template.Replace($uid, $paths[$uid])
}

# SRI/crossorigin refer to the CDN copies, which we no longer fetch.
$template = [regex]::Replace($template, '\s+integrity="[^"]*"', '')
$template = [regex]::Replace($template, '\s+crossorigin="[^"]*"', '')

# The runtime resolves bare CDN ids through window.__resources; point those at
# the vendored copies. Injected after <head> so the DOCTYPE stays first.
$resourceMap = @{}
foreach ($e in $extResources) {
  if ($paths.ContainsKey($e.uuid)) { $resourceMap[$e.id] = $paths[$e.uuid] }
}
$json = ($resourceMap | ConvertTo-Json -Compress) -replace '</', '<\/'
$inject = "`n<script>window.__resources = $json;</script>"

$headMatch = [regex]::Match($template, '<head[^>]*>', 'IgnoreCase')
if (-not $headMatch.Success) { throw "Template has no <head> to inject into" }
$at = $headMatch.Index + $headMatch.Length
$template = $template.Substring(0, $at) + $inject + $template.Substring($at)

$outFile = Join-Path $OutDir 'index.html'
[System.IO.File]::WriteAllText($outFile, $template, (New-Object System.Text.UTF8Encoding $false))
Write-Output "Wrote $outFile"
