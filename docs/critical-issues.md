# 크리티컬 이슈 및 학습 노트

개발 중 발생하는 장애/고위험 이슈를 기록합니다.

## 현재 상태

- 런타임 크리티컬 버그는 아직 식별되지 않았습니다.

## 현재 환경 리스크(관측)

### 2026-03-06 / TOOLCHAIN-002 / Flutter 전역 PATH 미설정

- 증상: 시스템 전역 `flutter` 명령 인식 실패
- 영향: 팀원/CI 환경마다 Flutter 실행 경로 불일치 가능성
- 즉시 대응:
  - 로컬 SDK를 `tools/flutter`에 설치
  - `tools/flutter/bin/flutter.bat` 기준으로 `pub get`, `analyze`, `test` 검증 수행
- 영구 대응:
  - Flutter SDK 전역 PATH 표준화 또는 `fvm` 도입
  - CI에 모바일 smoke test(`flutter pub get && flutter test`) 추가
- 학습 포인트:
  - 도구체인은 "설치 여부"뿐 아니라 "실행 경로 표준화"까지 완료돼야 팀 생산성이 안정화됨

### 2026-03-07 / TOOLCHAIN-003 / 경로(공백/한글) + native assets 훅 충돌

- 증상: `flutter test` 실행 시 `objective_c` native assets 훅이 `'C:\Users\99yoo\OneDrive\바탕' is not recognized` 오류로 실패
- 영향: 모바일 테스트 루프가 환경 경로에 따라 불안정해질 수 있음
- 즉시 대응:
  - `google_fonts` 의존성 제거로 transitive native assets 훅 제거
  - 의존성 단순화 후 `flutter analyze`, `flutter test` 재검증 통과
- 영구 대응:
  - 경로 공백/로케일 이슈를 포함한 Flutter CI 매트릭스 테스트 추가
  - 필요 시 폰트/플러그인 의존성은 native assets 영향 범위를 기준으로 선택
- 학습 포인트:
  - 모바일 툴체인 이슈는 기능 코드보다 실행 환경(경로/권한/훅) 검증을 먼저 자동화해야 재발을 줄일 수 있음

### 2026-03-07 / TOOLCHAIN-004 / Git safe.directory 소유권 검증 차단

- 증상: CodexSandbox 사용자로 실행 시 `detected dubious ownership` 오류로 `git status` 등 기본 Git 명령 실패
- 영향: 브랜치 상태 확인/커밋/머지 후속 작업이 즉시 중단되어 개발 흐름이 끊김
- 즉시 대응:
  - `git config --global --add safe.directory <repo-path>`로 신뢰 디렉터리 등록
  - 등록 직후 `git status -sb`로 접근 정상 여부 확인
- 영구 대응:
  - 팀 자동화 에이전트/CI 실행 계정이 바뀌는 환경에서는 초기 bootstrap 스크립트에 safe.directory 등록 단계 포함
  - OneDrive/공유 폴더 사용 시 소유권 변경 가능성을 운영 가이드에 명시
- 학습 포인트:
  - 권한/소유권 이슈는 코드와 무관하게 전체 개발 사이클을 멈추므로, 재현 즉시 "즉시 대응 + 영구 대응"을 분리해 기록해야 함

### 2026-03-07 / TOOLCHAIN-005 / flutter_webrtc 도입 후 native assets 훅 재발

- 증상: `flutter_webrtc` 추가 후 `flutter test`가 다시 `objective_c` 훅에서 `'C:\Users\99yoo\OneDrive\바탕' is not recognized`로 실패
- 영향: 모바일 WebRTC 기능 추가 직후 기본 테스트 루프가 다시 중단됨
- 즉시 대응:
  - 경로 공백/한글 우회용 스크립트 `mobile/flutter_app/scripts/flutter_test_safe.ps1` 추가
  - 스크립트에서 `subst V:` 임시 매핑 후 `flutter test` 실행, 완료 후 자동 해제
- 영구 대응:
  - CI/로컬 공통으로 공백 없는 작업 경로 표준화
  - native assets 훅을 사용하는 의존성 도입 시 사전 경로 호환성 체크를 PR 체크리스트에 추가
- 학습 포인트:
  - 기능 의존성 추가는 런타임 기능뿐 아니라 테스트 실행 파이프라인(native assets 포함) 영향까지 함께 검증해야 함

## 런타임 리스크(설계)

