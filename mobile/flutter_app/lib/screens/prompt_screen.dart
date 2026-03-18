import 'package:flutter/material.dart';

import '../state/app_controller.dart';
import 'review_screen.dart';

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

class _ErrorLocation {
  const _ErrorLocation({
    required this.path,
    required this.line,
    required this.message,
  });

  final String path;
  final int line;
  final String message;
}

_ErrorLocation? _parseErrorLocation(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) {
    return null;
  }

  final match = RegExp(r'^(.+?):(\d+)\s*(.*)$').firstMatch(trimmed);
  if (match == null) {
    return null;
  }

  return _ErrorLocation(
    path: match.group(1)?.trim() ?? '',
    line: int.tryParse(match.group(2) ?? '') ?? 1,
    message: match.group(3)?.trim() ?? '',
  );
}

String _terminalOutputPreview(String value, {int maxLines = 3}) {
  final lines = value
      .split('\n')
      .map((line) => line.trimRight())
      .where((line) => line.trim().isNotEmpty)
      .take(maxLines)
      .toList();
  return lines.join('\n').trim();
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
    text: '테스트 실패 원인을 분석하고 인증 미들웨어 패치를 제안해줘.',
  );
  final _promptFocusNode = FocusNode();
  final Map<String, Set<String>> _selectedPatchHunksByPath = {};

  final Map<String, bool> _context = {
    'activeFile': true,
    'selection': true,
    'latestError': true,
    'workspaceSummary': false,
  };
  bool _inlinePatchSelectionExpanded = false;

  int get _selectedContextCount =>
      _context.values.where((enabled) => enabled).length;

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
        _syncPatchSelection();

        final shouldShowSyncBanner = widget
                .controller.currentThreadId.isNotEmpty &&
            (widget.controller.sessionSyncStatus != SessionSyncStatus.live ||
                widget.controller.sessionSyncDetail.trim().isNotEmpty);
        final draftPreview = widget.controller.liveDraftPreview.isNotEmpty
            ? widget.controller.liveDraftPreview
            : widget.controller.promptDraft;

        return Column(
          key: const ValueKey('session-screen'),
          children: [
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 18),
                children: [
                  if (shouldShowSyncBanner) ...[
                    _SessionSyncBanner(controller: widget.controller),
                    const SizedBox(height: 14),
                  ],
                  _WorkstreamCard(
                    controller: widget.controller,
                    onOpenReview: _showReviewSheet,
                    onApplyAllPatch: _applyAllPatchFromFeed,
                    onApplySelectedPatch: _applySelectedPatchFromFeed,
                    onRunPrimaryProfile: _runPrimaryProfileFromFeed,
                    onOpenTerminal: _showTerminalSheet,
                    onOpenTopError: _openTopErrorFromFeed,
                    patchSelectionExpanded: _inlinePatchSelectionExpanded,
                    selectedPatchHunksByPath: _selectedPatchHunksByPath,
                    onTogglePatchSelectionExpanded: _toggleInlinePatchSelection,
                    onTogglePatchHunk: _togglePatchHunk,
                  ),
                  const SizedBox(height: 14),
                  _SectionCard(
                    title: '작업 로그',
                    subtitle: '프롬프트, 패치, 실행 결과를 한 피드에서 읽습니다.',
                    child: widget.controller.threadEvents.isEmpty
                        ? Text(
                            '아직 세션 이벤트가 없습니다. 아래 composer에서 첫 요청을 보내면 피드가 시작됩니다.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
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
              ),
            ),
            _ComposerDock(
              controller: widget.controller,
              promptController: _promptController,
              promptFocusNode: _promptFocusNode,
              draftPreview: draftPreview,
              selectedContextCount: _selectedContextCount,
              onChanged: widget.controller.updatePromptDraft,
              onOpenContextSheet: _showContextSheet,
              onClear: _clearPrompt,
              onSubmit: _submitPrompt,
            ),
          ],
        );
      },
    );
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

  Future<void> _applyAllPatchFromFeed() async {
    await widget.controller.applyPatch(
      applyAll: true,
      selectedByPath: const {},
    );
    if (!mounted) {
      return;
    }
    _showControllerSnack(
      widget.controller.patchResultStatus.isNotEmpty
          ? 'PATCH_RESULT: ${widget.controller.patchResultStatus} / ${widget.controller.patchResultMessage}'
          : '패치 적용 요청을 보냈습니다.',
    );
  }

  Future<void> _applySelectedPatchFromFeed() async {
    await widget.controller.applyPatch(
      applyAll: false,
      selectedByPath: _selectedPatchHunksByPath,
    );
    if (!mounted) {
      return;
    }
    _showControllerSnack(
      widget.controller.patchResultStatus.isNotEmpty
          ? 'PATCH_RESULT: ${widget.controller.patchResultStatus} / ${widget.controller.patchResultMessage}'
          : '선택한 패치 적용 요청을 보냈습니다.',
    );
  }

  Future<void> _runPrimaryProfileFromFeed() async {
    final profiles = widget.controller.runProfiles;
    if (profiles.isEmpty) {
      if (!mounted) {
        return;
      }
      _showControllerSnack('실행 가능한 프로파일이 아직 없습니다.');
      return;
    }

    final profile = profiles.first;
    await widget.controller.runProfile(profile.id);
    if (!mounted) {
      return;
    }
    _showControllerSnack(
      widget.controller.runStatus.isNotEmpty ||
              widget.controller.runSummary.isNotEmpty
          ? 'RUN_RESULT: ${widget.controller.runStatus} / ${widget.controller.runSummary}'
          : '${profile.displayLabel} 실행 요청을 보냈습니다.',
    );
  }

  void _showControllerSnack(String fallback) {
    final error = widget.controller.errorMessage?.trim() ?? '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(error.isNotEmpty ? error : fallback),
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

  void _syncPatchSelection() {
    final files = widget.controller.patchFiles;
    final paths = files.map((file) => file.path).toSet();
    _selectedPatchHunksByPath.removeWhere((path, _) => !paths.contains(path));

    for (final file in files) {
      final selected = _selectedPatchHunksByPath.putIfAbsent(
        file.path,
        () => <String>{},
      );
      final validIds = file.hunks.map((hunk) => hunk.id).toSet();
      selected.removeWhere((id) => !validIds.contains(id));
      if (selected.isEmpty) {
        _selectedPatchHunksByPath.remove(file.path);
      }
    }

    if (files.isEmpty) {
      _inlinePatchSelectionExpanded = false;
    }
  }

  Future<void> _showReviewSheet() async {
    await _showBottomSheet(
      title: '상세 패치와 실행',
      subtitle: '메인 피드에서는 핵심만 보고, 여기서는 전체 diff와 실행 기록을 자세히 봅니다.',
      child: ReviewScreen(controller: widget.controller),
    );
  }

  Future<void> _showTerminalSheet() async {
    await _showBottomSheet(
      title: '터미널',
      subtitle: '현재 세션에서 보고 있는 실행 상태와 최근 출력을 바로 확인합니다.',
      child: TerminalSheet(controller: widget.controller),
    );
  }

  Future<void> _openTopErrorFromFeed() async {
    if (widget.controller.topErrors.isEmpty) {
      return;
    }
    final target = _parseErrorLocation(widget.controller.topErrors.first);
    if (target == null || target.path.isEmpty) {
      return;
    }
    await widget.controller.openWorkspaceLocation(
      target.path,
      line: target.line <= 0 ? 1 : target.line,
    );
  }

  void _toggleInlinePatchSelection() {
    setState(() {
      _inlinePatchSelectionExpanded = !_inlinePatchSelectionExpanded;
    });
  }

  void _togglePatchHunk(String path, String hunkId, bool selected) {
    setState(() {
      final selectedSet = _selectedPatchHunksByPath.putIfAbsent(
        path,
        () => <String>{},
      );
      if (selected) {
        selectedSet.add(hunkId);
      } else {
        selectedSet.remove(hunkId);
      }
      if (selectedSet.isEmpty) {
        _selectedPatchHunksByPath.remove(path);
      }
    });
  }

  Future<void> _showContextSheet() async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF10161D),
      showDragHandle: true,
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '컨텍스트',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: const Color(0xFFF4F7FB),
                      ),
                ),
                const SizedBox(height: 6),
                Text(
                  '메인 화면은 깔끔하게 두고 필요한 정보만 여기서 붙입니다.',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF93A4B7),
                        height: 1.4,
                      ),
                ),
                const SizedBox(height: 14),
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
              ],
            ),
          ),
        );
      },
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

