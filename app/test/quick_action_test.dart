import 'dart:io';

import 'package:app/app_state.dart';
import 'package:app/models.dart';
import 'package:app/services/quick_action_desktop.dart';
import 'package:app/services/quick_action_service.dart';
import 'package:dbus/dbus.dart';
import 'package:flutter_test/flutter_test.dart';

class _Vault extends LifenizerAppState {
  bool unlocked = false;
  @override
  bool get isAuthenticated => unlocked;
}

void main() {
  test('links decode query and retain only known navigation actions', () {
    final action = QuickAction.fromUri(
      Uri.parse('lifenizer://search?q=Alice%20caf%C3%A9&conversation=a'),
    )!;
    expect(action.query, 'Alice café');
    expect(action.conversationId, 'a');
    expect(
      QuickAction.fromUri(Uri.parse('lifenizer://delete?q=anything')),
      isNull,
    );
    expect(
      QuickAction.fromUri(
        Uri.parse('https://example.test/?action=capture'),
      )!.action,
      'capture',
    );
  });

  test('pending quick action survives locked UI and is consumed once', () {
    final service = QuickActionService();
    var events = 0;
    service.addListener(() => events++);
    service.request(const QuickAction(query: 'Alice'));
    expect(service.pending!.query, 'Alice');
    expect(events, 1);
    expect(service.consume()!.query, 'Alice');
    expect(service.consume(), isNull);
    service.dispose();
  });

  test(
    'KRunner protocol returns ranked vault matches only while unlocked',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'lifenizer-runner-',
      );
      final server = DBusServer();
      final address = await server.listenAddress(
        DBusAddress.unix(dir: directory),
      );
      final exporter = DBusClient(address);
      final caller = DBusClient(address);
      final vault = _Vault();
      QuickAction? opened;
      var presentations = 0;
      final runner = LifenizerRunner(
        vault,
        (action) => opened = action,
        present: () async => presentations++,
      );
      await exporter.requestName(runnerBusName);
      await exporter.registerObject(runner);
      final remote = DBusRemoteObject(
        caller,
        name: runnerBusName,
        path: DBusObjectPath('/runner'),
      );
      vault.conversations.add(
        Conversation(
          id: 'alice',
          title: 'Alice holiday plans',
          source: 'signal',
          startedAt: DateTime(2026, 9, 25),
          participantIds: const [],
          segments: [ConversationSegment(id: 'one', text: 'Train trip')],
        ),
      );
      try {
        Future<List<DBusValue>> match(String query) async {
          final reply = await remote.callMethod(runnerInterface, 'Match', [
            DBusString(query),
          ], replySignature: DBusSignature('a(sssida{sv})'));
          return reply.returnValues.single.asArray().toList();
        }

        expect(await match('something unrelated'), isEmpty);
        var matches = await match('life Alice');
        expect(matches, hasLength(1));
        expect(matches.single.asStruct()[1].asString(), contains('Unlock'));
        vault.unlocked = true;
        matches = await match('life Alice');
        expect(matches, hasLength(2));
        expect(matches.first.asStruct()[0].asString(), 'conversation:alice');
        expect(matches.first.asStruct()[1].asString(), 'Alice holiday plans');
        await remote.callMethod(runnerInterface, 'Run', [
          const DBusString('conversation:alice'),
          const DBusString(''),
        ]);
        expect(opened!.conversationId, 'alice');
        expect(presentations, 1);
        vault.unlocked = false;
        await remote.callMethod(runnerInterface, 'Run', [
          const DBusString('conversation:alice'),
          const DBusString(''),
        ]);
        expect(opened!.conversationId, isNull);
        expect(await match('life'), hasLength(1));
        await remote.callMethod(runnerInterface, 'Open', [
          const DBusString('lifenizer://capture'),
        ]);
        expect(opened!.action, 'capture');
      } finally {
        await caller.close();
        await exporter.close();
        await server.close();
        await directory.delete(recursive: true);
        vault.dispose();
      }
    },
  );
}