### 2026-03-06 / RUNTIME-001 / ACK 만료 오탐 가능성

- 증상 가능성: 네트워크 지연이 큰 환경에서 정상 응답도 timeout 처리될 수 있음
- 영향: 불필요한 `RECONNECTING` 상태 전환 증가
- 즉시 대응: 현재는 만료 항목 조회 시에만 reconnect 전환
- 영구 대응:
  - 메시지 타입별 timeout 차등화
  - 재전송 횟수/지수 백오프 도입
  - 실제 RTT 관측값 기반 동적 timeout 조정
- 학습 포인트:
  - ACK 시스템은 "엄격함"보다 "관측 기반 튜닝"이 중요함

### 2026-03-06 / RUNTIME-002 / Inbound ACK 미처리 시 pending 누적

- 증상 가능성: 모바일에서 `CMD_ACK`를 보내도 서버가 미처리하면 pending ACK가 계속 쌓임
- 영향: 만료 감지 오탐 증가, reconnect 과다
- 즉시 대응: `/v1/agent/envelope`에서 `CMD_ACK`를 분기 처리해 pending 제거
- 영구 대응:
  - ACK 중복/순서 뒤바뀜 시나리오 통합 테스트 추가
  - 메시지 타입별 ACK 필요 여부를 명시한 정책 테이블 도입
- 학습 포인트:
  - ACK 추적은 등록/만료뿐 아니라 "수신 소거 경로"가 있어야 완결됨

### 2026-03-06 / SIGNAL-001 / 시그널 큐 포화 시 후보 누락 가능성

- 증상 가능성: 상대 피어 지연 접속 + ICE 폭주 시 oldest candidate가 큐에서 탈락
- 영향: NAT 환경에 따라 P2P 연결 성공률 저하 가능
- 즉시 대응: 큐 길이 상한을 두고 overflow 시 oldest 제거(서버 메모리 보호)
- 영구 대응:
  - candidate 우선순위 룰 적용(host/srflx/relay)
  - 큐 정책을 세션 품질 지표 기반으로 동적 조정
  - fallback 판단 로직(빠른 relay 전환)과 함께 튜닝
- 학습 포인트:
  - 시그널링 설계는 완전보존보다 연결 성공률/지연의 균형이 핵심

### 2026-03-06 / WEBRTC-001 / 로컬 통합 테스트 타이밍 플래키 가능성

- 증상 가능성: CI 환경 성능 편차에 따라 connected/open 이벤트 타임아웃 발생
- 영향: 실제 코드 이상 없이 테스트가 실패할 수 있음
- 즉시 대응: 상태/채널 open 대기 시간을 명시하고, ICE 후보 전달은 best-effort 로그 처리
- 영구 대응:
  - 테스트 전용 구성값(타임아웃, 버퍼) 분리
  - 재시도 가능한 헬퍼 및 flaky detector 도입
- 학습 포인트:
  - WebRTC 테스트는 기능 검증과 안정성 검증을 분리해야 유지보수가 쉬움

### 2026-03-06 / WEBRTC-002 / SIGNAL_READY 중복 수신 시 offer 중복 생성 리스크

- 증상 가능성: 재연결 또는 중복 이벤트에서 PC가 offer를 여러 번 생성하려 시도
- 영향: 협상 충돌, 연결 실패 확률 증가
- 즉시 대응: bridge에서 `offerStarted` 원자 플래그로 1회만 offer 시작
- 영구 대응:
  - renegotiation 전용 상태머신 분리
  - session version과 glare handling 정책 도입
- 학습 포인트:
  - 초기 협상 제어와 재협상 제어는 별도 설계가 필요함

### 2026-03-06 / AGENT-P2P-001 / WS read/write 루프 오류 시 자동 재시작 미구현

- 증상 가능성: 일시 네트워크 단절 후 세션이 `RECONNECTING`에 머물고 자동복구 실패
- 영향: 수동 `p2p/start` 재호출 필요
- 즉시 대응: read/write/bridge 오류 시 상태를 `RECONNECTING`으로 전환하고 오류 메시지 기록
- 영구 대응:
  - 지수 백오프 기반 자동 재연결 정책 추가
  - 실패 횟수 제한 + fallback relay 전환 정책 결합
- 학습 포인트:
  - 상태 전이 표시와 실제 복구 실행은 분리해서 설계해야 함

### 2026-03-06 / AGENT-P2P-002 / DataChannel 제어 메시지 burst 시 단일 루프 병목 가능성

