# 아키텍처

## 시스템 구성 요소

- 모바일 앱(Flutter): 대화/검토/상태 화면 제공, 공유 스레드 타임라인 표시
- PC 에이전트(Go): 잡 오케스트레이션, 공유 스레드 저장소, 패치 수명주기, 실행 프로파일, 전송 바인딩, IDE provider 연결 관리
- IDE 브리지(TypeScript): IDE extension host 추상화, extension runtime helper, stdio/TCP RPC 서버, 컨텍스트 조회, 패치 적용, 파일/라인 열기
- VibeDeck Bridge Extension(VS Code/Cursor): localhost TCP bridge package, mock mode와 built-in/external command provider 기반 command mode 제공, shared thread panel과 local agent 자동 부트스트랩 제공
- Signaling 서버(Go): 페어링 및 WebRTC 시그널링 부트스트랩
- Relay 서버(Go): 폴백 이벤트 라우팅 + 백프레셔 정책

## 설계 원칙

- Cursor는 첫 번째 실사용 provider일 뿐, 제품 경계가 아니다.
- agent 코어는 특정 IDE 채팅/패널 구현에 의존하지 않고 공유 스레드/패치/실행 모델만 안다.
- 모바일과 IDE는 동일한 thread/event 모델을 공유하고, 각 클라이언트는 자신의 UI로만 렌더링한다.
- IDE 패널은 agent HTTP API를 직접 읽는 provider-agnostic 레이어로 두어, Cursor 이후 다른 AI IDE host에도 같은 panel data layer를 재사용한다.
- 온보딩은 extension/패키지 기반 최소 세팅을 목표로 한다. 수동 환경변수 입력은 점진적으로 축소한다.

## Flutter UI 베이스라인 (`mobile/flutter_app`)

- `PromptScreen`: 공유 스레드 목록, 타임라인, 자연어 프롬프트 입력, context 옵션 토글
- `ReviewScreen`: 파일/헝크 목록 검토와 전체/선택 적용 액션, 동적 run profile 실행, 전체 출력 표시
- `StatusScreen`: 연결 상태, workspace adapter/runtime, pending ACK, ACK observability(RTT/queue depth), 히스토리 표시
- `StatusScreen`에서 direct signaling + WebRTC 상태(ws/peer/datachannel) 제어/로그 확인 가능

## Flutter API/전송 레이어 (`mobile/flutter_app/lib/state/app_controller.dart`)

- `AppController`가 화면 상태와 제어 경로(HTTP/DIRECT) 라우팅을 단일 진입점으로 관리
- `AgentApi`(`mobile/flutter_app/lib/services/agent_api.dart`)가 HTTP 요청/오류 처리 담당
- `GET /v1/agent/bootstrap`가 agent/signaling/workspace/adapter/current thread/recent threads 기본값을 내려주고, `AppSettingsStore`(`mobile/flutter_app/lib/services/app_settings_store.dart`)가 최근 host를 로컬에 저장합니다. 모바일 앱은 `app_links` 기반 `vibedeck://bootstrap` deep link도 받아 bootstrap 값을 즉시 적용합니다.
- `AppController`가 `/v1/agent/runtime/metrics`를 조회해 ACK RTT/queue depth/transport split 메트릭을 상태 화면에 반영하고, 외부 수집기는 `/metrics` Prometheus endpoint를 scrape할 수 있습니다.
- 기본 제어 메시지 전송 흐름:
  1. `PROMPT_SUBMIT` / `PATCH_APPLY` / `RUN_PROFILE` envelope 전송
  2. 응답 envelope 파싱
  3. non-ACK 응답 RID에 대해 `CMD_ACK` 자동 회신
- direct 제어 경로:
  - `SignalingApi`(`mobile/flutter_app/lib/services/signaling_api.dart`)가 pairing claim + WS URI 생성 담당
  - `MobileDirectSignalingSession`(`mobile/flutter_app/lib/services/mobile_direct_signaling_session.dart`)가 signaling WS + `flutter_webrtc` peer를 결합
  - `SIGNAL_OFFER` 수신 시 answer 생성/송신, `SIGNAL_ICE` 적용, local ICE 송신 처리
  - DataChannel open(Control Ready) 시 제어 envelope를 DIRECT 경로로 전송, 실패 시 HTTP 경로로 폴백

