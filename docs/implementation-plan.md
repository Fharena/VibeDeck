# 구현 계획

이 문서는 VibeDeck MVP 구현 순서와 완료 기준을 관리합니다.

## 기본 범위

- 모바일 앱은 AI 코딩 루프를 제어한다.
- PC 에이전트가 실행과 워크스페이스 변경을 담당한다.
- 전송은 P2P 우선, Relay 폴백을 필수로 둔다.
- 핵심 UX는 원격 편집이 아니라 패치/헝크 승인이다.

## 단계별 계획

### Phase 1: 연결 베이스라인

상태: `완료(베이스라인)`

산출물:

- 페어링 코드 생성/클레임 API
- 세션 생명주기 모델
- 시그널링 교환 채널
- Relay 폴백 서버 골격

완료 기준:

- 모바일/PC 피어가 같은 세션에 참여 가능
- 세션 상태가 signaling/relay 모드 전환 가능

### Phase 2: Prompt -> Patch -> Apply

상태: `베이스라인 완료`

산출물:

- 프롬프트 제출 ACK 플로우
- 패치 번들 정규화(`files[]`, `hunks[]`, `summary`)
- 전체/부분 적용 오케스트레이션

완료 기준:

- 모바일 프롬프트 요청이 검토 가능한 패치 번들로 반환
- 패치 적용 상태(`success|partial|conflict|failed`) 반환

### Phase 3: Run -> Result

상태: `베이스라인 완료`

산출물:

- 실행 프로파일 로더(`test_last`, `test_all`, `build`, `dev`)
- PC 에이전트 실행 디스패치
- 상위 에러/요약/excerpt 결과 모델

완료 기준:

- 모바일에서 프로파일 실행 후 요약 결과 수신 가능

### Phase 4: 런타임 신뢰성 강화

상태: `완료`

산출물:

- 연결 상태머신(`internal/runtime/state_manager.go`)
- ACK 추적기(`internal/runtime/ack_tracker.go`)
- HTTP/P2P 공통 envelope 라우팅(`internal/agent/control_router.go`)
- Agent P2P 오케스트레이터(`internal/agent/p2p_session.go`)
- 모바일 상호운용 E2E 테스트(`internal/agent/p2p_session_test.go`)
- Flutter direct signaling + WebRTC peer 제어 경로
- P2P 제어 응답 ACK 재전송/backoff + 재연결 트리거

완료 기준:

- direct 경로에서 `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE` 기본 루프 동작
- non-ACK 응답에 대한 `CMD_ACK` 자동 회신 및 pending ACK 소거 확인 가능
- P2P 경로에서 ACK 미수신 시 backoff 재전송 후 최대 재시도 초과 시 `reconnecting` 전이 가능

### Phase 5: 어댑터/시그널링 고도화

상태: `완료(MVP)`

완료된 산출물:

- TypeScript Cursor 브리지 계약 + Mock 구현
- Cursor Extension API 브리지 패키지 구현
  - Cursor command host 추상화(`adapters/cursor-bridge/src/cursorHost.ts`)
  - `CursorExtensionBridge`로 command 결과를 `WorkspaceAdapter` 계약으로 정규화
  - `createVSCodeCursorHost`로 active editor / dirty files / open location 연결
- Go agent <-> Cursor 브리지 stdio RPC 연결
  - `CursorBridgeAdapter`로 child-process bridge 호출 추가(`internal/agent/cursor_bridge_adapter.go`)
  - `cmd/agent` 기본 런타임을 external bridge 경로로 전환
  - 로컬 bootstrap용 fixture bridge(`adapters/cursor-bridge/src/fixtureBridgeMain.ts`) 추가
- Cursor extension activation runtime helper 추가
  - `createCursorExtensionRuntime`로 command registration + run metadata 추적 추가
  - `serveCursorExtensionBridge`로 extension host에서 stdio bridge 부트스트랩 가능
  - `defaultCursorBridgeCommands`에 workspace metadata / latest error command 기본값 추가
- 시그널링 기본 offer/answer/ice 라우팅
- 시그널링 방향성 검증(PC: OFFER/ICE, Mobile: ANSWER/ICE)
- 상대 미접속 시 시그널 메시지 큐잉/재전달
- `SIGNAL_READY` 이벤트 추가
- Pion 기반 WebRTC peer 스켈레톤(`internal/webrtc`)
- SignalBridge(`internal/webrtc/bridge.go`)로 signaling envelope <-> peer 동작 결합
- Flutter 화면 베이스라인(`mobile/flutter_app`)
- Flutter 화면과 agent API 연동
- Flutter direct 제어 경로 widget/controller integration 테스트
- Agent runtime metrics endpoint(`/v1/agent/runtime/metrics`) + ACK RTT/queue depth 집계
- Flutter Status ACK observability 카드 + 메트릭 widget 테스트

