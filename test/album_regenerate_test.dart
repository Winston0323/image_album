import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/src/album_images.dart';
import 'package:image_album/src/album_library.dart';
import 'package:path/path.dart' as p;

final _png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42Y'
  'AAAAASUVORK5CYII=',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_regen_test');
  });

  tearDown(() async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (_) {}
  });

  test('albumRegenerateThumbnails remakes every file', () async {
    final photos = Directory(p.join(temp.path, 'photos'))..createSync();
    final files = <File>[];
    for (var i = 0; i < 3; i++) {
      final file = File(p.join(photos.path, 'p$i.png'));
      await file.writeAsBytes(_png);
      files.add(file);
    }
    final library = await AlbumLibrary.open(
      Directory(p.join(temp.path, 'library')),
    );
    addTearDown(library.dispose);

    final stale = File(p.join(library.thumbnailDirectory.path, 'stale.thumb'));
    await library.thumbnailDirectory.create(recursive: true);
    await stale.writeAsBytes(_png);

    final progress = <(int, int)>[];
    final made = await albumRegenerateThumbnails(
      files,
      library: library,
      onProgress: (done, total) => progress.add((done, total)),
    );

    expect(made, 3);
    expect(progress.first, (0, 3));
    expect(progress.last, (3, 3));
    expect(await stale.exists(), isFalse);
    expect((await library.cacheUsage()).thumbnailCount, 3);
  });

  test(
    'albumRegenerateThumbnails keeps the first path of duplicates',
    () async {
      final photos = Directory(p.join(temp.path, 'photos'))..createSync();
      final file = File(p.join(photos.path, 'a.png'));
      await file.writeAsBytes(_png);
      final library = await AlbumLibrary.open(
        Directory(p.join(temp.path, 'library')),
      );
      addTearDown(library.dispose);

      final made = await albumRegenerateThumbnails([
        file,
        File(file.path),
        file,
      ], library: library);
      expect(made, 1);
      expect((await library.cacheUsage()).thumbnailCount, 1);
    },
  );
}
