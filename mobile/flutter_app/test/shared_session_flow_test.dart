import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';

void main() {
  test('loads shared session summaries and detail from session api', () async {
    final api = FakeSharedSessionAgentApi();
    final controller = AppController(api: api);

    addTearDown(controller.dispose);

    await controller.refreshStatus();

    expect(controller.currentThreadId, 'thread-shared-1');
    expect(controller.currentThreadTitle, 'shared session thread');
    expect(controller.currentSharedSessionId, 'thread-shared-1');
    expect(controller.currentJobId, 'job-shared-1');
    expect(controller.patchSummary, 'shared session patch ready');
    expect(controller.patchFiles, hasLength(1));
    expect(controller.patchFiles.single.path, 'lib/session.dart');
    expect(controller.threadEvents, hasLength(2));
    expect(controller.sessionSyncStatus, SessionSyncStatus.live);
    expect(controller.sessionLastSyncedAt, greaterThan(0));
    expect(api.sessionDetailRequests, contains('thread-shared-1'));
  });

  test('applies live session stream updates', () async {
    final api = FakeSharedSessionAgentApi();
    final controller = AppController(api: api);

    addTearDown(controller.dispose);

    await controller.refreshStatus();
    api.pushLiveDraft('cursor live draft');
    await Future<void>.delayed(const Duration(milliseconds: 20));

    expect(controller.liveDraftPreview, 'cursor live draft');
    expect(controller.liveComposerTyping, isTrue);
    expect(controller.liveParticipantCount, 1);
    expect(controller.liveActivitySummary, 'Cursor에서 초안 작성 중');
  });

  test('marks sync failed after stream interruption and recovers on retry',
      () async {
    final api = FakeSharedSessionAgentApi();
    final controller = AppController(
      api: api,
      sessionSyncReconnectDelay: const Duration(milliseconds: 10),
      sessionSyncMaxReconnectAttempts: 1,
    );

    addTearDown(controller.dispose);

    await controller.refreshStatus();
    api.failSessionDetail = true;
    api.emitStreamError('sleep-resume disconnect');
    await Future<void>.delayed(const Duration(milliseconds: 80));

    expect(controller.sessionSyncStatus, SessionSyncStatus.failed);
    expect(controller.sessionSyncDetail, contains('세션 동기화 요청이 실패했습니다.'));

    api.failSessionDetail = false;
    await controller.retrySessionSync();

    expect(controller.sessionSyncStatus, SessionSyncStatus.live);
    expect(controller.sessionSyncDetail, isEmpty);
  });
}

class FakeSharedSessionAgentApi extends AgentApi {
  final StreamController<Map<String, dynamic>> _streamController =
      StreamController<Map<String, dynamic>>.broadcast();
  late Map<String, dynamic> _detail = _buildDetail();
  final List<String> sessionDetailRequests = <String>[];
  bool failSessionDetail = false;

