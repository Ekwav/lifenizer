import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../app_state.dart';

Future<void> showDeviceSecurityDialog(
  BuildContext context,
  LifenizerAppState state,
) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => DeviceSecurityDialog(state: state),
);

Future<String?> requestDevicePassword(BuildContext context) =>
    showDialog<String>(
      context: context,
      builder: (_) => const _DevicePasswordDialog(),
    );

class DeviceSecurityDialog extends StatefulWidget {
  const DeviceSecurityDialog({required this.state, super.key});
  final LifenizerAppState state;

  @override
  State<DeviceSecurityDialog> createState() => _DeviceSecurityDialogState();
}

class _DeviceSecurityDialogState extends State<DeviceSecurityDialog> {
  final _password = TextEditingController();
  final _confirmation = TextEditingController();
  final _currentPassword = TextEditingController();
  late bool _enabled = widget.state.pairing.higherSecurity;
  bool _saving = false;
  String? _error;

  bool get _android => defaultTargetPlatform == TargetPlatform.android;

  @override
  void dispose() {
    _password.dispose();
    _confirmation.dispose();
    _currentPassword.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    final pairing = widget.state.pairing;
    if (_enabled && !_android) {
      if (_password.text.length < 12) {
        setState(
          () => _error = 'Use a device password of at least 12 characters.',
        );
        return;
      }
      if (_password.text != _confirmation.text) {
        setState(() => _error = 'The device passwords do not match.');
        return;
      }
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final saving = pairing.enableProtection(
      _enabled ? (_android ? 'biometric' : 'password') : 'system',
      password: _enabled && !_android ? _password.text : null,
      currentPassword: !_enabled && pairing.protectionMode == 'password'
          ? _currentPassword.text
          : null,
    );
    _password.clear();
    _confirmation.clear();
    _currentPassword.clear();
    final saved = await saving;
    if (!mounted) return;
    if (saved) {
      Navigator.of(context).pop();
    } else {
      setState(() {
        _saving = false;
        _error =
            pairing.error ?? 'Device security could not be changed. Retry.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pairing = widget.state.pairing;
    final changing = _enabled != pairing.higherSecurity;
    return PopScope(
      canPop: !_saving,
      child: AlertDialog(
        title: const Text('Device security'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'By default, this device unlocks from Android secure storage or KDE Wallet without an app password. Your vault is encrypted locally and during sync. Server imports and processing can read the content you submit; original source files keep their own protection.',
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  _android
                      ? 'Fingerprint or phone PIN'
                      : 'Require a device password',
                ),
                subtitle: const Text('Ask each time this app unlocks.'),
                value: _enabled,
                onChanged: _saving
                    ? null
                    : (value) => setState(() {
                        _enabled = value;
                        _error = null;
                      }),
              ),
              if (changing && _enabled && !_android) ...[
                TextField(
                  controller: _password,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Device password',
                    helperText:
                        'At least 12 characters. Keep it in your password manager.',
                  ),
                ),
                TextField(
                  controller: _confirmation,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Repeat device password',
                  ),
                ),
              ],
              if (changing && !_enabled && pairing.protectionMode == 'password')
                TextField(
                  controller: _currentPassword,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_saving,
                  decoration: const InputDecoration(
                    labelText: 'Current device password',
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (_saving) const LinearProgressIndicator(),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: _saving || !changing ? null : _save,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }
}

class _DevicePasswordDialog extends StatefulWidget {
  const _DevicePasswordDialog();

  @override
  State<_DevicePasswordDialog> createState() => _DevicePasswordDialogState();
}

class _DevicePasswordDialogState extends State<_DevicePasswordDialog> {
  final _password = TextEditingController();

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  void _unlock() {
    final password = _password.text;
    _password.clear();
    Navigator.of(context).pop(password);
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Unlock this device'),
    content: TextField(
      controller: _password,
      autofocus: true,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      decoration: const InputDecoration(labelText: 'Device password'),
      onSubmitted: (_) => _unlock(),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      FilledButton(onPressed: _unlock, child: const Text('Unlock')),
    ],
  );
}