남은 작업:

- 없음(MVP 범위 기준 완료)

## Post-MVP 진행

완료된 항목:

- Go agent external TCP bridge 연결 (`CURSOR_BRIDGE_TCP_ADDR`)
- TypeScript localhost TCP bridge 서버(`serveSocketBridge`)
- TCP fixture launcher(`npm run start:fixture:tcp`)
- VS Code/Cursor localhost bridge extension package(`extensions/vibedeck-bridge`)
- mock mode / command mode 설정 경로
- command mode 시작 전 registry 검증(`vibedeckBridge.validateCommands`)
- agent 연결용 PowerShell env 복사 명령(`vibedeckBridge.copyAgentEnv`)
- extension host mock mode smoke 명령 복사(`vibedeckBridge.copySmokeCommand`)
- status bar / 상태 메시지에 mode, provider, agent env, optional command 누락 경고 반영
- `WORKSPACE_ADAPTER_MODE=cursor_agent_cli` 대체 adapter 경로
- 공식 `cursor-agent` CLI를 임시 git worktree에서 실행해 diff만 회수하는 review-first 오케스트레이션
- fake CLI helper 기반 `SubmitTask/GetPatch/ApplyPatch/RunProfile` 회귀 테스트
- adapter 상태 endpoint(`GET /v1/agent/runtime/adapter`)
- temp repo 기준 실제 smoke 스크립트(`scripts/cursor_agent_smoke.ps1`)
- extension host mock mode 기준 agent smoke 스크립트(`scripts/extension_host_smoke.ps1`)
- Windows WSL distro/binary 자동 탐지 + direct exec smoke 지원
- headless `cursor-agent` 기본 `--trust`, `--model auto` 주입
- 실제 login 완료 환경에서 `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE` smoke proof 확보
- 실제 LLM 지연을 반영한 control envelope timeout 분리(`PROMPT_SUBMIT`/`RUN_PROFILE`: 5분, `PATCH_APPLY`: 30초)
- extension built-in cursor-agent command provider
- `bridgeExtensionController` 분리로 extension 활성화 로직 주입 가능화
- extension activation path smoke(`npm --prefix extensions/vibedeck-bridge run smoke:extension`)
- 기본 `vibedeck.*` command 설정이 `undefined`로 덮이지 않도록 command 설정 병합 버그 수정
- built-in provider가 기본 `vibedeck.*` command를 직접 등록하는 command mode runtime
- fake cursor-agent 기반 command provider smoke(`npm --prefix extensions/vibedeck-bridge run smoke:provider`)
- 실제 Cursor GUI extension host + built-in cursor-agent provider smoke proof(`scripts/gui_extension_host_smoke.ps1`)
- Go `cursor_agent_cli` adapter와 extension built-in provider 공통 ignored 파일 explicit allowlist sync 정책
- Prometheus scrape endpoint(`/metrics`) + control handler latency/timeout metrics
- 온보딩 점검 스크립트(`scripts/vibedeck_doctor.ps1`)
- VSIX 패키징 스크립트(`scripts/package_vibedeck_bridge.ps1`)
- 로컬 설치/실사용 온보딩 문서(`docs/onboarding.md`)
- agent 공유 스레드 저장소(`ThreadStore`)와 thread 조회 API(`GET /v1/agent/threads`, `GET /v1/agent/threads/{id}`)
- 모바일 대화형 스레드 화면(스레드 목록, 타임라인, 자연어 프롬프트 작성)
- 모바일 검토 화면의 동적 run profile 목록과 전체 실행 출력 표시
- 모바일 상태 화면의 workspace adapter/runtime 정보 표시
- Cursor extension shared thread panel(`vibedeckBridge.openThreadPanel`)
- extension panel smoke(`npm --prefix extensions/vibedeck-bridge run smoke:panel`)
- Cursor shared thread panel의 apply 비활성화 사유, current job 파일 목록, HTTP 400 `CMD_ACK false` 사유 복구 표시
- extension local agent 자동 부트스트랩(`vibedeckBridge.agent.*`, `VibeDeck: Start/Stop/Restart Local Agent`)
- bootstrap smoke(`npm --prefix extensions/vibedeck-bridge run smoke:bootstrap`)
- patch files를 thread event에 저장해 모바일/IDE가 thread detail만으로 review 상태 복원 가능
- shared thread history 디스크 영속화(THREAD_STORE_FILE, 기본 %APPDATA%\\VibeDeck\\thread-store.json)
- 모바일 bootstrap 자동 세팅 v1 (`GET /v1/agent/bootstrap`, agent/signaling/workspace/current thread/recent threads 자동 조회, 최근 host 기억)
- 모바일 bootstrap 자동 세팅 v2 (extension QR/deep link, `vibedeck://bootstrap` 수신, agent/signaling/thread 자동 적용)

