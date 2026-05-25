param(
    [string] $MasterImage = "vps-master:local",
    [string] $FrontendImage = "vps-frontend:local",
    [string] $BuildNetwork = "host"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")

function Invoke-DockerBuild {
    param(
        [string] $Dockerfile,
        [string] $Image
    )

    $args = @(
        "build",
        "--network", $BuildNetwork,
        "-f", $Dockerfile,
        "-t", $Image,
        "."
    )

    Push-Location $repoRoot
    try {
        & docker @args
        if ($LASTEXITCODE -ne 0) {
            throw "docker build failed for $Image with exit code $LASTEXITCODE"
        }
    } finally {
        Pop-Location
    }
}

docker info | Out-Null
Invoke-DockerBuild -Dockerfile "master/Dockerfile" -Image $MasterImage
Invoke-DockerBuild -Dockerfile "frontend/Dockerfile" -Image $FrontendImage

[pscustomobject]@{
    master_image = $MasterImage
    frontend_image = $FrontendImage
    build_network = $BuildNetwork
} | ConvertTo-Json
