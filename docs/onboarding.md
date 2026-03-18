# 온보딩 가이드

이 문서는 VibeDeck을 새 PC에서 `5~10분 안에` 실행 가능한 상태로 올리는 최소 절차를 정리합니다.

## 1. 사전 점검

루트에서 doctor 스크립트를 먼저 실행합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\vibedeck_doctor.ps1
```

doctor가 확인하는 항목:

- `git`, `go`, `node`, `npm`
- `flutter` 또는 로컬 Flutter SDK
- `cursor`/`code` CLI
- 네이티브 또는 WSL `cursor-agent`
- adapter/extension build 산출물
- VSIX 패키징 도구(`vsce`)

## 2. 가장 빠른 smoke

가장 빠른 시작 경로는 extension 자동 부트스트랩 smoke입니다.

```powershell
npm --prefix .\extensions\vibedeck-bridge run smoke:bootstrap
```

이 경로는 local agent lifecycle과 panel agent URL 연결이 정상인지 먼저 확인합니다.

저수준 fixture agent를 직접 띄워 보고 싶으면 아래를 사용합니다.

```powershell
npm --prefix .\adapters\cursor-bridge install
npm --prefix .\adapters\cursor-bridge run build
go run ./cmd/signaling
go run ./cmd/relay
go run ./cmd/agent
```

이 수동 경로는 `fixtureBridgeMain.js`를 사용하므로 실제 Cursor 파일 수정 대신 흐름만 검증합니다.

## 3. 실제 cursor-agent smoke

실제 AI patch 생성 경로는 아래 스크립트 하나로 검증합니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\cursor_agent_smoke.ps1
```

Windows에서 `cursor-agent`가 WSL에만 있으면:

```powershell
$env:CURSOR_AGENT_USE_WSL = "true"
$env:CURSOR_AGENT_WSL_DISTRO = "Ubuntu"
powershell -ExecutionPolicy Bypass -File .\scripts\cursor_agent_smoke.ps1
```

인증이 안 된 경우에는 먼저 PowerShell에서 로그인합니다.

```powershell
wsl.exe -d Ubuntu -- /home/<user>/.local/bin/cursor-agent login
```

Git Bash에서는 경로 변환 때문에 아래처럼 실행해야 합니다.

```bash
MSYS_NO_PATHCONV=1 wsl.exe -d Ubuntu -- /home/<user>/.local/bin/cursor-agent login
```

`cursor_agent_smoke.ps1`가 `resource_exhausted`로 실패하면 설치 문제보다는 Cursor 계정의 사용량 한도, 결제 상태, 동시 실행 제한을 먼저 확인하세요.

## 4. Extension VSIX 패키징

extension을 로컬 설치 가능한 `.vsix`로 만들려면:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1 -InstallDependencies
```

산출물 기본 경로:

- `artifacts\vsix\vibedeck-bridge-<version>.vsix`

패키징만 다시 할 때:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1
```

필요하면 smoke까지 같이 돌릴 수 있습니다.

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package_vibedeck_bridge.ps1 -RunSmoke
```

설치 예시:

```powershell
cursor --install-extension .\artifacts\vsix\vibedeck-bridge-0.1.0.vsix --force
```

또는 Cursor/VS Code에서 `Extensions: Install from VSIX...`를 사용합니다.

## 5. 실제 GUI extension host smoke

Cursor GUI까지 포함한 end-to-end smoke:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\gui_extension_host_smoke.ps1 -Editor cursor -UseWslCursorAgent true -CursorAgentBin /home/<user>/.local/bin/cursor-agent -CursorAgentWslDistro Ubuntu
```

이 스크립트는 다음을 자동으로 확인합니다.

- dev extension host 기동
- localhost TCP bridge 연결
- `PROMPT_SUBMIT -> PATCH_APPLY -> RUN_PROFILE`
- 실제 `notes.txt` 변경 반영

## 6. 모바일까지 붙여서 확인

같은 로컬 네트워크에서 모바일 앱을 붙일 때:

```powershell
go run ./cmd/signaling
go run ./cmd/relay
go run ./cmd/agent
cd .\mobile\flutter_app
..\..\tools\flutter\bin\flutter.bat run
```

앱 설정:

- Android 에뮬레이터: `10.0.2.2`
- 실기기: PC LAN IP 사용

필수 확인 항목:

- `P2P Active=true`
- `Direct 연결` 성공
- `Control Ready=true`
- Status 탭 `ACK Observability` 값 갱신

## 7. 현재 남은 운영 이슈

- Windows mock smoke는 임시 agent binary 직접 실행으로 정리했지만, 환경에 따라 temp root가 남으면 `-KeepTempRoot`로 원인을 확인해야 할 수 있음
- control timeout budget은 현재 코드 기본값으로 고정되어 있어 운영 설정 외부화가 남아 있음
