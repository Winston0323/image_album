import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_folders.dart';
import 'package:path/path.dart' as p;

final String _root = p.join('library', 'album');

AlbumPhoto _photoIn(String folder, String name) => AlbumPhoto(
  file: File(p.join(_root, folder, name)),
  takenAt: DateTime(2026, 7, 30),
);

/// Two photos in the root, Trips holds one itself plus Paris (2) and Rome (1),
/// and Pets holds three.
List<AlbumPhoto> _photos() => [
  _photoIn('', 'r1.jpg'),
  _photoIn('', 'r2.jpg'),
  _photoIn('Trips', 't1.jpg'),
  _photoIn(p.join('Trips', 'Paris'), 'p1.jpg'),
  _photoIn(p.join('Trips', 'Paris'), 'p2.jpg'),
  _photoIn(p.join('Trips', 'Rome'), 'o1.jpg'),
  _photoIn('Pets', 'a.jpg'),
  _photoIn('Pets', 'b.jpg'),
  _photoIn('Pets', 'c.jpg'),
];

String _path(String folder) => p.normalize(p.join(_root, folder));

void main() {
  group('buildAlbumFolderTree', () {
    test('counts photos directly in a folder and below it', () {
      final root = buildAlbumFolderTree(_photos(), _root);

      expect(root.name, 'album');
      expect(root.directCount, 2);
      expect(root.totalCount, 9);
      expect(root.children.map((c) => c.name), ['Pets', 'Trips']);

      final trips = root.children.last;
      expect(trips.directCount, 1);
      expect(trips.totalCount, 4);
      expect(trips.children.map((c) => c.name), ['Paris', 'Rome']);
      expect(trips.children.first.depth, 2);
      expect(trips.children.first.parent, trips);
    });

    test('sorts siblings by name regardless of case', () {
      final root = buildAlbumFolderTree([
        _photoIn('beta', 'a.jpg'),
        _photoIn('Alpha', 'a.jpg'),
        _photoIn('Gamma', 'a.jpg'),
      ], _root);

      expect(root.children.map((c) => c.name), ['Alpha', 'beta', 'Gamma']);
    });

    test('lists a folder that only has photos further down', () {
      final root = buildAlbumFolderTree([
        _photoIn(p.join('a', 'b', 'c'), 'x.jpg'),
      ], _root);

      final a = root.children.single;
      expect(a.directCount, 0);
      expect(a.totalCount, 1);
      expect(a.children.single.children.single.name, 'c');
    });

    test('is just the root when there are no photos', () {
      final root = buildAlbumFolderTree(const [], _root);

      expect(root.children, isEmpty);
      expect(root.totalCount, 0);
    });
  });

  group('filterAlbumByExcluded', () {
    test('returns the same list when nothing is excluded', () {
      final photos = _photos();

      expect(identical(filterAlbumByExcluded(photos, _root, {}), photos), true);
    });

    test('removes a folder and everything below it, keeping order', () {
      final photos = _photos();
      final kept = filterAlbumByExcluded(photos, _root, {_path('Trips')});

      expect(kept.map((photo) => photo.fileName), [
        'r1.jpg',
        'r2.jpg',
        'a.jpg',
        'b.jpg',
        'c.jpg',
      ]);
    });

    test('removes only the named subfolder', () {
      final kept = filterAlbumByExcluded(_photos(), _root, {
        _path(p.join('Trips', 'Paris')),
      });

      expect(kept, hasLength(7));
      expect(kept.map((photo) => photo.fileName), contains('t1.jpg'));
      expect(kept.map((photo) => photo.fileName), isNot(contains('p1.jpg')));
    });

    test('hides everything when the root itself is excluded', () {
      expect(filterAlbumByExcluded(_photos(), _root, {_path('')}), isEmpty);
    });

    test('accepts paths that are not normalized', () {
      final kept = filterAlbumByExcluded(_photos(), _root, {
        p.join(_root, 'Pets', '..', 'Pets'),
      });

      expect(kept, hasLength(6));
    });
  });

  group('albumFolderStates', () {
    final root = buildAlbumFolderTree(_photos(), _root);

    test('everything is included by default', () {
      final states = albumFolderStates(root, {});

      expect(states.values.toSet(), {AlbumFolderState.included});
    });

    test(
      'an excluded folder hides below it and marks the way down partial',
      () {
        final states = albumFolderStates(root, {
          _path(p.join('Trips', 'Paris')),
        });

        expect(
          states[_path(p.join('Trips', 'Paris'))],
          AlbumFolderState.excluded,
        );
        expect(
          states[_path(p.join('Trips', 'Rome'))],
          AlbumFolderState.included,
        );
        expect(states[_path('Trips')], AlbumFolderState.partial);
        expect(states[_path('')], AlbumFolderState.partial);
        expect(states[_path('Pets')], AlbumFolderState.included);
      },
    );

    test('children of an excluded folder are excluded too', () {
      final states = albumFolderStates(root, {_path('Trips')});

      expect(states[_path('Trips')], AlbumFolderState.excluded);
      expect(states[_path(p.join('Trips', 'Rome'))], AlbumFolderState.excluded);
    });
  });

  group('albumToggleFolder', () {
    final root = buildAlbumFolderTree(_photos(), _root);
    AlbumFolderNode node(String folder) {
      var current = root;
      if (folder.isEmpty) return current;
      for (final part in p.split(folder)) {
        current = current.children.firstWhere((c) => c.name == part);
      }
      return current;
    }

    Set<String> toggle(String folder, Set<String> excluded) {
      final states = albumFolderStates(root, excluded);
      final target = node(folder);
      return albumToggleFolder(target, excluded, states[target.path]!);
    }

    test('hides a shown folder', () {
      expect(toggle('Pets', {}), {_path('Pets')});
    });

    test('a partly shown folder becomes fully shown', () {
      final next = toggle('Trips', {
        _path(p.join('Trips', 'Paris')),
        _path('Pets'),
      });

      expect(next, {_path('Pets')});
    });

    test('shows a hidden folder again', () {
      expect(toggle('Pets', {_path('Pets')}), isEmpty);
    });

    test('showing a folder under a hidden one keeps its relatives hidden', () {
      final next = toggle(p.join('Trips', 'Rome'), {_path('Trips')});

      // Trips is no longer hidden as a whole. Paris takes over; Rome is back.
      expect(next, {_path(p.join('Trips', 'Paris'))});
      expect(
        filterAlbumByExcluded(_photos(), _root, next).map((a) => a.fileName),
        containsAll(['t1.jpg', 'o1.jpg', 'a.jpg', 'r1.jpg']),
      );
    });

    test('showing a deep folder under a hidden root spreads the exclusion', () {
      final next = toggle(p.join('Trips', 'Rome'), {_path('')});

      expect(next, {_path('Pets'), _path(p.join('Trips', 'Paris'))});
      final kept = filterAlbumByExcluded(_photos(), _root, next);
      // Rome, Trips' own photo and the root's photos stay visible.
      expect(kept.map((a) => a.fileName).toSet(), {
        'o1.jpg',
        't1.jpg',
        'r1.jpg',
        'r2.jpg',
      });
    });
  });

  group('folders in the album', () {
    late Directory temp;

    final onePixelPng = base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
      'AAAAASUVORK5CYII=',
    );

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('image_album_folder_test');
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

    /// Root has 1 photo, Pets 2, Trips/Paris 1. Spread over time so the order
    /// is stable.
    Future<void> populate(WidgetTester tester) => tester.runAsync(() async {
      Future<void> write(String relative, int minutesAgo) async {
        final file = File(p.join(temp.path, relative));
        await file.create(recursive: true);
        await file.writeAsBytes(onePixelPng);
        await file.setLastModified(
          DateTime.now().subtract(Duration(minutes: minutesAgo)),
        );
      }

      await write('root.jpg', 1);
      await write(p.join('Pets', 'a.jpg'), 2);
      await write(p.join('Pets', 'b.jpg'), 3);
      await write(p.join('Trips', 'Paris', 'p.jpg'), 4);
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump();
      }
    }

    void sizeWindow(WidgetTester tester, Size size) {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.reset);
    }

    Widget app({
      bool recursive = true,
      Set<String> excluded = const {},
      ValueChanged<Set<String>>? onChanged,
    }) => MaterialApp(
      home: ImageAlbum(
        path: temp.path,
        recursive: recursive,
        initialExcludedFolders: excluded,
        onExcludedFoldersChanged: onChanged,
      ),
    );

    testWidgets('a wide window shows the tree beside the grid', (tester) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      expect(find.text('Folders'), findsOneWidget);
      expect(find.text('Pets'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget);
      // Only the album's own folder is open at first.
      expect(find.text('Paris'), findsNothing);
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('unticking a folder hides its photos and reports it', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      final reported = <Set<String>>[];
      await tester.pumpWidget(app(onChanged: reported.add));
      await settle(tester);

      await tester.tap(find.text('Pets'));
      await tester.pump();

      expect(find.byType(Image), findsNWidgets(2));
      expect(find.text('2 photos · 2 hidden'), findsOneWidget);
      expect(find.text('2 of 4 photos shown'), findsOneWidget);
      expect(reported.single, {p.normalize(p.join(temp.path, 'Pets'))});

      await tester.tap(find.text('Show all'));
      await tester.pump();

      expect(find.byType(Image), findsNWidgets(4));
      expect(reported.last, isEmpty);
    });

    testWidgets('opens with the folders it was told to hide', (tester) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app(excluded: {p.join(temp.path, 'Trips')}));
      await settle(tester);

      expect(find.byType(Image), findsNWidgets(3));
      expect(find.text('3 photos · 1 hidden'), findsOneWidget);
    });

    testWidgets('a folder can be opened to reach its subfolders', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      await tester.tap(find.byIcon(Icons.chevron_right_rounded));
      await tester.pump();

      expect(find.text('Paris'), findsOneWidget);
    });

    testWidgets('hiding every folder offers a way back', (tester) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app(excluded: {temp.path}));
      await settle(tester);

      expect(find.text('All folders are hidden'), findsOneWidget);

      await tester.tap(find.text('Show all folders'));
      await tester.pump();

      expect(find.text('All folders are hidden'), findsNothing);
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('a narrow window opens the tree from the bar', (tester) async {
      sizeWindow(tester, const Size(500, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      expect(find.text('Pets'), findsNothing);

      await tester.tap(find.byTooltip('Folders'));
      await tester.pumpAndSettle();
      expect(find.text('Pets'), findsOneWidget);

      await tester.tap(find.text('Pets'));
      await tester.pumpAndSettle();
      // The sheet is still open and shows the new state.
      expect(find.text('2 of 4 photos shown'), findsOneWidget);

      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Pets'), findsNothing);
      expect(find.text('2 photos · 2 hidden'), findsOneWidget);
    });

    testWidgets('larger text grows the rows instead of clipping them', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(1.6)),
            child: child!,
          ),
          home: ImageAlbum(path: temp.path, recursive: true),
        ),
      );
      await settle(tester);

      // Nothing overflowed while laying out, and the rows are taller than at
      // the default size, with room for the larger name.
      expect(tester.takeException(), isNull);
      final row = find.ancestor(
        of: find.text('Pets'),
        matching: find.byType(InkWell),
      );
      expect(tester.getSize(row.first).height, greaterThan(40 * 1.5));
      final header = find.ancestor(
        of: find.text('Today'),
        matching: find.byType(SizedBox),
      );
      expect(tester.getSize(header.first).height, greaterThan(48));
    });

    testWidgets('has no folder tree unless subfolders are included', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app(recursive: false));
      await settle(tester);

      expect(find.byTooltip('Folders'), findsNothing);
      expect(find.text('Folders'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
