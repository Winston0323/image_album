import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_preview_page.dart';
import 'package:image_album/src/album_widgets.dart';

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

/// Steps through enough frames for any route or zoom animation to finish; the
/// first frame of an animation only starts its clock.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

void main() {
  group('albumDayLabels', () {
    final now = DateTime(2026, 10, 31, 15); // a Saturday

    test('says Today and Yesterday, with the date beside them', () {
      expect(albumDayLabels(DateTime(2026, 10, 31), now: now), (
        title: 'Today',
        subtitle: 'Sat, Oct 31',
      ));
      expect(albumDayLabels(DateTime(2026, 10, 30), now: now), (
        title: 'Yesterday',
        subtitle: 'Fri, Oct 30',
      ));
    });

    test('names the weekday for the rest of the past week', () {
      expect(albumDayLabels(DateTime(2026, 10, 28), now: now), (
        title: 'Wednesday',
        subtitle: 'Oct 28',
      ));
      expect(albumDayLabels(DateTime(2026, 10, 25), now: now).title, 'Sunday');
    });

    test(
      'shows the date for older days, and the year only when it differs',
      () {
        expect(albumDayLabels(DateTime(2026, 10, 24), now: now), (
          title: 'Oct 24',
          subtitle: 'Saturday',
        ));
        expect(albumDayLabels(DateTime(2025, 10, 24), now: now), (
          title: 'Oct 24, 2025',
          subtitle: 'Friday',
        ));
      },
    );

    test('counts days by calendar date, not by 24-hour spans', () {
      // 00:30 today is still "Today" even though the same time yesterday was
      // less than 24 hours ago.
      final justAfterMidnight = DateTime(2026, 10, 31, 0, 30);
      expect(
        albumDayLabels(DateTime(2026, 10, 30), now: justAfterMidnight).title,
        'Yesterday',
      );
    });
  });

  test('albumFormatCount groups thousands', () {
    expect(albumFormatCount(0), '0');
    expect(albumFormatCount(999), '999');
    expect(albumFormatCount(1000), '1,000');
    expect(albumFormatCount(12345), '12,345');
    expect(albumFormatCount(1234567), '1,234,567');
  });

  group('viewer', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('image_album_viewer_test');
    });

    tearDown(() async {
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          if (await temp.exists()) await temp.delete(recursive: true);
          return;
        } on FileSystemException {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      }
    });

    Future<void> open(WidgetTester tester, {int count = 3}) async {
      final photos = await tester.runAsync(
        () async => [
          for (var i = 0; i < count; i++)
            await () async {
              final file = File('${temp.path}/P$i.png');
              await file.writeAsBytes(_onePixelPng);
              return AlbumPhoto(
                file: file,
                takenAt: DateTime(2026, 7, 30, 12, i),
              );
            }(),
        ],
      );
      // 1000 wide, so the desktop-only side buttons are present.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 700);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        AlbumPreviewPage(photos: photos!, initialIndex: 0),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pump(const Duration(milliseconds: 400));
    }

    double barOpacity(WidgetTester tester) => tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.text('1 / 3'),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;

    testWidgets('shows the file name and a readable date under the photo', (
      tester,
    ) async {
      await open(tester);

      expect(find.text('1 / 3'), findsOneWidget);
      expect(find.text('P0.png'), findsOneWidget);
      expect(find.text('Jul 30, 2026 · 12:00'), findsOneWidget);
    });

    testWidgets('tapping the photo hides the bars, and again shows them', (
      tester,
    ) async {
      await open(tester);
      expect(barOpacity(tester), 1);

      await tester.tapAt(const Offset(500, 350));
      await _frames(tester);
      expect(barOpacity(tester), 0);

      await tester.tapAt(const Offset(500, 350));
      await _frames(tester);
      expect(barOpacity(tester), 1);
    });

    testWidgets('arrow keys move between photos', (tester) async {
      await open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(find.text('2 / 3'), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await _frames(tester);
      expect(find.text('1 / 3'), findsOneWidget);
    });

    testWidgets('the side buttons move between photos too', (tester) async {
      await open(tester);

      await tester.tap(find.byTooltip('Next photo'));
      await _frames(tester);
      expect(find.text('2 / 3'), findsOneWidget);
    });

    testWidgets('Escape closes the viewer', (tester) async {
      await open(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await _frames(tester);

      expect(find.text('1 / 3'), findsNothing);
      expect(find.text('open'), findsOneWidget);
    });

    testWidgets('double-tap zooms in, and double-tap again zooms out', (
      tester,
    ) async {
      await open(tester);
      TransformationController transform() => tester
          .widget<InteractiveViewer>(find.byType(InteractiveViewer))
          .transformationController!;

      expect(transform().value.getMaxScaleOnAxis(), closeTo(1, 1e-6));

      Future<void> doubleTap() async {
        await tester.tapAt(const Offset(300, 200));
        await tester.pump(const Duration(milliseconds: 60));
        await tester.tapAt(const Offset(300, 200));
        await _frames(tester);
      }

      await doubleTap();
      expect(transform().value.getMaxScaleOnAxis(), greaterThan(2));

      await doubleTap();
      expect(transform().value.getMaxScaleOnAxis(), closeTo(1, 1e-6));
    });

    testWidgets('swiping is locked while zoomed in', (tester) async {
      await open(tester);

      await tester.tapAt(const Offset(300, 200));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(const Offset(300, 200));
      await _frames(tester);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await _frames(tester);
      expect(find.text('1 / 3'), findsOneWidget);
    });
  });
}
