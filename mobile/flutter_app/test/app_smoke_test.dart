import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/screens/workspace_browser.dart';
import 'package:vibedeck_mobile/screens/prompt_screen.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';
import 'package:vibedeck_mobile/app.dart';

void main() {
  testWidgets('드로어 기반 모바일 셸 흐름을 보여준다', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = AppController(api: _FakeShellAgentApi());
    addTearDown(controller.dispose);

    await tester.pumpWidget(VibeDeckApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('바이브덱 모바일'), findsNothing);
    expect(find.text('인증 미들웨어 실패'), findsOneWidget);
    expect(find.text('현재 작업'), findsOneWidget);
    expect(find.text('검토와 실행'), findsOneWidget);
    expect(find.text('패치 검토'), findsOneWidget);
    expect(find.text('실행 확인'), findsOneWidget);
    expect(find.text('데모 점검 실행'), findsOneWidget);
    expect(find.text('파일별 선택'), findsOneWidget);
    expect(find.text('최근 터미널'), findsOneWidget);
    expect(find.text('에러 열기'), findsOneWidget);
    expect(find.textContaining('npm test -- --failed'), findsOneWidget);
    expect(find.text('작업 로그'), findsWidgets);
    expect(find.text('보내기'), findsOneWidget);

    await tester.tap(find.text('파일별 선택'));
    await tester.pumpAndSettle();

    expect(find.text('선택 적용'), findsOneWidget);
    expect(find.text('전체 시트 보기'), findsOneWidget);
    expect(find.text('mobile/flutter_app/lib/app.dart'), findsWidgets);
    expect(find.text('status modified / 헝크 1개'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    expect(find.text('세션 검색...'), findsOneWidget);
    expect(find.text('새 세션'), findsOneWidget);
    expect(find.text('세션'), findsWidgets);
    expect(find.text('파일'), findsOneWidget);
    expect(find.text('설정'), findsOneWidget);
    expect(find.text('인증 미들웨어 실패'), findsWidgets);

    await tester.tap(find.text('파일'));
    await tester.pumpAndSettle();

    expect(find.text('실시간 포커스'), findsOneWidget);
    expect(find.text('포커스 보기'), findsOneWidget);
    expect(find.textContaining('선택: 인증 미들웨어'), findsOneWidget);
    expect(find.text('README.md'), findsWidgets);

    await tester.tap(find.text('설정'));
    await tester.pumpAndSettle();

    expect(find.text('세션 센터 열기'), findsOneWidget);
    expect(find.text('터미널 열기'), findsOneWidget);

    await tester.tap(find.text('세션 센터 열기'));
    await tester.pumpAndSettle();

    expect(find.text('세션 센터'), findsOneWidget);
  });

  testWidgets('파일 미리보기와 저장 흐름을 보여준다', (tester) async {
    final api = _FakeShellAgentApi();
    final controller = AppController(api: api);

    await controller.initialize();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: WorkspaceFileSheet(
            controller: controller,
            path: 'README.md',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Cursor에서 열기'), findsOneWidget);
    expect(find.textContaining('# 데모 작업공간'), findsOneWidget);

    final saved = await controller.saveWorkspaceFile(
      'README.md',
      '# 데모 작업공간\n\n모바일에서 바로 수정한 내용입니다.\n',
    );
    await tester.pumpAndSettle();

    expect(saved.content, contains('모바일에서 바로 수정한 내용'));
    expect(controller.workspaceFile.content, contains('모바일에서 바로 수정한 내용'));
    expect(api.lastSessionUpdateId, 'session-auth');

    controller.dispose();
    await tester.pump();
  });

  testWidgets('세션 복구 배너와 로그를 보여준다', (tester) async {
    final controller = AppController(api: _FakeShellAgentApi());
    addTearDown(controller.dispose);

    controller.currentThreadId = 'thread-auth';
    controller.sessionSyncStatus = SessionSyncStatus.failed;
    controller.sessionSyncDetail =
        '세션 동기화 요청이 실패했습니다. [503] session stream closed';
    controller.debugPushSessionSyncLog(
      kind: 'stale',
      title: '멈춤 감지',
      detail: '마지막 동기화 이후 새 업데이트가 없어 복구를 시도합니다.',
    );
    controller.debugPushSessionSyncLog(
      kind: 'failed',
      title: '복구 실패',
      detail: '세션 동기화 요청이 실패했습니다. [503] session stream closed',
    );

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PromptScreen(controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('다음 액션'), findsOneWidget);
    expect(find.text('복구 로그'), findsOneWidget);
    expect(find.text('멈춤 감지'), findsOneWidget);
    expect(find.text('복구 실패'), findsOneWidget);
    expect(
      find.textContaining('마지막 작업 위치를 확인한 뒤 다시 연결하거나'),
      findsOneWidget,
    );
  });
}

class _FakeShellAgentApi extends AgentApi {
  _FakeShellAgentApi();

  final Map<String, String> _workspaceFiles = {
    'README.md': '# 데모 작업공간\n\n초기 안내 문서입니다.\n',
    'reports/demo.md': '작업 로그 초안\n',
  };
  String? lastSessionUpdateId;

  @override
  Future<Map<String, dynamic>> bootstrap(String baseUrl) async {
    return {
      'agentBaseUrl': 'http://127.0.0.1:8080',
      'signalingBaseUrl': 'http://127.0.0.1:8081',
      'workspaceRoot': 'C:/demo/workspace',
      'currentThreadId': 'thread-auth',
      'adapter': {
        'name': 'mock-cursor',
        'mode': 'mock',
        'provider': 'cursor',
        'ready': true,
      },
      'recentThreads': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> p2pStatus(String baseUrl) async {
    return {
      'active': false,
      'sessionId': '',
      'pairingCode': '',
      'state': 'PAIRING',
    };
  }

  @override
  Future<Map<String, dynamic>> runtimeState(String baseUrl) async {
    return {
      'state': 'CONNECTED',
      'history': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> runtimeMetrics(String baseUrl) async {
    return {
      'state': 'CONNECTED',
      'ack': {
        'pendingCount': 0,
        'maxPendingCount': 0,
        'pendingByTransport': {
          'http': 0,
          'p2p': 0,
          'unknown': 0,
        },
        'ackedCount': 0,
        'retryDispatchCount': 0,
        'expiredCount': 0,
        'exhaustedCount': 0,
        'lastAckRttMs': 0,
        'avgAckRttMs': 0,
        'maxAckRttMs': 0,
      },
    };
  }

  @override
  Future<Map<String, dynamic>> runtimeAdapter(String baseUrl) async {
    return {
      'name': 'mock-cursor',
      'mode': 'mock',
      'provider': 'cursor',
      'ready': true,
      'workspaceRoot': 'C:/demo/workspace',
      'binaryPath': 'node',
      'notes': const <String>[],
    };
  }

  @override
  Future<Map<String, dynamic>> runProfiles(String baseUrl) async {
    return {
      'profiles': const [
        {
          'id': 'test_all',
          'label': '데모 점검',
          'command': 'git status --short',
          'scope': 'SMALL',
          'optional': false,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> sessions(String baseUrl) async {
    return {
      'threads': [
        {
          'id': 'thread-auth',
          'title': '인증 미들웨어 실패',
          'sessionId': 'session-auth',
          'state': 'running',
          'currentJobId': 'job-auth',
          'lastEventKind': 'assistant',
          'lastEventText': '코드 변경 전에 실패한 인증 경로를 먼저 좁히는 중입니다.',
          'updatedAt': 1710601200000,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(
    String baseUrl,
    String sessionId,
  ) async {
    return {
      'thread': {
        'id': 'thread-auth',
        'title': '인증 미들웨어 실패',
        'sessionId': 'session-auth',
        'state': 'running',
        'currentJobId': 'job-auth',
        'lastEventKind': 'assistant',
        'lastEventText': '코드 변경 전에 실패한 인증 경로를 먼저 좁히는 중입니다.',
        'updatedAt': 1710601200000,
      },
      'events': [
        {
          'id': 'event-user',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'user_prompt',
          'role': 'user',
          'title': '요청',
          'body': '인증 미들웨어 실패 원인을 분석하고 가장 작은 패치를 제안해줘.',
          'data': const <String, dynamic>{},
          'at': 1710601200000,
        },
        {
          'id': 'event-assistant',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'assistant_summary',
          'role': 'assistant',
          'title': '어시스턴트',
          'body': '먼저 인증 가드와 최근 실패 테스트 출력을 확인하고 있습니다.',
          'data': const <String, dynamic>{},
          'at': 1710601260000,
        },
        {
          'id': 'event-patch',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'patch_ready',
          'role': 'assistant',
          'title': '패치 준비',
          'body': '인증 미들웨어 상태 카드만 먼저 정리하는 초안입니다.',
          'data': {
            'summary': '인증 미들웨어 상태 카드를 한 파일에서만 먼저 정리합니다.',
            'files': [
              {
                'path': 'mobile/flutter_app/lib/app.dart',
                'status': 'modified',
                'hunks': [
                  {
                    'hunkId': 'hunk-1',
                    'header': '@@ build status card @@',
                    'diff': '- old status card\n+ compact status card',
                    'risk': 'low',
                  },
                ],
              },
            ],
            'fileCount': 1,
          },
          'at': 1710601265000,
        },
        {
          'id': 'event-run-requested',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'run_requested',
          'role': 'system',
          'title': '실행 요청',
          'body': '실패한 인증 케이스만 다시 확인합니다.',
          'data': {
            'profileId': 'test_all',
            'label': '데모 점검',
            'command': 'npm test -- --failed',
          },
          'at': 1710601270000,
        },
        {
          'id': 'event-run-finished',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'run_finished',
          'role': 'system',
          'title': '실행 결과',
          'body': '인증 미들웨어 테스트가 아직 실패합니다.',
          'data': {
            'status': 'failed',
            'profileId': 'test_all',
            'summary': '인증 미들웨어 테스트가 아직 실패합니다.',
            'excerpt': 'FAIL auth middleware\nexpected 200 but got 401',
            'output':
                'FAIL auth middleware\nexpected 200 but got 401\nat middleware/auth_test.dart:27',
            'topErrors': [
              {
                'path': 'middleware/auth_test.dart',
                'line': 27,
                'message': 'expected 200 but got 401',
              },
            ],
          },
          'at': 1710601275000,
        },
      ],
      'liveState': {
        'composer': {
          'draftText': 'Cursor 공유 초안',
          'isTyping': true,
          'updatedAt': 1710601265000,
        },
        'focus': {
          'activeFilePath': 'README.md',
          'selection': '인증 미들웨어',
          'updatedAt': 1710601270000,
        },
        'activity': {
          'phase': 'analysis',
          'summary': '코드 수정 전에 인증 미들웨어 실패를 진단하는 중입니다.',
          'updatedAt': 1710601275000,
        },
        'reasoning': {
          'title': '판단 요약',
          'summary': '패치가 미들웨어 한 파일만 건드리도록 먼저 실패 경로를 확인합니다.',
          'sourceKind': 'manual',
          'updatedAt': 1710601280000,
        },
        'plan': {
          'summary': '인증 계획',
          'items': [
            {
              'id': 'inspect-test',
              'label': '실패한 인증 테스트 확인',
              'status': 'completed',
              'detail': '',
              'updatedAt': 1710601285000,
            },
            {
              'id': 'check-middleware',
              'label': '인증 미들웨어 가드 확인',
              'status': 'in_progress',
              'detail': '',
              'updatedAt': 1710601290000,
            },
          ],
          'updatedAt': 1710601290000,
        },
        'tools': {
          'currentLabel': '파일 검색',
          'currentStatus': 'in_progress',
          'activities': [
            {
              'kind': 'search',
              'label': '파일 검색',
              'status': 'in_progress',
              'detail': '인증 미들웨어 참조를 찾는 중',
              'at': 1710601295000,
            },
          ],
          'updatedAt': 1710601295000,
        },
        'terminal': {
          'status': 'failed',
          'profileId': 'test_all',
          'label': '데모 점검',
          'command': 'npm test -- --failed',
          'summary': '인증 미들웨어 테스트가 아직 실패합니다.',
          'excerpt': 'FAIL auth middleware\nexpected 200 but got 401',
          'output':
              'FAIL auth middleware\nexpected 200 but got 401\nat middleware/auth_test.dart:27',
          'updatedAt': 1710601300000,
        },
        'workspace': {
          'rootPath': 'C:/demo/workspace',
          'activeFilePath': 'README.md',
          'patchFiles': ['mobile/flutter_app/lib/app.dart'],
          'changedFiles': ['README.md', 'mobile/flutter_app/lib/app.dart'],
          'updatedAt': 1710601305000,
        },
      },
      'operationState': {
        'currentJobId': 'job-auth',
        'phase': 'analysis',
        'patchSummary': '패치는 아직 준비되지 않았습니다. 에이전트가 인증 미들웨어 변경 범위를 좁히는 중입니다.',
        'patchFileCount': 1,
        'patchFiles': ['mobile/flutter_app/lib/app.dart'],
        'patchResultStatus': '',
        'patchResultMessage': '',
        'runProfileId': 'test_all',
        'runLabel': '데모 점검',
        'runCommand': 'npm test -- --failed',
        'runStatus': 'failed',
        'runSummary': '인증 미들웨어 테스트가 아직 실패합니다.',
        'runExcerpt': 'FAIL auth middleware\nexpected 200 but got 401',
        'runOutput':
            'FAIL auth middleware\nexpected 200 but got 401\nat middleware/auth_test.dart:27',
        'runChangedFiles': ['README.md'],
        'runTopErrors': [
          {
            'path': 'middleware/auth_test.dart',
            'line': 27,
            'message': 'expected 200 but got 401',
          },
        ],
        'currentJobFiles': ['README.md', 'mobile/flutter_app/lib/app.dart'],
        'lastError': 'expected 200 but got 401',
      },
    };
  }

  @override
  Stream<Map<String, dynamic>> sessionStream(
    String baseUrl,
    String sessionId,
  ) {
    return const Stream<Map<String, dynamic>>.empty();
  }

  @override
  Future<Map<String, dynamic>> updateSessionLiveState(
    String baseUrl,
    String sessionId,
    Map<String, dynamic> update,
  ) async {
    lastSessionUpdateId = sessionId;
    return sessionDetail(baseUrl, sessionId);
  }

  @override
  Future<Map<String, dynamic>> threads(String baseUrl) {
    return sessions(baseUrl);
  }

  @override
  Future<Map<String, dynamic>> threadDetail(String baseUrl, String threadId) {
    return sessionDetail(baseUrl, threadId);
  }

  @override
  Future<Map<String, dynamic>> workspaceTree(
    String baseUrl, {
    String path = '',
    String? sessionId,
  }) async {
    if (path == 'reports') {
      return {
        'rootPath': 'C:/demo/workspace',
        'path': 'reports',
        'entries': [
          {
            'name': 'demo.md',
            'path': 'reports/demo.md',
            'isDir': false,
            'gitStatus': 'U',
            'isChanged': true,
          },
        ],
      };
    }

    return {
      'rootPath': 'C:/demo/workspace',
      'path': '',
      'entries': [
        {
          'name': 'reports',
          'path': 'reports',
          'isDir': true,
        },
        {
          'name': 'README.md',
          'path': 'README.md',
          'isDir': false,
          'gitStatus': 'M',
          'isActive': true,
          'isChanged': true,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> workspaceFile(
    String baseUrl,
    String path,
  ) async {
    final normalized = path.trim();
    return {
      'path': normalized,
      'content': _workspaceFiles[normalized] ?? '',
      'gitStatus': normalized == 'README.md' ? 'M' : 'U',
      'sizeBytes': (_workspaceFiles[normalized] ?? '').length,
      'updatedAt': 1710601305000,
      'isWritable': true,
    };
  }

  @override
  Future<Map<String, dynamic>> saveWorkspaceFile(
    String baseUrl,
    String path,
    String content,
  ) async {
    final normalized = path.trim();
    _workspaceFiles[normalized] = content;
    return workspaceFile(baseUrl, normalized);
  }

  @override
  void dispose() {}
}
