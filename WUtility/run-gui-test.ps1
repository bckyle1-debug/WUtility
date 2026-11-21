$ErrorActionPreference = 'Stop'
$src = 'C:\Users\akaib\Downloads\peak app widows editor\peak.ps1'
$dst = Join-Path $env:TEMP 'peak-gui-test.ps1'
$raw = [IO.File]::ReadAllText($src)
$raw = $raw.Replace(
  '                        Apply-InstalledMarks -File $script:guiDetectFile',
  "                        Apply-InstalledMarks -File `$script:guiDetectFile`n                        if (`$env:PEAK_AUTOCLOSE) { Write-Host LIFECYCLE-CLOSED; `$win.Close() }")
[IO.File]::WriteAllText($dst, $raw, (New-Object System.Text.UTF8Encoding($true)))
Write-Host ('patched: ' + ($raw -match 'LIFECYCLE-CLOSED'))
$env:PEAK_AUTOCLOSE = '1'
$code = [IO.File]::ReadAllText($dst)
& ([scriptblock]::Create($code)) -SkipElevation 2>&1 | Out-String | Write-Host
Remove-Item $dst -ErrorAction SilentlyContinue
