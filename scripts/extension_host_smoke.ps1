param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$BridgeAddress = $(if ($env:CURSOR_BRIDGE_TCP_ADDR) { $env:CURSOR_BRIDGE_TCP_ADDR } else { "127.0.0.1:7797" }),
    [string]$AgentBaseUrl = "",
    [string]$Prompt = "auth middleware 401 handling bug root cause를 설명하고 patch를 제안해줘",
    [string]$Template = "smoke",
    [string]$ExpectedPatchPath = "src/auth/middleware.ts",
    [string]$ExpectedDiffPattern = "return res\.status\(401\)\.send\(\)",
    [string]$RunProfileId = "test_all",
    [string]$ExpectedRunStatus = "failed",
    [string]$RunProfileFile = "",
    [bool]$IncludeActiveFile = $true,
    [bool]$IncludeSelection = $true,
    [bool]$IncludeLatestError = $true,
    [bool]$IncludeWorkspaceSummary = $true,
    [int]$StartupTimeoutSec = 60,
    [switch]$KeepTempRoot
)

$ErrorActionPreference = "Stop"

function Resolve-RequiredCommand {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Hint = ""
    )

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        if ($Hint) {
            throw "$Name 명령을 찾을 수 없습니다. $Hint"
        }
        throw "$Name 명령을 찾을 수 없습니다."
    }
    return $command
}

function Get-FreeLoopbackUrl {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        $endpoint = [System.Net.IPEndPoint]$listener.LocalEndpoint
        return "http://127.0.0.1:$($endpoint.Port)"
    } finally {
        $listener.Stop()
    }
}

function Split-BridgeAddress {
    param([Parameter(Mandatory = $true)][string]$Address)

    $trimmed = $Address.Trim()
    $separator = $trimmed.LastIndexOf(':')
    if ($separator -lt 1) {
        throw "bridge 주소 형식이 잘못되었습니다: $Address"
    }

    $bridgeHost = $trimmed.Substring(0, $separator)
    $port = 0
    if (-not [int]::TryParse($trimmed.Substring($separator + 1), [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        throw "bridge port가 잘못되었습니다: $Address"
    }

    return [PSCustomObject]@{
        Hostname = $bridgeHost
        Port = $port
    }
}

function Invoke-BridgeJsonRpc {
    param(
        [Parameter(Mandatory = $true)][string]$Hostname,
        [Parameter(Mandatory = $true)][int]$Port,
        [Parameter(Mandatory = $true)][string]$Method,
        [object]$Params,
        [int]$TimeoutSec = 10
    )

    $client = $null
    $stream = $null
    $writer = $null
    $reader = $null
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $connectTask = $client.ConnectAsync($Hostname, $Port)
        if (-not $connectTask.Wait([TimeSpan]::FromSeconds($TimeoutSec))) {
            throw "bridge 연결 timeout: $Hostname`:$Port"
        }

        $stream = $client.GetStream()
        $stream.ReadTimeout = $TimeoutSec * 1000
        $stream.WriteTimeout = $TimeoutSec * 1000
        $writer = [System.IO.StreamWriter]::new($stream, [System.Text.UTF8Encoding]::new($false), 1024, $true)
        $writer.NewLine = "`n"
        $writer.AutoFlush = $true
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true, 1024, $true)

        $request = @{
            id = "bridge-" + [System.Guid]::NewGuid().ToString("N")
            method = $Method
        }
        if ($PSBoundParameters.ContainsKey("Params") -and $null -ne $Params) {
            $request.params = $Params
        }

        $writer.WriteLine(($request | ConvertTo-Json -Depth 10 -Compress))
        $line = $reader.ReadLine()
        if ([string]::IsNullOrWhiteSpace($line)) {
            throw "bridge 응답이 비어 있습니다."
        }

        $response = $line | ConvertFrom-Json
        if ($response.error -and -not [string]::IsNullOrWhiteSpace($response.error.message)) {
            throw "bridge $Method 실패: $($response.error.message)"
        }

        return $response.result
    } finally {
        if ($reader) { $reader.Dispose() }
        if ($writer) { $writer.Dispose() }
        if ($stream) { $stream.Dispose() }
        if ($client) { $client.Dispose() }
    }
}

