import 'dart:async';
import 'dart:convert';

import 'package:app/pages/connection_scanner_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class _Camera extends MobileScannerPlatform {
  final captures = StreamController<BarcodeCapture?>.broadcast();
  bool denied = false;
  int starts = 0;
  int stops = 0;
  int disposals = 0;
  StartOptions? options;

  @override
  Stream<BarcodeCapture?> get barcodesStream => captures.stream;
  @override
  Stream<TorchState> get torchStateStream => const Stream.empty();
  @override
  Stream<double> get zoomScaleStateStream => const Stream.empty();
  @override
  Widget buildCameraView() => const SizedBox();
  @override
  Future<MobileScannerViewAttributes> start(StartOptions startOptions) async {
    starts++;
    options = startOptions;
    if (denied) {
      throw const MobileScannerException(
        errorCode: MobileScannerErrorCode.permissionDenied,
      );
    }
    return const MobileScannerViewAttributes(
      cameraDirection: CameraFacing.back,
      currentTorchMode: TorchState.unavailable,
      size: Size(640, 480),
    );
  }

  @override
  Future<void> stop() async {
    stops++;
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }

  @override
  Future<void> updateScanWindow(Rect? window) async {}

  void scan(String value) =>
      captures.add(BarcodeCapture(barcodes: [Barcode(rawValue: value)]));
}

void main() {
  late _Camera camera;
  late MobileScannerPlatform original;
  setUp(() {
    original = MobileScannerPlatform.instance;
    camera = _Camera();
    MobileScannerPlatform.instance = camera;
  });
  tearDown(() async {
    await camera.captures.close();
    MobileScannerPlatform.instance = original;
  });

  Future<void> open(WidgetTester tester, void Function(String?) result) async {
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => result(
                await Navigator.of(context).push<String>(
                  MaterialPageRoute(
                    builder: (_) => const ConnectionScannerPage(),
                  ),
                ),
              ),
              child: const Text('Open scanner'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open scanner'));
    await tester.pumpAndSettle();
  }

  testWidgets('rejects other QR codes, accepts an expired pairing link once', (
    tester,
  ) async {
    final results = <String?>[];
    await open(tester, results.add);
    expect(camera.options!.formats, [BarcodeFormat.qrCode]);
    camera.scan('https://example.com/unrelated');
    await tester.pumpAndSettle();
    expect(
      find.text('This is not a Lifenizer connection QR code.'),
      findsOneWidget,
    );
    expect(results, isEmpty);
    final secret = base64UrlEncode(List.filled(32, 1));
    final link =
        'lifenizer://connect?server=https%3A%2F%2Fexample.com'
        '#v=1&secret=$secret&until=1';
    camera.scan(link);
    camera.scan(link);
    await tester.pumpAndSettle();
    expect(results, [link]);
    expect(camera.stops, greaterThanOrEqualTo(1));
    expect(camera.disposals, 1);
  });

  testWidgets('stops camera in background and resumes scanning', (
    tester,
  ) async {
    await open(tester, (_) {});
    expect(camera.starts, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.stops, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(camera.starts, 2);
    await tester.tap(find.text('Paste link instead'));
    await tester.pumpAndSettle();
    expect(camera.disposals, 1);
  });

  testWidgets('denied camera offers retry and paste fallback', (tester) async {
    camera.denied = true;
    final results = <String?>[];
    await open(tester, results.add);
    expect(find.textContaining('Allow camera access'), findsOneWidget);
    camera.denied = false;
    await tester.tap(find.text('Retry camera'));
    await tester.pumpAndSettle();
    expect(camera.starts, 2);
    expect(find.textContaining('Allow camera access'), findsNothing);
    await tester.tap(find.text('Paste link instead'));
    await tester.pumpAndSettle();
    expect(results, [null]);
  });
}
