param(
    [string] $OutputPath = "dist/vps-agent",
    [string] $BuildNetwork = "host"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$resolvedOutput = if ([System.IO.Path]::IsPathRooted($OutputPath)) {
    $OutputPath
} else {
    Join-Path $repoRoot $OutputPath
}
$outputDir = Split-Path -Parent $resolvedOutput
$outputFileName = Split-Path -Leaf $resolvedOutput

if ($outputFileName -ne "vps-agent") {
    throw "OutputPath must end with vps-agent"
}

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$targetDir = Join-Path ([System.IO.Path]::GetTempPath()) "vps-agent-target-$([guid]::NewGuid().ToString("N"))"
New-Item -ItemType Directory -Force -Path $targetDir | Out-Null

docker info | Out-Null
try {
    $buildArgs = @(
        "run",
        "--rm",
        "--network", $BuildNetwork,
        "-v", "${repoRoot}:/work",
        "-v", "${targetDir}:/target",
        "-w", "/work",
        "-e", "CARGO_INCREMENTAL=0",
        "-e", "CARGO_TARGET_DIR=/target",
        "rust:1.88-bookworm",
        "cargo", "build", "--release", "-p", "vps-agent", "--bin", "vps-agent"
    )
    & docker @buildArgs
    if ($LASTEXITCODE -ne 0) {
        throw "agent binary build failed with exit code $LASTEXITCODE"
    }

    $copyArgs = @(
        "run",
        "--rm",
        "-v", "${targetDir}:/target:ro",
        "-v", "${outputDir}:/out",
        "rust:1.88-bookworm",
        "install", "-m", "0755", "/target/release/vps-agent", "/out/vps-agent"
    )
    & docker @copyArgs
    if ($LASTEXITCODE -ne 0) {
        throw "agent binary export failed with exit code $LASTEXITCODE"
    }
} finally {
    Remove-Item -Recurse -Force $targetDir -ErrorAction SilentlyContinue
}

$agentSha256 = (Get-FileHash -Algorithm SHA256 -Path $resolvedOutput).Hash.ToLowerInvariant()

[pscustomobject]@{
    agent_binary = $resolvedOutput
    agent_sha256 = $agentSha256
    build_network = $BuildNetwork
} | ConvertTo-Json