class _ComposerDock extends StatelessWidget {
  const _ComposerDock({
    required this.controller,
    required this.promptController,
    required this.promptFocusNode,
    required this.draftPreview,
    required this.selectedContextCount,
    required this.onChanged,
    required this.onOpenContextSheet,
    required this.onClear,
    required this.onSubmit,
  });

  final AppController controller;
  final TextEditingController promptController;
  final FocusNode promptFocusNode;
  final String draftPreview;
  final int selectedContextCount;
  final ValueChanged<String> onChanged;
  final VoidCallback onOpenContextSheet;
  final VoidCallback onClear;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SafeArea(
        top: false,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
          decoration: BoxDecoration(
            color: const Color(0xFF0D141B),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: const Color(0xFF202A35)),
            boxShadow: const [
              BoxShadow(
                color: Color(0x44000000),
                blurRadius: 20,
                offset: Offset(0, 10),
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (draftPreview.trim().isNotEmpty) ...[
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF121C25),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: const Color(0xFF223140)),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        controller.liveComposerTyping
                            ? Icons.edit_note_rounded
                            : Icons.sync_alt_rounded,
                        size: 16,
                        color: const Color(0xFFE4B15A),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          draftPreview,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: const Color(0xFFDCE6F2),
                                    height: 1.35,
                                  ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 10),
              ],
              TextField(
                controller: promptController,
                focusNode: promptFocusNode,
                minLines: 3,
                maxLines: 6,
                style: const TextStyle(
                  color: Color(0xFFEAF1F8),
                  height: 1.45,
                ),
                onChanged: onChanged,
                decoration: InputDecoration(
                  hintText: '계획, @ 컨텍스트, / 명령',
                  hintStyle: const TextStyle(color: Color(0xFF7D8EA2)),
                  filled: true,
                  fillColor: const Color(0xFF0A1016),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(18),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.all(16),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: onOpenContextSheet,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFDCE6F2),
                        side: const BorderSide(color: Color(0xFF32404D)),
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                      icon: const Icon(Icons.tune),
                      label: Text('컨텍스트 $selectedContextCount'),
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.outlined(
                    tooltip: '입력 지우기',
                    onPressed: onClear,
                    style: IconButton.styleFrom(
                      foregroundColor: const Color(0xFFDCE6F2),
                      side: const BorderSide(color: Color(0xFF32404D)),
                    ),
                    icon: const Icon(Icons.restart_alt),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: controller.isLoading ? null : onSubmit,
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFFE4B15A),
                      foregroundColor: const Color(0xFF10161D),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                    ),
                    icon: const Icon(Icons.send_rounded),
                    label: const Text('보내기'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WorkstreamCard extends StatelessWidget {
  const _WorkstreamCard({
    required this.controller,
    required this.onOpenReview,
    required this.onApplyAllPatch,
    required this.onApplySelectedPatch,
    required this.onRunPrimaryProfile,
    required this.onOpenTerminal,
    required this.onOpenTopError,
    required this.patchSelectionExpanded,
    required this.selectedPatchHunksByPath,
    required this.onTogglePatchSelectionExpanded,
    required this.onTogglePatchHunk,
  });

  final AppController controller;
  final VoidCallback onOpenReview;
  final Future<void> Function() onApplyAllPatch;
  final Future<void> Function() onApplySelectedPatch;
  final Future<void> Function() onRunPrimaryProfile;
  final Future<void> Function() onOpenTerminal;
  final Future<void> Function() onOpenTopError;
  final bool patchSelectionExpanded;
  final Map<String, Set<String>> selectedPatchHunksByPath;
  final VoidCallback onTogglePatchSelectionExpanded;
  final void Function(String path, String hunkId, bool selected)
      onTogglePatchHunk;

  @override
  Widget build(BuildContext context) {
    final reasoning = controller.liveSession.reasoning.summary.trim();
    final planItems = controller.liveSession.plan.items.take(4).toList();
    final toolActivities =
        controller.liveSession.tools.activities.reversed.take(3).toList();
    final primaryProfile =
        controller.runProfiles.isEmpty ? null : controller.runProfiles.first;
    final primaryProfileLabel = primaryProfile == null
        ? ''
        : (primaryProfile.label.trim().isNotEmpty
            ? primaryProfile.label.trim()
            : primaryProfile.id);
    final activeFile = _firstNonEmptyText([
      controller.liveSession.focus.activeFilePath,
      controller.liveSession.workspace.activeFilePath,
    ]);
    final patchPreviewPaths = _dedupeNonEmptyPaths([
      ...controller.patchFiles.map((file) => file.path),
      ...controller.liveSession.workspace.patchFiles,
    ]);
    final reviewFilePaths = _dedupeNonEmptyPaths([
      ...patchPreviewPaths,
      ...controller.currentJobFiles,
      ...controller.liveSession.workspace.changedFiles,
    ]);
    final patchSummary = controller.patchSummary.isNotEmpty
        ? controller.patchSummary
        : controller.patchAvailabilityReason;
    final selectedPatchHunkCount = selectedPatchHunksByPath.values.fold<int>(
      0,
      (sum, item) => sum + item.length,
    );
    final terminal = controller.liveSession.terminal;
    final terminalStatus = _firstNonEmptyText(
      [terminal.status, controller.runStatus],
      fallback: '대기 중',
    );
    final terminalCommand = _firstNonEmptyText([
      terminal.command,
      controller.sessionOperation.runCommand,
    ]);
    final terminalSummary = _firstNonEmptyText([
      terminal.summary,
      controller.runSummary,
    ], fallback: '최근 실행 결과가 아직 없습니다.');
    final terminalPreview = _terminalOutputPreview(
      _firstNonEmptyText([
        terminal.output,
        terminal.excerpt,
        controller.runOutput,
        controller.runExcerpt,
      ]),
    );
    final primaryError = controller.topErrors.isEmpty
        ? null
        : _parseErrorLocation(controller.topErrors.first);
    final runSummary = controller.runSummary.isNotEmpty
        ? controller.runSummary
        : (primaryProfile == null
            ? '실행 가능한 프로파일이 아직 없습니다.'
            : '패치 검토 뒤 실행 대기 중입니다.');

    return _SectionCard(
      title: '현재 작업',
      subtitle: '메인 세션 피드에는 필요한 상태만 남깁니다.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            controller.liveActivitySummary,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          if (activeFile.isNotEmpty) ...[
            const SizedBox(height: 10),
            _MetricPill(
              icon: Icons.insert_drive_file_outlined,
              label: _compactPath(activeFile, keep: 42),
              tone: const Color(0xFF4E8DFF),
            ),
          ],
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
              label: '계획',
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
                      '${controller.liveSession.tools.currentLabel} / ${controller.liveSession.tools.currentStatus.isEmpty ? '진행 중' : controller.liveSession.tools.currentStatus}',
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
                          '- ${activity.label.isEmpty ? activity.kind : activity.label}${activity.status.isEmpty ? '' : ' / ${activity.status}'}${activity.detail.isEmpty ? '' : ' / ${activity.detail}'}',
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
            label: '검토와 실행',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if ((controller.currentJobId ?? '').trim().isNotEmpty)
                      _MetricPill(
                        icon: Icons.work_outline_rounded,
                        label: controller.currentJobId!,
                        tone: const Color(0xFF4E8DFF),
                      ),
                    if (patchPreviewPaths.isNotEmpty)
                      _MetricPill(
                        icon: Icons.edit_note_outlined,
                        label: '패치 ${patchPreviewPaths.length}개',
                        tone: const Color(0xFFE4B15A),
                      ),
                    if (primaryProfile != null)
                      _MetricPill(
                        icon: Icons.play_circle_outline,
                        label: primaryProfileLabel,
                        tone: const Color(0xFF2E9D78),
                      ),
                    if (controller.runStatus.isNotEmpty)
                      _MetricPill(
                        icon: Icons.bolt_outlined,
                        label: controller.runStatus,
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                _InlineActionCard(
                  title: '패치 검토',
                  summary: patchSummary,
                  previewPaths: reviewFilePaths.take(3).toList(),
                  primaryActionLabel:
                      controller.canApplyAllPatch ? '전체 적용' : null,
                  onPrimaryAction:
                      controller.canApplyAllPatch ? onApplyAllPatch : null,
                  secondaryActionLabel:
                      patchSelectionExpanded ? '파일 선택 접기' : '파일별 선택',
                  onSecondaryAction: onTogglePatchSelectionExpanded,
                ),
                if (patchSelectionExpanded) ...[
                  const SizedBox(height: 10),
                  _InlinePatchSelectionSurface(
                    controller: controller,
                    selectedByPath: selectedPatchHunksByPath,
                    selectedHunkCount: selectedPatchHunkCount,
                    onToggleHunk: onTogglePatchHunk,
                    onApplySelectedPatch: onApplySelectedPatch,
                    onOpenReview: onOpenReview,
                  ),
                ],
                const SizedBox(height: 10),
                _InlineActionCard(
                  title: '실행 확인',
                  summary: runSummary,
                  previewPaths: controller.topErrors.isNotEmpty
                      ? controller.topErrors.take(2).toList()
                      : controller.currentJobFiles.take(3).toList(),
                  primaryActionLabel:
                      primaryProfile == null ? null : '$primaryProfileLabel 실행',
                  onPrimaryAction:
                      primaryProfile == null ? null : onRunPrimaryProfile,
                  secondaryActionLabel: '상세 보기',
                  onSecondaryAction: onOpenReview,
                ),
                const SizedBox(height: 10),
                _InlineTerminalSurface(
                  status: terminalStatus,
                  command: terminalCommand,
                  summary: terminalSummary,
                  outputPreview: terminalPreview,
                  primaryError: primaryError,
                  onOpenTerminal: onOpenTerminal,
                  onOpenTopError: primaryError == null ? null : onOpenTopError,
                ),
              ],
            ),
          ),
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
        ],
      ),
    );
  }
}

