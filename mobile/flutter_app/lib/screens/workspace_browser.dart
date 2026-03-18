import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_controller.dart';

class WorkspaceDrawerTab extends StatefulWidget {
  const WorkspaceDrawerTab({
    super.key,
    required this.controller,
    required this.onInspectFile,
  });

  final AppController controller;
  final ValueChanged<String> onInspectFile;

  @override
  State<WorkspaceDrawerTab> createState() => _WorkspaceDrawerTabState();
}

class _WorkspaceDrawerTabState extends State<WorkspaceDrawerTab> {
  String? _loadError;

  @override
  void initState() {
    super.initState();
    unawaited(_ensureRootEntries());
  }

  Future<void> _ensureRootEntries({bool force = false}) async {
    try {
      await widget.controller.loadWorkspaceTree('', force: force);
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = null;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _loadError = error.toString();
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final rootPath = widget.controller.workspaceRootPath;
    final hasRootEntries = widget.controller.hasWorkspaceEntries('');
    final rootEntries = widget.controller.workspaceEntriesForPath('');
    final focusPath = _primaryFocusPath(widget.controller);
    final runError = _primaryRunError(widget.controller);
    final hasLiveFocus = focusPath.isNotEmpty ||
        widget.controller.liveSession.focus.selection.trim().isNotEmpty ||
        runError != null;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text(
          '파일',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFF4F7FB),
              ),
        ),
        const SizedBox(height: 10),
        if (rootPath.isNotEmpty)
          Text(
            _compactPath(rootPath, keep: 48),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: const Color(0xFF8FA0B3),
                ),
          ),
        if (hasLiveFocus) ...[
          const SizedBox(height: 12),
          _WorkspaceLiveSyncCard(
            controller: widget.controller,
            focusPath: focusPath,
            runError: runError,
            onInspectFile: widget.onInspectFile,
          ),
        ],
        const SizedBox(height: 12),
        if (rootPath.isEmpty)
          const _WorkspaceHint(
            message: '작업 경로가 아직 준비되지 않았습니다. 에이전트 연결 상태를 먼저 확인해 주세요.',
          )
        else if (_loadError != null)
          _WorkspaceRetryCard(
            message: _loadError!,
            onRetry: () => _ensureRootEntries(force: true),
          )
        else if (!hasRootEntries)
          const _WorkspaceLoadingCard(message: '작업 디렉터리를 불러오는 중입니다.')
        else if (rootEntries.isEmpty)
          const _WorkspaceHint(
            message: '표시할 파일이 없습니다. 빈 작업 경로이거나 필터링된 디렉터리만 남아 있습니다.',
          )
        else
          ...rootEntries.map(
            (entry) => _WorkspaceEntryTile(
              controller: widget.controller,
              entry: entry,
              depth: 0,
              onInspectFile: widget.onInspectFile,
            ),
          ),
      ],
    );
  }
}

class _WorkspaceEntryTile extends StatefulWidget {
  const _WorkspaceEntryTile({
    required this.controller,
    required this.entry,
    required this.depth,
    required this.onInspectFile,
  });

  final AppController controller;
  final WorkspaceTreeEntryView entry;
  final int depth;
  final ValueChanged<String> onInspectFile;

  @override
  State<_WorkspaceEntryTile> createState() => _WorkspaceEntryTileState();
}

class _WorkspaceEntryTileState extends State<_WorkspaceEntryTile> {
  bool _expanded = false;
  bool _loadingChildren = false;
  String? _childError;

