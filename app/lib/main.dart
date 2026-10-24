import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_state.dart';
import 'e2e_bridge.dart';
import 'pages/login_page.dart';
import 'share_intent_service.dart';
import 'services/quick_action_service.dart';
import 'services/export_watch_service.dart';
import 'widgets/vault_shell.dart';

Future<void> main([List<String> arguments = const []]) async {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  final appState = LifenizerAppState()
    ..startupLoading = true
    ..startupUnlockPending = true;
  runApp(LifenizerApp(state: appState));
  WidgetsBinding.instance.addPostFrameCallback(
    (_) => appState.markStartup('firstFrame'),
  );
  try {
    await appState.initialize();
    appState.markStartup('metadata');
    await appState.pairing.restore(autoUnlock: false);
    appState.markStartup('deviceCredentials');
    appState.emailImport.start();
    appState.documentImport.start();
    appState.cameraRoll.start();
    appState.browserHistory.start();
    appState.browserExtension.start();
    appState.recordingRelay.start();
    installE2eBridge(appState);
    unawaited(ShareIntentService.instance.start(appState));
    await QuickActionService.instance.start(appState, arguments: arguments);
    await ExportWatchService.instance.start(appState);
    appState.finishStartup();
  } catch (error) {
    appState.finishStartup(error);
  }
}

class LifenizerApp extends StatefulWidget {
  const LifenizerApp({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<LifenizerApp> createState() => _LifenizerAppState();
}

class _LifenizerAppState extends State<LifenizerApp>
    with WidgetsBindingObserver {
  Timer? _syncTimer;
  late final _lightTheme = _theme(Brightness.light);
  late final _darkTheme = _theme(Brightness.dark);

  ThemeData _theme(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xff0f766e),
      brightness: brightness,
    ),
    useMaterial3: true,
    cardTheme: const CardThemeData(
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
    ),
  );

  LifenizerAppState get state => widget.state;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _resumeSync();
  }

  void _resumeSync() {
    _syncTimer?.cancel();
    unawaited(state.pairing.tick());
    unawaited(state.syncQuietly());
    unawaited(ExportWatchService.instance.checkForChanges());
    _syncTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => state.syncQuietly(),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) {
      _resumeSync();
    } else if (lifecycle == AppLifecycleState.paused ||
        lifecycle == AppLifecycleState.detached) {
      _syncTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          key: ValueKey(state.isAuthenticated),
          title: 'Lifenizer',
          debugShowCheckedModeBanner: false,
          themeMode: ThemeMode.system,
          theme: _lightTheme,
          darkTheme: _darkTheme,
          home: state.isAuthenticated
              ? VaultShell(state: state)
              : LoginPage(state: state),
        );
      },
    );
  }
}
