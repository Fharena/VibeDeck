import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/prompt_screen.dart';
import 'screens/status_screen.dart';
import 'services/app_settings_store.dart';
import 'services/bootstrap_link_source.dart';
import 'state/app_controller.dart';

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

class VibeDeckApp extends StatelessWidget {
  const VibeDeckApp({
    super.key,
    this.controller,
    this.bootstrapLinkSource,
  });

  final AppController? controller;
  final BootstrapLinkSource? bootstrapLinkSource;

  @override
  Widget build(BuildContext context) {
    final baseTextTheme = ThemeData.light().textTheme;

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'VibeDeck Mobile',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1F8C77),
          brightness: Brightness.light,
        ),
        fontFamily: 'monospace',
        textTheme: baseTextTheme.copyWith(
          headlineLarge: const TextStyle(
            fontSize: 36,
            fontWeight: FontWeight.w700,
            fontFamily: 'serif',
            color: Color(0xFF0F2D28),
          ),
          headlineMedium: const TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w700,
            fontFamily: 'serif',
            color: Color(0xFF0F2D28),
          ),
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontFamily: 'serif',
            color: Color(0xFF0F2D28),
          ),
        ),
      ),
      home: MobileShell(
        controller: controller,
        bootstrapLinkSource: bootstrapLinkSource,
      ),
    );
  }
}

class MobileShell extends StatefulWidget {
  const MobileShell({
    super.key,
    this.controller,
    this.bootstrapLinkSource,
  });

  final AppController? controller;
  final BootstrapLinkSource? bootstrapLinkSource;

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  late final AppController _controller;
  late final bool _ownsController;
  late final BootstrapLinkSource _bootstrapLinkSource;
  StreamSubscription<Uri>? _bootstrapLinkSub;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ??
        AppController(settingsStore: FileAppSettingsStore());
    _ownsController = widget.controller == null;
    _bootstrapLinkSource = widget.bootstrapLinkSource ??
        (_ownsController
            ? AppLinksBootstrapLinkSource()
            : const NoopBootstrapLinkSource());
    unawaited(_initializeApp());
  }

  Future<void> _initializeApp() async {
    await _controller.initialize();

    final initialUri = await _bootstrapLinkSource.getInitialUri();
    if (initialUri != null) {
      await _controller.applyBootstrapUri(initialUri);
    }

    _bootstrapLinkSub = _bootstrapLinkSource.uriStream.listen((uri) {
      unawaited(_controller.applyBootstrapUri(uri));
    });
  }

  @override
  void dispose() {
    unawaited(_bootstrapLinkSub?.cancel());
    if (_ownsController) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final currentTitle = _controller.currentThreadTitle.trim().isEmpty
            ? 'New Session'
            : _controller.currentThreadTitle.trim();

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: const Color(0xFF081018),
          drawer: _ShellDrawer(
            controller: _controller,
            onNewThread: () {
              Navigator.of(context).pop();
              _controller.beginNewThread();
            },
            onSelectThread: (threadId) async {
              Navigator.of(context).pop();
              await _controller.selectThread(threadId);
            },
            onOpenStatus: () async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: 'Session Center',
                subtitle:
                    'Connection, bootstrap, and direct signaling live here.',
                child: StatusScreen(controller: _controller),
              );
            },
            onOpenTerminal: () async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: 'Terminal',
                subtitle:
                    'Inspect the current run state and recent terminal output.',
                child: TerminalSheet(controller: _controller),
              );
            },
            onOpenFiles: () async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: 'File Focus',
                subtitle:
                    'Review focus, changed files, and patch files for this session.',
                child: FileFocusSheet(controller: _controller),
              );
            },
          ),
          appBar: AppBar(
            backgroundColor: const Color(0xFF081018),
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              icon: const Icon(Icons.menu_rounded),
            ),
            titleSpacing: 0,
            title: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  currentTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: const Color(0xFFF4F7FB),
                      ),
                ),
                Text(
                  '${_controller.currentSessionPhase} / ${_controller.sessionSyncStatusLabel}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF8FA0B3),
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            actions: [
              if (_controller.isLoading)
                const Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Color(0xFFE4B15A),
                    ),
                  ),
                ),
              IconButton(
                tooltip: 'New Session',
                onPressed: _controller.beginNewThread,
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF081018),
                  Color(0xFF0D141C),
                  Color(0xFF111A23),
                ],
              ),
            ),
            child: SafeArea(
              top: false,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                child: PromptScreen(controller: _controller),
              ),
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

class _ShellDrawer extends StatefulWidget {
  const _ShellDrawer({
    required this.controller,
    required this.onNewThread,
    required this.onSelectThread,
    required this.onOpenStatus,
    required this.onOpenTerminal,
    required this.onOpenFiles,
  });

