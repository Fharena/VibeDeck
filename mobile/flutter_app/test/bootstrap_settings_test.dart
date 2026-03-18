import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/services/app_settings_store.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';

void main() {
  test('loads bootstrap defaults and remembers recent hosts', () async {
    final settingsStore = InMemoryAppSettingsStore();
    final controller = AppController(
      api: FakeBootstrapAgentApi(),
      settingsStore: settingsStore,
    );

    await controller.initialize();

    expect(controller.agentBaseUrl, 'http://192.168.0.24:8080');
    expect(controller.signalingBaseUrl, 'http://192.168.0.24:8081');
    expect(controller.bootstrap.workspaceRoot, 'C:/demo/workspace');
    expect(controller.bootstrap.adapter.provider, 'cursor');
    expect(controller.currentThreadId, 'thread-bootstrap-1');
    expect(controller.currentSharedSessionId, 'sid-bootstrap');
    expect(controller.recentHosts, hasLength(1));
    expect(controller.recentHosts.single.agentBaseUrl, 'http://192.168.0.24:8080');
    expect(
      controller.recentHosts.single.signalingBaseUrl,
      'http://192.168.0.24:8081',
    );

    final restored = AppController(
      api: FakeBootstrapAgentApi(),
      settingsStore: settingsStore,
    );

    await restored.initialize();

    expect(restored.agentBaseUrl, 'http://192.168.0.24:8080');
    expect(restored.signalingBaseUrl, 'http://192.168.0.24:8081');
    expect(restored.recentHosts, isNotEmpty);

    restored.dispose();
    controller.dispose();
  });
}

class FakeBootstrapAgentApi extends AgentApi {
  @override
  Future<Map<String, dynamic>> bootstrap(String baseUrl) async {
    return {
      'agentBaseUrl': 'http://192.168.0.24:8080',
      'signalingBaseUrl': 'http://192.168.0.24:8081',
      'workspaceRoot': 'C:/demo/workspace',
      'currentThreadId': 'thread-bootstrap-1',
      'currentSessionId': 'sid-bootstrap',
      'adapter': {
        'name': 'cursor-agent-cli',
        'mode': 'cursor_agent_cli',
        'provider': 'cursor',
        'ready': true,
      },
      'recentThreads': [
        {
          'id': 'thread-bootstrap-1',
          'title': '최근 작업',
          'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
          'current': true,
        },
      ],
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
      'notes': const ['bootstrap test adapter'],
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
          'id': 'thread-bootstrap-1',
          'title': '최근 작업',
          'sessionId': 'sid-bootstrap',
          'state': 'draft',
          'currentJobId': '',
          'lastEventKind': '',
          'lastEventText': '',
          'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> threads(String baseUrl) async {
    return {
      'threads': [
        {
          'id': 'thread-bootstrap-1',
          'title': '최근 작업',
          'sessionId': 'sid-bootstrap',
          'state': 'draft',
          'currentJobId': '',
          'lastEventKind': '',
          'lastEventText': '',
          'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(String baseUrl, String sessionId) async {
    return {
      'thread': {
        'id': 'thread-bootstrap-1',
        'title': '최근 작업',
        'sessionId': 'sid-bootstrap',
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
      },
      'events': const [],
      'liveState': const <String, dynamic>{},
      'operationState': const <String, dynamic>{},
    };
  }

  @override
  Stream<Map<String, dynamic>> sessionStream(String baseUrl, String sessionId) {
    return const Stream<Map<String, dynamic>>.empty();
  }

  @override
  Future<Map<String, dynamic>> updateSessionLiveState(
    String baseUrl,
    String sessionId,
    Map<String, dynamic> update,
  ) async {
    return {
      'thread': {
        'id': 'thread-bootstrap-1',
        'title': '최근 작업',
        'sessionId': 'sid-bootstrap',
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
      },
      'events': const [],
      'liveState': {
        'participant': {
          'participantId': 'mobile-test',
          'clientType': 'mobile',
          'displayName': 'VibeDeck Mobile',
          'active': true,
          'lastSeenAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
        },
      },
      'operationState': const <String, dynamic>{},
    };
  }

  @override
  Future<Map<String, dynamic>> threadDetail(String baseUrl, String threadId) async {
    return {
      'thread': {
        'id': threadId,
        'title': '최근 작업',
        'sessionId': 'sid-bootstrap',
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 20, 45).millisecondsSinceEpoch,
      },
      'events': const [],
    };
  }

  @override
  void dispose() {}
}
