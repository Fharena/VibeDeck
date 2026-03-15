import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/app.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';

void main() {
  testWidgets('shows streamlined session shell labels', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = AppController(api: _FakeShellAgentApi());
    addTearDown(controller.dispose);

    await tester.pumpWidget(VibeDeckApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('VibeDeck Mobile'), findsOneWidget);
    expect(find.text('공유 세션'), findsWidgets);
    expect(find.text('세션에 요청'), findsOneWidget);
    expect(find.text('세션에 보내기'), findsOneWidget);

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('지금 진행 중'), findsOneWidget);
    expect(find.text('패치와 실행'), findsOneWidget);
    expect(find.text('세션 센터'), findsOneWidget);
    expect(find.text('터미널 보기'), findsOneWidget);
    expect(find.text('파일 보기'), findsOneWidget);

    await tester.ensureVisible(find.text('터미널 보기'));
    await tester.tap(find.text('터미널 보기'));
    await tester.pumpAndSettle();

    expect(find.text('터미널'), findsOneWidget);
    expect(find.text('최근 출력'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('파일 보기'));
    await tester.tap(find.text('파일 보기'));
    await tester.pumpAndSettle();

    expect(find.text('파일 포커스'), findsOneWidget);
    expect(find.text('현재 상태'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(Scrollable).first, const Offset(0, -700));
    await tester.pumpAndSettle();

    expect(find.text('작업 로그'), findsWidgets);
  });
}

class _FakeShellAgentApi extends AgentApi {
  @override
  Future<Map<String, dynamic>> bootstrap(String baseUrl) async {
    return {
      'agentBaseUrl': 'http://127.0.0.1:8080',
      'signalingBaseUrl': 'http://127.0.0.1:8081',
      'workspaceRoot': 'C:/demo/workspace',
      'currentThreadId': '',
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
      'name': 'mock-cursor',
      'mode': 'mock',
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
          'label': 'Demo Check',
          'command': 'git status --short',
          'scope': 'SMALL',
          'optional': false,
        },
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> threads(String baseUrl) async {
    return {'threads': const []};
  }

  @override
  Future<Map<String, dynamic>> threadDetail(
      String baseUrl, String threadId) async {
    return {
      'thread': {
        'id': threadId,
        'title': '새 스레드',
        'sessionId': '',
        'state': 'draft',
        'currentJobId': '',
        'lastEventKind': '',
        'lastEventText': '',
        'updatedAt': 0,
      },
      'events': const [],
    };
  }

  @override
  void dispose() {}
}
