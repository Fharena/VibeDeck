# VibeDeck

VibeDeck은 로컬 AI 코딩 세션을 모바일과 IDE에서 함께 이어서 쓰기 위한 모바일 우선 컨트롤 레이어입니다.
코드 실행은 PC에서 수행하고, 모바일은 다음 루프를 담당합니다.

- 프롬프트 제출
- 패치/디프 검토
- 전체/부분 적용
- 테스트/빌드 실행
- 결과 확인 및 재지시

현재 저장소는 원격 제어 MVP를 넘어서, 공유 스레드 기반 모바일 흐름과 실제 Cursor GUI extension host smoke proof까지 확보했습니다.

- Go 기반 Signaling/Relay 서버 골격
- Go 기반 PC Agent 오케스트레이션 + Cursor 브리지 stdio/TCP RPC 연결
- TypeScript 기반 Cursor 브리지 계약/stdio server/socket server/extension runtime helper
- VS Code/Cursor localhost bridge extension package(`extensions/vibedeck-bridge`)
- WebRTC Peer + SignalBridge + Agent P2P 제어 경로(Envelope) 라우팅 + ACK retry/backoff
- Flutter 모바일 앱(shared session shell) + 공유 세션 타임라인 + direct signaling/WebRTC control path + ACK observability/debug surface
- 공통 프로토콜/데이터 모델 문서
- ACK runtime metrics endpoint(`/v1/agent/runtime/metrics`) + Prometheus scrape endpoint(`/metrics`) + Status 화면 관측 카드

## 디렉터리 구조

```text
cmd/
  agent/      # PC 에이전트 실행 진입점
  signaling/  # 페어링 + 시그널링 서버 진입점
  relay/      # 릴레이 폴백 서버 진입점
internal/
  agent/      # 잡 오케스트레이션, 실행 프로파일, p2p 세션
  relay/      # 릴레이 라우팅, 백프레셔 정책
  signaling/  # 페어링/세션 시그널링 모델
  protocol/   # 공통 Envelope, 메시지 타입
  runtime/    # ACK 추적, 연결 상태머신
  webrtc/     # peer + signaling bridge 스켈레톤
adapters/
  cursor-bridge/ # TypeScript 브리지 계약 + stdio/tcp bridge 서버 + extension runtime helper
extensions/
  vibedeck-bridge/ # VS Code/Cursor localhost bridge extension package
mobile/
  flutter_app/   # Flutter Prompt/Review/Status 화면 베이스라인
shared/
  protocol/   # JSON Schema, 메시지 레퍼런스
docs/
  implementation-plan.md
  architecture.md
  critical-issues.md
  troubleshooting-study.md
```

## MVP 우선순위

1. 연결 안정성(P2P 우선, Relay 폴백)
2. Prompt -> Patch -> Apply 루프
3. Run -> Result 루프
4. 리뷰 UX 명확성
5. 어댑터 중심 확장성

## 현재 실사용 범위

- 모바일 앱과 agent가 같은 스레드 히스토리를 공유
- agent 재시작 뒤에도 shared thread history가 디스크에서 복원됨
- Cursor extension 안에서 shared thread panel을 열어 같은 스레드/패치/실행 결과를 확인하고 프롬프트/적용/실행까지 제어 가능
- `PROMPT_SUBMIT -> PATCH_READY -> PATCH_APPLY -> RUN_PROFILE` 흐름을 모바일과 IDE 양쪽에서 확인/승인 가능
- 실행 프로파일 목록은 agent가 동적으로 제공
- 실행 결과는 status/summary/top errors뿐 아니라 전체 출력까지 모바일 검토 화면에 표시
- 모바일 상태 화면이 `GET /v1/agent/bootstrap`로 agent/signaling/workspace/current thread/recent threads를 자동 조회해 기본 연결값을 채움
- Cursor extension이 `VibeDeck: Open Mobile Bootstrap` / `VibeDeck: Copy Mobile Bootstrap Link`로 LAN 기준 QR/deep link(`vibedeck://bootstrap`)를 제공
- 모바일 앱이 deep link를 수신하면 agent/signaling/thread를 즉시 적용하고, 최근 연결 host도 함께 기억함
- 모바일 메인 셸이 Cursor 계열 dark session feed로 정리되어 요청 작성, 작업 로그, 패치/실행 요약, 세션 복구 상태를 한 화면 흐름으로 확인 가능
- 메인 셸의 workstream 액션에서 터미널 출력과 파일 포커스 시트를 바로 열어 실행 상태와 변경 파일을 확인 가능