  final AppController controller;
  final VoidCallback onNewThread;
  final ValueChanged<String> onSelectThread;
  final VoidCallback onOpenStatus;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;

  @override
  State<_ShellDrawer> createState() => _ShellDrawerState();
}

class _ShellDrawerState extends State<_ShellDrawer> {
  final _searchController = TextEditingController();

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final workspaceFiles = _buildWorkspaceEntries(widget.controller);

    return Drawer(
      backgroundColor: const Color(0xFF090D11),
      child: SafeArea(
        child: DefaultTabController(
          length: 3,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: 'Close drawer',
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.menu_open_rounded),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextField(
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        style: const TextStyle(color: Color(0xFFF4F7FB)),
                        decoration: InputDecoration(
                          hintText: 'Search Sessions...',
                          hintStyle: const TextStyle(color: Color(0xFF6F7D8B)),
                          filled: true,
                          fillColor: const Color(0xFF11161C),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 12,
                          ),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(14),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: widget.onNewThread,
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFEAF1F8),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      side: const BorderSide(color: Color(0xFF2B3742)),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: const Text('New Agent'),
                  ),
                ),
              ),
              const TabBar(
                dividerColor: Color(0xFF1D252E),
                labelColor: Color(0xFFF4F7FB),
                unselectedLabelColor: Color(0xFF7F8D9C),
                indicatorColor: Color(0xFFE4B15A),
                tabs: [
                  Tab(text: 'Sessions'),
                  Tab(text: 'Files'),
                  Tab(text: 'Settings'),
                ],
              ),
              Expanded(
                child: TabBarView(
                  children: [
                    _SessionDrawerTab(
                      controller: widget.controller,
                      query: _searchController.text,
                      onSelectThread: widget.onSelectThread,
                    ),
                    _FilesDrawerTab(
                      controller: widget.controller,
                      files: workspaceFiles,
                      onOpenFiles: widget.onOpenFiles,
                    ),
                    _SettingsDrawerTab(
                      controller: widget.controller,
                      onOpenStatus: widget.onOpenStatus,
                      onOpenTerminal: widget.onOpenTerminal,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SessionDrawerTab extends StatelessWidget {
  const _SessionDrawerTab({
    required this.controller,
    required this.query,
    required this.onSelectThread,
  });

  final AppController controller;
  final String query;
  final ValueChanged<String> onSelectThread;

  @override
  Widget build(BuildContext context) {
    final normalizedQuery = query.trim().toLowerCase();
    final threads = controller.threads.where((thread) {
      if (normalizedQuery.isEmpty) {
        return true;
      }
      final haystack = '${thread.title} ${thread.lastEventText} ${thread.state}'
          .toLowerCase();
      return haystack.contains(normalizedQuery);
    }).toList();

    if (threads.isEmpty) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
        children: [
          Text(
            'Sessions',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          const SizedBox(height: 10),
          Text(
            normalizedQuery.isEmpty
                ? 'No sessions yet.'
                : 'No sessions match this search.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9FB0C0),
                  height: 1.45,
                ),
          ),
        ],
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      itemCount: threads.length + 1,
      separatorBuilder: (_, __) => const SizedBox(height: 10),
      itemBuilder: (context, index) {
        if (index == 0) {
          return Text(
            'Sessions',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          );
        }

        final thread = threads[index - 1];
        final isSelected = thread.id == controller.currentThreadId;
        final preview = thread.lastEventText.trim().isEmpty
            ? 'No events yet.'
            : thread.lastEventText.trim();

        return InkWell(
          onTap: () => onSelectThread(thread.id),
          borderRadius: BorderRadius.circular(16),
          child: Ink(
            decoration: BoxDecoration(
              color: isSelected
                  ? const Color(0xFF1A2028)
                  : const Color(0xFF0F141A),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF31455A)
                    : const Color(0xFF18202A),
              ),
            ),
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(
                      isSelected
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: isSelected
                          ? const Color(0xFFE4B15A)
                          : const Color(0xFF637282),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        thread.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              color: const Color(0xFFEAF1F8),
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      thread.updatedAtLabel,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: const Color(0xFF8FA0B3),
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  preview,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: const Color(0xFF9FB0C0),
                        height: 1.35,
                      ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    _DrawerBadge(
                      label: thread.state.isEmpty ? 'draft' : thread.state,
                    ),
                    if (thread.currentJobId.isNotEmpty)
                      _DrawerBadge(
                        label: thread.currentJobId,
                        tone: const Color(0xFF2E9D78),
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
}

class _FilesDrawerTab extends StatelessWidget {
  const _FilesDrawerTab({
    required this.controller,
    required this.files,
    required this.onOpenFiles,
  });

  final AppController controller;
  final List<_WorkspaceFileEntry> files;
  final VoidCallback onOpenFiles;

  @override
  Widget build(BuildContext context) {
    final rootPath = _firstNonEmptyText([
      controller.liveSession.workspace.rootPath,
      controller.adapterRuntime.workspaceRoot,
    ]);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text(
          'Files',
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
        const SizedBox(height: 12),
        if (files.isEmpty)
          Text(
            'No file focus yet. Patch or run activity will surface the files this session is looking at.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: const Color(0xFF9FB0C0),
                  height: 1.45,
                ),
          )
        else
          ..._buildFileTree(
            files: files,
            onOpenFiles: onOpenFiles,
          ),
      ],
    );
  }
}

class _SettingsDrawerTab extends StatelessWidget {
  const _SettingsDrawerTab({
    required this.controller,
    required this.onOpenStatus,
    required this.onOpenTerminal,
  });

  final AppController controller;
  final VoidCallback onOpenStatus;
  final VoidCallback onOpenTerminal;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 24),
      children: [
        Text(
          'Settings',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFF4F7FB),
              ),
        ),
        const SizedBox(height: 12),
        _DrawerInfoCard(
          rows: [
            _DrawerInfoRow(label: 'Agent', value: controller.agentBaseUrl),
            _DrawerInfoRow(
                label: 'Signaling', value: controller.signalingBaseUrl),
            _DrawerInfoRow(
              label: 'Adapter',
              value: controller.adapterRuntime.name.isEmpty
                  ? controller.bootstrap.adapter.name
                  : controller.adapterRuntime.name,
            ),
            _DrawerInfoRow(label: 'Control', value: controller.controlPath),
            _DrawerInfoRow(label: 'State', value: controller.connectionState),
            _DrawerInfoRow(
                label: 'Sync', value: controller.sessionSyncStatusLabel),
          ],
        ),
        const SizedBox(height: 12),
        _DrawerInfoCard(
          rows: [
            _DrawerInfoRow(
              label: 'Workspace',
              value: _firstNonEmptyText([
                controller.liveSession.workspace.rootPath,
                controller.adapterRuntime.workspaceRoot,
              ], fallback: '-'),
            ),
            _DrawerInfoRow(
                label: 'Last Sync', value: controller.sessionLastSyncedLabel),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: onOpenStatus,
          icon: const Icon(Icons.tune),
          label: const Text('Open Session Center'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onOpenTerminal,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFDCE6F2),
            side: const BorderSide(color: Color(0xFF32404D)),
          ),
          icon: const Icon(Icons.terminal_rounded),
          label: const Text('Open Terminal'),
        ),
      ],
    );
  }
}

class _DrawerInfoCard extends StatelessWidget {
  const _DrawerInfoCard({required this.rows});

  final List<_DrawerInfoRow> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F141A),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF1B232C)),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        children: [
          for (var index = 0; index < rows.length; index++) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 76,
                  child: Text(
                    rows[index].label,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFF8FA0B3),
                        ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rows[index].value,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: const Color(0xFFDCE6F2),
                          height: 1.35,
                        ),
                  ),
                ),
              ],
            ),
            if (index != rows.length - 1) const SizedBox(height: 10),
          ],
        ],
      ),
    );
  }
}