  Future<void> _loadChildren({bool force = false}) async {
    if (_loadingChildren) {
      return;
    }

    setState(() {
      _loadingChildren = true;
      _childError = null;
    });
    try {
      await widget.controller.loadWorkspaceTree(widget.entry.path, force: force);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _childError = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loadingChildren = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.entry.isDir) {
      return _WorkspaceFileRow(
        entry: widget.entry,
        depth: widget.depth,
        onTap: () => widget.onInspectFile(widget.entry.path),
      );
    }

    final children = widget.controller.workspaceEntriesForPath(widget.entry.path);
    final hasChildren = widget.controller.hasWorkspaceEntries(widget.entry.path);

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.only(left: widget.depth * 14 + 8, right: 4),
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: widget.entry.isActive,
        iconColor: const Color(0xFF8FA0B3),
        collapsedIconColor: const Color(0xFF637282),
        onExpansionChanged: (expanded) {
          setState(() {
            _expanded = expanded;
          });
          if (expanded && !hasChildren) {
            unawaited(_loadChildren());
          }
        },
        title: Row(
          children: [
            const Icon(
              Icons.folder_open_rounded,
              size: 18,
              color: Color(0xFF8FA0B3),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                widget.entry.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFEAF1F8),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
        children: [
          if (_loadingChildren)
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 8, 12, 12),
              child: _WorkspaceLoadingCard(message: '하위 디렉터리를 불러오는 중입니다.'),
            )
          else if (_childError != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 8, 12, 12),
              child: _WorkspaceRetryCard(
                message: _childError!,
                onRetry: () => _loadChildren(force: true),
              ),
            )
          else if (_expanded && hasChildren && children.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(22, 8, 12, 12),
              child: _WorkspaceHint(message: '이 디렉터리에는 표시할 파일이 없습니다.'),
            )
          else
            ...children.map(
              (entry) => _WorkspaceEntryTile(
                controller: widget.controller,
                entry: entry,
                depth: widget.depth + 1,
                onInspectFile: widget.onInspectFile,
              ),
            ),
        ],
      ),
    );
  }
}

class _WorkspaceFileRow extends StatelessWidget {
  const _WorkspaceFileRow({
    required this.entry,
    required this.depth,
    required this.onTap,
  });

  final WorkspaceTreeEntryView entry;
  final int depth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = entry.hasError
        ? Theme.of(context).colorScheme.error.withValues(alpha: 0.7)
        : entry.isActive
            ? const Color(0xFF35506A)
            : Colors.transparent;
    final backgroundColor = entry.isActive
        ? const Color(0xFF111A23)
        : const Color(0x00000000);
    final status = _displayStatus(entry);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Ink(
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: borderColor),
        ),
        padding: EdgeInsets.fromLTRB(depth * 14 + 18, 8, 8, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _iconForFilePath(entry.path),
              size: 18,
              color: entry.hasError
                  ? Theme.of(context).colorScheme.error
                  : entry.isPatch
                      ? const Color(0xFFE4B15A)
                      : const Color(0xFF7FD0B4),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          entry.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: const Color(0xFFEAF1F8),
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                      ),
                      if (status.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        Text(
                          status,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: _statusTone(context, entry),
                                    fontWeight: FontWeight.w700,
                                  ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    entry.path,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF6F7D8B),
                        ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class WorkspaceFileSheet extends StatefulWidget {
  const WorkspaceFileSheet({
    super.key,
    required this.controller,
    required this.path,
  });

  final AppController controller;
  final String path;

  @override
  State<WorkspaceFileSheet> createState() => _WorkspaceFileSheetState();
}

class _WorkspaceFileSheetState extends State<WorkspaceFileSheet> {
  final _editorController = TextEditingController();
  final _scrollController = ScrollController();
  WorkspaceFileContentView _file = const WorkspaceFileContentView();
  bool _loading = true;
  bool _saving = false;
  bool _editing = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadFile());
  }

  @override
  void dispose() {
    _editorController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  bool get _hasChanges => _editorController.text != _file.content;

  Future<void> _loadFile() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final file = await widget.controller.loadWorkspaceFile(widget.path);
      if (!mounted) {
        return;
      }
      setState(() {
        _file = file;
        _editorController.text = file.content;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = widget.controller.workspaceFileError ?? error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _saveFile() async {
    if (_saving) {
      return;
    }

    setState(() {
      _saving = true;
    });
    try {
      final file = await widget.controller.saveWorkspaceFile(
        widget.path,
        _editorController.text,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _file = file;
        _editing = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('파일을 저장했습니다.')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(widget.controller.workspaceFileError ?? error.toString()),
        ),
      );
    } finally {
      if (mounted) {
        setState(() {
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF0F161D),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.path,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFFF4F7FB),
                      ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _FileMetaChip(
                      label: _file.gitStatus.isEmpty
                          ? '상태 없음'
                          : '상태 ${_file.gitStatus}',
                    ),
                    _FileMetaChip(
                      label: _file.sizeBytes <= 0
                          ? '크기 확인 중'
                          : '${_file.sizeBytes} bytes',
                    ),
                    _FileMetaChip(label: '수정 ${_file.updatedAtLabel}'),
                  ],
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: () => widget.controller
                            .openWorkspaceLocation(widget.path),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFDCE6F2),
                          side: const BorderSide(color: Color(0xFF32404D)),
                        ),
                        icon: const Icon(Icons.open_in_new_rounded),
                        label: const Text('Cursor에서 열기'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: FilledButton.tonalIcon(
                        onPressed: _loading
                            ? null
                            : () {
                                setState(() {
                                  _editing = !_editing;
                                  if (!_editing) {
                                    _editorController.text = _file.content;
                                  }
                                });
                              },
                        icon: Icon(
                          _editing ? Icons.visibility_outlined : Icons.edit_outlined,
                        ),
                        label: Text(_editing ? '미리보기' : '간단 편집'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Color(0xFF24303B)),
          Expanded(
            child: _buildBody(context),
          ),
          if (_editing)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 10, 16, 16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _saving
                            ? null
                            : () {
                                setState(() {
                                  _editorController.text = _file.content;
                                  _editing = false;
                                });
                              },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: const Color(0xFFDCE6F2),
                          side: const BorderSide(color: Color(0xFF32404D)),
                        ),
                        child: const Text('변경 취소'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: !_file.isWritable || !_hasChanges || _saving
                            ? null
                            : _saveFile,
                        style: FilledButton.styleFrom(
                          backgroundColor: const Color(0xFFE4B15A),
                          foregroundColor: const Color(0xFF10161D),
                        ),
                        icon: _saving
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.save_outlined),
                        label: const Text('저장'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: Color(0xFFE4B15A)),
      );
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: _WorkspaceRetryCard(
            message: _error!,
            onRetry: _loadFile,
          ),
        ),
      );
    }
    if (_editing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
        child: TextField(
          controller: _editorController,
          scrollController: _scrollController,
          expands: true,
          maxLines: null,
          minLines: null,
          readOnly: !_file.isWritable,
          style: const TextStyle(
            color: Color(0xFFEAF1F8),
            fontFamily: 'monospace',
            height: 1.45,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: const Color(0xFF0A1016),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(18),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.all(16),
          ),
        ),
      );
    }

    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: const Color(0xFF0A1016),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: const Color(0xFF223140)),
          ),
          child: SelectableText(
            _file.content.isEmpty ? '빈 파일입니다.' : _file.content,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFEAF1F8),
                  fontFamily: 'monospace',
                  height: 1.45,
                ),
          ),
        ),
      ),
    );
  }
}

