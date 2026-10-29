import 'dart:io';
import 'dart:typed_data';

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

      final seen = <int>[];
      final photos = await loadAlbumPhotos(
        temp.path,
        onProgress: (found) => seen.add(found.length),
      );

      expect(photos.map((photo) => photo.fileName), ['newer.png', 'older.JPG']);
      expect(seen, isNotEmpty);
      expect(seen.last, photos.length);
    });

    test('includes images in subfolders when recursive is set', () async {
      await Directory('${temp.path}/nested/deeper').create(recursive: true);
      final top = File('${temp.path}/top.png');
      final nested = File('${temp.path}/nested/hidden.jpg');
      final deep = File('${temp.path}/nested/deeper/deep.webp');
      await top.writeAsBytes([0]);
      await nested.writeAsBytes([0]);
      await deep.writeAsBytes([0]);
      await top.setLastModified(DateTime(2026, 3, 1));
      await nested.setLastModified(DateTime(2026, 2, 1));
      await deep.setLastModified(DateTime(2026, 4, 1));
      await File('${temp.path}/nested/notes.txt').writeAsString('nope');

      final photos = await loadAlbumPhotos(temp.path, recursive: true);

      expect(
        photos.map((photo) => photo.fileName),
        ['deep.webp', 'top.png', 'hidden.jpg'],
      );
    });

    test('sorts nested photos by capture date, not when the file was copied',
        () async {
      await Directory('${temp.path}/nested').create();
      final copied = File('${temp.path}/nested/old-shot.jpg');
      final loose = File('${temp.path}/newer-file.png');
      await copied.writeAsBytes(_jpegWithCaptureDate('2020:01:15 08:30:00'));
      await loose.writeAsBytes([0]);
      // Both files look new on disk. The nested JPEG remembers the shot.
      await copied.setLastModified(DateTime(2026, 6, 1, 12));
      await loose.setLastModified(DateTime(2026, 6, 1, 9));

      final photos = await loadAlbumPhotos(temp.path, recursive: true);

      expect(
        photos.map((photo) => photo.fileName),
        ['newer-file.png', 'old-shot.jpg'],
      );
      expect(photos.last.takenAt, DateTime(2020, 1, 15, 8, 30, 0));
    });

    test('returns nothing when the directory does not exist', () async {
      expect(await loadAlbumPhotos('${temp.path}/missing'), isEmpty);
    });
  });
}

/// A tiny JPEG whose only EXIF tag is DateTimeOriginal [captureDate],
/// formatted `YYYY:MM:DD HH:MM:SS`.
Uint8List _jpegWithCaptureDate(String captureDate) {
  final date = [...captureDate.codeUnits, 0];
  // TIFF, little-endian. IFD0 holds the pointer to the EXIF IFD, which
  // holds the date string. Offsets are from the start of the TIFF header.
  final tiff = Uint8List(0x2c + date.length);
  tiff.setRange(0, 8, const [0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00]);
  tiff.setRange(8, 10, const [0x01, 0x00]);
  tiff.setRange(10, 22, const [
    0x69, 0x87, // ExifOffset
    0x04, 0x00, // LONG
    0x01, 0x00, 0x00, 0x00, // count
    0x1a, 0x00, 0x00, 0x00, // offset of the EXIF IFD
  ]);
  tiff.setRange(0x1a, 0x1c, const [0x01, 0x00]);
  tiff.setRange(0x1c, 0x28, const [
    0x03, 0x90, // DateTimeOriginal
    0x02, 0x00, // ASCII
    0x14, 0x00, 0x00, 0x00, // 20 bytes
    0x2c, 0x00, 0x00, 0x00, // offset of the string
  ]);
  tiff.setRange(0x2c, 0x2c + date.length, date);

  final app1Length = 2 + 6 + tiff.length;
  final out = BytesBuilder(copy: false);
  out.add(const [0xff, 0xd8, 0xff, 0xe1, 0x00, 0x00]);
  out.add('Exif\x00\x00'.codeUnits);
  out.add(tiff);
  out.add(const [0xff, 0xd9]);
  final bytes = out.takeBytes();
  bytes[4] = (app1Length >> 8) & 0xff;
  bytes[5] = app1Length & 0xff;
  return bytes;
}