## 최근 체크포인트

- 2026-03-15 / 모바일 메인 셸 정리
  - 모바일 기본 화면을 공유 세션 hero -> 요청 작성 -> 지금 진행 중 -> 작업 로그 흐름으로 재구성
  - 동기화 상태는 유지하되 workstream surface 안으로 압축
  - 패치와 실행, 세션 센터는 보조 액션으로 유지하고 비핵심 카드 노출을 축소
  - 검증: flutter analyze 통과, 안전 경로 기준 flutter test test/app_smoke_test.dart 통과
- 2026-03-15 / 모바일 터미널·파일 표면 다듬기
  - workstream 카드에서 터미널 보기, 파일 보기 액션을 열어 bottom sheet로 세션 세부 표면을 노출
  - 터미널 시트에 실행 요약, 실행 명령, 최근 출력, 상위 에러, 최근 변경 파일을 연결
  - 파일 포커스 시트에 현재 포커스, 변경 파일, 패치 파일, 최근 에러 위치를 연결
  - 검증: flutter analyze 통과, 안전 경로 기준 flutter test test/app_smoke_test.dart 통과

- 2026-03-16 / 모바일 드로어 셸 재구성
  - 셸을 앱 바 + 드로어 + 하단 composer 구조로 재구성
  - 세션/파일/설정을 메인 피드 밖으로 옮기고 메인 화면은 현재 작업 + 작업 로그에 집중하도록 정리
  - 검증: flutter analyze 통과, 안전 경로 app_smoke_test 통과, 전체 flutter_test_safe.ps1는 기존 bootstrap_settings/status_metrics 실패가 그대로 남아 있음
- 2026-03-17 / 작업공간 파일 브라우저와 미리보기
  - 드로어 파일 탭을 flat list 대신 workspace tree + git status + 세션 hint(active/changed/patch/error) 기반으로 교체
  - 모바일에서 파일 내용을 바로 미리보고, 필요한 경우 간단 편집과 저장까지 할 수 있는 시트를 추가
  - shared session live update가 thread id fallback으로 흐르지 않도록 session id 우선 경로를 보정
  - 검증: go test ./internal/agent -run Workspace 통과, flutter analyze 통과, 안전 경로 app_smoke_test 통과
- 2026-03-17 / 메인 피드 inline review 정리
  - workstream 카드 안에 `검토와 실행` 표면을 추가해 패치 요약, 상세 검토, 기본 실행 프로파일 액션을 메인 피드에서 바로 처리하도록 정리
  - 패치/실행을 별도 review sheet 전용 흐름으로만 두지 않고, 메인 피드에서 다음 행동이 바로 보이도록 조정
  - 검증: flutter analyze 통과, 안전 경로 app_smoke_test 통과
- 2026-03-17 / Cursor 패널 세션 동기화 보정
  - Cursor 패널에서 thread 선택 상태와 session API 호출을 분리해 detail 조회, live state publish, session stream이 session id 기준으로 흐르도록 정리
  - panel smoke fixture도 `/sessions/{sessionId}` 기준으로 맞춰 공유 세션 경로 검증이 thread id fallback에 묶이지 않도록 보정
  - 검증: `npm --prefix extensions/vibedeck-bridge run build`, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-17 / Cursor 패널 포커스·작업공간 live sync 보강
  - active editor 변경과 selection 변경을 패널에서 감지해 focus/workspace live state를 세션에 다시 publish하도록 정리
  - panel presence update가 active file, workspace root, patch files, changed files를 함께 싣도록 보강
  - panel smoke에 editor 변화 시나리오를 추가해 모바일이 볼 live focus/workspace 값이 즉시 갱신되는 경로를 검증
  - 검증: `npm --prefix extensions/vibedeck-bridge run build`, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-17 / PC 세팅 상태 안내 한국어 정리
  - extension 상태창과 명령 진단을 한국어 안내형 메시지로 바꾸고, 세팅 막힘별 권장 조치를 함께 노출
  - workspace root, 로컬 agent launch mode, binary/repo root 누락, login/trust/model 이슈에 대한 다음 행동을 바로 보이게 정리
  - doctor, agent env, smoke 명령을 상태창 안에서 바로 확인할 수 있게 정리
  - 검증: `npm --prefix extensions/vibedeck-bridge run build`, `npm --prefix extensions/vibedeck-bridge run smoke:bootstrap`, `npm --prefix extensions/vibedeck-bridge run smoke:extension` 통과
