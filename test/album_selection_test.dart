import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_widgets.dart';

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

/// Real file I/O needs the real event loop; see the same helper in
/// image_album_test.dart.
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
    temp = await Directory.systemTemp.createTemp('image_album_select_test');
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

  /// Opens an album of twelve photos from one day, newest first, so tile 0 is
  /// `P00`. The window is wide enough for them to fill two rows.
  Future<void> openAlbum(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await tester.runAsync(() async {
      for (var i = 0; i < 12; i++) {
        final name = 'P${i.toString().padLeft(2, '0')}.jpg';
        final file = File('${temp.path}/$name');
        await file.writeAsBytes(_onePixelPng);
        await file.setLastModified(DateTime(2026, 7, 30, 12, 59 - i));
      }
    });
    await tester.pumpWidget(MaterialApp(home: ImageAlbum(path: temp.path)));
    await _settle(tester);
  }

  Finder tile(int index) => find.byType(AlbumPhotoTile).at(index);
  Offset center(WidgetTester tester, int index) =>
      tester.getCenter(tile(index));

  Finder selectedCount(int n) => find.text('$n selected');

  Future<void> withKeys(
    WidgetTester tester,
    List<LogicalKeyboardKey> keys,
    Future<void> Function() body,
  ) async {
    for (final key in keys) {
      await tester.sendKeyDownEvent(key);
    }
    await body();
    for (final key in keys.reversed) {
      await tester.sendKeyUpEvent(key);
    }
  }

  group('keyboard', () {
    testWidgets('ctrl-click picks photos without opening them', (tester) async {
      await openAlbum(tester);

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await tester.tapAt(center(tester, 1));
        await tester.pump();
        await tester.tapAt(center(tester, 3));
        await tester.pump();
      });

      expect(selectedCount(2), findsOneWidget);
      expect(find.text('1 / 12'), findsNothing);

      // Ctrl-click on a picked photo unpicks it.
      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await tester.tapAt(center(tester, 1));
        await tester.pump();
      });
      expect(selectedCount(1), findsOneWidget);
    });

    testWidgets('shift-click picks the range from the last pick', (
      tester,
    ) async {
      await openAlbum(tester);

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await tester.tapAt(center(tester, 2));
        await tester.pump();
      });

      await withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await tester.tapAt(center(tester, 5));
        await tester.pump();
      });
      expect(selectedCount(4), findsOneWidget); // 2, 3, 4, 5

      // Shifting elsewhere re-aims the range from the same start, and
      // replaces the old range.
      await withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await tester.tapAt(center(tester, 0));
        await tester.pump();
      });
      expect(selectedCount(3), findsOneWidget); // 0, 1, 2

      // With ctrl as well, the old picks stay.
      await withKeys(
        tester,
        [LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft],
        () async {
          await tester.tapAt(center(tester, 8));
          await tester.pump();
        },
      );
      expect(selectedCount(9), findsOneWidget); // 0..2 plus 2..8
    });

    testWidgets('shift-click with nothing picked starts the range', (
      tester,
    ) async {
      await openAlbum(tester);

      await withKeys(tester, [LogicalKeyboardKey.shiftLeft], () async {
        await tester.tapAt(center(tester, 4));
        await tester.pump();
      });
      expect(selectedCount(1), findsOneWidget);
      expect(find.text('1 / 12'), findsNothing);
    });

    testWidgets('ctrl+A picks everything and escape lets go', (tester) async {
      await openAlbum(tester);

      await withKeys(tester, [LogicalKeyboardKey.controlLeft], () async {
        await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
        await tester.pump();
      });
      expect(selectedCount(12), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.textContaining('selected'), findsNothing);
    });
  });

  group('dragging', () {
    testWidgets('a mouse drag picks the tiles it crosses', (tester) async {
      await openAlbum(tester);

      final gesture = await tester.startGesture(
        center(tester, 1),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(center(tester, 2));
      await gesture.moveTo(center(tester, 4));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(selectedCount(4), findsOneWidget); // 1, 2, 3, 4
      // The release is not also a click on the last tile, which would have
      // unpicked it or opened it.
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(selectedCount(4), findsOneWidget);
      expect(find.text('5 / 12'), findsNothing);
    });

    testWidgets('a quick flick still gets the tiles in between', (
      tester,
    ) async {
      await openAlbum(tester);

      final gesture = await tester.startGesture(
        center(tester, 0),
        kind: PointerDeviceKind.mouse,
      );
      // One single jump of the pointer across five tiles.
      await gesture.moveTo(center(tester, 5));
      await gesture.up();
      await tester.pump();

      expect(selectedCount(6), findsOneWidget);
    });

    testWidgets('dragging across rows picks along the way', (tester) async {
      await openAlbum(tester);

      // The first tile of the second row is the first one lower than tile 0.
      final top = tester.getTopLeft(tile(0)).dy;
      var secondRow = 1;
      while (tester.getTopLeft(tile(secondRow)).dy <= top) {
        secondRow++;
      }

      final gesture = await tester.startGesture(
        center(tester, 0),
        kind: PointerDeviceKind.mouse,
      );
      // Straight down onto the tile below: nothing lies between them, and
      // nothing beside the line is picked.
      await gesture.moveTo(center(tester, secondRow));
      await gesture.up();
      await tester.pump();

      expect(selectedCount(2), findsOneWidget);
    });

    testWidgets('a small mouse move is still just a click', (tester) async {
      await openAlbum(tester);

      final gesture = await tester.startGesture(
        center(tester, 1),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(2, 0));
      await gesture.up();
      await _settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      // Nothing was picked: the click opened the photo.
      expect(find.textContaining('selected'), findsNothing);
      expect(find.text('2 / 12'), findsOneWidget);
    });

    testWidgets('dragging from a picked tile unpicks what it crosses', (
      tester,
    ) async {
      await openAlbum(tester);

      var gesture = await tester.startGesture(
        center(tester, 0),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(center(tester, 5));
      await gesture.up();
      await tester.pump();
      expect(selectedCount(6), findsOneWidget);

      gesture = await tester.startGesture(
        center(tester, 4),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveTo(center(tester, 2));
      await gesture.up();
      await tester.pump();

      expect(selectedCount(3), findsOneWidget); // 0, 1 and 5 are left
    });

    testWidgets('holding a finger on a tile, then moving, picks tiles', (
      tester,
    ) async {
      await openAlbum(tester);

      final gesture = await tester.startGesture(center(tester, 1));
      await tester.pump(const Duration(milliseconds: 700));
      expect(selectedCount(1), findsOneWidget);

      await gesture.moveTo(center(tester, 3));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(selectedCount(3), findsOneWidget); // 1, 2, 3
    });

    testWidgets('a mouse drag does not scroll the grid', (tester) async {
      await openAlbum(tester);

      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      final before = scrollable.position.pixels;

      final gesture = await tester.startGesture(
        center(tester, 1),
        kind: PointerDeviceKind.mouse,
      );
      await gesture.moveBy(const Offset(0, -60));
      await gesture.up();
      await tester.pump();

      expect(scrollable.position.pixels, before);
    });
  });
}
