import 'package:flutter/material.dart';

import '../state/app_controller.dart';

class StatusScreen extends StatefulWidget {
  const StatusScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<StatusScreen> createState() => _StatusScreenState();
}

class _StatusScreenState extends State<StatusScreen> {
  late final TextEditingController _agentUrlController;
  late final TextEditingController _signalingUrlController;
  late final TextEditingController _directPairingCodeController;

  @override
  void initState() {
    super.initState();
    _agentUrlController =
        TextEditingController(text: widget.controller.agentBaseUrl);
    _signalingUrlController =
        TextEditingController(text: widget.controller.signalingBaseUrl);
    _directPairingCodeController = TextEditingController(
      text: widget.controller.directPairingCode.isNotEmpty
          ? widget.controller.directPairingCode
          : widget.controller.pairingCode,
    );
  }

  @override
  void dispose() {
    _agentUrlController.dispose();
    _signalingUrlController.dispose();
    _directPairingCodeController.dispose();
    super.dispose();
  }

  String _msLabel(int value) => '${value}ms';

  void _syncControllerText(TextEditingController controller, String value) {
    if (controller.text == value) {
      return;
    }
    controller.value = controller.value.copyWith(
      text: value,
      selection: TextSelection.collapsed(offset: value.length),
      composing: TextRange.empty,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final state = widget.controller.connectionState;
        final runtime = widget.controller.adapterRuntime;
        final bootstrap = widget.controller.bootstrap;
        final resolvedPairingCode =
            widget.controller.directPairingCode.isNotEmpty
                ? widget.controller.directPairingCode
                : widget.controller.pairingCode;

        _syncControllerText(_agentUrlController, widget.controller.agentBaseUrl);
        _syncControllerText(
          _signalingUrlController,
          widget.controller.signalingBaseUrl,
        );

        if (_directPairingCodeController.text.isEmpty &&
            resolvedPairingCode.isNotEmpty) {
          _directPairingCodeController.text = resolvedPairingCode;
        }

        return ListView(
          key: const ValueKey('status-screen'),
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          children: [
            _SectionCard(
              title: '에이전트 런타임',
              subtitle: '현재 연결된 workspace adapter와 작업 디렉토리를 확인합니다.',
              accent: const Color(0xFFB9E6DA),
              background: const Color(0xFFEDF9F6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricPill(
                        label: 'Adapter',
                        value: runtime.name.isEmpty ? '-' : runtime.name,
                      ),
                      _MetricPill(
                        label: 'Mode',
                        value: runtime.mode.isEmpty ? '-' : runtime.mode,
                      ),
                      _MetricPill(
                        label: 'Ready',
                        value: runtime.ready ? 'true' : 'false',
                      ),
                      _MetricPill(
                        label: 'Thread',
                        value: widget.controller.currentThreadTitle,
                      ),
                      _MetricPill(
                        label: 'Run Profiles',
                        value: '${widget.controller.runProfiles.length}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(
                    label: '작업 디렉토리',
                    value: runtime.workspaceRoot.isEmpty ? '-' : runtime.workspaceRoot,
                  ),
                  _InfoRow(
                    label: 'binary',
                    value: runtime.binaryPath.isEmpty ? '-' : runtime.binaryPath,
                  ),
                  if (runtime.notes.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('runtime notes',
                        style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    ...runtime.notes.map((note) => Text('• $note')),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: '연결 설정',
              subtitle: 'Agent URL 하나만 맞추면 signaling 값도 자동 감지합니다.',
              accent: const Color(0xFFD6E9E3),
              background: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _agentUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Agent Base URL',
                      hintText: 'http://127.0.0.1:8080',
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _signalingUrlController,
                    decoration: const InputDecoration(
                      labelText: 'Signaling Base URL',
                      hintText: 'http://127.0.0.1:8081',
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.tonalIcon(
                          onPressed: widget.controller.isLoading
                              ? null
                              : () async {
                                  widget.controller.updateAgentBaseUrl(
                                      _agentUrlController.text);
                                  widget.controller.updateSignalingBaseUrl(
                                    _signalingUrlController.text,
                                  );
                                  await widget.controller.refreshStatus();
                                },
                          icon: const Icon(Icons.auto_fix_high_outlined),
                          label: const Text('설정 저장 + 자동 감지'),
                        ),
                      ),
                    ],
                  ),
                  if (widget.controller.recentHosts.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    Text('최근 host', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: widget.controller.recentHosts
                          .map(
                            (entry) => ActionChip(
                              label: Text(entry.agentBaseUrl),
                              onPressed: widget.controller.isLoading
                                  ? null
                                  : () async {
                                      await widget.controller.useRecentHost(entry);
                                    },
                            ),
                          )
                          .toList(),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: '자동 Bootstrap',
              subtitle: 'agent가 현재 연결 host 기준으로 signaling/workspace/thread 기본값을 내려줍니다.',
              accent: const Color(0xFFE7DBF8),
              background: const Color(0xFFFAF7FF),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricPill(
                        label: 'Provider',
                        value: bootstrap.adapter.provider.isEmpty
                            ? '-'
                            : bootstrap.adapter.provider,
                      ),
                      _MetricPill(
                        label: 'Bootstrap Ready',
                        value: bootstrap.adapter.ready ? 'true' : 'false',
                      ),
                      _MetricPill(
                        label: 'Recent Threads',
                        value: '${bootstrap.recentThreads.length}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(
                    label: 'bootstrap agent',
                    value: bootstrap.agentBaseUrl.isEmpty
                        ? '-'
                        : bootstrap.agentBaseUrl,
                  ),
                  _InfoRow(
                    label: 'bootstrap signaling',
                    value: bootstrap.signalingBaseUrl.isEmpty
                        ? '-'
                        : bootstrap.signalingBaseUrl,
                  ),
                  _InfoRow(
                    label: 'bootstrap workspace',
                    value: bootstrap.workspaceRoot.isEmpty
                        ? '-'
                        : bootstrap.workspaceRoot,
                  ),
                  _InfoRow(
                    label: 'bootstrap current thread',
                    value: bootstrap.currentThreadId.isEmpty
                        ? '-'
                        : bootstrap.currentThreadId,
                  ),
                  if (bootstrap.controlTimeouts.isConfigured) ...[
                    _InfoRow(
                      label: 'control timeout 기본',
                      value: bootstrap.controlTimeouts.defaultTimeout.isEmpty
                          ? '-'
                          : bootstrap.controlTimeouts.defaultTimeout,
                    ),
                    _InfoRow(
                      label: 'control timeout prompt',
                      value: bootstrap.controlTimeouts.promptSubmit.isEmpty
                          ? '-'
                          : bootstrap.controlTimeouts.promptSubmit,
                    ),
                    _InfoRow(
                      label: 'control timeout patch',
                      value: bootstrap.controlTimeouts.patchApply.isEmpty
                          ? '-'
                          : bootstrap.controlTimeouts.patchApply,
                    ),
                    _InfoRow(
                      label: 'control timeout run',
                      value: bootstrap.controlTimeouts.runProfile.isEmpty
                          ? '-'
                          : bootstrap.controlTimeouts.runProfile,
                    ),
                  ],
                  if (bootstrap.recentThreads.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('최근 스레드', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 6),
                    ...bootstrap.recentThreads.take(3).map(
                      (thread) => Text(
                        '• ${thread.title} (${thread.updatedAtLabel})${thread.current ? ' · current' : ''}',
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: '세션 상태',
              subtitle: '모바일 앱과 agent 간 제어 경로 상태입니다.',
              accent: const Color(0xFFD6E9E3),
              background: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricPill(label: 'Current', value: state),
                      _MetricPill(
                        label: 'P2P Active',
                        value: widget.controller.p2pActive ? 'true' : 'false',
                      ),
                      _MetricPill(
                        label: 'Pending ACK',
                        value: '${widget.controller.pendingAckCount}',
                      ),
                      _MetricPill(
                        label: 'Control Path',
                        value: widget.controller.controlPath,
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  _InfoRow(
                    label: 'sessionId',
                    value: widget.controller.sessionId.isEmpty
                        ? '-'
                        : widget.controller.sessionId,
                  ),
                  _InfoRow(
                    label: 'pairingCode',
                    value: widget.controller.pairingCode.isEmpty
                        ? '-'
                        : widget.controller.pairingCode,
                  ),
                  if (widget.controller.activity.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text('작업중: ${widget.controller.activity}'),
                  ],
                  if (widget.controller.errorMessage != null) ...[
                    const SizedBox(height: 8),
                    Text(
                      widget.controller.errorMessage!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'ACK Observability',
              subtitle: '직접 제어와 HTTP 폴백 모두 같은 런타임 지표로 봅니다.',
              accent: const Color(0xFFFFE2B8),
              background: const Color(0xFFFFFBF2),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricPill(
                        label: 'Avg RTT',
                        value: _msLabel(widget.controller.ackMetrics.avgAckRttMs),
                      ),
                      _MetricPill(
                        label: 'Last RTT',
                        value: _msLabel(widget.controller.ackMetrics.lastAckRttMs),
                      ),
                      _MetricPill(
                        label: 'Max RTT',
                        value: _msLabel(widget.controller.ackMetrics.maxAckRttMs),
                      ),
                      _MetricPill(
                        label: 'Peak Queue',
                        value: '${widget.controller.ackMetrics.maxPendingCount}',
                      ),
                      _MetricPill(
                        label: 'Acked',
                        value: '${widget.controller.ackMetrics.ackedCount}',
                      ),
                      _MetricPill(
                        label: 'Retries',
                        value: '${widget.controller.ackMetrics.retryDispatchCount}',
                      ),
                      _MetricPill(
                        label: 'Expired',
                        value: '${widget.controller.ackMetrics.expiredCount}',
                      ),
                      _MetricPill(
                        label: 'Exhausted',
                        value: '${widget.controller.ackMetrics.exhaustedCount}',
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'transport split: ${widget.controller.ackMetrics.pendingSplitLabel}',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: widget.controller.isLoading
                        ? null
                        : widget.controller.startP2P,
                    icon: const Icon(Icons.link),
                    label: const Text('P2P 시작'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1F8C77),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: widget.controller.isLoading
                        ? null
                        : widget.controller.stopP2P,
                    icon: const Icon(Icons.link_off),
                    label: const Text('P2P 종료'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: widget.controller.isLoading
                  ? null
                  : widget.controller.refreshStatus,
              icon: const Icon(Icons.refresh),
              label: const Text('상태 갱신'),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Direct Signaling + WebRTC',
              subtitle: '가능하면 direct datachannel, 실패 시 HTTP로 폴백합니다.',
              accent: const Color(0xFFDBDFF7),
              background: const Color(0xFFF7F8FF),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TextField(
                    controller: _directPairingCodeController,
                    decoration: const InputDecoration(
                      labelText: 'Pairing Code',
                      hintText: '예: 9K3P7Q',
                    ),
                  ),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: widget.controller.isLoading
                              ? null
                              : () async {
                                  widget.controller.updateDirectPairingCode(
                                    _directPairingCodeController.text,
                                  );
                                  await widget.controller.connectDirectSignaling();
                                },
                          icon: const Icon(Icons.usb),
                          label: const Text('Direct 연결'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: widget.controller.isLoading
                              ? null
                              : () async {
                                  await widget.controller.disconnectDirectSignaling();
                                },
                          icon: const Icon(Icons.usb_off),
                          label: const Text('Direct 종료'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _MetricPill(
                        label: 'Direct State',
                        value: widget.controller.directSignalingState,
                      ),
                      _MetricPill(
                        label: 'WS Connected',
                        value: widget.controller.directSignalingConnected
                            ? 'true'
                            : 'false',
                      ),
                      _MetricPill(
                        label: 'Peer Connected',
                        value: widget.controller.directPeerConnected
                            ? 'true'
                            : 'false',
                      ),
                      _MetricPill(
                        label: 'Control Ready',
                        value: widget.controller.directControlReady
                            ? 'true'
                            : 'false',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _InfoRow(
                    label: 'directSessionId',
                    value: widget.controller.directSessionId.isEmpty
                        ? '-'
                        : widget.controller.directSessionId,
                  ),
                  _InfoRow(
                    label: 'directDeviceKey',
                    value: widget.controller.directDeviceKey.isEmpty
                        ? '-'
                        : widget.controller.directDeviceKey,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Control Ready=true 이면 Prompt/검토 액션이 HTTP보다 DIRECT 경로를 우선 사용합니다.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 8),
                  Text('최근 direct 로그',
                      style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  if (widget.controller.directSignalLogs.isEmpty)
                    const Text('로그 없음')
                  else
                    ...widget.controller.directSignalLogs
                        .take(10)
                        .map((log) => Text(log,
                            style: Theme.of(context).textTheme.bodySmall)),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _SectionCard(
              title: 'Runtime Timeline',
              subtitle: '연결 상태 전이 로그입니다.',
              accent: const Color(0xFFDCE3ED),
              background: Colors.white,
              child: widget.controller.runtimeHistory.isEmpty
                  ? const Text('히스토리가 없습니다.')
                  : Column(
                      children: widget.controller.runtimeHistory
                          .map(
                            (event) => ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.timeline),
                              title: Text(event.state),
                              subtitle:
                                  Text(event.note.isEmpty ? '-' : event.note),
                              trailing: Text(event.atLabel),
                            ),
                          )
                          .toList(),
                    ),
            ),
          ],
        );
      },
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
    required this.accent,
    required this.background,
  });

  final String title;
  final String subtitle;
  final Widget child;
  final Color accent;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(subtitle, style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(22),
        border: Border.all(color: const Color(0xFFD6E9E3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.bodySmall),
          Text(
            value,
            style: Theme.of(
              context,
            ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text('$label: $value'),
    );
  }
}