- 2026-03-18 / Cursor 패널 작업 표면 재구성
  - panel을 `세션 작업함 + 세션 피드 + 검토와 실행 + 터미널 + 작업공간` 구조로 재배치
  - 세션 목록에 검색과 현재 세션 요약을 추가하고, 메인 화면은 thread viewer보다 shared session workspace surface에 가깝게 정리
  - prompt context 옵션은 접어두고, reasoning/plan/tools/workspace/terminal 상태를 작업 중심으로 노출
  - 검증: `npm --prefix extensions/vibedeck-bridge run build`, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-18 / shared session live state 스키마 보강
  - Cursor storage에서 들어온 `provider_message`, `tool_activity`를 shared session의 판단/계획/도구/터미널/작업공간 파생 로직에 반영
  - Cursor assistant 응답은 reasoning으로, context의 `todos`는 plan으로, terminal/files 맥락은 terminal/workspace surface로 우선 분리
  - generic context 이벤트가 assistant reasoning을 덮어쓰지 않도록 우선순위를 정리하고 focus도 workspace active file을 따라가게 보정
  - 검증: `go test ./internal/agent -run TestSessionStore`, `go test ./internal/agent -run 'TestHTTPServerSession(LiveUpdateEndpoint|TimelineAppendEndpoint)'` 통과
- 2026-03-18 / 모바일 메인 피드 inline diff 선택 보강
  - 메인 피드의 `패치 검토` 카드에서 파일별 diff 선택 surface를 직접 열고, 선택 적용을 바로 이어서 할 수 있게 정리
  - review sheet는 기본 작업 표면이 아니라 전체 diff/실행 기록을 보는 상세 시트 역할로 축소
  - smoke는 메인 피드에서 `파일별 선택 -> 선택 적용 surface 노출` 흐름을 기준으로 갱신
  - 검증: `flutter analyze` 통과, 안전 경로 `flutter test test/app_smoke_test.dart` 통과
- 2026-03-18 / 모바일 터미널 상태와 에러 포인터 표면 강화
  - 메인 피드 workstream 카드에 `최근 터미널` surface를 추가해 최근 실행 상태, 명령, 요약, 출력 미리보기를 함께 노출
  - 터미널 시트에서 상위 에러 위치와 최근 파일을 바로 열 수 있게 연결하고, 작업 로그 이벤트에도 명령/출력/상위 에러를 함께 보여주도록 정리
  - 검증: 안전 경로 `flutter analyze` 통과, 안전 경로 `flutter test test/app_smoke_test.dart` 통과
- 2026-03-18 / 모바일 파일 드로어 실시간 포커스 sync 보강
  - 파일 드로어 상단에 `실시간 포커스` 카드를 추가해 현재 파일, 선택 영역, 최근 에러 위치를 메인 피드 밖에서 바로 확인할 수 있게 정리
  - `파일 포커스` 시트에 `포커스 열기`, `에러 열기` 액션을 추가하고, 세션 live update가 들어오면 캐시된 workspace tree를 필요한 경로만 다시 불러오도록 보강
  - 검증: 안전 경로 `flutter analyze` 통과, 안전 경로 `flutter test test/app_smoke_test.dart` 통과
- 2026-03-18 / 모바일 shared session recovery/log visibility 마감
  - stalled/reconnecting/failed 상태에서 배너 안에 `다음 액션`, `복구 로그`를 함께 보여주도록 정리
  - 초기 연결 로그는 메인 피드를 밀어내지 않도록 숨기고, 실제 recovery 상황에서만 배너가 다시 나타나게 조정
  - 검증: 안전 경로 `flutter analyze` 통과, 안전 경로 `flutter test test/app_smoke_test.dart` 통과
