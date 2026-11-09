import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../services/browser_extension_receiver_service.dart';
import '../services/source_links.dart';

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
  bool _working = false;
  late final TextEditingController _port = TextEditingController();

  BrowserExtensionReceiverService get _service => widget.service;

  @override
  void dispose() {
    _port.dispose();
    super.dispose();
  }

  Future<void> _guard(Future<void> Function() action) async {
    setState(() {
      _localError = null;
      _working = true;
    });
    try {
      await action();
    } catch (exception) {
      if (mounted) setState(() => _localError = '$exception');
    } finally {
      if (mounted) setState(() => _working = false);
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
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _service,
    builder: (context, _) => _build(context),
  );

  Widget _build(BuildContext context) {
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
          'Connect the extension on this computer to import watch history and '
          'new WhatsApp Web or Discord Web messages. Keep this vault unlocked '
          'while importing.',
          style: muted,
        ),
        SwitchListTile(
          key: const Key('browser-extension-enabled'),
          contentPadding: EdgeInsets.zero,
          title: const Text(
            'Accept history and messages from the browser extension',
          ),
          value: _service.enabled,
          onChanged: widget.signedIn && !_working
              ? (value) => _guard(() => _service.setEnabled(value))
              : null,
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              key: const Key('browser-extension-connect'),
              onPressed: widget.signedIn && !_working
                  ? () => _guard(() async {
                      final link = await _service.createPairingLink();
                      if (!await openExternalLink(link)) {
                        throw StateError(
                          'Could not open the browser. Scan the QR code or copy its connection link instead.',
                        );
                      }
                    })
                  : null,
              icon: const Icon(Icons.open_in_browser),
              label: const Text('Connect browser'),
            ),
            OutlinedButton.icon(
              key: const Key('browser-extension-qr'),
              onPressed: widget.signedIn && !_working
                  ? () => _guard(() async {
                      await _service.createPairingLink();
                    })
                  : null,
              icon: const Icon(Icons.qr_code),
              label: const Text('Show QR code'),
            ),
          ],
        ),
        if (_service.pairingLink case final String link) ...[
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: QrImageView(
                  key: const Key('browser-extension-pairing-qr'),
                  data: link,
                  size: 196,
                  backgroundColor: Colors.white,
                  semanticsLabel: 'One-time browser connection QR code',
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'In the extension, choose Connect → Scan QR code. Select this app '
            'window to scan its screen, or use your camera. The code works once '
            'and expires after 2 minutes. Keep it private.',
          ),
          TextButton.icon(
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: link));
              if (!context.mounted) return;
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(content: Text('Connection link copied')),
              );
            },
            icon: const Icon(Icons.copy),
            label: const Text('Copy connection link'),
          ),
        ],
        ExpansionTile(
          tilePadding: EdgeInsets.zero,
          title: const Text('Advanced connection settings'),
          children: [
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
                  onPressed: widget.signedIn && !_working ? _applyPort : null,
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
                    onPressed: widget.signedIn && !_working
                        ? () => _guard(_service.regenerateToken)
                        : null,
                  ),
                ],
              ),
            ],
          ],
        ),
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