  @override
  Future<Map<String, dynamic>> bootstrap(String baseUrl) async {
    return {
      'agentBaseUrl': 'http://192.168.0.24:8080',
      'signalingBaseUrl': 'http://192.168.0.24:8081',
      'workspaceRoot': 'C:/demo/workspace',
      'currentThreadId': '',
      'currentSessionId': 'thread-shared-1',
      'adapter': {
        'name': 'cursor-agent-cli',
        'mode': 'cursor_agent_cli',
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
      'state': 'PAIRING',
      'history': const [],
    };
  }

  @override
  Future<Map<String, dynamic>> runtimeMetrics(String baseUrl) async {
    return {
      'state': 'PAIRING',
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
      'name': 'cursor-agent-cli',
      'mode': 'cursor_agent_cli',
      'ready': true,
      'workspaceRoot': 'C:/demo/workspace',
      'binaryPath': '/home/demo/.local/bin/cursor-agent',
      'notes': const <String>[],
    };
  }

  @override
  Future<Map<String, dynamic>> runProfiles(String baseUrl) async {
    return {
      'profiles': const [
        {
          'id': 'test_all',
          'label': 'Demo Check',
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
          'id': 'thread-shared-1',
          'title': 'shared session thread',
          'sessionId': 'thread-shared-1',
          'controlSessionId': 'sid-shared-control',
          'state': 'reviewing',
          'currentJobId': 'job-shared-1',
          'lastEventKind': 'patch_ready',
          'lastEventText': 'shared session patch ready',
          'updatedAt': DateTime(2026, 3, 9, 21, 10).millisecondsSinceEpoch,
        },
      ],
      'sessions': [
        {
          'id': 'session-shared-1',
          'threadId': 'thread-shared-1',
          'controlSessionId': 'sid-shared-control',
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(
      String baseUrl, String sessionId) async {
    sessionDetailRequests.add(sessionId);
    if (failSessionDetail) {
      throw AgentApiException(503, 'session sync unavailable');
    }
    return _detail;
  }

  @override
  Stream<Map<String, dynamic>> sessionStream(String baseUrl, String sessionId) {
    return _streamController.stream;
  }

  @override
  Future<Map<String, dynamic>> updateSessionLiveState(
    String baseUrl,
    String sessionId,
    Map<String, dynamic> update,
  ) async {
    final liveState = Map<String, dynamic>.from(_detail['liveState'] as Map);
    final participant = update['participant'];
    if (participant is Map<String, dynamic>) {
      liveState['participants'] = [participant];
    }
    final composer = update['composer'];
    if (composer is Map<String, dynamic>) {
      liveState['composer'] = composer;
    }
    final focus = update['focus'];
    if (focus is Map<String, dynamic>) {
      liveState['focus'] = focus;
    }
    final activity = update['activity'];
    if (activity is Map<String, dynamic>) {
      liveState['activity'] = activity;
    }
    _detail = {
      ..._detail,
      'liveState': liveState,
    };
    return _detail;
  }

  void emitStreamError(String message) {
    _streamController.addError(AgentApiException(503, message));
  }

  void pushLiveDraft(String draft) {
    final updatedAt = DateTime(2026, 3, 9, 21, 11).millisecondsSinceEpoch;
    _detail = {
      ..._detail,
      'liveState': {
        'participants': [
          {
            'participantId': 'cursor-panel',
            'clientType': 'cursor_panel',
            'displayName': 'Cursor Panel',
            'active': true,
            'lastSeenAt': updatedAt,
          },
        ],
        'composer': {
          'draftText': draft,
          'isTyping': true,
          'updatedAt': updatedAt,
        },
        'focus': {
          'activeFilePath': 'lib/session.dart',
          'selection': 'buildSession',
          'updatedAt': updatedAt,
        },
        'activity': {
          'phase': 'composing',
          'summary': 'Cursor에서 초안 작성 중',
          'updatedAt': updatedAt,
        },
      },
    };
    _streamController.add(_detail);
  }

  Map<String, dynamic> _buildDetail() {
    final updatedAt = DateTime(2026, 3, 9, 21, 10).millisecondsSinceEpoch;
    return {
      'session': {
        'id': 'session-shared-1',
        'threadId': 'thread-shared-1',
        'controlSessionId': 'sid-shared-control',
        'title': 'shared session thread',
        'phase': 'reviewing',
        'currentJobId': 'job-shared-1',
        'lastEventKind': 'patch_ready',
        'lastEventText': 'shared session patch ready',
        'updatedAt': updatedAt,
      },
      'thread': {
        'id': 'thread-shared-1',
        'title': 'shared session thread',
        'sessionId': 'thread-shared-1',
        'controlSessionId': 'sid-shared-control',
        'state': 'reviewing',
        'currentJobId': 'job-shared-1',
        'lastEventKind': 'patch_ready',
        'lastEventText': 'shared session patch ready',
        'updatedAt': updatedAt,
      },
      'liveState': {
        'participants': const <Map<String, dynamic>>[],
        'composer': const <String, dynamic>{},
        'focus': const <String, dynamic>{},
        'activity': const <String, dynamic>{},
      },
      'operationState': {
        'currentJobId': 'job-shared-1',
        'phase': 'reviewing',
        'patchSummary': 'shared session patch ready',
        'currentJobFiles': const ['lib/session.dart'],
      },
      'events': [
        {
          'id': 'evt-shared-prompt',
          'threadId': 'thread-shared-1',
          'jobId': 'job-shared-1',
          'kind': 'prompt_submitted',
          'role': 'user',
          'title': '프롬프트 제출',
          'body': 'shared session prompt',
          'data': const {},
          'at': updatedAt - 1000,
        },
        {
          'id': 'evt-shared-patch',
          'threadId': 'thread-shared-1',
          'jobId': 'job-shared-1',
          'kind': 'patch_ready',
          'role': 'assistant',
          'title': '패치 준비 완료',
          'body': 'shared session patch ready',
          'data': {
            'summary': 'shared session patch ready',
            'files': [
              {
                'path': 'lib/session.dart',
                'status': 'modified',
                'hunks': [
                  {
                    'hunkId': 'hunk-shared-1',
                    'header': '@@ -1 +1 @@',
                    'diff': '+shared-session',
                    'risk': 'LOW',
                  },
                ],
              },
            ],
          },
          'at': updatedAt,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> threads(String baseUrl) async {
    throw UnsupportedError('legacy threads api should not be used');
  }

  @override
  Future<Map<String, dynamic>> threadDetail(
      String baseUrl, String threadId) async {
    throw UnsupportedError('legacy thread detail api should not be used');
  }

  @override
  void dispose() {
    unawaited(_streamController.close());
  }
}
