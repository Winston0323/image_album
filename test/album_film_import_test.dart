import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_film_import.dart';
import 'package:image_album/src/album_films.dart';
import 'package:path/path.dart' as p;

void main() {
  test('a nested folder of scans becomes one roll of pictures', () async {
    final root = await Directory.systemTemp.createTemp('album_import_flat');
    addTearDown(() => root.delete(recursive: true));
    final film = Directory(p.join(root.path, 'KODAK_PORTRA_400'));
    await film.create();
    final source = Directory(p.join(root.path, 'camera', 'trip', 'scans'));
    await source.create(recursive: true);
    await File(p.join(source.path, 'a.jpg')).writeAsBytes([0xFF, 0xD8]);
    await File(p.join(source.path, 'b.jpg')).writeAsBytes([0xFF, 0xD8]);

    final roll = await albumImportFilmRoll(
      filmFolder: film.path,
      source: p.join(root.path, 'camera'),
    );

    expect(p.basename(roll), 'camera');
    expect(await File(p.join(roll, 'a.jpg')).exists(), isTrue);
    expect(await File(p.join(roll, 'b.jpg')).exists(), isTrue);
    expect(await Directory(p.join(roll, 'trip')).exists(), isFalse);
  });

  test('a zip of nested folders becomes one roll of pictures', () async {
    final root = await Directory.systemTemp.createTemp('album_import_zip');
    addTearDown(() => root.delete(recursive: true));
    final film = Directory(p.join(root.path, 'KODAK_GOLD_200'));
    await film.create();

    final archive = Archive()
      ..addFile(ArchiveFile('outer/inner/frame.jpg', 2, [0xFF, 0xD8]));
    final zip = File(p.join(root.path, 'holiday.zip'));
    await zip.writeAsBytes(ZipEncoder().encode(archive)!);

    final roll = await albumImportFilmRoll(
      filmFolder: film.path,
      source: zip.path,
    );

    expect(p.basename(roll), 'holiday');
    expect(await File(p.join(roll, 'frame.jpg')).exists(), isTrue);
    expect(await Directory(p.join(roll, 'outer')).exists(), isFalse);
  });

  test('a missing film folder is created for the kind', () async {
    final root = await Directory.systemTemp.createTemp('album_import_ensure');
    addTearDown(() => root.delete(recursive: true));
    final kind = albumFilmKinds.firstWhere(
      (item) => item.iconKey == 'portra-400',
    );

    final folder = await albumEnsureFilmFolder(
      libraryRoot: root.path,
      kind: kind,
    );

    expect(p.basename(folder), 'KODAK_PORTRA_400');
    expect(await Directory(folder).exists(), isTrue);
    final films = await scanAlbumFilms(root.path);
    expect(films.single.name, 'Kodak Portra 400');
  });

  test('every film kind gets a folder when the library is empty', () async {
    final root = await Directory.systemTemp.createTemp('album_import_all');
    addTearDown(() => root.delete(recursive: true));

    await albumEnsureMissingFilmFolders(root.path);

    final places = await listAlbumFilmPlaces(root.path);
    expect(places, hasLength(albumFilmKinds.length));
    expect(
      places.map((film) => p.basename(film.path)).toSet(),
      albumFilmKinds.map((kind) => kind.folderName).toSet(),
    );
  });

  test('a cleared film folder is not recreated for the library', () async {
    final root = await Directory.systemTemp.createTemp('album_import_cleared');
    addTearDown(() => root.delete(recursive: true));
    final kind = albumFilmKinds.firstWhere(
      (item) => item.iconKey == 'portra-400',
    );
    final folder = Directory(p.join(root.path, kind.folderName));
    await folder.create();
    await albumSetFilmFolderCleared(folder.path, true);

    await albumEnsureMissingFilmFolders(root.path);

    final places = await listAlbumFilmPlaces(root.path);
    expect(
      places.any(
        (film) => albumFilmKindForFolder(film.name)?.iconKey == kind.iconKey,
      ),
      isFalse,
    );
    expect(await albumFilmFolderIsCleared(folder.path), isTrue);
  });

  test('a roll moves to another film, keeping its name', () async {
    final root = await Directory.systemTemp.createTemp('album_import_move');
    addTearDown(() => root.delete(recursive: true));
    final from = Directory(p.join(root.path, 'KODAK_GOLD_200'));
    final to = Directory(p.join(root.path, 'KODAK_PORTRA_400'));
    await from.create();
    await to.create();
    final roll = Directory(p.join(from.path, '2024-tokyo'));
    await roll.create();
    await File(p.join(roll.path, 'a.jpg')).writeAsBytes([0xFF, 0xD8]);

    final moved = await albumMoveFilmRoll(
      rollPath: roll.path,
      targetFilmFolder: to.path,
    );

    expect(moved, isNotNull);
    expect(p.basename(moved!), '2024-tokyo');
    expect(await File(p.join(moved, 'a.jpg')).exists(), isTrue);
    expect(await Directory(p.join(from.path, '2024-tokyo')).exists(), isFalse);
  });
}
