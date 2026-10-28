<#
Builds the Windows x64 florestad release artifact from the PGP-verified
upstream tag, with the same checks as tool/release/build_florestad_artifact.sh:

  1. upstream tag signature: VALIDSIG by the pinned primary key;
  2. tag -> pinned commit;
  3. build from a `git archive` export (no .git);
  4. x64 PE image importing only Windows system DLLs (static C runtime, so
     users need no Visual C++ redistributable);
  5. `--version` prints exactly "florestad v<version>".

Output: <OutDir>\florestad-v<version>-windows-x64.exe + .build-info.json.
Nothing is signed or published here; sign the manifest with
tool/release/release_tool.dart on the machine that holds the release key.

Prerequisites (as upstream's CI, .github/workflows/rust.yml at v0.9.1):
  - Git for Windows, Gpg4win (gpg.exe on PATH);
  - Rust via rustup: `rustup toolchain install 1.95.0` and
    `rustup target add x86_64-pc-windows-msvc --toolchain 1.95.0`;
  - Visual Studio 2022 Build Tools ("Desktop development with C++");
  - CMake; LLVM (for bindgen: set LIBCLANG_PATH to its bin folder);
  - Boost via vcpkg: `vcpkg install boost-system boost-filesystem
    boost-thread boost-multi-index --triplet x64-windows-static`, then
    BOOST_ROOT=<vcpkg>\installed\x64-windows-static.
Run from "x64 Native Tools Command Prompt for VS 2022" -> powershell.

  powershell -ExecutionPolicy Bypass -File tool\windows\build_florestad_artifact.ps1 [-OutDir <dir>]
    [-Tag v<x.y.z> -Commit <40-hex sha>]

-Tag and -Commit build another upstream release (both, from upstream's
release page); the tag must still resolve to that commit and be VALIDSIG by
the pinned key. .github/workflows/florestad-artifacts.yml runs it that way.

Written 2026-10-27 without a Windows machine: NOT yet run. Validate it on
Windows before publishing its output.
#>
param(
  [string]$OutDir = "$env:USERPROFILE\.cache\floresta-gui-tools\release-artifacts",
  [string]$Tag = 'v0.9.1',
  [string]$Commit = 'bc2db8d07e72651f9981ce589c5688f4d575dc7a'
)
$ErrorActionPreference = 'Stop'

$FlorestaRepo = 'https://github.com/getfloresta/Floresta.git'
$FlorestaTag = $Tag
$FlorestaCommit = $Commit
if ($FlorestaTag -cnotmatch '^v\d+\.\d+\.\d+$') { Write-Error '-Tag must look like v1.2.3'; exit 1 }
if ($FlorestaCommit -cnotmatch '^[0-9a-f]{40}$') { Write-Error '-Commit must be a full sha'; exit 1 }
$FlorestaVersion = $FlorestaTag.TrimStart('v')
$TagSignerPrimary = '2C8E0F836FD7DBBBB9E9B2EF89964EC3AB22B2E3'
$RustVersion = '1.95.0'
$Target = 'x86_64-pc-windows-msvc'
$MinOs = '10.0.10240'   # Rust's MSVC target needs Windows 10
$Tools = "$env:USERPROFILE\.cache\floresta-gui-tools"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$SignerKey = Join-Path $Here '..\release\keys\davidson-souza.asc'

function Log($m) { Write-Host "[artifact] $m" }
function Die($m) { Write-Error "[artifact] ERROR: $m"; exit 1 }
function Need($tool) {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { Die "$tool not found" }
}
foreach ($t in 'git', 'gpg', 'cargo', 'rustup', 'cmake', 'tar') { Need $t }
if (-not $env:BOOST_ROOT) { Die 'BOOST_ROOT is not set (see the header)' }

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("florestad-" + [guid]::NewGuid())
New-Item -ItemType Directory $work | Out-Null
try {
  # 1-2. Source: pinned commit, signed tag.
  $src = Join-Path $Tools 'src\floresta'
  if (-not (Test-Path "$src\.git")) {
    Log "cloning $FlorestaRepo"
    git clone --quiet --no-checkout $FlorestaRepo $src
    if ($LASTEXITCODE) { Die 'clone failed' }
  }
  # Isolated keyring: never touches the user's GnuPG state.
  $env:GNUPGHOME = Join-Path $work 'gnupg'
  New-Item -ItemType Directory $env:GNUPGHOME | Out-Null
  # gpg and git verify-tag write to stderr, which Windows PowerShell 5.1
  # turns into terminating errors under 'Stop'; the checks below decide.
  $ErrorActionPreference = 'Continue'
  gpg --batch --quiet --import $SignerKey 2>$null
  git -C $src fetch --quiet --force origin "refs/tags/${FlorestaTag}:refs/tags/$FlorestaTag"
  $commit = (git -C $src rev-parse "$FlorestaTag^{commit}" | Out-String).Trim()
  $status = git -C $src verify-tag --raw $FlorestaTag 2>&1 | Out-String
  $ErrorActionPreference = 'Stop'
  if ($commit -ne $FlorestaCommit) { Die "$FlorestaTag points to $commit, expected $FlorestaCommit" }
  $valid = $status -split "`n" | Where-Object { $_ -match ' VALIDSIG ' } | Select-Object -First 1
  if (-not $valid -or ($valid.Trim() -split '\s+')[-1] -ne $TagSignerPrimary) {
    Die "$FlorestaTag is not validly signed by $TagSignerPrimary"
  }
  Log "$FlorestaTag signed by $TagSignerPrimary, commit $commit"

  # 3. Build from an export without .git.
  git -C $src archive --format=tar -o "$work\source.tar" $FlorestaTag
  $sourceSha = (Get-FileHash "$work\source.tar" -Algorithm SHA256).Hash.ToLower()
  New-Item -ItemType Directory "$work\src" | Out-Null
  tar -xf "$work\source.tar" -C "$work\src"
  if ($LASTEXITCODE) { Die 'could not unpack the source' }

  rustup target add $Target --toolchain $RustVersion | Out-Null
  $targetDir = Join-Path $Tools "release-target\$FlorestaTag\$Target"
  $env:CARGO_TARGET_DIR = $targetDir
  # Static C runtime: no vcruntime140.dll needed on users' machines.
  $env:RUSTFLAGS = '-C target-feature=+crt-static'
  Log "building florestad $FlorestaTag for $Target"
  Push-Location "$work\src"
  cargo "+$RustVersion" build --release --locked -p florestad --target $Target
  $built = $LASTEXITCODE
  Pop-Location
  if ($built) { Die 'cargo build failed' }
  $bin = Join-Path $targetDir "$Target\release\florestad.exe"
  if (-not (Test-Path $bin)) { Die 'build produced no binary' }

  # 4. x64 image, system DLLs only (dumpbin from the VS developer prompt).
  if (Get-Command dumpbin -ErrorAction SilentlyContinue) {
    $headers = dumpbin /headers $bin | Out-String
    if ($headers -notmatch '8664 machine \(x64\)') { Die 'not an x64 image' }
    $deps = dumpbin /dependents $bin | Select-String '^\s+(\S+\.dll)\s*$' |
      ForEach-Object { $_.Matches[0].Groups[1].Value.ToLower() }
    $system = '^(kernel32|advapi32|ws2_32|bcrypt|ntdll|userenv|ole32|oleaut32|shell32|user32|secur32|crypt32|iphlpapi|dbghelp|powrprof|psapi|api-ms-win-.*)\.dll$'
    foreach ($d in $deps) {
      if ($d -notmatch $system) { Die "non-system DLL dependency: $d" }
    }
    Log "imports: $($deps -join ', ')"
  } else {
    Die 'dumpbin not found: run from the x64 Native Tools prompt'
  }

  # 5. Version probe.
  $reported = (& $bin --version | Out-String).Trim()
  if ($reported -ne "florestad $FlorestaTag") {
    Die "--version printed '$reported', expected 'florestad $FlorestaTag'"
  }

  # Output.
  New-Item -ItemType Directory -Force $OutDir | Out-Null
  $name = "florestad-$FlorestaTag-windows-x64.exe"
  $out = Join-Path $OutDir $name
  Copy-Item $bin $out -Force
  $sha = (Get-FileHash $out -Algorithm SHA256).Hash.ToLower()
  $size = (Get-Item $out).Length
  $rustc = (& rustc "+$RustVersion" --version | Out-String).Trim()
  $info = [ordered]@{
    artifact = $name; os = 'windows'; arch = 'x64'; rustTarget = $Target
    version = $FlorestaVersion; upstreamTag = $FlorestaTag
    upstreamRef = $FlorestaTag; upstreamCommit = $commit
    tagSigner = $TagSignerPrimary; sourceTarSha256 = $sourceSha
    rustc = $rustc; minOs = $MinOs; sha256 = $sha; size = $size
    builtAt = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
  }
  # release_tool.dart reads "<artifact>.build-info.json" next to the binary.
  $info | ConvertTo-Json | Set-Content -Encoding ascii "$out.build-info.json"
  Log "OK $out ($reported, min Windows $MinOs)"
} finally {
  Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}
