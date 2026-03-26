import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';

import '../services/agent_api.dart';
import '../services/app_settings_store.dart';
import '../services/mobile_direct_signaling_session.dart';
import '../services/signaling_api.dart';

typedef DirectSessionFactory = MobileDirectSignalingSession Function();

enum SessionSyncStatus {
  idle,
  live,
  stale,
  reconnecting,
  failed,
}

class AppController extends ChangeNotifier {
  AppController({
    AgentApi? api,
    DirectSessionFactory? directSessionFactory,
    AppSettingsStore? settingsStore,
    Duration sessionSyncStaleAfter = const Duration(seconds: 20),
    Duration sessionSyncReconnectDelay = const Duration(seconds: 3),
    int sessionSyncMaxReconnectAttempts = 3,
  })  : _api = api ?? AgentApi(),
        _directSessionFactory =
            directSessionFactory ?? MobileDirectSignalingSession.new,
        _settingsStore = settingsStore ?? InMemoryAppSettingsStore(),
        _sessionSyncStaleAfter = sessionSyncStaleAfter,
        _sessionSyncReconnectDelay = sessionSyncReconnectDelay,
        _sessionSyncMaxReconnectAttempts = sessionSyncMaxReconnectAttempts < 1
            ? 1
            : sessionSyncMaxReconnectAttempts;

  final AgentApi _api;
  final DirectSessionFactory _directSessionFactory;
  final AppSettingsStore _settingsStore;
  final Duration _sessionSyncStaleAfter;
  final Duration _sessionSyncReconnectDelay;
  final int _sessionSyncMaxReconnectAttempts;

  String agentBaseUrl = 'http://127.0.0.1:8080';
  String signalingBaseUrl = 'http://127.0.0.1:8081';

  bool isLoading = false;
  String activity = '';
  String? errorMessage;

  bool p2pActive = false;
  String sessionId = '';
  String pairingCode = '';
  String connectionState = 'PAIRING';

  int pendingAckCount = 0;
  AckMetricsView ackMetrics = const AckMetricsView();
  AdapterRuntimeView adapterRuntime = const AdapterRuntimeView();
  BootstrapStatusView bootstrap = const BootstrapStatusView();
  UnmodifiableListView<RuntimeTransitionView> get runtimeHistory =>
      UnmodifiableListView(_runtimeHistory);
  final List<RuntimeTransitionView> _runtimeHistory = [];

  UnmodifiableListView<SavedHostEntry> get recentHosts =>
      UnmodifiableListView(_recentHosts);
  final List<SavedHostEntry> _recentHosts = [];

  bool _initialized = false;

  String promptDraft = '';
  String? currentJobId;
  String currentThreadId = '';
  String patchSummary = '';
  String patchResultStatus = '';
  String patchResultMessage = '';
  String runStatus = '';
  String runSummary = '';
  String runExcerpt = '';
  String runOutput = '';
  UnmodifiableListView<String> get runChangedFiles =>
      UnmodifiableListView(_runChangedFiles);
  final List<String> _runChangedFiles = [];
  final List<String> topErrors = [];

  UnmodifiableListView<PatchFileView> get patchFiles =>
      UnmodifiableListView(_patchFiles);
  final List<PatchFileView> _patchFiles = [];

  UnmodifiableListView<ThreadSummaryView> get threads =>
      UnmodifiableListView(_threads);
  final List<ThreadSummaryView> _threads = [];

  UnmodifiableListView<ThreadEventView> get threadEvents =>
      UnmodifiableListView(_threadEvents);
  final List<ThreadEventView> _threadEvents = [];

  SessionLiveView liveSession = const SessionLiveView();
  SessionOperationView sessionOperation = const SessionOperationView();
  SessionSyncStatus sessionSyncStatus = SessionSyncStatus.idle;
  String sessionSyncDetail = '';
  int sessionLastSyncedAt = 0;
  UnmodifiableListView<SessionSyncLogEntryView> get sessionSyncLogs =>
      UnmodifiableListView(_sessionSyncLogs);
  final List<SessionSyncLogEntryView> _sessionSyncLogs = [];
  final Map<String, List<WorkspaceTreeEntryView>> _workspaceTreeByPath = {};
  Timer? _workspaceTreeRefreshTimer;
  WorkspaceFileContentView workspaceFile = const WorkspaceFileContentView();
  String workspaceSelectedFilePath = '';
  bool workspaceFileLoading = false;
  String? workspaceFileError;

  UnmodifiableListView<RunProfileView> get runProfiles =>
      UnmodifiableListView(_runProfiles);
  final List<RunProfileView> _runProfiles = [];

  String directPairingCode = '';
  String directSignalingState = 'IDLE';
  bool directSignalingConnected = false;
  bool directPeerConnected = false;
  bool directControlReady = false;
  String directSessionId = '';
  String directDeviceKey = '';
  UnmodifiableListView<String> get directSignalLogs =>
      UnmodifiableListView(_directSignalLogs);
  final List<String> _directSignalLogs = [];

  MobileDirectSignalingSession? _directSession;
  StreamSubscription<DirectSignalingState>? _directStateSub;
  StreamSubscription<DirectSignalEvent>? _directEventSub;
  StreamSubscription<Map<String, dynamic>>? _directEnvelopeSub;
  StreamSubscription<String>? _directErrorSub;
  StreamSubscription<Map<String, dynamic>>? _sessionStreamSub;

  Timer? _sessionPresenceTimer;
  Timer? _promptDraftSyncTimer;
  Timer? _sessionSyncWatchdogTimer;
  Timer? _sessionSyncRetryTimer;
  String _sessionStreamThreadId = '';
  String _sessionStreamBaseUrl = '';
  int _sessionSyncReconnectAttempts = 0;

  int _seq = 1;

  String get controlPath => directControlReady ? 'DIRECT' : 'HTTP';
  ThreadSummaryView? get selectedThreadSummary {
    for (final thread in _threads) {
      if (thread.id == currentThreadId) {
        return thread;
      }
    }
    return null;
  }

  String get currentThreadTitle {
    final selected = selectedThreadSummary;
    if (selected != null) {
      return selected.title;
    }
    if (currentThreadId.isEmpty) {
      return '새 스레드';
    }
    return currentThreadId;
  }

  String get currentThreadState => selectedThreadSummary?.state ?? 'draft';
  String get currentSessionPhase => sessionOperation.phase.isNotEmpty
      ? sessionOperation.phase
      : currentThreadState;
  int get liveParticipantCount => liveSession.participants
      .where((participant) => participant.active)
      .length;
  String get liveParticipantSummary {
    if (liveSession.participants.isEmpty) {
      return '참여자 없음';
    }
    return '$liveParticipantCount명 연결';
  }

  String get liveActivitySummary {
    if (liveSession.activity.summary.isNotEmpty) {
      return liveSession.activity.summary;
    }
    if (currentThreadId.isEmpty) {
      return '아직 연결된 세션이 없습니다.';
    }
    return '모바일과 Cursor가 같은 세션을 보고 있습니다.';
  }

  String get liveFocusSummary {
    final focus = liveSession.focus;
    final candidates = <String>[
      focus.activeFilePath,
      focus.patchPath,
      focus.runErrorPath,
      focus.selection,
    ];
    for (final candidate in candidates) {
      if (candidate.trim().isNotEmpty) {
        return candidate.trim();
      }
    }
    return '포커스 없음';
  }

  String get liveDraftPreview => liveSession.composer.draftText;
  bool get liveComposerTyping => liveSession.composer.isTyping;
  bool get hasSessionSyncTarget => currentSharedSessionId.isNotEmpty;
  bool get canRetrySessionSync => hasSessionSyncTarget && !isLoading;
  bool get canRefreshSessionSync => hasSessionSyncTarget && !isLoading;
  String get workspaceRootPath {
    for (final candidate in [
      liveSession.workspace.rootPath,
      adapterRuntime.workspaceRoot,
      bootstrap.workspaceRoot,
    ]) {
      final trimmed = candidate.trim();
      if (trimmed.isNotEmpty) {
        return trimmed;
      }
    }
    return '';
  }

  String get currentSharedSessionId {
    final selected = selectedThreadSummary?.sessionId.trim() ?? '';
    if (selected.isNotEmpty) {
      return selected;
    }
    if (sessionId.trim().isNotEmpty) {
      return sessionId.trim();
    }
    return currentThreadId.trim();
  }

  String get sessionSyncStatusLabel {
    switch (sessionSyncStatus) {
      case SessionSyncStatus.live:
        return '실시간 연결';
      case SessionSyncStatus.stale:
        return '멈춤 감지';
      case SessionSyncStatus.reconnecting:
        return '다시 연결 중';
      case SessionSyncStatus.failed:
        return '복구 필요';
      case SessionSyncStatus.idle:
        return hasSessionSyncTarget ? '준비 중' : '세션 없음';
    }
  }

  String get sessionSyncSummary {
    switch (sessionSyncStatus) {
      case SessionSyncStatus.live:
        return '세션이 실시간으로 동기화되고 있습니다.';
      case SessionSyncStatus.stale:
        return '동기화가 오래 멈춰 있어 새로고침이나 다시 연결이 필요할 수 있습니다.';
      case SessionSyncStatus.reconnecting:
        return '세션 연결을 복구하는 중입니다.';
      case SessionSyncStatus.failed:
        return '자동 복구가 실패했습니다. 직접 다시 연결해 주세요.';
      case SessionSyncStatus.idle:
        return hasSessionSyncTarget
            ? '세션 연결을 준비하는 중입니다.'
            : '세션을 선택하면 연결 상태를 추적합니다.';
    }
  }

  String get sessionSyncNextAction {
    switch (sessionSyncStatus) {
      case SessionSyncStatus.stale:
        return '세션 새로고침이나 다시 연결로 마지막 작업 위치를 확인하세요.';
      case SessionSyncStatus.reconnecting:
        return '복구가 끝날 때까지 기다리거나, 오래 멈추면 세션 새로고침을 눌러 주세요.';
      case SessionSyncStatus.failed:
        return '마지막 작업 위치를 확인한 뒤 다시 연결하거나, 필요하면 프롬프트를 다시 제출하세요.';
      case SessionSyncStatus.live:
        return hasRecentSessionSyncLogs
            ? '방금 복구된 세션입니다. 아래 로그로 어디서 끊겼는지 확인할 수 있습니다.'
            : '세션이 정상적으로 실시간 동기화되고 있습니다.';
      case SessionSyncStatus.idle:
        return hasSessionSyncTarget
            ? '세션 연결 준비가 끝나면 실시간 상태와 복구 로그가 여기에 표시됩니다.'
            : '세션을 선택하면 복구 상태를 추적합니다.';
    }
  }

  String get sessionSyncAttemptLabel {
    if (_sessionSyncReconnectAttempts <= 0) {
      return '재시도 없음';
    }
    return '재시도 $_sessionSyncReconnectAttempts/$_sessionSyncMaxReconnectAttempts';
  }

