<#
  Kraken Game Art - media bridge
  Serves what Windows says is playing (the media flyout / SMTC: Apple Music, browsers,
  most players) at http://localhost:8766 so the Kraken page can show it.

    /media       -> JSON { playing, title, artist, album, app, art }
    /art         -> current cover art image
    /            -> this folder's index.html (so CAM can point at http://localhost:8766/?user=...)

  Run:      powershell -ExecutionPolicy Bypass -File media-bridge.ps1
  Install:  powershell -ExecutionPolicy Bypass -File media-bridge.ps1 -Install
            (copies to %LOCALAPPDATA%\KrakenGameArt and starts it hidden at logon)
  Must run in Windows PowerShell 5.1 (powershell.exe), not PowerShell 7.

  Only answers requests from this PC, and only lets these web pages read it (so other
  sites you visit can't see what you're listening to): -AllowOrigin to change.
#>
param([int]$Port = 8766, [switch]$Install, [switch]$Uninstall,
      [string[]]$AllowOrigin = @('https://slaterdamian.github.io'))

$ErrorActionPreference = 'Stop'
$dest = Join-Path $env:LOCALAPPDATA 'KrakenGameArt'
$lnk  = Join-Path ([Environment]::GetFolderPath('Startup')) 'Kraken Game Art bridge.lnk'

function Stop-Bridge {
  Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
    Where-Object { $_.CommandLine -like '*media-bridge.ps1*' -and $_.ProcessId -ne $PID } |
    ForEach-Object { Stop-Process -Id $_.ProcessId }
}

if ($Uninstall) {
  Remove-Item $lnk -ErrorAction SilentlyContinue
  Stop-Bridge
  Write-Host "Removed startup shortcut and stopped the bridge. Files left in $dest."
  return
}

if ($Install) {
  Stop-Bridge   # replaces an older running copy
  New-Item -ItemType Directory -Force $dest | Out-Null
  Copy-Item $PSCommandPath (Join-Path $dest 'media-bridge.ps1') -Force
  $page = Join-Path $PSScriptRoot 'index.html'
  if (Test-Path $page) { Copy-Item $page (Join-Path $dest 'index.html') -Force }
  $argList = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$dest\media-bridge.ps1`" -Port $Port"
  $sh = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
  $sh.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
  $sh.Arguments = $argList
  $sh.WindowStyle = 7
  $sh.Save()
  Start-Process $sh.TargetPath -ArgumentList $argList -WindowStyle Hidden
  Write-Host "Installed to $dest and started. It will launch at logon. Test: http://localhost:$Port/media"
  return
}

# ---------------- WinRT plumbing ----------------
Add-Type -AssemblyName System.Runtime.WindowsRuntime
$asTaskOp = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
  $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
  $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
function Await($op, [Type]$type) {
  $task = $asTaskOp.MakeGenericMethod($type).Invoke($null, @($op))
  $null = $task.Wait(5000)
  $task.Result
}
$null = [Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager, Windows.Media.Control, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.IRandomAccessStreamWithContentType, Windows.Storage.Streams, ContentType = WindowsRuntime]
# PowerShell only sees the thumbnail stream as a bare COM object, so these are called through reflection.
$asStreamForRead = [System.IO.WindowsRuntimeStreamExtensions].GetMethod('AsStreamForRead', [Type[]]@([Windows.Storage.Streams.IInputStream]))
$contentTypeProp = [Windows.Storage.Streams.IContentTypeProvider].GetProperty('ContentType')
$mgr = Await ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager]::RequestAsync()) `
             ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager])

function Get-AppName([string]$aumid) {
  switch -Regex ($aumid) {
    'AppleMusic|iTunes' { 'Apple Music'; break }
    'Spotify'           { 'Spotify'; break }
    'chrome'            { 'Chrome'; break }
    'msedge|Edge'       { 'Edge'; break }
    'firefox'           { 'Firefox'; break }
    'ZuneMusic'         { 'Media Player'; break }
    default             { ($aumid -replace '^.*[\\/]', '' -replace '\.exe$', '' -replace '_.*$', '') }
  }
}

$script:art = @{ key = $null; bytes = $null; type = 'image/jpeg' }