## 핵심 인터페이스

### WorkspaceAdapter

에이전트 코어는 IDE 종속 로직을 몰라야 하므로 어댑터 추상화에 의존합니다.

주요 메서드:

- `GetContext`
- `SubmitTask`
- `GetPatch`
- `ApplyPatch`
- `RunProfile`
- `GetRunResult`
- `OpenLocation`

### ThreadStore

- agent 내부의 공유 대화/작업 기록 저장소
- 스레드 요약과 이벤트 타임라인을 분리해 관리
- `prompt_submitted`, `patch_ready`, `patch_applied`, `run_finished` 같은 이벤트를 누적
- 모바일 앱과 향후 IDE 패널이 같은 API로 스레드를 조회

### Unified Session 방향

- 현재 `ThreadStore`는 durable timeline의 기반으로 유지하되, 다음 단계의 canonical object는 `shared session`으로 올린다.
- shared session은 `thread history`만이 아니라 `live presence`, `draft`, `focus`, `current operation state`, `recovery state`를 함께 다룬다.
- durable event와 ephemeral state를 분리해, 기록 복원과 실시간 협업을 각각 최적화한다.
- 모바일과 IDE는 polling 중심이 아니라 session stream을 구독해 같은 세션 변화를 즉시 반영하는 방향으로 확장한다.
- Cursor native chat/session 연동이 가능하면 메타데이터를 묶되, 제품의 소스 오브 트루스는 VibeDeck session으로 유지한다.
- 자세한 단계 계획은 `docs/unified-session.md`를 따른다.

### IDE Provider 확장 전략

- `WorkspaceAdapter`는 IDE 독립 인터페이스다.
- Cursor는 현재 `cursor-agent CLI`와 extension bridge 두 provider로 연결된다.
- 이후 `Codex`, `Claude Code`, `Antigravity` 같은 다른 AI IDE/CLI도 같은 계약을 구현하는 provider 패키지로 확장할 수 있다.
- 확장 단위:
  - agent 쪽 adapter 구현
  - 필요 시 extension/bridge package
  - provider별 setup/packaging 스크립트
- 이 구조를 유지하면 모바일 앱은 IDE가 늘어나도 thread/review/run UI를 바꿀 필요가 없다.

TypeScript 브리지 패키지 구성:

- `CursorExtensionBridge`가 Cursor command 결과를 `WorkspaceAdapter` 계약으로 정규화
- `CursorCommandHost`가 에디터 상태 조회/명령 호출 추상화를 제공
- `createVSCodeCursorHost`가 VS Code/Cursor runtime과 브리지 계약을 연결
- `createCursorExtensionRuntime`이 extension activation 시 command registration과 last-run metadata 추적을 담당
- `serveCursorExtensionBridge`, `serveStdioBridge`, `serveSocketBridge`가 newline-delimited JSON RPC over stdio/TCP 서버를 구성
- extensions/vibedeck-bridge는 mock mode, built-in cursor-agent provider, external command registry 연동, 설정 기반 command ID 매핑, command registry readiness 검증, agent env 복사 명령을 제공하는 설치 가능한 extension package입니다.
- `bridgeExtensionController`는 extension 활성화 로직을 주입 가능한 controller로 분리해 fake host 기반 smoke에서도 같은 시작 경로를 재사용합니다.
- `LocalAgentController`는 bridge 주소를 주입받아 local agent lifecycle(start/stop/restart, ready polling, 상태 요약)을 관리합니다. 현재는 `go_run`/`binary`/`manual` launch mode를 제공하며, provider와 독립된 bootstrap 층으로 유지합니다.
- `threadPanelController`는 agent HTTP API(`runtime/adapter`, `run-profiles`, `threads`, `threads/{id}`, `envelope`)를 읽어 IDE shared thread panel을 구성합니다. panel 로직은 bridge/provider 구현과 분리돼 있어 향후 다른 IDE host에도 그대로 옮길 수 있습니다.
- `ThreadStore`는 기본적으로 디스크 스냅샷을 사용해 shared thread history를 재시작 후에도 복원합니다. 현재는 summary/event history 복원까지만 다루고, adapter 내부 task 재개는 별도 범위로 남겨 둡니다.
- CursorAgentCLIAdapter는 네이티브 cursor-agent 또는 Windows WSL distro 안의 `~/.local/bin/cursor-agent`/`agent`를 감지해 임시 git worktree snapshot에서 실행하고, tracked 변경 + untracked 파일 + 명시 allowlist와 일치하는 ignored 파일만 snapshot에 반영한 뒤 생성된 diff를 PatchReadyPayload로 파싱합니다. 실제 workspace 반영은 review 승인 후 git apply로만 수행합니다.

