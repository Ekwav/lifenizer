import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:app/services/discord_bot_gateway_io.dart';

void main() {
  test(
    'Gateway identifies, heartbeats, dispatches authors and resumes after reconnect',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final resume = Completer<Map<String, dynamic>>();
      final heartbeat = Completer<void>();
      final event = Completer<Map<String, dynamic>>();
      var connections = 0;
      final sockets = <WebSocket>[];
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        sockets.add(socket);
        connections++;
        socket.add(
          jsonEncode({
            'op': 10,
            'd': {'heartbeat_interval': 50},
          }),
        );
        socket.listen((raw) {
          final data = jsonDecode(raw as String) as Map<String, dynamic>;
          if (data['op'] == 1) {
            if (!heartbeat.isCompleted) heartbeat.complete();
            socket.add('{"op":11,"d":null}');
          }
          if (data['op'] == 2) {
            expect(data['d']['token'], 'fake-bot-token');
            expect(data['d']['intents'], 1 | (1 << 9) | (1 << 15));
            socket.add(
              jsonEncode({
                'op': 0,
                't': 'READY',
                's': 41,
                'd': {
                  'session_id': 'session-1',
                  'resume_gateway_url': 'wss://gateway.discord.gg',
                },
              }),
            );
            socket.add(
              jsonEncode({
                'op': 0,
                't': 'MESSAGE_CREATE',
                's': 42,
                'd': {
                  'id': '101',
                  'channel_id': '123',
                  'author': {'id': '8', 'username': 'ekwav'},
                  'content': 'hello',
                },
              }),
            );
            Timer(
              const Duration(milliseconds: 100),
              () => socket.add('{"op":7,"d":null}'),
            );
          }
          if (data['op'] == 6 && !resume.isCompleted) {
            resume.complete(data['d'] as Map<String, dynamic>);
          }
        });
      });
      final gateway = DiscordBotGateway(
        token: 'fake-bot-token',
        onStatus: (_) {},
        onEvent: (type, data) {
          if (type == 'MESSAGE_CREATE' && !event.isCompleted) {
            event.complete(data);
          }
        },
        connect: (_) => WebSocket.connect('ws://127.0.0.1:${server.port}'),
      );
      try {
        await gateway.start();
        expect(
          (await event.future.timeout(
            const Duration(seconds: 5),
          ))['author']['id'],
          '8',
        );
        await heartbeat.future.timeout(const Duration(seconds: 5));
        final payload = await resume.future.timeout(const Duration(seconds: 5));
        expect(payload['session_id'], 'session-1');
        expect(payload['seq'], 42);
        expect(connections, 2);
      } finally {
        await gateway.close();
        for (final socket in sockets) {
          await socket.close();
        }
        await server.close(force: true);
      }
    },
  );
}