- 2026-03-18 / Windows smoke cleanup 경로 정리
  - `scripts/extension_host_smoke.ps1`를 `go run` wrapper 대신 임시 agent binary 직접 빌드 + 직접 실행 경로로 전환해 Windows cleanup 안정성을 높임
  - `vibedeck_doctor.ps1`, README, onboarding, 패널 안내 문구를 bootstrap smoke / doctor 중심 흐름으로 정리
  - 검증: `powershell -ExecutionPolicy Bypass -File .\scripts\vibedeck_doctor.ps1` 통과, `npm --prefix extensions/vibedeck-bridge run smoke:bootstrap` 통과, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-18 / Cursor 스타일 채팅 패널 리프레시
  - `extensions/vibedeck-bridge` 패널을 카드 대시보드형에서 `세션 사이드바 + 중앙 대화 + 우측 보조 레일` 구조로 재배치
  - 대화 타임라인을 말풍선형 메시지 피드로 바꾸고, composer를 하단 작업창처럼 정리
  - `검토`, `실행`, `파일과 포커스`는 우측 레일로 눌러 메인 채팅 흐름 오염을 줄임
  - 검증: `npm --prefix extensions/vibedeck-bridge run build` 통과, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-18 / Cursor shared threads 사이드패널 전환과 빈 화면 수정
  - `Open Shared Threads`를 에디터 탭 fallback이 아닌 사이드바 webview view를 우선 여는 구조로 바꿈
  - 실제 session live state가 일부 비어 있어도 렌더가 죽지 않도록 live/operation state를 기본값으로 정규화
  - 검증: `npm --prefix extensions/vibedeck-bridge run build` 통과, `npm --prefix extensions/vibedeck-bridge run smoke:panel` 통과
- 2026-03-18 / 모바일 bootstrap local agent 자동 복구와 실기기 안내 보강
  - `Open Mobile Bootstrap` 진입 시 local agent가 꺼져 있으면 먼저 자동으로 시작을 시도하도록 보강
  - 부트스트랩 패널과 오류 메시지에 `vibedeckBridge.agent.host=0.0.0.0`, `VibeDeck: Restart Local Agent`, `signaling` 별도 실행 필요를 한국어로 명시
  - 검증: `npm --prefix extensions/vibedeck-bridge run build` 통과, `npm --prefix extensions/vibedeck-bridge run smoke:mobile-bootstrap` 통과

## 다음 작업 우선순위

1. control timeout budget 운영 설정 외부화
2. 설치 산출물 버전 관리/릴리스 자동화
3. Cursor 외 provider(Codex/Claude Code/Antigravity) 확장용 adapter mode 정리

주의:
- provider 확장은 Cursor 기반 unified session 흐름이 충분히 완성된 뒤에 진행한다.
- 자세한 설계와 단계 목표는 `docs/unified-session.md`를 기준으로 한다.

## 커밋 전략

기능 단위의 큰 커밋으로 진행:

1. `chore(repo): 모노레포 구조 및 공통 계약 초기화`
2. `feat(signaling,relay): 페어링/시그널링/릴레이 베이스라인`
3. `feat(agent): prompt-patch-run 오케스트레이션 베이스라인`
4. `feat(cursor-bridge): TypeScript WorkspaceAdapter 계약 추가`
5. `feat(runtime): 연결 상태머신/ACK 추적기 추가`
6. `feat(signaling): webrtc signaling 검증/큐잉 강화`
7. `feat(webrtc): pc/mobile datachannel skeleton`
8. `feat(webrtc): signaling bridge runtime`
9. `feat(agent): p2p session orchestrator`
10. `feat(agent): p2p envelope routing 통합`
11. `test(agent): mobile control flow interop e2e 추가`
12. `feat(mobile): flutter prompt/review/status baseline`
13. `feat(mobile): flutter screen + agent api integration`
14. `docs(ops): 크리티컬 이슈/트러블슈팅 학습 노트`
15. `feat(mobile): direct signaling skeleton + status ui`
16. `feat(mobile): flutter webrtc peer + direct control path integration`
17. `feat(cursor-bridge): add cursor extension host bridge`
18. `feat(agent): connect cursor bridge runtime over stdio`
19. `feat(cursor-bridge): add cursor extension runtime helper`
20. `feat(runtime): p2p control response ack retry backoff 추가`
21. `test(mobile): add direct control integration coverage`
22. `feat(runtime): add ack observability metrics`
23. `feat(cursor-bridge): add localhost tcp extension bridge`
24. `feat(extension): add bridge command readiness diagnostics`
25. `feat(agent): add cursor-agent cli worktree adapter`
26. `feat(ops): add cursor-agent smoke diagnostics`
27. `feat(agent): support WSL cursor-agent smoke on Windows`
28. `feat(agent): align control timeouts with real cursor-agent latency`
29. `test(ops): prove real cursor-agent smoke after login`
