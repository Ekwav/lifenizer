import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

class ImapImportPanel extends StatefulWidget {
  const ImapImportPanel({required this.state, super.key});
  final LifenizerAppState state;
  @override
  State<ImapImportPanel> createState() => _ImapImportPanelState();
}

class _ImapImportPanelState extends State<ImapImportPanel> {
  final _username = TextEditingController();
  final _password = TextEditingController();
  final _mailbox = TextEditingController(text: 'INBOX');
  Map<String, dynamic>? _settings;
  String? _error;
  bool _remember = !kIsWeb;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.state.emailImport.start();
    });
    unawaited(_loadSettings());
  }

  Future<void> _loadSettings() async {
    try {
      final settings = await widget.state.imapSettings();
      if (mounted) setState(() => _settings = settings);
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not load the configured email server.');
      }
    }
  }

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    _mailbox.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final password = _password.text;
    _password.clear();
    await widget.state.emailImport.connect(
      username: _username.text,
      password: password,
      mailbox: _mailbox.text,
      remember: _remember,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, widget.state.emailImport]),
    builder: (context, _) {
      final service = widget.state.emailImport;
      final enabled = !service.working && !widget.state.busy;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Connect email', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (_settings == null && _error == null)
            const LinearProgressIndicator(),
          if (_settings != null)
            Text(
              _settings!['configured'] == true
                  ? '${_settings!['host']}:${_settings!['port']} · ${_settings!['useTls'] == true ? 'TLS encrypted' : 'Local test server'}'
                  : 'The server administrator must configure an IMAP host.',
            ),
          const SizedBox(height: 8),
          const Text(
            'Use your email account’s app password where available. Messages are processed by your server, then saved encrypted in your vault.',
          ),
          TextField(
            controller: _username,
            enabled: enabled,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email username'),
          ),
          TextField(
            controller: _password,
            enabled: enabled,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Email app password'),
          ),
          TextField(
            controller: _mailbox,
            enabled: enabled,
            decoration: const InputDecoration(labelText: 'Mailbox'),
          ),
          if (!kIsWeb)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Remember on this device'),
              subtitle: const Text(
                'Saved in the OS credential store. Checks every 5 minutes while the app is open and the vault is unlocked.',
              ),
              value: _remember,
              onChanged: enabled
                  ? (value) => setState(() => _remember = value!)
                  : null,
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: enabled && _settings?['configured'] == true
                    ? _connect
                    : null,
                child: const Text('Connect & import'),
              ),
              if (service.connected)
                OutlinedButton(
                  onPressed: enabled ? service.fetch : null,
                  child: const Text('Check now'),
                ),
              if (service.connected || service.error != null)
                TextButton(
                  onPressed: enabled ? service.removeAccount : null,
                  child: const Text('Stop & remove account'),
                ),
            ],
          ),
          if (service.working) const LinearProgressIndicator(),
          if (service.connected)
            Text('${service.username} · ${service.mailbox}'),
          if (service.status != null) Text(service.status!),
          if (_error != null || service.error != null)
            Text(
              service.error ?? _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
