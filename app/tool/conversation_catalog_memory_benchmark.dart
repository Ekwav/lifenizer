import 'dart:convert';
import 'dart:io';
import 'package:app/models.dart';
import 'package:app/services/conversation_catalog.dart';

/// Catalog-only memory probe: compile AOT, then run [count] [--plain].
/// Checks every serialized summary field so AOT retains the complete model.
/// Does not open or modify a vault/database; full search needs its own benchmark.
void main(List<String> args) {
  final count = args.isEmpty ? 300000 : int.parse(args[0]);
  if (count < 1 || count > 2000000) {
    throw ArgumentError('Use a count from 1 through 2000000.');
  }
  final compact = !args.contains('--plain');
  final List<Conversation> catalog = compact
      ? ConversationCatalog()
      : <Conversation>[];
  final before = ProcessInfo.currentRss;
  for (var i = 0; i < count; i++) {
    final date = DateTime.utc(2026, 1, 1).subtract(Duration(minutes: i));
    final data =
        jsonDecode(
              jsonEncode({
                'id':
                    '7a6d31e2-9f84-4b67-82a1-${i.toRadixString(16).padLeft(12, '0')}',
                'title': 'Archive ${i.toString().padLeft(12, '0')}',
                'source': [
                  'manual',
                  'imap',
                  'discord',
                  'youtube-watch-history',
                  'scanned-pdf',
                ][i % 5],
                'participantIds': [
                  i % 10000 == 0
                      ? 'fa3e6982-cc80-4d96-bd62-000000000001'
                      : 'fa3e6982-cc80-4d96-bd62-000000000002',
                ],
                'artifactNames': [],
                'tags': [],
                'startedAt': date.toIso8601String(),
                'endedAt': date.toIso8601String(),
                'previewText':
                    '${i.toString().padLeft(12, '0')} ${'grocery shopping ' * 11}'
                        .substring(0, 180),
                'segmentCount': 10,
              }),
            )
            as Map<String, dynamic>;
    catalog.add(Conversation.fromSummaryJson(data));
  }
  var checksum = 0;
  for (final doc in catalog) {
    checksum += jsonEncode(doc.toSummaryJson()).length;
  }
  stdout.writeln(
    jsonEncode({
      'compact': compact,
      'count': count,
      'before': before,
      'rss': ProcessInfo.currentRss,
      'peak': ProcessInfo.maxRss,
      'checksum': checksum,
    }),
  );
}
