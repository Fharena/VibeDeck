import 'dart:convert';

import 'package:http/http.dart' as http;

class AgentApiException implements Exception {
  AgentApiException(this.statusCode, this.message, {this.responseBody});

  final int statusCode;
  final String message;
  final Map<String, dynamic>? responseBody;

  @override
  String toString() => 'AgentApiException($statusCode): $message';
}

class AgentApi {
  AgentApi({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<Map<String, dynamic>> p2pStart(
    String baseUrl, {
    String? signalingBaseUrl,
  }) {
    final body = <String, dynamic>{};
    if (signalingBaseUrl != null && signalingBaseUrl.trim().isNotEmpty) {
      body['signalingBaseUrl'] = signalingBaseUrl.trim();
    }

    return _request(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/v1/agent/p2p/start',
      body: body,
    );
  }

  Future<Map<String, dynamic>> p2pStatus(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/p2p/status',
    );
  }

  Future<Map<String, dynamic>> p2pStop(String baseUrl) {
    return _request(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/v1/agent/p2p/stop',
    );
  }

  Future<Map<String, dynamic>> runtimeState(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/runtime/state',
    );
  }

  Future<Map<String, dynamic>> pendingAcks(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/runtime/acks/pending',
    );
  }

  Future<Map<String, dynamic>> runtimeMetrics(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/runtime/metrics',
    );
  }

  Future<Map<String, dynamic>> runtimeAdapter(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/runtime/adapter',
    );
  }

  Future<Map<String, dynamic>> bootstrap(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/bootstrap',
    );
  }

  Future<Map<String, dynamic>> runProfiles(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/run-profiles',
    );
  }

  Future<Map<String, dynamic>> sessions(String baseUrl) async {
    try {
      final body = await _request(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/v1/agent/sessions',
      );
      return _normalizeSessionsResponse(body);
    } on AgentApiException catch (error) {
      if (!_shouldFallbackToThreads(error)) {
        rethrow;
      }

      final body = await threads(baseUrl);
      return {
        ...body,
        'threads': _cloneObjectList(body['threads']),
      };
    }
  }

  Future<Map<String, dynamic>> sessionDetail(
    String baseUrl,
    String sessionId,
  ) async {
    try {
      final body = await _request(
        method: 'GET',
        baseUrl: baseUrl,
        path: '/v1/agent/sessions/${Uri.encodeComponent(sessionId)}',
      );
      return _normalizeSessionDetail(body);
    } on AgentApiException catch (error) {
      if (!_shouldFallbackToThreads(error)) {
        rethrow;
      }

      final body = await threadDetail(baseUrl, sessionId);
      return {
        ...body,
        'thread': _objectValue(body['thread']),
        'events': _cloneObjectList(body['events']),
        'liveState': const <String, dynamic>{},
        'operationState': const <String, dynamic>{},
      };
    }
  }

  Stream<Map<String, dynamic>> sessionStream(
    String baseUrl,
    String sessionId,
  ) async* {
    final response = await _streamRequest(
      baseUrl: baseUrl,
      path: '/v1/agent/sessions/${Uri.encodeComponent(sessionId)}/stream',
    );
    yield* _decodeSseEvents(response).map(_normalizeSessionDetail);
  }

  Future<Map<String, dynamic>> updateSessionLiveState(
    String baseUrl,
    String sessionId,
    Map<String, dynamic> update,
  ) async {
    final body = await _request(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/v1/agent/sessions/${Uri.encodeComponent(sessionId)}/live',
      body: update,
    );
    return _normalizeSessionDetail(body);
  }

  Future<Map<String, dynamic>> threads(String baseUrl) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/threads',
    );
  }

  Future<Map<String, dynamic>> threadDetail(String baseUrl, String threadId) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/threads/${Uri.encodeComponent(threadId)}',
    );
  }

  Future<Map<String, dynamic>> workspaceTree(
    String baseUrl, {
    String path = '',
    String? sessionId,
  }) {
    final queryParameters = <String, String>{};
    if (path.trim().isNotEmpty) {
      queryParameters['path'] = path.trim();
    }
    if (sessionId != null && sessionId.trim().isNotEmpty) {
      queryParameters['sessionId'] = sessionId.trim();
    }

    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/workspace/tree',
      queryParameters: queryParameters.isEmpty ? null : queryParameters,
    );
  }

  Future<Map<String, dynamic>> workspaceFile(
    String baseUrl,
    String path,
  ) {
    return _request(
      method: 'GET',
      baseUrl: baseUrl,
      path: '/v1/agent/workspace/file',
      queryParameters: <String, String>{'path': path.trim()},
    );
  }

  Future<Map<String, dynamic>> saveWorkspaceFile(
    String baseUrl,
    String path,
    String content,
  ) {
    return _request(
      method: 'PUT',
      baseUrl: baseUrl,
      path: '/v1/agent/workspace/file',
      queryParameters: <String, String>{'path': path.trim()},
      body: <String, dynamic>{'content': content},
    );
  }

  Future<Map<String, dynamic>> sendEnvelope(
    String baseUrl,
    Map<String, dynamic> envelope,
  ) {
    return _request(
      method: 'POST',
      baseUrl: baseUrl,
      path: '/v1/agent/envelope',
      body: envelope,
    );
  }

  void dispose() {
    _client.close();
  }

  bool _shouldFallbackToThreads(AgentApiException error) {
    return error.statusCode == 404 ||
        error.statusCode == 405 ||
        error.statusCode == 501;
  }

  Map<String, dynamic> _normalizeSessionsResponse(Map<String, dynamic> body) {
    final sessionList = _cloneObjectList(body['sessions']);
    final fallbackThreads = _cloneObjectList(body['threads']);
    return {
      ...body,
      'threads': (sessionList.isNotEmpty ? sessionList : fallbackThreads)
          .map(_normalizeSessionSummary)
          .toList(),
    };
  }

  Map<String, dynamic> _normalizeSessionDetail(Map<String, dynamic> body) {
    final session = _objectValue(body['session']);
    final timeline = body['timeline'] is List ? body['timeline'] : body['events'];
    return {
      ...body,
      'thread': _normalizeSessionSummary(session),
      'events': _cloneObjectList(timeline),
      'liveState': _objectValue(body['liveState']),
      'operationState': _objectValue(body['operationState']),
    };
  }

  Map<String, dynamic> _normalizeSessionSummary(Map<String, dynamic> session) {
    final sessionId = _text(session['id']);
    final threadId = _text(session['threadId']);
    final controlSessionId = _text(session['controlSessionId']);
    return {
      'id': threadId.isNotEmpty ? threadId : sessionId,
      'threadId': threadId,
      'sessionId': sessionId.isNotEmpty
          ? sessionId
          : (threadId.isNotEmpty ? threadId : controlSessionId),
      'controlSessionId': controlSessionId,
      'title': _text(session['title']),
      'state': _text(session['phase']),
      'currentJobId': _text(session['currentJobId']),
      'lastEventKind': _text(session['lastEventKind']),
      'lastEventText': _text(session['lastEventText']),
      'updatedAt': session['updatedAt'],
    };
  }

  List<Map<String, dynamic>> _cloneObjectList(dynamic value) {
    if (value is! List) {
      return const [];
    }
    return value
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Map<String, dynamic> _objectValue(dynamic value) {
    if (value is Map) {
      return Map<String, dynamic>.from(value);
    }
    return <String, dynamic>{};
  }

  String _text(dynamic value) {
    if (value == null) {
      return '';
    }
    return value.toString();
  }

  Future<http.StreamedResponse> _streamRequest({
    required String baseUrl,
    required String path,
  }) async {
    final uri = _buildUri(baseUrl, path);
    final request = http.Request('GET', uri)
      ..headers['Accept'] = 'text/event-stream';
    final response = await _client.send(request);
    if (response.statusCode >= 200 && response.statusCode < 300) {
      return response;
    }

    final text = await response.stream.bytesToString();
    dynamic decoded;
    if (text.isEmpty) {
      decoded = <String, dynamic>{};
    } else {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = <String, dynamic>{'raw': text};
      }
    }

    final message = decoded is Map<String, dynamic>
        ? (decoded['error']?.toString() ?? decoded.toString())
        : decoded.toString();
    throw AgentApiException(
      response.statusCode,
      message,
      responseBody: decoded is Map<String, dynamic> ? decoded : null,
    );
  }

  Stream<Map<String, dynamic>> _decodeSseEvents(
    http.StreamedResponse response,
  ) async* {
    final lines = response.stream.transform(utf8.decoder).transform(const LineSplitter());
    final buffer = <String>[];
    await for (final line in lines) {
      if (line.isEmpty) {
        if (buffer.isEmpty) {
          continue;
        }
        final payload = buffer.join('\n');
        buffer.clear();
        if (payload.trim().isEmpty) {
          continue;
        }
        dynamic decoded;
        try {
          decoded = jsonDecode(payload);
        } catch (_) {
          continue;
        }
        if (decoded is Map<String, dynamic>) {
          yield decoded;
        }
        continue;
      }

      if (line.startsWith(':')) {
        continue;
      }
      if (line.startsWith('data:')) {
        buffer.add(line.substring(5).trimLeft());
      }
    }
  }

  Future<Map<String, dynamic>> _request({
    required String method,
    required String baseUrl,
    required String path,
    Map<String, dynamic>? body,
    Map<String, String>? queryParameters,
  }) async {
    final uri = _buildUri(baseUrl, path, queryParameters: queryParameters);

    late final http.Response response;
    if (method == 'GET') {
      response = await _client.get(uri);
    } else if (method == 'POST') {
      response = await _client.post(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: body == null ? '{}' : jsonEncode(body),
      );
    } else if (method == 'PUT') {
      response = await _client.put(
        uri,
        headers: const {'Content-Type': 'application/json'},
        body: body == null ? '{}' : jsonEncode(body),
      );
    } else {
      throw AgentApiException(0, 'unsupported method: $method');
    }

    final text = utf8.decode(response.bodyBytes);
    dynamic decoded;
    if (text.isEmpty) {
      decoded = <String, dynamic>{};
    } else {
      try {
        decoded = jsonDecode(text);
      } catch (_) {
        decoded = <String, dynamic>{'raw': text};
      }
    }

    if (response.statusCode < 200 || response.statusCode >= 300) {
      final message = decoded is Map<String, dynamic>
          ? (decoded['error']?.toString() ?? decoded.toString())
          : decoded.toString();
      throw AgentApiException(
        response.statusCode,
        message,
        responseBody: decoded is Map<String, dynamic> ? decoded : null,
      );
    }

    if (decoded is Map<String, dynamic>) {
      return decoded;
    }

    return <String, dynamic>{'data': decoded};
  }

  Uri _buildUri(
    String baseUrl,
    String path, {
    Map<String, String>? queryParameters,
  }) {
    final normalized = baseUrl.trim();
    if (normalized.isEmpty) {
      throw AgentApiException(0, 'agent base url is empty');
    }

    var trimmedBase = normalized;
    while (trimmedBase.endsWith('/')) {
      trimmedBase = trimmedBase.substring(0, trimmedBase.length - 1);
    }
    final baseUri = Uri.parse(trimmedBase + path);
    if (queryParameters == null || queryParameters.isEmpty) {
      return baseUri;
    }
    return baseUri.replace(queryParameters: queryParameters);
  }
}
