# VibeDeck Bridge Extension

이 패키지는 Cursor/VS Code extension host 안에서 localhost TCP bridge를 열고, 필요하면 local agent까지 같이 올려 VibeDeck이 editor 프로세스에 붙을 수 있게 합니다.

## 모드

- `mock`: 저장소의 `MockCursorBridge`를 사용해 bridge/agent 흐름을 빠르게 검증합니다.
- `command`: command registry를 통해 `submitTask/getPatch/applyPatch/runProfile/getRunResult`를 위임합니다.

## mock mode

1. 이 extension을 Cursor/VS Code에 로드
2. 설정에서 `vibedeckBridge.mode=mock`
3. bridge 시작 확인
4. `VibeDeck: Copy Smoke Command`를 실행하거나 아래 명령으로 mock smoke 수행

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extension_host_smoke.ps1 -BridgeAddress "127.0.0.1:7797"
```

이 스크립트는 bridge preflight 후 agent를 띄워 `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE` 전체 흐름을 검증합니다.
Windows에서는 종료 직후 `agent.exe` 잠금으로 temp root cleanup warning이 남을 수 있습니다.

## VSIX 패키징/설치

로컬 설치용 `.vsix`는 루트 스크립트로 만드는 편이 가장 안전합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1 -InstallDependencies
```

직접 extension 폴더에서 패키징하려면:

```powershell
npm install
npm run package:vsix -- --out ..\..\artifacts\vsix\vibedeck-bridge-0.1.0.vsix
```

설치 예시:

```powershell
cursor --install-extension .\artifacts\vsix\vibedeck-bridge-0.1.0.vsix --force
```

패키징 전 빠른 점검:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\vibedeck_doctor.ps1
```

## shared thread panel

`VibeDeck: Open Shared Threads` 명령은 agent의 shared thread API를 읽는 IDE 사이드바 뷰를 엽니다. 사이드바 뷰를 열 수 없는 환경에서는 에디터 웹뷰로 fallback 됩니다.
이 뷰는 모바일 앱과 같은 thread/event 모델을 사용하므로, 같은 스레드 타임라인과 patch/run 결과를 IDE 안에서도 그대로 이어서 볼 수 있습니다.
패치가 없으면 적용 불가 사유를 바로 보여주고, 실행 결과 카드에는 현재 job 기준 파일 목록을 raw 출력보다 먼저 노출합니다. agent가 HTTP 400과 함께 `CMD_ACK false`를 돌려줘도 해당 사유를 패널에 복구해 표시합니다.

주요 설정:

- `vibedeckBridge.agent.host`: 기본값 `127.0.0.1`
- `vibedeckBridge.agent.port`: 기본값 `8080`
- `vibedeckBridge.agentBaseUrl`: 기본값 빈 값, 비우면 `agent.host/port` 사용
- `vibedeckBridge.panelAutoRefreshMs`: 기본값 `4000`

panel smoke:

```powershell
npm run smoke:panel
```

이 smoke는 다음을 검증합니다.

- panel 명령 등록과 open/reveal 경로
- agent HTTP thread 조회/refresh
- panel에서 `PROMPT_SUBMIT`, `PATCH_APPLY`, `RUN_PROFILE`, `OPEN_LOCATION` 제어

## 모바일 bootstrap

- `VibeDeck: Open Mobile Bootstrap`: 모바일용 QR/deep link 패널을 엽니다.
- `VibeDeck: Copy Mobile Bootstrap Link`: `vibedeck://bootstrap?agent=...&signaling=...&thread=...` 링크를 클립보드에 복사합니다.
- `vibedeckBridge.mobileBootstrap.hostOverride`: QR/deep link에 넣을 host를 강제로 지정합니다. 비우면 private IPv4를 자동 선택합니다.
- `vibedeckBridge.mobileBootstrap.scheme`: 기본값 `vibedeck`

모바일 bootstrap smoke:

```powershell
npm run smoke:mobile-bootstrap
```

이 smoke는 다음을 검증합니다.

- agent bootstrap API를 읽어 current thread/workspace/provider를 노출하는지
- localhost agent/signaling 주소를 LAN 주소로 재작성하는지
- QR SVG와 deep link가 같이 생성되는지

## local agent 자동 부트스트랩

기본값은 `vibedeckBridge.agent.autoStart=true`, `vibedeckBridge.agent.launchMode=auto` 입니다.
이 조합이면 extension이 bridge를 띄운 뒤 local agent도 같이 올리고, shared thread panel은 같은 host/port를 자동으로 사용합니다.

지원 launch mode:

- `auto`: extension 위치에서 VibeDeck repo 구조를 감지하면 `go_run`, 아니면 `manual`
- `go_run`: `go run ./cmd/agent`
- `binary`: 지정한 실행 파일을 직접 실행
- `manual`: extension이 agent를 띄우지 않음

주요 설정:

- `vibedeckBridge.agent.repoRoot`: `go_run`/`binary` 실행 루트
- `vibedeckBridge.agent.goBin`: `go_run` 모드의 Go 실행 파일
- `vibedeckBridge.agent.binaryPath`: `binary` 모드의 agent 실행 파일 경로
- `vibedeckBridge.agent.args`: 추가 실행 인자
- `vibedeckBridge.agent.extraEnv`: 추가 환경변수(`KEY=VALUE`)
- `vibedeckBridge.agent.runProfileFile`: 비우면 `repoRoot/configs/run-profiles.json`
- `vibedeckBridge.agent.signalingBaseUrl`: agent에 전달할 signaling base URL
- `vibedeckBridge.agent.readyTimeoutMs`: `healthz` ready 대기 시간

명령:

- `VibeDeck: Start Local Agent`
- `VibeDeck: Stop Local Agent`
- `VibeDeck: Restart Local Agent`
- `VibeDeck: Show Bridge Status`
- `VibeDeck: Open Mobile Bootstrap`
- `VibeDeck: Copy Mobile Bootstrap Link`

자동 부트스트랩 smoke:

```powershell
npm run smoke:bootstrap
```

이 smoke는 다음을 검증합니다.

- extension activation 후 bridge + local agent 상태 반영
- status bar / show status가 agent 상태를 같이 노출하는지
- shared thread panel이 자동으로 local agent URL을 따라가는지

## command mode

기본값은 `vibedeckBridge.commandProvider=builtin_cursor_agent` 입니다.
이 설정이면 extension이 내부에서 기본 `vibedeck.*` command를 직접 등록하므로, 별도 Cursor command ID를 찾지 않아도 command mode가 바로 뜹니다.

### built-in provider 설정

- `vibedeckBridge.cursorAgent.bin`: 기본값 `cursor-agent`
- `vibedeckBridge.cursorAgent.gitBin`: 기본값 `git`
- `vibedeckBridge.cursorAgent.workspaceRoot`: 비워두면 현재 열려 있는 첫 workspace folder 사용
- `vibedeckBridge.cursorAgent.useWsl`: Windows에서 WSL로 cursor-agent 실행
- `vibedeckBridge.cursorAgent.wslDistro`: optional
- `vibedeckBridge.cursorAgent.extraArgs`: 추가 CLI 인자
- `vibedeckBridge.cursorAgent.extraEnv`: 추가 환경변수(`KEY=VALUE`)
- `vibedeckBridge.cursorAgent.syncIgnoredPaths`: temp worktree snapshot에 복사할 ignored 파일 pathspec allowlist
- `vibedeckBridge.cursorAgent.trustWorkspace`: 기본값 `true`
- `vibedeckBridge.cursorAgent.model`: 기본값 `auto`

### 시작 전 검증

- `VibeDeck: Validate Commands` 명령으로 현재 extension host에 등록된 command ID를 검사할 수 있습니다.
- built-in provider가 켜져 있으면 기본 `vibedeck.*` 명령이 자동 등록되므로, command mode는 기본 설정만으로 통과해야 합니다.
- ignored 파일은 기본으로 복사하지 않으며, `.env.local` 같은 파일이 필요할 때만 `vibedeckBridge.cursorAgent.syncIgnoredPaths`에 명시합니다.
- `openLocation/getWorkspaceMetadata/getLatestTerminalError`는 optional이라 누락 시 경고만 표시합니다.

### Agent 연결 fallback

자동 부트스트랩을 쓰지 않을 때만 아래 수동 연결을 사용합니다.

- `VibeDeck: Copy Agent Env` 명령은 현재 bridge 주소 기준으로 PowerShell 환경변수 문자열을 클립보드에 복사합니다.
- built-in provider일 때 `VibeDeck: Copy Smoke Command`는 extension 활성화 smoke 명령을 복사합니다.

```powershell
$env:CURSOR_BRIDGE_TCP_ADDR = "127.0.0.1:7797"
go run ./cmd/agent
```

### 로컬 smoke

low-level provider smoke:

```powershell
npm run smoke:provider
```

이 smoke는 다음을 검증합니다.

- built-in command provider가 기본 `vibedeck.*` 명령을 등록하는지
- command bridge가 command registry를 통해 `submitTask/getPatch/applyPatch/runProfile/getRunResult`를 호출하는지
- ignored allowlist에 포함한 파일이 temp worktree snapshot으로만 제한적으로 복사되는지
- fake cursor-agent가 만든 diff가 patch bundle/apply/run result로 정상 전달되는지

extension activation path smoke:

```powershell
npm run smoke:extension
```

이 smoke는 다음을 추가로 검증합니다.

- `extension.ts -> bridgeExtensionController -> built-in provider` 활성화 경로
- status bar/clipboard/validate command 흐름
- TCP bridge가 실제로 열리고 JSON-RPC로 왕복되는지

### external provider

`vibedeckBridge.commandProvider=external`로 바꾸면 extension은 command를 등록하지 않고, 이미 extension host에 존재하는 command ID만 사용합니다.
이 경우 `vibedeckBridge.commands.*`에 원하는 command ID를 직접 매핑해야 합니다.