class TerminalSheet extends StatelessWidget {
  const TerminalSheet({super.key, required this.controller});

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
    final primaryError = controller.topErrors.isEmpty
        ? null
        : _parseErrorLocation(controller.topErrors.first);
    final primaryFile = recentFiles.isEmpty ? '' : recentFiles.first;

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
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                summary,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFDCE6F2),
                      height: 1.45,
                    ),
              ),
              if (primaryError != null || primaryFile.isNotEmpty) ...[
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    if (primaryError != null)
                      OutlinedButton.icon(
                        onPressed: () async {
                          await controller.openWorkspaceLocation(
                            primaryError.path,
                            line:
                                primaryError.line <= 0 ? 1 : primaryError.line,
                          );
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFDCE6F2),
                          side: const BorderSide(color: Color(0xFF32404D)),
                        ),
                        icon: const Icon(Icons.my_location_outlined),
                        label: const Text('상위 에러 열기'),
                      ),
                    if (primaryFile.isNotEmpty)
                      FilledButton.tonalIcon(
                        onPressed: () async {
                          await controller.openWorkspaceLocation(primaryFile);
                        },
                        style: FilledButton.styleFrom(
                          foregroundColor: const Color(0xFFF4F7FB),
                          backgroundColor: const Color(0xFF213244),
                        ),
                        icon: const Icon(Icons.insert_drive_file_outlined),
                        label: const Text('최근 파일 열기'),
                      ),
                  ],
                ),
              ],
            ],
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

