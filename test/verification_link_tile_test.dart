import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geocam/features/history/widgets/verification_link_tile.dart';
import 'package:geocam/services/photo_processor.dart';

void main() {
  const url = 'https://example.test/GC-123';
  late List<Uri> opened;
  late bool openResult;
  String? clipboard;

  Future<void> show(WidgetTester t) async {
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: VerificationLinkTile(
          url: url,
          opener: (u) async {
            opened.add(u);
            return openResult;
          },
        ),
      ),
    ));
  }

  setUp(() {
    opened = [];
    openResult = true;
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      return null;
    });
  });

  tearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

  testWidgets('tapping the link opens it in the browser', (t) async {
    await show(t);
    await t.tap(find.text(url));
    await t.pump();
    expect(opened.single.toString(), url);
    expect(clipboard, isNull);
  });

  testWidgets('the copy button copies the link', (t) async {
    await show(t);
    await t.tap(find.byTooltip('Copy link'));
    await t.pump();
    expect(clipboard, url);
    expect(find.text('Link copied'), findsOneWidget);
    expect(opened, isEmpty);
  });

  testWidgets('long-pressing the link copies it', (t) async {
    await show(t);
    await t.longPress(find.text(url));
    await t.pump();
    expect(clipboard, url);
  });

  testWidgets('if no browser can be opened the user is told, and can still copy', (t) async {
    openResult = false;
    await show(t);
    await t.tap(find.text(url));
    await t.pump();
    expect(find.textContaining('Could not open the browser'), findsOneWidget);
  });

  test('the tile shows the same link the photo QR code carries', () {
    final qr = PhotoProcessor.qrPayloadFor(address: '', timestamp: DateTime.utc(2026), recordId: 'GC-123');
    expect(qr.endsWith('/GC-123'), isTrue);
  });
}
