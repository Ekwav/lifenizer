import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dbus/dbus.dart';

import '../app_state.dart';
import 'quick_action_service.dart';
import 'export_watch_service.dart';

const runnerBusName = 'com.lifenizer.Search';
const runnerInterface = 'org.kde.krunner1';
const controlInterface = 'com.lifenizer.Control';

Future<void> startDesktopRunner(
  LifenizerAppState state,
  void Function(QuickAction) request,
) async {
  final client = DBusClient.session();
  try {
    await client.registerObject(LifenizerRunner(state, request));
    final ownership = await client.requestName(
      runnerBusName,
      flags: {DBusRequestNameFlag.doNotQueue},
    );
    if (ownership != DBusRequestNameReply.primaryOwner) {
      await client.close();
      return;
    }
  } catch (_) {
    // Search in the app remains available without a desktop session bus.
    await client.close();
  }
}

/// KDE's D-Bus runner protocol; the only index is the unlocked app's memory.
class LifenizerRunner extends DBusObject {
  LifenizerRunner(
    this.state,
    this.request, {
    this.present = _presentWindow,
    Future<void> Function(String)? importFile,
  }) : importFile = importFile ?? state.importDiscordArchive,
       super(DBusObjectPath('/runner'));

  final LifenizerAppState state;
  final void Function(QuickAction) request;
  final Future<void> Function() present;
  final Future<void> Function(String) importFile;

  static Future<void> _presentWindow() async {
    await QuickActionService.channel.invokeMethod<void>('present');
  }

