import 'dart:async';

import 'package:flutter/material.dart';

import 'screens/prompt_screen.dart';
import 'services/app_settings_store.dart';
import 'services/bootstrap_link_source.dart';
import 'state/app_controller.dart';

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
        return Scaffold(
          body: Container(
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFF081018),
                  Color(0xFF0D141C),
                  Color(0xFF111A23)
                ],
              ),
            ),
            child: SafeArea(
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
                    child: Row(
                      children: [
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: const Color(0xFFE4B15A),
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: const [
                              BoxShadow(
                                color: Color(0x33291900),
                                blurRadius: 18,
                                offset: Offset(0, 8),
                              ),
                            ],
                          ),
                          child: _controller.isLoading
                              ? const Padding(
                                  padding: EdgeInsets.all(10),
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Color(0xFF10161D),
                                  ),
                                )
                              : const Icon(
                                  Icons.auto_awesome,
                                  color: Color(0xFF10161D),
                                ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'VibeDeck Mobile',
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      color: const Color(0xFFF4F7FB),
                                    ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '공유 세션을 모바일에서 이어가는 컨트롤 레이어',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: const Color(0xFF93A4B7),
                                      fontWeight: FontWeight.w500,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 260),
                      child: PromptScreen(controller: _controller),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
