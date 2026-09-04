param(
    [string]$ZmkApp = "C:\zmk\app",
    [string]$OutputDir = (Join-Path $PSScriptRoot "outputs")
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Path not found: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Convert-ToCMakePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path.Replace("\", "/")
}

function Test-AsciiPath {
    param([Parameter(Mandatory = $true)][string]$Path)
    return $Path -cmatch '^[\x00-\x7F]+$'
}

function Find-Python {
    param([Parameter(Mandatory = $true)][string]$ZmkRoot)

    $candidates = @()
    $venvPython = Join-Path $ZmkRoot ".venv\Scripts\python.exe"
    if (Test-Path -LiteralPath $venvPython) {
        $candidates += (Resolve-Path -LiteralPath $venvPython).Path
    }

    foreach ($name in @("python.exe", "python", "python3")) {
        $command = Get-Command $name -ErrorAction SilentlyContinue
        if ($command) {
            $candidates += $command.Source
        }
    }

    foreach ($candidate in $candidates | Select-Object -Unique) {
        & $candidate -m west --version *> $null
        if ($LASTEXITCODE -eq 0) {
            return $candidate
        }
    }

    throw "A working Python environment with west was not found. Set up or activate the ZMK environment and try again."
}

$repoRoot = $PSScriptRoot
$zmkAppPath = Resolve-RequiredPath $ZmkApp
$moduModule = Resolve-RequiredPath (Join-Path $repoRoot "modu-module")
$pmwModule = Resolve-RequiredPath (Join-Path $repoRoot "zmk-pmw3610-driver")
$uf2Converter = Resolve-RequiredPath (Join-Path $repoRoot "tools\uf2\uf2conv.py")

if (-not (Test-AsciiPath $repoRoot)) {
    throw "The repository path must contain ASCII characters only: $repoRoot"
}
if (-not (Test-AsciiPath $zmkAppPath)) {
    throw "The ZMK path must contain ASCII characters only: $zmkAppPath"
}

$zmkRoot = Split-Path -Parent $zmkAppPath
$python = Find-Python $zmkRoot
$moduleArg = "-DZMK_EXTRA_MODULES=$(Convert-ToCMakePath $moduModule);$(Convert-ToCMakePath $pmwModule)"

$shields = @("modu_left", "modu_right")

# Patches this firmware needs in ZMK itself.
#
# Not applied here. build.sh owns its ZMK workspace and can restore it before
# patching; this script builds against a checkout the user manages, and quietly
# editing someone's own tree is worse than saying what is missing.
#
# Without them the firmware still builds and runs - the only symptom is that a
# Studio client cannot offer values for the pointing behaviours, which looks
# like the app being broken rather than the build.
$patchDir = Join-Path $repoRoot "patches"
if (Test-Path -LiteralPath $patchDir) {
    $patches = Get-ChildItem -LiteralPath $patchDir -Filter *.patch -ErrorAction SilentlyContinue
    foreach ($patch in $patches) {
        $applied = & git -C $zmkRoot apply --reverse --check $patch.FullName 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "ZMK patch not applied: $($patch.Name)"
            Write-Warning "  git -C `"$zmkRoot`" apply `"$($patch.FullName)`""
        }
    }
}

New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
$outputRoot = (Resolve-Path -LiteralPath $OutputDir).Path

Push-Location $zmkAppPath
try {
    foreach ($shield in $shields) {
        $buildDir = Join-Path $repoRoot "build\$shield"
        $hexSource = Join-Path $buildDir "zephyr\zmk.hex"
        $uf2Target = Join-Path $outputRoot "$shield.uf2"

        Write-Host "Building $shield..."
        & $python -m west build -d $buildDir -b ms88sf3/nrf52840 -p auto -- $moduleArg "-DSHIELD=$shield"
        if ($LASTEXITCODE -ne 0) {
            throw "west build failed for $shield with exit code $LASTEXITCODE"
        }
        if (-not (Test-Path -LiteralPath $hexSource)) {
            throw "Build completed but zmk.hex was not found: $hexSource"
        }

        & $python $uf2Converter -f 0xADA52840 -c -o $uf2Target $hexSource
        if ($LASTEXITCODE -ne 0) {
            throw "UF2 conversion failed for $shield with exit code $LASTEXITCODE"
        }

        Write-Host "Wrote $uf2Target"
    }
}
finally {
    Pop-Location
}