## 세팅 방향

- 모바일 앱은 `GET /v1/agent/bootstrap`, 최근 host 기억, `vibedeck://bootstrap` deep link를 사용해 URL 입력을 거의 제거하는 방향으로 유지
- IDE 쪽은 extension 또는 배포 가능한 패키지로 최소 세팅만 요구하는 방향으로 유지
- 현재는 `extensions/vibedeck-bridge` VSIX, extension local agent 자동 부트스트랩, shared thread history 영속화, 모바일 bootstrap 자동 세팅 v2(QR/deep link), mobile/cursor live session sync, 모바일 단일 shared session 셸, 터미널/파일 포커스 시트까지 갖춘 상태입니다. 다음 큰 단계는 live sync 정확도와 stalled recovery, Windows rough edge 마감입니다.

## 로컬 개발

### 요구사항

- Go 1.23+
- Node.js 22+
- Flutter 3.22+
- Cursor 또는 VS Code(실제 extension host bridge를 확인할 때)
- Cursor CLI (cursor-agent, 실제 AI patch 생성을 확인할 때, optional)

### 5분 점검

환경이 맞는지 먼저 확인하려면 아래 명령을 실행합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\vibedeck_doctor.ps1
```

doctor는 `git/go/node/npm/flutter/editor CLI/cursor-agent/build 산출물/vsce`를 점검하고, 현재 PC에서 가능한 실행 프로필을 바로 보여줍니다.

### 10분 온보딩

실사용 설치 절차는 별도 문서로 정리했습니다.

- 온보딩 가이드: [docs/onboarding.md](./docs/onboarding.md)

### 빠른 실행

기본값은 fixture child-process bridge입니다.

```bash
npm --prefix adapters/cursor-bridge install
npm --prefix adapters/cursor-bridge run build
go run ./cmd/signaling
go run ./cmd/relay
go run ./cmd/agent
```

`cmd/agent`는 기본적으로 `adapters/cursor-bridge/dist/fixtureBridgeMain.js`를 child process로 실행합니다.
`WORKSPACE_ADAPTER_MODE=cursor_agent_cli`를 설정하면 bridge 대신 공식 `cursor-agent` CLI를 임시 git worktree에서 실행하고, 생성된 diff만 review/apply 흐름으로 반환합니다.
bridge 명령을 교체할 때는 다음 환경변수를 사용합니다.

- `CURSOR_BRIDGE_BIN`: 기본값 `node`
- `CURSOR_BRIDGE_ENTRY`: 기본값 `adapters/cursor-bridge/dist/fixtureBridgeMain.js`
- `CURSOR_BRIDGE_ARGS_JSON`: 실행 인자를 JSON 배열로 직접 지정할 때 사용
- `CURSOR_BRIDGE_WORKDIR`: bridge 프로세스 working directory override
- `CURSOR_BRIDGE_CALL_TIMEOUT`: RPC 호출 타임아웃, 기본값 `10s`
- `CURSOR_BRIDGE_STARTUP_TIMEOUT`: bridge 초기 handshake 타임아웃, 기본값 `5s`

### Cursor Agent CLI 대체 경로

bridge command 매핑 대신 공식 Cursor CLI를 쓰려면 다음 환경변수를 사용합니다.

```powershell
$env:WORKSPACE_ADAPTER_MODE = "cursor_agent_cli"
$env:CURSOR_AGENT_BIN = "cursor-agent"
go run ./cmd/agent
```

Windows에서 네이티브 `cursor-agent`가 없고 WSL에만 설치돼 있다면 아래처럼 실행할 수 있습니다.

```powershell
$env:WORKSPACE_ADAPTER_MODE = "cursor_agent_cli"
$env:CURSOR_AGENT_USE_WSL = "true"
$env:CURSOR_AGENT_WSL_DISTRO = "Ubuntu" # optional, 비우면 agent가 설치된 distro를 자동 탐지
go run ./cmd/agent
```

기본 동작:

- 네이티브 `cursor-agent` 또는 WSL distro 안의 `~/.local/bin/cursor-agent`/`~/.local/bin/agent`를 탐지
- 감지한 CLI를 임시 git worktree에서 실행
- 현재 workspace의 tracked 변경, untracked 파일, 그리고 명시 allowlist와 일치하는 ignored 파일만 temp worktree에 동기화
- agent가 만든 diff만 `PATCH_READY`로 반환
- review 승인 후 실제 workspace에는 `git apply`로 반영

추가 환경변수:

- `CURSOR_AGENT_BIN`: 기본값 `cursor-agent`, WSL 모드에서는 기본값 `wsl.exe`
- `CURSOR_AGENT_ARGS_JSON`: CLI 인자를 JSON 배열로 직접 지정할 때 사용, 기본값은 `["--print","--output-format","json"]`이고 `--trust`, `--model <값>`이 없으면 agent가 자동 주입
- `CURSOR_AGENT_TRUST_WORKSPACE`: 기본값 `true`, CLI 인자에 `--trust`가 없으면 자동 추가
- `CURSOR_AGENT_MODEL`: 기본값 `auto`, CLI 인자에 model이 없으면 `--model <값>` 자동 추가
- `CURSOR_AGENT_ENV_JSON`: CLI 실행 환경변수를 JSON 배열로 지정할 때 사용
- `CURSOR_AGENT_SYNC_IGNORED_JSON`: temp worktree snapshot에 복사할 ignored 파일 pathspec allowlist를 JSON 배열로 지정할 때 사용
- `CURSOR_AGENT_USE_WSL`: Windows에서 WSL 안의 Cursor CLI를 사용할 때 `true`
- `CURSOR_AGENT_WSL_DISTRO`: 특정 WSL distro를 강제로 지정할 때 사용, 비우면 자동 탐지
- `CURSOR_AGENT_WORKSPACE_ROOT`: workspace root override
- `CURSOR_AGENT_TEMP_ROOT`: 임시 worktree parent directory override
- `CURSOR_AGENT_PROMPT_TIMEOUT`: 프롬프트 실행 타임아웃, 기본값 `2m`
- `CURSOR_AGENT_RUN_TIMEOUT`: run profile 실행 타임아웃, 기본값 `2m`

### Cursor Agent Smoke Script

네이티브 `cursor-agent` 또는 WSL에 설치된 Cursor CLI가 있으면 아래 스크립트로 temp repo 기준 smoke 테스트를 바로 돌릴 수 있습니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cursor_agent_smoke.ps1
```