  bool get hasRecentSessionSyncLogs {
    if (_sessionSyncLogs.isEmpty) {
      return false;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    const recentWindow = Duration(minutes: 5);
    return _sessionSyncLogs.any(
      (entry) =>
          now - entry.atMillis <= recentWindow.inMilliseconds &&
          (entry.kind != 'live' || entry.title == '연결 복구 완료'),
    );
  }

  String get sessionLastSyncedLabel {
    if (sessionLastSyncedAt <= 0) {
      return '아직 동기화 기록 없음';
    }
    return '${_formatSessionSyncTimestamp(sessionLastSyncedAt)} / ${_formatSessionSyncRelativeAge(sessionLastSyncedAt)}';
  }

  bool get canApplyAllPatch => !isLoading && _patchFiles.isNotEmpty;

  List<String> get currentJobFiles {
    if (_runChangedFiles.isNotEmpty) {
      return List.unmodifiable(_runChangedFiles);
    }
    return List.unmodifiable(_currentPatchPaths());
  }

  String get patchAvailabilityReason {
    if (_patchFiles.isNotEmpty) {
      return '';
    }
    if (isLoading) {
      return 'agent 응답을 처리하는 중입니다.';
    }
    if ((currentJobId ?? '').trim().isEmpty) {
      return '먼저 프롬프트를 보내 작업을 시작하세요.';
    }

    final normalizedSummary = patchSummary.trim();
    if (normalizedSummary.isNotEmpty) {
      if (normalizedSummary.toLowerCase().contains('without code changes')) {
        return '이 작업은 코드 변경 없이 완료되어 적용할 파일이 없습니다.';
      }
      return '적용할 파일 패치가 없습니다. $normalizedSummary';
    }

    final normalizedError = errorMessage?.trim() ?? '';
    if (normalizedError.isNotEmpty) {
      return '패치를 만들지 못했습니다. $normalizedError';
    }

    if (_threadEvents.any(
      (event) => event.jobId == currentJobId && event.kind == 'prompt_accepted',
    )) {
      return '패치가 아직 준비되지 않았거나 코드 변경이 없었습니다.';
    }

    return '적용할 패치가 없습니다.';
  }

  Future<void> initialize() async {
    if (_initialized) {
      return;
    }
    _initialized = true;
    await _restoreSettings();
    await refreshStatus();
  }

  Future<void> applyBootstrapUri(Uri uri) {
    if (!_isBootstrapUri(uri)) {
      return Future.value();
    }

    return _run('Bootstrap 링크 적용', () async {
      await _applyBootstrapUriRaw(uri);
    });
  }

  Future<void> useRecentHost(SavedHostEntry host) {
    agentBaseUrl = host.agentBaseUrl;
    if (host.signalingBaseUrl.trim().isNotEmpty) {
      signalingBaseUrl = host.signalingBaseUrl.trim();
    }
    notifyListeners();
    return refreshStatus();
  }

  bool _isBootstrapUri(Uri uri) {
    return uri.scheme.toLowerCase() == 'vibedeck' &&
        uri.host.toLowerCase() == 'bootstrap';
  }

  Future<void> _applyBootstrapUriRaw(Uri uri) async {
    final agent = uri.queryParameters['agent']?.trim() ?? '';
    final signaling = uri.queryParameters['signaling']?.trim() ?? '';
    final thread = uri.queryParameters['thread']?.trim() ?? '';
    final session = uri.queryParameters['session']?.trim() ?? '';

    if (agent.isEmpty && signaling.isEmpty && thread.isEmpty && session.isEmpty) {
      return;
    }

    if (agent.isNotEmpty) {
      agentBaseUrl = agent;
    }
    if (signaling.isNotEmpty) {
      signalingBaseUrl = signaling;
    }
    if (thread.isNotEmpty) {
      currentThreadId = thread;
    }
    if (session.isNotEmpty) {
      sessionId = session;
    }

    _rememberCurrentHost();
    await _persistSettings();
    notifyListeners();
    await _refreshStatusRaw();
  }

  void updateAgentBaseUrl(String value) {
    agentBaseUrl = value.trim();
    notifyListeners();
  }

  void updateSignalingBaseUrl(String value) {
    signalingBaseUrl = value.trim();
    notifyListeners();
  }

  void updateDirectPairingCode(String value) {
    directPairingCode = value.trim();
    notifyListeners();
  }

  void beginNewThread() {
    currentThreadId = '';
    sessionId = '';
    currentJobId = null;
    promptDraft = '';
    patchSummary = '';
    patchResultStatus = '';
    patchResultMessage = '';
    runStatus = '';
    runSummary = '';
    runExcerpt = '';
    runOutput = '';
    liveSession = const SessionLiveView();
    sessionOperation = const SessionOperationView();
    _runChangedFiles.clear();
    topErrors.clear();
    _patchFiles.clear();
    _threadEvents.clear();
    _sessionSyncLogs.clear();
    _clearWorkspaceBrowserState();
    _promptDraftSyncTimer?.cancel();
    _resetSessionSyncState(shouldNotify: false);
    unawaited(_stopSessionStream());
    notifyListeners();
  }

  Future<void> selectThread(String threadId) {
    currentThreadId = threadId.trim();
    sessionId = '';
    _patchFiles.clear();
    _sessionSyncLogs.clear();
    _clearWorkspaceBrowserState();
    return _run('스레드 로드', () async {
      await _refreshThreadDetail();
    });
  }

  Future<void> refreshStatus() {
    return _run('상태 갱신', _refreshStatusRaw);
  }

  Future<void> refreshCurrentSession() {
    if (currentThreadId.isEmpty) {
      return Future.value();
    }
    return _run('세션 새로고침', () async {
      await _refreshThreadDetail();
    });
  }

  Future<void> retrySessionSync() {
    if (currentThreadId.isEmpty) {
      return Future.value();
    }
    return _run('세션 다시 연결', () async {
      await _reconnectSessionStream(manual: true);
    });
  }

  List<WorkspaceTreeEntryView> workspaceEntriesForPath(String path) {
    final normalized = _normalizeWorkspacePath(path);
    final entries = _workspaceTreeByPath[normalized];
    if (entries == null) {
      return const [];
    }
    return List<WorkspaceTreeEntryView>.unmodifiable(entries);
  }

  bool hasWorkspaceEntries(String path) {
    return _workspaceTreeByPath.containsKey(_normalizeWorkspacePath(path));
  }

  Future<List<WorkspaceTreeEntryView>> loadWorkspaceTree(
    String path, {
    bool force = false,
  }) async {
    final normalized = _normalizeWorkspacePath(path);
    if (!force && _workspaceTreeByPath.containsKey(normalized)) {
      return workspaceEntriesForPath(normalized);
    }

    final response = await _api.workspaceTree(
      agentBaseUrl,
      path: normalized,
      sessionId: currentSharedSessionId,
    );
    final entriesRaw = response['entries'];
    final entries = entriesRaw is List
        ? entriesRaw
            .whereType<Map>()
            .map((item) =>
                WorkspaceTreeEntryView.fromMap(Map<String, dynamic>.from(item)))
            .toList()
        : const <WorkspaceTreeEntryView>[];

    _workspaceTreeByPath[normalized] = entries;
    notifyListeners();
    return List<WorkspaceTreeEntryView>.unmodifiable(entries);
  }

  Future<WorkspaceFileContentView> loadWorkspaceFile(String path) async {
    final normalized = _normalizeWorkspacePath(path);
    workspaceFileLoading = true;
    workspaceFileError = null;
    notifyListeners();

    try {
      final response = await _api.workspaceFile(agentBaseUrl, normalized);
      workspaceSelectedFilePath = normalized;
      workspaceFile = WorkspaceFileContentView.fromMap(response);
      unawaited(_publishWorkspaceFocus(normalized));
      return workspaceFile;
    } on AgentApiException catch (error) {
      workspaceFileError = '[${error.statusCode}] ${error.message}';
      rethrow;
    } finally {
      workspaceFileLoading = false;
      notifyListeners();
    }
  }

  Future<WorkspaceFileContentView> saveWorkspaceFile(
    String path,
    String content,
  ) async {
    final normalized = _normalizeWorkspacePath(path);
    workspaceFileLoading = true;
    workspaceFileError = null;
    notifyListeners();

    try {
      final response = await _api.saveWorkspaceFile(
        agentBaseUrl,
        normalized,
        content,
      );
      workspaceSelectedFilePath = normalized;
      workspaceFile = WorkspaceFileContentView.fromMap(response);
      final parentPath = _workspaceParentPath(normalized);
      if (_workspaceTreeByPath.containsKey(parentPath)) {
        await loadWorkspaceTree(parentPath, force: true);
      }
      unawaited(_publishWorkspaceFocus(normalized));
      return workspaceFile;
    } on AgentApiException catch (error) {
      workspaceFileError = '[${error.statusCode}] ${error.message}';
      rethrow;
    } finally {
      workspaceFileLoading = false;
      notifyListeners();
    }
  }

  Future<void> openWorkspaceLocation(
    String path, {
    int line = 1,
    int column = 1,
  }) async {
    final normalized = _normalizeWorkspacePath(path);
    errorMessage = null;
    notifyListeners();

    try {
      final responses = await _sendEnvelopeAndAck(
        _buildEnvelope(
          type: 'OPEN_LOCATION',
          payload: {
            'path': normalized,
            'line': line,
            if (column > 0) 'column': column,
          },
        ),
      );
      _applyResponses(responses);
      unawaited(_publishWorkspaceFocus(normalized));
    } on AgentApiException catch (error) {
      errorMessage = '[${error.statusCode}] ${error.message}';
      notifyListeners();
    } catch (error) {
      errorMessage = error.toString();
      notifyListeners();
    }
  }

  Future<void> startP2P() {
    return _run('P2P 시작', () async {
      await _api.p2pStart(
        agentBaseUrl,
        signalingBaseUrl: signalingBaseUrl,
      );
      await _refreshStatusRaw();
    });
  }

  Future<void> stopP2P() {
    return _run('P2P 종료', () async {
      await _api.p2pStop(agentBaseUrl);
      await _refreshStatusRaw();
    });
  }

  Future<void> connectDirectSignaling() {
    final code = _resolveDirectPairingCode();
    if (code.isEmpty) {
      errorMessage = 'pairing code를 입력하거나 P2P 시작 후 발급 코드를 사용하세요.';
      notifyListeners();
      return Future.value();
    }

    return _run('Direct signaling 연결', () async {
      await _closeDirectSignalingSession();

      final session = _directSessionFactory();
      _directSession = session;
      _bindDirectSession(session);

      directPairingCode = code;
      _appendDirectLog('direct connect 시작 (code=$code)');

      await session.connect(
        signalingBaseUrl: signalingBaseUrl,
        pairingCode: code,
      );

      directSignalingConnected = session.isConnected;
      directPeerConnected = session.isPeerConnected;
      directControlReady = session.isControlReady;
      directSessionId = session.sessionId;
      directDeviceKey = session.mobileDeviceKey;
      notifyListeners();
    });
  }

  Future<void> disconnectDirectSignaling() {
    return _run('Direct signaling 종료', () async {
      await _closeDirectSignalingSession();
      directSignalingConnected = false;
      directPeerConnected = false;
      directControlReady = false;
      directSignalingState = 'CLOSED';
      notifyListeners();
    });
  }

  Future<void> submitPrompt({
    required String prompt,
    String template = '',
    required Map<String, bool> context,
  }) {
    if (prompt.trim().isEmpty) {
      errorMessage = 'prompt를 입력해주세요.';
      notifyListeners();
      return Future.value();
    }

    return _run('Prompt 제출', () async {
      final payload = <String, dynamic>{
        'prompt': prompt.trim(),
        'contextOptions': {
          'includeActiveFile': context['activeFile'] ?? false,
          'includeSelection': context['selection'] ?? false,
          'includeLatestError': context['latestError'] ?? false,
          'includeWorkspaceSummary': context['workspaceSummary'] ?? false,
        },
      };
      if (currentThreadId.isNotEmpty) {
        payload['threadId'] = currentThreadId;
      }
      if (template.trim().isNotEmpty) {
        payload['template'] = template.trim();
      }

      final envelope = _buildEnvelope(
        type: 'PROMPT_SUBMIT',
        payload: payload,
      );

      promptDraft = prompt.trim();
      final responses = await _sendEnvelopeAndAck(envelope);
      _applyResponses(responses);
      await _refreshStatusRaw();
    });
  }

  Future<void> applyPatch({
    required bool applyAll,
    required Map<String, Set<String>> selectedByPath,
  }) {
    if ((currentJobId ?? '').isEmpty) {
      errorMessage = '적용할 job이 없습니다. Prompt를 먼저 제출해주세요.';
      notifyListeners();
      return Future.value();
    }

    final selected = <Map<String, dynamic>>[];
    if (!applyAll) {
      for (final entry in selectedByPath.entries) {
        if (entry.value.isEmpty) {
          continue;
        }
        selected.add(
          {
            'path': entry.key,
            'hunkIds': entry.value.toList(),
          },
        );
      }
    }

    return _run('Patch 적용', () async {
      final envelope = _buildEnvelope(
        type: 'PATCH_APPLY',
        payload: {
          'jobId': currentJobId,
          'mode': applyAll ? 'all' : 'selected',
          if (!applyAll) 'selected': selected,
        },
      );

      final responses = await _sendEnvelopeAndAck(envelope);
      _applyResponses(responses);
      await _refreshStatusRaw();
    });
  }

  Future<void> runProfile(String profileId) {
    if ((currentJobId ?? '').isEmpty) {
      errorMessage = '실행할 job이 없습니다. Prompt를 먼저 제출해주세요.';
      notifyListeners();
      return Future.value();
    }

    return _run('프로파일 실행', () async {
      final envelope = _buildEnvelope(
        type: 'RUN_PROFILE',
        payload: {
          'jobId': currentJobId,
          'profileId': profileId,
        },
      );

      final responses = await _sendEnvelopeAndAck(envelope);
      _applyResponses(responses);
      await _refreshStatusRaw();
    });
  }

  Future<void> _refreshStatusRaw() async {
    await _refreshBootstrapRaw();

    final results = await Future.wait<Object?>([
      _api.p2pStatus(agentBaseUrl),
      _api.runtimeState(agentBaseUrl),
      _api.runtimeMetrics(agentBaseUrl),
      _api.runtimeAdapter(agentBaseUrl),
      _api.runProfiles(agentBaseUrl),
      _api.sessions(agentBaseUrl),
    ]);

    final p2p = Map<String, dynamic>.from(results[0] as Map);
    p2pActive = p2p['active'] == true;
    sessionId = p2p['sessionId']?.toString() ?? '';
    pairingCode = p2p['pairingCode']?.toString() ?? '';

    if (directPairingCode.isEmpty && pairingCode.isNotEmpty) {
      directPairingCode = pairingCode;
    }

    final runtime = Map<String, dynamic>.from(results[1] as Map);
    connectionState = runtime['state']?.toString() ?? connectionState;
    _runtimeHistory
      ..clear()
      ..addAll(_parseHistory(runtime['history']));

    final metrics = Map<String, dynamic>.from(results[2] as Map);
    ackMetrics = _parseAckMetrics(metrics['ack']);
    pendingAckCount = ackMetrics.pendingCount;

    adapterRuntime = _parseAdapterRuntime(
      Map<String, dynamic>.from(results[3] as Map),
    );

    final runProfilesResponse = Map<String, dynamic>.from(results[4] as Map);
    _runProfiles
      ..clear()
      ..addAll(_parseRunProfiles(runProfilesResponse['profiles']));

    final threadsResponse = Map<String, dynamic>.from(results[5] as Map);
    _threads
      ..clear()
      ..addAll(_parseThreads(threadsResponse['threads']));

    if (currentThreadId.isNotEmpty &&
        !_threads.any((thread) => thread.id == currentThreadId)) {
      currentThreadId = '';
    }
    if (currentThreadId.isEmpty && _threads.isNotEmpty) {
      currentThreadId = _threads.first.id;
    }

    await _refreshThreadDetail();
    _rememberCurrentHost();
    await _persistSettings();
  }

  Future<void> _refreshBootstrapRaw() async {
    final raw = await _api.bootstrap(agentBaseUrl);
    bootstrap = BootstrapStatusView.fromMap(raw);

    if (bootstrap.agentBaseUrl.isNotEmpty) {
      agentBaseUrl = bootstrap.agentBaseUrl;
    }
    if (bootstrap.signalingBaseUrl.isNotEmpty) {
      signalingBaseUrl = bootstrap.signalingBaseUrl;
    }
    if (sessionId.isEmpty && bootstrap.currentSessionId.isNotEmpty) {
      sessionId = bootstrap.currentSessionId;
    }
    if (currentThreadId.isEmpty && bootstrap.currentThreadId.isNotEmpty) {
      currentThreadId = bootstrap.currentThreadId;
    }
  }

  Future<void> _refreshThreadDetail() async {
    if (currentSharedSessionId.isEmpty) {
      currentJobId = null;
      _threadEvents.clear();
      liveSession = const SessionLiveView();
      sessionOperation = const SessionOperationView();
      _clearWorkspaceBrowserState();
      _resetSessionSyncState(shouldNotify: false);
      await _stopSessionStream();
      return;
    }

    final detail = await _api.sessionDetail(agentBaseUrl, currentSharedSessionId);
    _applySessionDetail(detail);
    await _ensureSessionStream();
  }

  void updatePromptDraft(String value) {
    promptDraft = value;
    notifyListeners();

    _promptDraftSyncTimer?.cancel();
    if (currentThreadId.isEmpty) {
      return;
    }

    _promptDraftSyncTimer = Timer(const Duration(milliseconds: 250), () {
      unawaited(
        _publishSessionLiveStateSafe(
          composer: {
            'draftText': value,
            'isTyping': value.trim().isNotEmpty,
            'updatedAt': DateTime.now().millisecondsSinceEpoch,
          },
        ),
      );
    });
  }

  void _applySessionDetail(Map<String, dynamic> detail) {
    final previousLiveSession = liveSession;
    currentThreadId = detail['thread'] is Map
        ? (detail['thread']['id']?.toString() ?? currentThreadId)
        : currentThreadId;
    sessionId = detail['thread'] is Map
        ? (detail['thread']['sessionId']?.toString() ?? sessionId)
        : sessionId;
    _markSessionSyncHealthy(shouldNotify: false);
    _threadEvents
      ..clear()
      ..addAll(_parseThreadEvents(detail['events']));

    final threadRaw = detail['thread'];
    if (threadRaw is Map) {
      final thread =
          ThreadSummaryView.fromMap(Map<String, dynamic>.from(threadRaw));
      currentJobId =
          thread.currentJobId.isEmpty ? currentJobId : thread.currentJobId;
    }

    liveSession = detail['liveState'] is Map
        ? SessionLiveView.fromMap(
            Map<String, dynamic>.from(detail['liveState'] as Map))
        : const SessionLiveView();
    sessionOperation = detail['operationState'] is Map
        ? SessionOperationView.fromMap(
            Map<String, dynamic>.from(detail['operationState'] as Map),
          )
        : const SessionOperationView();

    _syncDerivedStateFromThreadEvents();
    if (sessionOperation.currentJobId.isNotEmpty) {
      currentJobId = sessionOperation.currentJobId;
    }
    if (sessionOperation.patchSummary.isNotEmpty && patchSummary.isEmpty) {
      patchSummary = sessionOperation.patchSummary;
    }
    if (sessionOperation.patchResultStatus.isNotEmpty) {
      patchResultStatus = sessionOperation.patchResultStatus;
    }
    if (sessionOperation.patchResultMessage.isNotEmpty) {
      patchResultMessage = sessionOperation.patchResultMessage;
    }
    if (sessionOperation.runStatus.isNotEmpty) {
      runStatus = sessionOperation.runStatus;
    }
    if (sessionOperation.runSummary.isNotEmpty) {
      runSummary = sessionOperation.runSummary;
    }
    if (sessionOperation.runExcerpt.isNotEmpty) {
      runExcerpt = sessionOperation.runExcerpt;
    }
    if (sessionOperation.runOutput.isNotEmpty) {
      runOutput = sessionOperation.runOutput;
    }
    if (topErrors.isEmpty && sessionOperation.runTopErrors.isNotEmpty) {
      topErrors
        ..clear()
        ..addAll(
          sessionOperation.runTopErrors.map(
            (item) => item.path.isNotEmpty
                ? '${item.path}:${item.line} ${item.message}'.trim()
                : item.message,
          ),
        );
    }
    if (_runChangedFiles.isEmpty &&
        sessionOperation.runChangedFiles.isNotEmpty) {
      _runChangedFiles
        ..clear()
        ..addAll(sessionOperation.runChangedFiles);
    } else if (_runChangedFiles.isEmpty &&
        sessionOperation.currentJobFiles.isNotEmpty) {
      _runChangedFiles
        ..clear()
        ..addAll(sessionOperation.currentJobFiles);
    }

    _syncWorkspaceSurfaceFromLiveSession(previousLiveSession);
  }

  Future<void> _ensureSessionStream({bool force = false}) async {
    if (currentThreadId.isEmpty) {
      await _stopSessionStream();
      return;
    }
    if (!force &&
        _sessionStreamSub != null &&
        _sessionStreamThreadId == currentSharedSessionId &&
        _sessionStreamBaseUrl == agentBaseUrl) {
      _armSessionSyncWatchdog();
      return;
    }

    await _stopSessionStream(preserveSyncState: true);
    _sessionStreamThreadId = currentSharedSessionId;
    _sessionStreamBaseUrl = agentBaseUrl;
    _markSessionSyncReconnecting(
      detail: '세션 실시간 연결을 준비하는 중입니다.',
      shouldNotify: false,
    );
    _sessionStreamSub =
        _api.sessionStream(agentBaseUrl, currentSharedSessionId).listen(
      (detail) {
        _applySessionDetail(detail);
        notifyListeners();
      },
      onError: (Object error, StackTrace stackTrace) {
        _handleSessionSyncFault(error, source: 'stream');
      },
      onDone: () {
        if (currentThreadId.isEmpty) {
          return;
        }
        _handleSessionSyncFault(
          StateError('session stream closed'),
          source: 'stream_closed',
        );
      },
      cancelOnError: true,
    );

    await _publishSessionPresenceSafe();
    _sessionPresenceTimer = Timer.periodic(const Duration(seconds: 12), (_) {
      unawaited(_publishSessionPresenceSafe());
    });
  }

  Future<void> _stopSessionStream({bool preserveSyncState = false}) async {
    _promptDraftSyncTimer?.cancel();
    _promptDraftSyncTimer = null;
    _sessionPresenceTimer?.cancel();
    _sessionPresenceTimer = null;
    _sessionSyncWatchdogTimer?.cancel();
    _sessionSyncWatchdogTimer = null;
    _sessionSyncRetryTimer?.cancel();
    _sessionSyncRetryTimer = null;
    await _sessionStreamSub?.cancel();
    _sessionStreamSub = null;
    _sessionStreamThreadId = '';
    _sessionStreamBaseUrl = '';
    if (!preserveSyncState && currentThreadId.isEmpty) {
      _resetSessionSyncState(shouldNotify: false);
    }
  }

  Future<void> _publishSessionPresence() {
    return _publishSessionLiveState();
  }

  Future<void> _publishSessionPresenceSafe() async {
    try {
      await _publishSessionPresence();
    } catch (error) {
      _handleSessionSyncFault(error, source: 'presence');
    }
  }

  Future<void> _publishSessionLiveStateSafe({
    Map<String, dynamic>? composer,
    Map<String, dynamic>? focus,
    Map<String, dynamic>? workspace,
  }) async {
    try {
      await _publishSessionLiveState(
        composer: composer,
        focus: focus,
        workspace: workspace,
      );
    } catch (error) {
      _handleSessionSyncFault(error, source: 'live_update');
    }
  }

  Future<void> _publishSessionLiveState({
    Map<String, dynamic>? composer,
    Map<String, dynamic>? focus,
    Map<String, dynamic>? workspace,
  }) async {
    if (currentThreadId.isEmpty) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final update = <String, dynamic>{
      'participant': {
        'participantId': _mobileParticipantId(),
        'clientType': 'mobile',
        'displayName': 'VibeDeck Mobile',
        'active': true,
        'lastSeenAt': now,
      },
      'activity': {
        'phase': currentSessionPhase,
        'summary': _liveActivitySummaryForPublish(),
        'updatedAt': now,
      },
    };

    final focusUpdate = <String, dynamic>{
      ..._buildMobileFocus(now),
      if (focus != null) ...focus,
    };
    if (focusUpdate.isNotEmpty) {
      focusUpdate['updatedAt'] = focusUpdate['updatedAt'] ?? now;
      update['focus'] = focusUpdate;
    }
    if (composer != null) {
      update['composer'] = composer;
    }
    if (workspace != null) {
      update['workspace'] = {
        ...workspace,
        'updatedAt': workspace['updatedAt'] ?? now,
      };
    }

    final detail = await _api.updateSessionLiveState(
      agentBaseUrl,
      currentSharedSessionId,
      update,
    );
    _applySessionDetail(detail);
    notifyListeners();
  }

  Future<void> _reconnectSessionStream({bool manual = false}) async {
    if (currentThreadId.isEmpty) {
      return;
    }

    _sessionSyncRetryTimer?.cancel();
    _sessionSyncRetryTimer = null;
    if (manual) {
      _sessionSyncReconnectAttempts = 0;
      _recordSessionSyncLog(
        kind: 'manual',
        title: '수동 다시 연결',
        detail: '사용자가 세션 연결을 다시 시작했습니다.',
      );
    }

    _markSessionSyncReconnecting(
      detail: manual ? '세션 연결을 다시 시작하는 중입니다.' : '세션 연결을 복구하는 중입니다.',
      shouldNotify: false,
    );
    await _stopSessionStream(preserveSyncState: true);
    final detail = await _api.sessionDetail(agentBaseUrl, currentSharedSessionId);
    _applySessionDetail(detail);
    await _ensureSessionStream(force: true);
    notifyListeners();
  }

  void _handleSessionSyncFault(Object error, {required String source}) {
    if (currentThreadId.isEmpty) {
      return;
    }

    final detail = _sessionSyncRecoveryDetail(error, source: source);
    if (source == 'watchdog') {
      _recordSessionSyncLog(
        kind: 'stale',
        title: '멈춤 감지',
        detail: detail,
      );
      _markSessionSyncStale(detail: detail);
    } else {
      final nextAttempt = _sessionSyncReconnectAttempts + 1;
      _recordSessionSyncLog(
        kind: 'reconnecting',
        title: '복구 시도',
        detail: nextAttempt > _sessionSyncMaxReconnectAttempts
            ? detail
            : '$detail ($nextAttempt/$_sessionSyncMaxReconnectAttempts)',
      );
      _markSessionSyncReconnecting(detail: detail);
    }

    if (_sessionSyncRetryTimer != null) {
      return;
    }
    if (_sessionSyncReconnectAttempts >= _sessionSyncMaxReconnectAttempts) {
      _recordSessionSyncLog(
        kind: 'failed',
        title: '복구 실패',
        detail: detail,
      );
      _markSessionSyncFailed(detail: detail);
      return;
    }

    _sessionSyncReconnectAttempts += 1;
    _sessionSyncRetryTimer = Timer(_sessionSyncReconnectDelay, () {
      _sessionSyncRetryTimer = null;
      unawaited(_runSessionSyncReconnectAttempt());
    });
  }

  Future<void> _runSessionSyncReconnectAttempt() async {
    try {
      await _reconnectSessionStream();
    } catch (error) {
      final detail = _sessionSyncRecoveryDetail(error, source: 'retry');
      if (_sessionSyncReconnectAttempts >= _sessionSyncMaxReconnectAttempts) {
        _markSessionSyncFailed(detail: detail);
        return;
      }
      _markSessionSyncReconnecting(detail: detail);
      _handleSessionSyncFault(error, source: 'retry');
    }
  }

  void _armSessionSyncWatchdog() {
    _sessionSyncWatchdogTimer?.cancel();
    if (currentThreadId.isEmpty ||
        sessionSyncStatus == SessionSyncStatus.failed) {
      return;
    }

    _sessionSyncWatchdogTimer = Timer(_sessionSyncStaleAfter, () {
      if (currentThreadId.isEmpty ||
          sessionSyncStatus == SessionSyncStatus.failed) {
        return;
      }
      _handleSessionSyncFault(
        StateError('session sync watchdog timeout'),
        source: 'watchdog',
      );
    });
  }

  void _resetSessionSyncState({bool shouldNotify = true}) {
    _sessionSyncWatchdogTimer?.cancel();
    _sessionSyncWatchdogTimer = null;
    _sessionSyncRetryTimer?.cancel();
    _sessionSyncRetryTimer = null;
    _sessionSyncReconnectAttempts = 0;
    sessionSyncStatus = SessionSyncStatus.idle;
    sessionSyncDetail = '';
    sessionLastSyncedAt = 0;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _markSessionSyncHealthy({bool shouldNotify = true}) {
    if (currentThreadId.isEmpty) {
      _resetSessionSyncState(shouldNotify: shouldNotify);
      return;
    }

    final previousStatus = sessionSyncStatus;
    final hadLastSync = sessionLastSyncedAt > 0;
    _sessionSyncReconnectAttempts = 0;
    sessionSyncStatus = SessionSyncStatus.live;
    sessionSyncDetail = '';
    sessionLastSyncedAt = DateTime.now().millisecondsSinceEpoch;
    if (!hadLastSync) {
      _recordSessionSyncLog(
        kind: 'live',
        title: '실시간 연결 시작',
        detail: '공유 세션 동기화를 시작했습니다.',
      );
    } else if (previousStatus != SessionSyncStatus.live) {
      _recordSessionSyncLog(
        kind: 'live',
        title: '연결 복구 완료',
        detail: '세션 업데이트 수신이 다시 이어졌습니다.',
      );
    }
    _armSessionSyncWatchdog();
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _markSessionSyncReconnecting({
    required String detail,
    bool shouldNotify = true,
  }) {
    if (currentThreadId.isEmpty) {
      return;
    }
    sessionSyncStatus = SessionSyncStatus.reconnecting;
    sessionSyncDetail = detail;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _markSessionSyncStale(
      {required String detail, bool shouldNotify = true}) {
    if (currentThreadId.isEmpty) {
      return;
    }
    sessionSyncStatus = SessionSyncStatus.stale;
    sessionSyncDetail = detail;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  void _markSessionSyncFailed(
      {required String detail, bool shouldNotify = true}) {
    if (currentThreadId.isEmpty) {
      return;
    }
    _sessionSyncWatchdogTimer?.cancel();
    _sessionSyncWatchdogTimer = null;
    _sessionSyncRetryTimer?.cancel();
    _sessionSyncRetryTimer = null;
    sessionSyncStatus = SessionSyncStatus.failed;
    sessionSyncDetail = detail;
    if (shouldNotify) {
      notifyListeners();
    }
  }

  String _sessionSyncRecoveryDetail(Object error, {required String source}) {
    if (source == 'watchdog') {
      return '마지막 동기화 이후 새 업데이트가 없어 복구를 시도합니다.';
    }
    if (error is AgentApiException) {
      return '세션 동기화 요청이 실패했습니다. [${error.statusCode}] ${error.message}';
    }
    return '세션 연결이 끊기면 복구를 시도합니다.';
  }

  void _recordSessionSyncLog({
    required String kind,
    required String title,
    required String detail,
  }) {
    final trimmedTitle = title.trim();
    final trimmedDetail = detail.trim();
    if (trimmedTitle.isEmpty && trimmedDetail.isEmpty) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    final entry = SessionSyncLogEntryView(
      kind: kind,
      title: trimmedTitle,
      detail: trimmedDetail,
      atMillis: now,
    );

    if (_sessionSyncLogs.isNotEmpty) {
      final latest = _sessionSyncLogs.first;
      if (latest.kind == entry.kind &&
          latest.title == entry.title &&
          latest.detail == entry.detail &&
          now - latest.atMillis < 1500) {
        _sessionSyncLogs[0] = entry;
        return;
      }
    }

    _sessionSyncLogs.insert(0, entry);
    if (_sessionSyncLogs.length > 6) {
      _sessionSyncLogs.removeRange(6, _sessionSyncLogs.length);
    }
  }

  @visibleForTesting
  void debugPushSessionSyncLog({
    required String kind,
    required String title,
    required String detail,
  }) {
    _recordSessionSyncLog(
      kind: kind,
      title: title,
      detail: detail,
    );
    notifyListeners();
  }

  String _formatSessionSyncTimestamp(int value) {
    final local = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '${local.month}/${local.day} $hh:$mm:$ss';
  }

  String _formatSessionSyncRelativeAge(int value) {
    final delta = DateTime.now().millisecondsSinceEpoch - value;
    if (delta < 5000) {
      return '방금 전';
    }
    if (delta < 60000) {
      return '${(delta / 1000).floor()}초 전';
    }
    if (delta < 3600000) {
      return '${(delta / 60000).floor()}분 전';
    }
    return '${(delta / 3600000).floor()}시간 전';
  }

  Map<String, dynamic> _buildMobileFocus(int now) {
    final focus = <String, dynamic>{};
    if (_patchFiles.isNotEmpty) {
      focus['patchPath'] = _patchFiles.first.path;
    }
    if (topErrors.isNotEmpty) {
      final first = topErrors.first;
      final colonIndex = first.indexOf(':');
      if (colonIndex > 0) {
        focus['runErrorPath'] = first.substring(0, colonIndex);
      }
    }
    if (focus.isNotEmpty) {
      focus['updatedAt'] = now;
    }
    return focus;
  }

  Future<void> _publishWorkspaceFocus(String path) async {
    if (currentThreadId.isEmpty) {
      return;
    }

    final normalized = _normalizeWorkspacePath(path);
    if (normalized.isEmpty) {
      return;
    }

    final now = DateTime.now().millisecondsSinceEpoch;
    await _publishSessionLiveStateSafe(
      focus: {
        'activeFilePath': normalized,
        'updatedAt': now,
      },
      workspace: {
        'rootPath': workspaceRootPath,
        'activeFilePath': normalized,
        'updatedAt': now,
      },
    );
  }

  void _clearWorkspaceBrowserState() {
    _workspaceTreeRefreshTimer?.cancel();
    _workspaceTreeRefreshTimer = null;
    _workspaceTreeByPath.clear();
    workspaceFile = const WorkspaceFileContentView();
    workspaceSelectedFilePath = '';
    workspaceFileLoading = false;
    workspaceFileError = null;
  }

  void _syncWorkspaceSurfaceFromLiveSession(SessionLiveView previousLiveSession) {
    final previousFocusPath = _primaryLiveFocusPath(previousLiveSession);
    final nextFocusPath = _primaryLiveFocusPath(liveSession);

    if (nextFocusPath.isNotEmpty &&
        (workspaceSelectedFilePath.isEmpty ||
            workspaceSelectedFilePath == previousFocusPath)) {
      workspaceSelectedFilePath = nextFocusPath;
    }

    if (_workspaceSurfaceSignature(previousLiveSession) ==
        _workspaceSurfaceSignature(liveSession)) {
      return;
    }

    _scheduleWorkspaceTreeRefresh();
  }

  String _primaryLiveFocusPath(SessionLiveView value) {
    for (final candidate in [
      value.focus.activeFilePath,
      value.workspace.activeFilePath,
      value.focus.patchPath,
      value.focus.runErrorPath,
    ]) {
      final normalized = _normalizeWorkspacePath(candidate);
      if (normalized.isNotEmpty) {
        return normalized;
      }
    }
    return '';
  }

  String _workspaceSurfaceSignature(SessionLiveView value) {
    final changed = [
      ...value.workspace.changedFiles,
      ...value.workspace.patchFiles,
    ]..sort();
    return [
      _normalizeWorkspacePath(value.focus.activeFilePath),
      value.focus.selection.trim(),
      _normalizeWorkspacePath(value.focus.patchPath),
      _normalizeWorkspacePath(value.focus.runErrorPath),
      value.focus.runErrorLine.toString(),
      _normalizeWorkspacePath(value.workspace.activeFilePath),
      ...changed.map(_normalizeWorkspacePath),
    ].join('|');
  }

  void _scheduleWorkspaceTreeRefresh() {
    if (_workspaceTreeByPath.isEmpty || currentThreadId.isEmpty) {
      return;
    }

    _workspaceTreeRefreshTimer?.cancel();
    _workspaceTreeRefreshTimer = Timer(
      const Duration(milliseconds: 280),
      () => unawaited(_refreshTrackedWorkspaceTrees()),
    );
  }

  Future<void> _refreshTrackedWorkspaceTrees() async {
    _workspaceTreeRefreshTimer?.cancel();
    _workspaceTreeRefreshTimer = null;

    final refreshTargets = _trackedWorkspaceTreePaths();
    for (final path in refreshTargets) {
      try {
        await loadWorkspaceTree(path, force: true);
      } catch (_) {
        // live sync refresh 실패는 기존 파일 브라우저 상태를 유지한다.
      }
    }
  }

  List<String> _trackedWorkspaceTreePaths() {
    final targets = <String>{};
    if (_workspaceTreeByPath.containsKey('')) {
      targets.add('');
    }

    final interestingFiles = <String>{
      liveSession.focus.activeFilePath,
      liveSession.workspace.activeFilePath,
      liveSession.focus.patchPath,
      liveSession.focus.runErrorPath,
      ...liveSession.workspace.patchFiles,
      ...liveSession.workspace.changedFiles,
      ..._runChangedFiles,
      ...sessionOperation.currentJobFiles,
    }
        .map(_normalizeWorkspacePath)
        .where((item) => item.isNotEmpty)
        .toList();

    for (final filePath in interestingFiles) {
      var parent = _workspaceParentPath(filePath);
      while (true) {
        if (_workspaceTreeByPath.containsKey(parent)) {
          targets.add(parent);
        }
        if (parent.isEmpty) {
          break;
        }
        parent = _workspaceParentPath(parent);
      }
    }

    final ordered = targets.toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    return ordered;
  }

  String _normalizeWorkspacePath(String value) {
    final trimmed = value.trim().replaceAll('\\', '/');
    final segments = <String>[];
    for (final segment in trimmed.split('/')) {
      final part = segment.trim();
      if (part.isEmpty || part == '.') {
        continue;
      }
      if (part == '..') {
        if (segments.isNotEmpty) {
          segments.removeLast();
        }
        continue;
      }
      segments.add(part);
    }
    return segments.join('/');
  }

  String _workspaceParentPath(String value) {
    final normalized = _normalizeWorkspacePath(value);
    if (normalized.isEmpty || !normalized.contains('/')) {
      return '';
    }
    return normalized.substring(0, normalized.lastIndexOf('/'));
  }

  String _liveActivitySummaryForPublish() {
    if (isLoading && activity.isNotEmpty) {
      return '모바일에서 $activity 중';
    }
    if (promptDraft.trim().isNotEmpty) {
      return '모바일에서 프롬프트 작성 중';
    }
    if (_patchFiles.isNotEmpty) {
      return '모바일에서 패치 검토 중';
    }
    if (runStatus.trim().isNotEmpty) {
      return '모바일에서 실행 결과 확인 중';
    }
    return '모바일에서 세션을 보고 있습니다.';
  }

  String _mobileParticipantId() {
    if (directDeviceKey.trim().isNotEmpty) {
      return 'mobile:$directDeviceKey';
    }
    final controlSid = selectedThreadSummary?.sessionId ?? '';
    if (controlSid.trim().isNotEmpty) {
      return 'mobile:$controlSid';
    }
    return 'mobile:app';
  }

  Future<List<Map<String, dynamic>>> _sendEnvelopeAndAck(
    Map<String, dynamic> envelope,
  ) async {
    final direct = _directSession;
    if (direct != null && direct.isControlReady) {
      try {
        return await _sendEnvelopeAndAckViaDirect(direct, envelope);
      } catch (e) {
        _appendDirectLog('DIRECT 제어 실패 -> HTTP 폴백: $e');
      }
    }

    return _sendEnvelopeAndAckViaHttp(envelope);
  }

  Future<List<Map<String, dynamic>>> _sendEnvelopeAndAckViaDirect(
    MobileDirectSignalingSession direct,
    Map<String, dynamic> envelope,
  ) async {
    final responses =
        await direct.sendControlEnvelopeAndAwaitResponses(envelope);

    for (final env in responses) {
      final typ = env['type']?.toString() ?? '';
      if (typ == 'CMD_ACK') {
        continue;
      }

      final rid = env['rid']?.toString() ?? '';
      if (rid.isEmpty) {
        continue;
      }

      final sid = env['sid']?.toString() ?? _sid();
      final ackEnvelope = _buildEnvelope(
        sid: sid,
        type: 'CMD_ACK',
        payload: {
          'requestRid': rid,
          'accepted': true,
          'message': 'received by mobile',
        },
      );

      try {
        await direct.sendControlEnvelope(ackEnvelope);
      } catch (_) {
        // ACK 실패는 다음 refresh에서 pending으로 관측된다.
      }
    }

    return responses;
  }

  Future<List<Map<String, dynamic>>> _sendEnvelopeAndAckViaHttp(
    Map<String, dynamic> envelope,
  ) async {
    Map<String, dynamic> response;
    try {
      response = await _api.sendEnvelope(agentBaseUrl, envelope);
    } on AgentApiException catch (e) {
      final recovered = _extractResponsesFromBody(e.responseBody);
      if (recovered.isNotEmpty) {
        return recovered;
      }
      rethrow;
    }

    final raw = response['responses'];
    if (raw is! List) {
      return const [];
    }

    final responses = raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();

    for (final env in responses) {
      final typ = env['type']?.toString() ?? '';
      if (typ == 'CMD_ACK') {
        continue;
      }
      final rid = env['rid']?.toString() ?? '';
      final sid = env['sid']?.toString() ?? _sid();
      if (rid.isEmpty) {
        continue;
      }

      final ackEnvelope = _buildEnvelope(
        sid: sid,
        type: 'CMD_ACK',
        payload: {
          'requestRid': rid,
          'accepted': true,
          'message': 'received by mobile',
        },
      );

      try {
        await _api.sendEnvelope(agentBaseUrl, ackEnvelope);
      } catch (_) {
        // ACK 실패는 다음 refresh에서 pending으로 관측된다.
      }
    }

    return responses;
  }

  void _applyResponses(List<Map<String, dynamic>> responses) {
    for (final response in responses) {
      final type = response['type']?.toString() ?? '';
      final payload = response['payload'];
      if (payload is! Map) {
        continue;
      }
      final map = Map<String, dynamic>.from(payload);

      if (type == 'CMD_ACK') {
        if (map['accepted'] != true) {
          final message = map['message']?.toString().trim() ?? '';
          if (message.isNotEmpty) {
            errorMessage = message;
          }
        }
        continue;
      }

      if (type == 'PROMPT_ACK') {
        currentThreadId = map['threadId']?.toString() ?? currentThreadId;
        currentJobId = map['jobId']?.toString();
      }

      if (type == 'PATCH_READY') {
        patchSummary = map['summary']?.toString() ?? '';
        _patchFiles
          ..clear()
          ..addAll(_parsePatchFiles(map['files']));
      }

      if (type == 'PATCH_RESULT') {
        patchResultStatus = map['status']?.toString() ?? '';
        patchResultMessage = map['message']?.toString() ?? '';
      }

      if (type == 'RUN_RESULT') {
        runStatus = map['status']?.toString() ?? '';
        runSummary = map['summary']?.toString() ?? '';
        runExcerpt = map['excerpt']?.toString() ?? '';
        runOutput = map['output']?.toString() ?? runExcerpt;
        _runChangedFiles
          ..clear()
          ..addAll(_parseStringList(map['changedFiles']));
        if (_runChangedFiles.isEmpty) {
          _runChangedFiles.addAll(_currentPatchPaths());
        }
        topErrors
          ..clear()
          ..addAll(_parseTopErrors(map['topErrors']));
      }
    }
  }

  void _syncDerivedStateFromThreadEvents() {
    final selectedJobId = selectedThreadSummary?.currentJobId ?? '';
    currentJobId = selectedJobId.isEmpty ? currentJobId : selectedJobId;
    promptDraft = '';
    patchSummary = '';
    patchResultStatus = '';
    patchResultMessage = '';
    runStatus = '';
    runSummary = '';
    runExcerpt = '';
    runOutput = '';
    _runChangedFiles.clear();
    topErrors.clear();

    for (final event in _threadEvents) {
      if (event.jobId.isNotEmpty) {
        currentJobId = event.jobId;
      }
      if (event.kind == 'prompt_submitted' && event.body.isNotEmpty) {
        promptDraft = event.body;
      }
      if (event.kind == 'patch_ready') {
        patchSummary = event.data['summary']?.toString() ?? event.body;
        _patchFiles
          ..clear()
          ..addAll(_parsePatchFiles(event.data['files']));
      }
      if (event.kind == 'patch_applied') {
        patchResultStatus =
            event.data['status']?.toString() ?? patchResultStatus;
        patchResultMessage = event.body.isEmpty
            ? (event.data['message']?.toString() ?? patchResultMessage)
            : event.body;
      }
      if (event.kind == 'run_finished') {
        runStatus = event.data['status']?.toString() ?? runStatus;
        runSummary = event.data['summary']?.toString() ?? event.body;
        runExcerpt = event.data['excerpt']?.toString() ?? runExcerpt;
        runOutput = event.data['output']?.toString() ?? runOutput;
        _runChangedFiles
          ..clear()
          ..addAll(_parseStringList(event.data['changedFiles']));
        topErrors
          ..clear()
          ..addAll(_parseTopErrors(event.data['topErrors']));
      }
    }

    if (_runChangedFiles.isEmpty) {
      _runChangedFiles.addAll(_currentPatchPaths());
    }
  }

  AckMetricsView _parseAckMetrics(dynamic raw) {
    if (raw is! Map) {
      return const AckMetricsView();
    }

    final metrics = Map<String, dynamic>.from(raw);
    final pendingByTransportRaw = metrics['pendingByTransport'];
    final pendingByTransport = pendingByTransportRaw is Map
        ? Map<String, dynamic>.from(pendingByTransportRaw)
        : const <String, dynamic>{};

    return AckMetricsView(
      pendingCount: _toInt(metrics['pendingCount']),
      maxPendingCount: _toInt(metrics['maxPendingCount']),
      ackedCount: _toInt(metrics['ackedCount']),
      retryDispatchCount: _toInt(metrics['retryDispatchCount']),
      expiredCount: _toInt(metrics['expiredCount']),
      exhaustedCount: _toInt(metrics['exhaustedCount']),
      lastAckRttMs: _toInt(metrics['lastAckRttMs']),
      avgAckRttMs: _toInt(metrics['avgAckRttMs']),
      maxAckRttMs: _toInt(metrics['maxAckRttMs']),
      pendingHttpCount: _toInt(pendingByTransport['http']),
      pendingP2PCount: _toInt(pendingByTransport['p2p']),
      pendingUnknownCount: _toInt(pendingByTransport['unknown']),
    );
  }

  AdapterRuntimeView _parseAdapterRuntime(Map<String, dynamic> raw) {
    return AdapterRuntimeView.fromMap(raw);
  }

  List<RunProfileView> _parseRunProfiles(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((item) => RunProfileView.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  List<ThreadSummaryView> _parseThreads(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((item) =>
            ThreadSummaryView.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  List<ThreadEventView> _parseThreadEvents(dynamic raw) {
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((item) => ThreadEventView.fromMap(Map<String, dynamic>.from(item)))
        .toList();
  }

  List<RuntimeTransitionView> _parseHistory(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw
        .whereType<Map>()
        .map(
          (item) => RuntimeTransitionView(
            state: item['state']?.toString() ?? '',
            note: item['note']?.toString() ?? '',
            atMillis: _toInt(item['at']),
          ),
        )
        .toList();
  }

  List<PatchFileView> _parsePatchFiles(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw.whereType<Map>().map((file) {
      final hunksRaw = file['hunks'];
      final hunks = <PatchHunkView>[];
      if (hunksRaw is List) {
        for (final hunk in hunksRaw.whereType<Map>()) {
          hunks.add(
            PatchHunkView(
              id: hunk['hunkId']?.toString() ?? '',
              header: hunk['header']?.toString() ?? '',
              diff: hunk['diff']?.toString() ?? '',
              risk: hunk['risk']?.toString() ?? '',
            ),
          );
        }
      }

      return PatchFileView(
        path: file['path']?.toString() ?? '',
        status: file['status']?.toString() ?? '',
        hunks: hunks,
      );
    }).toList();
  }

  List<String> _parseTopErrors(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    return raw.whereType<Map>().map((item) {
      final message = item['message']?.toString() ?? '';
      final path = item['path']?.toString() ?? '';
      final line = _toInt(item['line']);
      if (path.isEmpty) {
        return message;
      }
      return '$path:$line $message';
    }).toList();
  }

  List<String> _parseStringList(dynamic raw) {
    if (raw is! List) {
      return const [];
    }

    final seen = <String>{};
    final values = <String>[];
    for (final item in raw) {
      final value = item?.toString().trim() ?? '';
      if (value.isEmpty || seen.contains(value)) {
        continue;
      }
      seen.add(value);
      values.add(value);
    }
    return values;
  }

  List<String> _currentPatchPaths() {
    final seen = <String>{};
    final values = <String>[];
    for (final file in _patchFiles) {
      final value = file.path.trim();
      if (value.isEmpty || seen.contains(value)) {
        continue;
      }
      seen.add(value);
      values.add(value);
    }
    return values;
  }

  Future<void> _restoreSettings() async {
    final snapshot = await _settingsStore.load();
    if (snapshot.agentBaseUrl.trim().isNotEmpty) {
      agentBaseUrl = snapshot.agentBaseUrl.trim();
    }
    if (snapshot.signalingBaseUrl.trim().isNotEmpty) {
      signalingBaseUrl = snapshot.signalingBaseUrl.trim();
    }
    _recentHosts
      ..clear()
      ..addAll(_sortedRecentHosts(snapshot.recentHosts));
    notifyListeners();
  }

  List<Map<String, dynamic>> _extractResponsesFromBody(
    Map<String, dynamic>? body,
  ) {
    if (body == null) {
      return const [];
    }
    final raw = body['responses'];
    if (raw is! List) {
      return const [];
    }
    return raw
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .toList();
  }

  Future<void> _persistSettings() {
    return _settingsStore.save(
      AppSettingsSnapshot(
        agentBaseUrl: agentBaseUrl.trim(),
        signalingBaseUrl: signalingBaseUrl.trim(),
        recentHosts: _sortedRecentHosts(_recentHosts),
      ),
    );
  }

  void _rememberCurrentHost() {
    final normalizedAgent = agentBaseUrl.trim();
    if (normalizedAgent.isEmpty) {
      return;
    }

    final entry = SavedHostEntry(
      agentBaseUrl: normalizedAgent,
      signalingBaseUrl: signalingBaseUrl.trim(),
      lastUsedAtMillis: DateTime.now().millisecondsSinceEpoch,
    );

    _recentHosts
      ..removeWhere((item) => item.agentBaseUrl == entry.agentBaseUrl)
      ..insert(0, entry);

    final sorted = _sortedRecentHosts(_recentHosts);
    _recentHosts
      ..clear()
      ..addAll(sorted);
  }

  List<SavedHostEntry> _sortedRecentHosts(Iterable<SavedHostEntry> hosts) {
    final items = hosts
        .where((item) => item.agentBaseUrl.trim().isNotEmpty)
        .toList()
      ..sort((a, b) => b.lastUsedAtMillis.compareTo(a.lastUsedAtMillis));
    if (items.length > 5) {
      return items.sublist(0, 5);
    }
    return items;
  }

  Map<String, dynamic> _buildEnvelope({
    String? sid,
    required String type,
    required Map<String, dynamic> payload,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final seq = _seq++;
    final rid = 'rid_${type.toLowerCase()}_$seq';

    return {
      'sid': sid ?? _sid(),
      'rid': rid,
      'seq': seq,
      'ts': now,
      'type': type,
      'payload': payload,
    };
  }

  String _sid() {
    if (directSessionId.isNotEmpty) {
      return directSessionId;
    }
    if (sessionId.isNotEmpty) {
      return sessionId;
    }
    final sharedControlSessionId = selectedThreadSummary?.sessionId ?? '';
    if (sharedControlSessionId.isNotEmpty) {
      return sharedControlSessionId;
    }
    return 'sid-mobile-demo';
  }

  int _toInt(dynamic value) {
    if (value is int) {
      return value;
    }
    if (value is num) {
      return value.toInt();
    }
    return int.tryParse(value?.toString() ?? '') ?? 0;
  }

  Future<void> _run(String name, Future<void> Function() action) async {
    isLoading = true;
    activity = name;
    errorMessage = null;
    notifyListeners();

    try {
      await action();
    } on AgentApiException catch (e) {
      errorMessage = '[${e.statusCode}] ${e.message}';
    } on SignalingApiException catch (e) {
      errorMessage = '[${e.statusCode}] ${e.message}';
    } catch (e) {
      errorMessage = e.toString();
    } finally {
      isLoading = false;
      activity = '';
      notifyListeners();
    }
  }

  void _bindDirectSession(MobileDirectSignalingSession session) {
    _directStateSub = session.states.listen((state) {
      directSignalingState = state.name.toUpperCase();
      directSignalingConnected = session.isConnected;
      directPeerConnected = session.isPeerConnected;
      directControlReady = session.isControlReady;
      notifyListeners();
    });

    _directEventSub = session.events.listen((event) {
      _appendDirectLog(event.label);
      directSignalingConnected = session.isConnected;
      directPeerConnected = session.isPeerConnected;
      directControlReady = session.isControlReady;
      notifyListeners();
    });

    _directEnvelopeSub = session.envelopes.listen((envelope) {
      _handleDirectEnvelope(envelope);
      notifyListeners();
    });

    _directErrorSub = session.errors.listen((message) {
      _appendDirectLog('ERROR: $message');
      errorMessage = message;
      notifyListeners();
    });
  }

  Future<void> _closeDirectSignalingSession() async {
    await _directStateSub?.cancel();
    await _directEventSub?.cancel();
    await _directEnvelopeSub?.cancel();
    await _directErrorSub?.cancel();
    _directStateSub = null;
    _directEventSub = null;
    _directEnvelopeSub = null;
    _directErrorSub = null;

    final session = _directSession;
    _directSession = null;
    if (session != null) {
      await session.close();
      session.dispose();
    }

    directSignalingConnected = false;
    directPeerConnected = false;
    directControlReady = false;
    directSessionId = '';
    directDeviceKey = '';
  }

  void _handleDirectEnvelope(Map<String, dynamic> envelope) {
    final typ = envelope['type']?.toString() ?? 'UNKNOWN';
    final sid = envelope['sid']?.toString() ?? '';
    _appendDirectLog('ENVELOPE: $typ sid=$sid');

    if (typ == 'CMD_ACK') {
      final payload = envelope['payload'];
      if (payload is Map) {
        final requestRid = payload['requestRid']?.toString() ?? '';
        if (requestRid.isNotEmpty) {
          _appendDirectLog('DIRECT ACK 수신: requestRid=$requestRid');
        }
      }
    }
  }

  void _appendDirectLog(String log) {
    _directSignalLogs.insert(0, log);
    if (_directSignalLogs.length > 60) {
      _directSignalLogs.removeRange(60, _directSignalLogs.length);
    }
  }

  String _resolveDirectPairingCode() {
    if (directPairingCode.trim().isNotEmpty) {
      return directPairingCode.trim();
    }
    if (pairingCode.trim().isNotEmpty) {
      return pairingCode.trim();
    }
    return '';
  }

  @override
  void dispose() {
    unawaited(_closeDirectSignalingSession());
    unawaited(_stopSessionStream());
    _workspaceTreeRefreshTimer?.cancel();
    _api.dispose();
    super.dispose();
  }
}

class AckMetricsView {
  const AckMetricsView({
    this.pendingCount = 0,
    this.maxPendingCount = 0,
    this.ackedCount = 0,
    this.retryDispatchCount = 0,
    this.expiredCount = 0,
    this.exhaustedCount = 0,
    this.lastAckRttMs = 0,
    this.avgAckRttMs = 0,
    this.maxAckRttMs = 0,
    this.pendingHttpCount = 0,
    this.pendingP2PCount = 0,
    this.pendingUnknownCount = 0,
  });

  final int pendingCount;
  final int maxPendingCount;
  final int ackedCount;
  final int retryDispatchCount;
  final int expiredCount;
  final int exhaustedCount;
  final int lastAckRttMs;
  final int avgAckRttMs;
  final int maxAckRttMs;
  final int pendingHttpCount;
  final int pendingP2PCount;
  final int pendingUnknownCount;

  String get pendingSplitLabel {
    return 'http=$pendingHttpCount / p2p=$pendingP2PCount / unknown=$pendingUnknownCount';
  }
}

class PatchFileView {
  const PatchFileView({
    required this.path,
    required this.status,
    required this.hunks,
  });

  final String path;
  final String status;
  final List<PatchHunkView> hunks;
}

class PatchHunkView {
  const PatchHunkView({
    required this.id,
    required this.header,
    required this.diff,
    required this.risk,
  });

  final String id;
  final String header;
  final String diff;
  final String risk;
}

class RuntimeTransitionView {
  const RuntimeTransitionView({
    required this.state,
    required this.note,
    required this.atMillis,
  });

  final String state;
  final String note;
  final int atMillis;

  String get atLabel {
    if (atMillis <= 0) {
      return '-';
    }

    final dt = DateTime.fromMillisecondsSinceEpoch(atMillis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class AdapterRuntimeView {
  const AdapterRuntimeView({
    this.name = '',
    this.mode = '',
    this.ready = false,
    this.workspaceRoot = '',
    this.binaryPath = '',
    this.notes = const [],
  });

  final String name;
  final String mode;
  final bool ready;
  final String workspaceRoot;
  final String binaryPath;
  final List<String> notes;

  factory AdapterRuntimeView.fromMap(Map<String, dynamic> map) {
    final notesRaw = map['notes'];
    return AdapterRuntimeView(
      name: map['name']?.toString() ?? '',
      mode: map['mode']?.toString() ?? '',
      ready: map['ready'] == true,
      workspaceRoot: map['workspaceRoot']?.toString() ?? '',
      binaryPath: map['binaryPath']?.toString() ?? '',
      notes: notesRaw is List
          ? notesRaw.map((item) => item.toString()).toList()
          : const [],
    );
  }
}

class BootstrapStatusView {
  const BootstrapStatusView({
    this.agentBaseUrl = '',
    this.signalingBaseUrl = '',
    this.workspaceRoot = '',
    this.currentThreadId = '',
    this.currentSessionId = '',
    this.adapter = const BootstrapAdapterView(),
    this.recentThreads = const [],
  });

  final String agentBaseUrl;
  final String signalingBaseUrl;
  final String workspaceRoot;
  final String currentThreadId;
  final String currentSessionId;
  final BootstrapAdapterView adapter;
  final List<BootstrapThreadView> recentThreads;

  factory BootstrapStatusView.fromMap(Map<String, dynamic> map) {
    final adapterRaw = map['adapter'];
    final recentThreadsRaw = map['recentThreads'];
    return BootstrapStatusView(
      agentBaseUrl: map['agentBaseUrl']?.toString() ?? '',
      signalingBaseUrl: map['signalingBaseUrl']?.toString() ?? '',
      workspaceRoot: map['workspaceRoot']?.toString() ?? '',
      currentThreadId: map['currentThreadId']?.toString() ?? '',
      currentSessionId: map['currentSessionId']?.toString() ?? '',
      adapter: adapterRaw is Map
          ? BootstrapAdapterView.fromMap(Map<String, dynamic>.from(adapterRaw))
          : const BootstrapAdapterView(),
      recentThreads: recentThreadsRaw is List
          ? recentThreadsRaw
              .whereType<Map>()
              .map((item) =>
                  BootstrapThreadView.fromMap(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
    );
  }
}

class BootstrapAdapterView {
  const BootstrapAdapterView({
    this.name = '',
    this.mode = '',
    this.provider = '',
    this.ready = false,
  });

  final String name;
  final String mode;
  final String provider;
  final bool ready;

  factory BootstrapAdapterView.fromMap(Map<String, dynamic> map) {
    return BootstrapAdapterView(
      name: map['name']?.toString() ?? '',
      mode: map['mode']?.toString() ?? '',
      provider: map['provider']?.toString() ?? '',
      ready: map['ready'] == true,
    );
  }
}

class BootstrapThreadView {
  const BootstrapThreadView({
    required this.id,
    required this.title,
    required this.updatedAtMillis,
    required this.current,
  });

  final String id;
  final String title;
  final int updatedAtMillis;
  final bool current;

  factory BootstrapThreadView.fromMap(Map<String, dynamic> map) {
    return BootstrapThreadView(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
      current: map['current'] == true,
    );
  }

  String get updatedAtLabel {
    if (updatedAtMillis <= 0) {
      return '-';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class RunProfileView {
  const RunProfileView({
    required this.id,
    required this.label,
    required this.command,
    required this.scope,
    required this.optional,
  });

  final String id;
  final String label;
  final String command;
  final String scope;
  final bool optional;

  factory RunProfileView.fromMap(Map<String, dynamic> map) {
    return RunProfileView(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      command: map['command']?.toString() ?? '',
      scope: map['scope']?.toString() ?? '',
      optional: map['optional'] == true,
    );
  }

  String get displayLabel {
    if (label.isEmpty || label == id) {
      return id;
    }
    return '$label ($id)';
  }
}

class ThreadSummaryView {
  const ThreadSummaryView({
    required this.id,
    required this.title,
    required this.sessionId,
    required this.state,
    required this.currentJobId,
    required this.lastEventKind,
    required this.lastEventText,
    required this.updatedAtMillis,
  });

  final String id;
  final String title;
  final String sessionId;
  final String state;
  final String currentJobId;
  final String lastEventKind;
  final String lastEventText;
  final int updatedAtMillis;

  factory ThreadSummaryView.fromMap(Map<String, dynamic> map) {
    return ThreadSummaryView(
      id: map['id']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      sessionId: map['sessionId']?.toString() ?? '',
      state: map['state']?.toString() ?? '',
      currentJobId: map['currentJobId']?.toString() ?? '',
      lastEventKind: map['lastEventKind']?.toString() ?? '',
      lastEventText: map['lastEventText']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }

  String get updatedAtLabel {
    if (updatedAtMillis <= 0) {
      return '-';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class ThreadEventView {
  const ThreadEventView({
    required this.id,
    required this.threadId,
    required this.jobId,
    required this.kind,
    required this.role,
    required this.title,
    required this.body,
    required this.data,
    required this.atMillis,
  });

  final String id;
  final String threadId;
  final String jobId;
  final String kind;
  final String role;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final int atMillis;

  factory ThreadEventView.fromMap(Map<String, dynamic> map) {
    final data = map['data'] is Map
        ? Map<String, dynamic>.from(map['data'] as Map)
        : <String, dynamic>{};
    return ThreadEventView(
      id: map['id']?.toString() ?? '',
      threadId: map['threadId']?.toString() ?? '',
      jobId: map['jobId']?.toString() ?? '',
      kind: map['kind']?.toString() ?? '',
      role: map['role']?.toString() ?? '',
      title: map['title']?.toString() ?? '',
      body: map['body']?.toString() ?? '',
      data: data,
      atMillis: map['at'] is num
          ? (map['at'] as num).toInt()
          : int.tryParse(map['at']?.toString() ?? '') ?? 0,
    );
  }

  String get atLabel {
    if (atMillis <= 0) {
      return '-';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(atMillis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    final ss = dt.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class SessionParticipantView {
  const SessionParticipantView({
    required this.participantId,
    required this.clientType,
    required this.displayName,
    required this.active,
    required this.lastSeenAtMillis,
  });

  final String participantId;
  final String clientType;
  final String displayName;
  final bool active;
  final int lastSeenAtMillis;

  factory SessionParticipantView.fromMap(Map<String, dynamic> map) {
    return SessionParticipantView(
      participantId: map['participantId']?.toString() ?? '',
      clientType: map['clientType']?.toString() ?? '',
      displayName: map['displayName']?.toString() ?? '',
      active: map['active'] == true,
      lastSeenAtMillis: map['lastSeenAt'] is num
          ? (map['lastSeenAt'] as num).toInt()
          : int.tryParse(map['lastSeenAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionSyncLogEntryView {
  const SessionSyncLogEntryView({
    required this.kind,
    required this.title,
    required this.detail,
    required this.atMillis,
  });

  final String kind;
  final String title;
  final String detail;
  final int atMillis;

  String get atLabel {
    if (atMillis <= 0) {
      return '-';
    }
    final local = DateTime.fromMillisecondsSinceEpoch(atMillis).toLocal();
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    final ss = local.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }
}

class SessionComposerView {
  const SessionComposerView({
    this.draftText = '',
    this.isTyping = false,
    this.updatedAtMillis = 0,
  });

  final String draftText;
  final bool isTyping;
  final int updatedAtMillis;

  factory SessionComposerView.fromMap(Map<String, dynamic> map) {
    return SessionComposerView(
      draftText: map['draftText']?.toString() ?? '',
      isTyping: map['isTyping'] == true,
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionFocusView {
  const SessionFocusView({
    this.activeFilePath = '',
    this.selection = '',
    this.patchPath = '',
    this.runErrorPath = '',
    this.runErrorLine = 0,
    this.updatedAtMillis = 0,
  });

  final String activeFilePath;
  final String selection;
  final String patchPath;
  final String runErrorPath;
  final int runErrorLine;
  final int updatedAtMillis;

  factory SessionFocusView.fromMap(Map<String, dynamic> map) {
    return SessionFocusView(
      activeFilePath: map['activeFilePath']?.toString() ?? '',
      selection: map['selection']?.toString() ?? '',
      patchPath: map['patchPath']?.toString() ?? '',
      runErrorPath: map['runErrorPath']?.toString() ?? '',
      runErrorLine: map['runErrorLine'] is num
          ? (map['runErrorLine'] as num).toInt()
          : int.tryParse(map['runErrorLine']?.toString() ?? '') ?? 0,
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionActivityView {
  const SessionActivityView({
    this.phase = '',
    this.summary = '',
    this.updatedAtMillis = 0,
  });

  final String phase;
  final String summary;
  final int updatedAtMillis;

  factory SessionActivityView.fromMap(Map<String, dynamic> map) {
    return SessionActivityView(
      phase: map['phase']?.toString() ?? '',
      summary: map['summary']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionReasoningView {
  const SessionReasoningView({
    this.title = '',
    this.summary = '',
    this.sourceKind = '',
    this.updatedAtMillis = 0,
  });

  final String title;
  final String summary;
  final String sourceKind;
  final int updatedAtMillis;

  factory SessionReasoningView.fromMap(Map<String, dynamic> map) {
    return SessionReasoningView(
      title: map['title']?.toString() ?? '',
      summary: map['summary']?.toString() ?? '',
      sourceKind: map['sourceKind']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionPlanItemView {
  const SessionPlanItemView({
    this.id = '',
    this.label = '',
    this.status = '',
    this.detail = '',
    this.updatedAtMillis = 0,
  });

  final String id;
  final String label;
  final String status;
  final String detail;
  final int updatedAtMillis;

  factory SessionPlanItemView.fromMap(Map<String, dynamic> map) {
    return SessionPlanItemView(
      id: map['id']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      status: map['status']?.toString() ?? '',
      detail: map['detail']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionPlanView {
  const SessionPlanView({
    this.summary = '',
    this.items = const [],
    this.updatedAtMillis = 0,
  });

  final String summary;
  final List<SessionPlanItemView> items;
  final int updatedAtMillis;

  factory SessionPlanView.fromMap(Map<String, dynamic> map) {
    final itemsRaw = map['items'];
    return SessionPlanView(
      summary: map['summary']?.toString() ?? '',
      items: itemsRaw is List
          ? itemsRaw
              .whereType<Map>()
              .map((item) =>
                  SessionPlanItemView.fromMap(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionToolActivityView {
  const SessionToolActivityView({
    this.kind = '',
    this.label = '',
    this.status = '',
    this.detail = '',
    this.atMillis = 0,
  });

  final String kind;
  final String label;
  final String status;
  final String detail;
  final int atMillis;

  factory SessionToolActivityView.fromMap(Map<String, dynamic> map) {
    return SessionToolActivityView(
      kind: map['kind']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      status: map['status']?.toString() ?? '',
      detail: map['detail']?.toString() ?? '',
      atMillis: map['at'] is num
          ? (map['at'] as num).toInt()
          : int.tryParse(map['at']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionToolView {
  const SessionToolView({
    this.currentLabel = '',
    this.currentStatus = '',
    this.activities = const [],
    this.updatedAtMillis = 0,
  });

  final String currentLabel;
  final String currentStatus;
  final List<SessionToolActivityView> activities;
  final int updatedAtMillis;

  factory SessionToolView.fromMap(Map<String, dynamic> map) {
    final activitiesRaw = map['activities'];
    return SessionToolView(
      currentLabel: map['currentLabel']?.toString() ?? '',
      currentStatus: map['currentStatus']?.toString() ?? '',
      activities: activitiesRaw is List
          ? activitiesRaw
              .whereType<Map>()
              .map((item) => SessionToolActivityView.fromMap(
                  Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionTerminalView {
  const SessionTerminalView({
    this.status = '',
    this.profileId = '',
    this.label = '',
    this.command = '',
    this.summary = '',
    this.excerpt = '',
    this.output = '',
    this.updatedAtMillis = 0,
  });

  final String status;
  final String profileId;
  final String label;
  final String command;
  final String summary;
  final String excerpt;
  final String output;
  final int updatedAtMillis;

  factory SessionTerminalView.fromMap(Map<String, dynamic> map) {
    return SessionTerminalView(
      status: map['status']?.toString() ?? '',
      profileId: map['profileId']?.toString() ?? '',
      label: map['label']?.toString() ?? '',
      command: map['command']?.toString() ?? '',
      summary: map['summary']?.toString() ?? '',
      excerpt: map['excerpt']?.toString() ?? '',
      output: map['output']?.toString() ?? '',
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionWorkspaceView {
  const SessionWorkspaceView({
    this.rootPath = '',
    this.activeFilePath = '',
    this.patchFiles = const [],
    this.changedFiles = const [],
    this.updatedAtMillis = 0,
  });

  final String rootPath;
  final String activeFilePath;
  final List<String> patchFiles;
  final List<String> changedFiles;
  final int updatedAtMillis;

  factory SessionWorkspaceView.fromMap(Map<String, dynamic> map) {
    final patchFilesRaw = map['patchFiles'];
    final changedFilesRaw = map['changedFiles'];
    return SessionWorkspaceView(
      rootPath: map['rootPath']?.toString() ?? '',
      activeFilePath: map['activeFilePath']?.toString() ?? '',
      patchFiles: patchFilesRaw is List
          ? patchFilesRaw
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      changedFiles: changedFilesRaw is List
          ? changedFilesRaw
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
    );
  }
}

class SessionRunErrorView {
  const SessionRunErrorView({
    this.path = '',
    this.line = 0,
    this.message = '',
  });

  final String path;
  final int line;
  final String message;

  factory SessionRunErrorView.fromMap(Map<String, dynamic> map) {
    return SessionRunErrorView(
      path: map['path']?.toString() ?? '',
      line: map['line'] is num
          ? (map['line'] as num).toInt()
          : int.tryParse(map['line']?.toString() ?? '') ?? 0,
      message: map['message']?.toString() ?? '',
    );
  }
}

class SessionLiveView {
  const SessionLiveView({
    this.participants = const [],
    this.composer = const SessionComposerView(),
    this.focus = const SessionFocusView(),
    this.activity = const SessionActivityView(),
    this.reasoning = const SessionReasoningView(),
    this.plan = const SessionPlanView(),
    this.tools = const SessionToolView(),
    this.terminal = const SessionTerminalView(),
    this.workspace = const SessionWorkspaceView(),
  });

  final List<SessionParticipantView> participants;
  final SessionComposerView composer;
  final SessionFocusView focus;
  final SessionActivityView activity;
  final SessionReasoningView reasoning;
  final SessionPlanView plan;
  final SessionToolView tools;
  final SessionTerminalView terminal;
  final SessionWorkspaceView workspace;

  factory SessionLiveView.fromMap(Map<String, dynamic> map) {
    final participantsRaw = map['participants'];
    return SessionLiveView(
      participants: participantsRaw is List
          ? participantsRaw
              .whereType<Map>()
              .map((item) => SessionParticipantView.fromMap(
                  Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      composer: map['composer'] is Map
          ? SessionComposerView.fromMap(
              Map<String, dynamic>.from(map['composer'] as Map))
          : const SessionComposerView(),
      focus: map['focus'] is Map
          ? SessionFocusView.fromMap(
              Map<String, dynamic>.from(map['focus'] as Map))
          : const SessionFocusView(),
      activity: map['activity'] is Map
          ? SessionActivityView.fromMap(
              Map<String, dynamic>.from(map['activity'] as Map))
          : const SessionActivityView(),
      reasoning: map['reasoning'] is Map
          ? SessionReasoningView.fromMap(
              Map<String, dynamic>.from(map['reasoning'] as Map))
          : const SessionReasoningView(),
      plan: map['plan'] is Map
          ? SessionPlanView.fromMap(
              Map<String, dynamic>.from(map['plan'] as Map))
          : const SessionPlanView(),
      tools: map['tools'] is Map
          ? SessionToolView.fromMap(
              Map<String, dynamic>.from(map['tools'] as Map))
          : const SessionToolView(),
      terminal: map['terminal'] is Map
          ? SessionTerminalView.fromMap(
              Map<String, dynamic>.from(map['terminal'] as Map))
          : const SessionTerminalView(),
      workspace: map['workspace'] is Map
          ? SessionWorkspaceView.fromMap(
              Map<String, dynamic>.from(map['workspace'] as Map))
          : const SessionWorkspaceView(),
    );
  }
}

class SessionOperationView {
  const SessionOperationView({
    this.currentJobId = '',
    this.phase = '',
    this.patchSummary = '',
    this.patchFileCount = 0,
    this.patchFiles = const [],
    this.patchResultStatus = '',
    this.patchResultMessage = '',
    this.runProfileId = '',
    this.runLabel = '',
    this.runCommand = '',
    this.runStatus = '',
    this.runSummary = '',
    this.runExcerpt = '',
    this.runOutput = '',
    this.runChangedFiles = const [],
    this.runTopErrors = const [],
    this.currentJobFiles = const [],
    this.lastError = '',
  });

  final String currentJobId;
  final String phase;
  final String patchSummary;
  final int patchFileCount;
  final List<String> patchFiles;
  final String patchResultStatus;
  final String patchResultMessage;
  final String runProfileId;
  final String runLabel;
  final String runCommand;
  final String runStatus;
  final String runSummary;
  final String runExcerpt;
  final String runOutput;
  final List<String> runChangedFiles;
  final List<SessionRunErrorView> runTopErrors;
  final List<String> currentJobFiles;
  final String lastError;

  factory SessionOperationView.fromMap(Map<String, dynamic> map) {
    final patchFilesRaw = map['patchFiles'];
    final runChangedFilesRaw = map['runChangedFiles'];
    final currentJobFilesRaw = map['currentJobFiles'];
    final runTopErrorsRaw = map['runTopErrors'];
    return SessionOperationView(
      currentJobId: map['currentJobId']?.toString() ?? '',
      phase: map['phase']?.toString() ?? '',
      patchSummary: map['patchSummary']?.toString() ?? '',
      patchFileCount: map['patchFileCount'] is num
          ? (map['patchFileCount'] as num).toInt()
          : int.tryParse(map['patchFileCount']?.toString() ?? '') ?? 0,
      patchFiles: patchFilesRaw is List
          ? patchFilesRaw
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      patchResultStatus: map['patchResultStatus']?.toString() ?? '',
      patchResultMessage: map['patchResultMessage']?.toString() ?? '',
      runProfileId: map['runProfileId']?.toString() ?? '',
      runLabel: map['runLabel']?.toString() ?? '',
      runCommand: map['runCommand']?.toString() ?? '',
      runStatus: map['runStatus']?.toString() ?? '',
      runSummary: map['runSummary']?.toString() ?? '',
      runExcerpt: map['runExcerpt']?.toString() ?? '',
      runOutput: map['runOutput']?.toString() ?? '',
      runChangedFiles: runChangedFilesRaw is List
          ? runChangedFilesRaw
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      runTopErrors: runTopErrorsRaw is List
          ? runTopErrorsRaw
              .whereType<Map>()
              .map((item) =>
                  SessionRunErrorView.fromMap(Map<String, dynamic>.from(item)))
              .toList()
          : const [],
      currentJobFiles: currentJobFilesRaw is List
          ? currentJobFilesRaw
              .map((item) => item.toString())
              .where((item) => item.isNotEmpty)
              .toList()
          : const [],
      lastError: map['lastError']?.toString() ?? '',
    );
  }
}

class WorkspaceTreeEntryView {
  const WorkspaceTreeEntryView({
    required this.name,
    required this.path,
    required this.isDir,
    required this.gitStatus,
    required this.isActive,
    required this.isChanged,
    required this.isPatch,
    required this.hasError,
  });

  final String name;
  final String path;
  final bool isDir;
  final String gitStatus;
  final bool isActive;
  final bool isChanged;
  final bool isPatch;
  final bool hasError;

  factory WorkspaceTreeEntryView.fromMap(Map<String, dynamic> map) {
    return WorkspaceTreeEntryView(
      name: map['name']?.toString() ?? '',
      path: map['path']?.toString() ?? '',
      isDir: map['isDir'] == true,
      gitStatus: map['gitStatus']?.toString() ?? '',
      isActive: map['isActive'] == true,
      isChanged: map['isChanged'] == true,
      isPatch: map['isPatch'] == true,
      hasError: map['hasError'] == true,
    );
  }
}

class WorkspaceFileContentView {
  const WorkspaceFileContentView({
    this.path = '',
    this.content = '',
    this.gitStatus = '',
    this.sizeBytes = 0,
    this.updatedAtMillis = 0,
    this.isWritable = false,
  });

  final String path;
  final String content;
  final String gitStatus;
  final int sizeBytes;
  final int updatedAtMillis;
  final bool isWritable;

  factory WorkspaceFileContentView.fromMap(Map<String, dynamic> map) {
    return WorkspaceFileContentView(
      path: map['path']?.toString() ?? '',
      content: map['content']?.toString() ?? '',
      gitStatus: map['gitStatus']?.toString() ?? '',
      sizeBytes: map['sizeBytes'] is num
          ? (map['sizeBytes'] as num).toInt()
          : int.tryParse(map['sizeBytes']?.toString() ?? '') ?? 0,
      updatedAtMillis: map['updatedAt'] is num
          ? (map['updatedAt'] as num).toInt()
          : int.tryParse(map['updatedAt']?.toString() ?? '') ?? 0,
      isWritable: map['isWritable'] == true,
    );
  }

  String get updatedAtLabel {
    if (updatedAtMillis <= 0) {
      return '-';
    }
    final dt = DateTime.fromMillisecondsSinceEpoch(updatedAtMillis);
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}
