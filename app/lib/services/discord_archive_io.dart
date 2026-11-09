import 'dart:convert';

import 'package:archive/archive.dart';

import '../models.dart';

final _messagePath = RegExp(
  r'^(?:[^/]+/)?(?:messages|nachrichten)/([^/]+)/messages\.json$',
  caseSensitive: false,
);

Future<bool> isDiscordArchive(String path) async {
  final input = InputFileStream(path);
  try {
    final directory = ZipDirectory()..read(input);
    return directory.fileHeaders.any((e) => _messagePath.hasMatch(e.filename));
  } finally {
    await input.close();
  }
}

/// Only selected JSON is inflated. Activity, media and other package files stay
/// compressed on disk; no plaintext extraction directory is created.
Stream<NormalizedImportResult> readDiscordArchive(
  String path, {
  void Function(int channels, int total, int messages)? onProgress,
  int maxEntryBytes = 8 * 1024 * 1024,
  int maxSelectedBytes = 256 * 1024 * 1024,
}) async* {
  final input = InputFileStream(path);
  try {
    final directory = ZipDirectory()..read(input);
    final files = {for (final e in directory.fileHeaders) e.filename: e};
    final messageFiles = directory.fileHeaders
        .where((e) => _messagePath.hasMatch(e.filename))
        .toList();
    if (messageFiles.isEmpty) {
      throw const FormatException(
        'This ZIP is not a Discord data package. Choose the source for other ZIP exports.',
      );
    }
    var selectedBytes = 0;
    Object? readJson(ZipFileHeader entry) {
      if (entry.uncompressedSize > maxEntryBytes ||
          entry.compressedSize > maxEntryBytes ||
          selectedBytes + entry.uncompressedSize > maxSelectedBytes) {
        throw const FormatException(
          'Selected Discord JSON exceeds the import limit. Split the exported message folders into smaller ZIPs.',
        );
      }
      if ((entry.generalPurposeBitFlag & 1) != 0 ||
          ((entry.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const FormatException(
          'Encrypted or linked Discord JSON entries cannot be imported. Use an original Discord data package.',
        );
      }
      final output = _BoundedOutput(maxEntryBytes);
      final compressed = entry.file!.getStream(decompress: false);
      if (entry.compressionMethod == 8) {
        const ZLibDecoderWeb().decodeStream(compressed, output, raw: true);
      } else if (entry.compressionMethod == 0) {
        output.writeStream(compressed);
      } else {
        throw const FormatException(
          'Unsupported Discord ZIP compression. Re-export or create a standard ZIP.',
        );
      }
      final bytes = output.getBytes();
      selectedBytes += bytes.length;
      if (bytes.length != entry.uncompressedSize ||
          getCrc32(bytes) != entry.crc32 ||
          selectedBytes > maxSelectedBytes) {
        throw const FormatException(
          'A selected Discord JSON file is damaged or exceeds the import limit. Download the data package again.',
        );
      }
      try {
        return jsonDecode(utf8.decode(bytes));
      } on FormatException {
        throw const FormatException(
          'A selected Discord file is not valid JSON. Use the original Discord data package.',
        );
      }
    }

    final accountFile = directory.fileHeaders
        .where(
          (e) => RegExp(
            r'^(?:[^/]+/)?(?:account|konto)/user\.json$',
            caseSensitive: false,
          ).hasMatch(e.filename),
        )
        .firstOrNull;
    if (accountFile == null) {
      throw const FormatException(
        'The Discord package needs Account/user.json to identify the author of your messages.',
      );
    }
    final account = readJson(accountFile);
    if (account is! Map) {
      throw const FormatException('The Discord account profile is invalid.');
    }
    final ownId = _id(account['id']);
    final people = <String, NormalizedParticipant>{ownId: _person(account)};
    if (account['relationships'] is List) {
      for (final relationship in account['relationships']) {
        if (relationship is Map && relationship['user'] is Map) {
          final user = relationship['user'] as Map;
          if (user['id'] != null) {
            people[_id(user['id'])] = _person(
              user,
              alias: relationship['nickname'] as String?,
            );
          }
        }
      }
    }

    final indexFile = directory.fileHeaders
        .where(
          (e) => RegExp(
            r'^(?:[^/]+/)?(?:messages|nachrichten)/index\.json$',
            caseSensitive: false,
          ).hasMatch(e.filename),
        )
        .firstOrNull;
    final channelIndex = indexFile == null ? null : readJson(indexFile);
    var conversations = <NormalizedConversation>[];
    var participants = <String, NormalizedParticipant>{};
    var batchBytes = 0;
    var messageCount = 0;
    for (var index = 0; index < messageFiles.length; index++) {
      final entry = messageFiles[index];
      final folder = entry.filename.substring(
        0,
        entry.filename.lastIndexOf('/'),
      );
      final channelFile = files['$folder/channel.json'];
      if (channelFile == null) {
        throw const FormatException(
          'A Discord message folder is missing channel.json. Use the complete export.',
        );
      }
      final channel = readJson(channelFile);
      final messages = readJson(entry);
      if (channel is! Map || messages is! List) {
        throw const FormatException(
          'Discord channel metadata or messages have an unsupported shape.',
        );
      }
      final channelId = _id(channel['id']);
      final guild = channel['guild'];
      final guildId = guild is Map && guild['id'] != null
          ? _id(guild['id'])
          : null;
      final guildName = guild is Map ? guild['name'] as String? : null;
      final channelType = channel['type'] as String? ?? 'Channel';
      final sourceUrl = guildId != null
          ? 'https://discord.com/channels/$guildId/$channelId'
          : ['DM', 'GROUP_DM'].contains(channelType)
          ? 'https://discord.com/channels/@me/$channelId'
          : null;
      final memberIds = <String>{ownId};
      var unidentifiedRecipients = 0;
      if (channel['recipients'] is List) {
        for (final recipient in channel['recipients']) {
          if (recipient == 'Deleted User') {
            unidentifiedRecipients++;
            continue;
          }
          final id = _id(recipient is Map ? recipient['id'] : recipient);
          if (recipient is Map) people[id] = _person(recipient);
          memberIds.add(id);
        }
      }
      final indexLabel = channelIndex is Map
          ? channelIndex[channelId] as String?
          : null;
      final otherIds = memberIds.where((id) => id != ownId).toList();
      if (channel['type'] == 'DM' &&
          otherIds.length == 1 &&
          !people.containsKey(otherIds.single) &&
          indexLabel != null) {
        final label = indexLabel
            .replaceFirst(
              RegExp(
                r'^Direct Message (?:with|with:|-)\s*',
                caseSensitive: false,
              ),
              '',
            )
            .trim();
        if (label.isNotEmpty && label != indexLabel) {
          people[otherIds.single] = NormalizedParticipant(
            displayName: label,
            identifiers: ['discord:${otherIds.single}'],
          );
        }
      }
      final segments = <NormalizedSegment>[];
      for (final message in messages) {
        if (message is! Map) {
          throw const FormatException('Discord messages must be JSON objects.');
        }
        final id = _id(message['ID']);
        final text = message['Contents'] as String? ?? '';
        final attachments = (message['Attachments'] as String? ?? '')
            .split(RegExp(r'\s+'))
            .where((s) => ['http', 'https'].contains(Uri.tryParse(s)?.scheme))
            .toList();
        final timestamp = message['Timestamp'] as String?;
        final createdAt = timestamp == null
            ? null
            : DateTime.tryParse(
                RegExp(
                      r'(Z|[+-]\d{2}:?\d{2})$',
                      caseSensitive: false,
                    ).hasMatch(timestamp)
                    ? timestamp
                    : '${timestamp}Z',
              );
        if (createdAt == null) {
          throw const FormatException(
            'A Discord message has an invalid timestamp. Use the original data package.',
          );
        }
        segments.add(
          NormalizedSegment(
            text: text,
            participantName: people[ownId]!.displayName,
            participantIdentifier: 'discord:$ownId',
            sourceMessageId: 'discord:$id',
            attachmentUrls: attachments,
            createdAt: createdAt.toUtc(),
            offsetMs: 0,
          ),
        );
      }
      if (segments.isNotEmpty) {
        for (final id in memberIds) {
          participants[id] =
              people[id] ??
              NormalizedParticipant(
                displayName: 'Discord user $id',
                identifiers: ['discord:$id'],
              );
        }
        final name = channel['name'] as String?;
        final title = name?.trim().isNotEmpty == true
            ? name!.trim()
            : channel['type'] == 'DM' && otherIds.any(people.containsKey)
            ? 'DM · ${otherIds.map((id) => people[id]?.displayName ?? 'Discord user $id').join(', ')}'
            : indexLabel ?? '${channel['type'] ?? 'Channel'} $channelId';
        conversations.add(
          NormalizedConversation(
            title: guildName == null ? title : '$guildName · $title',
            source: 'discord',
            sourceThreadId: 'discord:$channelId',
            sourceUrl: sourceUrl,
            metadata: {
              'channelType': channelType,
              'messageScope': 'own-sent-messages',
              if (unidentifiedRecipients > 0)
                'unidentifiedRecipients': '$unidentifiedRecipients',
            },
            participantNames: [],
            participantIdentifiers: memberIds
                .map((id) => 'discord:$id')
                .toList(),
            segments: segments,
            artifactNames: [],
          ),
        );
        messageCount += segments.length;
        batchBytes += entry.uncompressedSize + channelFile.uncompressedSize;
      }
      if ((index + 1) % 25 == 0) {
        onProgress?.call(index + 1, messageFiles.length, messageCount);
        await Future<void>.delayed(Duration.zero);
      }
      if (conversations.length >= 500 ||
          batchBytes >= 4 * 1024 * 1024 ||
          index == messageFiles.length - 1) {
        if (conversations.isNotEmpty) {
          yield NormalizedImportResult(
            source: 'discord',
            plaintextCompute: false,
            message: 'Read Discord messages locally.',
            conversations: conversations,
            participants: participants.values.toList(),
          );
        }
        conversations = [];
        participants = {};
        batchBytes = 0;
      }
    }
    onProgress?.call(messageFiles.length, messageFiles.length, messageCount);
  } finally {
    await input.close();
  }
}

String _id(Object? value) {
  final id = value is int || value is String ? '$value' : '';
  if (!RegExp(r'^\d{1,20}$').hasMatch(id)) {
    throw const FormatException(
      'A Discord identifier is missing or invalid. Use the original data package.',
    );
  }
  return id;
}

NormalizedParticipant _person(Map user, {String? alias}) {
  final id = _id(user['id']);
  final username = user['username'] as String?;
  final globalName = user['global_name'] as String?;
  final email = user['email'] as String?;
  final discriminator = user['discriminator'] as String?;
  return NormalizedParticipant(
    displayName: globalName?.trim().isNotEmpty == true
        ? globalName!
        : username ?? 'Discord user $id',
    identifiers: [
      'discord:$id',
      if (email?.trim().isNotEmpty == true)
        'email:${email!.trim().toLowerCase()}',
    ],
    aliases: [
      if (alias?.trim().isNotEmpty == true) alias!.trim(),
      if (username?.trim().isNotEmpty == true) username!,
      if (username?.trim().isNotEmpty == true &&
          discriminator != null &&
          discriminator != '0')
        '$username#$discriminator',
      if (globalName?.trim().isNotEmpty == true) globalName!,
    ],
  );
}

/// Enforce the limit during inflation, including back-references; a forged
/// uncompressed size must never let a compressed JSON bomb allocate unbounded RAM.
class _BoundedOutput extends OutputMemoryStream {
  _BoundedOutput(this.limit);
  final int limit;
  void _check(int count) {
    if (length + count > limit) {
      throw const FormatException(
        'A Discord JSON entry expands beyond the import limit.',
      );
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }

  @override
  void writeStream(InputStream stream) {
    while (!stream.isEOS) {
      writeBytes(
        stream
            .readBytes(stream.length < 65536 ? stream.length : 65536)
            .toUint8List(),
      );
    }
  }
}
