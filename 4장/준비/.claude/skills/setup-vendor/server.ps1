# Fake vendor MCP server (stdio). Windows PowerShell 5.1, no install needed.
# ASCII only on purpose: PowerShell 5.1 reads BOM-less .ps1 files as the system
# code page, so Korean text lives in vendor-data.json (read as UTF-8) instead.

$ErrorActionPreference = 'Stop'
$utf8 = New-Object System.Text.UTF8Encoding($false)
[Console]::InputEncoding  = $utf8
[Console]::OutputEncoding = $utf8

$dir     = Split-Path -Parent $MyInvocation.MyCommand.Path
$data    = Get-Content -Raw -Encoding UTF8 (Join-Path $dir 'vendor-data.json') | ConvertFrom-Json
$logPath = Join-Path $dir 'reservations.log'
$Words     = $data.text

function Send($obj) {
  $json = ConvertTo-Json -InputObject $obj -Depth 20 -Compress
  [Console]::Out.WriteLine($json)
  [Console]::Out.Flush()
}
function Reply($id, $result)       { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; result = $result }) }
function ReplyError($id, $c, $m)   { Send ([ordered]@{ jsonrpc = '2.0'; id = $id; error = [ordered]@{ code = $c; message = $m } }) }
function TextResult($text, $isErr) { [ordered]@{ content = @(@{ type = 'text'; text = $text }); isError = [bool]$isErr } }

function Call-Tool($name, $a) {
  switch ($name) {
    'get_vendor_info' {
      $lines = foreach ($p in $data.info.PSObject.Properties) { '{0}: {1}' -f $p.Name, $p.Value }
      return TextResult ($data.vendor + "`n" + ($lines -join "`n")) $false
    }
    'check_times' {
      $lines = foreach ($s in $data.times) { $Words.timeLine -f $s.time, $s.left }
      return TextResult ($Words.timesHeader + "`n" + ($lines -join "`n")) $false
    }
    'reserve' {
      $time  = [string]$a.time
      $carts = 0
      if (-not [int]::TryParse([string]$a.carts, [ref]$carts) -or $carts -lt 1) {
        return TextResult $Words.badCarts $true
      }
      $slot = $data.times | Where-Object { $_.time -eq $time } | Select-Object -First 1
      if (-not $slot)            { return TextResult ($Words.noSuchTime -f $time) $true }
      if ($slot.left -lt $carts) { return TextResult ($Words.notEnough -f $time, $slot.left) $true }
      $slot.left = $slot.left - $carts
      $who  = [string]$a.name
      $line = "{0}`t{1}`t{2}`t{3}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $time, $carts, $who
      [IO.File]::AppendAllText($logPath, $line + "`r`n", $utf8)
      return TextResult ($Words.reserved -f $time, $carts) $false
    }
    default { return $null }
  }
}

while ($true) {
  $raw = [Console]::In.ReadLine()
  if ($null -eq $raw) { break }
  if ($raw.Trim() -eq '') { continue }
  try { $msg = $raw | ConvertFrom-Json } catch { continue }
  $hasId = $msg.PSObject.Properties.Name -contains 'id'

  switch ($msg.method) {
    'initialize' {
      $pv = $msg.params.protocolVersion
      if (-not $pv) { $pv = '2025-06-18' }
      Reply $msg.id ([ordered]@{
        protocolVersion = $pv
        capabilities    = @{ tools = @{} }
        serverInfo      = @{ name = 'gapyeong-railbike'; version = '1.0.0' }
      })
    }
    'tools/list' { Reply $msg.id @{ tools = @($data.tools) } }
    'tools/call' {
      try {
        $r = Call-Tool $msg.params.name $msg.params.arguments
        if ($null -eq $r) { ReplyError $msg.id ([int]-32602) ('Unknown tool: ' + $msg.params.name) }
        else { Reply $msg.id $r }
      } catch {
        Reply $msg.id (TextResult ('Server error: ' + $_.Exception.Message) $true)
      }
    }
    'ping'    { Reply $msg.id @{} }
    default   { if ($hasId) { ReplyError $msg.id ([int]-32601) ('Method not found: ' + $msg.method) } }
  }
}
