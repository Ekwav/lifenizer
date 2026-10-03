import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'app_state.dart';
import 'e2e_bridge.dart';
import 'pages/login_page.dart';
import 'share_intent_service.dart';
import 'widgets/vault_shell.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SemanticsBinding.instance.ensureSemantics();
  final appState = LifenizerAppState();
  installE2eBridge(appState);
  ShareIntentService.instance.start(appState);
  runApp(LifenizerApp(state: appState));
}

class LifenizerApp extends StatelessWidget {
  const LifenizerApp({required this.state, super.key});

  final LifenizerAppState state;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: state,
      builder: (context, _) {
        return MaterialApp(
          title: 'Lifenizer',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xff0f766e),
              brightness: Brightness.light,
            ),
            useMaterial3: true,
            cardTheme: const CardThemeData(
              margin: EdgeInsets.zero,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.all(Radius.circular(8)),
              ),
            ),
          ),
          home: state.isAuthenticated
              ? VaultShell(state: state)
              : LoginPage(state: state),
        );
      },
    );
  }
}
