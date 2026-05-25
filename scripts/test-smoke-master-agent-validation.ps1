$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$scriptPath = Join-Path $repoRoot "scripts/smoke-master-agent.ps1"

$tokens = $null
$parseErrors = $null
$scriptAst = [System.Management.Automation.Language.Parser]::ParseFile(
    $scriptPath,
    [ref] $tokens,
    [ref] $parseErrors
)
if ($parseErrors.Count -gt 0) {
    throw "smoke-master-agent.ps1 has PowerShell parse errors"
}

$failureMessageFunction = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "New-AgentDoctorFailureMessage"
}, $true)
if ($null -eq $failureMessageFunction) {
    throw "New-AgentDoctorFailureMessage helper was not found"
}

. ([scriptblock]::Create($failureMessageFunction.Extent.Text))

$message = New-AgentDoctorFailureMessage `
    -ExitCode 42 `
    -DoctorOutput @(
        "credential=ag_should_not_print",
        "bootstrap_token=bt_should_not_print",
        "vps-agent doctor failed"
    )

if ($message -match "ag_should_not_print|bt_should_not_print|credential=|bootstrap_token=") {
    throw "agent doctor failure message leaked raw doctor output"
}
if ($message -notmatch "agent doctor failed with exit code 42") {
    throw "agent doctor failure message did not include the exit code"
}
if ($message -notmatch "suppressed") {
    throw "agent doctor failure message did not explain that raw output was suppressed"
}

$redactionFunction = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "ConvertTo-RedactedSmokeLogLine"
}, $true)
if ($null -eq $redactionFunction) {
    throw "ConvertTo-RedactedSmokeLogLine helper was not found"
}

$dockerLogFunction = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Write-RedactedDockerLogs"
}, $true)
if ($null -eq $dockerLogFunction) {
    throw "Write-RedactedDockerLogs helper was not found"
}

$composeFunction = $scriptAst.Find({
    param($node)
    $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -eq "Invoke-Compose"
}, $true)
if ($null -eq $composeFunction) {
    throw "Invoke-Compose helper was not found"
}

if ($scriptAst.Extent.Text -cmatch 'docker logs \$containerName') {
    throw "smoke script still dumps raw docker logs through the global container name"
}
if ($scriptAst.Extent.Text -notmatch '"MASTER_ADMIN_USERNAME"' -or $scriptAst.Extent.Text -notmatch '\$env:MASTER_ADMIN_USERNAME\s*=\s*"admin"') {
    throw "smoke script must set and restore MASTER_ADMIN_USERNAME for docker compose"
}

. ([scriptblock]::Create($redactionFunction.Extent.Text))
. ([scriptblock]::Create($dockerLogFunction.Extent.Text))
. ([scriptblock]::Create($composeFunction.Extent.Text))

$redactedLine = ConvertTo-RedactedSmokeLogLine -Text 'bootstrap_token=bt_should_not_print credential="ag_should_not_print" password: "hunter2" Authorization: Bearer raw_secret X-Agent-Credential: ag_header_should_not_print X-Agent-Signature: sig_should_not_print Cookie: admin_session=session-secret; csrf_token=csrf-secret Set-Cookie: admin_session=set-secret postgres://user:pass@db/app'
if ($redactedLine -match "bt_should_not_print|ag_should_not_print|ag_header_should_not_print|sig_should_not_print|hunter2|raw_secret|session-secret|csrf-secret|set-secret|user:pass") {
    throw "smoke docker log redactor leaked secret-like values"
}
if ($redactedLine -notmatch "\[REDACTED\]") {
    throw "smoke docker log redactor did not include redaction markers"
}

function docker {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

    "credential=ag_should_not_print"
    "normal smoke diagnostic"
}

$logOutput = Write-RedactedDockerLogs -ContainerName "test-container" -Tail 3 2>&1
$joinedLogOutput = $logOutput -join "`n"
if ($joinedLogOutput -match "ag_should_not_print") {
    throw "redacted docker log helper leaked raw docker log output"
}
if ($joinedLogOutput -notmatch "normal smoke diagnostic") {
    throw "redacted docker log helper dropped non-secret diagnostics"
}

function docker {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

    throw "Error response from daemon: No such container: missing-smoke-container"
}

$missingContainerLogOutput = Write-RedactedDockerLogs -ContainerName "missing-smoke-container" -Tail 5 2>&1
$joinedMissingContainerLogOutput = $missingContainerLogOutput -join "`n"
if ($joinedMissingContainerLogOutput -notmatch "docker logs failed with exit code 1") {
    throw "redacted docker log helper did not report missing-container log collection failure"
}
if ($joinedMissingContainerLogOutput -match "credential=|bootstrap_token=|Authorization: Bearer") {
    throw "missing-container docker log failure leaked secret-like output"
}

function docker {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)

    "credential=compose_should_not_print"
    "normal compose diagnostic"
    $global:LASTEXITCODE = 1
}

$composeFailureOutput = try {
    Invoke-Compose -Arguments @("-f", "compose.yml", "up", "-d", "postgres") 2>&1
} catch {
    @($Error[0].ToString())
}
$joinedComposeFailureOutput = $composeFailureOutput -join "`n"
if ($joinedComposeFailureOutput -match "compose_should_not_print") {
    throw "compose failure diagnostics leaked secret-like output"
}
if ($joinedComposeFailureOutput -notmatch "normal compose diagnostic") {
    throw "compose failure diagnostics dropped non-secret output"
}
if ($joinedComposeFailureOutput -notmatch "docker compose failed with exit code 1") {
    throw "compose failure diagnostics did not include the exit code"
}

Write-Output "smoke-master-agent validation tests passed"
