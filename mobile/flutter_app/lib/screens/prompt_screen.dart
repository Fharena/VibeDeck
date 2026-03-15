import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'review_screen.dart';
import 'status_screen.dart';

Color _syncTone(BuildContext context, SessionSyncStatus status) {
  switch (status) {
    case SessionSyncStatus.live:
      return const Color(0xFF2E9D78);
    case SessionSyncStatus.stale:
      return const Color(0xFFD28A32);
    case SessionSyncStatus.reconnecting:
      return const Color(0xFF4E8DFF);
    case SessionSyncStatus.failed:
      return Theme.of(context).colorScheme.error;
    case SessionSyncStatus.idle:
      return const Color(0xFF8B9AAF);
  }
}

IconData _syncIcon(SessionSyncStatus status) {
  switch (status) {
    case SessionSyncStatus.live:
      return Icons.cloud_done_outlined;
    case SessionSyncStatus.stale:
      return Icons.schedule_outlined;
    case SessionSyncStatus.reconnecting:
      return Icons.autorenew_rounded;
    case SessionSyncStatus.failed:
      return Icons.sync_problem_outlined;
    case SessionSyncStatus.idle:
      return Icons.link_outlined;
  }
}

String _compactPath(String value, {int keep = 34}) {
  final trimmed = value.trim();
  if (trimmed.length <= keep) {
    return trimmed;
  }
  return '...${trimmed.substring(trimmed.length - keep)}';
}

String _firstNonEmptyText(Iterable<String> values, {String fallback = ''}) {
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return fallback;
}

List<String> _dedupeNonEmptyPaths(Iterable<String> values) {
  final result = <String>[];
  final seen = <String>{};

  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isEmpty || !seen.add(trimmed)) {
      continue;
    }
    result.add(trimmed);
  }

  return result;
}

String _planStatusLabel(String value) {
  switch (value) {
    case 'completed':
      return '완료';
    case 'in_progress':
      return '진행 중';
    case 'blocked':
      return '막힘';
    case 'pending':
      return '대기';
    default:
      return value.isEmpty ? '-' : value;
  }
}

class PromptScreen extends StatefulWidget {
  const PromptScreen({
    super.key,
    required this.controller,
  });

  final AppController controller;

  @override
  State<PromptScreen> createState() => _PromptScreenState();
}

class _PromptScreenState extends State<PromptScreen> {
  final _promptController = TextEditingController(
    text: '테스트 실패 원인을 분석하고 auth middleware 패치를 제안해줘.',
  );
  final _promptFocusNode = FocusNode();

  final Map<String, bool> _context = {
    'activeFile': true,
    'selection': true,
    'latestError': true,
    'workspaceSummary': false,
  };

