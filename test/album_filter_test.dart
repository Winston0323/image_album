import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
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
    temp = await Directory.systemTemp.createTemp('image_album_filter_test');
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

  /// Writes the named files, newest first in the order given.
  Future<void> write(WidgetTester tester, List<String> names) =>
      tester.runAsync(() async {
        for (var i = 0; i < names.length; i++) {
          final file = File('${temp.path}/${names[i]}');
          await file.writeAsBytes(_onePixelPng);
          await file.setLastModified(DateTime(2026, 7, 30, 12, 59 - i));
        }
      });

  Future<void> open(
    WidgetTester tester, {
    Set<String> initial = const {},
    ValueChanged<Set<String>>? onChanged,
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 800);
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: ImageAlbum(
          path: temp.path,
          initialFileTypes: initial,
          onFileTypesChanged: onChanged,
        ),
      ),
    );
    await _settle(tester);
  }

  int tiles(WidgetTester tester) =>
      find.byType(AlbumPhotoTile).evaluate().length;

  final dropdown = find.byKey(const ValueKey('albumTypeFilter'));

  /// The text on the drop-down button: what is shown now.
  String current(WidgetTester tester) => tester
      .widget<Text>(
        find.descendant(of: dropdown, matching: find.byType(Text)).first,
      )
      .data!;

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
  }

  /// The menu entry of a type, ticking or unticking it.
  Future<void> tapChip(WidgetTester tester, String label) async {
    if (find.byType(CheckboxMenuButton).evaluate().isEmpty) {
      await openMenu(tester);
    }
    await tester.tap(find.widgetWithText(CheckboxMenuButton, label));
    await _settle(tester);
    await tester.pumpAndSettle();
  }

  bool ticked(WidgetTester tester, String label) => tester
      .widget<CheckboxMenuButton>(
        find.widgetWithText(CheckboxMenuButton, label),
      )
      .value!;

  testWidgets('a mixed folder gets one drop-down, with a count per type', (
    tester,
  ) async {
    await write(tester, ['a.jpg', 'b.JPEG', 'c.png', 'd.gif']);
    await open(tester);

    expect(dropdown, findsOneWidget);
    expect(current(tester), 'All types · 4');
    // No row of chips any more.
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);

    await openMenu(tester);
    expect(find.widgetWithText(CheckboxMenuButton, 'All types · 4'), findsOne);
    expect(find.widgetWithText(CheckboxMenuButton, 'GIF · 1'), findsOneWidget);
    expect(find.widgetWithText(CheckboxMenuButton, 'JPG · 2'), findsOneWidget);
    expect(find.widgetWithText(CheckboxMenuButton, 'PNG · 1'), findsOneWidget);
    expect(tiles(tester), 4);
  });

  testWidgets('a folder of one type shows that type in the drop-down', (
    tester,
  ) async {
    await write(tester, ['a.jpg', 'b.jpeg']);
    await open(tester);

    expect(dropdown, findsOneWidget);
    expect(current(tester), 'JPG · 2');
    expect(tiles(tester), 2);

    // Its menu lists just that type.
    await openMenu(tester);
    expect(find.widgetWithText(CheckboxMenuButton, 'JPG · 2'), findsOneWidget);
    expect(find.byType(CheckboxMenuButton), findsNWidgets(2));
  });

  testWidgets('picking a type shows only that type', (tester) async {
    await write(tester, ['a.jpg', 'b.jpeg', 'c.png', 'd.gif']);
    final reported = <Set<String>>[];
    await open(tester, onChanged: reported.add);

    await tapChip(tester, 'JPG · 2');

    expect(tiles(tester), 2);
    expect(find.text('2 photos · 2 hidden'), findsOneWidget);
    expect(reported.last, {'JPG'});
  });

  testWidgets('several types can be picked together', (tester) async {
    await write(tester, ['a.jpg', 'b.jpeg', 'c.png', 'd.gif']);
    final reported = <Set<String>>[];
    await open(tester, onChanged: reported.add);

    await tapChip(tester, 'JPG · 2');
    await tapChip(tester, 'PNG · 1');
    expect(tiles(tester), 3);
    expect(reported.last, {'JPG', 'PNG'});

    // Picking one again takes it back out.
    await tapChip(tester, 'JPG · 2');
    expect(tiles(tester), 1);
    expect(reported.last, {'PNG'});
  });

  testWidgets('the All chip clears the filter', (tester) async {
    await write(tester, ['a.jpg', 'b.png', 'c.gif']);
    final reported = <Set<String>>[];
    await open(tester, onChanged: reported.add);

    await tapChip(tester, 'PNG · 1');
    expect(tiles(tester), 1);

    expect(current(tester), 'PNG · 1');
    await tester.tap(find.widgetWithText(CheckboxMenuButton, 'All types · 3'));
    await _settle(tester);
    await tester.pumpAndSettle();
    expect(tiles(tester), 3);
    expect(reported.last, isEmpty);
    expect(current(tester), 'All types · 3');
    // Choosing it closes the menu.
    expect(find.byType(CheckboxMenuButton), findsNothing);
  });

  testWidgets('the drop-down names every type picked', (tester) async {
    await write(tester, ['a.jpg', 'b.jpeg', 'c.png', 'd.gif']);
    await open(tester);

    await tapChip(tester, 'JPG · 2');
    expect(current(tester), 'JPG · 2');
    await tapChip(tester, 'PNG · 1');
    expect(current(tester), 'JPG, PNG · 3');

    // The menu stayed open between the two picks, and shows what is ticked.
    expect(ticked(tester, 'JPG · 2'), isTrue);
    expect(ticked(tester, 'PNG · 1'), isTrue);
    expect(ticked(tester, 'GIF · 1'), isFalse);
    expect(ticked(tester, 'All types · 4'), isFalse);
  });

  testWidgets('the filter the album opens with is applied', (tester) async {
    await write(tester, ['a.jpg', 'b.png', 'c.gif']);
    await open(tester, initial: {'png'});

    expect(tiles(tester), 1);
    expect(current(tester), 'PNG · 1');
    await openMenu(tester);
    expect(ticked(tester, 'PNG · 1'), isTrue);
  });

  testWidgets('a type with no photos says so and offers a way out', (
    tester,
  ) async {
    await write(tester, ['a.jpg', 'b.png']);
    final reported = <Set<String>>[];
    await open(tester, initial: {'GIF'}, onChanged: reported.add);

    expect(find.text('No photos of this type'), findsOneWidget);
    expect(find.text('None of the photos here are GIF.'), findsOneWidget);

    await tester.tap(find.text('Show all types'));
    await _settle(tester);

    expect(tiles(tester), 2);
    expect(reported.last, isEmpty);
  });

  testWidgets('changing the filter drops hidden photos from the selection', (
    tester,
  ) async {
    await write(tester, ['a.jpg', 'b.png', 'c.jpg']);
    await open(tester);

    await tester.longPress(find.byType(AlbumPhotoTile).first);
    await tester.pump();
    expect(find.text('1 selected'), findsOneWidget);

    // The first tile is a.jpg, so showing only PNG takes it off screen, and
    // out of the selection: it cannot be deleted unseen.
    await tapChip(tester, 'PNG · 1');
    expect(find.textContaining('selected'), findsNothing);
    expect(tiles(tester), 1);
  });
}