function Get-NowPlaying {
  $s = $mgr.GetCurrentSession()
  if (-not $s) { return @{ playing = $false } }
  $status = $s.GetPlaybackInfo().PlaybackStatus.ToString()
  $p = Await ($s.TryGetMediaPropertiesAsync()) ([Windows.Media.Control.GlobalSystemMediaTransportControlsSessionMediaProperties])
  if (-not $p -or -not $p.Title) { return @{ playing = $false } }
  $key = "$($s.SourceAppUserModelId)|$($p.Title)|$($p.Artist)|$($p.AlbumTitle)"
  if ($script:art.key -ne $key) { $script:art = @{ key = $key; bytes = $null; type = 'image/jpeg' } }
  # Players often publish the title before the artwork, so keep trying until we have it.
  if (-not $script:art.bytes -and $p.Thumbnail) {
    try {
      $ws = Await ($p.Thumbnail.OpenReadAsync()) ([Windows.Storage.Streams.IRandomAccessStreamWithContentType])
      $ms = New-Object System.IO.MemoryStream
      $asStreamForRead.Invoke($null, @($ws)).CopyTo($ms)
      if ($ms.Length -gt 0) { $script:art.bytes = $ms.ToArray() }
      $ct = "$($contentTypeProp.GetValue($ws))".Split(',')[0]
      if ($ct) { $script:art.type = $ct }
    } catch { }
  }

  # Apple Music puts "Artist - Album" (with a long dash) in the artist field and leaves the album empty.
  $artist = if ($p.Artist) { $p.Artist } else { $p.AlbumArtist }
  $album = $p.AlbumTitle
  if (-not $album -and $artist -match "^(.+?) $([char]0x2014) (.+)$") { $artist = $Matches[1]; $album = $Matches[2] }

  $tl = $s.GetTimelineProperties()
  $epoch = [DateTimeOffset]::new(1970, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
  @{
    playing  = ($status -eq 'Playing')
    status   = $status
    title    = $p.Title
    artist   = $artist
    album    = $album
    app      = Get-AppName $s.SourceAppUserModelId
    art      = if ($script:art.bytes) { "/art?v=" + [Math]::Abs($key.GetHashCode()) } else { $null }
    position = $tl.Position.TotalSeconds
    duration = ($tl.EndTime - $tl.StartTime).TotalSeconds
    at       = [long]($tl.LastUpdatedTime - $epoch).TotalMilliseconds   # when position was measured
  }
}

# ---------------- HTTP server ----------------
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "Media bridge on http://localhost:$Port  (Ctrl+C to stop)"

# powershell -File passes "a,b" as one string, so split it here.
$allowed = @($AllowOrigin -split ',' | ForEach-Object { $_.Trim().TrimEnd('/') } | Where-Object { $_ }) + "http://localhost:$Port"

# Who may read the bridge: this PC only, and browsers only from the allowed pages.
# Requests with no Origin that a browser marks cross-site (e.g. <img> on another site) are refused too;
# ones without browser headers (typing the URL, curl) are fine.
function Test-Allowed($req) {
  if (-not $req.IsLocal) { return $false }
  $origin = $req.Headers['Origin']
  if ($origin) { return $allowed -contains $origin }
  return $req.Headers['Sec-Fetch-Site'] -notin @('cross-site', 'same-site')
}

function Send($ctx, [byte[]]$body, [string]$type, [int]$code = 200) {
  $r = $ctx.Response
  $r.StatusCode = $code
  $r.ContentType = $type
  $origin = $ctx.Request.Headers['Origin']
  if ($origin -and $allowed -contains $origin) {
    $r.Headers['Access-Control-Allow-Origin'] = $origin
    $r.Headers['Access-Control-Allow-Private-Network'] = 'true'
  }
  $r.Headers['Vary'] = 'Origin'
  $r.Headers['X-Content-Type-Options'] = 'nosniff'
  $r.Headers['Cache-Control'] = 'no-store'
  if ($body) { $r.ContentLength64 = $body.Length; $r.OutputStream.Write($body, 0, $body.Length) }
  $r.Close()
}

while ($listener.IsListening) {
  $ctx = $listener.GetContext()
  try {
    if (-not (Test-Allowed $ctx.Request)) { Send $ctx $null 'text/plain' 403; continue }
    if ($ctx.Request.HttpMethod -eq 'OPTIONS') { Send $ctx $null 'text/plain' 204; continue }
    if ($ctx.Request.HttpMethod -ne 'GET') { Send $ctx $null 'text/plain' 405; continue }
    switch ($ctx.Request.Url.AbsolutePath) {
      '/media' {
        $json = Get-NowPlaying | ConvertTo-Json -Compress
        Send $ctx ([Text.Encoding]::UTF8.GetBytes($json)) 'application/json; charset=utf-8'
      }
      '/art' {
        if ($script:art.bytes) { Send $ctx $script:art.bytes $script:art.type }
        else { Send $ctx $null 'text/plain' 404 }
      }
      { $_ -in '/', '/index.html' } {
        $page = Join-Path $PSScriptRoot 'index.html'
        if (Test-Path $page) { Send $ctx ([IO.File]::ReadAllBytes($page)) 'text/html; charset=utf-8' }
        else { Send $ctx ([Text.Encoding]::UTF8.GetBytes('index.html not found next to media-bridge.ps1')) 'text/plain' 404 }
      }
      default { Send $ctx $null 'text/plain' 404 }
    }
  } catch {
    Write-Host "Error: $_"
    try { Send $ctx $null 'text/plain' 500 } catch { }
  }
}
