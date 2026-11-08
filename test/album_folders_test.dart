import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_folders.dart';
import 'package:image_album/src/album_preview_page.dart';
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

    /// Opens the source row so the albums under it are visible. The tree
    /// starts collapsed.
    Future<void> expandRoot(WidgetTester tester) async {
      final chevron = find.descendant(
        of: find.byType(AlbumFolderPanel),
        matching: find.byIcon(Icons.chevron_right_rounded),
      );
      if (chevron.evaluate().isEmpty) return;
      await tester.tap(chevron.first);
      await tester.pumpAndSettle();
    }

    /// The checkbox on the row of the folder called [name].
    Finder checkboxOf(String name) => find.descendant(
      of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)),
      matching: find.byType(Checkbox),
    );

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
      // The source starts collapsed: albums are hidden until it is opened.
      expect(find.text('Pets'), findsNothing);
      expect(find.text('Trips'), findsNothing);

      await expandRoot(tester);
      expect(find.text('Pets'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget);
      // Albums stay collapsed: Paris is under Trips.
      expect(find.text('Paris'), findsNothing);
      expect(find.byType(Image), findsNWidgets(4));
    });

    testWidgets('the tree sits on the left, the grid to its right', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      final bar = tester.getRect(find.byTooltip('Digital'));
      final panel = tester.getRect(find.byType(AlbumFolderPanel));
      expect(panel.left, bar.right);
      expect(panel.width, 300);
      expect(
        tester.getTopLeft(find.byType(Image).first).dx,
        greaterThan(panel.right - 1),
      );
    });

    testWidgets('closing the tree slides it away rather than jumping', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      await tester.tap(find.byTooltip('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Part way: still there, but its edge has moved in from where it was.
      // The panel keeps its width and is clipped, so it is the edge that moves.
      final barRight = tester.getRect(find.byTooltip('Digital')).right;
      final edge = tester.getRect(find.byType(AlbumFolderPanel)).right;
      expect(edge, inExclusiveRange(barRight, barRight + 300));

      await tester.pumpAndSettle();
      expect(find.byType(AlbumFolderPanel), findsNothing);

      // And it comes back the same way from the bar.
      await tester.tap(find.byTooltip('Digital'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(AlbumFolderPanel), findsOneWidget);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byType(AlbumFolderPanel)).right,
        tester.getRect(find.byTooltip('Digital')).right + 300,
      );
    });

    testWidgets('Tab folds the tree away and brings it back', (tester) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);
      expect(find.byType(AlbumFolderPanel), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumFolderPanel), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumFolderPanel), findsOneWidget);
    });

    testWidgets('Tab works with a photo open beside the tree', (tester) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);
      await tester.tap(find.byType(Image).first);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlbumPreviewPage), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();

      expect(find.byType(AlbumFolderPanel), findsNothing);
      // The photo is still open, and now has the room.
      expect(find.byType(AlbumPreviewPage), findsOneWidget);
      expect(
        tester.getRect(find.byType(AlbumPreviewPage)).left,
        tester.getRect(find.byTooltip('Digital')).right,
      );
    });

    testWidgets('a photo opens beside the tree, which stays until closed', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      await tester.pumpWidget(app());
      await settle(tester);

      // The second photo is in Pets, which holds two.
      await tester.tap(find.byType(Image).at(1));
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 400));

      // The viewer is open, and the tree is still there to its left.
      expect(find.textContaining(' / 2'), findsOneWidget);
      expect(find.byType(AlbumFolderPanel), findsOneWidget);
      final panel = tester.getRect(find.byType(AlbumFolderPanel));
      final viewer = tester.getRect(find.byType(AlbumPreviewPage));
      expect(panel.left, tester.getRect(find.byTooltip('Digital')).right);
      expect(viewer.left, greaterThanOrEqualTo(panel.right));
      expect(viewer.right, 1200);

      // Zooming does not push the viewer over the tree.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byType(PageView));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(AlbumFolderPanel), findsOneWidget);

      // Closing the viewer leaves the tree open.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(AlbumPreviewPage), findsNothing);
      expect(find.byType(AlbumFolderPanel), findsOneWidget);
    });

    group('the folder menu', () {
      Widget withConfirm(List<(String, int)> asked, {bool answer = true}) =>
          MaterialApp(
            home: ImageAlbum(
              path: temp.path,
              recursive: true,
              confirmDeleteFolder: (context, name, count) async {
                asked.add((name, count));
                return answer;
              },
            ),
          );

      Future<void> openMenu(WidgetTester tester, String folder) async {
        await tester.tap(find.text(folder), buttons: kSecondaryMouseButton);
        await tester.pumpAndSettle();
      }

      testWidgets('a right click opens it, with a way to delete', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');

        expect(find.text('Show only this folder'), findsOneWidget);
        expect(find.text('Delete folder…'), findsOneWidget);
        // A menu, not a click: nothing was narrowed or ticked.
        expect(find.byType(Image), findsNWidgets(4));
      });

      testWidgets('so does the button on the row', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.byTooltip('Folder options').at(1));
        await tester.pumpAndSettle();

        expect(find.text('Delete folder…'), findsOneWidget);
      });

      testWidgets('and so does a long press', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.longPress(find.text('Pets'));
        await tester.pumpAndSettle();

        expect(find.text('Delete folder…'), findsOneWidget);
      });

      testWidgets('the source itself cannot be deleted from it', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, p.basename(temp.path));

        expect(find.text('Show only this folder'), findsOneWidget);
        expect(find.text('Delete folder…'), findsNothing);
      });

      testWidgets('its first entry narrows the album', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Show only this folder'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(2));
        // And on the folder it is narrowed to, it offers the way back.
        await openMenu(tester, 'Pets');
        expect(find.text('Show the whole album'), findsOneWidget);
      });

      testWidgets('deleting asks first, and No leaves everything', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final asked = <(String, int)>[];
        await tester.pumpWidget(withConfirm(asked, answer: false));
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Delete folder…'));
        await settle(tester);

        expect(asked, [('Pets', 2)]);
        expect(find.byType(Image), findsNWidgets(4));
        expect(Directory(p.join(temp.path, 'Pets')).existsSync(), isTrue);
      });

      testWidgets('Yes deletes its photos and the folder', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final asked = <(String, int)>[];
        await tester.pumpWidget(withConfirm(asked));
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Delete folder…'));
        await settle(tester);
        await settle(tester);

        expect(asked, [('Pets', 2)]);
        expect(find.byType(Image), findsNWidgets(2));
        expect(find.text('Pets'), findsNothing);
        expect(Directory(p.join(temp.path, 'Pets')).existsSync(), isFalse);
        expect(File(p.join(temp.path, 'root.jpg')).existsSync(), isTrue);
      });

      testWidgets('a folder takes the ones inside it along', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final asked = <(String, int)>[];
        await tester.pumpWidget(withConfirm(asked));
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Trips');
        await tester.tap(find.text('Delete folder…'));
        await settle(tester);
        await settle(tester);

        // Paris was the only photo in Trips.
        expect(asked, [('Trips', 1)]);
        expect(Directory(p.join(temp.path, 'Trips')).existsSync(), isFalse);
      });

      testWidgets('a folder with something else in it stays', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.runAsync(
          () => File(p.join(temp.path, 'Pets', 'notes.txt')).writeAsString('x'),
        );
        await tester.pumpWidget(withConfirm([]));
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Delete folder…'));
        await settle(tester);
        await settle(tester);

        expect(File(p.join(temp.path, 'Pets', 'a.jpg')).existsSync(), isFalse);
        expect(
          File(p.join(temp.path, 'Pets', 'notes.txt')).existsSync(),
          isTrue,
        );
        expect(find.byType(Image), findsNWidgets(2));
      });

      Set<String> namesIn(String relative) => Directory(
        p.join(temp.path, relative),
      ).listSync().whereType<File>().map((f) => p.basename(f.path)).toSet();

      testWidgets('Show in Explorer opens the folder', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final shown = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: ImageAlbum(
              path: temp.path,
              recursive: true,
              revealFolder: (path) async => shown.add(path),
            ),
          ),
        );
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Show in Explorer'));
        await tester.pumpAndSettle();

        expect(shown.map(p.normalize), [p.join(temp.path, 'Pets')]);
        // Only looked at: nothing was narrowed.
        expect(find.byType(Image), findsNWidgets(4));
      });

      testWidgets('the source row can be shown too', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final shown = <String>[];
        await tester.pumpWidget(
          MaterialApp(
            home: ImageAlbum(
              path: temp.path,
              recursive: true,
              revealFolder: (path) async => shown.add(path),
            ),
          ),
        );
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, p.basename(temp.path));
        await tester.tap(find.text('Show in Explorer'));
        await tester.pumpAndSettle();

        expect(shown.map(p.normalize), [p.normalize(temp.path)]);
      });

      testWidgets('a folder that cannot be opened is reported', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(
          MaterialApp(
            home: ImageAlbum(
              path: temp.path,
              recursive: true,
              revealFolder: (path) async =>
                  throw const FileSystemException('no'),
            ),
          ),
        );
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Show in Explorer'));
        await tester.pump();
        await tester.pump();

        expect(
          find.textContaining('Could not open the folder'),
          findsOneWidget,
        );
      });

      testWidgets('renaming offers a name, and numbers the images', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        expect(find.text('Rename images…'), findsOneWidget);
        await tester.tap(find.text('Rename images…'));
        await tester.pumpAndSettle();

        // The folder's own name is the starting point, and there is nothing
        // below Pets to choose about.
        expect(find.widgetWithText(TextField, 'Pets'), findsOneWidget);
        expect(find.text('Include the folders inside'), findsNothing);

        await tester.enterText(find.byType(TextField), 'cat');
        await tester.pump();
        expect(find.textContaining('cat_001.jpg'), findsOneWidget);
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await settle(tester);
        await settle(tester);

        expect(namesIn('Pets'), {'cat_001.jpg', 'cat_002.jpg'});
        expect(File(p.join(temp.path, 'root.jpg')).existsSync(), isTrue);
      });

      testWidgets('cancelling changes nothing', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Rename images…'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();

        expect(namesIn('Pets'), {'a.jpg', 'b.jpg'});
      });

      testWidgets('the folders inside are left alone unless asked for', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        // Trips holds nothing itself, only Paris with one photo.
        await openMenu(tester, 'Trips');
        await tester.tap(find.text('Rename images…'));
        await tester.pumpAndSettle();

        expect(find.text('Include the folders inside'), findsOneWidget);
        expect(find.text('There are no images to rename.'), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Rename'))
              .onPressed,
          isNull,
        );

        await tester.tap(find.text('Include the folders inside'));
        await tester.pump();
        expect(
          tester
              .widget<FilledButton>(find.widgetWithText(FilledButton, 'Rename'))
              .onPressed,
          isNotNull,
        );
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await settle(tester);
        await settle(tester);

        expect(namesIn(p.join('Trips', 'Paris')), {'Trips_001.jpg'});
      });

      testWidgets('without that choice a folder keeps what is inside it', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.runAsync(() async {
          await File(
            p.join(temp.path, 'Pets', 'deep', 'd.jpg'),
          ).create(recursive: true);
          await File(
            p.join(temp.path, 'Pets', 'deep', 'd.jpg'),
          ).writeAsBytes(onePixelPng);
        });
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Rename images…'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), 'cat');
        await tester.tap(find.text('Rename'));
        await tester.pumpAndSettle();
        await settle(tester);
        await settle(tester);

        expect(namesIn('Pets'), {'cat_001.jpg', 'cat_002.jpg'});
        expect(namesIn(p.join('Pets', 'deep')), {'d.jpg'});
      });

      testWidgets('deleting the folder it is narrowed to widens it', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(withConfirm([]));
        await settle(tester);
        await expandRoot(tester);
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        await openMenu(tester, 'Pets');
        await tester.tap(find.text('Delete folder…'));
        await settle(tester);
        await settle(tester);

        expect(find.byType(InputChip), findsNothing);
        expect(find.byType(Image), findsNWidgets(2));
      });
    });

    group('narrowing the album to one folder', () {
      /// Whether the row of [name] is filled with any colour. Clicking an
      /// album shades that folder; a photo shades its own folder instead.
      bool filled(WidgetTester tester, String name) {
        final scheme = Theme.of(
          tester.element(find.byType(AlbumFolderPanel)),
        ).colorScheme;
        return tester
            .widgetList<Material>(
              find.ancestor(
                of: find.text(name),
                matching: find.byType(Material),
              ),
            )
            .any(
              (material) =>
                  material.color == scheme.primaryContainer ||
                  material.color == scheme.secondaryContainer,
            );
      }

      Finder chip() => find.byType(InputChip);

      testWidgets('clicking a folder shows only its photos', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        expect(chip(), findsNothing);

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(2));
        expect(filled(tester, 'Pets'), isTrue);
        expect(filled(tester, 'Trips'), isFalse);
        // The rest is set aside, not hidden: no checkbox changed.
        expect(find.text('2 photos'), findsOneWidget);
        expect(find.text('4 photos'), findsOneWidget); // the panel's total
        expect(chip(), findsOneWidget);
        expect(find.textContaining('Pets · 2 photos'), findsOneWidget);
      });

      testWidgets('a folder takes its subfolders along', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNWidgets(1));
      });

      testWidgets('the cross on the chip leaves it', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Show the whole album'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(4));
        expect(chip(), findsNothing);
        expect(filled(tester, 'Pets'), isFalse);
      });

      testWidgets('Escape leaves it', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(4));
        expect(chip(), findsNothing);
      });

      testWidgets('clicking the same folder again leaves it', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(4));
        expect(chip(), findsNothing);
      });

      testWidgets('another folder replaces the first', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(1));
        expect(filled(tester, 'Trips'), isTrue);
        expect(filled(tester, 'Pets'), isFalse);
      });

      testWidgets('the source row means the whole album', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        await tester.tap(find.text(p.basename(temp.path)));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(4));
        expect(chip(), findsNothing);
      });

      testWidgets('the preview holds just what the grid shows', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        // Narrowed to the source's root nothing changes; narrowed to Pets the
        // two photos are all there is to page through.
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(Image).first);
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.textContaining('1 / 2'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        // Escape closed the photo only; the album is still narrowed.
        expect(find.byType(AlbumPreviewPage), findsNothing);
        expect(chip(), findsOneWidget);
      });

      testWidgets('clicking a hidden folder brings it back first', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app(excluded: {p.join(temp.path, 'Pets')}));
        await settle(tester);
        await expandRoot(tester);
        expect(find.byType(Image), findsNWidgets(2));

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        expect(find.byType(Image), findsNWidgets(2));
        expect(filled(tester, 'Pets'), isTrue);
        expect(find.text('4 photos'), findsOneWidget);
      });

      testWidgets('hiding the folder it is narrowed to widens it', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        await tester.tap(checkboxOf('Pets'));
        await tester.pumpAndSettle();

        expect(chip(), findsNothing);
        expect(find.byType(Image), findsNWidgets(2)); // Pets hidden, rest shown
      });

      testWidgets(
        'on a narrow window the sheet closes once a folder is picked',
        (tester) async {
          sizeWindow(tester, const Size(500, 900));
          await populate(tester);
          await tester.pumpWidget(app());
          await settle(tester);

          await tester.tap(find.byTooltip('Digital'));
          await tester.pumpAndSettle();
          await expandRoot(tester);
          await tester.tap(find.text('Pets'));
          await tester.pumpAndSettle();

          // The sheet closes so the album is what is on screen.
          expect(find.text('Folders'), findsNothing);
          expect(find.byType(Image), findsNWidgets(2));
          expect(chip(), findsOneWidget);
        },
      );
    });

    group('albums are the folders one level under the source', () {
      Future<void> open(WidgetTester tester, int index) async {
        await tester.tap(find.byType(Image).at(index));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
      }

      testWidgets('the preview holds only the album of the photo', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);

        // Newest first: root, Pets/a, Pets/b, Trips/Paris/p.
        await open(tester, 1);
        expect(find.textContaining('1 / 2'), findsOneWidget);

        // The last of Pets is the end: the next photo in the grid is in Trips.
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(find.textContaining('2 / 2'), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(find.textContaining('2 / 2'), findsOneWidget);
      });

      testWidgets('a deeper folder belongs to its album', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);

        // Trips/Paris is part of the Trips album, which holds only it.
        await open(tester, 3);
        expect(find.textContaining('1 / 1'), findsOneWidget);
      });

      testWidgets('photos lying in the source itself are an album', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);

        await open(tester, 0);
        expect(find.textContaining('1 / 1'), findsOneWidget);
      });

      testWidgets('each source has its own albums', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        final other = await tester.runAsync(() async {
          final dir = await Directory.systemTemp.createTemp(
            'image_album_other',
          );
          final file = File(p.join(dir.path, 'Pets', 'z.jpg'));
          await file.create(recursive: true);
          await file.writeAsBytes(onePixelPng);
          await file.setLastModified(
            DateTime.now().subtract(const Duration(minutes: 30)),
          );
          return dir;
        });
        addTearDown(() async {
          try {
            await other!.delete(recursive: true);
          } on FileSystemException {
            // Left for the system to clear.
          }
        });
        await tester.pumpWidget(
          MaterialApp(
            home: ImageAlbum(paths: [temp.path, other!.path], recursive: true),
          ),
        );
        await settle(tester);

        // A Pets folder in each source: still two separate albums.
        await open(tester, 1);
        expect(find.textContaining('1 / 2'), findsOneWidget);
      });
    });

    group('one album is open at a time', () {
      Future<void> populateDeeper(WidgetTester tester) async {
        await populate(tester);
        await tester.runAsync(() async {
          final file = File(p.join(temp.path, 'Pets', 'Cats', 'c.jpg'));
          await file.create(recursive: true);
          await file.writeAsBytes(onePixelPng);
        });
      }

      testWidgets('clicking an album opens it', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populateDeeper(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);
        expect(find.text('Cats'), findsNothing);

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();

        expect(find.text('Cats'), findsOneWidget);
        // Only that one: the other album stays shut.
        expect(find.text('Paris'), findsNothing);
      });

      testWidgets('and folds the album that was open', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populateDeeper(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Pets'));
        await tester.pumpAndSettle();
        expect(find.text('Cats'), findsOneWidget);

        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();

        expect(find.text('Paris'), findsOneWidget);
        expect(find.text('Cats'), findsNothing);
        // Folded, not gone: its own row is still there to click.
        expect(find.text('Pets'), findsOneWidget);
      });

      testWidgets('a folder deeper in an album keeps its album open', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populateDeeper(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();
        expect(find.text('Paris'), findsOneWidget);

        // Opening a folder by its arrow, as before, is left to the user.
        await tester.tap(find.byIcon(Icons.chevron_right_rounded).first);
        await tester.pumpAndSettle();
        expect(find.text('Cats'), findsOneWidget);
        expect(find.text('Paris'), findsOneWidget);
      });

      testWidgets('clicking a photo folds the other albums too', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populateDeeper(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();
        expect(find.text('Paris'), findsOneWidget);

        // Back to the whole album, which leaves the tree as it is.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.text('Paris'), findsOneWidget);

        // Pets/a is the second photo, newest first.
        await tester.tap(find.byType(Image).at(1));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();

        expect(find.text('Paris'), findsNothing);
      });
    });

    group('the folder of the clicked photo', () {
      bool marked(WidgetTester tester, String name) {
        final shade = Theme.of(
          tester.element(find.byType(AlbumFolderPanel)),
        ).colorScheme.secondaryContainer;
        return tester
            .widgetList<Material>(
              find.ancestor(
                of: find.text(name),
                matching: find.byType(Material),
              ),
            )
            .any((material) => material.color == shade);
      }

      Future<void> open(WidgetTester tester, int index) async {
        await tester.tap(find.byType(Image).at(index));
        await settle(tester);
        await tester.pump(const Duration(milliseconds: 400));
      }

      testWidgets('is marked in the tree', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        // Nothing is marked before a click.
        expect(marked(tester, 'Pets'), isFalse);
        expect(marked(tester, 'Trips'), isFalse);

        // The grid runs newest first: root, Pets/a, Pets/b, Trips/Paris/p.
        await open(tester, 1);
        expect(marked(tester, 'Pets'), isTrue);
        expect(marked(tester, 'Trips'), isFalse);
        expect(marked(tester, p.basename(temp.path)), isFalse);
      });

      testWidgets('opens the folders above it', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        expect(find.text('Paris'), findsNothing);

        await open(tester, 3);
        await tester.pumpAndSettle();

        expect(find.text('Paris'), findsOneWidget);
        expect(marked(tester, 'Paris'), isTrue);
        expect(marked(tester, 'Trips'), isFalse);
      });

      testWidgets('follows the preview from photo to photo', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        // Pets is an album of a, b and the deeper c.
        await tester.runAsync(() async {
          final file = File(p.join(temp.path, 'Pets', 'Cats', 'c.jpg'));
          await file.create(recursive: true);
          await file.writeAsBytes(onePixelPng);
          await file.setLastModified(
            DateTime.now().subtract(const Duration(minutes: 10)),
          );
        });
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        // Newest first: root, Pets/a, Pets/b, Trips/Paris/p, Pets/Cats/c.
        await open(tester, 1);
        expect(marked(tester, 'Pets'), isTrue);
        expect(marked(tester, 'Cats'), isFalse);

        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        await tester.sendKeyEvent(LogicalKeyboardKey.pageDown);
        await tester.pumpAndSettle();
        expect(find.textContaining('3 / 3'), findsOneWidget);
        expect(marked(tester, 'Cats'), isTrue);
        expect(marked(tester, 'Pets'), isFalse);
      });

      testWidgets('is unmarked once the preview closes', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        await open(tester, 1);
        expect(marked(tester, 'Pets'), isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();

        expect(find.byType(AlbumPreviewPage), findsNothing);
        expect(marked(tester, 'Pets'), isFalse);
      });

      testWidgets('is unmarked once a full-screen preview closes', (
        tester,
      ) async {
        // Too narrow for the tree beside the grid: the preview is a page.
        sizeWindow(tester, const Size(500, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);

        await open(tester, 1);
        await tester.pumpAndSettle();
        expect(find.byType(AlbumPreviewPage), findsOneWidget);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlbumPreviewPage), findsNothing);

        // The tree, opened from the bar, has nothing marked.
        await tester.tap(find.byTooltip('Digital'));
        await tester.pumpAndSettle();
        expect(marked(tester, 'Pets'), isFalse);
      });

      testWidgets('picking a photo marks nothing', (tester) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.tap(find.byType(Image).at(1));
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(find.byType(AlbumPreviewPage), findsNothing);
        expect(marked(tester, 'Pets'), isFalse);
      });

      testWidgets('the waterfall marks no folder, narrowed or not', (
        tester,
      ) async {
        sizeWindow(tester, const Size(1200, 900));
        await populate(tester);
        await tester.pumpWidget(app());
        await settle(tester);
        await expandRoot(tester);

        // Narrowed to Trips, whose one photo is in Paris below it: that
        // album's row is the one marked.
        await tester.tap(find.text('Trips'));
        await tester.pumpAndSettle();
        expect(find.byType(Image), findsNWidgets(1));
        expect(marked(tester, 'Trips'), isTrue);
        expect(marked(tester, 'Paris'), isFalse);

        // A photo open in the preview marks its folder, and only that one.
        await open(tester, 0);
        await tester.pumpAndSettle();
        expect(marked(tester, 'Paris'), isTrue);
        expect(marked(tester, 'Trips'), isFalse);

        // The photo is closed; the album is still narrowed, so its folder
        // stays marked.
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pumpAndSettle();
        expect(find.byType(AlbumPreviewPage), findsNothing);
        expect(marked(tester, 'Paris'), isFalse);
        expect(marked(tester, 'Trips'), isTrue);
      });
    });

    testWidgets('unticking a folder hides its photos and reports it', (
      tester,
    ) async {
      sizeWindow(tester, const Size(1200, 900));
      await populate(tester);
      final reported = <Set<String>>[];
      await tester.pumpWidget(app(onChanged: reported.add));
      await settle(tester);
      await expandRoot(tester);

      await tester.tap(checkboxOf('Pets'));
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

      await expandRoot(tester);
      // Trips is the album with a subfolder.
      await tester.tap(find.text('Trips'));
      await tester.pumpAndSettle();

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

      await tester.tap(find.byTooltip('Digital'));
      await tester.pumpAndSettle();
      await expandRoot(tester);
      expect(find.text('Pets'), findsOneWidget);

      await tester.tap(checkboxOf('Pets'));
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
      await expandRoot(tester);

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

      expect(find.byTooltip('Digital'), findsNothing);
      expect(find.text('Folders'), findsNothing);
      expect(find.byType(Image), findsOneWidget);
    });
  });
}
