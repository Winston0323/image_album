import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show kSecondaryMouseButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_camera.dart';
import 'package:image_album/src/album_widgets.dart';
import 'package:path/path.dart' as p;

final List<int> _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

AlbumPhoto _photo(String path, {int minute = 0}) =>
    AlbumPhoto(file: File(path), takenAt: DateTime(2026, 10, 30, 12, minute));

void main() {
  group('albumFolderName', () {
    test('keeps spaces and drops characters Windows forbids', () {
      expect(albumFolderName('  Trip: one/two  '), 'Trip one two');
    });

    test('refuses a reserved name', () {
      expect(albumFolderName('con'), '');
      expect(albumFolderName('...'), '');
    });
  });

  group('albumGroupCameraShots', () {
    test('pairs a picture and a raw that share a name, on any card', () {
      final shots = albumGroupCameraShots([
        _photo(r'D:\DCIM\100MSDCF\DSC0001.ARW'),
        _photo(r'E:\DCIM\100MSDCF\DSC0001.JPG'),
        _photo(r'E:\DCIM\100MSDCF\DSC0002.JPG', minute: 1),
      ]);

      expect(shots, hasLength(2));
      final pair = shots.firstWhere((shot) => shot.name == 'DSC0001');
      expect(pair.paired, isTrue);
      expect(pair.picture!.file.path, endsWith('.JPG'));
      expect(pair.raw!.file.path, endsWith('.ARW'));
      expect(pair.display.file.path, endsWith('.JPG'));
      expect(
        shots.firstWhere((shot) => shot.name == 'DSC0002').paired,
        isFalse,
      );
    });

    test('pairs two files that are already on the same card', () {
      final shots = albumGroupCameraShots([
        _photo(r'D:\DCIM\100MSDCF\DSC0003.JPG'),
        _photo(r'D:\DCIM\100MSDCF\DSC0003.ARW'),
      ]);

      expect(shots.single.paired, isTrue);
    });

    test('two pictures with one name stay two shots', () {
      final shots = albumGroupCameraShots([
        _photo(r'D:\DCIM\a.JPG'),
        _photo(r'E:\DCIM\a.JPG'),
      ]);

      expect(shots, hasLength(2));
      expect(shots.every((shot) => shot.paired), isFalse);
    });

    test('the kind chooses which files are copied', () {
      final shot = albumGroupCameraShots([
        _photo('a.JPG'),
        _photo('a.ARW'),
      ]).single;

      expect(shot.filesFor(AlbumImportKind.both), hasLength(2));
      expect(
        shot.filesFor(AlbumImportKind.raw).single.file.path,
        endsWith('.ARW'),
      );
      expect(
        shot.filesFor(AlbumImportKind.jpeg).single.file.path,
        endsWith('.JPG'),
      );
      expect(
        albumGroupCameraShots([
          _photo('b.JPG'),
        ]).single.filesFor(AlbumImportKind.raw),
        isEmpty,
      );
    });
  });

  group('albumCameraFolders', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('image_album_cards');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'reads DCIM\\100MSDCF and a later shot folder, not DCIM itself',
      () async {
        await Directory(
          p.join(root.path, 'card', 'DCIM', '100MSDCF'),
        ).create(recursive: true);
        await Directory(
          p.join(root.path, 'card', 'DCIM', '101MSDCF'),
        ).create(recursive: true);
        await Directory(
          p.join(root.path, 'card', 'DCIM', 'PRIVATE'),
        ).create(recursive: true);
        await Directory(p.join(root.path, 'settings')).create();

        final folders = await albumCameraFolders([
          p.join(root.path, 'card'),
          p.join(root.path, 'settings'),
        ]);

        expect(folders.reading, [
          p.join(root.path, 'card', 'DCIM', '100MSDCF'),
          p.join(root.path, 'card', 'DCIM', '101MSDCF'),
        ]);
        expect(folders.silent, isEmpty);
      },
    );

    test('a drive is named by its letter, a folder by its own name', () {
      expect(albumCardLabel(r'D:\'), 'D:');
      expect(albumCardLabel(r'D:\DCIM\100MSDCF'), 'D:');
      expect(albumCardLabel(p.join(root.path, 'Holiday')), 'Holiday');
    });

    test('a chosen folder of photos is that folder', () async {
      final folder = Directory(p.join(root.path, 'Holiday'))..createSync();
      File(p.join(folder.path, 'A.JPG')).writeAsBytesSync([1]);

      expect(await albumImportTargets(folder.path), [p.normalize(folder.path)]);
    });

    test('a chosen card root still finds 100MSDCF', () async {
      final shot = Directory(p.join(root.path, 'card', 'DCIM', '100MSDCF'));
      await shot.create(recursive: true);
      await File(p.join(shot.path, 'A.ARW')).writeAsBytes([1]);

      expect(await albumImportTargets(p.join(root.path, 'card')), [
        p.normalize(shot.path),
      ]);
      expect(await albumImportTargets(p.join(root.path, 'card', 'DCIM')), [
        p.normalize(shot.path),
      ]);
    });

    test('a drive without DCIM is left out, and one with it is kept', () async {
      final withDcim = Directory(p.join(root.path, 'card', 'DCIM', '100MSDCF'));
      await withDcim.create(recursive: true);
      final plain = Directory(p.join(root.path, 'settings'))..createSync();

      final kept = await albumDriveIfDcim(p.join(root.path, 'card'));
      final skipped = await albumDriveIfDcim(plain.path);

      expect(kept?.root, p.normalize(p.join(root.path, 'card')));
      expect(kept?.name, isEmpty);
      expect(skipped, isNull);
    });

    test('lists the files sitting in 100MSDCF', () async {
      final shot = Directory(p.join(root.path, 'card', 'DCIM', '100MSDCF'));
      await shot.create(recursive: true);
      await File(p.join(shot.path, 'A.JPG')).writeAsBytes([1]);
      await File(p.join(shot.path, 'A.ARW')).writeAsBytes([2]);

      final folders = await albumCameraFolders([p.join(root.path, 'card')]);
      final shots = await albumLoadCameraShots(folders.reading);

      expect(folders.reading, [shot.path]);
      expect(shots, hasLength(1));
      expect(shots.single.paired, isTrue);
    });
  });

  group('albumCopyShots', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('image_album_copy');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    AlbumCameraShot pair() {
      final jpg = File(p.join(root.path, 'card', 'DSC0001.JPG'));
      final arw = File(p.join(root.path, 'card', 'DSC0001.ARW'));
      jpg.createSync(recursive: true);
      jpg.writeAsBytesSync(_png);
      arw.writeAsBytesSync([1, 2, 3, 4]);
      return albumGroupCameraShots([_photo(jpg.path), _photo(arw.path)]).single;
    }

    test('copies both files, and leaves them on the card', () async {
      final shot = pair();
      final dest = p.join(root.path, 'out');

      final result = await albumCopyShots(
        shots: [shot],
        kind: AlbumImportKind.both,
        destination: dest,
      );

      expect(result.copied, 2);
      expect(result.deleted, 0);
      expect(result.errors, isEmpty);
      expect(File(p.join(dest, 'DSC0001.JPG')).readAsBytesSync(), _png);
      expect(File(shot.raw!.file.path).existsSync(), isTrue);
    });

    test('raw only copies the raw, and jpeg only the picture', () async {
      final dest = p.join(root.path, 'out');

      final raw = await albumCopyShots(
        shots: [pair()],
        kind: AlbumImportKind.raw,
        destination: dest,
      );
      expect(raw.copied, 1);
      expect(File(p.join(dest, 'DSC0001.ARW')).existsSync(), isTrue);
      expect(File(p.join(dest, 'DSC0001.JPG')).existsSync(), isFalse);

      final jpeg = await albumCopyShots(
        shots: [pair()],
        kind: AlbumImportKind.jpeg,
        destination: p.join(root.path, 'out2'),
      );
      expect(jpeg.copied, 1);
      expect(
        File(p.join(root.path, 'out2', 'DSC0001.JPG')).existsSync(),
        isTrue,
      );
    });

    test('a shot with nothing of the kind is skipped', () async {
      final jpg = File(p.join(root.path, 'only.JPG'))..writeAsBytesSync(_png);
      final shot = albumGroupCameraShots([_photo(jpg.path)]).single;

      final result = await albumCopyShots(
        shots: [shot],
        kind: AlbumImportKind.raw,
        destination: p.join(root.path, 'out'),
      );

      expect(result.copied, 0);
      expect(result.skipped, 1);
    });

    test('deletes the original only after the copy is the same size', () async {
      final shot = pair();

      final result = await albumCopyShots(
        shots: [shot],
        kind: AlbumImportKind.both,
        destination: p.join(root.path, 'out'),
        deleteAfter: true,
      );

      expect(result.copied, 2);
      expect(result.deleted, 2);
      expect(shot.picture!.file.existsSync(), isFalse);
      expect(shot.raw!.file.existsSync(), isFalse);
    });

    test('a file already there is left, and its original stays', () async {
      final shot = pair();
      final dest = Directory(p.join(root.path, 'out'))..createSync();
      File(p.join(dest.path, 'DSC0001.JPG')).writeAsBytesSync([9]);

      final result = await albumCopyShots(
        shots: [shot],
        kind: AlbumImportKind.both,
        destination: dest.path,
        deleteAfter: true,
      );

      expect(result.copied, 1);
      expect(result.errors.single, contains('DSC0001.JPG'));
      expect(File(p.join(dest.path, 'DSC0001.JPG')).readAsBytesSync(), [9]);
      expect(shot.picture!.file.existsSync(), isTrue);
      expect(shot.raw!.file.existsSync(), isFalse);
    });

    test('stops between files when asked', () async {
      final shot = pair();
      var seen = 0;

      final result = await albumCopyShots(
        shots: [shot],
        kind: AlbumImportKind.both,
        destination: p.join(root.path, 'out'),
        cancelled: () => seen++ > 0,
      );

      expect(result.stopped, isTrue);
      expect(result.copied, 1);
    });
  });

  group('importing from the folder menu', () {
    late Directory album;
    late Directory cards;

    setUp(() async {
      album = await Directory.systemTemp.createTemp('image_album_import_ui');
      cards = await Directory.systemTemp.createTemp('image_album_import_cards');
      await File(p.join(album.path, 'keep.jpg')).writeAsBytes(_png);
      Future<void> shot(String card, String name, List<int> bytes) async {
        final file = File(p.join(cards.path, card, 'DCIM', '100MSDCF', name));
        await file.create(recursive: true);
        await file.writeAsBytes(bytes);
      }

      await shot('rawcard', 'DSC0001.ARW', [1, 2, 3, 4]);
      await shot('jpgcard', 'DSC0001.JPG', _png);
      await shot('jpgcard', 'DSC0002.JPG', _png);
    });

    tearDown(() async {
      for (final dir in [album, cards]) {
        Object? locked;
        for (var attempt = 0; attempt < 25; attempt++) {
          try {
            if (await dir.exists()) await dir.delete(recursive: true);
            locked = null;
            break;
          } on FileSystemException catch (error) {
            locked = error;
            await Future<void>.delayed(const Duration(milliseconds: 40));
          }
        }
        if (locked != null) throw locked;
      }
    });

    Future<void> settle(WidgetTester tester) async {
      for (var i = 0; i < 15; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 30)),
        );
        await tester.pump();
      }
    }

    /// Real file listing finishes on the real clock. A long single pump would
    /// trip the card's answer timeout while a folder is open, so the clock
    /// only moves a little at a time.
    Future<void> waitUntilRead(WidgetTester tester) async {
      for (var i = 0; i < 80; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        final still = find.textContaining('still reading');
        final summary = find.textContaining('1 with both');
        if (still.evaluate().isEmpty && summary.evaluate().isNotEmpty) {
          for (var n = 0; n < 8; n++) {
            await tester.runAsync(
              () => Future<void>.delayed(const Duration(milliseconds: 40)),
            );
            await tester.pump();
          }
          return;
        }
      }
      fail(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((text) => text.data)
            .join(' | '),
      );
    }

    Future<void> open(WidgetTester tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1200, 900);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: ImageAlbum(
            path: album.path,
            recursive: true,
            cameraCards: () async => [
              p.join(cards.path, 'rawcard'),
              p.join(cards.path, 'jpgcard'),
            ],
          ),
        ),
      );
      await settle(tester);
    }

    testWidgets('asks for a folder, then shows one tile per shot', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(
        find.text(p.basename(album.path)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from camera…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));

      expect(find.text('Drives'), findsOneWidget);
      expect(find.text('Folder name'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Holiday');
      await waitUntilRead(tester);

      expect(find.text('Import into "Holiday"'), findsOneWidget);
      expect(find.textContaining('2 cards'), findsOneWidget);
      expect(find.textContaining('1 with both'), findsOneWidget);
      // The pair is one tile, and the lone JPEG another.
      expect(find.byType(AlbumPhotoTile), findsNWidgets(2));
    });

    testWidgets('the preview lists the shot\'s files at its top right', (
      tester,
    ) async {
      await open(tester);
      await tester.tap(
        find.text(p.basename(album.path)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from camera…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await waitUntilRead(tester);

      // Newest first is not guaranteed between the two; the pair's tile shows
      // the JPEG, so open the preview and look for both labels.
      await tester.tap(find.byType(AlbumPhotoTile).first);
      await tester.pumpAndSettle();
      if (find.text('ARW').evaluate().isEmpty) {
        await tester.tap(find.byIcon(Icons.chevron_right_rounded));
        await tester.pumpAndSettle();
      }

      expect(find.text('JPG'), findsOneWidget);
      expect(find.text('ARW'), findsOneWidget);
      expect(find.text('DSC0001.JPG'), findsOneWidget);

      await tester.tap(find.text('ARW'));
      await tester.pumpAndSettle();
      expect(find.text('DSC0001.ARW'), findsOneWidget);
    });

    testWidgets('copies the chosen kind into the new folder', (tester) async {
      await open(tester);
      await tester.tap(
        find.text(p.basename(album.path)),
        buttons: kSecondaryMouseButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import from camera…'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.enterText(find.byType(TextField), 'Holiday');
      await waitUntilRead(tester);

      await tester.tap(find.text('RAW'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete from the camera after copying'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Copy and delete'));
      await settle(tester);
      await tester.pumpAndSettle();

      final dest = Directory(p.join(album.path, 'Holiday'));
      expect(dest.existsSync(), isTrue);
      expect(dest.listSync().map((e) => p.basename(e.path)).toList(), [
        'DSC0001.ARW',
      ]);
      expect(
        File(
          p.join(cards.path, 'rawcard', 'DCIM', '100MSDCF', 'DSC0001.ARW'),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(cards.path, 'jpgcard', 'DCIM', '100MSDCF', 'DSC0001.JPG'),
        ).existsSync(),
        isTrue,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      for (var n = 0; n < 8; n++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 40)),
        );
        await tester.pump();
      }
    });
  });
}
