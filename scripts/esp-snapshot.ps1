# esp-snapshot.ps1 -- snapshot the current ESP: unlock firmware log, EFI binaries, drv backup, tree listing
$ErrorActionPreference = 'Continue'
$out = 'D:\40hx-unlock\esp-snapshot.txt'
$dst = 'D:\40hx-unlock\esp-snapshot'
$lines = New-Object System.Collections.ArrayList
function W($s) { [void]$lines.Add([string]$s) }

New-Item -ItemType Directory -Force -Path $dst | Out-Null
W ("=== ESP snapshot " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " ===")

$esp = $null
foreach ($l in @('Y','X','W','V','U','T','S','R','Q')) {
  if (-not (Test-Path "${l}:\")) { mountvol "${l}:" /S | Out-Null; if (Test-Path "${l}:\") { $esp = "${l}:"; break } }
}
if (-not $esp) { W "cannot mount ESP"; $lines -join "`n" | Set-Content $out -Encoding UTF8; exit 1 }
W ("ESP = " + $esp)

# 1) firmware log
$lg = "$esp\40hx_log.txt"
if (Test-Path $lg) {
  Copy-Item $lg (Join-Path $dst '40hx_log.txt') -Force
  W ("  copied 40hx_log.txt  size=" + (Get-Item $lg).Length + "  mtime=" + (Get-Item $lg).LastWriteTime)
} else { W "  40hx_log.txt NOT PRESENT" }

# 2) copy EFI tree (everything under \EFI\40HX plus \EFI\Boot)
foreach ($sub in @('\EFI\40HX', '\EFI\Boot')) {
  $src = "$esp$sub"
  if (Test-Path $src) {
    $target = Join-Path $dst ($sub.TrimStart('\').Replace('\','_'))
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Get-ChildItem -Force -Recurse $src | ForEach-Object {
      if (-not $_.PSIsContainer) {
        $rel = $_.FullName.Substring($src.Length).TrimStart('\')
        Copy-Item $_.FullName (Join-Path $target $rel) -Force
        $h = (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLower()
        W ("  {0}\{1}  {2} bytes  sha256={3}" -f $sub, $rel, $_.Length, $h.Substring(0,16))
      }
    }
  } else { W ("  {0} MISSING" -f $sub) }
}

# 3) full ESP tree listing
W ""
W "--- ESP tree ---"
Get-ChildItem -Force -Recurse "$esp\" -ErrorAction SilentlyContinue | ForEach-Object {
  W ("  {0}  {1}" -f $(if ($_.PSIsContainer) { 'DIR ' } else { 'FILE' }), $_.FullName.Substring($esp.Length))
}

mountvol $esp /D | Out-Null
W "ESP unmounted"
$lines -join "`n" | Set-Content -Path $out -Encoding UTF8
