import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models.dart';
import 'discord_bot_gateway.dart';

/// Keeps bot credentials and channel cursors in the device's OS credential store.
class DiscordBotCredentialStore {
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(resetOnError: false),
  );
  String _key(String identity) =>
      'lifenizer.discord-bot.v1.${base64UrlEncode(utf8.encode(identity))}';
  Future<Map<String, dynamic>?> read(String identity) async {
    final value = await _storage.read(key: _key(identity));
    return value == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(value) as Map);
  }

  Future<void> write(String identity, Map<String, dynamic> value) =>
      _storage.write(key: _key(identity), value: jsonEncode(value));
  Future<void> remove(String identity) => _storage.delete(key: _key(identity));
}

/// Bot API normalization preserves Discord identifiers used by archive imports.
NormalizedImportResult normalizeDiscordBotMessages(
  Map<String, dynamic> channel,
  List<Map<String, dynamic>> messages, {
  String? ownUserId,
}) {
  final people = <String, NormalizedParticipant>{};
  final segments = <NormalizedSegment>[];
  for (final message in messages) {
    final author = message['author'];
    if (author is! Map || !RegExp(r'^\d+$').hasMatch('${author['id']}')) {
      continue;
    }
    final id = '${author['id']}';
    final identifier = message['webhook_id'] == null
        ? 'discord:$id'
        : 'discord-webhook:$id';
    final name =
        '${message['member']?['nick'] ?? author['global_name'] ?? author['username'] ?? id}';
    people[identifier] = NormalizedParticipant(
      displayName: name,
      identifiers: [identifier],
      aliases: [if (author['username'] != null) '${author['username']}'],
    );
    segments.add(
      NormalizedSegment(
        text: message['content'] as String? ?? '',
        participantName: name,
        participantIdentifier: identifier,
        sourceMessageId: '${message['id']}',
        createdAt: DateTime.tryParse('${message['timestamp']}'),
        attachmentUrls: [
          for (final attachment in message['attachments'] as List? ?? const [])
            if (attachment is Map && attachment['url'] is String)
              attachment['url'] as String,
        ],
      ),
    );
  }
  segments.sort(
    (a, b) => BigInt.parse(
      a.sourceMessageId!,
    ).compareTo(BigInt.parse(b.sourceMessageId!)),
  );
  final id = '${channel['id']}';
  final guild = '${channel['guild_id'] ?? '@me'}';
  return NormalizedImportResult(
    source: 'discord',
    plaintextCompute: false,
    message: 'Discord bot messages normalized locally.',
    conversations: segments.isEmpty
        ? []
        : [
            NormalizedConversation(
              title: '${channel['name'] ?? 'Discord channel $id'}',
              source: 'discord',
              sourceThreadId: 'discord:$id',
              sourceUrl: 'https://discord.com/channels/$guild/$id',
              participantNames: people.values
                  .map((p) => p.displayName)
                  .toList(),
              participantIdentifiers: people.keys.toList(),
              metadata: {
                'messageScope': 'bot-visible-messages',
                'channelType': '${channel['type'] ?? 0}',
                if (ownUserId != null && ownUserId.isNotEmpty)
                  'ownDiscordId': ownUserId,
              },
              segments: segments,
            ),
          ],
    participants: people.values.toList(),
  );
}

class DiscordBotImportService extends ChangeNotifier {
  DiscordBotImportService({
    required this.ingest,
    this.liveUpdates = true,
    DiscordBotCredentialStore? store,
    http.Client? client,
  }) : _store = store ?? DiscordBotCredentialStore(),
       _client = client ?? http.Client();

  /// Return true only after records have been saved in the unlocked encrypted vault.
  final Future<bool> Function(NormalizedImportResult) ingest;
  final bool liveUpdates;
  final DiscordBotCredentialStore _store;
  final http.Client _client;
  String? _identity;
  Map<String, dynamic>? _account;
  final Map<String, Map<String, dynamic>> _channels = {};
  DiscordBotGateway? _gateway;
  Timer? _timer;
  Timer? _liveFlush;
  Future<void>? _running;
  final Map<String, Map<String, dynamic>> _pendingLive = {};
  int _generation = 0;
  bool _disposed = false;
  bool _connecting = false;
  String? status;
  String? error;
  bool get connected => _account != null;
  bool get working => _connecting || _running != null;
  List<String> get channelIds =>
      (_account?['channels'] as List? ?? []).cast<String>();
  void _notify() {
    if (!_disposed) notifyListeners();
  }

  bool _current(int generation) =>
      !_disposed && _identity != null && _generation == generation;

