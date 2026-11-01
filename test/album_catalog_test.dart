import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_catalog.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory temp;
  late Directory photos;
  late Directory cache;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_catalog_test');
    photos = await Directory(p.join(temp.path, 'photos')).create();
    cache = Directory(p.join(temp.path, 'cache'));
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<File> photo(String relative, DateTime modified) async {
    final file = File(p.joinAll([photos.path, ...relative.split('/')]));
    await file.create(recursive: true);
    await file.writeAsBytes([0]);
    await file.setLastModified(modified);
    return file;
  }

  Future<List<AlbumPhoto>> scan({
    bool recursive = false,
    Duration? trust,
    Directory? cacheDirectory,
    bool useCatalog = true,
  }) => loadAlbumPhotos(
    photos.path,
    recursive: recursive,
    cacheDirectory: cacheDirectory ?? cache,
    trustCatalog: trust,
    useCatalog: useCatalog,
  );

  List<String> names(List<AlbumPhoto> list) => [
    for (final photo in list) photo.fileName,
  ];

  const day = Duration(days: 1);

  group('the catalog file', () {
    test('has an uncommon extension, not the Rollei RAW one', () {
      expect(albumCatalogName, startsWith('.'));
      expect(p.extension(albumCatalogName), '.iacx');
      expect(p.extension(albumCatalogName), isNot('.ia'));
    });

    test('is written in the folder by a scan, and is not a photo', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      final found = await scan();

      expect(await albumCatalogFile(photos.path).exists(), isTrue);
      expect(names(found), ['a.png']);
      // Scanning again does not mistake the catalog for an image.
      expect(names(await scan()), ['a.png']);
    });

    test('is hidden on Windows', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      // Written again over the hidden one, which must still work.
      await photo('b.png', DateTime(2026, 2, 1));
      await scan();

      final file = albumCatalogFile(photos.path);
      expect(await file.exists(), isTrue);
      if (Platform.isWindows) {
        final listing = (await Process.run('attrib', [file.path])).stdout;
        expect(
          (listing as String).split(file.path).first,
          contains('H'),
          reason: 'attrib: $listing',
        );
      }
      // The scan did not leave temporary files behind.
      final stray = photos.listSync().whereType<File>().where(
        (f) => p.basename(f.path).endsWith('.tmp'),
      );
      expect(stray, isEmpty);
    });

    test('stores paths relative to the folder, with slashes', () async {
      await photo('top.png', DateTime(2026, 1, 1));
      await photo('trips/paris/p.png', DateTime(2026, 1, 2));
      await scan(recursive: true);

      final catalog = (await readAlbumCatalog(photos.path))!;
      expect(catalog.entries.keys.toSet(), {'top.png', 'trips/paris/p.png'});
      expect(catalog.deep, isTrue);
    });

    test('stays valid when the folder is moved', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await photo('sub/b.png', DateTime(2026, 2, 1));
      await scan(recursive: true);

      final moved = Directory(p.join(temp.path, 'moved'));
      await photos.rename(moved.path);

      final indexed = await readAlbumIndex(
        moved.path,
        recursive: true,
        cacheDirectory: cache,
      );
      expect(names(indexed), ['b.png', 'a.png']);
      expect(
        indexed.every((photo) => p.isWithin(moved.path, photo.file.path)),
        isTrue,
      );
    });

    test('is left out when the album is told not to use it', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await scan(useCatalog: false);

      expect(await albumCatalogFile(photos.path).exists(), isFalse);
    });

    test('is rebuilt when damaged', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      // The catalog is hidden on Windows, which will not let it be opened for
      // writing, so it is replaced rather than overwritten.
      await deleteAlbumCatalog(photos.path);
      await albumCatalogFile(
        photos.path,
      ).writeAsBytes([0xff, 0xfe, 0x00, 0x09]);

      expect(names(await scan()), ['a.png']);
      expect((await readAlbumCatalog(photos.path))!.entries, hasLength(1));
    });

    test('a catalog of another version is ignored', () async {
      await albumCatalogFile(
        photos.path,
      ).writeAsString('IACX\t99\t1\t0\na.png\t1\t1\t1\n');

      expect(await readAlbumCatalog(photos.path), isNull);
    });

    test('a folder that cannot be written to still scans', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      // A directory where the catalog should go makes every write fail.
      await Directory(albumCatalogFile(photos.path).path).create();

      expect(names(await scan()), ['a.png']);
    });
  });

  group('opening a folder again', () {
    test(
      'answers from the catalog when the album file knows nothing',
      () async {
        await photo('a.png', DateTime(2026, 1, 1));
        await photo('b.png', DateTime(2026, 2, 1));
        await scan();

        // Another install: a different, empty album file. Files could vanish
        // meanwhile; the catalog is only a memory of the last scan.
        final other = Directory(p.join(temp.path, 'other-cache'));
        for (final file in photos.listSync().whereType<File>()) {
          if (p.basename(file.path) != albumCatalogName) file.deleteSync();
        }
        final indexed = await readAlbumIndex(
          photos.path,
          cacheDirectory: other,
        );

        expect(names(indexed), ['b.png', 'a.png']);
      },
    );

    test('a shallow catalog does not stand in for the whole tree', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await photo('sub/b.png', DateTime(2026, 2, 1));
      await scan();

      expect(
        await readAlbumIndex(
          photos.path,
          recursive: true,
          cacheDirectory: cache,
        ),
        isEmpty,
      );
      expect(names(await readAlbumIndex(photos.path, cacheDirectory: cache)), [
        'a.png',
      ]);
    });

    test('a deep catalog also serves the folder alone', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await photo('sub/b.png', DateTime(2026, 2, 1));
      await scan(recursive: true);

      expect(names(await readAlbumIndex(photos.path, cacheDirectory: cache)), [
        'a.png',
      ]);
      expect(
        names(
          await readAlbumIndex(
            photos.path,
            recursive: true,
            cacheDirectory: cache,
          ),
        ),
        ['b.png', 'a.png'],
      );
    });

    test('a scan of the folder alone keeps what a deeper one found', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await photo('sub/b.png', DateTime(2026, 2, 1));
      await scan(recursive: true);

      await photo('c.png', DateTime(2026, 3, 1));
      await scan();

      final catalog = (await readAlbumCatalog(photos.path))!;
      expect(catalog.entries.keys.toSet(), {'a.png', 'c.png', 'sub/b.png'});
      expect(catalog.deep, isTrue);
    });
  });

  group('trusting the catalog', () {
    test('skips checking files it already lists', () async {
      final file = await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      await file.setLastModified(DateTime(2026, 5, 1));

      // Believed: the edit is not noticed...
      final trusted = await scan(trust: day);
      expect(trusted.single.takenAt, DateTime(2026, 1, 1));
      // ...and without trust, every file is checked.
      final checked = await scan();
      expect(checked.single.takenAt, DateTime(2026, 5, 1));
    });

    test('works from the catalog alone, with no album file', () async {
      final file = await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      await file.setLastModified(DateTime(2026, 5, 1));

      final other = Directory(p.join(temp.path, 'other-cache'));
      final trusted = await scan(trust: day, cacheDirectory: other);

      expect(trusted.single.takenAt, DateTime(2026, 1, 1));
    });

    test('still sees photos that came and went', () async {
      final old = await photo('old.png', DateTime(2026, 1, 1));
      await scan();

      await old.delete();
      await photo('new.png', DateTime(2026, 2, 1));
      final found = await scan(trust: day);

      expect(names(found), ['new.png']);
      final catalog = (await readAlbumCatalog(photos.path))!;
      expect(catalog.entries.keys, ['new.png']);
    });

    test('does not count as checking the files', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      final first = (await readAlbumCatalog(photos.path))!.verifiedAt;

      await Future<void>.delayed(const Duration(milliseconds: 20));
      await photo('b.png', DateTime(2026, 2, 1));
      await scan(trust: day);

      final catalog = (await readAlbumCatalog(photos.path))!;
      expect(catalog.entries.keys.toSet(), {'a.png', 'b.png'});
      expect(catalog.verifiedAt, first);
    });

    test('is not done once the catalog is older than the limit', () async {
      final file = await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      final catalog = (await readAlbumCatalog(photos.path))!;
      final stale = DateTime.now().subtract(const Duration(days: 2));
      await writeAlbumCatalog(
        photos.path,
        AlbumCatalog(
          verifiedAt: stale.microsecondsSinceEpoch,
          deep: catalog.deep,
          entries: catalog.entries,
        ),
      );
      await file.setLastModified(DateTime(2026, 5, 1));

      final found = await scan(trust: day);

      expect(found.single.takenAt, DateTime(2026, 5, 1));
      // Verified again, so the next scan may trust it afresh.
      final renewed = (await readAlbumCatalog(photos.path))!.verifiedAt;
      expect(renewed, greaterThan(stale.microsecondsSinceEpoch));
      await file.setLastModified(DateTime(2026, 6, 1));
      expect((await scan(trust: day)).single.takenAt, DateTime(2026, 5, 1));
    });

    test('is not done when no catalog has been made yet', () async {
      await photo('a.png', DateTime(2026, 1, 1));

      final found = await scan(trust: day);

      expect(found.single.takenAt, DateTime(2026, 1, 1));
      expect(await albumCatalogFile(photos.path).exists(), isTrue);
    });
  });

  group('the album file and the catalogs', () {
    test('count and clear the catalogs of its sources', () async {
      await photo('a.png', DateTime(2026, 1, 1));
      await scan();
      final library = await AlbumLibrary.open(
        Directory(p.join(temp.path, 'library')),
      );
      await library.setSources([photos.path]);

      final usage = await library.cacheUsage();
      expect(usage.indexCount, 1);
      expect(usage.indexBytes, greaterThan(0));

      await library.clearCaches();

      expect(await albumCatalogFile(photos.path).exists(), isFalse);
      expect((await library.cacheUsage()).indexCount, 0);
      library.dispose();
    });
  });
}
