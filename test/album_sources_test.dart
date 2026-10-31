import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:path/path.dart' as p;

AlbumPhoto _photo(String name, DateTime takenAt) =>
    AlbumPhoto(file: File(name), takenAt: takenAt);

void main() {
  group('mergeAlbumPhotos', () {
    test('keeps newest first across lists', () {
      final merged = mergeAlbumPhotos([
        [
          _photo('a1', DateTime(2026, 7, 30)),
          _photo('a2', DateTime(2026, 7, 1)),
        ],
        [_photo('b1', DateTime(2026, 7, 15))],
      ]);

      expect(merged.map((photo) => photo.id), ['a1', 'b1', 'a2']);
    });

    test('lists a photo once when two sources hold it', () {
      final shared = _photo('shared', DateTime(2026, 7, 10));
      final merged = mergeAlbumPhotos([
        [_photo('a', DateTime(2026, 7, 20)), shared],
        [shared, _photo('b', DateTime(2026, 7, 1))],
      ]);

      expect(merged.map((photo) => photo.id), ['a', 'shared', 'b']);
    });

    test('hands back a lone list as it is, and nothing for nothing', () {
      final only = [_photo('a', DateTime(2026, 7, 30))];

      expect(identical(mergeAlbumPhotos([only, const []]), only), true);
      expect(mergeAlbumPhotos(const []), isEmpty);
      expect(mergeAlbumPhotos([const [], const []]), isEmpty);
    });
  });

  group('several sources', () {
    late Directory temp;

    final onePixelPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
      'AAAAASUVORK5CYII=',
    );

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('image_album_sources_test');
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

    String dir(String name) => p.join(temp.path, name);

    /// Alpha has 2 photos, Beta 2, and Beta/Deep 1.
    Future<void> populate(WidgetTester tester) => tester.runAsync(() async {
      var minutes = 0;
      Future<void> write(String relative) async {
        final file = File(p.join(temp.path, relative));
        await file.create(recursive: true);
        await file.writeAsBytes(onePixelPng);
        await file.setLastModified(
          DateTime.now().subtract(Duration(minutes: minutes++)),
        );
      }

      await write(p.join('Alpha', 'a1.jpg'));
      await write(p.join('Beta', 'b1.jpg'));
      await write(p.join('Alpha', 'a2.jpg'));
      await write(p.join('Beta', 'b2.jpg'));
      await write(p.join('Beta', 'Deep', 'd1.jpg'));
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    void wide(WidgetTester tester) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
    }

    /// An album whose sources the test changes through [sources], the way an
    /// app would.
    Widget host(
      ValueNotifier<List<String>> sources, {
      VoidCallback? onAdd,
      ValueChanged<String>? onRemove,
      bool recursive = false,
    }) => MaterialApp(
      home: ValueListenableBuilder<List<String>>(
        valueListenable: sources,
        builder: (context, paths, _) => ImageAlbum(
          paths: paths,
          recursive: recursive,
          onAddSource: onAdd,
          onRemoveSource: onRemove,
        ),
      ),
    );

    testWidgets('shows the photos of every folder together', (tester) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Alpha'), dir('Beta')]);
      await tester.pumpWidget(host(sources, onAdd: () {}, onRemove: (_) {}));
      await settle(tester);

      expect(find.byType(Image), findsNWidgets(4));
      expect(find.text('4 photos'), findsWidgets);
      // Each source is the top of its own tree.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('a folder inside another source is counted once', (
      tester,
    ) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Beta'), dir('Beta/Deep')]);
      await tester.pumpWidget(host(sources, recursive: true));
      await settle(tester);

      expect(find.byType(Image), findsNWidgets(3));
    });

    testWidgets('a folder added later brings its photos in', (tester) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Alpha')]);
      await tester.pumpWidget(host(sources, onAdd: () {}));
      await settle(tester);
      expect(find.byType(Image), findsNWidgets(2));

      sources.value = [dir('Alpha'), dir('Beta')];
      await settle(tester);

      expect(find.byType(Image), findsNWidgets(4));
      expect(find.text('Beta'), findsOneWidget);
    });

    testWidgets('the add button asks the app for a folder', (tester) async {
      wide(tester);
      await populate(tester);
      var asked = 0;
      final sources = ValueNotifier([dir('Alpha')]);
      await tester.pumpWidget(host(sources, onAdd: () => asked++));
      await settle(tester);

      await tester.tap(find.byTooltip('Add folder'));
      await tester.pump();

      expect(asked, 1);
      // The album waits for the app to pass the new list in.
      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('the remove button reports the folder, and it leaves', (
      tester,
    ) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Alpha'), dir('Beta')]);
      final removed = <String>[];
      await tester.pumpWidget(
        host(
          sources,
          onRemove: (path) {
            removed.add(path);
            sources.value = [
              for (final source in sources.value)
                if (source != path) source,
            ];
          },
        ),
      );
      await settle(tester);
      expect(find.byTooltip('Remove folder'), findsNWidgets(2));

      await tester.tap(find.byTooltip('Remove folder').last);
      await settle(tester);

      expect(removed, [p.normalize(dir('Beta'))]);
      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('Beta'), findsNothing);
      expect(find.text('Alpha'), findsOneWidget);
    });

    testWidgets('without callbacks there are no add or remove buttons', (
      tester,
    ) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Alpha'), dir('Beta')]);
      await tester.pumpWidget(host(sources, recursive: true));
      await settle(tester);

      expect(find.byTooltip('Add folder'), findsNothing);
      expect(find.byTooltip('Remove folder'), findsNothing);
    });

    testWidgets('with every folder removed it invites adding one', (
      tester,
    ) async {
      wide(tester);
      await populate(tester);
      var asked = 0;
      final sources = ValueNotifier([dir('Alpha')]);
      await tester.pumpWidget(host(sources, onAdd: () => asked++));
      await settle(tester);

      sources.value = [];
      await settle(tester);

      expect(find.byType(Image), findsNothing);
      expect(find.text('No folders yet'), findsOneWidget);

      await tester.tap(find.text('Add folder'));
      expect(asked, 1);
    });

    testWidgets('a missing folder does not stop the others', (tester) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Gone'), dir('Alpha')]);
      await tester.pumpWidget(host(sources, onAdd: () {}));
      await settle(tester);

      expect(find.byType(Image), findsNWidgets(2));
    });

    testWidgets('folders with the same name are told apart', (tester) async {
      wide(tester);
      await tester.runAsync(() async {
        for (final parent in ['one', 'two']) {
          final file = File(p.join(temp.path, parent, 'Camera', 'x.jpg'));
          await file.create(recursive: true);
          await file.writeAsBytes(onePixelPng);
        }
      });
      final sources = ValueNotifier([
        p.join(dir('one'), 'Camera'),
        p.join(dir('two'), 'Camera'),
      ]);
      await tester.pumpWidget(host(sources, onAdd: () {}));
      await settle(tester);

      expect(find.text('Camera (one)'), findsOneWidget);
      expect(find.text('Camera (two)'), findsOneWidget);
    });

    testWidgets('hiding a folder in one source leaves the other alone', (
      tester,
    ) async {
      wide(tester);
      await populate(tester);
      final sources = ValueNotifier([dir('Alpha'), dir('Beta')]);
      await tester.pumpWidget(host(sources, recursive: true));
      await settle(tester);

      // Beta's tree starts open, with Deep in it. Hide just that.
      await tester.tap(find.text('Deep'));
      await tester.pump();

      expect(find.byType(Image), findsNWidgets(4));
      expect(find.text('4 photos · 1 hidden'), findsOneWidget);
    });
  });
}