스크립트가 하는 일:

- temp git repo 생성
- `WORKSPACE_ADAPTER_MODE=cursor_agent_cli`로 agent 실행
- `GET /v1/agent/runtime/adapter`로 adapter/binary 상태 확인
- `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE(smoke)` 순서 실행
- 실제 변경이 temp repo 파일에 반영됐는지 확인

현재 스크립트는 네이티브 `cursor-agent`가 없어도 WSL 안의 `cursor-agent`/`agent`를 자동 탐지합니다. 이 PC에서는 `cursor-agent login` 완료 후 실제 `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE` smoke가 통과했습니다. headless 실행 안정성을 위해 agent는 `--print`, `--output-format json`, `--trust`, `--model auto`를 기본 주입하고, HTTP/P2P control 경로는 message type별 timeout(`PROMPT_SUBMIT`/`RUN_PROFILE`: 5분, `PATCH_APPLY`: 30초)을 사용합니다.
shared thread history는 기본적으로 디스크에 영속화됩니다.

- 기본 경로: `%APPDATA%\VibeDeck\thread-store.json`
- override: `THREAD_STORE_FILE=<absolute path>`
- 현재 범위: thread summary/event history 복원
- 현재 제한: 진행 중 task/job 자체는 adapter 내부 상태까지 저장하지 않으므로, 재시작 뒤에는 과거 history는 보이지만 미완료 patch/apply/run을 이어서 재개하지는 못합니다.

### 모바일 Bootstrap API

모바일 앱은 `GET /v1/agent/bootstrap`를 먼저 호출해 agent/signaling/workspace/adapter/current thread/recent threads 기본값을 읽고, extension이 생성한 `vibedeck://bootstrap` deep link를 수신하면 해당 값을 바로 적용합니다.

```json
{
  "agentBaseUrl": "http://192.168.0.24:8080",
  "signalingBaseUrl": "http://192.168.0.24:8081",
  "workspaceRoot": "C:\\repo\\workspace",
  "adapter": {
    "name": "cursor-agent-cli",
    "mode": "cursor_agent_cli",
    "provider": "cursor",
    "ready": true
  },
  "currentThreadId": "thread-123",
  "recentThreads": []
}
```

