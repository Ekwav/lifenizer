import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/discord_bot_import_service.dart';

class DiscordBotImportPanel extends StatefulWidget {
  const DiscordBotImportPanel({
    required this.service,
    this.ownUserId = '',
    super.key,
  });
  final DiscordBotImportService service;
  final String ownUserId;
  @override
  State<DiscordBotImportPanel> createState() => _DiscordBotImportPanelState();
}

class _DiscordBotImportPanelState extends State<DiscordBotImportPanel> {
  final _token = TextEditingController();
  final _channels = TextEditingController();
  final _guild = TextEditingController();
  late final _own = TextEditingController(text: widget.ownUserId);
  bool _remember = true;
  @override
  void dispose() {
    _token.dispose();
    _channels.dispose();
    _guild.dispose();
    _own.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final token = _token.text;
    _token.clear();
    await widget.service.connect(
      token: token,
      channels: _channels.text.split(RegExp(r'[\s,]+')),
      guildId: _guild.text.trim(),
      ownUserId: _own.text.trim(),
      remember: _remember,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.service,
    builder: (context, _) {
      final service = widget.service;
      final enabled = !kIsWeb && !service.working;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Discord bot: history & live messages',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const Text(
            'Create a bot in the Discord Developer Portal and enable Message Content Intent. Invite it with View Channel and Read Message History permissions. It reads only server channels and threads the bot can access. Your personal DMs require a Discord data export.',
          ),
          if (kIsWeb)
            const Text(
              'Use the desktop or Android app for Discord bot imports.',
            ),
          TextField(
            controller: _token,
            enabled: enabled,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'Bot token'),
          ),
          TextField(
            controller: _channels,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Channel or thread IDs (comma separated)',
            ),
          ),
          TextField(
            controller: _guild,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Server ID (optional: discover text channels)',
            ),
          ),
          TextField(
            controller: _own,
            enabled: enabled,
            decoration: const InputDecoration(
              labelText: 'Your Discord user ID (ekwav)',
              helperText:
                  'Real authors and replies are indexed; this identifies your side of conversations.',
            ),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Remember on this device'),
            subtitle: const Text(
              'Token and resume cursors are stored in the OS credential store. Import runs while this app is open and the vault is unlocked.',
            ),
            value: _remember,
            onChanged: enabled ? (v) => setState(() => _remember = v!) : null,
          ),
          Wrap(
            spacing: 8,
            children: [
              FilledButton(
                onPressed: enabled ? _connect : null,
                child: const Text('Connect & import history'),
              ),
              if (service.connected)
                OutlinedButton(
                  onPressed: enabled ? service.fetch : null,
                  child: const Text('Check now'),
                ),
              if (service.connected)
                OutlinedButton(
                  onPressed: enabled ? service.reimportHistory : null,
                  child: const Text('Reimport history & offline edits'),
                ),
              if (service.connected || service.error != null)
                TextButton(
                  onPressed: service.removeAccount,
                  child: const Text('Stop & remove bot'),
                ),
            ],
          ),
          if (service.working) const LinearProgressIndicator(),
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