  @override
  List<DBusIntrospectInterface> introspect() => [
    DBusIntrospectInterface(
      controlInterface,
      methods: [
        for (final name in ['ImportFile', 'WatchExport'])
          DBusIntrospectMethod(
            name,
            args: [
              DBusIntrospectArgument(
                DBusSignature('s'),
                DBusArgumentDirection.in_,
                name: 'path',
              ),
            ],
          ),
        DBusIntrospectMethod('Lock'),
        DBusIntrospectMethod(
          'Status',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.out,
              name: 'status',
            ),
          ],
        ),
      ],
    ),
    DBusIntrospectInterface(
      runnerInterface,
      methods: [
        DBusIntrospectMethod(
          'Match',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'query',
            ),
            DBusIntrospectArgument(
              DBusSignature('a(sssida{sv})'),
              DBusArgumentDirection.out,
              name: 'matches',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'Run',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'matchId',
            ),
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'actionId',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'Actions',
          args: [
            DBusIntrospectArgument(
              DBusSignature('a(sss)'),
              DBusArgumentDirection.out,
              name: 'actions',
            ),
          ],
        ),
        DBusIntrospectMethod(
          'Open',
          args: [
            DBusIntrospectArgument(
              DBusSignature('s'),
              DBusArgumentDirection.in_,
              name: 'uri',
            ),
          ],
        ),
      ],
    ),
  ];

  @override
  Future<DBusMethodResponse> handleMethodCall(DBusMethodCall methodCall) async {
    if (methodCall.interface == controlInterface) {
      if (methodCall.name == 'Status' &&
          methodCall.signature == DBusSignature('')) {
        return DBusMethodSuccessResponse([
          DBusString(
            jsonEncode({
              'unlocked': state.isAuthenticated,
              'busy': state.busy,
              'conversations': state.isAuthenticated
                  ? state.conversations.length
                  : 0,
              'messages': state.isAuthenticated
                  ? state.conversations.fold<int>(
                      0,
                      (n, c) => n + c.segments.length,
                    )
                  : 0,
              'people': state.isAuthenticated ? state.participants.length : 0,
              'pendingSync': state.pendingSyncCount,
              'hasError': state.error != null,
              'syncPaused': state.syncError != null,
            }),
          ),
        ]);
      }
      if (state.busy || !state.isAuthenticated) {
        return DBusMethodErrorResponse('com.lifenizer.NotReady', [
          const DBusString(
            'Unlock the vault and wait for the current operation.',
          ),
        ]);
      }
      if (methodCall.name == 'Lock' &&
          methodCall.signature == DBusSignature('')) {
        await state.lock();
        return state.isAuthenticated
            ? DBusMethodErrorResponse('com.lifenizer.SaveFailed')
            : DBusMethodSuccessResponse();
      }
      if (['ImportFile', 'WatchExport'].contains(methodCall.name) &&
          methodCall.signature == DBusSignature('s')) {
        final path = methodCall.values.single.asString();
        if (!path.startsWith('/') ||
            !path.toLowerCase().endsWith('.zip') ||
            !await File(path).exists()) {
          return DBusMethodErrorResponse.invalidArgs();
        }
        request(const QuickAction(action: 'imports'));
        await present();
        final operation = methodCall.name == 'WatchExport'
            ? ExportWatchService.instance.watch(path)
            : importFile(path);
        unawaited(
          operation.catchError((Object _) {
            state.reportError(
              'The Discord export could not be imported. Check the selected file in Imports.',
            );
          }),
        );
        return DBusMethodSuccessResponse();
      }
      return DBusMethodErrorResponse.unknownMethod();
    }
    if (methodCall.interface != runnerInterface) {
      return DBusMethodErrorResponse.unknownInterface();
    }
    if (methodCall.name == 'Actions' &&
        methodCall.signature == DBusSignature('')) {
      return DBusMethodSuccessResponse([DBusArray(DBusSignature('(sss)'), [])]);
    }
    if (methodCall.name == 'Match' &&
        methodCall.signature == DBusSignature('s')) {
      final input = methodCall.values.single.asString().trim();
      final prefix = RegExp(
        r'^(life|lifenizer)(?:\s+|$)',
        caseSensitive: false,
      );
      final matches = <DBusValue>[];
      if (prefix.hasMatch(input)) {
        final query = input.replaceFirst(prefix, '').trim();
        if (state.isAuthenticated) {
          final results = state.search(query, maxResults: 8);
          for (var i = 0; i < results.length; i++) {
            final conversation = results[i];
            matches.add(
              _match(
                'conversation:${conversation.id}',
                conversation.title,
                1 - i * .05,
                '${conversation.source} · ${conversation.startedAt.toLocal().toIso8601String().split('T').first}',
              ),
            );
          }
        }
        final uri = Uri(
          scheme: 'lifenizer',
          host: 'search',
          queryParameters: {'q': query},
        );
        matches.add(
          _match(
            uri.toString(),
            state.isAuthenticated
                ? 'Search Lifenizer'
                : 'Unlock Lifenizer to search',
            .5,
            'Open your private conversations',
          ),
        );
      }
      return DBusMethodSuccessResponse([
        DBusArray(DBusSignature('(sssida{sv})'), matches),
      ]);
    }
    if (methodCall.name == 'Open' &&
        methodCall.signature == DBusSignature('s')) {
      final uri = Uri.tryParse(methodCall.values.single.asString());
      final action = uri == null ? null : QuickAction.fromUri(uri);
      if (action == null) return DBusMethodErrorResponse.invalidArgs();
      request(action);
      await present();
      return DBusMethodSuccessResponse();
    }
    if (methodCall.name == 'Run' &&
        methodCall.signature == DBusSignature('ss')) {
      final id = methodCall.values.first.asString();
      if (id.startsWith('conversation:')) {
        // A result can outlive its unlock session; never reopen a private item after lock.
        if (state.isAuthenticated) {
          request(
            QuickAction(conversationId: id.substring('conversation:'.length)),
          );
        } else {
          request(const QuickAction());
        }
      } else {
        final uri = Uri.tryParse(id);
        final action = uri == null ? null : QuickAction.fromUri(uri);
        if (action == null) return DBusMethodErrorResponse.invalidArgs();
        request(action);
      }
      await present();
      return DBusMethodSuccessResponse();
    }
    return DBusMethodErrorResponse.unknownMethod();
  }

  DBusStruct _match(
    String id,
    String title,
    double relevance,
    String subtitle,
  ) => DBusStruct([
    DBusString(id),
    DBusString(title),
    const DBusString('system-search'),
    const DBusInt32(100),
    DBusDouble(relevance),
    DBusDict.stringVariant({'subtext': DBusString(subtitle)}),
  ]);
}
