import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:vibedeck_mobile/services/agent_api.dart';

void main() {
  test('shared session api keeps real session id instead of control session id',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final requests = <String>[];

    server.listen((request) async {
      requests.add(request.uri.path);
      request.response.headers.contentType = ContentType.json;

      if (request.method == 'GET' && request.uri.path == '/v1/agent/sessions') {
        request.response.write(
          jsonEncode({
            'sessions': [
              {
                'id': 'thread-shared-1',
                'threadId': 'thread-shared-1',
                'controlSessionId': 'sid-shared-control',
                'title': 'shared session thread',
                'phase': 'reviewing',
                'currentJobId': 'job-shared-1',
                'lastEventKind': 'patch_ready',
                'lastEventText': 'shared session patch ready',
                'updatedAt': 1773067800000,
              },
            ],
          }),
        );
        await request.response.close();
        return;
      }

      if (request.method == 'GET' &&
          request.uri.path == '/v1/agent/sessions/thread-shared-1') {
        request.response.write(
          jsonEncode({
            'session': {
              'id': 'thread-shared-1',
              'threadId': 'thread-shared-1',
              'controlSessionId': 'sid-shared-control',
              'title': 'shared session thread',
              'phase': 'reviewing',
              'currentJobId': 'job-shared-1',
              'lastEventKind': 'patch_ready',
              'lastEventText': 'shared session patch ready',
              'updatedAt': 1773067800000,
            },
            'timeline': const [],
            'liveState': const <String, dynamic>{},
            'operationState': const <String, dynamic>{},
          }),
        );
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      request.response.write(jsonEncode({'error': 'not found'}));
      await request.response.close();
    });

    addTearDown(() async {
      await server.close(force: true);
    });

    final api = AgentApi();
    addTearDown(api.dispose);

    final baseUrl = 'http://${server.address.address}:${server.port}';
    final sessions = await api.sessions(baseUrl);
    final thread = (sessions['threads'] as List).single as Map<String, dynamic>;

    expect(thread['id'], 'thread-shared-1');
    expect(thread['sessionId'], 'thread-shared-1');
    expect(thread['controlSessionId'], 'sid-shared-control');

    final detail = await api.sessionDetail(baseUrl, thread['sessionId'].toString());
    final detailThread = Map<String, dynamic>.from(detail['thread'] as Map);

    expect(detailThread['id'], 'thread-shared-1');
    expect(detailThread['sessionId'], 'thread-shared-1');
    expect(detailThread['controlSessionId'], 'sid-shared-control');
    expect(
      requests,
      containsAll(<String>[
        '/v1/agent/sessions',
        '/v1/agent/sessions/thread-shared-1',
      ]),
    );
  });
}