- 증상 가능성: 모바일에서 제어 요청을 매우 빠르게 연속 전송하면 처리 지연이 누적될 수 있음
- 영향: `PROMPT_ACK`/`PATCH_READY`/`RUN_RESULT` 응답 지연, ACK timeout 오탐 위험 증가
- 즉시 대응: 현재는 단일 소비 루프 + bounded channel로 안정성 우선, 파싱 실패는 연결을 끊지 않고 에러 기록
- 영구 대응:
  - 제어 메시지 worker pool + 순서 보장 정책 분리
  - 메시지 타입별 우선순위 큐 도입(`CMD_ACK` 고우선)
  - queue depth/latency 메트릭 기반 autoscaling 임계치 정의
- 학습 포인트:
  - 제어 경로는 처리량보다 순서/신뢰성 보장이 먼저이며, 병렬화는 명시적 순서 정책과 함께 도입해야 함

### 2026-03-08 / CURSOR-EXT-001 / 공식 Cursor task command 계약 부재

- 증상: extension host에 localhost bridge는 올릴 수 있지만, 저장소 안에 실제 Cursor AI task/patch/run command ID 매핑은 없음
- 영향: `command` mode를 바로 켜도 기본 `vibedeck.*` command가 등록되지 않은 환경에서는 bridge가 시작되지 않음
- 즉시 대응:
  - `extensions/vibedeck-bridge`에 command readiness 검증(`vibedeckBridge.validateCommands`) 추가
  - 필수 command 누락 시 시작을 막고, optional command는 경고만 표시
  - `vibedeckBridge.copyAgentEnv`로 agent 연결 환경변수 복사 경로 제공
- 영구 대응:
  - 공식 Cursor extension API/command 계약이 확인되면 해당 command ID 또는 API 호출로 직접 매핑
  - 공식 계약이 없으면 CLI/MCP 기반 대체 adapter 경로 설계
  - extension host smoke/E2E 자동화로 실제 사용 가능 상태를 지속 검증
- 학습 포인트:
  - editor bridge는 "브리지를 띄우는 것"과 "실제 AI 작업 명령에 연결하는 것"을 분리해서 관리해야 구현 착시를 줄일 수 있음

### 2026-03-08 / CURSOR-CLI-001 / 공식 Cursor CLI 비대화형 쓰기 권한과 review-first UX 충돌

- 증상: 공식 `cursor-agent` CLI는 비대화형 `--print` 모드에서도 파일을 직접 수정할 수 있어, 그대로 workspace에서 실행하면 VibeDeck의 `patch review -> apply` 흐름을 우회함
- 영향: 사용자의 미검토 변경이 실제 workspace에 즉시 반영되고, 기존 로컬 변경과 충돌하거나 덮어쓸 리스크가 커짐
- 즉시 대응:
  - `WORKSPACE_ADAPTER_MODE=cursor_agent_cli` 경로에서 CLI를 실제 workspace가 아닌 임시 git worktree snapshot에서 실행
  - 현재 workspace의 tracked diff와 untracked 파일만 temp worktree에 동기화
  - 생성된 diff만 `PATCH_READY`로 반환하고, 승인 후 실제 workspace에는 `git apply`로 반영
- 영구 대응:
  - ignored/generated 파일 sync 정책 정리
  - 실제 `cursor-agent` 바이너리 기준 smoke/E2E 자동화 추가
  - 필요 시 worktree 대신 snapshot copy/overlay 전략과 성능 비교
- 학습 포인트:
  - 공식 AI 실행 경로가 있다고 해서 곧바로 제품 UX에 맞는 것은 아니며, review-first 제품은 실행 경계(workspace isolation)를 먼저 설계해야 함

### 2026-03-08 / TOOLCHAIN-006 / 로컬 Windows 환경에 cursor-agent 바이너리 부재

- 증상: `where.exe cursor-agent`가 실패해 Windows PATH만 기준으로는 `cursor-agent`를 찾지 못함
- 영향: 네이티브 경로만 가정하면 실제 Cursor CLI 기준 smoke/E2E를 이 PC에서 즉시 수행할 수 없음
- 즉시 대응:
  - WSL distro 목록과 `~/.local/bin/cursor-agent`/`~/.local/bin/agent`를 자동 탐지하도록 agent/smoke 스크립트 보강
  - `CURSOR_AGENT_USE_WSL=true`, `CURSOR_AGENT_WSL_DISTRO=<name>` 환경변수로 경로를 명시적으로 제어 가능하게 유지
  - `/v1/agent/runtime/adapter` endpoint로 adapter/binary 상태를 바로 확인 가능하게 함