function Wait-AgentReady {
    param(
        [Parameter(Mandatory = $true)][string]$HealthUrl,
        [Parameter(Mandatory = $true)][System.Diagnostics.Process]$Process,
        [int]$TimeoutSec = 60,
        [string]$StdErrLog = ""
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    do {
        if ($Process.HasExited) {
            $stderr = if ($StdErrLog -and (Test-Path $StdErrLog)) { Get-Content -Path $StdErrLog -Raw } else { "" }
            throw "agent가 준비되기 전에 종료되었습니다. exit=$($Process.ExitCode) $stderr"
        }

        try {
            return Invoke-RestMethod -Method Get -Uri $HealthUrl -TimeoutSec 2
        } catch {
            Start-Sleep -Milliseconds 1000
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "agent readiness timeout: $HealthUrl"
}

function Invoke-AgentJson {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body
    )

    if ($PSBoundParameters.ContainsKey("Body")) {
        return Invoke-RestMethod -Method $Method -Uri $Uri -ContentType "application/json" -Body ($Body | ConvertTo-Json -Depth 10)
    }

    return Invoke-RestMethod -Method $Method -Uri $Uri
}

function Invoke-GoBuild {
    param(
        [Parameter(Mandatory = $true)][string]$GoCommandPath,
        [Parameter(Mandatory = $true)][string]$RepoRoot,
        [Parameter(Mandatory = $true)][string]$OutputPath,
        [Parameter(Mandatory = $true)][string]$GoCacheDir,
        [Parameter(Mandatory = $true)][string]$GoTmpDir
    )

    $previousGoCache = [Environment]::GetEnvironmentVariable("GOCACHE", "Process")
    $previousGoTmpDir = [Environment]::GetEnvironmentVariable("GOTMPDIR", "Process")
    try {
        [Environment]::SetEnvironmentVariable("GOCACHE", $GoCacheDir, "Process")
        [Environment]::SetEnvironmentVariable("GOTMPDIR", $GoTmpDir, "Process")
        Push-Location $RepoRoot
        try {
            & $GoCommandPath build "-buildvcs=false" "-o" $OutputPath "./cmd/agent"
            if ($LASTEXITCODE -ne 0) {
                throw "agent binary build failed: exit $LASTEXITCODE"
            }
        } finally {
            Pop-Location
        }
    } finally {
        [Environment]::SetEnvironmentVariable("GOCACHE", $previousGoCache, "Process")
        [Environment]::SetEnvironmentVariable("GOTMPDIR", $previousGoTmpDir, "Process")
    }
}

function Start-AgentBinaryProcess {
    param(
        [Parameter(Mandatory = $true)][string]$BinaryPath,
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string]$ListenAddress,
        [Parameter(Mandatory = $true)][string]$BridgeAddress,
        [Parameter(Mandatory = $true)][string]$StdoutLog,
        [Parameter(Mandatory = $true)][string]$StderrLog,
        [string]$RunProfileFile = ""
    )

    $stdoutWriter = [System.IO.StreamWriter]::new($StdoutLog, $false, [System.Text.UTF8Encoding]::new($false))
    $stderrWriter = [System.IO.StreamWriter]::new($StderrLog, $false, [System.Text.UTF8Encoding]::new($false))
    $stdoutWriter.AutoFlush = $true
    $stderrWriter.AutoFlush = $true

    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $BinaryPath
    $startInfo.WorkingDirectory = $WorkingDirectory
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.Environment["AGENT_ADDR"] = $ListenAddress
    $startInfo.Environment["CURSOR_BRIDGE_TCP_ADDR"] = $BridgeAddress
    if (-not [string]::IsNullOrWhiteSpace($RunProfileFile)) {
        $startInfo.Environment["RUN_PROFILE_FILE"] = $RunProfileFile
    }

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $startInfo

    $stdoutHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            $stdoutWriter.WriteLine($eventArgs.Data)
        }
    }
    $stderrHandler = [System.Diagnostics.DataReceivedEventHandler]{
        param($sender, $eventArgs)
        if ($null -ne $eventArgs.Data) {
            $stderrWriter.WriteLine($eventArgs.Data)
        }
    }

    $process.add_OutputDataReceived($stdoutHandler)
    $process.add_ErrorDataReceived($stderrHandler)

    try {
        if (-not $process.Start()) {
            throw "agent process start failed"
        }
        $process.BeginOutputReadLine()
        $process.BeginErrorReadLine()
        return [PSCustomObject]@{
            Process = $process
            StdoutWriter = $stdoutWriter
            StderrWriter = $stderrWriter
            StdoutHandler = $stdoutHandler
            StderrHandler = $stderrHandler
        }
    } catch {
        $process.remove_OutputDataReceived($stdoutHandler)
        $process.remove_ErrorDataReceived($stderrHandler)
        $process.Dispose()
        $stdoutWriter.Dispose()
        $stderrWriter.Dispose()
        throw
    }
}

function New-Envelope {
    param(
        [Parameter(Mandatory = $true)][string]$Sid,
        [Parameter(Mandatory = $true)][string]$Rid,
        [Parameter(Mandatory = $true)][int]$Seq,
        [Parameter(Mandatory = $true)][string]$Type,
        [Parameter(Mandatory = $true)][hashtable]$Payload
    )

    return @{
        sid = $Sid
        rid = $Rid
        seq = $Seq
        ts = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
        type = $Type
        payload = $Payload
    }
}