class _DrawerInfoRow {
  const _DrawerInfoRow({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;
}

class _DrawerBadge extends StatelessWidget {
  const _DrawerBadge({
    required this.label,
    this.tone = const Color(0xFF6B7A8A),
  });

  final String label;
  final Color tone;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.22)),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: const Color(0xFFDCE6F2),
              fontWeight: FontWeight.w700,
            ),
      ),
    );
  }
}

class _WorkspaceFileEntry {
  const _WorkspaceFileEntry({
    required this.path,
    this.isActive = false,
    this.isChanged = false,
    this.isPatch = false,
    this.hasError = false,
  });

  final String path;
  final bool isActive;
  final bool isChanged;
  final bool isPatch;
  final bool hasError;
}

class _WorkspaceTreeNode {
  _WorkspaceTreeNode({
    required this.name,
    required this.path,
    required this.isFile,
  });

  final String name;
  final String path;
  final bool isFile;
  _WorkspaceFileEntry? file;
  final Map<String, _WorkspaceTreeNode> children =
      <String, _WorkspaceTreeNode>{};
}

List<_WorkspaceFileEntry> _buildWorkspaceEntries(AppController controller) {
  final activePath = _firstNonEmptyText([
    controller.liveSession.focus.activeFilePath,
    controller.liveSession.workspace.activeFilePath,
  ]);
  final runErrorPath = controller.liveSession.focus.runErrorPath.trim();
  final changedFiles = <String>{
    ...controller.liveSession.workspace.changedFiles,
    ...controller.runChangedFiles,
    ...controller.currentJobFiles,
  };
  final patchFiles = <String>{
    ...controller.liveSession.workspace.patchFiles,
    ...controller.patchFiles.map((file) => file.path),
  };
  final allPaths = <String>{
    if (activePath.isNotEmpty) activePath,
    if (runErrorPath.isNotEmpty) runErrorPath,
    ...changedFiles.where((path) => path.trim().isNotEmpty),
    ...patchFiles.where((path) => path.trim().isNotEmpty),
  }.toList()
    ..sort();

  return allPaths
      .map(
        (path) => _WorkspaceFileEntry(
          path: path,
          isActive: path == activePath,
          isChanged: changedFiles.contains(path),
          isPatch: patchFiles.contains(path),
          hasError: path == runErrorPath,
        ),
      )
      .toList()
    ..sort((left, right) {
      final leftScore = (left.isActive ? 0 : 10) +
          (left.hasError ? 0 : 5) +
          (left.isChanged ? 0 : 2);
      final rightScore = (right.isActive ? 0 : 10) +
          (right.hasError ? 0 : 5) +
          (right.isChanged ? 0 : 2);
      if (leftScore != rightScore) {
        return leftScore.compareTo(rightScore);
      }
      return left.path.compareTo(right.path);
    });
}

