import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';
import '../services/source_links.dart';
import '../services/paperless_client.dart';

class PaperlessImportPanel extends StatefulWidget {
  const PaperlessImportPanel({required this.state, super.key});
  final LifenizerAppState state;
  @override
  State<PaperlessImportPanel> createState() => _PaperlessImportPanelState();
}

class _PaperlessImportPanelState extends State<PaperlessImportPanel> {
  final _token = TextEditingController();
  final _address = TextEditingController();
  bool _remember = !kIsWeb;
  bool _loading = true;
  bool _editing = false;
  Uri? _server;
  String? _error;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSettings());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.state.documentImport.start();
    });
  }

  Future<void> _loadSettings() async {
    setState(() {
      _loading = true;
      _error = null;
      _server = null;
    });
    try {
      final settings = await widget.state.paperlessSettings();
      if (!mounted) return;
      final uri =
          settings['configured'] == true && settings['baseUrl'] is String
          ? externalLinkUri(settings['baseUrl'] as String)
          : null;
      if (uri != null && !uri.hasQuery && !uri.hasFragment) {
        _server = uri;
      } else if (kIsWeb) {
        _error =
            'Your Lifenizer server has no Paperless address configured. If you run this server, set Imports__Paperless__BaseUrl to your trusted Paperless address, restart the server, then retry.';
      }
    } catch (_) {
      if (mounted && kIsWeb) {
        _error =
            'Could not load Paperless setup. Check your Lifenizer connection, then retry.';
      }
    } finally {
      if (mounted) {
        if (!kIsWeb && _address.text.isEmpty) {
          final platform = defaultTargetPlatform;
          _address.text =
              widget.state.documentImport.baseUrl ??
              _server?.toString() ??
              (platform == TargetPlatform.android ||
                      platform == TargetPlatform.iOS
                  ? ''
                  : 'http://127.0.0.1:8002');
        }
        setState(() => _loading = false);
      }
    }
  }

  bool _matchesServer(Uri address) =>
      _server != null &&
      address.toString().replaceFirst(RegExp(r'/$'), '') ==
          _server.toString().replaceFirst(RegExp(r'/$'), '');

  Uri? _connectionAddress() {
    if (kIsWeb) return _server;
    final configured = externalLinkUri(_address.text);
    if (configured != null &&
        _matchesServer(configured) &&
        !widget.state.documentImport.directConnection) {
      return configured;
    }
    try {
      return PaperlessClient.validateBaseUrl(_address.text);
    } on FormatException catch (error) {
      setState(() => _error = error.message);
      return null;
    }
  }

  Future<void> _openPaperless() async {
    setState(() => _error = null);
    final address = _connectionAddress();
    if (address == null) return;
    final opened = await openExternalLink(address.toString());
    if (!opened && mounted) {
      setState(
        () => _error =
            'Could not open the browser. Open $address in your browser to copy the token.',
      );
    }
  }

  Future<void> _connect() async {
    setState(() {
      _editing = true;
      _error = null;
    });
    final address = _connectionAddress();
    if (address == null) return;
    final service = widget.state.documentImport;
    await service.connect(
      token: _token.text,
      remember: _remember,
      baseUrl: !kIsWeb && (service.directConnection || !_matchesServer(address))
          ? address.toString()
          : null,
    );
    if (!mounted) return;
    if (service.error == null && service.connected) {
      _token.clear();
      setState(() => _editing = false);
    }
  }

  @override
  void dispose() {
    _token.dispose();
    _address.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([widget.state, widget.state.documentImport]),
    builder: (context, _) {
      final service = widget.state.documentImport;
      final enabled =
          widget.state.isAuthenticated &&
          !widget.state.busy &&
          !service.working;
      final configured = !_loading && _server != null;
      final connected = service.connected && service.error == null && !_editing;
      return Column(
        key: const Key('paperless-import-panel'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_loading) const Text('Loading Paperless setup…'),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (kIsWeb && !configured && !_loading)
            TextButton(
              onPressed: _loadSettings,
              child: const Text('Retry Paperless setup'),
            ),
          if (kIsWeb && _server != null) Text('Paperless server: $_server'),
          if (connected) ...[
            const Text('Paperless connected.'),
            if (!kIsWeb && service.baseUrl != null)
              Text('Paperless address: ${service.baseUrl}'),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: enabled ? service.fetch : null,
                  child: const Text('Check now'),
                ),
                TextButton(
                  onPressed: enabled
                      ? () {
                          _address.text = service.baseUrl ?? _address.text;
                          setState(() => _editing = true);
                        }
                      : null,
                  child: const Text('Change API token'),
                ),
              ],
            ),
          ] else if (!kIsWeb || configured) ...[
            if (!kIsWeb) ...[
              const Text(
                'Connect to your Paperless library. Imported documents sync encrypted.',
              ),
              TextField(
                key: const Key('paperless-address'),
                controller: _address,
                enabled: enabled,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'Paperless address',
                  hintText: 'https://paperless.example.com',
                ),
              ),
            ],
            const Text(
              'An API token is an access key for your Paperless account. It lets Lifenizer read your document text. Keep it private, like a password.',
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: _openPaperless,
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open Paperless'),
            ),
            const Text(
              '1. Sign in to Paperless. Open the account menu at the top right → My Profile → API token.',
            ),
            const Text(
              '2. Copy the existing token. If there is none, create one with the circular-arrow button. Regenerating a token replaces the old one.',
            ),
            const Text('3. Paste the token below, then connect and import.'),
            TextField(
              key: const Key('paperless-token'),
              controller: _token,
              enabled: enabled,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Paperless API token',
              ),
            ),
            if (!kIsWeb)
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remember on this device'),
                subtitle: const Text(
                  'Saved in the OS credential store. Checks for updates every 5 minutes while unlocked.',
                ),
                value: _remember,
                onChanged: enabled
                    ? (value) => setState(() => _remember = value!)
                    : null,
              ),
            FilledButton(
              onPressed: enabled ? _connect : null,
              child: const Text('Connect & import'),
            ),
            if (_editing && service.connected && service.error == null)
              TextButton(
                onPressed: enabled
                    ? () {
                        _token.clear();
                        setState(() => _editing = false);
                      }
                    : null,
                child: const Text('Cancel token change'),
              ),
          ],
          if (service.connected || service.error != null)
            TextButton(
              onPressed: enabled ? service.removeAccount : null,
              child: const Text('Disconnect Paperless'),
            ),
          if (service.working || _loading) const LinearProgressIndicator(),
          if (service.status != null) Text(service.status!),
          if (service.error != null)
            Text(
              service.error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      );
    },
  );
}