  @override
  void dispose() {
    _promptController.dispose();
    _promptFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        _syncPromptDraft();

        return ListView(
          key: const ValueKey('session-screen'),
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 20),
          children: [
            _SessionHeroCard(
              controller: widget.controller,
              onNewThread: _handleNewThread,
              onSelectThread: (threadId) async {
                await widget.controller.selectThread(threadId);
              },
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: '세션에 요청',
              subtitle: '채팅 입력과 공유 draft를 한 카드에 모아 세션 흐름을 끊지 않습니다.',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.controller.liveDraftPreview.isNotEmpty ||
                      widget.controller.promptDraft.isNotEmpty) ...[
                    _StreamSurface(
                      label: '공유 draft',
                      child: Text(
                        widget.controller.liveDraftPreview.isNotEmpty
                            ? widget.controller.liveDraftPreview
                            : widget.controller.promptDraft,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: const Color(0xFFDCE6F2),
                              height: 1.45,
                            ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  TextField(
                    controller: _promptController,
                    focusNode: _promptFocusNode,
                    minLines: 5,
                    maxLines: 8,
                    style: const TextStyle(
                      color: Color(0xFFEAF1F8),
                      height: 1.45,
                    ),
                    onChanged: widget.controller.updatePromptDraft,
                    decoration: InputDecoration(
                      hintText: '예: 로그인 실패 원인을 먼저 좁히고, 변경 파일을 최소화한 패치를 제안해줘.',
                      hintStyle: const TextStyle(color: Color(0xFF7D8EA2)),
                      filled: true,
                      fillColor: const Color(0xFF0E151C),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(18),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.all(16),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '컨텍스트',
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: const Color(0xFFF4F7FB),
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _ContextChip(
                        label: '활성 파일',
                        value: _context['activeFile']!,
                        onChanged: (value) =>
                            setState(() => _context['activeFile'] = value),
                      ),
                      _ContextChip(
                        label: '선택 영역',
                        value: _context['selection']!,
                        onChanged: (value) =>
                            setState(() => _context['selection'] = value),
                      ),
                      _ContextChip(
                        label: '최근 오류',
                        value: _context['latestError']!,
                        onChanged: (value) =>
                            setState(() => _context['latestError'] = value),
                      ),
                      _ContextChip(
                        label: '워크스페이스 요약',
                        value: _context['workspaceSummary']!,
                        onChanged: (value) => setState(
                          () => _context['workspaceSummary'] = value,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: const Icon(Icons.send_rounded),
                          label: const Text('세션에 보내기'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            backgroundColor: const Color(0xFFE4B15A),
                            foregroundColor: const Color(0xFF10161D),
                          ),
                          onPressed: widget.controller.isLoading
                              ? null
                              : _submitPrompt,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('입력 지우기'),
                          style: OutlinedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            foregroundColor: const Color(0xFFDCE6F2),
                            side: const BorderSide(color: Color(0xFF32404D)),
                          ),
                          onPressed: _clearPrompt,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            _WorkstreamCard(
              controller: widget.controller,
              onOpenReview: _showReviewSheet,
              onOpenStatus: _showStatusSheet,
              onOpenTerminal: _showTerminalSheet,
              onOpenFiles: _showFileSheet,
            ),
            const SizedBox(height: 14),
            _SectionCard(
              title: '작업 로그',
              subtitle: '프롬프트, 패치, 실행 결과를 시간순으로 이어서 읽는 메인 피드입니다.',
              child: widget.controller.threadEvents.isEmpty
                  ? Text(
                      '아직 세션 이벤트가 없습니다. 위 입력창에서 첫 요청을 보내면 여기로 흐름이 쌓입니다.',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF9FB0C0),
                            height: 1.45,
                          ),
                    )
                  : Column(
                      children: widget.controller.threadEvents
                          .map((event) => _ThreadEventTile(event: event))
                          .toList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  void _handleNewThread() {
    widget.controller.beginNewThread();
    _clearPrompt();
  }

  void _clearPrompt() {
    _promptController.clear();
    widget.controller.updatePromptDraft('');
  }

  Future<void> _submitPrompt() async {
    final messenger = ScaffoldMessenger.of(context);
    await widget.controller.submitPrompt(
      prompt: _promptController.text,
      context: _context,
    );

    if (!mounted) {
      return;
    }

    final error = widget.controller.errorMessage;
    if (error == null) {
      _clearPrompt();
    }
    messenger.showSnackBar(
      SnackBar(
        content: Text(error ?? 'PROMPT_SUBMIT 완료'),
      ),
    );
  }

  void _syncPromptDraft() {
    if (_promptFocusNode.hasFocus) {
      return;
    }

    final desiredText = widget.controller.liveDraftPreview.isNotEmpty
        ? widget.controller.liveDraftPreview
        : widget.controller.promptDraft;
    if (_promptController.text == desiredText) {
      return;
    }

    _promptController.value = _promptController.value.copyWith(
      text: desiredText,
      selection: TextSelection.collapsed(offset: desiredText.length),
      composing: TextRange.empty,
    );
  }

  Future<void> _showReviewSheet() async {
    await _showBottomSheet(
      title: '패치와 실행',
      subtitle: '검토와 실행 결과를 세션 흐름과 붙여서 확인합니다.',
      child: ReviewScreen(controller: widget.controller),
    );
  }

  Future<void> _showStatusSheet() async {
    await _showBottomSheet(
      title: '세션 센터',
      subtitle: '연결, bootstrap, direct signaling 같은 운영 표면을 모아둡니다.',
      child: StatusScreen(controller: widget.controller),
    );
  }

  Future<void> _showTerminalSheet() async {
    await _showBottomSheet(
      title: '터미널',
      subtitle: '현재 세션에서 보고 있는 실행 상태와 최근 출력을 바로 확인합니다.',
      child: _TerminalSheet(controller: widget.controller),
    );
  }

  Future<void> _showFileSheet() async {
    await _showBottomSheet(
      title: '파일 포커스',
      subtitle: '현재 세션의 focus, changed files, patch files를 한 번에 봅니다.',
      child: _FileFocusSheet(controller: widget.controller),
    );
  }

  Future<void> _showBottomSheet({
    required String title,
    required String subtitle,
    required Widget child,
  }) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (context) {
        return SafeArea(
          child: FractionallySizedBox(
            heightFactor: 0.94,
            child: Container(
              decoration: const BoxDecoration(
                color: Color(0xFF0F161D),
                borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
              ),
              child: Column(
                children: [
                  const SizedBox(height: 12),
                  Container(
                    width: 52,
                    height: 5,
                    decoration: BoxDecoration(
                      color: const Color(0xFF2C3844),
                      borderRadius: BorderRadius.circular(999),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                title,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      color: const Color(0xFFF4F7FB),
                                    ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                subtitle,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: const Color(0xFF93A4B7),
                                    ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          color: const Color(0xFFDCE6F2),
                          icon: const Icon(Icons.close),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF24303B)),
                  Expanded(child: child),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SessionHeroCard extends StatelessWidget {
  const _SessionHeroCard({
    required this.controller,
    required this.onNewThread,
    required this.onSelectThread,
  });

  final AppController controller;
  final VoidCallback onNewThread;
  final ValueChanged<String> onSelectThread;

  @override
  Widget build(BuildContext context) {
    final syncTone = _syncTone(context, controller.sessionSyncStatus);
    final activeThreads = controller.threads.take(4).toList();

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF141F29), Color(0xFF0E161D)],
        ),
        border: Border.all(color: const Color(0xFF27333F)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 18,
            offset: Offset(0, 10),
          ),
        ],
      ),
      padding: const EdgeInsets.all(18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '공유 세션',
                      style: Theme.of(context).textTheme.labelLarge?.copyWith(
                            color: const Color(0xFFE4B15A),
                            letterSpacing: 0.8,
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      controller.currentThreadTitle,
                      style:
                          Theme.of(context).textTheme.headlineMedium?.copyWith(
                                color: const Color(0xFFF4F7FB),
                                height: 1.1,
                              ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '${controller.currentSessionPhase} · ${controller.connectionState}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFF96A7BA),
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed: onNewThread,
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFDCE6F2),
                ),
                icon: const Icon(Icons.add_comment_outlined),
                label: const Text('새 세션'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(
                icon: _syncIcon(controller.sessionSyncStatus),
                label: controller.sessionSyncStatusLabel,
                tone: syncTone,
              ),
              _MetricPill(
                icon: Icons.group_outlined,
                label: controller.liveParticipantSummary,
              ),
              _MetricPill(
                icon: Icons.route_outlined,
                label: controller.controlPath,
              ),
              _MetricPill(
                icon: Icons.rule_folder_outlined,
                label: '패치 ${controller.patchFiles.length}개',
              ),
            ],
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _MetricChip(
                label: '현재 Job',
                value: controller.currentJobId ?? '-',
              ),
              _MetricChip(
                label: '포커스',
                value: _compactPath(controller.liveFocusSummary),
              ),
              _MetricChip(
                label: '작업 디렉토리',
                value: controller.adapterRuntime.workspaceRoot.isEmpty
                    ? '-'
                    : _compactPath(controller.adapterRuntime.workspaceRoot,
                        keep: 28),
              ),
            ],
          ),
          if (activeThreads.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              '최근 세션',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: const Color(0xFFDCE6F2),
                  ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: activeThreads
                  .map(
                    (thread) => ChoiceChip(
                      label: Text(
                        thread.title,
                        overflow: TextOverflow.ellipsis,
                      ),
                      selected: thread.id == controller.currentThreadId,
                      onSelected: (_) => onSelectThread(thread.id),
                      backgroundColor: const Color(0xFF111922),
                      selectedColor: const Color(0xFF253445),
                      side: const BorderSide(color: Color(0xFF2B3742)),
                      labelStyle: TextStyle(
                        color: thread.id == controller.currentThreadId
                            ? const Color(0xFFF4F7FB)
                            : const Color(0xFFB4C2CF),
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _WorkstreamCard extends StatelessWidget {
  const _WorkstreamCard({
    required this.controller,
    required this.onOpenReview,
    required this.onOpenStatus,
    required this.onOpenTerminal,
    required this.onOpenFiles,
  });

  final AppController controller;
  final VoidCallback onOpenReview;
  final VoidCallback onOpenStatus;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final reasoning = controller.liveSession.reasoning.summary.trim();
    final planItems = controller.liveSession.plan.items.take(4).toList();
    final toolActivities =
        controller.liveSession.tools.activities.reversed.take(3).toList();
    final terminal = controller.liveSession.terminal;
    final workspace = controller.liveSession.workspace;
    final fileHighlights = <String>{};

    if (workspace.activeFilePath.trim().isNotEmpty) {
      fileHighlights.add(workspace.activeFilePath.trim());
    }
    fileHighlights.addAll(
      workspace.changedFiles.where((path) => path.trim().isNotEmpty).take(4),
    );
    if (fileHighlights.isEmpty) {
      fileHighlights.addAll(
        controller.currentJobFiles
            .where((path) => path.trim().isNotEmpty)
            .take(4),
      );
    }

    return _SectionCard(
      title: '지금 진행 중',
      subtitle: '작업 로그, 복구 상태, 패치/실행 요약을 메인 흐름 안에서 압축해서 보여줍니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            controller.liveActivitySummary,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricChip(
                  label: '세션 단계', value: controller.currentSessionPhase),
              _MetricChip(
                  label: '참여자', value: controller.liveParticipantSummary),
              _MetricChip(
                  label: '마지막 동기화', value: controller.sessionLastSyncedLabel),
            ],
          ),
          const SizedBox(height: 12),
          _SessionSyncBanner(controller: controller),
          if (reasoning.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '판단 요약',
              child: Text(
                reasoning,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFDCE6F2),
                      height: 1.45,
                    ),
              ),
            ),
          ],
          if (planItems.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '계획 추적',
              child: _PlanTrace(items: planItems),
            ),
          ],
          if (controller.liveSession.tools.currentLabel.trim().isNotEmpty ||
              toolActivities.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '작업 로그',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (controller.liveSession.tools.currentLabel
                      .trim()
                      .isNotEmpty)
                    Text(
                      '${controller.liveSession.tools.currentLabel} · ${controller.liveSession.tools.currentStatus.isEmpty ? '진행 중' : controller.liveSession.tools.currentStatus}',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFFF4F7FB),
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  if (toolActivities.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...toolActivities.map(
                      (activity) => Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(
                          '• ${activity.label.isEmpty ? activity.kind : activity.label}${activity.status.isEmpty ? '' : ' · ${activity.status}'}${activity.detail.isEmpty ? '' : ' · ${activity.detail}'}',
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFFB7C4D2),
                                    height: 1.35,
                                  ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          const SizedBox(height: 12),
          _StreamSurface(
            label: '패치',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  controller.patchSummary.isNotEmpty
                      ? controller.patchSummary
                      : controller.patchAvailabilityReason,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFFDCE6F2),
                        height: 1.45,
                      ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _MetricPill(
                      icon: Icons.description_outlined,
                      label: '파일 ${controller.patchFiles.length}',
                    ),
                    if ((controller.currentJobId ?? '').isNotEmpty)
                      _MetricPill(
                        icon: Icons.work_outline,
                        label: controller.currentJobId!,
                      ),
                  ],
                ),
              ],
            ),
          ),
          if (controller.runSummary.isNotEmpty ||
              controller.runStatus.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '실행',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    controller.runSummary.isEmpty
                        ? '최근 실행 결과가 아직 없습니다.'
                        : controller.runSummary,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFFDCE6F2),
                          height: 1.45,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      if (controller.runStatus.isNotEmpty)
                        _MetricPill(
                          icon: Icons.play_circle_outline,
                          label: controller.runStatus,
                        ),
                      if (controller.topErrors.isNotEmpty)
                        _MetricPill(
                          icon: Icons.error_outline,
                          label: '상위 에러 ${controller.topErrors.length}',
                        ),
                    ],
                  ),
                  if (controller.topErrors.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ...controller.topErrors.take(2).map(
                          (line) => Text(
                            '• $line',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: const Color(0xFFB7C4D2),
                                      height: 1.35,
                                    ),
                          ),
                        ),
                  ],
                ],
              ),
            ),
          ],
          if (fileHighlights.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '파일 포커스',
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: fileHighlights
                    .map((path) => _MetricPill(
                        icon: Icons.insert_drive_file_outlined,
                        label: _compactPath(path)))
                    .toList(),
              ),
            ),
          ],
          if (terminal.summary.isNotEmpty ||
              terminal.command.isNotEmpty ||
              terminal.status.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '터미널',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (terminal.summary.isNotEmpty)
                    Text(
                      terminal.summary,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: const Color(0xFFDCE6F2),
                            height: 1.45,
                          ),
                    ),
                  if (terminal.command.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      terminal.command,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF93A4B7),
                            fontFamily: 'monospace',
                          ),
                    ),
                  ],
                ],
              ),
            ),
          ],
          if (controller.errorMessage != null) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '최근 오류',
              accent: Theme.of(context).colorScheme.error,
              child: Text(
                controller.errorMessage!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFFFD5D2),
                      height: 1.45,
                    ),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onOpenReview,
                  style: FilledButton.styleFrom(
                    foregroundColor: const Color(0xFFF4F7FB),
                    backgroundColor: const Color(0xFF213244),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.rule_folder_outlined),
                  label: const Text('패치와 실행'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onOpenStatus,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDCE6F2),
                    side: const BorderSide(color: Color(0xFF32404D)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.tune),
                  label: const Text('세션 센터'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: onOpenTerminal,
                  style: FilledButton.styleFrom(
                    foregroundColor: const Color(0xFF10161D),
                    backgroundColor: const Color(0xFFE4B15A),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.terminal_rounded),
                  label: const Text('터미널 보기'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onOpenFiles,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDCE6F2),
                    side: const BorderSide(color: Color(0xFF32404D)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  icon: const Icon(Icons.account_tree_outlined),
                  label: const Text('파일 보기'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _TerminalSheet extends StatelessWidget {
  const _TerminalSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final terminal = controller.liveSession.terminal;
    final status = _firstNonEmptyText([terminal.status, controller.runStatus],
        fallback: '대기 중');
    final profile = _firstNonEmptyText([
      terminal.label,
      terminal.profileId,
      controller.sessionOperation.runLabel,
      controller.sessionOperation.runProfileId,
    ]);
    final command = _firstNonEmptyText([
      terminal.command,
      controller.sessionOperation.runCommand,
    ]);
    final summary = _firstNonEmptyText([
      terminal.summary,
      controller.runSummary,
    ], fallback: '최근 실행 결과가 아직 없습니다.');
    final output = _firstNonEmptyText([
      terminal.output,
      terminal.excerpt,
      controller.runOutput,
      controller.runExcerpt,
    ]);
    final recentFiles = _dedupeNonEmptyPaths([
      ...controller.runChangedFiles,
      ...controller.currentJobFiles,
    ]);

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _MetricPill(
              icon: Icons.play_circle_outline,
              label: status,
              tone: status == 'success'
                  ? const Color(0xFF2E9D78)
                  : const Color(0xFFE4B15A),
            ),
            if (profile.isNotEmpty)
              _MetricPill(
                icon: Icons.terminal_rounded,
                label: profile,
                tone: const Color(0xFF4E8DFF),
              ),
            if (recentFiles.isNotEmpty)
              _MetricPill(
                icon: Icons.insert_drive_file_outlined,
                label: '변경 파일 ${recentFiles.length}',
              ),
          ],
        ),
        const SizedBox(height: 12),
        _StreamSurface(
          label: '실행 요약',
          child: Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFDCE6F2),
                  height: 1.45,
                ),
          ),
        ),
        if (command.isNotEmpty) ...[
          const SizedBox(height: 12),
          _StreamSurface(
            label: '실행 명령',
            child: SelectableText(
              command,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFDCE6F2),
                    fontFamily: 'monospace',
                    height: 1.45,
                  ),
            ),
          ),
        ],
        const SizedBox(height: 12),
        _StreamSurface(
          label: '최근 출력',
          child: output.isEmpty
              ? Text(
                  '아직 터미널 출력이 없습니다. 실행 프로파일을 돌리면 최근 출력이 여기에 표시됩니다.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: const Color(0xFFB7C4D2),
                        height: 1.45,
                      ),
                )
              : Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: const Color(0xFF091017),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF202A35)),
                  ),
                  padding: const EdgeInsets.all(12),
                  child: SelectableText(
                    output,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFEAF1F8),
                          fontFamily: 'monospace',
                          height: 1.4,
                        ),
                  ),
                ),
        ),
        if (controller.topErrors.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SheetListBlock(
            label: '상위 에러',
            icon: Icons.error_outline,
            items: controller.topErrors.take(6).toList(),
            emptyMessage: '표시할 에러가 없습니다.',
          ),
        ],
        if (recentFiles.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SheetListBlock(
            label: '최근 변경 파일',
            icon: Icons.insert_drive_file_outlined,
            items: recentFiles.take(8).toList(),
            emptyMessage: '최근 변경 파일이 없습니다.',
          ),
        ],
      ],
    );
  }
}

