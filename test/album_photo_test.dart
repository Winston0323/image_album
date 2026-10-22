import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_album/image_album.dart';

AlbumPhoto _photo(String name, DateTime takenAt) =>
    AlbumPhoto(file: File(name), takenAt: takenAt);

void main() {
  group('groupAlbumByDay', () {
    test('orders days newest first, and shots newest first within a day', () {
      final sections = groupAlbumByDay([
        _photo('old.JPG', DateTime(2026, 7, 28, 9)),
        _photo('newest.JPG', DateTime(2026, 7, 30, 18)),
        _photo('earlier_today.JPG', DateTime(2026, 7, 30, 8)),
      ]);

      expect(
        sections.map((s) => s.day),
        [DateTime(2026, 7, 30), DateTime(2026, 7, 28)],
      );
      expect(
        sections.first.photos.map((p) => p.fileName),
        ['newest.JPG', 'earlier_today.JPG'],
      );
    });

    test('splits shots that straddle midnight into separate days', () {
      final sections = groupAlbumByDay([
        _photo('before.JPG', DateTime(2026, 7, 30, 23, 59)),
        _photo('after.JPG', DateTime(2026, 7, 31, 0, 1)),
      ]);

      expect(sections, hasLength(2));
      expect(sections.first.photos.single.fileName, 'after.JPG');
    });

    test('returns nothing for an empty album', () {
      expect(groupAlbumByDay([]), isEmpty);
    });
  });

  group('loadAlbumPhotos', () {
    late Directory temp;

    setUp(() async {
      temp = await Directory.systemTemp.createTemp('image_album_load_test');
    });

    tearDown(() async {
      if (await temp.exists()) await temp.delete(recursive: true);
    });

    test('lists images newest first and skips everything else', () async {
      final older = File('${temp.path}/older.JPG');
      final newer = File('${temp.path}/newer.png');
      await older.writeAsBytes([0]);
      await newer.writeAsBytes([0]);
      await older.setLastModified(DateTime(2026, 1, 1));
      await newer.setLastModified(DateTime(2026, 6, 1));
      await File('${temp.path}/notes.txt').writeAsString('nope');
      await File('${temp.path}/partial.JPG.part').writeAsBytes([0]);
      await Directory('${temp.path}/nested').create();
      await File('${temp.path}/nested/hidden.jpg').writeAsBytes([0]);

      final photos = await loadAlbumPhotos(temp.path);

      expect(photos.map((photo) => photo.fileName), ['newer.png', 'older.JPG']);
    });

    test('returns nothing when the directory does not exist', () async {
      expect(await loadAlbumPhotos('${temp.path}/missing'), isEmpty);
    });
  });
}