class _WorkspaceLoadingCard extends StatelessWidget {
  const _WorkspaceLoadingCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F141A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1B232C)),
      ),
      child: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Color(0xFFE4B15A),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFDCE6F2),
                  ),
            ),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceRetryCard extends StatelessWidget {
  const _WorkspaceRetryCard({
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F141A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF3C2A2A)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFFFFD5D2),
                  height: 1.45,
                ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFDCE6F2),
              side: const BorderSide(color: Color(0xFF32404D)),
            ),
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('다시 시도'),
          ),
        ],
      ),
    );
  }
}

class _WorkspaceHint extends StatelessWidget {
  const _WorkspaceHint({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Text(
      message,
      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: const Color(0xFF9FB0C0),
            height: 1.45,
          ),
    );
  }
}

class _WorkspaceLiveSyncCard extends StatelessWidget {
  const _WorkspaceLiveSyncCard({
    required this.controller,
    required this.focusPath,
    required this.runError,
    required this.onInspectFile,
  });

  final AppController controller;
  final String focusPath;
  final _WorkspaceRunError? runError;
  final ValueChanged<String> onInspectFile;

  @override
  Widget build(BuildContext context) {
    final selection = controller.liveSession.focus.selection.trim();
    final changedCount = {
      ...controller.liveSession.workspace.changedFiles,
      ...controller.runChangedFiles,
    }.where((item) => item.trim().isNotEmpty).length;
    final patchCount = {
      ...controller.liveSession.workspace.patchFiles,
      ...controller.patchFiles.map((item) => item.path),
    }.where((item) => item.trim().isNotEmpty).length;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF0F141A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1B232C)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '실시간 포커스',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: const Color(0xFFF4F7FB),
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (focusPath.isNotEmpty) const _FileMetaChip(label: '포커스 연결됨'),
              if (changedCount > 0) _FileMetaChip(label: '변경 $changedCount개'),
              if (patchCount > 0) _FileMetaChip(label: '패치 $patchCount개'),
              if (runError != null) const _FileMetaChip(label: '에러 위치 있음'),
            ],
          ),
          if (focusPath.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _compactPath(focusPath, keep: 56),
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: const Color(0xFFDCE6F2),
                    height: 1.35,
                  ),
            ),
          ],
          if (selection.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              '선택: $selection',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFF9FB0C0),
                    height: 1.35,
                  ),
            ),
          ],
          if (runError != null) ...[
            const SizedBox(height: 8),
            Text(
              '최근 에러: ${runError!.label}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: const Color(0xFFFFD5D2),
                    height: 1.35,
                  ),
            ),
          ],
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (focusPath.isNotEmpty)
                FilledButton.tonalIcon(
                  onPressed: () => onInspectFile(focusPath),
                  icon: const Icon(Icons.visibility_outlined),
                  label: const Text('포커스 보기'),
                ),
              if (runError != null)
                OutlinedButton.icon(
                  onPressed: () async {
                    await controller.openWorkspaceLocation(
                      runError!.path,
                      line: runError!.line <= 0 ? 1 : runError!.line,
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
      ),
    );
  }
}

