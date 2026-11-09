import 'dart:convert';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/pages/search/search_results_list.dart';
import 'package:app/services/source_links.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Conversation thread({String guild = '@me', int messages = 1}) => Conversation(
  id: 'thread',
  title: 'Example thread',
  source: 'discord',
  participantIds: [],
  sourceThreadId: 'discord:333',
  sourceUrl: 'https://discord.com/channels/$guild/333',
  metadata: {
    'messageScope': 'own-sent-messages',
    'channelType': guild == '@me' ? 'DM' : 'PUBLIC_THREAD',
  },
  segments: [
    for (var index = 0; index < messages; index++)
      ConversationSegment(
        id: 'message-$index',
        text: 'message-$index ${'x' * 700}',
        sourceMessageId: 'discord:${1000 + index}',
        createdAt: DateTime.utc(2025, 1, 1).add(Duration(minutes: index)),
      ),
  ],
);

void main() {
  test(
    'message links derive from persisted channel context with exact IDs and safe URL schemes',
    () {
      for (final guild in ['@me', '555']) {
        final conversation = thread(guild: guild);
        final restored = Conversation.fromJson(
          jsonDecode(jsonEncode(conversation.toJson())) as Map<String, dynamic>,
        );
        expect(
          discordMessageUrl(restored, restored.segments.single),
          'https://discord.com/channels/$guild/333/1000',
        );
        final normalized = NormalizedConversation.fromJson({
          'title': 'Thread',
          'source': 'discord',
          'sourceUrl': conversation.sourceUrl,
          'metadata': conversation.metadata,
          'segments': [],
        });
        expect(
          NormalizedConversation.fromJson(normalized.toJson()).metadata,
          conversation.metadata,
        );
        expect(normalized.sourceUrl, conversation.sourceUrl);
      }
      expect(externalLinkUri('javascript:alert(1)'), isNull);
      expect(externalLinkUri('file:///tmp/export'), isNull);
      expect(externalLinkUri('https://password@example.test/'), isNull);
      expect(externalLinkUri('https:///no-host'), isNull);
      final unrelated = Conversation.fromJson({
        ...thread().toJson(),
        'sourceUrl': 'https://example.test/channels/@me/333',
      });
      expect(discordMessageUrl(unrelated, unrelated.segments.single), isNull);
    },
  );

  testWidgets(
    'long threads render lazily with copyable messages and working original-chat/message actions',
    (tester) async {
      final state = LifenizerAppState();
      final conversation = thread(messages: 10000);
      final launched = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          launched.add((call.arguments as Map)['url'] as String);
          return true;
        }
        return false;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ConversationCard(state: state, conversation: conversation),
          ),
        ),
      );
      final preview = tester
          .widgetList<Text>(find.byType(Text))
          .where((text) => text.data?.startsWith('message-0 ') == true)
          .single;
      expect(preview.data!.length, lessThanOrEqualTo(500));
      await tester.tap(find.text('Example thread'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('This export contains only your sent messages'),
        findsOneWidget,
      );
      expect(
        tester.widgetList<SelectableText>(find.byType(SelectableText)).length,
        lessThan(50),
      );
      expect(find.textContaining('message-9999 '), findsNothing);
      await tester.tap(find.text('Open Discord chat'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open message').first);
      await tester.tap(find.text('Open message').first);
      await tester.pumpAndSettle();
      expect(launched, [
        'https://discord.com/channels/@me/333',
        'https://discord.com/channels/@me/333/1000',
      ]);
      await tester.pumpWidget(const SizedBox.shrink());
      state.dispose();
    },
  );
}
