<#
Validates Floresta GUI on a real Windows 10/11 x64 machine, step by step:

  1. dart format check, flutter analyze, unit and widget tests;
  2. production build (build_app.ps1) and package (package_windows.ps1);
  3. full-app clean install (integration_test\clean_install_run_test.dart):
     installs florestad from the public release source, runs the wizard on
     regtest, starts, stops, restarts, removes.

Step 3 needs the Windows florestad in the published manifest. Order:
  a. on Windows: tool\windows\build_florestad_artifact.ps1;
  b. copy florestad-v0.9.1-windows-x64.exe and its .build-info.json to the
     Mac that holds the release key, into the staging folder with the
     other builds, then there:
       dart run tool/release/release_tool.dart manifest --artifacts <dir> --serial <newer> --valid-days 180
       dart run tool/release/release_tool.dart sign --artifacts <dir> --key ~/.config/floresta-gui-release/prod-2026a.key --key-id prod-2026a
     and publish it to floresta-gui-release (README there);
  c. back on Windows: run this script.

  powershell -ExecutionPolicy Bypass -File tool\windows\test_windows.ps1 [-SkipCleanInstall]

Prerequisites: Flutter 3.35.5, Visual Studio 2022 (Desktop C++), internet,
regtest ports 18442 and 20001 free. Written 2026-10-27 without a Windows
machine: NOT yet run.
#>
param([switch]$SkipCleanInstall)
$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..\..')
Push-Location $root
function Step($name, [scriptblock]$run) {
  Write-Host "== $name =="
  & $run
  if ($LASTEXITCODE) { Write-Error "$name failed ($LASTEXITCODE)"; exit $LASTEXITCODE }
}
try {
  Step 'pub get' { flutter pub get }
  Step 'format' { dart format --output=none --set-exit-if-changed lib test integration_test }
  Step 'analyze' { flutter analyze }
  Step 'unit and widget tests' { flutter test test }
  Step 'production build' { powershell -ExecutionPolicy Bypass -File tool\windows\build_app.ps1 production }
  Step 'package' { powershell -ExecutionPolicy Bypass -File tool\windows\package_windows.ps1 }
  if (-not $SkipCleanInstall) {
    $evidence = Join-Path $root 'build\windows-evidence'
    Step 'full-app clean install' {
      flutter test integration_test\clean_install_run_test.dart -d windows `
        --dart-define-from-file=config\release\production.json `
        --dart-define=FLORESTA_CLEAN_RUN=true `
        "--dart-define=FLORESTA_EVIDENCE_DIR=$evidence"
    }
  }
  Write-Host 'test_windows: all steps passed'
} finally { Pop-Location }