class _FileFocusSheet extends StatelessWidget {
  const _FileFocusSheet({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final workspace = controller.liveSession.workspace;
    final focus = controller.liveSession.focus;
    final rootPath = _firstNonEmptyText([
      workspace.rootPath,
      controller.adapterRuntime.workspaceRoot,
    ]);
    final focusPaths = _dedupeNonEmptyPaths([
      focus.activeFilePath,
      workspace.activeFilePath,
      focus.patchPath,
      focus.runErrorPath,
    ]);
    final changedFiles = _dedupeNonEmptyPaths([
      ...workspace.changedFiles,
      ...controller.runChangedFiles,
      ...controller.currentJobFiles,
    ]);
    final patchFiles = _dedupeNonEmptyPaths([
      ...workspace.patchFiles,
      ...controller.patchFiles.map((file) => file.path),
    ]);
    final selection = focus.selection.trim();
    final runError = focus.runErrorPath.trim().isEmpty
        ? ''
        : focus.runErrorLine > 0
            ? '${focus.runErrorPath.trim()}:${focus.runErrorLine}'
            : focus.runErrorPath.trim();
    final hasData = rootPath.isNotEmpty ||
        focusPaths.isNotEmpty ||
        changedFiles.isNotEmpty ||
        patchFiles.isNotEmpty ||
        selection.isNotEmpty ||
        runError.isNotEmpty;

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 28),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (rootPath.isNotEmpty)
              _MetricChip(
                  label: '워크스페이스', value: _compactPath(rootPath, keep: 30)),
            if (focusPaths.isNotEmpty)
              _MetricChip(label: '포커스 수', value: '${focusPaths.length}개'),
            if (changedFiles.isNotEmpty)
              _MetricChip(label: '변경 파일', value: '${changedFiles.length}개'),
            if (patchFiles.isNotEmpty)
              _MetricChip(label: '패치 파일', value: '${patchFiles.length}개'),
          ],
        ),
        if (hasData) ...[
          if (focusPaths.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SheetListBlock(
              label: '현재 포커스',
              icon: Icons.my_location_outlined,
              items: focusPaths,
              emptyMessage: '현재 포커스 정보가 아직 없습니다.',
            ),
          ],
          if (selection.isNotEmpty) ...[
            const SizedBox(height: 12),
            _StreamSurface(
              label: '선택 영역',
              child: SelectableText(
                selection,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFDCE6F2),
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
              ),
            ),
          ],
          if (changedFiles.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SheetListBlock(
              label: '변경 파일',
              icon: Icons.edit_note_outlined,
              items: changedFiles.take(12).toList(),
              emptyMessage: '변경 파일이 아직 없습니다.',
            ),
          ],
          if (patchFiles.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SheetListBlock(
              label: '패치 파일',
              icon: Icons.rule_folder_outlined,
              items: patchFiles.take(12).toList(),
              emptyMessage: '패치 파일이 아직 없습니다.',
            ),
          ],
          if (runError.isNotEmpty) ...[
            const SizedBox(height: 12),
            _SheetListBlock(
              label: '최근 에러 위치',
              icon: Icons.error_outline,
              items: [runError],
              emptyMessage: '최근 에러 위치가 없습니다.',
            ),
          ],
        ] else ...[
          const SizedBox(height: 12),
          _StreamSurface(
            label: '현재 상태',
            child: Text(
              '아직 파일 포커스 정보가 없습니다. 패치나 실행이 생기면 현재 파일, 변경 파일, 에러 위치를 이 시트에서 바로 확인할 수 있습니다.',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFB7C4D2),
                    height: 1.45,
                  ),
            ),
          ),
        ],
      ],
    );
  }
}

