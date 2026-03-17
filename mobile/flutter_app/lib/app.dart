import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/prompt_screen.dart';
import 'screens/status_screen.dart';
import 'screens/workspace_browser.dart';
import 'services/app_settings_store.dart';
import 'services/bootstrap_link_source.dart';
import 'state/app_controller.dart';

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
      title: '바이브덱 모바일',
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
            ? '새 세션'
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
                title: '세션 센터',
                subtitle: '연결, bootstrap, direct signaling 같은 운영 표면을 모아둭니다.',
                child: StatusScreen(controller: _controller),
              );
            },
            onOpenTerminal: () async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: '터미널',
                subtitle: '현재 세션에서 보고 있는 실행 상태와 최근 출력을 바로 확인합니다.',
                child: TerminalSheet(controller: _controller),
              );
            },
            onOpenFiles: () async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: '파일 포커스',
                subtitle: '현재 세션의 포커스, 변경 파일, 패치 파일을 한 번에 봅니다.',
                child: FileFocusSheet(controller: _controller),
              );
            },
            onInspectWorkspaceFile: (path) async {
              Navigator.of(context).pop();
              await _showBottomSheet(
                title: '파일 미리보기',
                subtitle: '작업 파일을 확인하고 필요한 경우 바로 수정합니다.',
                child: WorkspaceFileSheet(
                  controller: _controller,
                  path: path,
                ),
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
                tooltip: '새 세션',
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
    required this.onInspectWorkspaceFile,
  });

  final AppController controller;
  final VoidCallback onNewThread;
  final ValueChanged<String> onSelectThread;
  final VoidCallback onOpenStatus;
  final VoidCallback onOpenTerminal;
  final VoidCallback onOpenFiles;
  final ValueChanged<String> onInspectWorkspaceFile;

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
                      tooltip: '드로어 닫기',
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
                          hintText: '세션 검색...',
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
                    child: const Text('새 세션'),
                  ),
                ),
              ),
              const TabBar(
                dividerColor: Color(0xFF1D252E),
                labelColor: Color(0xFFF4F7FB),
                unselectedLabelColor: Color(0xFF7F8D9C),
                indicatorColor: Color(0xFFE4B15A),
                tabs: [
                  Tab(text: '세션'),
                  Tab(text: '파일'),
                  Tab(text: '설정'),
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
                      onInspectFile: widget.onInspectWorkspaceFile,
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
            '세션',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          ),
          const SizedBox(height: 10),
          Text(
            normalizedQuery.isEmpty ? '아직 세션이 없습니다.' : '검색 조건과 맞는 세션이 없습니다.',
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
            '세션',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: const Color(0xFFF4F7FB),
                ),
          );
        }

        final thread = threads[index - 1];
        final isSelected = thread.id == controller.currentThreadId;
        final preview = thread.lastEventText.trim().isEmpty
            ? '아직 이벤트가 없습니다.'
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
                      label: thread.state.isEmpty ? '초안' : thread.state,
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
    required this.onInspectFile,
  });

  final AppController controller;
  final ValueChanged<String> onInspectFile;

  @override
  Widget build(BuildContext context) {
    return WorkspaceDrawerTab(
      controller: controller,
      onInspectFile: onInspectFile,
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
          '설정',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: const Color(0xFFF4F7FB),
              ),
        ),
        const SizedBox(height: 12),
        _DrawerInfoCard(
          rows: [
            _DrawerInfoRow(label: '에이전트', value: controller.agentBaseUrl),
            _DrawerInfoRow(label: '시그널링', value: controller.signalingBaseUrl),
            _DrawerInfoRow(
              label: '어댑터',
              value: controller.adapterRuntime.name.isEmpty
                  ? controller.bootstrap.adapter.name
                  : controller.adapterRuntime.name,
            ),
            _DrawerInfoRow(label: '제어 경로', value: controller.controlPath),
            _DrawerInfoRow(label: '연결 상태', value: controller.connectionState),
            _DrawerInfoRow(
                label: '동기화', value: controller.sessionSyncStatusLabel),
          ],
        ),
        const SizedBox(height: 12),
        _DrawerInfoCard(
          rows: [
            _DrawerInfoRow(
              label: '작업 경로',
              value: _firstNonEmptyText([
                controller.liveSession.workspace.rootPath,
                controller.adapterRuntime.workspaceRoot,
              ], fallback: '-'),
            ),
            _DrawerInfoRow(
                label: '마지막 동기화', value: controller.sessionLastSyncedLabel),
          ],
        ),
        const SizedBox(height: 14),
        FilledButton.tonalIcon(
          onPressed: onOpenStatus,
          icon: const Icon(Icons.tune),
          label: const Text('세션 센터 열기'),
        ),
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: onOpenTerminal,
          style: OutlinedButton.styleFrom(
            foregroundColor: const Color(0xFFDCE6F2),
            side: const BorderSide(color: Color(0xFF32404D)),
          ),
          icon: const Icon(Icons.terminal_rounded),
          label: const Text('터미널 열기'),
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