- 영구 대응:
  - 팀 로컬 환경에 Cursor CLI 설치 절차를 네이티브/WSL 두 경로로 표준화
  - 실제 설치 환경에서 `scripts/cursor_agent_smoke.ps1` 결과를 CI 또는 운영 체크리스트에 포함
  - Windows PATH 등록 여부와 설치 위치 차이를 가이드에 명시
- 학습 포인트:
  - 실사용 smoke는 기능 코드만으로 끝나지 않고, 실제 실행 바이너리의 설치 위치와 운영체제별 호출 경로까지 포함해야 재현 가능성이 확보됨

### 2026-03-08 / CURSOR-CLI-002 / cursor-agent 인증 미완료로 실제 smoke 차단

- 증상: WSL 안의 `cursor-agent` binary는 정상 탐지되지만 `PROMPT_SUBMIT` 시 `Authentication required. Please run 'agent login' first, or set CURSOR_API_KEY environment variable.` 오류로 종료됨
- 영향: 실제 AI patch 생성 smoke는 코드 경로가 정상이더라도 Cursor 인증이 완료되기 전까지 진행되지 않음
- 현재 상태: 2026-03-08 `cursor-agent login` 완료 후 active blocker는 해소되었고, 실제 smoke가 통과함
- 즉시 대응:
  - `powershell -ExecutionPolicy Bypass -File .\scripts\cursor_agent_smoke.ps1`가 인증 미완료를 감지하면 정확한 login 명령을 안내하도록 보강
  - 현재 환경 기준 안내 명령: `wsl.exe -d Ubuntu -- /home/fharena/.local/bin/cursor-agent login`
  - 또는 Windows 쪽 `CURSOR_API_KEY` 환경변수를 설정한 뒤 agent/smoke를 재실행
- 영구 대응:
  - 팀 온보딩 문서에 Cursor CLI 인증 절차 추가
  - CI/공용 환경에서는 secret 관리 방식(`CURSOR_API_KEY`)과 login-free 실행 정책 분리
  - 가능하면 adapter readiness에 인증 상태 preflight를 추가
- 학습 포인트:
  - 외부 AI 도구의 "설치됨"과 "실행 가능함"은 다르며, 실제 운영 가능성은 인증 상태까지 포함해 확인해야 함

### 2026-03-08 / CURSOR-CLI-003 / Workspace Trust 미설정 시 headless smoke 실패

- 증상: 실제 `cursor-agent --print` 실행이 `Workspace Trust Required` 오류로 종료됨
- 영향: 설치와 인증이 모두 정상이어도 headless patch 생성이 첫 요청에서 막힘
- 즉시 대응:
  - agent 기본 인자에 `--trust`를 자동 주입하고 `CURSOR_AGENT_TRUST_WORKSPACE=false`일 때만 비활성화
  - smoke 스크립트도 동일한 기본값을 사용하도록 정렬
- 영구 대응:
  - adapter readiness 또는 smoke preflight에서 trust 요구 여부를 더 이르게 진단
  - 팀 문서에 headless 실행 시 trust 정책을 명시
- 학습 포인트:
  - CLI 기반 자동화도 IDE의 workspace policy를 그대로 상속하므로, 비대화형 실행 옵션을 운영 기본값으로 설계해야 함

### 2026-03-08 / CURSOR-CLI-004 / Free plan에서 named model 기본값이 실패

- 증상: 실제 실행 시 `Named models unavailable Free plans can only use Auto.` 오류가 발생함
- 영향: 설치/인증이 정상이더라도 모델 선택 기본값이 계정 플랜과 안 맞으면 smoke가 실패함
- 즉시 대응:
  - agent 기본 인자에 model이 없으면 `--model auto`를 자동 주입
  - `CURSOR_AGENT_MODEL` 환경변수로 명시적 override 지원 유지
- 영구 대응:
  - adapter readiness에 모델 capability 또는 계정 제약 진단을 추가
  - 운영 가이드에서 plan-dependent 기본값을 분리
- 학습 포인트:
  - 외부 AI 런타임의 모델 선택은 코드 기본값만으로 안전하지 않으며, 계정/플랜 제약을 함께 반영해야 함