class FileFocusSheet extends StatelessWidget {
  const FileFocusSheet({super.key, required this.controller});

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
    final primaryFocusPath = _firstNonEmptyText([
      focus.activeFilePath,
      workspace.activeFilePath,
      focus.patchPath,
      focus.runErrorPath,
    ]);
    final runErrorLocation = focus.runErrorPath.trim().isNotEmpty
        ? _ErrorLocation(
            path: focus.runErrorPath.trim(),
            line: focus.runErrorLine,
            message: '',
          )
        : (controller.topErrors.isEmpty
            ? null
            : _parseErrorLocation(controller.topErrors.first));
    final runError = runErrorLocation == null
        ? ''
        : runErrorLocation.line > 0
            ? '${runErrorLocation.path}:${runErrorLocation.line}'
            : runErrorLocation.path;
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
          if (primaryFocusPath.isNotEmpty || runErrorLocation != null) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (primaryFocusPath.isNotEmpty)
                  FilledButton.tonalIcon(
                    onPressed: () async {
                      await controller.openWorkspaceLocation(primaryFocusPath);
                    },
                    style: FilledButton.styleFrom(
                      foregroundColor: const Color(0xFFF4F7FB),
                      backgroundColor: const Color(0xFF213244),
                    ),
                    icon: const Icon(Icons.visibility_outlined),
                    label: const Text('포커스 열기'),
                  ),
                if (runErrorLocation != null)
                  OutlinedButton.icon(
                    onPressed: () async {
                      await controller.openWorkspaceLocation(
                        runErrorLocation.path,
                        line: runErrorLocation.line <= 0
                            ? 1
                            : runErrorLocation.line,
                      );
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFDCE6F2),
                      side: const BorderSide(color: Color(0xFF32404D)),
                    ),
                    icon: const Icon(Icons.my_location_outlined),
                    label: const Text('에러 열기'),
                  ),
              ],
            ),
          ],
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