$repoRootResolved = (Resolve-Path $RepoRoot).Path
$goCommand = Resolve-RequiredCommand -Name "go" -Hint "Go toolchain이 필요합니다."
if ([string]::IsNullOrWhiteSpace($AgentBaseUrl)) {
    $AgentBaseUrl = Get-FreeLoopbackUrl
}
if (-not [string]::IsNullOrWhiteSpace($RunProfileFile)) {
    $RunProfileFile = (Resolve-Path $RunProfileFile).Path
}

$bridge = Split-BridgeAddress -Address $BridgeAddress
$bridgeName = Invoke-BridgeJsonRpc -Hostname $bridge.Hostname -Port $bridge.Port -Method "name"
if ($bridgeName -ne "cursor-extension-bridge") {
    throw "unexpected bridge name: $bridgeName (extension host의 mock mode 또는 command mode bridge가 필요합니다)"
}
$null = Invoke-BridgeJsonRpc -Hostname $bridge.Hostname -Port $bridge.Port -Method "capabilities"

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("vibedeck-extension-smoke-" + [System.Guid]::NewGuid().ToString("N"))
$logsDir = Join-Path $tempRoot "logs"
[System.IO.Directory]::CreateDirectory($logsDir) | Out-Null
$stdoutLog = Join-Path $logsDir "agent.stdout.log"
$stderrLog = Join-Path $logsDir "agent.stderr.log"
$agentBinaryDir = Join-Path $tempRoot "agent-bin"
$agentBinaryPath = Join-Path $agentBinaryDir "agent.exe"
$goCacheDir = Join-Path $tempRoot "go-cache"
$goTmpDir = Join-Path $tempRoot "go-tmp"
[System.IO.Directory]::CreateDirectory($agentBinaryDir) | Out-Null
[System.IO.Directory]::CreateDirectory($goCacheDir) | Out-Null
[System.IO.Directory]::CreateDirectory($goTmpDir) | Out-Null
$listenAddress = $AgentBaseUrl -replace "^https?://", ""

