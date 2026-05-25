param(
    [int] $MasterPort = 18080,
    [int] $TimeoutSeconds = 180
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$adminToken = "$([guid]::NewGuid().ToString("N"))$([guid]::NewGuid().ToString("N"))"
$readonlyToken = "$([guid]::NewGuid().ToString("N"))$([guid]::NewGuid().ToString("N"))"
$containerName = "vps-master-agent-smoke"
$smokeDir = Join-Path ([System.IO.Path]::GetTempPath()) "vps-master-agent-smoke-$([guid]::NewGuid().ToString("N"))"
$masterBaseUrl = "http://127.0.0.1:$MasterPort"
$agentMasterBaseUrl = "http://127.0.0.1:8080"
$composeEnvNames = @(
    "DOMAIN",
    "MASTER_PUBLIC_BASE_URL",
    "MASTER_INSTALLER_BASE_URL",
    "POSTGRES_PASSWORD",
    "MASTER_ADMIN_USERNAME",
    "MASTER_ADMIN_TOKEN_HASH",
    "MASTER_READONLY_TOKEN_HASH"
)
$savedComposeEnv = @{}
foreach ($name in $composeEnvNames) {
    $savedComposeEnv[$name] = [Environment]::GetEnvironmentVariable($name, "Process")
}

function Restore-ComposeEnv {
    foreach ($name in $composeEnvNames) {
        $previousValue = $savedComposeEnv[$name]
        if ($null -eq $previousValue) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" -Value $previousValue
        }
    }
}

function ConvertTo-RedactedSmokeLogLine {
    param([AllowNull()] [string] $Text)

    if ($null -eq $Text) {
        return ""
    }

    $redacted = $Text
    $redacted = $redacted -replace '(?i)\bAuthorization\s*[:=]\s*(Bearer|Basic)\s+[^"\s,;}\]]+"?', 'Authorization: $1 [REDACTED]'
    $redacted = $redacted -replace '(?i)\b(X-Agent-Credential|X-Agent-Signature)\s*:\s*[^"\s,;}\]]+"?', '$1: [REDACTED]'
    $redacted = $redacted -replace '(?i)\b(Set-Cookie|Cookie)\s*:\s*[^\r\n]*', '$1: [REDACTED]'
    $redacted = $redacted -replace '(?i)\b(bootstrap[_-]?token|token|credential|password|secret|authorization|private[_-]?key)\b\s*[:=]\s*"?[^"\s,;}\]]+"?', '$1=[REDACTED]'
    $redacted = $redacted -replace '(?i)([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^@\s/]+@', '${1}[REDACTED]@'
    $redacted
}

function Write-RedactedDockerLogs {
    param(
        [string] $ContainerName,
        [int] $Tail
    )

    Write-Output "docker logs tail $Tail for $ContainerName (secret patterns redacted)"
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $dockerOutput = docker logs $ContainerName --tail $Tail 2>&1
        $dockerExitCode = $LASTEXITCODE
    } catch {
        $dockerOutput = @($_.Exception.Message)
        $dockerExitCode = 1
    } finally {
        $ErrorActionPreference = $oldPreference
    }
    foreach ($line in @($dockerOutput)) {
        Write-Output (ConvertTo-RedactedSmokeLogLine -Text ([string] $line))
    }
    if ($dockerExitCode -ne 0) {
        Write-Output "docker logs failed with exit code $dockerExitCode"
    }
}

function Wait-ForMaster {
    param([string] $Url, [int] $Timeout)

    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        try {
            $health = Invoke-RestMethod -Uri "$Url/healthz" -TimeoutSec 2
            if ($health.status -eq "ok") {
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    }

    Write-RedactedDockerLogs -ContainerName $containerName -Tail 120
    throw "master did not become healthy before timeout"
}

function Invoke-MasterJson {
    param(
        [string] $Method,
        [string] $Path,
        [object] $Body = $null,
        [hashtable] $ExtraHeaders = @{},
        [string] $BearerToken = $adminToken
    )

    $headers = @{ Authorization = "Bearer $BearerToken" }
    foreach ($key in $ExtraHeaders.Keys) {
        $headers[$key] = $ExtraHeaders[$key]
    }
    $args = @{
        Headers = $headers
        Method = $Method
        Uri = "$masterBaseUrl$Path"
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $args.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    Invoke-RestMethod @args
}

function New-SecretHash {
    param([string] $Secret)

    $env:SECRET_TO_HASH = $Secret
    try {
        docker run --rm `
            -v "${repoRoot}:/work" `
            -w /work `
            -e CARGO_INCREMENTAL=0 `
            -e SECRET_TO_HASH `
            rust:1.88 `
            cargo run -q -p vps-master --bin hash-secret
    } finally {
        Remove-Item Env:SECRET_TO_HASH -ErrorAction SilentlyContinue
    }
}

function Test-HttpFailure {
    param(
        [scriptblock] $Request,
        [int] $ExpectedStatus,
        [string] $FailureMessage
    )

    try {
        & $Request | Out-Null
    } catch {
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq $ExpectedStatus) {
            return $true
        }
        throw
    }

    throw $FailureMessage
}

function New-AgentDoctorFailureMessage {
    param(
        [int] $ExitCode,
        [string[]] $DoctorOutput = @()
    )

    "agent doctor failed with exit code $ExitCode; raw doctor output suppressed because agent config contains credentials"
}

function Assert-AuditTaskDetail {
    param(
        [object[]] $AuditLogs,
        [string] $Action,
        [string] $TaskId,
        [string] $TaskKind,
        [string] $VmId
    )

    $entry = $AuditLogs |
        Where-Object {
            $_.action -eq $Action `
                -and $_.task_id -eq $TaskId `
                -and $_.detail.task_kind -eq $TaskKind `
                -and $_.detail.vm_id -eq $VmId
        } |
        Select-Object -First 1

    if ($null -eq $entry) {
        throw "expected audit action '$Action' for task '$TaskId' to include task_kind '$TaskKind' and vm_id '$VmId'"
    }
}

function Convert-ToHex {
    param([byte[]] $Bytes)

    (($Bytes | ForEach-Object { $_.ToString("x2") }) -join "")
}

function New-AgentSignature {
    param(
        [string] $Credential,
        [string] $Method,
        [string] $Path,
        [string] $Body,
        [int64] $Timestamp,
        [string] $Nonce
    )

    $encoding = [System.Text.Encoding]::UTF8
    $bodyBytes = $encoding.GetBytes($Body)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $bodyHash = Convert-ToHex -Bytes $sha.ComputeHash($bodyBytes)
    $canonical = "$($Method.ToUpperInvariant())`n$Path`n$bodyHash`n$Timestamp`n$Nonce"
    $hmac = New-Object System.Security.Cryptography.HMACSHA256 -ArgumentList (, $encoding.GetBytes($Credential))
    Convert-ToHex -Bytes $hmac.ComputeHash($encoding.GetBytes($canonical))
}

function Invoke-AgentJson {
    param(
        [string] $Method,
        [string] $Path,
        [object] $Body,
        [string] $Credential
    )

    $jsonBody = $Body | ConvertTo-Json -Depth 10 -Compress
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $nonce = [guid]::NewGuid().ToString("N")
    $signature = New-AgentSignature `
        -Credential $Credential `
        -Method $Method `
        -Path $Path `
        -Body $jsonBody `
        -Timestamp $timestamp `
        -Nonce $nonce

    Invoke-RestMethod `
        -Headers @{
            "X-Agent-Credential" = $Credential
            "X-Agent-Timestamp" = "$timestamp"
            "X-Agent-Nonce" = $nonce
            "X-Agent-Signature" = $signature
        } `
        -Method $Method `
        -Uri "$masterBaseUrl$Path" `
        -ContentType "application/json" `
        -Body $jsonBody
}

function Remove-SmokeContainer {
    $existing = docker ps -a --format "{{.Names}}" | Where-Object { $_ -eq $containerName }
    if ($existing) {
        $oldPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            docker rm -f $containerName 2>$null | Out-Null
        } finally {
            $ErrorActionPreference = $oldPreference
        }
    }
}

function Invoke-Compose {
    param(
        [string[]] $Arguments,
        [switch] $IgnoreFailure
    )

    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $composeOutput = & docker compose @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        $composeOutput = @($_.Exception.Message)
        $exitCode = 1
    } finally {
        $ErrorActionPreference = $oldPreference
    }

    if (-not $IgnoreFailure -and $exitCode -ne 0) {
        foreach ($line in @($composeOutput)) {
            Write-Output (ConvertTo-RedactedSmokeLogLine -Text ([string] $line))
        }
        throw "docker compose failed with exit code $exitCode"
    }
}

