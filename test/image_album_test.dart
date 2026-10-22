import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';

/// A 1x1 transparent PNG. Real bytes (rather than junk) so `Image.file`
/// decodes successfully instead of exercising the error-builder path.
final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

/// The album does real disk I/O and image decoding, none of which is driven
/// by [WidgetTester.pump]'s fake clock — [WidgetTester.runAsync] steps out to
/// the real event loop so that work can finish.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 10; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_widget_test');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<void> writePhoto(
    WidgetTester tester,
    String name, {
    required DateTime modifiedAt,
  }) =>
      tester.runAsync(() async {
        final file = File('${temp.path}/$name');
        await file.writeAsBytes(_onePixelPng);
        await file.setLastModified(modifiedAt);
      });

  Widget app() => MaterialApp(home: ImageAlbum(path: temp.path));

  testWidgets('shows an empty state when the folder has no images',
      (tester) async {
    await tester.pumpWidget(app());
    await _settle(tester);

    expect(find.text('No photos'), findsOneWidget);
  });

  testWidgets('lists images grouped by day, newest first', (tester) async {
    final today = DateTime.now();
    final yesterday = today.subtract(const Duration(days: 1));

    await writePhoto(tester, 'A.JPG', modifiedAt: yesterday);
    await writePhoto(tester, 'B.JPG', modifiedAt: today);
    await writePhoto(tester, 'C.JPG.part', modifiedAt: today);

    await tester.pumpWidget(app());
    await _settle(tester);

    expect(find.text('Today'), findsOneWidget);
    expect(find.text('Yesterday'), findsOneWidget);
    expect(find.text('2 photos'), findsOneWidget);

    final todayY = tester.getTopLeft(find.text('Today')).dy;
    final yesterdayY = tester.getTopLeft(find.text('Yesterday')).dy;
    expect(todayY, lessThan(yesterdayY));
  });

  testWidgets('tapping a photo opens the full-screen swipe preview',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime.now());

    await tester.pumpWidget(app());
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);

    expect(find.text('1 / 1'), findsOneWidget);
    expect(find.text('A.JPG'), findsOneWidget);
  });

  testWidgets('the preview info button shows the photo details',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime(2026, 7, 30, 12));

    await tester.pumpWidget(app());
    await _settle(tester);

    await tester.tap(find.byType(Image).first);
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 400));

    await tester.tap(find.byTooltip('Photo info'));
    await tester.pump(const Duration(milliseconds: 400));
    await _settle(tester);

    expect(find.text('Size'), findsOneWidget);
    expect(find.text('1 × 1 (0.0 MP)'), findsOneWidget);
    expect(find.text('2026-07-30 12:00:00'), findsOneWidget);
    expect(find.text('Path'), findsOneWidget);
    expect(find.textContaining('A.JPG'), findsWidgets);
    expect(find.text('Focal length'), findsNothing);
  });

  testWidgets('long-press selects, and delete removes the file',
      (tester) async {
    await writePhoto(tester, 'A.JPG', modifiedAt: DateTime.now());

    await tester.pumpWidget(app());
    await _settle(tester);

    await tester.longPress(find.byType(Image).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    await tester.tap(find.byTooltip('Delete'));
    await _settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await _settle(tester);

    expect(find.text('No photos'), findsOneWidget);
    await tester.runAsync(() async {
      expect(File('${temp.path}/A.JPG').existsSync(), isFalse);
    });
  });
}
