import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/browser_extension_receiver_service.dart';

/// "Browser extension" section of the Viewing history panel (desktop only).
class BrowserExtensionSection extends StatefulWidget {
  const BrowserExtensionSection({
    required this.service,
    required this.signedIn,
    super.key,
  });
  final BrowserExtensionReceiverService service;
  final bool signedIn;

  @override
  State<BrowserExtensionSection> createState() =>
      _BrowserExtensionSectionState();
}

class _BrowserExtensionSectionState extends State<BrowserExtensionSection> {
  String? _localError;
  late final TextEditingController _port = TextEditingController();

  BrowserExtensionReceiverService get _service => widget.service;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() => _localError = null);
    try {
      await action();
    } catch (exception) {
      if (mounted) setState(() => _localError = '$exception');
    }
  }

  Future<void> _applyPort() => _guard(() async {
    final value = int.tryParse(_port.text.trim());
    if (value == null) {
      throw const FormatException('Enter a port between 1 and 65535.');
    }
    await _service.setPort(value);
  });

  @override
  Widget build(BuildContext context) {
    if (!_service.supported) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (_port.text.isEmpty) _port.text = '${_service.port}';
    final token = _service.token;
    return Column(
      key: const Key('browser-extension-section'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Divider(height: 28),
        Text('Browser extension', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          'The Lifenizer browser extension can send your YouTube and TikTok '
          'watch history and new messages from WhatsApp Web and Discord Web to this app. '
          'The app listens on 127.0.0.1 only '
          '(this computer) and requires the token below. See '
          'integrations/browser-extension/README.md for installation.',
          style: muted,
        ),
        SwitchListTile(
          key: const Key('browser-extension-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Accept history and messages from the browser extension',
          ),
          value: _service.enabled,
          onChanged: widget.signedIn
              ? (value) => _guard(() => _service.setEnabled(value))
              : null,
        ),
        Row(
          children: [
            SizedBox(
              width: 120,
              child: TextField(
                key: const Key('browser-extension-port'),
                controller: _port,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Port',
                  isDense: true,
                ),
                onSubmitted: (_) => _applyPort(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              key: const Key('browser-extension-apply-port'),
              onPressed: widget.signedIn ? _applyPort : null,
              child: const Text('Set port'),
            ),
          ],
        ),
        if (token != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: SelectableText(
                  token,
                  key: const Key('browser-extension-token'),
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
              IconButton(
                key: const Key('browser-extension-copy'),
                tooltip: 'Copy token',
                icon: const Icon(Icons.copy),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: token));
                  if (!context.mounted) return;
                  ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                    const SnackBar(content: Text('Token copied')),
                  );
                },
              ),
              IconButton(
                key: const Key('browser-extension-regenerate'),
                tooltip: 'Generate a new token (the old one stops working)',
                icon: const Icon(Icons.refresh),
                onPressed: widget.signedIn
                    ? () => _guard(_service.regenerateToken)
                    : null,
              ),
            ],
          ),
        ],
        if (_service.enabled)
          Text(
            _service.listening
                ? 'Listening on 127.0.0.1:${_service.port}'
                : 'Not listening.',
            key: const Key('browser-extension-status'),
            style: muted,
          ),
        if (_service.lastSync != null)
          Text(
            'Last sync ${_service.lastSync!.toLocal().toString().split('.').first} · '
            '${_service.visitsAccepted} visit(s) received · '
            '${_service.videosImported} video(s) imported',
            key: const Key('browser-extension-counters'),
            style: muted,
          ),
        for (final message in [?_service.error, ?_localError])
          Text(
            message,
            key: const Key('browser-extension-error'),
            style: TextStyle(color: theme.colorScheme.error),
          ),
      ],
    );
  }
}