$agentRuntime = $null
$smokeSucceeded = $false
try {
    Invoke-GoBuild -GoCommandPath $goCommand.Source -RepoRoot $repoRootResolved -OutputPath $agentBinaryPath -GoCacheDir $goCacheDir -GoTmpDir $goTmpDir
    $agentRuntime = Start-AgentBinaryProcess -BinaryPath $agentBinaryPath -WorkingDirectory $repoRootResolved -ListenAddress $listenAddress -BridgeAddress $BridgeAddress -StdoutLog $stdoutLog -StderrLog $stderrLog -RunProfileFile $RunProfileFile
    $null = Wait-AgentReady -HealthUrl ($AgentBaseUrl.TrimEnd("/") + "/healthz") -Process $agentRuntime.Process -TimeoutSec $StartupTimeoutSec -StdErrLog $stderrLog

    $adapter = Invoke-AgentJson -Method GET -Uri ($AgentBaseUrl.TrimEnd("/") + "/v1/agent/runtime/adapter")
    if ($adapter.name -ne "cursor-extension-bridge") {
        throw "unexpected adapter name: $($adapter.name)"
    }

    $sid = "sid-extension-smoke"
    $promptResponse = Invoke-AgentJson -Method POST -Uri ($AgentBaseUrl.TrimEnd("/") + "/v1/agent/envelope") -Body (New-Envelope -Sid $sid -Rid "rid-prompt-1" -Seq 1 -Type "PROMPT_SUBMIT" -Payload @{
        prompt = $Prompt
        template = $Template
        contextOptions = @{
            includeActiveFile = $IncludeActiveFile
            includeSelection = $IncludeSelection
            includeLatestError = $IncludeLatestError
            includeWorkspaceSummary = $IncludeWorkspaceSummary
        }
    })

    $promptAck = $promptResponse.responses | Where-Object { $_.type -eq "PROMPT_ACK" } | Select-Object -First 1
    $patchReady = $promptResponse.responses | Where-Object { $_.type -eq "PATCH_READY" } | Select-Object -First 1
    if (-not $promptAck) {
        throw "PROMPT_ACK response not found"
    }
    if (-not $patchReady) {
        throw "PATCH_READY response not found"
    }

    $jobId = $promptAck.payload.jobId
    if ([string]::IsNullOrWhiteSpace($jobId)) {
        throw "jobId missing from PROMPT_ACK"
    }

    $patchFiles = @($patchReady.payload.files)
    if ($patchFiles.Count -ne 1 -or $patchFiles[0].path -ne $ExpectedPatchPath) {
        throw "unexpected patch files: $(($patchFiles | ConvertTo-Json -Depth 6 -Compress))"
    }
    $patchDiff = @($patchFiles[0].hunks | ForEach-Object { $_.diff }) -join "`n"
    if (-not [string]::IsNullOrWhiteSpace($ExpectedDiffPattern) -and $patchDiff -notmatch $ExpectedDiffPattern) {
        throw "smoke patch does not contain expected fix: $patchDiff"
    }
    $patchFilePaths = @($patchFiles | Where-Object { $null -ne $_ } | ForEach-Object { $_.path })

    $applyResponse = Invoke-AgentJson -Method POST -Uri ($AgentBaseUrl.TrimEnd("/") + "/v1/agent/envelope") -Body (New-Envelope -Sid $sid -Rid "rid-apply-1" -Seq 2 -Type "PATCH_APPLY" -Payload @{
        jobId = $jobId
        mode = "all"
    })
    $patchResult = $applyResponse.responses | Where-Object { $_.type -eq "PATCH_RESULT" } | Select-Object -First 1
    if (-not $patchResult) {
        throw "PATCH_RESULT response not found"
    }
    if ($patchResult.payload.status -ne "success") {
        throw "patch apply failed: $($patchResult.payload.status) $($patchResult.payload.message)"
    }

    $runResponse = Invoke-AgentJson -Method POST -Uri ($AgentBaseUrl.TrimEnd("/") + "/v1/agent/envelope") -Body (New-Envelope -Sid $sid -Rid "rid-run-1" -Seq 3 -Type "RUN_PROFILE" -Payload @{
        jobId = $jobId
        profileId = $RunProfileId
    })
    $runResult = $runResponse.responses | Where-Object { $_.type -eq "RUN_RESULT" } | Select-Object -First 1
    if (-not $runResult) {
        throw "RUN_RESULT response not found"
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedRunStatus) -and $runResult.payload.status -ne $ExpectedRunStatus) {
        throw "unexpected run status: $($runResult.payload.status)"
    }
    $topErrors = @($runResult.payload.topErrors)
    $topErrorMessage = $null
    if ($topErrors.Count -gt 0 -and $null -ne $topErrors[0]) {
        $topErrorMessage = $topErrors[0].message
    }

    $smokeSucceeded = $true
    [PSCustomObject]@{
        bridgeAddress = $BridgeAddress
        bridgeName = $bridgeName
        adapterName = $adapter.name
        adapterMode = $adapter.mode
        patchSummary = $patchReady.payload.summary
        patchFiles = $patchFilePaths
        applyStatus = $patchResult.payload.status
        jobId = $jobId
        promptTemplate = $Template
        runProfileId = $RunProfileId
        runStatus = $runResult.payload.status
        runSummary = $runResult.payload.summary
        topError = $topErrorMessage
        tempRoot = $tempRoot
    }
} finally {
    if ($agentRuntime -and $agentRuntime.Process -and -not $agentRuntime.Process.HasExited) {
        $agentRuntime.Process.Kill()
        $agentRuntime.Process.WaitForExit()
    }
    if ($agentRuntime) {
        try {
            $agentRuntime.Process.CancelOutputRead()
        } catch {
        }
        try {
            $agentRuntime.Process.CancelErrorRead()
        } catch {
        }
        Start-Sleep -Milliseconds 250
        try {
            $agentRuntime.Process.remove_OutputDataReceived($agentRuntime.StdoutHandler)
            $agentRuntime.Process.remove_ErrorDataReceived($agentRuntime.StderrHandler)
        } catch {
        }
        try {
            $agentRuntime.Process.Dispose()
        } catch {
        }
        try {
            $agentRuntime.StdoutWriter.Dispose()
        } catch {
        }
        try {
            $agentRuntime.StderrWriter.Dispose()
        } catch {
        }
        $agentRuntime = $null
        Start-Sleep -Milliseconds 1000
    }
    if ($smokeSucceeded) {
        $global:LASTEXITCODE = 0
    }
    if (-not $KeepTempRoot -and (Test-Path $tempRoot)) {
        for ($attempt = 0; $attempt -lt 30; $attempt++) {
            try {
                Remove-Item -Path $tempRoot -Recurse -Force -ErrorAction Stop
                break
            } catch {
                if ($attempt -eq 29) {
                    Write-Warning "temp root cleanup skipped: $tempRoot / $($_.Exception.Message)"
                } else {
                    Start-Sleep -Milliseconds 1000
                }
            }
        }
    }
    if ($smokeSucceeded) {
        $global:LASTEXITCODE = 0
    }
}
