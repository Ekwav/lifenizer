import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../api_client.dart';
import '../app_state.dart';
import '../models.dart';
import 'pairing_crypto.dart';
import 'pairing_store.dart';

class DevicePairingService extends ChangeNotifier {
  DevicePairingService(this.state, {PairingCredentialStore? store})
    : _store = store ?? PairingCredentialStore();
  final LifenizerAppState state;
  final PairingCredentialStore _store;
  Map<String, dynamic>? _credentials;
  DeviceProtection _protection = DeviceProtection.keyring;
  final List<Map<String, dynamic>> pending = [];
  bool busy = false;
  bool waitingForApproval = false;
  String? message;
  String? error;
  String? verificationCode;
  Timer? _timer;
  int _generation = 0;
  bool _ticking = false;
  Future<String?>? _refreshing;

  bool get isPaired => _credentials?['email'] is String;
  bool get higherSecurity => _protection != DeviceProtection.keyring;
  String get protectionMode => switch (_protection) {
    DeviceProtection.keyring => 'system',
    DeviceProtection.password => 'password',
    DeviceProtection.biometric => 'biometric',
  };
  bool matchesVault(String server, String email) =>
      isPaired &&
      _credentials!['server'] == server &&
      _credentials!['email'] == email;
  bool get _currentVault =>
      matchesVault(state.apiBaseUrl, state.rememberedEmail);
  String? get connectionLink {
    if (kIsWeb || !state.isAuthenticated || !_currentVault) return null;
    final secret = _credentials?['secret'];
    final until = _credentials?['until'];
    if (secret is! String || until is! int) return null;
    final link = Uri(
      scheme: 'lifenizer',
      host: 'connect',
      queryParameters: {'server': state.apiBaseUrl},
      fragment: Uri(
        queryParameters: {'v': '1', 'secret': secret, 'until': '$until'},
      ).query,
    ).toString();
    try {
      PairingLink.parse(link);
      return link;
    } on FormatException {
      return null;
    }
  }

  DateTime? get automaticApprovalUntil => _credentials == null
      ? null
      : DateTime.fromMillisecondsSinceEpoch(
          (_credentials!['until'] as int) * 1000,
          isUtc: true,
        );
  bool get automaticApprovalActive =>
      automaticApprovalUntil?.isAfter(DateTime.now().toUtc()) == true;

