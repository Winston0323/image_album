import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_films.dart';
import 'package:image_album/src/album_folders.dart';
import 'package:image_album/src/album_shared_gear.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a folder name uses the same film box as ApertureDiary', () {
    expect(
      albumFilmIconAsset('Kodak Portra 400'),
      'assets/films/portra-400.png',
    );
    expect(albumFilmIconAsset('portra-400'), 'assets/films/portra-400.png');
    expect(albumFilmIconAsset('HP5'), 'assets/films/hp5-400.png');
    expect(albumFilmIconAsset('something else'), isNull);
  });

  test('a film kind folder is brand, series, then the film', () {
    expect(albumFilmFolderName('Kodak Gold 200'), 'KODAK_GOLD_200');
    expect(albumFilmFolderName('Kodak Ultramax 400'), 'KODAK_ULTRAMAX_400');
    expect(
      albumFilmFolderName('Kodak Vision3 250D (5207)'),
      'KODAK_VISION3_5207',
    );
    expect(albumFilmFolderName('Ilford HP5 Plus'), 'ILFORD_HP5_PLUS');
    expect(albumFilmFolderName('Fujifilm 200'), 'FUJIFILM_200');
  });

  test('film locations are known before the rolls are opened', () async {
    final root = await Directory.systemTemp.createTemp('album_film_places');
    addTearDown(() => root.delete(recursive: true));
    await Directory(p.join(root.path, 'KODAK_PORTRA_400')).create();
    final cleared = Directory(p.join(root.path, 'KODAK_GOLD_200'));
    await cleared.create();
    await albumSetFilmFolderCleared(cleared.path, true);

    final places = await listAlbumFilmPlaces(root.path);

    expect(places.map((film) => film.name), ['Kodak Portra 400']);
    expect(places.single.rolls, isEmpty);
  });

  test('a matching folder is renamed to the film kind', () async {
    final root = await Directory.systemTemp.createTemp('album_film_rename');
    addTearDown(() => root.delete(recursive: true));
    await Directory(p.join(root.path, 'Gold 200')).create();
    await Directory(p.join(root.path, 'KODAK_ULTRAMAX_400')).create();
    await Directory(p.join(root.path, 'notes')).create();

    await albumRenameMatchedFilmFolders(root.path);

    expect(
      await Directory(p.join(root.path, 'KODAK_GOLD_200')).exists(),
      isTrue,
    );
    expect(await Directory(p.join(root.path, 'Gold 200')).exists(), isFalse);
    expect(
      await Directory(p.join(root.path, 'KODAK_ULTRAMAX_400')).exists(),
      isTrue,
    );
    expect(await Directory(p.join(root.path, 'notes')).exists(), isTrue);
  });

  test('a cleared Portra 800 folder can become Portra 400', () async {
    final root = await Directory.systemTemp.createTemp('album_film_redirect');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory(p.join(root.path, 'KODAK_PORTRA_800'));
    await folder.create();
    await albumSetFilmFolderCleared(folder.path, true);
    final kind = albumFilmKinds.firstWhere(
      (film) => film.folderName == 'KODAK_PORTRA_400',
    );

    final placed = await albumPlaceFilmFolder(
      folder: folder.path,
      kind: kind,
      libraryRoot: root.path,
    );

    expect(p.basename(placed!), 'KODAK_PORTRA_400');
    expect(await albumFilmFolderIsCleared(placed), isFalse);
    expect(await Directory(folder.path).exists(), isFalse);
    final films = await scanAlbumFilms(root.path);
    expect(films.single.name, 'Kodak Portra 400');
  });

  test('Portra 400 keeps the folder Windows will not rename', () async {
    final root = await Directory.systemTemp.createTemp('album_film_keep');
    addTearDown(() => root.delete(recursive: true));
    final chosen = Directory(p.join(root.path, 'portra scans'));
    await chosen.create();
    await File(p.join(root.path, 'KODAK_PORTRA_400')).writeAsBytes([1]);
    final kind = albumFilmKinds.firstWhere(
      (item) => item.iconKey == 'portra-400',
    );

    final placed = await albumPlaceFilmFolder(
      folder: chosen.path,
      kind: kind,
      libraryRoot: root.path,
    );

    expect(p.normalize(placed!), p.normalize(chosen.path));
    final films = await scanAlbumFilms(root.path);
    expect(films.single.name, 'Kodak Portra 400');
    expect(p.basename(films.single.path), 'portra scans');
  });

  test('a folder Windows will not rename can still be Portra 400', () async {
    final root = await Directory.systemTemp.createTemp('album_film_link');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory(p.join(root.path, 'KODAK_PORTRA_800'));
    await folder.create();
    await albumSetFilmLink(root.path, 'portra-400', folder.path);

    final films = await scanAlbumFilms(root.path);

    expect(films, hasLength(1));
    expect(films.single.name, 'Kodak Portra 400');
    expect(films.single.path, p.normalize(folder.path));
  });

  test('a hidden film file can be updated', () async {
    final folder = await Directory.systemTemp.createTemp('album_hidden_meta');
    addTearDown(() => folder.delete(recursive: true));
    await albumSetFilmFolderCleared(folder.path, true);
    final file = File(p.join(folder.path, albumFilmMetaName));
    if (Platform.isWindows) {
      final hidden = await Process.run('attrib', ['+h', file.path]);
      expect(hidden.exitCode, 0);
    }

    await albumSetFilmFolderCleared(folder.path, false);

    expect(await albumFilmFolderIsCleared(folder.path), isFalse);
  });

  test('a cleared film folder stays on disk and leaves the list', () async {
    final root = await Directory.systemTemp.createTemp('album_film_clear');
    addTearDown(() => root.delete(recursive: true));
    final folder = Directory(p.join(root.path, 'KODAK_GOLD_200'));
    await folder.create();
    await albumSetFilmFolderCleared(folder.path, true);

    final films = await scanAlbumFilms(root.path);

    expect(films, isEmpty);
    expect(await folder.exists(), isTrue);
  });

  test(
    'a roll sits under its film, and a hidden file names the format',
    () async {
      final root = await Directory.systemTemp.createTemp('album_films');
      addTearDown(() => root.delete(recursive: true));
      final tokyo = Directory(p.join(root.path, 'Kodak Portra 400', 'tokyo'));
      final summer = Directory(p.join(root.path, 'Kodak Portra 400', 'summer'));
      await tokyo.create(recursive: true);
      await summer.create(recursive: true);
      await writeAlbumFilmFormat(tokyo.path, '135');
      await writeAlbumFilmFormat(summer.path, '120');
      await Directory(
        p.join(root.path, 'Kodak Portra 400', 'notes'),
      ).create(recursive: true);
      await File(
        p.join(root.path, 'Kodak Portra 400', 'loose.jpg'),
      ).writeAsBytes([0]);
      final unset = Directory(p.join(root.path, 'Kodak Portra 400', 'unset'));
      await unset.create(recursive: true);
      await File(p.join(unset.path, 'frame.jpg')).writeAsBytes([0]);

      final films = await scanAlbumFilms(root.path);

      expect(films, hasLength(1));
      expect(films.single.name, 'Kodak Portra 400');
      expect(films.single.iconAsset, 'assets/films/portra-400.png');
      expect(films.single.rolls.map((roll) => '${roll.format} ${roll.name}'), [
        ' unset',
      ]);
      expect(
        await readAlbumFilmFormat(
          p.join(root.path, 'KODAK_PORTRA_400', 'tokyo'),
        ),
        '135',
      );
      expect(
        jsonDecode(
          await File(
            p.join(root.path, 'KODAK_PORTRA_400', 'tokyo', albumFilmMetaName),
          ).readAsString(),
        ),
        {'format': '135'},
      );
    },
  );

  test('an empty 120 or 135 folder is not a roll', () async {
    final root = await Directory.systemTemp.createTemp('album_films_superia');
    addTearDown(() => root.delete(recursive: true));
    final film = Directory(p.join(root.path, 'Holiday'));
    await Directory(p.join(film.path, '120')).create(recursive: true);
    final kept = Directory(p.join(film.path, '135', 'kept'));
    await kept.create(recursive: true);
    await File(p.join(kept.path, 'frame.jpg')).writeAsBytes([0]);

    final films = await scanAlbumFilms(root.path);
    final tree = await buildAlbumDirectoryTree(film.path, filmHeader: true);

    expect(films.single.hasPictures, isTrue);
    expect(films.single.rolls.map((roll) => roll.name), ['kept']);
    expect(tree.children.map((node) => node.name), ['135']);
    expect(tree.children.single.children.map((node) => node.name), ['kept']);
  });

  test('an older 135 or 120 folder writes the format onto each roll', () async {
    final root = await Directory.systemTemp.createTemp('album_films_old');
    addTearDown(() => root.delete(recursive: true));
    final tokyo = Directory(
      p.join(root.path, 'Kodak Portra 400', '135', 'tokyo'),
    );
    await tokyo.create(recursive: true);
    await File(p.join(tokyo.path, 'frame.jpg')).writeAsBytes([0]);
    final summer = Directory(
      p.join(root.path, 'Kodak Portra 400', '120', 'summer'),
    );
    await summer.create(recursive: true);

    final films = await scanAlbumFilms(root.path);

    expect(films.single.rolls.map((roll) => '${roll.format} ${roll.name}'), [
      '135 tokyo',
    ]);
    expect(
      await File(
        p.join(
          root.path,
          'KODAK_PORTRA_400',
          '120',
          'summer',
          albumFilmMetaName,
        ),
      ).exists(),
      isFalse,
    );
    expect(
      await readAlbumFilmFormat(
        p.join(root.path, 'KODAK_PORTRA_400', '135', 'tokyo'),
      ),
      '135',
    );
  });

  test('folder metadata keeps the camera, lens, and film', () async {
    final roll = await Directory.systemTemp.createTemp('album_meta');
    addTearDown(() => roll.delete(recursive: true));
    await writeAlbumFolderMeta(
      roll.path,
      const AlbumFolderMeta(
        format: '120',
        filmName: 'Kodak Portra 400',
        iso: 400,
        frameFormat: '6x6',
        cameraLabel: 'Hasselblad 500CM',
        lensLabel: 'Planar 80',
      ),
    );

    final meta = await readAlbumFolderMeta(roll.path);
    expect(meta.format, '120');
    expect(meta.filmName, 'Kodak Portra 400');
    expect(meta.iso, 400);
    expect(meta.cameraLabel, 'Hasselblad 500CM');
    expect(meta.lensLabel, 'Planar 80');
    expect(await readAlbumFilmFormat(roll.path), '120');
  });

  test('a Lightroom JPG folder is the same roll, and its file wins', () {
    final roll = p.join('library', 'tokyo');
    final jpg = p.join(roll, 'JPG');
    AlbumPhoto photo(String path) =>
        AlbumPhoto(file: File(path), takenAt: DateTime(2024, 7, 30));
    final merged = albumPreferLightroomJpeg([
      photo(p.join(roll, 'a.tif')),
      photo(p.join(roll, 'b.tif')),
      photo(p.join(jpg, 'a.jpg')),
      photo(p.join(jpg, 'c.jpg')),
    ]);

    expect(merged.photos.map((photo) => photo.fileName), [
      'b.tif',
      'a.jpg',
      'c.jpg',
    ]);
    expect(
      albumRollFolder(p.dirname(p.join(jpg, 'a.jpg')), merged.jpegFolders),
      p.normalize(roll),
    );
  });

  test('a film folder lists every folder under it', () async {
    final root = await Directory.systemTemp.createTemp('album_tree');
    addTearDown(() => root.delete(recursive: true));
    await Directory(p.join(root.path, 'tokyo', 'day1')).create(recursive: true);
    await File(p.join(root.path, 'tokyo', 'a.jpg')).writeAsBytes([0]);

    final tree = await buildAlbumDirectoryTree(root.path);

    expect(tree.children.single.name, 'tokyo');
    expect(tree.children.single.directCount, 1);
    expect(tree.children.single.children.single.name, 'day1');

    final lightroom = Directory(p.join(root.path, 'summer'));
    await lightroom.create();
    await File(p.join(lightroom.path, 'frame.tif')).writeAsBytes([0]);
    await Directory(p.join(lightroom.path, 'JPG')).create();
    await File(p.join(lightroom.path, 'JPG', 'frame.jpg')).writeAsBytes([0]);
    final again = await buildAlbumDirectoryTree(root.path);
    final summer = again.children.singleWhere((node) => node.name == 'summer');
    expect(summer.children, isEmpty);
  });

  test('a camera is stored in the shape ApertureDiary reads', () async {
    final dir = await Directory.systemTemp.createTemp('album_gear');
    addTearDown(() => dir.delete(recursive: true));
    await albumSaveCameras([
      AlbumSharedCamera(
        albumNewCamera(
          brand: 'Nikon',
          name: 'F3',
          formatId: '36x24',
          interchangeable: true,
          mount: 'F',
        ),
      ),
    ], directory: dir);

    final loaded = await albumLoadCameras(directory: dir);
    expect(loaded.single.label, 'Nikon F3');
    expect(loaded.single.mount, 'F');
    final raw =
        jsonDecode(await File(p.join(dir.path, 'cameras.json')).readAsString())
            as List;
    expect((raw.single as Map)['formatId'], '36x24');
    expect((raw.single as Map)['interchangeableLenses'], true);
  });

  testWidgets('a chosen path asks film or digital', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    addTearDown(tester.view.reset);

    final root = Directory.systemTemp.createTempSync('album_kind');
    addTearDown(() => root.deleteSync(recursive: true));
    String? next = root.path;
    String? digital;
    String? film;

    await tester.pumpWidget(
      MaterialApp(
        home: ImageAlbum(
          paths: const [],
          pickFolder: ([_]) async => next,
          onImportDigital: (path) => digital = path,
          onFilmLibraryChanged: (path) => film = path,
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect(find.text('Import folder'), findsOneWidget);
    expect(find.text('Digital'), findsOneWidget);
    expect(find.text('Film'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(digital, isNull);
    expect(film, isNull);

    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Digital'));
    await tester.pumpAndSettle();
    expect(digital, root.path);
    expect(film, isNull);

    digital = null;
    await tester.tap(find.byTooltip('Film'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose folder').first);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Film'));
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    expect(film, root.path);
    expect(digital, isNull);
    expect(find.text('Import folder'), findsNothing);

    next = null;
    await tester.tap(find.byTooltip('Digital'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add folder'));
    await tester.pumpAndSettle();
    expect(find.text('Import folder'), findsNothing);
  });
}
