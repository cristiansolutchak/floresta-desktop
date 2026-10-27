<#
Packages the Windows release build (tool\windows\build_app.ps1) as a .zip
with the licences, plus SHA-256 checksums, like package_macos.sh and
package_linux.sh. Nothing is signed (no Authenticode certificate), so
Windows SmartScreen warns on first launch: "More info" -> "Run anyway".

  powershell -ExecutionPolicy Bypass -File tool\windows\package_windows.ps1 [-Out dist]

Written 2026-10-27 without a Windows machine: NOT yet run.
#>
param([string]$Out)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..')
if (-not $Out) { $Out = Join-Path $root 'dist' }
$release = Join-Path $root 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $release 'floresta_gui.exe'))) {
  Write-Error "no release build at $release (run build_app.ps1 first)"; exit 1
}
$version = (Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([^+\s]+)').Matches[0].Groups[1].Value
$name = "floresta-gui-$version-windows-x64"
New-Item -ItemType Directory -Force $Out | Out-Null
$stage = Join-Path ([System.IO.Path]::GetTempPath()) $name
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
Copy-Item -Recurse $release $stage
foreach ($f in 'LICENSE-MIT', 'LICENSE-APACHE', 'README.md') {
  Copy-Item (Join-Path $root $f) $stage
}
$zip = Join-Path $Out "$name.zip"
Remove-Item -Force $zip -ErrorAction SilentlyContinue
Compress-Archive -Path $stage -DestinationPath $zip
Remove-Item -Recurse -Force $stage
$hash = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
"$hash  $name.zip" | Set-Content -Encoding ascii (Join-Path $Out 'SHA256SUMS-windows-x64')
Write-Host "package_windows: wrote $zip ($hash)"