  LifenizerApiClient _api(String server) =>
      state.apiFactory?.call(server) ?? LifenizerApiClient(baseUrl: server);
  LifenizerApiClient _authenticatedApi() => _api(
    state.apiBaseUrl,
  ).authenticated(state.session!.authToken, refreshAuth: refreshAccess);

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => tick());
  }

  Future<void> restore({bool autoUnlock = true}) async {
    if (kIsWeb) return;
    try {
      _credentials = await _store.read();
      _protection = PairingCredentialStore.protectionOf(_credentials);
      if (!isPaired) {
        _credentials = null;
      }
      notifyListeners();
      if (isPaired) {
        _startTimer();
        if (autoUnlock && !higherSecurity) await unlockSaved();
      }
    } catch (_) {
      error =
          'The device keyring is unavailable. Unlock KDE Wallet or Android secure storage and retry.';
      notifyListeners();
    }
  }

  Future<void> unlockSaved({
    String? password,
    bool authenticate = false,
  }) async {
    if (!isPaired || busy || state.busy || state.isAuthenticated) return;
    if (higherSecurity && !authenticate) return;
    final generation = _generation;
    var loginStarted = false;
    busy = true;
    error = null;
    notifyListeners();
    try {
      state.reportUnlockProgress(
        higherSecurity
            ? 'Verifying device protection'
            : 'Reading paired device credentials',
      );
      final credentials = await _store.readForUnlock(
        password: password,
        authenticate: authenticate,
      );
      if (credentials == null || credentials['email'] is! String) {
        throw StateError('Device keyring credentials are missing.');
      }
      if (generation != _generation) return;
      _credentials = credentials;
      state.reportUnlockProgress('Refreshing device access');
      AuthSession? auth;
      try {
        final result = await _api(credentials['server'] as String)
            .refreshPairing(
              credentials['deviceId'] as String,
              credentials['refreshToken'] as String,
            );
        if (result['email'] != credentials['email'] ||
            result['deviceId'] != credentials['deviceId']) {
          throw StateError('The paired account changed.');
        }
        auth = AuthSession.fromJson(
          Map<String, dynamic>.from(result['session'] as Map),
        );
      } on ApiException catch (exception) {
        if (exception.statusCode == 401 || exception.statusCode == 403) {
          error =
              'Device approval expired. Open the connection link again and approve this device from an unlocked device. Your local vault remains available offline.';
        }
      } on StateError {
        error =
            'The server returned another paired account. Your saved vault credentials were preserved.';
      } catch (_) {
        /* Offline unlock uses the encrypted local session. */
      }
      if (generation != _generation) return;
      loginStarted = true;
      await state.login(
        baseUrl: credentials['server'] as String,
        email: credentials['email'] as String,
        passphrase: credentials['vaultPassphrase'] as String,
        pairedSession: auth,
        offline: auth == null,
      );
      if (!state.isAuthenticated && auth != null) {
        await state.login(
          baseUrl: credentials['server'] as String,
          email: credentials['email'] as String,
          passphrase: credentials['vaultPassphrase'] as String,
          offline: true,
        );
      }
      if (!state.isAuthenticated) {
        error ??= state.error;
      }
      _startTimer();
    } catch (_) {
      error = higherSecurity
          ? 'Could not unlock this device. Check your device password or fingerprint/PIN verification and retry.'
          : 'Could not unlock this device. Check the device keyring and connection.';
    } finally {
      if (!loginStarted && generation == _generation) {
        state.reportUnlockProgress(null);
      }
      if (!state.isAuthenticated) {
        _store.forgetUnlock();
        _credentials?.remove('secret');
        _credentials?.remove('vaultPassphrase');
        _credentials?.remove('refreshToken');
        _credentials?.remove('pendingEnrollment');
      }
      busy = false;
      notifyListeners();
    }
    if (state.isAuthenticated) unawaited(tick());
  }

  void onLocked() {
    _generation++;
    _store.forgetUnlock();
    _credentials?.remove('secret');
    _credentials?.remove('vaultPassphrase');
    _credentials?.remove('refreshToken');
    _credentials?.remove('pendingEnrollment');
    pending.clear();
    message = null;
    notifyListeners();
  }

  Future<bool> enableProtection(
    String mode, {
    String? password,
    String? currentPassword,
  }) async {
    if (busy ||
        state.busy ||
        !state.isAuthenticated ||
        !_currentVault ||
        _credentials?['vaultPassphrase'] is! String) {
      error = 'Unlock this paired vault before changing device security.';
      notifyListeners();
      return false;
    }
    final target = switch (mode) {
      'system' => DeviceProtection.keyring,
      'password' => DeviceProtection.password,
      'biometric' => DeviceProtection.biometric,
      _ => throw ArgumentError('Unknown device protection.'),
    };
    busy = true;
    error = null;
    notifyListeners();
    try {
      await _store.setProtection(
        target,
        Map<String, dynamic>.from(_credentials!),
        password: password,
        currentPassword: currentPassword,
      );
      _protection = target;
      if (state.isAuthenticated) state.status = 'Device security updated';
      return true;
    } catch (_) {
      error =
          'Device security was not changed. Check your current password or fingerprint/PIN verification and try again.';
      return false;
    } finally {
      if (!state.isAuthenticated) onLocked();
      busy = false;
      notifyListeners();
    }
  }

  Future<void> connect(String connectionLink) async {
    if (kIsWeb) {
      error = 'Open the connection link in the native Android or KDE app.';
      notifyListeners();
      return;
    }
    if (busy || state.busy || state.isAuthenticated) {
      error = 'Lock this vault before connecting another device or account.';
      notifyListeners();
      return;
    }
    if (higherSecurity && isPaired) {
      error =
          'Unlock this device and disable Device security before changing its connection.';
      notifyListeners();
      return;
    }
    final generation = ++_generation;
    busy = true;
    error = null;
    message = 'Connecting securely…';
    verificationCode = null;
    notifyListeners();
    PairingRequest? request;
    Map<String, dynamic>? saved;
    Map<String, dynamic>? enrollment;
    try {
      final link = PairingLink.parse(connectionLink);
      // Fail before enrollment when the native keyring cannot be accessed.
      saved = await _store.read();
      if (saved?['email'] is String &&
          (saved!['server'] != link.server ||
              saved['secret'] != base64UrlEncode(link.secret))) {
        throw StateError(
          'This device is paired with another vault. Its existing key was preserved.',
        );
      }
      request = await PairingCrypto.request(
        link,
        defaultTargetPlatform == TargetPlatform.android
            ? 'Android phone'
            : 'KDE computer',
      );
      final previous = saved?['pendingEnrollment'];
      final retrying =
          previous is Map &&
          previous['server'] == link.server &&
          previous['secret'] == base64UrlEncode(link.secret);
      enrollment = retrying
          ? Map<String, dynamic>.from(previous)
          : <String, dynamic>{
              'server': link.server,
              'secret': base64UrlEncode(link.secret),
              'until':
                  link.until.isBefore(
                    DateTime.now().toUtc().add(const Duration(hours: 1)),
                  )
                  ? link.until.millisecondsSinceEpoch ~/ 1000
                  : DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
              'vaultPassphrase': PairingCrypto.randomToken(),
              'refreshToken': request.refreshToken,
              'request': request.body,
            };
      await _store.write({...?saved, 'pendingEnrollment': enrollment});
      final api = _api(link.server);
      Map<String, dynamic>? recovered;
      if (retrying && saved?['email'] is! String) {
        try {
          recovered = {
            ...await api.refreshPairing(
              null,
              enrollment['refreshToken'] as String,
            ),
            'status': 'bootstrap',
          };
        } on ApiException catch (exception) {
          if (exception.statusCode != 401) rethrow;
        }
      }
      var result =
          recovered ??
          await api.requestPairing(
            Map<String, dynamic>.from(enrollment['request'] as Map),
          );
      // Private transfer keys stay in memory. A resumed pending request starts
      // a fresh exchange, while an interrupted bootstrap reuses its identity.
      if (retrying && result['status'] == 'pending') {
        enrollment['refreshToken'] = request.refreshToken;
        enrollment['request'] = request.body;
        await _store.write({...?saved, 'pendingEnrollment': enrollment});
        result = await api.requestPairing(request.body);
      }
      verificationCode = await PairingCrypto.verificationCode(
        Map<String, dynamic>.from(enrollment['request'] as Map),
      );
      final bootstrap = result['status'] == 'bootstrap';
      if (result['status'] == 'pending') {
        final id = result['requestId'] as String;
        final token = result['requestToken'] as String;
        final expiry = DateTime.parse(result['expiresAt'] as String).toUtc();
        waitingForApproval = true;
        message =
            'Open Sync on a connected, unlocked device. Compare code $verificationCode, then approve this device.';
        notifyListeners();
        while (DateTime.now().toUtc().isBefore(expiry)) {
          await Future<void>.delayed(const Duration(seconds: 2));
          if (generation != _generation) return;
          result = await api.pollPairing(id, token);
          if (result['status'] == 'approved') break;
          if (result['status'] == 'denied') {
            throw StateError('Device request denied.');
          }
        }
      }
      if (generation != _generation) return;
      if (!bootstrap && result['status'] != 'approved') {
        throw StateError(
          'Device request expired. Try the connection link again.',
        );
      }
      if (state.isAuthenticated || state.busy) {
        throw StateError('Another vault is already open. Lock it and retry.');
      }
      if (saved?['email'] is String &&
          (bootstrap || result['email'] != saved!['email'])) {
        await _store.write(saved!);
        throw StateError(
          'The server returned a different vault. Your existing device key was preserved.',
        );
      }
      final transfer = bootstrap
          ? null
          : await PairingCrypto.decryptTransfer(
              request,
              Map<String, dynamic>.from(result['transfer'] as Map),
              link.secret,
            );
      final passphrase = bootstrap
          ? enrollment['vaultPassphrase'] as String
          : transfer!['vaultPassphrase'] as String;
      var untilSeconds = (enrollment['until'] as int);
      final linkedUntil = link.until.millisecondsSinceEpoch ~/ 1000;
      if (linkedUntil < untilSeconds) untilSeconds = linkedUntil;
      if (transfer != null &&
          (transfer['approvalUntil'] as int) < untilSeconds) {
        untilSeconds = transfer['approvalUntil'] as int;
      }
      if (result['bootstrapExpiresAt'] != null) {
        final serverUntil =
            DateTime.parse(
              result['bootstrapExpiresAt'] as String,
            ).toUtc().millisecondsSinceEpoch ~/
            1000;
        if (serverUntil < untilSeconds) untilSeconds = serverUntil;
      }
      final credentials = <String, dynamic>{
        'server': link.server,
        'secret': base64UrlEncode(link.secret),
        'until': untilSeconds,
        'vaultPassphrase': passphrase,
        'email': result['email'],
        'deviceId': result['deviceId'],
        'refreshToken': enrollment['refreshToken'],
      };
      await _store.write(credentials);
      _credentials = credentials;
      await state.login(
        baseUrl: link.server,
        email: result['email'] as String,
        passphrase: passphrase,
        pairedSession: AuthSession.fromJson(
          Map<String, dynamic>.from(result['session'] as Map),
        ),
        register: bootstrap,
      );
      if (!state.isAuthenticated) {
        throw StateError(state.error ?? 'Could not unlock the paired vault.');
      }
      message = 'Device connected';
      _startTimer();
    } catch (exception) {
      error = exception is FormatException
          ? 'Invalid secure connection link.'
          : 'Could not connect this device: $exception';
    } finally {
      request?.dispose();
      if (generation == _generation) {
        busy = false;
        waitingForApproval = false;
        notifyListeners();
      }
    }
    if (state.isAuthenticated) unawaited(tick());
  }

  void cancel() {
    if (!waitingForApproval) return;
    _generation++;
    waitingForApproval = false;
    busy = false;
    message = null;
    verificationCode = null;
    notifyListeners();
  }

  Future<String?> refreshAccess() {
    if (_refreshing != null) return _refreshing!;
    final operation = _refreshAccess();
    _refreshing = operation;
    return operation.whenComplete(() {
      _refreshing = null;
    });
  }

  Future<String?> _refreshAccess() async {
    if (!isPaired || !_currentVault || state.session == null) return null;
    final credentials = _credentials!;
    final previous = state.session!;
    final result = await _api(credentials['server'] as String).refreshPairing(
      credentials['deviceId'] as String,
      credentials['refreshToken'] as String,
    );
    if (!identical(state.session, previous)) return null;
    if (result['email'] != credentials['email'] ||
        result['deviceId'] != credentials['deviceId']) {
      throw StateError('Paired account changed.');
    }
    final auth = AuthSession.fromJson(
      Map<String, dynamic>.from(result['session'] as Map),
    );
    await state.updatePairedSession(auth);
    return auth.authToken;
  }

  bool _expiresSoon(String token) {
    try {
      final payload =
          jsonDecode(
                utf8.decode(
                  base64Url.decode(base64Url.normalize(token.split('.')[1])),
                ),
              )
              as Map;
      return (payload['exp'] as num).toInt() <
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 300;
    } catch (_) {
      return false;
    }
  }

  Future<void> tick() async {
    if (!isPaired ||
        !_currentVault ||
        !state.isAuthenticated ||
        state.busy ||
        busy ||
        _ticking) {
      return;
    }
    _ticking = true;
    try {
      if (_expiresSoon(state.session!.authToken)) await refreshAccess();
      final currentSession = state.session;
      final records = await _authenticatedApi().pendingPairings();
      if (!identical(state.session, currentSession) ||
          !state.isAuthenticated ||
          state.busy) {
        return;
      }
      pending.clear();
      for (final record in records) {
        if (!await PairingCrypto.verifyRequest(
          base64Url.decode(_credentials!['secret'] as String),
          record,
        )) {
          continue;
        }
        if (!DateTime.parse(
          record['expiresAt'] as String,
        ).toUtc().isAfter(DateTime.now().toUtc())) {
          continue;
        }
        record['verificationCode'] = await PairingCrypto.verificationCode(
          record,
        );
        pending.add(record);
      }
      notifyListeners();
      if (automaticApprovalActive) {
        for (final record in List<Map<String, dynamic>>.of(pending)) {
          if (!automaticApprovalActive ||
              !state.isAuthenticated ||
              state.busy) {
            break;
          }
          await approve(record, automatic: true);
        }
      }
    } catch (_) {
      // Offline operation stays available. Requests retry while the app is open.
    } finally {
      _ticking = false;
    }
  }

  Future<void> approve(
    Map<String, dynamic> request, {
    bool automatic = false,
  }) async {
    if (!isPaired || !_currentVault || !state.isAuthenticated || state.busy) {
      return;
    }
    final credentials = _credentials!;
    final currentSession = state.session;
    if (!await PairingCrypto.verifyRequest(
      base64Url.decode(credentials['secret'] as String),
      request,
    )) {
      throw StateError('Unverified device request.');
    }
    final transfer = await PairingCrypto.encryptTransfer(
      request,
      credentials['vaultPassphrase'] as String,
      credentials['until'] as int,
      base64Url.decode(credentials['secret'] as String),
    );
    if (!identical(state.session, currentSession) ||
        !state.isAuthenticated ||
        state.busy) {
      return;
    }
    if (automatic && !automaticApprovalActive) {
      return;
    }
    await _authenticatedApi().approvePairing(request['id'] as String, transfer);
    pending.removeWhere((record) => record['id'] == request['id']);
    notifyListeners();
  }

  Future<void> deny(Map<String, dynamic> request) async {
    if (!state.isAuthenticated || state.busy) return;
    await _authenticatedApi().denyPairing(request['id'] as String);
    pending.removeWhere((record) => record['id'] == request['id']);
    notifyListeners();
  }

  @override
  void dispose() {
    _generation++;
    _timer?.cancel();
    _store.forgetUnlock();
    _credentials = null;
    super.dispose();
  }
}