class _InlineActionCard extends StatelessWidget {
  const _InlineActionCard({
    required this.title,
    required this.summary,
    required this.previewPaths,
    this.primaryActionLabel,
    this.onPrimaryAction,
    required this.secondaryActionLabel,
    required this.onSecondaryAction,
  });

  final String title;
  final String summary;
  final List<String> previewPaths;
  final String? primaryActionLabel;
  final Future<void> Function()? onPrimaryAction;
  final String secondaryActionLabel;
  final VoidCallback onSecondaryAction;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0A1016),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF202A35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          const SizedBox(height: 8),
          Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFDCE6F2),
                  height: 1.45,
                ),
          ),
          if (previewPaths.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...previewPaths.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '- $item',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFB7C4D2),
                        height: 1.35,
                      ),
                ),
              ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onSecondaryAction,
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFFF4F7FB),
                  backgroundColor: const Color(0xFF213244),
                ),
                icon: const Icon(Icons.rule_folder_outlined),
                label: Text(secondaryActionLabel),
              ),
              if (primaryActionLabel != null)
                OutlinedButton.icon(
                  onPressed: onPrimaryAction == null
                      ? null
                      : () async {
                          await onPrimaryAction!();
                        },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDCE6F2),
                    side: const BorderSide(color: Color(0xFF32404D)),
                  ),
                  icon: Icon(
                    title == '패치 검토'
                        ? Icons.done_all_rounded
                        : Icons.play_arrow_rounded,
                  ),
                  label: Text(primaryActionLabel!),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlinePatchSelectionSurface extends StatelessWidget {
  const _InlinePatchSelectionSurface({
    required this.controller,
    required this.selectedByPath,
    required this.selectedHunkCount,
    required this.onToggleHunk,
    required this.onApplySelectedPatch,
    required this.onOpenReview,
  });

  final AppController controller;
  final Map<String, Set<String>> selectedByPath;
  final int selectedHunkCount;
  final void Function(String path, String hunkId, bool selected) onToggleHunk;
  final Future<void> Function() onApplySelectedPatch;
  final VoidCallback onOpenReview;

  @override
  Widget build(BuildContext context) {
    final files = controller.patchFiles;
    if (files.isEmpty) {
      return _StreamSurface(
        label: '파일별 선택',
        accent: const Color(0xFF8EB7FF),
        child: Text(
          controller.patchAvailabilityReason,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: const Color(0xFFB7C4D2),
                height: 1.45,
              ),
        ),
      );
    }

    final totalHunks =
        files.fold<int>(0, (sum, file) => sum + file.hunks.length);

    return _StreamSurface(
      label: '파일별 선택',
      accent: const Color(0xFF8EB7FF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(
                icon: Icons.rule_folder_outlined,
                label: '파일 ${files.length}개',
                tone: const Color(0xFF4E8DFF),
              ),
              _MetricPill(
                icon: Icons.segment_rounded,
                label: '헝크 $totalHunks개',
                tone: const Color(0xFFE4B15A),
              ),
              if (selectedHunkCount > 0)
                _MetricPill(
                  icon: Icons.checklist_rounded,
                  label: '$selectedHunkCount개 선택',
                  tone: const Color(0xFF2E9D78),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ...files.map(
            (file) => _InlinePatchFileCard(
              file: file,
              selectedHunks: selectedByPath[file.path] ?? const <String>{},
              onToggleHunk: (hunkId, selected) =>
                  onToggleHunk(file.path, hunkId, selected),
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: selectedHunkCount == 0 ? null : onApplySelectedPatch,
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFFF4F7FB),
                  backgroundColor: const Color(0xFF1F3A2E),
                ),
                icon: const Icon(Icons.done_outline_rounded),
                label: const Text('선택 적용'),
              ),
              OutlinedButton.icon(
                onPressed: onOpenReview,
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFDCE6F2),
                  side: const BorderSide(color: Color(0xFF32404D)),
                ),
                icon: const Icon(Icons.open_in_new_rounded),
                label: const Text('전체 시트 보기'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InlinePatchFileCard extends StatelessWidget {
  const _InlinePatchFileCard({
    required this.file,
    required this.selectedHunks,
    required this.onToggleHunk,
  });

  final PatchFileView file;
  final Set<String> selectedHunks;
  final void Function(String hunkId, bool selected) onToggleHunk;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF091017),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFF202A35)),
      ),
      child: Theme(
        data: theme.copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          iconColor: const Color(0xFFB7C4D2),
          collapsedIconColor: const Color(0xFF8FA2B6),
          title: Text(
            file.path,
            style: theme.textTheme.titleSmall?.copyWith(
              color: const Color(0xFFF4F7FB),
            ),
          ),
          subtitle: Text(
            'status ${file.status.isEmpty ? "-" : file.status} / 헝크 ${file.hunks.length}개',
            style: theme.textTheme.bodySmall?.copyWith(
              color: const Color(0xFF93A4B7),
            ),
          ),
          children: file.hunks.isEmpty
              ? [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                    child: Text(
                      '표시할 상세 diff가 아직 없습니다.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF93A4B7),
                      ),
                    ),
                  ),
                ]
              : file.hunks
                  .map(
                    (hunk) => Container(
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0D141B),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: const Color(0xFF24303B)),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CheckboxListTile(
                            dense: true,
                            controlAffinity: ListTileControlAffinity.leading,
                            value: selectedHunks.contains(hunk.id),
                            activeColor: const Color(0xFF2E9D78),
                            checkColor: const Color(0xFF07120D),
                            contentPadding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            onChanged: (value) =>
                                onToggleHunk(hunk.id, value ?? false),
                            title: Text(
                              hunk.header.isEmpty
                                  ? hunk.id
                                  : '${hunk.id} ${hunk.header}',
                              style: theme.textTheme.bodyMedium?.copyWith(
                                color: const Color(0xFFF4F7FB),
                              ),
                            ),
                            subtitle: Text(
                              hunk.risk.isEmpty
                                  ? 'risk -'
                                  : 'risk ${hunk.risk}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF93A4B7),
                              ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
                            child: SelectableText(
                              hunk.diff,
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: const Color(0xFFEAF1F8),
                                fontFamily: 'monospace',
                                height: 1.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
        ),
      ),
    );
  }
}