공개 URL이 localhost가 아니어야 하면 아래 환경변수로 override할 수 있습니다.

- `AGENT_PUBLIC_BASE_URL`
- `SIGNALING_PUBLIC_BASE_URL`

### 운영 메트릭 Export

- 모바일 앱/디버그 JSON: `GET /v1/agent/runtime/metrics`
- 외부 대시보드 scrape: `GET /metrics` (Prometheus text exposition)

```powershell
Invoke-WebRequest http://127.0.0.1:8080/metrics | Select-Object -ExpandProperty Content
```

`/metrics`는 ACK queue depth/RTT, control request result(success/error/timeout), handler latency(last/avg/max)를 Prometheus/Grafana 같은 외부 수집기에 바로 노출합니다.

### 실제 extension host 연결

Cursor/VS Code 안에서 localhost TCP bridge와 local agent를 함께 올리려면 다음 순서를 사용합니다.

```bash
npm --prefix adapters/cursor-bridge install
npm --prefix adapters/cursor-bridge run build
npm --prefix extensions/vibedeck-bridge install
npm --prefix extensions/vibedeck-bridge run build
```

1. `extensions/vibedeck-bridge`를 Cursor/VS Code extension으로 로드
2. extension 설정에서 `vibedeckBridge.mode=mock` 또는 `command` 지정
3. command mode를 쓸 때는 기본값 `vibedeckBridge.commandProvider=builtin_cursor_agent` 그대로 두면 extension이 기본 `vibedeck.*` 명령을 직접 등록
4. Windows에서 Cursor CLI가 WSL에만 있으면 `vibedeckBridge.cursorAgent.useWsl=true`, 필요하면 `vibedeckBridge.cursorAgent.wslDistro=Ubuntu` 설정
5. `.env.local` 같은 ignored 파일이 temp worktree snapshot에 필요하면 `vibedeckBridge.cursorAgent.syncIgnoredPaths=[".env.local"]`처럼 명시 allowlist로만 추가
6. local agent 자동 부트스트랩은 기본값 `vibedeckBridge.agent.autoStart=true`, `vibedeckBridge.agent.launchMode=auto`로 켜집니다.
7. 저장소 checkout에서 extension을 직접 로드한 상태라면 `launchMode=auto`가 repo 레이아웃을 감지해 `go run ./cmd/agent` 경로를 내부에서 올립니다.
8. 별도 binary를 쓸 때는 `vibedeckBridge.agent.launchMode=binary`, `vibedeckBridge.agent.binaryPath=<agent executable>`만 지정하면 됩니다.
9. `VibeDeck: Open Shared Threads`로 IDE 안에서 shared thread panel 열기
10. 수동 fallback이 필요할 때만 `VibeDeck: Copy Agent Env`로 bridge 주소를 복사해 외부 agent에 전달

자동 부트스트랩에서 쓰는 핵심 설정:

- `vibedeckBridge.agent.host`, `vibedeckBridge.agent.port`: local agent listen 주소
- `vibedeckBridge.agent.repoRoot`: `go_run`/`binary` 모드의 실행 루트
- `vibedeckBridge.agent.runProfileFile`: 기본값은 `repoRoot/configs/run-profiles.json`
- `vibedeckBridge.agentBaseUrl`: 비워두면 panel이 `agent.host/port`를 자동 사용

수동 fallback 예시:

```powershell
$env:CURSOR_BRIDGE_TCP_ADDR = "127.0.0.1:7797"
$env:CURSOR_BRIDGE_TCP_DIAL_TIMEOUT = "3s"
go run ./cmd/agent
```

