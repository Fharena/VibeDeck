param(
    [string]$RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [switch]$FailOnError
)

$ErrorActionPreference = "Stop"

function New-CheckResult {
    param(
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Status,
        [Parameter(Mandatory = $true)][string]$Summary,
        [string]$Hint = ""
    )

    return [PSCustomObject]@{
        category = $Category
        status = $Status
        summary = $Summary
        hint = $Hint
    }
}

function Get-CommandInfo {
    param([Parameter(Mandatory = $true)][string]$Name)

    $command = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $command) {
        return $null
    }
    return $command.Source
}

function Normalize-CommandText {
    param([string]$Value)

    return ($Value -replace "`0", '').Trim()
}

function Get-VersionText {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$ArgumentList = @("--version")
    )

    try {
        $output = & $FilePath @ArgumentList 2>$null
        $text = Normalize-CommandText (($output | Out-String))
        if ([string]::IsNullOrWhiteSpace($text)) {
            return "version check unavailable"
        }
        return ($text -split "`r?`n")[0]
    } catch {
        return "version check failed"
    }
}

function Get-WslCursorAgentInfo {
    $wsl = Get-CommandInfo -Name "wsl.exe"
    if (-not $wsl) {
        return $null
    }

    try {
        $distrosRaw = Normalize-CommandText ((& $wsl -l -q 2>$null | Out-String))
    } catch {
        return [PSCustomObject]@{
            available = $true
            resolved = $false
            summary = "WSL distro 목록 조회 실패"
        }
    }

    $distros = @()
    foreach ($line in $distrosRaw.Split("`n")) {
        $name = $line.Trim()
        if (-not [string]::IsNullOrWhiteSpace($name)) {
            $distros += $name
        }
    }

    foreach ($distro in $distros) {
        try {
            $bin = & $wsl -d $distro -- bash -lc 'if command -v cursor-agent >/dev/null 2>&1; then command -v cursor-agent; elif command -v agent >/dev/null 2>&1; then command -v agent; fi' 2>$null
            $resolvedBin = Normalize-CommandText (($bin | Out-String))
            if (-not [string]::IsNullOrWhiteSpace($resolvedBin)) {
                $version = & $wsl -d $distro -- bash -lc "PATH=\"\$HOME/.local/bin:\$PATH\"; $resolvedBin --version" 2>$null
                $resolvedVersion = Normalize-CommandText (($version | Out-String))
                return [PSCustomObject]@{
                    available = $true
                    resolved = $true
                    distro = $distro
                    bin = $resolvedBin
                    version = if ([string]::IsNullOrWhiteSpace($resolvedVersion)) { "version check unavailable" } else { ($resolvedVersion -split "`r?`n")[0] }
                    summary = "WSL cursor-agent detected"
                }
            }
        } catch {
        }
    }

    return [PSCustomObject]@{
        available = $true
        resolved = $false
        summary = if ($distros.Count -gt 0) { "distro 확인됨, cursor-agent 미탐지" } else { "설치된 distro 없음" }
    }
}

function Add-FileCheck {
    param(
        [Parameter(Mandatory = $true)][System.Collections.Generic.List[object]]$Results,
        [Parameter(Mandatory = $true)][string]$Category,
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][string]$Hint
    )

    if (Test-Path $Path) {
        $Results.Add((New-CheckResult -Category $Category -Status "OK" -Summary $Path))
        return $true
    }

    $Results.Add((New-CheckResult -Category $Category -Status "FAIL" -Summary "missing: $Path" -Hint $Hint))
    return $false
}

$repoRootResolved = (Resolve-Path $RepoRoot).Path
$results = [System.Collections.Generic.List[object]]::new()

$gitPath = Get-CommandInfo -Name "git"
if ($gitPath) {
    $results.Add((New-CheckResult -Category "git" -Status "OK" -Summary (Get-VersionText -FilePath $gitPath)))
} else {
    $results.Add((New-CheckResult -Category "git" -Status "FAIL" -Summary "git 미설치" -Hint "Git 설치 후 다시 실행하세요." ))
}

$goPath = Get-CommandInfo -Name "go"
if ($goPath) {
    $results.Add((New-CheckResult -Category "go" -Status "OK" -Summary (Get-VersionText -FilePath $goPath -ArgumentList @("version"))))
} else {
    $results.Add((New-CheckResult -Category "go" -Status "FAIL" -Summary "go 미설치" -Hint "Go 1.23+ 설치가 필요합니다." ))
}

$nodePath = Get-CommandInfo -Name "node"
if ($nodePath) {
    $results.Add((New-CheckResult -Category "node" -Status "OK" -Summary (Get-VersionText -FilePath $nodePath)))
} else {
    $results.Add((New-CheckResult -Category "node" -Status "FAIL" -Summary "node 미설치" -Hint "Node.js 22+ 설치가 필요합니다." ))
}

$npmPath = Get-CommandInfo -Name "npm"
if ($npmPath) {
    $results.Add((New-CheckResult -Category "npm" -Status "OK" -Summary (Get-VersionText -FilePath $npmPath)))
} else {
    $results.Add((New-CheckResult -Category "npm" -Status "FAIL" -Summary "npm 미설치" -Hint "Node.js 설치에 npm이 포함되어야 합니다." ))
}

$flutterLocal = Join-Path $repoRootResolved "tools\flutter\bin\flutter.bat"
$flutterGlobal = Get-CommandInfo -Name "flutter"
if (Test-Path $flutterLocal) {
    $results.Add((New-CheckResult -Category "flutter" -Status "OK" -Summary "local sdk: $flutterLocal"))
} elseif ($flutterGlobal) {
    $results.Add((New-CheckResult -Category "flutter" -Status "OK" -Summary (Get-VersionText -FilePath $flutterGlobal)))
} else {
    $results.Add((New-CheckResult -Category "flutter" -Status "WARN" -Summary "flutter 미탐지" -Hint "모바일 앱까지 확인할 때만 필요합니다." ))
}

