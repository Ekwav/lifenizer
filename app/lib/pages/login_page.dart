import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';

import '../app_state.dart';

/// Vault unlock screen shown when no authenticated session exists.
///
/// In debug builds only, the email/passphrase fields are prefilled with the
/// local dev-login demo credentials so manual testing stays fast; release
/// builds always start with empty fields so no demo credentials ship to
/// real users.
class LoginPage extends StatefulWidget {
  const LoginPage({required this.state, super.key});

  final LifenizerAppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  late final TextEditingController _apiController;
  final TextEditingController _emailController = TextEditingController(
    text: kDebugMode ? 'alice@example.test' : '',
  );
  final TextEditingController _passphraseController = TextEditingController(
    text: kDebugMode ? 'correct horse battery staple' : '',
  );

  @override
  void initState() {
    super.initState();
    _apiController = TextEditingController(text: widget.state.apiBaseUrl);
  }

  @override
  void dispose() {
    _apiController.dispose();
    _emailController.dispose();
    _passphraseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Lifenizer',
                    style: Theme.of(context).textTheme.displaySmall,
                  ),
                  const SizedBox(height: 24),
                  TextField(
                    controller: _apiController,
                    decoration: const InputDecoration(
                      labelText: 'API URL',
                      prefixIcon: Icon(Icons.dns_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _emailController,
                    decoration: const InputDecoration(
                      labelText: 'Email',
                      prefixIcon: Icon(Icons.alternate_email),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _passphraseController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Vault passphrase',
                      prefixIcon: Icon(Icons.key_outlined),
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: widget.state.busy
                        ? null
                        : () => widget.state.login(
                            baseUrl: _apiController.text,
                            email: _emailController.text,
                            passphrase: _passphraseController.text,
                          ),
                    icon: const Icon(Icons.lock_open),
                    label: const Text('Enter vault'),
                  ),
                  if (widget.state.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.state.error!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
