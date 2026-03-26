import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/app.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/services/bootstrap_link_source.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';

void main() {
  testWidgets('applies initial bootstrap deep link on startup', (tester) async {
    final controller = AppController(api: _FakeBootstrapLinkAgentApi());
    final linkSource = FakeBootstrapLinkSource(
      initialUri: Uri.parse(
        'vibedeck://bootstrap?agent=http%3A%2F%2F192.168.0.24%3A8080&signaling=http%3A%2F%2F192.168.0.24%3A8081&thread=thread-link-1&session=sid-link-1',
      ),
    );

    addTearDown(linkSource.dispose);

    await tester.pumpWidget(
      VibeDeckApp(
        controller: controller,
        bootstrapLinkSource: linkSource,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(controller.agentBaseUrl, 'http://192.168.0.24:8080');
    expect(controller.signalingBaseUrl, 'http://192.168.0.24:8081');
    expect(controller.currentThreadId, 'thread-link-1');
    expect(controller.currentSharedSessionId, 'sid-link-1');
    expect(controller.recentHosts, isNotEmpty);

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });

  testWidgets('applies incoming bootstrap deep link while app is open', (
    tester,
  ) async {
    final controller = AppController(api: _FakeBootstrapLinkAgentApi());
    final linkSource = FakeBootstrapLinkSource();

    addTearDown(linkSource.dispose);

    await tester.pumpWidget(
      VibeDeckApp(
        controller: controller,
        bootstrapLinkSource: linkSource,
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    linkSource.push(
      Uri.parse(
        'vibedeck://bootstrap?agent=http%3A%2F%2F10.0.0.55%3A8080&signaling=http%3A%2F%2F10.0.0.55%3A8081&thread=thread-link-2&session=sid-link-2',
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(controller.agentBaseUrl, 'http://10.0.0.55:8080');
    expect(controller.signalingBaseUrl, 'http://10.0.0.55:8081');
    expect(controller.currentThreadId, 'thread-link-2');
    expect(controller.currentSharedSessionId, 'sid-link-2');

    await tester.pumpWidget(const SizedBox.shrink());
    controller.dispose();
    await tester.pump();
  });
}

class FakeBootstrapLinkSource implements BootstrapLinkSource {
  FakeBootstrapLinkSource({this.initialUri});

  final Uri? initialUri;
  final StreamController<Uri> _controller = StreamController<Uri>.broadcast();

  @override
  Future<Uri?> getInitialUri() async => initialUri;

  @override
  Stream<Uri> get uriStream => _controller.stream;

  void push(Uri uri) {
    _controller.add(uri);
  }

  Future<void> dispose() async {
    await _controller.close();
  }
}

class _FakeBootstrapLinkAgentApi extends AgentApi {
  @override
  Future<Map<String, dynamic>> bootstrap(String baseUrl) async {
    final isLan = baseUrl.contains('192.168.0.24') || baseUrl.contains('10.0.0.55');
    final resolvedBaseUrl = isLan ? baseUrl : 'http://127.0.0.1:8080';
    final resolvedSignaling = resolvedBaseUrl
        .replaceFirst(':8080', ':8081')
        .replaceFirst('127.0.0.1', isLan ? Uri.parse(baseUrl).host : '127.0.0.1');
    return {
      'agentBaseUrl': resolvedBaseUrl,
      'signalingBaseUrl': resolvedSignaling,
      'workspaceRoot': 'C:/demo/workspace',
      'currentThreadId': 'thread-link-1',
      'currentSessionId': 'sid-link-1',
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
          'id': baseUrl.contains('10.0.0.55') ? 'thread-link-2' : 'thread-link-1',
          'title': 'link thread',
          'sessionId': baseUrl.contains('10.0.0.55') ? 'sid-link-2' : 'sid-link-1',
          'state': 'draft',
          'currentJobId': '',
          'lastEventKind': '',
          'lastEventText': '',
          'updatedAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> threads(String baseUrl) async {
    return {
      'threads': [
        {
          'id': baseUrl.contains('10.0.0.55') ? 'thread-link-2' : 'thread-link-1',
          'title': 'link thread',
          'sessionId': baseUrl.contains('10.0.0.55') ? 'sid-link-2' : 'sid-link-1',
          'state': 'draft',
          'currentJobId': '',
          'lastEventKind': '',
          'lastEventText': '',
          'updatedAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> sessionDetail(String baseUrl, String sessionId) async {
    final threadId = baseUrl.contains('10.0.0.55') ? 'thread-link-2' : 'thread-link-1';
    final resolvedSessionId = baseUrl.contains('10.0.0.55') ? 'sid-link-2' : 'sid-link-1';
    return {
      'thread': {
        'id': threadId,
        'title': 'link thread',
        'sessionId': resolvedSessionId,
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
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
    final threadId = sessionId == 'sid-link-2' ? 'thread-link-2' : 'thread-link-1';
    return {
      'thread': {
        'id': threadId,
        'title': 'link thread',
        'sessionId': sessionId,
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
      },
      'events': const [],
      'liveState': {
        'participant': {
          'participantId': 'mobile-test',
          'clientType': 'mobile',
          'displayName': 'VibeDeck Mobile',
          'active': true,
          'lastSeenAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
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
        'title': 'link thread',
        'sessionId': threadId == 'thread-link-2' ? 'sid-link-2' : 'sid-link-1',
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': DateTime(2026, 3, 8, 21, 15).millisecondsSinceEpoch,
      },
      'events': const [],
    };
  }

  @override
  void dispose() {}
}