### 2026-03-08 / RUNTIME-003 / 고정 5초 control timeout이 실제 AI 실행을 조기 종료

- 증상: 직접 `cursor-agent` 실행은 성공하지만 `/v1/agent/envelope` 경로에서는 약 5초 후 `cursor-agent execution failed`로 종료됨
- 영향: mock/fixture에서는 드러나지 않던 실제 LLM 지연 때문에 `PROMPT_SUBMIT`과 `RUN_PROFILE`이 지속적으로 실패함
- 즉시 대응:
  - HTTP/P2P control handler에 message type별 timeout helper를 도입
  - `PROMPT_SUBMIT`, `RUN_PROFILE`은 처음 2분으로 분리했고, 실제 GUI smoke 검증 후 5분으로 상향. `PATCH_APPLY`는 30초, 나머지는 5초 유지
  - timeout 정책 단위 테스트 추가
- 영구 대응:
  - timeout budget을 환경변수 또는 운영 설정으로 외부화
  - runtime metrics에 handler latency/timeout 비율을 추가해 조기 경고 가능하게 함(완료: `/v1/agent/runtime/metrics` + `/metrics`에 control 집계 추가)
- 학습 포인트:
  - fixture가 빠르게 응답한다고 해서 운영 timeout budget이 충분한 것은 아니며, 실제 AI latency를 기준으로 제어면 budget을 따로 설계해야 함
### 2026-03-08 / RUNTIME-004 / 실제 GUI extension host + Cursor Agent 첫 호출이 2분 budget을 초과

- 증상: 실제 Cursor GUI extension host에서 built-in cursor-agent provider를 통해 `PROMPT_SUBMIT`을 실행하면 첫 호출이 2분 budget을 넘어 `context deadline exceeded`로 종료될 수 있음
- 영향: fixture/mock smoke는 통과해도 real smoke/E2E가 불안정하고, 사용자는 첫 실제 요청에서 실패로 인식할 수 있음
- 즉시 대응:
  - HTTP/P2P control timeout에서 `PROMPT_SUBMIT`/`RUN_PROFILE` budget을 5분으로 상향
  - extension built-in provider 기본 `promptTimeoutMs`/`runTimeoutMs`도 300000으로 상향
  - `scripts/gui_extension_host_smoke.ps1`로 실제 Cursor GUI host 기준 smoke 재검증 통과
- 영구 대응:
  - timeout budget을 환경변수 또는 운영 설정으로 외부화
  - 첫 호출 latency와 steady-state latency를 분리 관측해 budget을 재조정
  - 장기적으로는 `PROMPT_SUBMIT`을 비동기 job kickoff와 상태 polling으로 분리 검토
- 학습 포인트:
  - fixture가 빠르게 응답한다고 운영 budget이 충분한 것은 아니며, 실제 GUI/LLM warm-up 비용을 기준으로 제어면 deadline을 설계해야 함

### 2026-03-08 / TOOLCHAIN-007 / Windows extension host smoke 종료 직후 agent.exe 잠금

- 증상: `scripts/extension_host_smoke.ps1`가 기능 smoke는 통과하지만 cleanup 단계에서 `Access to the path ''agent.exe'' is denied.` 경고를 남기고 temp root를 지우지 못함
- 영향: smoke 결과 자체는 확인되지만, 종료 직후 temp 산출물이 남고 스크립트 종료 코드가 불안정해질 수 있음
- 2026-03-18 업데이트:
  - `extension_host_smoke.ps1`가 `go run` 대신 임시 `agent.exe`를 먼저 빌드하고, wrapper `cmd` 없이 프로세스를 직접 실행하도록 변경
  - stdout/stderr도 agent 프로세스에 직접 연결해 종료 후 handle 해제와 cleanup retry가 더 안정적으로 동작하게 정리
- 즉시 대응:
  - 최신 스크립트 기준으로 다시 실행해 재현 여부를 먼저 확인
  - 여전히 temp root가 남으면 `-KeepTempRoot`로 산출물을 남기고 수동 정리
- 영구 대응:
  - cleanup 전 child process tree와 handle 해제 시점을 더 정확히 추적
- 학습 포인트:
  - Windows smoke 스크립트는 기능 경로 검증과 별개로 프로세스/파일 잠금 해제 타이밍까지 고려해야 안정적으로 종료된다
### 2026-03-08 / EXTENSION-001 / 기본 command 설정이 undefined로 default 매핑을 덮어씀