class _InlineTerminalSurface extends StatelessWidget {
  const _InlineTerminalSurface({
    required this.status,
    required this.command,
    required this.summary,
    required this.outputPreview,
    required this.primaryError,
    required this.onOpenTerminal,
    required this.onOpenTopError,
  });

  final String status;
  final String command;
  final String summary;
  final String outputPreview;
  final _ErrorLocation? primaryError;
  final Future<void> Function() onOpenTerminal;
  final Future<void> Function()? onOpenTopError;

  @override
  Widget build(BuildContext context) {
    return _StreamSurface(
      label: '최근 터미널',
      accent: const Color(0xFF8EB7FF),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _MetricPill(
                icon: Icons.terminal_rounded,
                label: status,
                tone: status == 'failed'
                    ? Theme.of(context).colorScheme.error
                    : const Color(0xFF4E8DFF),
              ),
              if (command.isNotEmpty)
                _MetricPill(
                  icon: Icons.play_arrow_rounded,
                  label: _compactPath(command, keep: 28),
                  tone: const Color(0xFFE4B15A),
                ),
              if (primaryError != null)
                _MetricPill(
                  icon: Icons.error_outline,
                  label: primaryError!.line > 0
                      ? '${primaryError!.path}:${primaryError!.line}'
                      : primaryError!.path,
                  tone: Theme.of(context).colorScheme.error,
                ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFDCE6F2),
                  height: 1.45,
                ),
          ),
          if (outputPreview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              decoration: BoxDecoration(
                color: const Color(0xFF091017),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF202A35)),
              ),
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                outputPreview,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFEAF1F8),
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.tonalIcon(
                onPressed: onOpenTerminal,
                style: FilledButton.styleFrom(
                  foregroundColor: const Color(0xFFF4F7FB),
                  backgroundColor: const Color(0xFF213244),
                ),
                icon: const Icon(Icons.terminal_rounded),
                label: const Text('터미널 보기'),
              ),
              if (onOpenTopError != null)
                OutlinedButton.icon(
                  onPressed: onOpenTopError,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFDCE6F2),
                    side: const BorderSide(color: Color(0xFF32404D)),
                  ),
                  icon: const Icon(Icons.my_location_outlined),
                  label: const Text('에러 열기'),
                ),
            ],
          ),
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
    final eventCommand = _firstNonEmptyText([
      event.data['command']?.toString() ?? '',
      event.data['label']?.toString() ?? '',
    ]);
    final eventOutputPreview = _terminalOutputPreview(_firstNonEmptyText([
      event.data['output']?.toString() ?? '',
      event.data['excerpt']?.toString() ?? '',
    ]));
    final eventErrors = event.data['topErrors'] is List
        ? (event.data['topErrors'] as List)
            .whereType<Map>()
            .map((item) {
              final path = item['path']?.toString() ?? '';
              final line = item['line']?.toString() ?? '';
              final message = item['message']?.toString() ?? '';
              return path.isEmpty ? message : '$path:$line $message'.trim();
            })
            .where((line) => line.trim().isNotEmpty)
            .take(2)
            .toList()
        : const <String>[];

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
                    label: '파일 ${event.data['fileCount']}개',
                  ),
              ],
            ),
          ],
          if (eventCommand.isNotEmpty) ...[
            const SizedBox(height: 10),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: const Color(0xFF0D141B),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: const Color(0xFF202A35)),
              ),
              child: SelectableText(
                eventCommand,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: const Color(0xFFEAF1F8),
                      fontFamily: 'monospace',
                      height: 1.4,
                    ),
              ),
            ),
          ],
          if (eventOutputPreview.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              eventOutputPreview,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFB7C4D2),
                    height: 1.4,
                  ),
            ),
          ],
          if (eventErrors.isNotEmpty) ...[
            const SizedBox(height: 10),
            ...eventErrors.map(
              (line) => Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  '• $line',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFFFFD5D2),
                        height: 1.35,
                      ),
                ),
              ),
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
