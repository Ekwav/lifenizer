import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../app_state.dart';
import '../services/quick_action_service.dart';
import '../widgets/sync_progress_indicator.dart';
import '../widgets/device_security_dialog.dart';
import 'connection_scanner_page.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> with WidgetsBindingObserver {
  late final _search = TextEditingController(
    text: widget.state.pendingSearchQuery,
  );
  late final _api = TextEditingController(text: widget.state.apiBaseUrl);
  late final _email = TextEditingController(text: widget.state.rememberedEmail);
  final _password = TextEditingController();
  final _passphrase = TextEditingController();
  final _confirmation = TextEditingController();
  final _invitation = TextEditingController();
  final _connectionLink = TextEditingController();
  bool _manual = false;
  bool _register = false;
  bool _linkElsewhere = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.state.addListener(_stateChanged);
    QuickActionService.instance.addListener(_receiveAction);
    widget.state.pairing.addListener(_maybeAutoUnlock);
    _stateChanged();
    _receiveAction();
  }

  void _stateChanged() {
    _maybeAutoUnlock();
    _maybeStartRecording();
  }

  void _receiveAction() {
    final action = QuickActionService.instance.pending;
    if (action?.action == 'search') {
      _search.text = action!.query;
      widget.state.pendingSearchQuery = action.query;
    }
    _maybeStartRecording();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycle) {
    if (lifecycle == AppLifecycleState.resumed) _maybeStartRecording();
  }

  void _maybeStartRecording() {
    if (kIsWeb ||
        defaultTargetPlatform != TargetPlatform.android ||
        widget.state.rememberedEmail.isEmpty ||
        QuickActionService.instance.pending?.action != 'record') {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed ||
          QuickActionService.instance.pending?.action != 'record') {
        return;
      }
      QuickActionService.instance.consume();
      QuickActionService.instance.request(const QuickAction(action: 'capture'));
      unawaited(widget.state.recording.start().whenComplete(_maybeAutoUnlock));
    });
  }

  Widget _searchField() => TextField(
    controller: _search,
    onChanged: (query) {
      widget.state.pendingSearchQuery = query;
      if (QuickActionService.instance.pending?.action == 'search') {
        QuickActionService.instance.consume();
      }
    },
    textInputAction: TextInputAction.search,
    decoration: const InputDecoration(
      hintText: 'Search conversations',
      prefixIcon: Icon(Icons.search),
      border: OutlineInputBorder(),
    ),
  );

  Widget _recordingControls() {
    final recording = widget.state.recording;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          onPressed: recording.working
              ? null
              : () {
                  if (recording.recording) {
                    unawaited(recording.stop());
                  } else {
                    unawaited(recording.start().whenComplete(_maybeAutoUnlock));
                  }
                },
          icon: Icon(recording.recording ? Icons.stop : Icons.mic),
          label: Text(
            recording.recording
                ? 'Stop and save recording'
                : 'Start microphone recording',
          ),
        ),
        if (recording.recording)
          const Text('Recording continues while you unlock this device.'),
        if (recording.error != null) Text(recording.error!),
      ],
    );
  }

  bool get _canRecord =>
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.android &&
      widget.state.rememberedEmail.isNotEmpty;

  void _maybeAutoUnlock() {
    final state = widget.state;
    final pairing = state.pairing;
    if (!mounted ||
        state.startupLoading ||
        !state.startupUnlockPending ||
        state.busy ||
        pairing.busy ||
        (_canRecord &&
            (state.recording.working ||
                QuickActionService.instance.pending?.action == 'record'))) {
      return;
    }
    state.startupUnlockPending = false;
    if (_linkElsewhere ||
        !pairing.isPaired ||
        pairing.protectionMode == 'password' ||
        state.isAuthenticated) {
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_linkElsewhere && !state.isAuthenticated) {
        _unlockDevice();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.state.removeListener(_stateChanged);
    QuickActionService.instance.removeListener(_receiveAction);
    widget.state.pairing.removeListener(_maybeAutoUnlock);
    for (final controller in [
      _search,
      _api,
      _email,
      _password,
      _passphrase,
      _confirmation,
      _invitation,
      _connectionLink,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _enter({bool offline = false}) async {
    if (_register && !offline && _passphrase.text != _confirmation.text) {
      widget.state.reportError('The vault passphrases do not match.');
      return;
    }
    await widget.state.login(
      baseUrl: _api.text,
      email: _email.text,
      password: _password.text,
      passphrase: _passphrase.text,
      register: _register,
      registrationToken: _register ? _invitation.text : null,
      offline: offline,
    );
  }

  Future<void> _scanConnection() async {
    final link = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const ConnectionScannerPage()),
    );
    if (!mounted ||
        link == null ||
        widget.state.busy ||
        widget.state.pairing.busy) {
      return;
    }
    await widget.state.pairing.connect(link);
  }

  Future<void> _unlockDevice() async {
    String? password;
    if (widget.state.pairing.protectionMode == 'password') {
      password = await requestDevicePassword(context);
      if (!mounted || password == null) return;
    }
    await widget.state.pairing.unlockSaved(
      password: password,
      authenticate: true,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.state.recording,
    builder: (context, _) =>
        widget.state.startupLoading ? _startupPage() : _loginPage(context),
  );

  Widget _startupPage() => Scaffold(
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _searchField(),
                const SizedBox(height: 16),
                if (_canRecord) ...[
                  _recordingControls(),
                  const SizedBox(height: 16),
                ],
                const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    ),
  );

  Widget _loginPage(BuildContext context) => Scaffold(
    body: SafeArea(
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: AutofillGroup(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Image.asset(
                        'assets/branding/logo.png',
                        width: 48,
                        height: 48,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Lifenizer',
                          style: Theme.of(context).textTheme.displaySmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Your conversations, searchable on every device.'),
                  const SizedBox(height: 24),
                  if (widget.state.pairing.isPaired && !_linkElsewhere) ...[
                    _searchField(),
                    const SizedBox(height: 16),
                    if (_canRecord) ...[
                      _recordingControls(),
                      const SizedBox(height: 16),
                    ],
                  ],
                  SyncProgressIndicator(progress: widget.state.syncProgress),
                  if (!kIsWeb) ...[
                    if (widget.state.pairing.isPaired && !_linkElsewhere) ...[
                      FilledButton.icon(
                        onPressed:
                            widget.state.busy || widget.state.pairing.busy
                            ? null
                            : _unlockDevice,
                        icon: const Icon(Icons.lock_open),
                        label: const Text('Unlock this device'),
                      ),
                      TextButton(
                        onPressed:
                            widget.state.busy || widget.state.pairing.busy
                            ? null
                            : () => setState(() {
                                widget.state.startupUnlockPending = false;
                                _linkElsewhere = true;
                              }),
                        child: const Text('Link elsewhere'),
                      ),
                    ],
                    if (!widget.state.pairing.isPaired || _linkElsewhere) ...[
                      if (_linkElsewhere) ...[
                        TextButton(
                          onPressed:
                              widget.state.busy || widget.state.pairing.busy
                              ? null
                              : () => setState(() {
                                  _linkElsewhere = false;
                                  _manual = false;
                                }),
                          child: const Text('Cancel'),
                        ),
                        if (widget.state.pairing.higherSecurity)
                          const Text(
                            'Unlock this device before changing its protected connection.',
                          ),
                      ],
                      if (defaultTargetPlatform == TargetPlatform.android) ...[
                        FilledButton.icon(
                          onPressed:
                              widget.state.busy || widget.state.pairing.busy
                              ? null
                              : _scanConnection,
                          icon: const Icon(Icons.qr_code_scanner),
                          label: const Text('Scan connection QR'),
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextField(
                        controller: _connectionLink,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Connection link',
                          helperText:
                              'Paste your setup link or scan its QR code.',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      FilledButton.icon(
                        onPressed:
                            widget.state.busy || widget.state.pairing.busy
                            ? null
                            : () {
                                final link = _connectionLink.text;
                                _connectionLink.clear();
                                widget.state.pairing.connect(link);
                              },
                        icon: const Icon(Icons.link),
                        label: const Text('Connect this device'),
                      ),
                    ],
                    if (widget.state.pairing.busy) ...[
                      if (widget.state.syncProgress == null)
                        const LinearProgressIndicator(),
                      if (widget.state.pairing.waitingForApproval)
                        TextButton(
                          onPressed: widget.state.pairing.cancel,
                          child: const Text('Cancel'),
                        ),
                    ],
                    if (widget.state.pairing.message != null)
                      Text(widget.state.pairing.message!),
                    if (widget.state.pairing.error != null)
                      Text(
                        widget.state.pairing.error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    if (!widget.state.pairing.isPaired || _linkElsewhere)
                      TextButton(
                        onPressed: () => setState(() => _manual = !_manual),
                        child: Text(
                          _manual
                              ? 'Hide account login'
                              : 'Use email and passwords',
                        ),
                      ),
                  ],
                  if (kIsWeb ||
                      (_manual &&
                          (!widget.state.pairing.isPaired ||
                              _linkElsewhere))) ...[
                    TextField(
                      controller: _api,
                      keyboardType: TextInputType.url,
                      decoration: const InputDecoration(
                        labelText: 'API URL',
                        helperText:
                            'Use the same HTTPS server on your phone and computer.',
                        prefixIcon: Icon(Icons.dns_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _email,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.username],
                      decoration: const InputDecoration(
                        labelText: 'Email',
                        prefixIcon: Icon(Icons.alternate_email),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _password,
                      obscureText: true,
                      autofillHints: [
                        _register
                            ? AutofillHints.newPassword
                            : AutofillHints.password,
                      ],
                      decoration: const InputDecoration(
                        labelText: 'Account password',
                        helperText: 'Authenticates sync with your server.',
                        prefixIcon: Icon(Icons.password),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _passphrase,
                      obscureText: true,
                      onSubmitted: (_) {
                        if (!widget.state.busy && !widget.state.pairing.busy) {
                          _enter();
                        }
                      },
                      decoration: const InputDecoration(
                        labelText: 'Vault passphrase',
                        helperText:
                            'Decrypts on this device. Never sent to the server.',
                        prefixIcon: Icon(Icons.key_outlined),
                        border: OutlineInputBorder(),
                      ),
                    ),
                    if (_register) ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _confirmation,
                        obscureText: true,
                        decoration: const InputDecoration(
                          labelText: 'Repeat vault passphrase',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: _invitation,
                        obscureText: true,
                        autocorrect: false,
                        enableSuggestions: false,
                        decoration: const InputDecoration(
                          labelText: 'Invitation code (if required)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Use a different passphrase from your account password. Keep it in your password manager; a forgotten vault passphrase cannot be recovered.',
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: widget.state.busy || widget.state.pairing.busy
                          ? null
                          : _enter,
                      icon: const Icon(Icons.lock_open),
                      label: Text(
                        _register ? 'Create encrypted vault' : 'Enter vault',
                      ),
                    ),
                    TextButton(
                      onPressed: widget.state.busy || widget.state.pairing.busy
                          ? null
                          : () => setState(() => _register = !_register),
                      child: Text(
                        _register
                            ? 'Use an existing account'
                            : 'Create an account',
                      ),
                    ),
                    if (!_register)
                      OutlinedButton.icon(
                        onPressed:
                            widget.state.busy || widget.state.pairing.busy
                            ? null
                            : () => _enter(offline: true),
                        icon: const Icon(Icons.offline_bolt_outlined),
                        label: const Text('Unlock this device offline'),
                      ),
                  ],
                  if (widget.state.busy && widget.state.syncProgress == null)
                    const LinearProgressIndicator(),
                  if (widget.state.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      widget.state.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