class _SheetListBlock extends StatelessWidget {
  const _SheetListBlock({
    required this.label,
    required this.icon,
    required this.items,
    required this.emptyMessage,
  });

  final String label;
  final IconData icon;
  final List<String> items;
  final String emptyMessage;

  @override
  Widget build(BuildContext context) {
    return _StreamSurface(
      label: label,
      child: items.isEmpty
          ? Text(
              emptyMessage,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFB7C4D2),
                    height: 1.45,
                  ),
            )
          : Column(
              children: [
                for (var index = 0; index < items.length; index++)
                  Padding(
                    padding: EdgeInsets.only(
                      bottom: index == items.length - 1 ? 0 : 10,
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(icon, size: 18, color: const Color(0xFF8FA0B3)),
                        const SizedBox(width: 10),
                        Expanded(
                          child: SelectableText(
                            items[index],
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: const Color(0xFFDCE6F2),
                                  height: 1.4,
                                ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }
}

class _SessionSyncBanner extends StatelessWidget {
  const _SessionSyncBanner({required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final tone = _syncTone(context, controller.sessionSyncStatus);
    final showActions = controller.hasSessionSyncTarget &&
        controller.sessionSyncStatus != SessionSyncStatus.live;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: tone.withValues(alpha: 0.28)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(_syncIcon(controller.sessionSyncStatus),
                  color: tone, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  controller.sessionSyncStatusLabel,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: tone,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ),
              Text(
                controller.sessionLastSyncedLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFB9C6D4),
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            controller.sessionSyncSummary,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFDCE6F2),
                  height: 1.35,
                ),
          ),
          if (controller.sessionSyncDetail.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              controller.sessionSyncDetail,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFB9C6D4),
                    height: 1.35,
                  ),
            ),
          ],
          if (showActions) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: controller.canRetrySessionSync
                        ? () async {
                            await controller.retrySessionSync();
                          }
                        : null,
                    icon: const Icon(Icons.autorenew_rounded),
                    label: const Text('다시 연결'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: controller.canRefreshSessionSync
                        ? () async {
                            await controller.refreshCurrentSession();
                          }
                        : null,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFDCE6F2),
                      side: const BorderSide(color: Color(0xFF32404D)),
                    ),
                    icon: const Icon(Icons.refresh_rounded),
                    label: const Text('세션 새로고침'),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        color: const Color(0xFF121A22),
        border: Border.all(color: const Color(0xFF24303B)),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF93A4B7),
                  height: 1.35,
                ),
          ),
          const SizedBox(height: 14),
          child,
        ],
      ),
    );
  }
}