## 에이전트-어댑터 연결

- `cmd/agent`는 기본적으로 Node child process로 Cursor 브리지를 실행합니다.
- 기본 엔트리포인트는 `adapters/cursor-bridge/dist/fixtureBridgeMain.js`이며, 환경변수로 실제 extension 런처 명령으로 교체할 수 있습니다.
- `CURSOR_BRIDGE_TCP_ADDR`가 설정되면 agent는 child process 대신 기존 localhost TCP bridge에 직접 연결합니다.
- `WORKSPACE_ADAPTER_MODE=cursor_agent_cli`가 설정되면 bridge 대신 `CursorAgentCLIAdapter`를 사용합니다.
- 장기적으로는 `WORKSPACE_ADAPTER_MODE`를 Cursor 전용 값에 고정하지 않고 provider 식별자(`cursor_agent_cli`, `cursor_bridge`, `codex_cli`, `claude_code_cli`, ...)로 확장합니다.
- `CursorBridgeAdapter`(`internal/agent/cursor_bridge_adapter.go`)가 `name`, `capabilities`, `getContext`, `submitTask`, `getPatch`, `applyPatch`, `runProfile`, `getRunResult`, `openLocation` RPC를 담당합니다.
- `CursorAgentCLIAdapter`(`internal/agent/cursor_agent_cli_adapter.go`)는 현재 workspace 상태를 temp worktree에 동기화하고, 네이티브 CLI 또는 WSL distro 내부의 실제 binary를 직접 실행해 diff만 회수합니다. ignored 파일은 기본 제외하고 `CURSOR_AGENT_SYNC_IGNORED_JSON` allowlist와 일치하는 항목만 snapshot에 포함합니다.
- `GET /v1/agent/runtime/adapter`는 현재 adapter 이름, capability, mode, workspace root, binary 경로 같은 smoke 진단 정보를 노출합니다. `/metrics`는 ACK 상태, control result(success/error/timeout), handler latency를 Prometheus text format으로 노출합니다. `cmd/agent`는 기본적으로 `%APPDATA%\\VibeDeck\\thread-store.json`에 thread history를 저장하고, `THREAD_STORE_FILE`로 override할 수 있습니다.
- `scripts/cursor_agent_smoke.ps1`는 temp repo를 만들고 `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE` smoke를 자동 수행합니다. 현재 Windows + WSL + login 완료 환경에서 실제 smoke proof를 확보했습니다.
- `scripts/extension_host_smoke.ps1`는 이미 떠 있는 extension host TCP bridge에 대해 bridge preflight 후 agent mock smoke를 수행합니다.
- `scripts/gui_extension_host_smoke.ps1`는 실제 Cursor GUI extension host를 dev extension 모드로 띄우고, built-in cursor-agent provider 경로를 end-to-end로 검증합니다.
- `scripts/vibedeck_doctor.ps1`는 로컬 요구사항, build 산출물, VSIX 패키징 가능 여부를 점검해 현재 PC에서 가능한 실행 프로필을 요약합니다.
- `scripts/package_vibedeck_bridge.ps1`는 adapter/extension build와 optional smoke 뒤에 temp staging 디렉터리에서 `extensions/vibedeck-bridge`를 `.vsix`로 패키징합니다.
- `npm --prefix extensions/vibedeck-bridge run smoke:provider`는 fake cursor-agent를 사용해 built-in command provider와 command bridge 경로를 결정적으로 검증합니다. ignored allowlist에 포함한 파일이 snapshot에 반영되는지도 함께 확인합니다.
- `npm --prefix extensions/vibedeck-bridge run smoke:extension`는 fake VS Code host + fake cursor-agent를 사용해 `extension.ts -> controller -> TCP bridge -> JSON-RPC` 활성화 경로를 검증합니다. extension 설정의 `vibedeckBridge.cursorAgent.syncIgnoredPaths`도 이 smoke에서 같이 검증합니다.
- 현재 auto-setup 방향은 다음과 같습니다.
  - IDE: extension이 bridge/runtime과 local agent lifecycle을 내부에서 올리고 panel은 `agent.host/port`를 자동 사용
  - 모바일: `GET /v1/agent/bootstrap`, 최근 host 복원, `vibedeck://bootstrap` deep link로 agent/signaling/workspace/thread 기본값을 자동 적용하고, 다음 단계에서 LAN discovery로 수동 입력을 더 줄임
  - 배포: VSIX 또는 향후 npm/installer 형태로 최소 세팅화