function Invoke-AgentRunOnce {
    param([string] $FailureMessage)

    docker run --rm `
        --network "container:$containerName" `
        -v "${repoRoot}:/work" `
        -v "${smokeDir}:/smoke" `
        -w /work `
        -e CARGO_INCREMENTAL=0 `
        -e VPS_AGENT_CONFIG=/smoke/agent.toml `
        -e VPS_AGENT_ALLOW_INSECURE_MASTER=1 `
        -e VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS=1 `
        -e VPS_AGENT_RUN_ONCE=1 `
        rust:1.88 `
        cargo run -q -p vps-agent | Out-Null
    if ($LASTEXITCODE -ne 0) {
        throw "$FailureMessage with exit code $LASTEXITCODE"
    }
}

try {
    New-Item -ItemType Directory -Path $smokeDir | Out-Null
    $agentBinaryPath = Join-Path $smokeDir "vps-agent"
    [System.IO.File]::WriteAllText($agentBinaryPath, "fake-agent-binary")

    $adminHash = New-SecretHash -Secret $adminToken
    $readonlyHash = New-SecretHash -Secret $readonlyToken

    $env:DOMAIN = "localhost"
    $env:MASTER_PUBLIC_BASE_URL = "https://localhost"
    $env:MASTER_INSTALLER_BASE_URL = "https://localhost"
    $env:POSTGRES_PASSWORD = "vps"
    $env:MASTER_ADMIN_USERNAME = "admin"
    $env:MASTER_ADMIN_TOKEN_HASH = $adminHash
    $env:MASTER_READONLY_TOKEN_HASH = $readonlyHash

    Invoke-Compose -Arguments @("-f", (Join-Path $repoRoot "deploy/docker-compose.yml"), "up", "-d", "postgres")
    Remove-SmokeContainer
    docker run -d `
        --name $containerName `
        -p "${MasterPort}:8080" `
        -v "${repoRoot}:/work" `
        -v "${smokeDir}:/smoke" `
        -w /work `
        -e CARGO_INCREMENTAL=0 `
        -e MASTER_HTTP_BIND=0.0.0.0:8080 `
        -e MASTER_PUBLIC_BASE_URL=https://localhost `
        -e DATABASE_URL=postgres://vps:vps@host.docker.internal:5432/vps `
        -e MASTER_ADMIN_USERNAME=admin `
        -e "MASTER_ADMIN_TOKEN_HASH=$adminHash" `
        -e "MASTER_READONLY_TOKEN_HASH=$readonlyHash" `
        -e MASTER_AGENT_BINARY_PATH=/smoke/vps-agent `
        rust:1.88 `
        cargo run -q -p vps-master --bin vps-master | Out-Null

    Wait-ForMaster -Url $masterBaseUrl -Timeout $TimeoutSeconds

    $installer = Invoke-WebRequest -Uri "$masterBaseUrl/scripts/install-agent.sh" -TimeoutSec 10
    if ($installer.Content -notmatch "install-agent.sh" -or $installer.Content -notmatch "--bootstrap-token") {
        throw "master did not serve the expected installer script"
    }
    if ($installer.Content -notmatch "validate_libvirt_identifier" -or $installer.Content -notmatch "--network-name") {
        throw "installer script did not include libvirt network validation"
    }

    $downloadPath = Join-Path $smokeDir "downloaded-vps-agent"
    Invoke-WebRequest -Uri "$masterBaseUrl/downloads/vps-agent" -OutFile $downloadPath -TimeoutSec 10
    $downloadedBytes = [System.IO.File]::ReadAllBytes($downloadPath)
    $expectedBytes = [System.IO.File]::ReadAllBytes($agentBinaryPath)
    if (-not [System.Linq.Enumerable]::SequenceEqual($downloadedBytes, $expectedBytes)) {
        throw "downloaded agent binary did not match configured artifact"
    }

    $adminSession = Invoke-RestMethod `
        -Method Post `
        -Uri "$masterBaseUrl/api/admin/session" `
        -ContentType "application/json" `
        -Body (@{ username = "admin"; password = $adminToken } | ConvertTo-Json -Compress)
    if (-not $adminSession.ok -or $adminSession.role -ne "admin") {
        throw "admin username/password session login failed"
    }
    $badAdminSessionRejected = Test-HttpFailure -ExpectedStatus 401 -FailureMessage "wrong admin password was accepted" -Request {
        Invoke-RestMethod `
            -Method Post `
            -Uri "$masterBaseUrl/api/admin/session" `
            -ContentType "application/json" `
            -Body (@{ username = "admin"; password = "wrong-$adminToken" } | ConvertTo-Json -Compress)
    }

    $nodeCreateRequestId = "smoke-node-$([guid]::NewGuid().ToString("N"))"
    $node = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes" `
        -Body @{ name = "smoke-agent-node" } `
        -ExtraHeaders @{ "X-Request-Id" = $nodeCreateRequestId }
    Invoke-MasterJson -Method Get -Path "/api/admin/nodes" -BearerToken $readonlyToken | Out-Null
    $readonlyMutationRejected = Test-HttpFailure -ExpectedStatus 403 -FailureMessage "readonly token was allowed to create a node" -Request {
        Invoke-MasterJson `
            -Method Post `
            -Path "/api/admin/nodes" `
            -BearerToken $readonlyToken `
            -Body @{ name = "readonly-should-not-create" }
    }
    $expiresAt = (Get-Date).ToUniversalTime().AddMinutes(30).ToString("o")
    $bootstrap = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes/$($node.id)/bootstrap-tokens" `
        -Body @{ expires_at = $expiresAt }
    $expectedAgentSha256 = (Get-FileHash -Path $agentBinaryPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if (-not $bootstrap.install_command.Contains("--agent-sha256 '$expectedAgentSha256'")) {
        throw "generated install command did not include the configured agent binary SHA-256"
    }
    $ipPool = Invoke-MasterJson -Method Post -Path "/api/admin/ip-pools" -Body @{
        name = "smoke-pool-$([guid]::NewGuid().ToString("N").Substring(0, 12))"
        cidr = "192.0.2.0/29"
        gateway_ip = "192.0.2.1"
    }
    $imageSuffix = [guid]::NewGuid().ToString("N").Substring(0, 12)
    $imageFileName = "debian-12-$imageSuffix.qcow2"
    $image = Invoke-MasterJson -Method Post -Path "/api/admin/images" -Body @{
        name = "Debian 12 Smoke $imageSuffix"
        file_name = $imageFileName
        enabled = $true
    }
    $disabledImageFileName = "disabled-$imageSuffix.qcow2"
    $disabledImage = Invoke-MasterJson -Method Post -Path "/api/admin/images" -Body @{
        name = "Disabled Smoke $imageSuffix"
        file_name = $disabledImageFileName
        enabled = $false
    }
    Invoke-MasterJson -Method Get -Path "/api/admin/images" -BearerToken $readonlyToken | Out-Null
    $readonlyImageToggleRejected = Test-HttpFailure -ExpectedStatus 403 -FailureMessage "readonly token was allowed to toggle an image" -Request {
        Invoke-MasterJson `
            -Method Post `
            -Path "/api/admin/images/$($disabledImage.id)/enabled" `
            -BearerToken $readonlyToken `
            -Body @{ enabled = $true }
    }
    $disabledImageRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "disabled image was allowed for create_vm" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "disabled-image-vm"
                image = $disabledImageFileName
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $enabledImage = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/images/$($disabledImage.id)/enabled" `
        -Body @{ enabled = $true }
    if (-not $enabledImage.enabled) {
        throw "image enable endpoint did not return enabled=true"
    }
    $imagesAfterEnable = Invoke-MasterJson -Method Get -Path "/api/admin/images"
    $listedEnabledImage = $imagesAfterEnable |
        Where-Object { $_.id -eq $disabledImage.id } |
        Select-Object -First 1
    if ($null -eq $listedEnabledImage -or -not $listedEnabledImage.enabled) {
        throw "image list did not show enabled image state"
    }
    $plan = Invoke-MasterJson -Method Post -Path "/api/admin/plans" -Body @{
        name = "Small Smoke $imageSuffix"
        slug = "small-$imageSuffix"
        cpu_cores = 2
        memory_mb = 1024
        disk_gb = 20
        enabled = $true
    }
    $disabledPlan = Invoke-MasterJson -Method Post -Path "/api/admin/plans" -Body @{
        name = "Disabled Smoke $imageSuffix"
        slug = "disabled-$imageSuffix"
        cpu_cores = 1
        memory_mb = 512
        disk_gb = 10
        enabled = $false
    }
    $sshPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb smoke@example"
    Invoke-MasterJson -Method Get -Path "/api/admin/plans" -BearerToken $readonlyToken | Out-Null
    $readonlyPlanToggleRejected = Test-HttpFailure -ExpectedStatus 403 -FailureMessage "readonly token was allowed to toggle a plan" -Request {
        Invoke-MasterJson `
            -Method Post `
            -Path "/api/admin/plans/$($disabledPlan.id)/enabled" `
            -BearerToken $readonlyToken `
            -Body @{ enabled = $true }
    }

    $invalidVmRejected = Test-HttpFailure -ExpectedStatus 400 -FailureMessage "invalid VM image was not rejected" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "bad-vm"
                image = "../bad.qcow2"
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $unregisteredImageRejected = Test-HttpFailure -ExpectedStatus 404 -FailureMessage "unregistered VM image was not rejected" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "missing-image-vm"
                image = "missing-image.qcow2"
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $invalidSshKeyRejected = Test-HttpFailure -ExpectedStatus 400 -FailureMessage "invalid SSH public key was not rejected" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "bad-ssh-vm"
                image = $imageFileName
                ssh_public_key = "ssh-ed25519 AAAA`nbad"
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $disabledPlanRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "disabled plan was allowed for create_vm" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                plan_id = $disabledPlan.id
                name = "disabled-plan-vm"
                image = $imageFileName
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $enabledPlan = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/plans/$($disabledPlan.id)/enabled" `
        -Body @{ enabled = $true }
    if (-not $enabledPlan.enabled) {
        throw "plan enable endpoint did not return enabled=true"
    }
    $plansAfterEnable = Invoke-MasterJson -Method Get -Path "/api/admin/plans"
    $listedEnabledPlan = $plansAfterEnable |
        Where-Object { $_.id -eq $disabledPlan.id } |
        Select-Object -First 1
    if ($null -eq $listedEnabledPlan -or -not $listedEnabledPlan.enabled) {
        throw "plan list did not show enabled plan state"
    }

    $unregisteredNodeTaskRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "unregistered node was allowed to receive a VM task" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "pre-register-vm"
                image = $imageFileName
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }

    $agentConfigPath = Join-Path $smokeDir "agent.toml"
    $agentConfig = @"
master_base_url = "$agentMasterBaseUrl"
node_id = "$($node.id)"
data_dir = "/smoke/data"
bootstrap_token = "$($bootstrap.bootstrap_token)"

[executor]
mode = "mock"
"@
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($agentConfigPath, $agentConfig, $utf8NoBom)

    Invoke-AgentRunOnce -FailureMessage "agent registration smoke run failed"

    $disabledSchedulingNode = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes/$($node.id)/scheduling" `
        -Body @{ enabled = $false }
    if ($disabledSchedulingNode.scheduling_enabled) {
        throw "node scheduling disable endpoint did not return scheduling_enabled=false"
    }
    $nodeSchedulingDisabledRejectedTask = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "disabled node scheduling allowed a VM task" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "disabled-scheduling-vm"
                image = $imageFileName
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
            }
        }
    }
    $reenabledSchedulingNode = Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes/$($node.id)/scheduling" `
        -Body @{ enabled = $true }
    if (-not $reenabledSchedulingNode.scheduling_enabled) {
        throw "node scheduling enable endpoint did not return scheduling_enabled=true"
    }

    $agentConfigAfterRegistration = Get-Content -Raw -Path $agentConfigPath
    if ($agentConfigAfterRegistration -notmatch 'credential\s*=\s*"([^"]+)"') {
        throw "agent config does not contain persisted credential after registration"
    }
    $credential = $Matches[1]
    Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/heartbeat" `
        -Body @{
            node_id = $node.id
            agent_version = "smoke-capacity"
            libvirt_status = "not_checked"
            host_checks = @()
            cpu_total = 1
            cpu_used = 0
            memory_total = 536870912
            memory_used = 0
            disk_total = 1073741824
            disk_used = 0
            vm_count = 0
        } | Out-Null
    $nodeCapacityRejectedTask = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "node capacity guard allowed an oversized VM task" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                name = "oversized-vm"
                image = $imageFileName
                cpu_cores = 2
                memory_mb = 1024
                disk_gb = 10
            }
        }
    }
    Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/heartbeat" `
        -Body @{
            node_id = $node.id
            agent_version = "smoke-capacity"
            libvirt_status = "not_checked"
            host_checks = @()
            cpu_total = 4
            cpu_used = 0
            memory_total = 8589934592
            memory_used = 0
            disk_total = 107374182400
            disk_used = 0
            vm_count = 0
        } | Out-Null

    $maintenanceCandidate = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
        vm = @{
            node_id = $node.id
            name = "maintenance-hold-vm"
            image = $imageFileName
            cpu_cores = 1
            memory_mb = 512
            disk_gb = 10
        }
    }
    Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes/$($node.id)/scheduling" `
        -Body @{ enabled = $false } | Out-Null
    $maintenancePoll = Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/tasks/poll" `
        -Body @{ node_id = $node.id }
    if ($null -ne $maintenancePoll.task) {
        throw "disabled node scheduling allowed a pending task to be assigned"
    }
    $maintenanceTaskAfterPoll = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($maintenanceCandidate.id)"
    if ($maintenanceTaskAfterPoll.status -ne "pending") {
        throw "disabled node scheduling changed pending task status to $($maintenanceTaskAfterPoll.status)"
    }
    Invoke-MasterJson -Method Post -Path "/api/admin/tasks/$($maintenanceCandidate.id)/cancel" | Out-Null
    Invoke-MasterJson `
        -Method Post `
        -Path "/api/admin/nodes/$($node.id)/scheduling" `
        -Body @{ enabled = $true } | Out-Null
    $nodeSchedulingDisablePausedPendingAssignment = $true

    $task = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
            vm = @{
                node_id = $node.id
                ip_pool_id = $ipPool.id
                plan_id = $plan.id
                assigned_ip = "203.0.113.99"
                name = "smoke-vm"
                image = $imageFileName
                ssh_public_key = $sshPublicKey
                cpu_cores = 1
                memory_mb = 512
                disk_gb = 10
        }
    }
    $provisioningVmId = $task.kind.vm_id
    $provisioningVmActionRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "provisioning VM accepted a follow-up VM action" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/delete-vm" -Body @{
            node_id = $node.id
            vm_id = $provisioningVmId
        }
    }
    $nodesAfterTaskCreate = Invoke-MasterJson -Method Get -Path "/api/admin/nodes"
    $nodeAfterTaskCreate = $nodesAfterTaskCreate |
        Where-Object { $_.id -eq $node.id } |
        Select-Object -First 1
    if ($null -eq $nodeAfterTaskCreate) {
        throw "node list did not return node after create_vm task"
    }
    if ($nodeAfterTaskCreate.committed_cpu -lt 1) {
        throw "expected node committed_cpu to include create_vm task"
    }
    if ($nodeAfterTaskCreate.committed_memory_mb -lt 512) {
        throw "expected node committed_memory_mb to include create_vm task"
    }
    if ($nodeAfterTaskCreate.committed_disk_gb -lt 10) {
        throw "expected node committed_disk_gb to include create_vm task"
    }
    $cancelCandidate = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
        vm = @{
            node_id = $node.id
            name = "cancel-vm"
            image = $imageFileName
            cpu_cores = 1
            memory_mb = 512
            disk_gb = 10
        }
    }
    $canceledTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/$($cancelCandidate.id)/cancel"
    if ($canceledTask.status -ne "canceled") {
        throw "expected pending task cancellation to return canceled status"
    }

    Invoke-AgentRunOnce -FailureMessage "agent create-vm smoke run failed"

    $nodesAfterHeartbeat = Invoke-MasterJson -Method Get -Path "/api/admin/nodes"
    $nodeAfterHeartbeat = $nodesAfterHeartbeat |
        Where-Object { $_.id -eq $node.id } |
        Select-Object -First 1
    if ($null -eq $nodeAfterHeartbeat) {
        throw "heartbeat node was not returned from node list"
    }
    if ($nodeAfterHeartbeat.cpu_total -le 0) {
        throw "expected node resource metrics to include cpu_total"
    }
    if ($nodeAfterHeartbeat.memory_total -lt $nodeAfterHeartbeat.memory_used) {
        throw "node memory metrics are inconsistent"
    }
    if ($nodeAfterHeartbeat.disk_total -lt $nodeAfterHeartbeat.disk_used) {
        throw "node disk metrics are inconsistent"
    }

    $vms = Invoke-MasterJson -Method Get -Path "/api/admin/vms"
    $vm = $vms | Where-Object { $_.id -eq $task.kind.vm_id } | Select-Object -First 1
    if ($null -eq $vm) {
        throw "created VM inventory row was not returned"
    }
    $canceledVm = $vms |
        Where-Object { $_.id -eq $cancelCandidate.kind.vm_id } |
        Select-Object -First 1
    if ($null -eq $canceledVm -or $canceledVm.status -ne "error") {
        throw "expected canceled create_vm task to mark VM inventory as error"
    }
    if ($vm.status -ne "running") {
        throw "expected VM status 'running', got '$($vm.status)'"
    }
    if ($vm.assigned_ip -ne "192.0.2.2") {
        throw "expected master-assigned IP '192.0.2.2', got '$($vm.assigned_ip)'"
    }
    if ($task.kind.assigned_ip -ne "192.0.2.2") {
        throw "expected task payload to contain master-assigned IP '192.0.2.2', got '$($task.kind.assigned_ip)'"
    }
    if ($task.kind.assigned_ip_prefix -ne 29) {
        throw "expected task payload to contain assigned_ip_prefix 29, got '$($task.kind.assigned_ip_prefix)'"
    }
    if ($task.kind.assigned_gateway_ip -ne "192.0.2.1") {
        throw "expected task payload to contain assigned_gateway_ip '192.0.2.1', got '$($task.kind.assigned_gateway_ip)'"
    }
    if ($task.kind.plan_id -ne $plan.id -or $vm.plan_id -ne $plan.id) {
        throw "expected task and VM inventory to preserve selected plan_id"
    }
    if ($task.kind.ssh_public_key -ne $sshPublicKey -or $vm.ssh_public_key -ne $sshPublicKey) {
        throw "expected task and VM inventory to preserve selected SSH public key"
    }
    if ($task.kind.cpu_cores -ne 2 -or $task.kind.memory_mb -ne 1024 -or $task.kind.disk_gb -ne 20) {
        throw "expected plan sizing to overwrite create_vm task sizing"
    }
    if ($vm.cpu_cores -ne 2 -or $vm.memory_mb -ne 1024 -or $vm.disk_gb -ne 20) {
        throw "expected VM inventory to store plan sizing"
    }
    $reinstallUnknownImageRejected = Test-HttpFailure -ExpectedStatus 404 -FailureMessage "reinstall with unknown image was not rejected" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/reinstall-vm" -Body @{
            node_id = $node.id
            vm_id = $vm.id
            image = "missing-reinstall-image.qcow2"
        }
    }
    $reinstallTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/reinstall-vm" -Body @{
        node_id = $node.id
        vm_id = $vm.id
    }
    if ($reinstallTask.kind.type -ne "reinstall_vm" -or $reinstallTask.kind.image -ne $imageFileName) {
        throw "expected reinstall task to use the VM inventory image"
    }
    if ($reinstallTask.kind.ssh_public_key -ne $sshPublicKey) {
        throw "expected reinstall task to carry the VM inventory SSH public key"
    }
    Invoke-AgentRunOnce -FailureMessage "agent reinstall smoke run failed"
    $vmsAfterReinstall = Invoke-MasterJson -Method Get -Path "/api/admin/vms"
    $vmAfterReinstall = $vmsAfterReinstall | Where-Object { $_.id -eq $vm.id } | Select-Object -First 1
    if ($null -eq $vmAfterReinstall -or $vmAfterReinstall.status -ne "running") {
        throw "expected VM to be running after reinstall"
    }
    if ($vmAfterReinstall.image -ne $imageFileName) {
        throw "expected VM inventory image to remain '$imageFileName' after reinstall"
    }
    $stopTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/stop-vm" -Body @{
        node_id = $node.id
        vm_id = $vm.id
    }
    Invoke-AgentRunOnce -FailureMessage "agent stop-vm smoke run failed"
    $vmAfterStop = (Invoke-MasterJson -Method Get -Path "/api/admin/vms") |
        Where-Object { $_.id -eq $vm.id } |
        Select-Object -First 1
    if ($null -eq $vmAfterStop -or $vmAfterStop.status -ne "stopped") {
        throw "expected VM to be stopped after stop-vm task"
    }

    $startTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/start-vm" -Body @{
        node_id = $node.id
        vm_id = $vm.id
    }
    Invoke-AgentRunOnce -FailureMessage "agent start-vm smoke run failed"
    $vmAfterStart = (Invoke-MasterJson -Method Get -Path "/api/admin/vms") |
        Where-Object { $_.id -eq $vm.id } |
        Select-Object -First 1
    if ($null -eq $vmAfterStart -or $vmAfterStart.status -ne "running") {
        throw "expected VM to be running after start-vm task"
    }

    $rebootTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/reboot-vm" -Body @{
        node_id = $node.id
        vm_id = $vm.id
    }
    Invoke-AgentRunOnce -FailureMessage "agent reboot-vm smoke run failed"
    $vmAfterReboot = (Invoke-MasterJson -Method Get -Path "/api/admin/vms") |
        Where-Object { $_.id -eq $vm.id } |
        Select-Object -First 1
    if ($null -eq $vmAfterReboot -or $vmAfterReboot.status -ne "running") {
        throw "expected VM to be running after reboot-vm task"
    }

    $deleteTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/delete-vm" -Body @{
        node_id = $node.id
        vm_id = $vm.id
    }
    Invoke-AgentRunOnce -FailureMessage "agent delete-vm smoke run failed"
    $vmAfterDelete = (Invoke-MasterJson -Method Get -Path "/api/admin/vms") |
        Where-Object { $_.id -eq $vm.id } |
        Select-Object -First 1
    if ($null -ne $vmAfterDelete) {
        throw "expected deleted VM to be hidden from VM list"
    }
    $deletedVmActionRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "deleted VM was allowed to receive a start task" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/start-vm" -Body @{
            node_id = $node.id
            vm_id = $vm.id
        }
    }
    $ipPools = Invoke-MasterJson -Method Get -Path "/api/admin/ip-pools"
    $updatedPool = $ipPools | Where-Object { $_.id -eq $ipPool.id } | Select-Object -First 1
    if ($null -eq $updatedPool -or $updatedPool.allocated_count -ne 0) {
        throw "expected IP pool allocated_count to be 0 after delete-vm"
    }

    $auditLogs = Invoke-MasterJson -Method Get -Path "/api/admin/audit-logs"
    $auditActions = @($auditLogs | ForEach-Object { $_.action })
    foreach ($expectedAction in @(
        "node.create",
        "bootstrap_token.create",
        "plan.create",
        "plan.enabled_update",
        "image.create",
        "image.enabled_update",
        "ip_pool.create",
        "node.scheduling_update",
        "task.create_vm",
        "task.reinstall_vm",
        "task.stop_vm",
        "task.start_vm",
        "task.reboot_vm",
        "task.delete_vm",
        "task.cancel",
        "agent.register",
        "task.assigned",
        "task.status_update"
    )) {
        if ($auditActions -notcontains $expectedAction) {
            throw "expected audit action '$expectedAction' was not returned"
        }
    }
    $nodeCreateAudit = $auditLogs |
        Where-Object { $_.action -eq "node.create" -and $_.node_id -eq $node.id } |
        Select-Object -First 1
    if ($null -eq $nodeCreateAudit -or $nodeCreateAudit.request_id -ne $nodeCreateRequestId) {
        throw "expected node.create audit entry to preserve X-Request-Id"
    }
    $resourceHeartbeat = $auditLogs |
        Where-Object {
            $_.action -eq "agent.heartbeat" `
                -and $_.node_id -eq $node.id `
                -and $_.detail.cpu_total -gt 0 `
                -and $_.detail.memory_total -ge $_.detail.memory_used `
                -and $_.detail.disk_total -ge $_.detail.disk_used
        } |
        Select-Object -First 1
    if ($null -eq $resourceHeartbeat) {
        throw "expected agent heartbeat audit entry to include resource metrics"
    }
    foreach ($taskAuditCheck in @(
        @{ action = "task.create_vm"; task_id = $task.id; task_kind = "create_vm"; vm_id = $vm.id },
        @{ action = "task.cancel"; task_id = $canceledTask.id; task_kind = "create_vm"; vm_id = $cancelCandidate.kind.vm_id },
        @{ action = "task.reinstall_vm"; task_id = $reinstallTask.id; task_kind = "reinstall_vm"; vm_id = $vm.id },
        @{ action = "task.stop_vm"; task_id = $stopTask.id; task_kind = "stop_vm"; vm_id = $vm.id },
        @{ action = "task.start_vm"; task_id = $startTask.id; task_kind = "start_vm"; vm_id = $vm.id },
        @{ action = "task.reboot_vm"; task_id = $rebootTask.id; task_kind = "reboot_vm"; vm_id = $vm.id },
        @{ action = "task.delete_vm"; task_id = $deleteTask.id; task_kind = "delete_vm"; vm_id = $vm.id },
        @{ action = "task.assigned"; task_id = $task.id; task_kind = "create_vm"; vm_id = $vm.id },
        @{ action = "task.status_update"; task_id = $task.id; task_kind = "create_vm"; vm_id = $vm.id }
    )) {
        Assert-AuditTaskDetail `
            -AuditLogs $auditLogs `
            -Action $taskAuditCheck.action `
            -TaskId $taskAuditCheck.task_id `
            -TaskKind $taskAuditCheck.task_kind `
            -VmId $taskAuditCheck.vm_id
    }

    $taskLogs = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($task.id)/logs"
    $taskLogMessages = @($taskLogs | ForEach-Object { $_.message })
    foreach ($expectedLog in @(
        "task executor started",
        "mock executor accepted task: create_vm",
        "mock executor finished successfully"
    )) {
        if ($taskLogMessages -notcontains $expectedLog) {
            throw "expected task log '$expectedLog' was not returned"
        }
    }
    $reinstallTaskLogs = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($reinstallTask.id)/logs"
    $reinstallTaskLogMessages = @($reinstallTaskLogs | ForEach-Object { $_.message })
    if ($reinstallTaskLogMessages -notcontains "mock executor accepted task: reinstall_vm") {
        throw "expected reinstall task log was not returned"
    }
    foreach ($actionLogCheck in @(
        @{ task_id = $stopTask.id; expected = "mock executor accepted task: stop_vm" },
        @{ task_id = $startTask.id; expected = "mock executor accepted task: start_vm" },
        @{ task_id = $rebootTask.id; expected = "mock executor accepted task: reboot_vm" },
        @{ task_id = $deleteTask.id; expected = "mock executor accepted task: delete_vm" }
    )) {
        $actionLogs = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($actionLogCheck.task_id)/logs"
        $actionLogMessages = @($actionLogs | ForEach-Object { $_.message })
        if ($actionLogMessages -notcontains $actionLogCheck.expected) {
            throw "expected VM action task log '$($actionLogCheck.expected)' was not returned"
        }
    }

    $agentConfig = Get-Content -Raw -Path $agentConfigPath
    if ($agentConfig -match "bootstrap_token") {
        throw "agent config still contains bootstrap_token after registration"
    }
    if ($agentConfig -notmatch 'credential\s*=\s*"([^"]+)"') {
        throw "agent config does not contain persisted credential after registration"
    }
    $credential = $Matches[1]

    $doctorOutput = docker run --rm `
        -v "${repoRoot}:/work" `
        -v "${smokeDir}:/smoke" `
        -w /work `
        -e CARGO_INCREMENTAL=0 `
        -e VPS_AGENT_CONFIG=/smoke/agent.toml `
        -e VPS_AGENT_ALLOW_INSECURE_MASTER=1 `
        -e VPS_AGENT_ALLOW_INSECURE_CONFIG_PERMS=1 `
        rust:1.88 `
        cargo run -q -p vps-agent -- doctor 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw (New-AgentDoctorFailureMessage -ExitCode $LASTEXITCODE -DoctorOutput $doctorOutput)
    }
    if (($doctorOutput -join "`n") -notmatch "vps-agent doctor: ok") {
        throw "agent doctor did not report ok"
    }

    $failedTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/create-vm" -Body @{
        vm = @{
            node_id = $node.id
            name = "failed-vm"
            image = $imageFileName
            cpu_cores = 1
            memory_mb = 512
            disk_gb = 10
        }
    }
    $claimedFailure = Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/tasks/poll" `
        -Body @{ node_id = $node.id }
    if ($null -eq $claimedFailure.task -or $claimedFailure.task.id -ne $failedTask.id) {
        throw "expected manual agent poll to claim failed-task candidate"
    }
    Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/tasks/$($failedTask.id)/status" `
        -Body @{
            node_id = $node.id
            status = "running"
            error_message = $null
        } | Out-Null

    $sensitiveLogMessage = 'bootstrap_token=bt_smoke_secret password: "hunter2" authorization=BearerRawSecret'
    $taskLogPath = "/api/agent/tasks/$($failedTask.id)/logs"
    $taskLogBody = @{
        node_id = $node.id
        message = $sensitiveLogMessage
    } | ConvertTo-Json -Compress
    $taskLogTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $taskLogNonce = [guid]::NewGuid().ToString("N")
    $taskLogSignature = New-AgentSignature `
        -Credential $credential `
        -Method "POST" `
        -Path $taskLogPath `
        -Body $taskLogBody `
        -Timestamp $taskLogTimestamp `
        -Nonce $taskLogNonce
    Invoke-RestMethod `
        -Headers @{
            "X-Agent-Credential" = $credential
            "X-Agent-Timestamp" = "$taskLogTimestamp"
            "X-Agent-Nonce" = $taskLogNonce
            "X-Agent-Signature" = $taskLogSignature
        } `
        -Method Post `
        -Uri "$masterBaseUrl$taskLogPath" `
        -ContentType "application/json" `
        -Body $taskLogBody | Out-Null

    $failedTaskError = 'libvirt failed password=hunter2 credential=ag_should_not_persist'
    Invoke-AgentJson `
        -Credential $credential `
        -Method "POST" `
        -Path "/api/agent/tasks/$($failedTask.id)/status" `
        -Body @{
            node_id = $node.id
            status = "failed"
            error_message = $failedTaskError
        } | Out-Null
    $failedTaskRead = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($failedTask.id)"
    if ($failedTaskRead.status -ne "failed") {
        throw "expected failed task status to persist"
    }
    if ([string]::IsNullOrWhiteSpace($failedTaskRead.error_message)) {
        throw "expected failed task error_message to persist"
    }
    if ($failedTaskRead.error_message -match "hunter2|ag_should_not_persist") {
        throw "failed task error_message was stored without redaction"
    }
    $redactedLogs = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($failedTask.id)/logs"
    $redactedLog = $redactedLogs |
        Where-Object { $_.message -like "*bootstrap_token=*" } |
        Select-Object -Last 1
    if ($null -eq $redactedLog) {
        throw "expected redacted sensitive task log was not returned"
    }
    if ($redactedLog.message -match "bt_smoke_secret|hunter2|BearerRawSecret") {
        throw "sensitive task log was stored without redaction"
    }
    if ($redactedLog.message -notmatch "\[REDACTED\]") {
        throw "sensitive task log did not contain redaction marker"
    }
    $retriedTask = Invoke-MasterJson -Method Post -Path "/api/admin/tasks/$($failedTask.id)/retry"
    if ($retriedTask.status -ne "pending" -or $retriedTask.kind.vm_id -ne $failedTask.kind.vm_id) {
        throw "expected retry endpoint to create a pending replacement task for the same VM"
    }
    $retrySucceededRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "succeeded task was allowed to retry" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/$($task.id)/retry"
    }
    Invoke-AgentRunOnce -FailureMessage "agent retry smoke run failed"
    $retriedTaskRead = Invoke-MasterJson -Method Get -Path "/api/admin/tasks/$($retriedTask.id)"
    if ($retriedTaskRead.status -ne "succeeded" -or $null -ne $retriedTaskRead.error_message) {
        throw "expected retried task to succeed and clear error_message"
    }
    $retriedVm = (Invoke-MasterJson -Method Get -Path "/api/admin/vms") |
        Where-Object { $_.id -eq $failedTask.kind.vm_id } |
        Select-Object -First 1
    if ($null -eq $retriedVm -or $retriedVm.status -ne "running") {
        throw "expected retried VM to be running"
    }
    $retryAudit = (Invoke-MasterJson -Method Get -Path "/api/admin/audit-logs") |
        Where-Object { $_.action -eq "task.retry" -and $_.task_id -eq $retriedTask.id } |
        Select-Object -First 1
    if ($null -eq $retryAudit -or $retryAudit.detail.source_task_id -ne $failedTask.id) {
        throw "expected retry audit entry to reference the source task"
    }

    $terminalTransitionPath = "/api/agent/tasks/$($task.id)/status"
    $terminalTransitionBody = @{
        node_id = $node.id
        status = "running"
        error_message = $null
    } | ConvertTo-Json -Compress
    $terminalTransitionTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $terminalTransitionNonce = [guid]::NewGuid().ToString("N")
    $terminalTransitionSignature = New-AgentSignature `
        -Credential $credential `
        -Method "POST" `
        -Path $terminalTransitionPath `
        -Body $terminalTransitionBody `
        -Timestamp $terminalTransitionTimestamp `
        -Nonce $terminalTransitionNonce
    $terminalTransitionRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "terminal task was allowed to transition back to running" -Request {
        Invoke-RestMethod `
            -Headers @{
                "X-Agent-Credential" = $credential
                "X-Agent-Timestamp" = "$terminalTransitionTimestamp"
                "X-Agent-Nonce" = $terminalTransitionNonce
                "X-Agent-Signature" = $terminalTransitionSignature
            } `
            -Method Post `
            -Uri "$masterBaseUrl$terminalTransitionPath" `
            -ContentType "application/json" `
            -Body $terminalTransitionBody | Out-Null
    }
    $terminalCancelRejected = Test-HttpFailure -ExpectedStatus 409 -FailureMessage "finished task was allowed to be canceled" -Request {
        Invoke-MasterJson -Method Post -Path "/api/admin/tasks/$($task.id)/cancel"
    }

    $bootstrapReplayRejected = Test-HttpFailure -ExpectedStatus 401 -FailureMessage "bootstrap token replay was not rejected" -Request {
        Invoke-RestMethod `
            -Method Post `
            -Uri "$masterBaseUrl/api/agent/register" `
            -ContentType "application/json" `
            -Body (@{
                node_id = $node.id
                bootstrap_token = $bootstrap.bootstrap_token
                agent_version = "smoke-replay"
            } | ConvertTo-Json -Compress) | Out-Null
    }

    $otherNode = Invoke-MasterJson -Method Post -Path "/api/admin/nodes" -Body @{ name = "smoke-other-node" }

    $heartbeatBody = @{
        node_id = $node.id
        agent_version = "smoke"
        libvirt_status = "available"
        host_checks = @(
            @{
                name = "kvm"
                status = "passed"
                message = "/dev/kvm is available"
            }
        )
        cpu_total = 0
        cpu_used = 0
        memory_total = 0
        memory_used = 0
        disk_total = 0
        disk_used = 0
        vm_count = 0
    } | ConvertTo-Json -Compress
    $heartbeatPath = "/api/agent/heartbeat"
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $nonce = [guid]::NewGuid().ToString("N")
    $signature = New-AgentSignature `
        -Credential $credential `
        -Method "POST" `
        -Path $heartbeatPath `
        -Body $heartbeatBody `
        -Timestamp $timestamp `
        -Nonce $nonce
    $signedHeaders = @{
        "X-Agent-Credential" = $credential
        "X-Agent-Timestamp" = "$timestamp"
        "X-Agent-Nonce" = $nonce
        "X-Agent-Signature" = $signature
    }

    Invoke-RestMethod `
        -Headers $signedHeaders `
        -Method Post `
        -Uri "$masterBaseUrl$heartbeatPath" `
        -ContentType "application/json" `
        -Body $heartbeatBody | Out-Null

    $nodeAfterSignedHeartbeat = (Invoke-MasterJson -Method Get -Path "/api/admin/nodes") |
        Where-Object { $_.id -eq $node.id } |
        Select-Object -First 1
    if ($null -eq $nodeAfterSignedHeartbeat -or $nodeAfterSignedHeartbeat.libvirt_status -ne "available") {
        throw "expected signed heartbeat to persist libvirt_status"
    }
    if ($nodeAfterSignedHeartbeat.host_checks.Count -ne 1 -or $nodeAfterSignedHeartbeat.host_checks[0].name -ne "kvm") {
        throw "expected signed heartbeat to persist host preflight checks"
    }

    $replayRejected = $false
    try {
        Invoke-RestMethod `
            -Headers $signedHeaders `
            -Method Post `
            -Uri "$masterBaseUrl$heartbeatPath" `
            -ContentType "application/json" `
            -Body $heartbeatBody | Out-Null
    } catch {
        $replayRejected = $_.Exception.Response.StatusCode.value__ -eq 401
    }
    if (-not $replayRejected) {
        throw "agent request nonce replay was not rejected"
    }

    $wrongNodeBody = @{
        node_id = $otherNode.id
        agent_version = "smoke"
        libvirt_status = "not_checked"
        cpu_total = 0
        cpu_used = 0
        memory_total = 0
        memory_used = 0
        disk_total = 0
        disk_used = 0
        vm_count = 0
    } | ConvertTo-Json -Compress
    $wrongNodeNonce = [guid]::NewGuid().ToString("N")
    $wrongNodeTimestamp = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $wrongNodeSignature = New-AgentSignature `
        -Credential $credential `
        -Method "POST" `
        -Path $heartbeatPath `
        -Body $wrongNodeBody `
        -Timestamp $wrongNodeTimestamp `
        -Nonce $wrongNodeNonce
    $wrongNodeRejected = Test-HttpFailure -ExpectedStatus 401 -FailureMessage "wrong node heartbeat was not rejected" -Request {
        Invoke-RestMethod `
            -Headers @{
                "X-Agent-Credential" = $credential
                "X-Agent-Timestamp" = "$wrongNodeTimestamp"
                "X-Agent-Nonce" = $wrongNodeNonce
                "X-Agent-Signature" = $wrongNodeSignature
            } `
            -Method Post `
            -Uri "$masterBaseUrl$heartbeatPath" `
            -ContentType "application/json" `
            -Body $wrongNodeBody | Out-Null
    }

    [pscustomobject]@{
        node_id = $node.id
        task_id = $task.id
        vm_id = $vm.id
        vm_status = "deleted"
        assigned_ip = $vm.assigned_ip
        assigned_ip_prefix = $task.kind.assigned_ip_prefix
        assigned_gateway_ip = $task.kind.assigned_gateway_ip
        ip_pool_allocated_count = $updatedPool.allocated_count
        bootstrap_token_cleared = $true
        agent_credential_persisted = $true
        agent_doctor_ok = $true
        agent_binary_downloaded = $true
        install_command_checksum_pinned = $true
        image_catalog_visible = $null -ne $image
        plan_catalog_visible = $null -ne $plan
        task_logs_visible = $true
        audit_logs_visible = $true
        audit_request_id_visible = $true
        resource_heartbeat_reported = $true
        node_resource_metrics_persisted = $true
        node_host_checks_persisted = $true
        node_committed_capacity_visible = $true
        node_scheduling_disable_rejected_task = $nodeSchedulingDisabledRejectedTask
        node_scheduling_disable_paused_pending_assignment = $nodeSchedulingDisablePausedPendingAssignment
        node_scheduling_reenabled = $true
        node_capacity_rejected_task = $nodeCapacityRejectedTask
        failed_task_error_message_persisted = $true
        failed_task_retry_succeeded = $true
        succeeded_task_retry_rejected = $retrySucceededRejected
        pending_task_canceled = $true
        reinstall_task_succeeded = $true
        vm_stop_start_reboot_delete_succeeded = $true
        provisioning_vm_action_rejected = $provisioningVmActionRejected
        deleted_vm_action_rejected = $deletedVmActionRejected
        terminal_transition_rejected = $terminalTransitionRejected
        terminal_cancel_rejected = $terminalCancelRejected
        admin_session_login = $true
        bad_admin_session_rejected = $badAdminSessionRejected
        readonly_get_allowed = $true
        readonly_mutation_rejected = $readonlyMutationRejected
        readonly_plan_toggle_rejected = $readonlyPlanToggleRejected
        readonly_image_toggle_rejected = $readonlyImageToggleRejected
        unregistered_node_task_rejected = $unregisteredNodeTaskRejected
        secret_log_redacted = $true
        invalid_vm_rejected = $invalidVmRejected
        invalid_ssh_public_key_rejected = $invalidSshKeyRejected
        unregistered_image_rejected = $unregisteredImageRejected
        disabled_image_rejected = $disabledImageRejected
        reinstall_unknown_image_rejected = $reinstallUnknownImageRejected
        disabled_plan_rejected = $disabledPlanRejected
        bootstrap_replay_rejected = $bootstrapReplayRejected
        wrong_node_rejected = $wrongNodeRejected
        nonce_replay_rejected = $true
    } | ConvertTo-Json -Depth 4
} catch {
    Write-RedactedDockerLogs -ContainerName $containerName -Tail 200
    throw
} finally {
    Remove-Item Env:SECRET_TO_HASH -ErrorAction SilentlyContinue
    Remove-SmokeContainer
    Invoke-Compose -Arguments @("-f", (Join-Path $repoRoot "deploy/docker-compose.yml"), "down") -IgnoreFailure
    Restore-ComposeEnv
    Remove-Item -Recurse -Force $smokeDir -ErrorAction SilentlyContinue
}