class _FileMetaChip extends StatelessWidget {
  const _FileMetaChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0D141B),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: const Color(0xFF202A35)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFFDCE6F2),
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

String _compactPath(String value, {int keep = 34}) {
  final trimmed = value.trim();
  if (trimmed.length <= keep) {
    return trimmed;
  }
  return '...${trimmed.substring(trimmed.length - keep)}';
}

String _firstNonEmptyText(List<String> values) {
  for (final value in values) {
    final trimmed = value.trim();
    if (trimmed.isNotEmpty) {
      return trimmed;
    }
  }
  return '';
}

String _primaryFocusPath(AppController controller) {
  return _firstNonEmptyText([
    controller.liveSession.focus.activeFilePath,
    controller.liveSession.workspace.activeFilePath,
    controller.liveSession.focus.patchPath,
    controller.liveSession.focus.runErrorPath,
  ]);
}

_WorkspaceRunError? _primaryRunError(AppController controller) {
  final focus = controller.liveSession.focus;
  if (focus.runErrorPath.trim().isNotEmpty) {
    return _WorkspaceRunError(
      path: focus.runErrorPath.trim(),
      line: focus.runErrorLine,
      label: focus.runErrorLine > 0
          ? '${focus.runErrorPath.trim()}:${focus.runErrorLine}'
          : focus.runErrorPath.trim(),
    );
  }

  if (controller.topErrors.isEmpty) {
    return null;
  }
  final match = RegExp(r'^(.+?):(\d+)\s*(.*)$').firstMatch(
    controller.topErrors.first.trim(),
  );
  if (match == null) {
    return null;
  }

  final path = match.group(1)?.trim() ?? '';
  final line = int.tryParse(match.group(2) ?? '') ?? 1;
  final message = match.group(3)?.trim() ?? '';
  if (path.isEmpty) {
    return null;
  }
  return _WorkspaceRunError(
    path: path,
    line: line,
    label: message.isEmpty ? '$path:$line' : '$path:$line $message',
  );
}

class _WorkspaceRunError {
  const _WorkspaceRunError({
    required this.path,
    required this.line,
    required this.label,
  });

  final String path;
  final int line;
  final String label;
}

String _displayStatus(WorkspaceTreeEntryView entry) {
  if (entry.gitStatus.isNotEmpty) {
    return entry.gitStatus;
  }
  if (entry.isChanged) {
    return 'M';
  }
  if (entry.isPatch) {
    return 'P';
  }
  return '';
}

Color _statusTone(BuildContext context, WorkspaceTreeEntryView entry) {
  if (entry.hasError) {
    return Theme.of(context).colorScheme.error;
  }
  switch (_displayStatus(entry)) {
    case 'M':
      return const Color(0xFFE4B15A);
    case 'U':
      return const Color(0xFF7FD0B4);
    case 'A':
      return const Color(0xFF4E8DFF);
    case 'D':
      return Theme.of(context).colorScheme.error;
    case 'P':
      return const Color(0xFFE4B15A);
    default:
      return const Color(0xFF8FA0B3);
  }
}

IconData _iconForFilePath(String path) {
  final lower = path.toLowerCase();
  if (lower.endsWith('.dart')) {
    return Icons.code_rounded;
  }
  if (lower.endsWith('.md') || lower.endsWith('.txt')) {
    return Icons.description_outlined;
  }
  if (lower.endsWith('.py')) {
    return Icons.data_object_rounded;
  }
  if (lower.endsWith('.java')) {
    return Icons.coffee_rounded;
  }
  if (lower.endsWith('.json') || lower.endsWith('.yaml') || lower.endsWith('.yml')) {
    return Icons.data_object_rounded;
  }
  return Icons.insert_drive_file_outlined;
}
