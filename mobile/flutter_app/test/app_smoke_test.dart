import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/app.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';
import 'package:vibedeck_mobile/state/app_controller.dart';

void main() {
  testWidgets('shows drawer-based mobile shell flow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final controller = AppController(api: _FakeShellAgentApi());
    addTearDown(controller.dispose);

    await tester.pumpWidget(VibeDeckApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('VibeDeck Mobile'), findsNothing);
    expect(find.text('Auth middleware failure'), findsOneWidget);
    expect(find.text('Current Work'), findsOneWidget);
    expect(find.text('Activity Feed'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.menu_rounded));
    await tester.pumpAndSettle();

    expect(find.text('Search Sessions...'), findsOneWidget);
    expect(find.text('New Agent'), findsOneWidget);
    expect(find.text('Sessions'), findsWidgets);
    expect(find.text('Files'), findsOneWidget);
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Auth middleware failure'), findsWidgets);

    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();

    expect(find.text('README.md'), findsWidgets);

    await tester.tap(find.text('Settings'));
    await tester.pumpAndSettle();

    expect(find.text('Open Session Center'), findsOneWidget);
    expect(find.text('Open Terminal'), findsOneWidget);

    await tester.tap(find.text('Open Session Center'));
    await tester.pumpAndSettle();

    expect(find.text('Session Center'), findsOneWidget);
  });
}

class _FakeShellAgentApi extends AgentApi {
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
          'id': 'thread-auth',
          'title': 'Auth middleware failure',
          'sessionId': 'session-auth',
          'state': 'running',
          'currentJobId': 'job-auth',
          'lastEventKind': 'assistant',
          'lastEventText':
              'Narrowing the failing auth path before changing code.',
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
        'title': 'Auth middleware failure',
        'sessionId': 'session-auth',
        'state': 'running',
        'currentJobId': 'job-auth',
        'lastEventKind': 'assistant',
        'lastEventText':
            'Narrowing the failing auth path before changing code.',
        'updatedAt': 1710601200000,
      },
      'events': [
        {
          'id': 'event-user',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'user_prompt',
          'role': 'user',
          'title': 'Prompt',
          'body':
              'Analyze the auth middleware failure and propose the smallest patch.',
          'data': const <String, dynamic>{},
          'at': 1710601200000,
        },
        {
          'id': 'event-assistant',
          'threadId': 'thread-auth',
          'jobId': 'job-auth',
          'kind': 'assistant_summary',
          'role': 'assistant',
          'title': 'Assistant',
          'body':
              'Checking the auth guard and recent failing test output first.',
          'data': const <String, dynamic>{},
          'at': 1710601260000,
        },
      ],
      'liveState': {
        'composer': {
          'draftText': 'Shared draft from Cursor',
          'isTyping': true,
          'updatedAt': 1710601265000,
        },
        'focus': {
          'activeFilePath': 'README.md',
          'selection': 'auth middleware',
          'updatedAt': 1710601270000,
        },
        'activity': {
          'phase': 'analysis',
          'summary':
              'Diagnosing the auth middleware failure before editing code.',
          'updatedAt': 1710601275000,
        },
        'reasoning': {
          'title': 'Reasoning',
          'summary':
              'Confirm the failing auth path first so the patch only touches one middleware file.',
          'sourceKind': 'manual',
          'updatedAt': 1710601280000,
        },
        'plan': {
          'summary': 'Auth plan',
          'items': [
            {
              'id': 'inspect-test',
              'label': 'Inspect the failing auth test',
              'status': 'completed',
              'detail': '',
              'updatedAt': 1710601285000,
            },
            {
              'id': 'check-middleware',
              'label': 'Check the auth middleware guard',
              'status': 'in_progress',
              'detail': '',
              'updatedAt': 1710601290000,
            },
          ],
          'updatedAt': 1710601290000,
        },
        'tools': {
          'currentLabel': 'Search files',
          'currentStatus': 'in_progress',
          'activities': [
            {
              'kind': 'search',
              'label': 'Search files',
              'status': 'in_progress',
              'detail': 'Looking for auth middleware references',
              'at': 1710601295000,
            },
          ],
          'updatedAt': 1710601295000,
        },
        'terminal': {
          'status': 'idle',
          'profileId': 'test_all',
          'label': 'Demo Check',
          'command': 'git status --short',
          'summary': 'Waiting to run after patch review.',
          'excerpt': '',
          'output': '',
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
        'patchSummary':
            'Patch is not ready yet. The agent is still narrowing the auth middleware change.',
        'patchFileCount': 1,
        'patchFiles': ['mobile/flutter_app/lib/app.dart'],
        'patchResultStatus': '',
        'patchResultMessage': '',
        'runProfileId': 'test_all',
        'runLabel': 'Demo Check',
        'runCommand': 'git status --short',
        'runStatus': '',
        'runSummary': 'Waiting to run after patch review.',
        'runExcerpt': '',
        'runOutput': '',
        'runChangedFiles': ['README.md'],
        'runTopErrors': const [],
        'currentJobFiles': ['README.md', 'mobile/flutter_app/lib/app.dart'],
        'lastError': '',
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
  void dispose() {}
}
