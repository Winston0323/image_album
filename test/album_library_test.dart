import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';
import 'package:image_album/src/album_cache.dart';
import 'package:image_album/src/album_images.dart';
import 'package:path/path.dart' as p;

final List<int> _onePixelPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_library_test');
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

  Directory libraryDir() => Directory(p.join(temp.path, 'library'));

  Future<Map<String, Object?>> manifest(AlbumLibrary library) async =>
      jsonDecode(await library.file.readAsString()) as Map<String, Object?>;

  group('AlbumLibrary', () {
    test('opens empty, with the default cache options', () async {
      final library = await AlbumLibrary.open(libraryDir());

      expect(library.sources, isEmpty);
      expect(library.excluded, isEmpty);
      expect(library.cache, const AlbumCacheOptions());
      expect(library.indexes, isEmpty);
      expect(library.indexDirectory.path, p.join(libraryDir().path, 'index'));
      expect(
        library.thumbnailDirectory.path,
        p.join(libraryDir().path, 'thumbs'),
      );
    });

    test(
      'keeps sources, hidden folders and options between openings',
      () async {
        final library = await AlbumLibrary.open(libraryDir());
        await library.addSource(p.join(temp.path, 'a'));
        await library.addSource(p.join(temp.path, 'b'));
        await library.setExcluded({p.join(temp.path, 'a', 'private')});
        await library.setCacheOptions(
          const AlbumCacheOptions(
            thumbnailWidth: 320,
            thumbnailQuality: 70,
            thumbnailMaxBytes: 64 << 20,
          ),
        );

        final reopened = await AlbumLibrary.open(libraryDir());

        expect(reopened.sources, [
          p.join(temp.path, 'a'),
          p.join(temp.path, 'b'),
        ]);
        expect(reopened.excluded, {p.join(temp.path, 'a', 'private')});
        expect(reopened.cache.thumbnailWidth, 320);
        expect(reopened.cache.thumbnailQuality, 70);
        expect(reopened.cache.thumbnailMaxBytes, 64 << 20);

        final json = await manifest(reopened);
        expect(json['version'], AlbumLibrary.version);
        expect(json['sources'], hasLength(2));
      },
    );

    test('keeps the file type filter, tidied, between openings', () async {
      final library = await AlbumLibrary.open(libraryDir());
      expect(library.fileTypes, isEmpty);

      await library.setFileTypes([' png ', 'JPG', '']);
      expect(library.fileTypes, {'PNG', 'JPG'});

      final reopened = await AlbumLibrary.open(libraryDir());
      expect(reopened.fileTypes, {'PNG', 'JPG'});
      expect((await manifest(reopened))['fileTypes'], ['JPG', 'PNG']);

      await reopened.setFileTypes(const []);
      expect((await AlbumLibrary.open(libraryDir())).fileTypes, isEmpty);
    });

    test('removing a source keeps the others in order', () async {
      final library = await AlbumLibrary.open(libraryDir());
      for (final name in ['a', 'b', 'c']) {
        await library.addSource(p.join(temp.path, name));
      }

      expect(await library.removeSource(p.join(temp.path, 'b')), true);
      expect(await library.removeSource(p.join(temp.path, 'b')), false);

      final reopened = await AlbumLibrary.open(libraryDir());
      expect(reopened.sources, [
        p.join(temp.path, 'a'),
        p.join(temp.path, 'c'),
      ]);
    });

    test('a folder cannot be added twice, however it is written', () async {
      final library = await AlbumLibrary.open(libraryDir());

      expect(await library.addSource(p.join(temp.path, 'a')), true);
      expect(await library.addSource(p.join(temp.path, 'x', '..', 'a')), false);
      expect(library.sources, hasLength(1));
    });

    test('setSources drops repeats', () async {
      final library = await AlbumLibrary.open(libraryDir());

      await library.setSources([
        p.join(temp.path, 'a'),
        p.join(temp.path, 'b'),
        p.join(temp.path, 'a'),
      ]);

      expect(library.sources, [p.join(temp.path, 'a'), p.join(temp.path, 'b')]);
    });

    test('several changes at once all end up in the file', () async {
      final library = await AlbumLibrary.open(libraryDir());

      await Future.wait([
        for (var i = 0; i < 6; i++) library.addSource(p.join(temp.path, '$i')),
      ]);

      final reopened = await AlbumLibrary.open(libraryDir());
      expect(reopened.sources, hasLength(6));
    });

    test('tells its listeners about changes to the user\'s choices', () async {
      final library = await AlbumLibrary.open(libraryDir());
      var notified = 0;
      library.addListener(() => notified++);

      await library.addSource(p.join(temp.path, 'a'));
      await library.setExcluded({p.join(temp.path, 'a', 'x')});
      await library.setExcluded({p.join(temp.path, 'a', 'x')}); // no change
      await library.recordScan(p.join(temp.path, 'a'), false, 3);

      expect(notified, 2);
    });

    test(
      'out-of-range options in the file fall back to the defaults',
      () async {
        await libraryDir().create(recursive: true);
        await File(
          p.join(libraryDir().path, AlbumLibrary.manifestName),
        ).writeAsString(
          jsonEncode({
            'version': 1,
            'cache': {
              'thumbnailWidth': -5,
              'thumbnailQuality': 400,
              'thumbnailMaxBytes': 'lots',
            },
          }),
        );

        final library = await AlbumLibrary.open(libraryDir());

        expect(library.cache, const AlbumCacheOptions());
      },
    );

    test(
      'a damaged manifest is set aside and the album starts empty',
      () async {
        await libraryDir().create(recursive: true);
        final path = p.join(libraryDir().path, AlbumLibrary.manifestName);
        await File(path).writeAsString('{ not json');

        final library = await AlbumLibrary.open(libraryDir());

        expect(library.sources, isEmpty);
        expect(await File('$path.damaged').readAsString(), '{ not json');

        // It can be used and saved as normal afterwards.
        await library.addSource(p.join(temp.path, 'a'));
        expect((await AlbumLibrary.open(libraryDir())).sources, hasLength(1));
      },
    );

    test('remembers when each source was scanned', () async {
      final library = await AlbumLibrary.open(libraryDir());
      final source = p.join(temp.path, 'a');
      final at = DateTime.utc(2026, 10, 31, 12);

      await library.recordScan(source, true, 42, at: at);

      final reopened = await AlbumLibrary.open(libraryDir(), now: at);
      final info = reopened.indexFor(source, recursive: true)!;
      expect(info.photoCount, 42);
      expect(info.scannedAt.toUtc(), at);
      expect(info.file, albumIndexName(source, true));
      expect(reopened.indexFor(source), isNull); // the other mode
    });

    test(
      'forgets indexes unused for a month and deletes stray files',
      () async {
        final library = await AlbumLibrary.open(libraryDir());
        final now = DateTime.utc(2026, 10, 31);
        final fresh = p.join(temp.path, 'fresh');
        final stale = p.join(temp.path, 'stale');
        await library.recordScan(
          fresh,
          false,
          1,
          at: now.subtract(const Duration(days: 2)),
        );
        await library.recordScan(
          stale,
          false,
          1,
          at: now.subtract(const Duration(days: 90)),
        );

        await library.indexDirectory.create(recursive: true);
        Future<File> write(String name) async {
          final file = File(p.join(library.indexDirectory.path, name));
          await file.writeAsString('x');
          return file;
        }

        final freshFile = await write(albumIndexName(fresh, false));
        final staleFile = await write(albumIndexName(stale, false));
        final strayFile = await write('0000000000000000.tsv');
        final otherFile = await write('notes.txt');

        final reopened = await AlbumLibrary.open(libraryDir(), now: now);

        expect(reopened.indexFor(fresh), isNotNull);
        expect(reopened.indexFor(stale), isNull);
        expect(await freshFile.exists(), true);
        expect(await staleFile.exists(), false);
        expect(await strayFile.exists(), false);
        // Only files that are the library's own are touched.
        expect(await otherFile.exists(), true);
      },
    );

    test('reports and clears what the caches take', () async {
      final library = await AlbumLibrary.open(libraryDir());
      await library.addSource(p.join(temp.path, 'a'));
      await library.thumbnailDirectory.create(recursive: true);
      await File(
        p.join(library.thumbnailDirectory.path, 'a.thumb'),
      ).writeAsBytes(List.filled(100, 1));
      await File(
        p.join(library.thumbnailDirectory.path, 'b.thumb'),
      ).writeAsBytes(List.filled(50, 1));
      await library.recordScan(p.join(temp.path, 'a'), false, 1);
      await library.indexDirectory.create(recursive: true);
      await File(
        p.join(
          library.indexDirectory.path,
          albumIndexName(p.join(temp.path, 'a'), false),
        ),
      ).writeAsString('abc');

      final usage = await library.cacheUsage();
      expect(usage.thumbnailCount, 2);
      expect(usage.thumbnailBytes, 150);
      expect(usage.indexCount, 1);
      expect(usage.indexBytes, 3);
      expect(usage.totalBytes, 153);

      await library.clearCaches();

      expect((await library.cacheUsage()).totalBytes, 0);
      expect(library.indexes, isEmpty);
      // Choices are not caches.
      expect(library.sources, hasLength(1));
    });
  });

  group('readAlbumIndex', () {
    Future<Directory> photos() async {
      final dir = Directory(p.join(temp.path, 'photos'));
      await dir.create();
      for (var i = 0; i < 3; i++) {
        final file = File(p.join(dir.path, 'p$i.png'));
        await file.writeAsBytes(_onePixelPng);
        await file.setLastModified(DateTime(2026, 7, 10 + i, 9));
      }
      return dir;
    }

    test(
      'returns what the last scan found, newest first, without scanning',
      () async {
        final dir = await photos();
        final cache = Directory(p.join(temp.path, 'cache'));
        final scanned = await loadAlbumPhotos(dir.path, cacheDirectory: cache);

        // Files can vanish; the index is only a memory of the last scan.
        for (final file in dir.listSync()) {
          file.deleteSync();
        }
        final indexed = await readAlbumIndex(dir.path, cacheDirectory: cache);

        expect(
          indexed.map((photo) => photo.id),
          scanned.map((photo) => photo.id),
        );
        expect(
          indexed.map((photo) => photo.takenAt),
          scanned.map((photo) => photo.takenAt),
        );
      },
    );

    test('is empty for a folder never scanned', () async {
      final cache = Directory(p.join(temp.path, 'cache'));

      expect(await readAlbumIndex(temp.path, cacheDirectory: cache), isEmpty);
    });

    test('keeps the two modes apart', () async {
      final dir = await photos();
      final cache = Directory(p.join(temp.path, 'cache'));
      await loadAlbumPhotos(dir.path, cacheDirectory: cache);

      expect(
        await readAlbumIndex(dir.path, recursive: true, cacheDirectory: cache),
        isEmpty,
      );
      expect(
        await readAlbumIndex(dir.path, cacheDirectory: cache),
        hasLength(3),
      );
    });

    test('skips damaged lines', () async {
      final cache = Directory(p.join(temp.path, 'cache'));
      await cache.create();
      await File(
        p.join(cache.path, albumIndexName('somewhere', false)),
      ).writeAsString(
        'somewhere/a.jpg\t1\t2\t1000000\n'
        'garbage\n'
        'somewhere/b.jpg\tx\t2\t3\n'
        'somewhere/c.jpg\t1\t2\t5000000\n',
      );

      final indexed = await readAlbumIndex('somewhere', cacheDirectory: cache);

      expect(indexed.map((photo) => photo.fileName), ['c.jpg', 'a.jpg']);
    });
  });

  group('thumbnails of a library', () {
    test('follow the library\'s options and folder', () async {
      final library = await AlbumLibrary.open(libraryDir());
      await library.setCacheOptions(
        const AlbumCacheOptions(
          thumbnailWidth: 400,
          thumbnailQuality: 60,
          thumbnailMaxBytes: 8 << 20,
        ),
      );

      final provider =
          albumThumbnailProvider(File('x.jpg'), library: library)
              as AlbumThumbnailProvider;

      expect(provider.width, 400);
      expect(provider.quality, 60);
      expect(provider.maxCacheBytes, 8 << 20);
      expect(provider.cacheDirectory!.path, library.thumbnailDirectory.path);
      expect(
        (albumThumbnailProvider(File('x.jpg')) as AlbumThumbnailProvider)
            .cacheDirectory,
        isNull,
      );
    });

    test('a different quality is a different thumbnail', () {
      final low = AlbumThumbnailProvider(File('x.jpg'), quality: 40);
      final high = AlbumThumbnailProvider(File('x.jpg'), quality: 90);

      expect(low == high, false);
      expect(low == AlbumThumbnailProvider(File('x.jpg'), quality: 40), true);
    });
  });
}