  /// Root calls this with a stable per-user identity on unlock, null on lock/logout.
  void setIdentity(String? identity) {
    if (_identity == identity || _disposed) return;
    final generation = ++_generation;
    _identity = identity;
    _account = null;
    _channels.clear();
    _pendingLive.clear();
    _timer?.cancel();
    _liveFlush?.cancel();
    _liveFlush = null;
    unawaited(_gateway?.close());
    _gateway = null;
    status = null;
    error = null;
    _notify();
    if (identity != null && !kIsWeb) unawaited(_restore(identity, generation));
  }

  Future<void> _restore(String identity, int generation) async {
    try {
      final account = await _store.read(identity);
      if (!_current(generation) || account == null) return;
      _account = account;
      _start(generation);
      await fetch();
    } catch (_) {
      if (_current(generation)) {
        error =
            'Could not restore the Discord bot from the OS credential store.';
        _notify();
      }
    }
  }

  Future<dynamic> _get(String path, int generation) async {
    for (var attempt = 0; attempt < 6; attempt++) {
      if (!_current(generation) || _account == null) {
        throw StateError('Discord import paused.');
      }
      final response = await _client
          .get(
            Uri.parse('https://discord.com/api/v10$path'),
            headers: {
              'Authorization': 'Bot ${_account!['token']}',
              'User-Agent':
                  'Lifenizer (https://mail.coflnet.com/lifenizer, 1.0)',
            },
          )
          .timeout(const Duration(seconds: 30));
      if (!_current(generation)) throw StateError('Discord import paused.');
      if (response.statusCode == 429) {
        final retry = jsonDecode(response.body) as Map;
        await Future<void>.delayed(
          Duration(
            milliseconds: ((retry['retry_after'] as num).toDouble() * 1000)
                .ceil(),
          ),
        );
        continue;
      }
      if (response.statusCode != 200) {
        throw _DiscordApiError(response.statusCode);
      }
      return jsonDecode(response.body);
    }
    throw StateError('Discord rate limit is still active. Import will retry.');
  }

  Future<void> connect({
    required String token,
    required List<String> channels,
    String guildId = '',
    String ownUserId = '',
    bool remember = true,
  }) async {
    if (working || _identity == null) return;
    if (kIsWeb) {
      error = 'Discord bot import requires the native app.';
      _notify();
      return;
    }
    final ids = channels
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toSet()
        .toList();
    if (token.trim().isEmpty ||
        (ids.isEmpty && !RegExp(r'^\d+$').hasMatch(guildId)) ||
        ids.any((e) => !RegExp(r'^\d+$').hasMatch(e)) ||
        (ownUserId.isNotEmpty && !RegExp(r'^\d+$').hasMatch(ownUserId))) {
      error =
          'Enter a bot token and numeric channel IDs; your own Discord ID is optional.';
      _notify();
      return;
    }
    _connecting = true;
    final generation = ++_generation;
    final identity = _identity!;
    final old = _account;
    final explicit = ids.toSet();
    await _gateway?.close();
    _account = {
      'token': token.trim().replaceFirst(
        RegExp(r'^Bot\s+', caseSensitive: false),
        '',
      ),
      'channels': ids,
      'ownUserId': ownUserId,
      'remember': remember,
      'cursors': <String, dynamic>{},
    };
    try {
      final bot = await _get('/users/@me', generation) as Map;
      if (bot['bot'] != true) {
        throw StateError(
          'Use a Discord bot token from the Developer Portal. Personal account tokens are unsupported.',
        );
      }
      if (guildId.isNotEmpty) {
        final discovered =
            await _get('/guilds/$guildId/channels', generation) as List;
        ids.addAll(
          discovered
              .whereType<Map>()
              .where((c) => [0, 5].contains(c['type']))
              .map((c) => '${c['id']}')
              .where((id) => !ids.contains(id)),
        );
        if (ids.isEmpty) {
          throw StateError(
            'The server has no text channels. Enter a channel or thread ID.',
          );
        }
      }
      for (final id in ids.toList()) {
        try {
          final channel = Map<String, dynamic>.from(
            await _get('/channels/$id', generation) as Map,
          );
          if (channel['guild_id'] == null) {
            throw StateError(
              'Select server channels or threads accessible to the bot. Bots cannot read your personal DM conversations.',
            );
          }
          if (!explicit.contains(id)) {
            await _get('/channels/$id/messages?limit=1', generation);
          }
          if (!_current(generation)) return;
          _channels[id] = channel;
        } on _DiscordApiError catch (exception) {
          if (explicit.contains(id) || ![403, 404].contains(exception.code)) {
            rethrow;
          }
          ids.remove(id);
        }
      }
      if (ids.isEmpty) {
        throw StateError(
          'The bot cannot read any text channels in this server. Grant View Channel and Read Message History, or enter authorized channel IDs.',
        );
      }
      if (!_current(generation)) return;
      if (remember) {
        await _store.write(identity, _account!);
      } else {
        await _store.remove(identity);
      }
      if (!_current(generation)) return;
      error = null;
      _start(generation);
    } catch (exception) {
      if (_current(generation)) {
        _account = old;
        error = exception.toString();
        if (old != null) _start(generation);
      }
    } finally {
      _connecting = false;
      _notify();
    }
    if (_current(generation) && error == null) await fetch();
  }

