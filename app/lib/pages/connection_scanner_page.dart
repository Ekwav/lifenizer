import 'dart:async';

import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../services/pairing_crypto.dart';

class ConnectionScannerPage extends StatefulWidget {
  const ConnectionScannerPage({super.key});

  @override
  State<ConnectionScannerPage> createState() => _ConnectionScannerPageState();
}

class _ConnectionScannerPageState extends State<ConnectionScannerPage>
    with WidgetsBindingObserver {
  final _camera = MobileScannerController(
    autoStart: false,
    formats: const [BarcodeFormat.qrCode],
  );
  bool _completed = false;
  String? _message;

  bool get _foreground =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (!mounted || _completed || _camera.value.isStarting) return;
    try {
      await _camera.start();
      if (mounted && !_foreground) {
        await _camera.stop();
      }
    } on MobileScannerException {
      // The camera preview displays permission and availability errors.
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_camera.value.hasCameraPermission || _completed) return;
    if (state == AppLifecycleState.resumed) {
      unawaited(_start());
    } else {
      unawaited(_camera.stop());
    }
  }

  Future<void> _detected(BarcodeCapture capture) async {
    if (_completed || !mounted || !_foreground) {
      return;
    }
    for (final barcode in capture.barcodes) {
      final link = barcode.rawValue;
      if (link == null) continue;
      try {
        PairingLink.parse(link);
      } catch (_) {
        setState(
          () => _message = 'This is not a Lifenizer connection QR code.',
        );
        continue;
      }
      _completed = true;
      await _camera.stop();
      if (mounted) Navigator.of(context).pop(link.trim());
      return;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_camera.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Scan connection QR')),
    body: SafeArea(
      child: Column(
        children: [
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Point your camera at the QR code in Sync on your other device.',
            ),
          ),
          Expanded(
            child: MobileScanner(
              controller: _camera,
              onDetect: _detected,
              errorBuilder: (context, error) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    error.errorCode == MobileScannerErrorCode.permissionDenied
                        ? 'Allow camera access to scan the QR code. If access was blocked, enable Camera in Android Settings → Apps → Lifenizer → Permissions, then retry.'
                        : 'The camera is unavailable. Retry, or paste the connection link instead.',
                  ),
                ),
              ),
            ),
          ),
          if (_message != null)
            Padding(padding: const EdgeInsets.all(16), child: Text(_message!)),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 16,
              children: [
                OutlinedButton(
                  onPressed: _start,
                  child: const Text('Retry camera'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Paste link instead'),
                ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