List<Widget> _buildFileTree({
  required List<_WorkspaceFileEntry> files,
  required VoidCallback onOpenFiles,
}) {
  final root = _WorkspaceTreeNode(name: '', path: '', isFile: false);

  for (final file in files) {
    final parts = file.path
        .split(RegExp(r'[\\/]'))
        .where((part) => part.trim().isNotEmpty)
        .toList();
    if (parts.isEmpty) {
      continue;
    }

    var current = root;
    final pathParts = <String>[];
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      pathParts.add(part);
      final isFile = index == parts.length - 1;
      current = current.children.putIfAbsent(
        part,
        () => _WorkspaceTreeNode(
          name: part,
          path: pathParts.join('/'),
          isFile: isFile,
        ),
      );
      if (isFile) {
        current.file = file;
      }
    }
  }

  final widgets = <Widget>[];
  final children = root.children.values.toList()
    ..sort((left, right) => left.name.compareTo(right.name));
  for (final child in children) {
    widgets.add(
      _WorkspaceTreeTile(
        node: child,
        depth: 0,
        onOpenFiles: onOpenFiles,
      ),
    );
  }
  return widgets;
}

class _WorkspaceTreeTile extends StatelessWidget {
  const _WorkspaceTreeTile({
    required this.node,
    required this.depth,
    required this.onOpenFiles,
  });

  final _WorkspaceTreeNode node;
  final int depth;
  final VoidCallback onOpenFiles;

  @override
  Widget build(BuildContext context) {
    if (node.isFile && node.file != null) {
      return _WorkspaceFileRow(
        entry: node.file!,
        depth: depth,
        onTap: onOpenFiles,
      );
    }

    final children = node.children.values.toList()
      ..sort((left, right) {
        if (left.isFile != right.isFile) {
          return left.isFile ? 1 : -1;
        }
        return left.name.compareTo(right.name);
      });

    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.only(left: depth * 14 + 8, right: 4),
        childrenPadding: EdgeInsets.zero,
        initiallyExpanded: depth < 1,
        iconColor: const Color(0xFF8FA0B3),
        collapsedIconColor: const Color(0xFF637282),
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
                node.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: const Color(0xFFEAF1F8),
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
        children: [
          for (final child in children)
            _WorkspaceTreeTile(
              node: child,
              depth: depth + 1,
              onOpenFiles: onOpenFiles,
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

  final _WorkspaceFileEntry entry;
  final int depth;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final badges = <Widget>[
      if (entry.isActive)
        const _DrawerBadge(label: 'ACT', tone: Color(0xFF4E8DFF)),
      if (entry.isChanged)
        const _DrawerBadge(label: 'MOD', tone: Color(0xFF2E9D78)),
      if (entry.isPatch)
        const _DrawerBadge(label: 'PATCH', tone: Color(0xFFE4B15A)),
      if (entry.hasError)
        _DrawerBadge(
          label: 'ERR',
          tone: Theme.of(context).colorScheme.error,
        ),
    ];

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.fromLTRB(depth * 14 + 30, 8, 4, 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              _iconForFilePath(entry.path),
              size: 18,
              color: const Color(0xFF7FD0B4),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.path.split(RegExp(r'[\\/]')).last,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: const Color(0xFFEAF1F8),
                          fontWeight: FontWeight.w600,
                        ),
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
            const SizedBox(width: 8),
            if (badges.isNotEmpty)
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: badges,
              ),
          ],
        ),
      ),
    );
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
  return Icons.insert_drive_file_outlined;
}