  void _start(int generation) {
    _timer?.cancel();
    _liveFlush?.cancel();
    _liveFlush = null;
    _timer = Timer.periodic(
      const Duration(minutes: 5),
      (_) => unawaited(fetch()),
    );
    if (!liveUpdates) return;
    _gateway = DiscordBotGateway(
      token: _account!['token'] as String,
      onStatus: (value) {
        if (_current(generation)) {
          status = value;
          _notify();
        }
      },
      onEvent: (type, message) {
        if (!_current(generation)) return;
        // REST reconciliation gives complete author fields for partial UPDATE events.
        if ((type == 'MESSAGE_CREATE' || type == 'MESSAGE_UPDATE') &&
            channelIds.contains('${message['channel_id']}')) {
          queueLiveMessage(message, partial: type == 'MESSAGE_UPDATE');
        }
        if (type == 'READY' || type == 'RESUMED') unawaited(fetch());
      },
    );
    unawaited(_gateway!.start());
  }

  /// Coalesces bursts before encrypted snapshot writes. Partial updates use REST.
  void queueLiveMessage(Map<String, dynamic> message, {bool partial = false}) {
    final generation = _generation;
    if (!_current(generation) ||
        !channelIds.contains('${message['channel_id']}')) {
      return;
    }
    final key = '${message['channel_id']}:${message['id']}';
    if (_pendingLive.length >= 200 && !_pendingLive.containsKey(key)) {
      error =
          'Discord live queue exceeded 200 messages. New messages will be recovered by history checking; an overflowing edit may require reimporting that channel.';
      _notify();
      return;
    }
    _pendingLive[key] = {...message, '_partial': partial};
    _liveFlush ??= Timer(const Duration(seconds: 2), () {
      _liveFlush = null;
      unawaited(_drainLive(generation));
    });
  }

  Future<void> _drainLive(int generation) async {
    if (_running != null || !_current(generation) || _pendingLive.isEmpty) {
      return;
    }
    _running = _ingestPendingLive(generation);
    await _running;
    _running = null;
    _notify();
    if (_current(generation) && _pendingLive.isNotEmpty) {
      _liveFlush ??= Timer(Duration(seconds: error == null ? 2 : 30), () {
        _liveFlush = null;
        unawaited(_drainLive(generation));
      });
    }
  }

  /// Called only by the current serialized operation, including between pages.
  Future<void> _ingestPendingLive(int generation) async {
    for (
      var batchIndex = 0;
      batchIndex < 2 && _current(generation) && _pendingLive.isNotEmpty;
      batchIndex++
    ) {
      final id = '${_pendingLive.values.first['channel_id']}';
      final batch = Map<String, Map<String, dynamic>>.fromEntries(
        _pendingLive.entries
            .where((e) => '${e.value['channel_id']}' == id)
            .take(100),
      );
      try {
        final channel = _channels[id] ??= Map<String, dynamic>.from(
          await _get('/channels/$id', generation) as Map,
        );
        final messages = <Map<String, dynamic>>[];
        for (final entry in batch.entries) {
          final message = entry.value;
          try {
            messages.add(
              message['_partial'] == true
                  ? Map<String, dynamic>.from(
                      await _get(
                            '/channels/$id/messages/${message['id']}',
                            generation,
                          )
                          as Map,
                    )
                  : message,
            );
          } on _DiscordApiError catch (exception) {
            if (exception.code != 404) rethrow;
            // A deleted message has no body to update. Preserve stored history.
            if (identical(_pendingLive[entry.key], entry.value)) {
              _pendingLive.remove(entry.key);
            }
          }
        }
        if (!_current(generation)) return;
        if (messages.isNotEmpty &&
            !await ingest(
              normalizeDiscordBotMessages(
                channel,
                messages,
                ownUserId: _account!['ownUserId'] as String?,
              ),
            )) {
          status = 'Live import waiting for the vault.';
          return;
        }
        if (!_current(generation)) return;
        for (final entry in batch.entries) {
          if (identical(_pendingLive[entry.key], entry.value)) {
            _pendingLive.remove(entry.key);
          }
        }
      } catch (exception) {
        if (_current(generation)) {
          error = 'Live Discord batch retained for retry: $exception';
        }
        return;
      }
    }
  }