- 증상: built-in command provider activation smoke에서 `required commands ready: 0/0`가 나오고, 기본 `vibedeck.*` command가 등록되지 않음
- 영향: command mode를 기본 설정으로 켜도 built-in provider와 external provider 모두 필수 command 매핑이 비어 실제 시작 경로가 깨질 수 있음
- 즉시 대응:
  - extension의 command 설정 로더가 `undefined` 값을 객체에 넣지 않도록 수정
  - activation-path smoke(`npm --prefix extensions/vibedeck-bridge run smoke:extension`) 추가로 실제 활성화 경로에서 재발 여부 확인
- 영구 대응:
  - 부분 설정 객체를 default 객체에 merge할 때 `undefined` override를 금지하는 공통 helper 패턴 유지
  - command readiness 검증을 unit/smoke 수준 모두에서 유지
- 학습 포인트:
  - TypeScript에서 partial config를 spread merge할 때 `undefined`도 실제 override이므로, 기본값 보존이 필요한 설정은 "키 생략"과 "undefined 값"을 엄격히 구분해야 한다
### 2026-03-08 / TOOLCHAIN-008 / file: 의존성 그대로 VSIX에 들어가 invalid relative path 발생

- 증상: `vsce package`가 `invalid relative path: extension/../../adapters/cursor-bridge/node_modules/...` 오류로 실패
- 영향: 로컬에서는 extension이 동작해도 실제 `.vsix` 산출물을 만들 수 없어 설치/배포 단계가 막힘
- 즉시 대응:
  - `extensions/vibedeck-bridge/scripts/package_vsix.mjs` 추가
  - 패키징 시 temp staging 디렉터리를 만들고, extension dist와 `@vibedeck/cursor-bridge`의 runtime 파일(`dist`, `README.md`, `package.json`)만 vendor copy
  - extension 쪽은 `node ./scripts/package_vsix.mjs`, 루트 쪽은 `scripts/package_vibedeck_bridge.ps1`에서 Node entry를 직접 호출하도록 정렬
- 영구 대응:
  - 로컬 file dependency 기반 extension 패키징은 staging/vendor copy 또는 publishable tarball 경로로 표준화
  - 릴리스 자동화 시 VSIX 내부 tree 검증을 체크에 포함
- 학습 포인트:
  - 개발용 file dependency는 런타임 확인에는 편하지만, 배포 산출물에서는 저장소 바깥 상대경로를 끌어들일 수 있으므로 packaging 경계를 따로 설계해야 함
### 2026-03-08 / TOOLCHAIN-009 / Android Gradle local.properties 가 한글 경로를 깨뜨림

- 증상: `flutter build apk` 또는 `flutter run`이 `Included build ''...tools\flutter\packages\flutter_tools\gradle'' does not exist.` 로 실패하고, 경로의 `바탕 화면` 부분이 mojibake로 깨짐
- 영향: Android 실기기 연결이 정상이어도 Windows 한글/공백 경로에서 모바일 앱 실행이 막힘
- 즉시 대응:
  - `mobile/flutter_app/scripts/flutter_safe.ps1` 추가
  - `subst V:` 임시 매핑 후 `V:\tools\flutter\bin\flutter.bat` 기준으로 실행
  - 실행 전에 `android/local.properties`를 삭제해 Flutter가 ASCII 경로 기준으로 다시 생성하게 함
- 영구 대응:
  - Flutter/Android 작업 경로를 공백 없는 ASCII 경로로 표준화
  - 모바일 온보딩 문서와 실행 스크립트에 safe 경로 우회 방법을 기본 경로로 포함
- 학습 포인트:
  - Java properties 기반 도구는 Windows 로케일 경로를 그대로 안전하게 처리하지 못할 수 있으므로, 실제 Android/Gradle 경로는 ASCII 기준 우회 경로를 미리 제공하는 편이 안정적임
## 해결 방식 학습 체크리스트

1. 문제 재현 명령을 문서화했는가?
2. 임시 우회와 영구 해결을 분리해 기록했는가?
3. 해결 후 회귀 테스트를 추가했는가?
4. 설계 원칙(ACK 보장, backpressure, adapter 분리) 위반이 없는가?

## 사고 기록 템플릿

- 날짜:
- 컴포넌트:
- 증상:
- 근본 원인:
- 즉시 완화 조치:
- 영구 해결 방식:
- 추가한 회귀 테스트:
- 학습 포인트:
