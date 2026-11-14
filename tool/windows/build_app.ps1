<#
Builds the Windows app for one flavour with its release configuration, like
tool/build_app.sh does on macOS and Linux.

  powershell -ExecutionPolicy Bypass -File tool\windows\build_app.ps1 production
  powershell -ExecutionPolicy Bypass -File tool\windows\build_app.ps1 development [config.json]

Production builds refuse any development key or development flavour in
their configuration. Needs Flutter 3.35.5 and Visual Studio 2022
("Desktop development with C++"). Output: build\windows\x64\runner\Release.

Written 2026-10-27 without a Windows machine: NOT yet run.
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet('production', 'development')][string]$Flavor,
  [string]$Config
)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..')
if (-not $Config) { $Config = Join-Path $root "config\release\$Flavor.json" }
if (-not (Test-Path $Config)) { Write-Error "missing $Config (see config\release\*.example.json)"; exit 1 }
$values = Get-Content $Config -Raw | ConvertFrom-Json
if ($values.FLORESTA_FLAVOR -ne $Flavor) {
  Write-Error "$Config sets FLORESTA_FLAVOR=$($values.FLORESTA_FLAVOR), expected $Flavor"; exit 1
}
if ($Flavor -eq 'production' -and $values.FLORESTA_DEV_RELEASE_KEY) {
  Write-Error 'a production configuration must not contain a development key'; exit 1
}
if (-not $values.FLORESTA_RELEASE_MANIFEST_URL) {
  Write-Warning 'no FLORESTA_RELEASE_MANIFEST_URL: this build offers no automatic install'
}
Push-Location $root
try {
  flutter build windows --release "--dart-define-from-file=$Config"
  if ($LASTEXITCODE) { exit $LASTEXITCODE }
  Write-Host "build_app: built $Flavor for windows"
} finally { Pop-Location }