  Future<void> fetch() {
    if (_running != null) return _running!;
    if (_identity == null || _account == null || _connecting) {
      return Future.value();
    }
    _running = _fetch(_generation).whenComplete(() {
      _running = null;
      _notify();
      unawaited(_drainLive(_generation));
    });
    _notify();
    return _running!;
  }

  Future<void> _fetch(int generation) async {
    try {
      error = null;
      for (final id in channelIds) {
        if (!_current(generation)) return;
        final channel = _channels[id] ??= Map<String, dynamic>.from(
          await _get('/channels/$id', generation) as Map,
        );
        final cursors = _account!['cursors'] as Map;
        final cursor = Map<String, dynamic>.from(cursors[id] as Map? ?? {});
        // Work is bounded per check; incomplete historical backfill resumes safely.
        for (var page = 0; page < 20 && _current(generation); page++) {
          final history = cursor['historyComplete'] != true;
          final query = history
              ? (cursor['before'] == null ? '' : '&before=${cursor['before']}')
              : (cursor['latest'] == null ? '' : '&after=${cursor['latest']}');
          status = 'Reading Discord channel $id · page ${page + 1}…';
          _notify();
          final raw =
              await _get('/channels/$id/messages?limit=100$query', generation)
                  as List;
          final messages =
              raw.map((e) => Map<String, dynamic>.from(e as Map)).toList()
                ..sort(
                  (a, b) => BigInt.parse(
                    '${a['id']}',
                  ).compareTo(BigInt.parse('${b['id']}')),
                );
          if (!_current(generation)) return;
          if (messages.isNotEmpty &&
              !await ingest(
                normalizeDiscordBotMessages(
                  channel,
                  messages,
                  ownUserId: _account!['ownUserId'] as String?,
                ),
              )) {
            status =
                'Discord import waiting for the vault. Retry with Check now.';
            return;
          }
          if (!_current(generation)) return;
          if (messages.isNotEmpty) {
            final newest = '${messages.last['id']}';
            if (cursor['latest'] == null ||
                BigInt.parse(newest) > BigInt.parse('${cursor['latest']}')) {
              cursor['latest'] = newest;
            }
            if (history) cursor['before'] = '${messages.first['id']}';
          }
          if (history && messages.length < 100) {
            cursor['historyComplete'] = true;
          }
          cursors[id] = cursor;
          if (_account!['remember'] == true) {
            await _store.write(_identity!, _account!);
          }
          if (_liveFlush == null && _pendingLive.isNotEmpty) {
            await _ingestPendingLive(generation);
          }
          if (messages.length < 100) break;
        }
      }
      if (_current(generation)) {
        status =
            'Discord messages saved encrypted. Live updates active; history and missed messages checked every 5 minutes while unlocked.';
      }
    } catch (exception) {
      if (_current(generation)) error = exception.toString();
    }
  }

  /// Rechecks existing IDs too, so edits made while offline can be imported.
  Future<void> reimportHistory() async {
    if (working || _account == null || _identity == null) return;
    final generation = _generation;
    _account!['cursors'] = <String, dynamic>{};
    try {
      if (_account!['remember'] == true) {
        await _store.write(_identity!, _account!);
      }
      if (_current(generation)) await fetch();
    } catch (_) {
      if (_current(generation)) {
        error = 'Could not save the Discord history reset. Retry reimport.';
      }
      _notify();
    }
  }

  Future<void> removeAccount() async {
    final identity = _identity;
    _generation++;
    _timer?.cancel();
    _liveFlush?.cancel();
    _liveFlush = null;
    _account = null;
    _pendingLive.clear();
    await _gateway?.close();
    _gateway = null;
    await _running;
    try {
      if (identity != null) await _store.remove(identity);
      status =
          'Discord import stopped. Imported conversations remain in your vault.';
      error = null;
    } catch (_) {
      error =
          'Could not remove the saved Discord token from the OS credential store. Retry removal.';
    }
    _notify();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _timer?.cancel();
    _liveFlush?.cancel();
    _liveFlush = null;
    unawaited(_gateway?.close());
    _account = null;
    _client.close();
    super.dispose();
  }
}

class _DiscordApiError extends StateError {
  _DiscordApiError(this.code)
    : super(
        'Discord API $code. Check the bot token, View Channel, Read Message History, and Message Content Intent.',
      );
  final int code;
}