## 프로토콜 전략

모든 제어 경로 메시지는 공통 Envelope를 사용합니다.

- HTTP/P2P control handler는 message type별 timeout budget을 사용합니다. 기본값은 `PROMPT_SUBMIT`/`RUN_PROFILE` 5분, `PATCH_APPLY` 30초, 나머지 5초이며, agent는 `CONTROL_TIMEOUT_*` 환경변수로 이를 운영 설정에서 override할 수 있습니다.

- `sid`: session id
- `rid`: request id
- `seq`: sequence number
- `ts`: unix ms timestamp
- `type`: message type
- `payload`: JSON payload

제어 메시지는 반드시 ACK를 보장하고, 터미널 스트림은 best-effort로 처리합니다.

## ACK 추적 정책

- `AckTracker`가 transport별 pending ACK를 추적합니다.
- HTTP 응답은 observe-only pending ACK로 등록하고, 상태/타임아웃 관찰만 수행합니다.
- P2P(DataChannel) 응답은 retryable pending ACK로 등록하고, 원본 envelope와 마지막 전송 시각을 함께 보존합니다.
- `P2PSessionManager`가 backoff 간격으로 재전송을 수행하고, 최대 재시도 초과 또는 재전송 실패 시 세션 상태를 `reconnecting`으로 전이합니다.
- 세션 종료 시 transport별 pending ACK를 정리해 stale 상태를 남기지 않습니다.
- `AckTracker.Metrics()`가 pending count/max queue depth, transport split, ack RTT(last/avg/max), retry/expired/exhausted 집계를 제공하고 HTTP `/v1/agent/runtime/metrics`와 `/metrics`로 노출됩니다.
- `ControlMetrics`가 HTTP/P2P control request count(success/error/timeout)와 handler latency(last/avg/max)를 message type/path별로 집계해 외부 대시보드가 바로 scrape할 수 있게 합니다.

## 시그널링 레이어(WebRTC 연동)

### 메시지 방향성

- PC -> Mobile: `SIGNAL_OFFER`, `SIGNAL_ICE`
- Mobile -> PC: `SIGNAL_ANSWER`, `SIGNAL_ICE`
- Server -> 양쪽: `SIGNAL_READY`

### 검증 정책

- `sid`와 연결된 세션 ID가 반드시 일치해야 함
- `offer/answer/ice` payload 필수 필드 검증
- 역할(role)에 맞지 않는 시그널링 타입은 즉시 거절

### 큐잉 정책

- 상대 피어가 아직 없을 때 시그널링 메시지를 세션 큐에 임시 보관
- 피어가 연결되면 queued signaling 메시지를 먼저 재전달
- 큐 길이는 상한을 두고 초과 시 oldest 항목 제거

## WebRTC 데이터채널 스켈레톤 (`internal/webrtc`)

- `SidePC`는 offerer 역할로 data channel을 선생성
- `SideMobile`는 offer 수신 후 answer 생성
- `SignalBridge`가 signaling envelope과 peer 동작을 결합
- `ControlRouter`가 HTTP/P2P 공통 제어 메시지 해석과 `CMD_ACK` 소거를 담당합니다.
- HTTP server와 `P2PSessionManager`가 transport 특성에 맞는 ACK 등록/재전송 정책을 적용합니다.