$cursorCli = Get-CommandInfo -Name "cursor"
$codeCli = Get-CommandInfo -Name "code"
if ($cursorCli) {
    $results.Add((New-CheckResult -Category "editor-cli" -Status "OK" -Summary "cursor: $cursorCli"))
} elseif ($codeCli) {
    $results.Add((New-CheckResult -Category "editor-cli" -Status "OK" -Summary "code: $codeCli"))
} else {
    $results.Add((New-CheckResult -Category "editor-cli" -Status "WARN" -Summary "Cursor/VS Code CLI 미탐지" -Hint "GUI extension smoke나 VSIX 설치 자동화에 필요합니다." ))
}

$cursorAgentNative = $null
foreach ($candidate in @("cursor-agent", "agent")) {
    $resolved = Get-CommandInfo -Name $candidate
    if ($resolved) {
        $cursorAgentNative = [PSCustomObject]@{
            name = $candidate
            path = $resolved
            version = Get-VersionText -FilePath $resolved
        }
        break
    }
}
if ($cursorAgentNative) {
    $results.Add((New-CheckResult -Category "cursor-agent(native)" -Status "OK" -Summary "$($cursorAgentNative.name): $($cursorAgentNative.version)"))
} else {
    $results.Add((New-CheckResult -Category "cursor-agent(native)" -Status "WARN" -Summary "네이티브 cursor-agent 미탐지" -Hint "WSL 경로를 쓰면 계속 진행 가능합니다." ))
}

$wslCursorAgent = Get-WslCursorAgentInfo
if ($wslCursorAgent -and $wslCursorAgent.resolved) {
    $results.Add((New-CheckResult -Category "cursor-agent(wsl)" -Status "OK" -Summary $wslCursorAgent.summary))
} elseif ($wslCursorAgent -and $wslCursorAgent.available) {
    $results.Add((New-CheckResult -Category "cursor-agent(wsl)" -Status "WARN" -Summary $wslCursorAgent.summary -Hint "WSL을 쓰려면 distro 안에서 cursor-agent login까지 끝내야 합니다." ))
}

$adapterDistOk = Add-FileCheck -Results $results -Category "adapter-dist" -Path (Join-Path $repoRootResolved "adapters\cursor-bridge\dist\index.js") -Hint "npm --prefix .\adapters\cursor-bridge install ; npm --prefix .\adapters\cursor-bridge run build"
$extensionDistOk = Add-FileCheck -Results $results -Category "extension-dist" -Path (Join-Path $repoRootResolved "extensions\vibedeck-bridge\dist\extension.js") -Hint "npm --prefix .\extensions\vibedeck-bridge install ; npm --prefix .\extensions\vibedeck-bridge run build"
$vsceCmd = Join-Path $repoRootResolved "extensions\vibedeck-bridge\node_modules\.bin\vsce.cmd"
$vsceOk = Add-FileCheck -Results $results -Category "vsce" -Path $vsceCmd -Hint "cd .\extensions\vibedeck-bridge ; npm install"

$bootstrapReady = ($nodePath -and $npmPath -and $extensionDistOk)
$realSmokeReady = ($gitPath -and $goPath -and ($cursorAgentNative -or ($wslCursorAgent -and $wslCursorAgent.resolved)))
$guiSmokeReady = ($realSmokeReady -and $extensionDistOk -and ($cursorCli -or $codeCli))
$vsixReady = ($extensionDistOk -and $vsceOk)

$profiles = @(
    [PSCustomObject]@{ profile = "기본 bootstrap smoke"; ready = $bootstrapReady; command = "npm --prefix .\\extensions\\vibedeck-bridge run smoke:bootstrap" },
    [PSCustomObject]@{ profile = "실제 cursor-agent smoke"; ready = $realSmokeReady; command = "powershell -ExecutionPolicy Bypass -File .\scripts\cursor_agent_smoke.ps1" },
    [PSCustomObject]@{ profile = "GUI extension smoke"; ready = $guiSmokeReady; command = "powershell -ExecutionPolicy Bypass -File .\scripts\gui_extension_host_smoke.ps1 -Editor cursor -UseWslCursorAgent true -CursorAgentBin /home/<user>/.local/bin/cursor-agent -CursorAgentWslDistro Ubuntu" },
    [PSCustomObject]@{ profile = "VSIX 패키징"; ready = $vsixReady; command = "powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1" }
)

$failCount = @($results | Where-Object { $_.status -eq "FAIL" }).Count
$warnCount = @($results | Where-Object { $_.status -eq "WARN" }).Count

Write-Host ""
Write-Host "== VibeDeck Doctor =="
$results | Format-Table -AutoSize

Write-Host ""
Write-Host "== 실행 가능 프로필 =="
$profiles | Select-Object profile, ready, command | Format-Table -AutoSize

$hints = @($results | Where-Object { -not [string]::IsNullOrWhiteSpace($_.hint) } | Select-Object -ExpandProperty hint -Unique)
if ($hints.Count -gt 0) {
    Write-Host ""
    Write-Host "== 권장 조치 =="
    foreach ($hint in $hints) {
        Write-Host "- $hint"
    }
}

$summary = [PSCustomObject]@{
    repoRoot = $repoRootResolved
    failCount = $failCount
    warnCount = $warnCount
    checks = $results
    profiles = $profiles
}

if ($FailOnError -and $failCount -gt 0) {
    throw "doctor check failed: $failCount"
}

$summary