class _StreamSurface extends StatelessWidget {
  const _StreamSurface({
    required this.label,
    required this.child,
    this.accent = const Color(0xFFE4B15A),
  });

  final String label;
  final Widget child;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0D141B),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF202A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _PlanTrace extends StatelessWidget {
  const _PlanTrace({required this.items});

  final List<SessionPlanItemView> items;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: items.map((item) => _PlanTraceRow(item: item)).toList(),
    );
  }
}

class _PlanTraceRow extends StatelessWidget {
  const _PlanTraceRow({required this.item});

  final SessionPlanItemView item;

  @override
  Widget build(BuildContext context) {
    final status = item.status;
    Color tone;
    switch (status) {
      case 'completed':
        tone = const Color(0xFF2E9D78);
        break;
      case 'in_progress':
        tone = const Color(0xFF4E8DFF);
        break;
      case 'blocked':
        tone = Theme.of(context).colorScheme.error;
        break;
      default:
        tone = const Color(0xFF8B9AAF);
        break;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            margin: const EdgeInsets.only(top: 4),
            width: 10,
            height: 10,
            decoration: BoxDecoration(
              color: tone,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              item.label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFDCE6F2),
                  ),
            ),
          ),
          const SizedBox(width: 10),
          Text(
            _planStatusLabel(item.status),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: tone,
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _ThreadEventTile extends StatelessWidget {
  const _ThreadEventTile({required this.event});

  final ThreadEventView event;

  @override
  Widget build(BuildContext context) {
    final isUser = event.role == 'user';
    final bgColor = isUser ? const Color(0xFF13222A) : const Color(0xFF151E2A);
    final borderColor =
        isUser ? const Color(0xFF244653) : const Color(0xFF263449);
    final iconColor =
        isUser ? const Color(0xFF7FD0B4) : const Color(0xFFB8C7FF);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                isUser ? Icons.person_outline : Icons.smart_toy_outlined,
                size: 18,
                color: iconColor,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  event.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: const Color(0xFFF4F7FB),
                      ),
                ),
              ),
              Text(
                event.atLabel,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFF93A4B7),
                    ),
              ),
            ],
          ),
          if (event.body.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              event.body,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFDCE6F2),
                    height: 1.45,
                  ),
            ),
          ],
          if (event.data['status'] != null ||
              event.data['profileId'] != null ||
              event.data['fileCount'] != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (event.data['status'] != null)
                  _MetricPill(
                    icon: Icons.check_circle_outline,
                    label: event.data['status'].toString(),
                  ),
                if (event.data['profileId'] != null)
                  _MetricPill(
                    icon: Icons.play_circle_outline,
                    label: event.data['profileId'].toString(),
                  ),
                if (event.data['fileCount'] != null)
                  _MetricPill(
                    icon: Icons.description_outlined,
                    label: 'files ${event.data['fileCount']}',
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _MetricChip extends StatelessWidget {
  const _MetricChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 100, maxWidth: 220),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF0D141B),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF202A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF8FA0B3),
                ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                  fontWeight: FontWeight.w700,
                ),
          ),
        ],
      ),
    );
  }
}

class _MetricPill extends StatelessWidget {
  const _MetricPill({
    required this.icon,
    required this.label,
    this.tone = const Color(0xFF8B9AAF),
  });

  final IconData icon;
  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.24)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 6),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFFDCE6F2),
                  fontWeight: FontWeight.w600,
                ),
          ),
        ],
      ),
    );
  }
}

class _ContextChip extends StatelessWidget {
  const _ContextChip({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return FilterChip(
      label: Text(label),
      selected: value,
      onSelected: onChanged,
      backgroundColor: const Color(0xFF0D141B),
      selectedColor: const Color(0xFF213244),
      side: const BorderSide(color: Color(0xFF293541)),
      labelStyle: TextStyle(
        color: value ? const Color(0xFFF4F7FB) : const Color(0xFFAFBFCE),
        fontWeight: value ? FontWeight.w700 : FontWeight.w500,
      ),
      checkmarkColor: const Color(0xFFE4B15A),
    );
  }
}