mock mode smoke는 아래 스크립트로 바로 검증할 수 있습니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\extension_host_smoke.ps1 -BridgeAddress "127.0.0.1:7797"
```

command mode built-in provider smoke는 세 단계로 검증합니다.

```powershell
npm --prefix extensions/vibedeck-bridge run smoke:provider
npm --prefix extensions/vibedeck-bridge run smoke:extension
npm --prefix extensions/vibedeck-bridge run smoke:panel
npm --prefix extensions/vibedeck-bridge run smoke:bootstrap
npm --prefix extensions/vibedeck-bridge run smoke:mobile-bootstrap
```
- `smoke:provider`는 built-in provider와 command bridge의 low-level 경로를 검증합니다.
- `smoke:extension`은 `extension.ts -> bridgeExtensionController -> built-in provider -> TCP bridge` 활성화 경로를 검증합니다.
- `smoke:panel`은 `openThreadPanel -> agent HTTP -> shared thread refresh/action` 경로를 검증합니다.
- `smoke:bootstrap`은 extension이 local agent lifecycle과 panel agent URL을 같이 관리하는 자동 부트스트랩 경로를 검증합니다.
- `smoke:mobile-bootstrap`은 extension이 LAN host를 고르고 QR/deep link를 생성해 모바일 bootstrap 정보를 노출하는 경로를 검증합니다.
- `VibeDeck: Copy Smoke Command`는 mock mode에서는 `extension_host_smoke.ps1`, built-in command mode에서는 `npm --prefix extensions/vibedeck-bridge run smoke:extension` 명령을 복사합니다.

실제 GUI extension host + built-in provider smoke는 아래 스크립트로 검증합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\gui_extension_host_smoke.ps1 -Editor cursor -UseWslCursorAgent true -CursorAgentBin /home/fharena/.local/bin/cursor-agent -CursorAgentWslDistro Ubuntu
```

현재 상태:

- `mock` 모드는 실제 extension host 안에서 등록된 mock command를 통해 `Prompt -> Patch -> Apply -> Run` smoke를 검증합니다.
- `command` 모드의 기본값은 built-in `cursor-agent` provider이며, 별도 외부 command ID 없이도 기본 `vibedeck.*` 매핑으로 시작할 수 있습니다.
- extension은 bridge와 local agent를 함께 관리할 수 있고, panel은 기본적으로 `agent.host/port`를 따라갑니다.
- `smoke:extension`으로 저장소 안의 activation path를 자동 검증하고, `smoke:bootstrap`으로 local agent 자동 부트스트랩 경로를, `smoke:mobile-bootstrap`으로 QR/deep link 경로를 검증합니다.
- `gui_extension_host_smoke.ps1`로 실제 Cursor GUI extension host + real `cursor-agent` 경로까지 검증했습니다.
- built-in provider와 Go `cursor_agent_cli` adapter는 둘 다 ignored 파일을 기본 비동기화로 두고, 명시 allowlist와 일치하는 항목만 temp worktree snapshot에 복사합니다.
- 외부 대시보드용 Prometheus scrape endpoint(`/metrics`)와 control handler latency/timeout 메트릭을 제공합니다.
- 현재 남은 큰 과제는 session UX foundation(reasoning summary/plan trace/tool activity/terminal/file tree), Cursor panel redesign, 모바일 dark session shell polish, Cursor 세션/로그 가시성 및 stalled recovery, Windows cleanup warning 정리, timeout budget 운영 설정 외부화, 설치 산출물 릴리스 자동화입니다.
- Windows에서는 smoke 종료 직후 `agent.exe` 잠금 때문에 temp root cleanup warning이 남을 수 있습니다.
- Cursor 외 provider 확장은 Cursor 기반 unified session 흐름을 충분히 완성한 뒤 진행할 계획입니다.

### VSIX 패키징

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1 -InstallDependencies
```

이 스크립트는 packaging 전용 temp staging 디렉터리에서 runtime 파일만 묶어서 VSIX를 생성합니다.

기본 산출물 경로:

- `artifacts\vsix\vibedeck-bridge-<version>.vsix`

추가 옵션:

- `-RunSmoke`: package 전 `smoke:provider`, `smoke:extension`, `smoke:panel`, `smoke:bootstrap`, `smoke:mobile-bootstrap` 같이 실행
- `-SkipCheck`: `npm run check` 생략

생성 후 설치 예시:

```powershell
cursor --install-extension .\artifacts\vsix\vibedeck-bridge-0.1.0.vsix --force
```
## 문서

- 구현 계획: [docs/implementation-plan.md](./docs/implementation-plan.md)
- 아키텍처: [docs/architecture.md](./docs/architecture.md)
- Unified Session 계획: [docs/unified-session.md](./docs/unified-session.md)
- Session UX 기준: [docs/session-ux.md](./docs/session-ux.md)
- 크리티컬 이슈 로그: [docs/critical-issues.md](./docs/critical-issues.md)
- 해결 학습 가이드: [docs/troubleshooting-study.md](./docs/troubleshooting-study.md)
- 온보딩 가이드: [docs/onboarding.md](./docs/onboarding.md)
