import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:image_album/src/album_images.dart';
import 'package:image_album/src/album_photo.dart';
import 'package:image_album/src/album_raw.dart';
import 'package:path/path.dart' as p;

/// A [width]x[height] JPEG of random noise, so it does not compress away: a
/// 600x400 one is far over the size the album takes as a real preview.
Uint8List _noisyJpeg(int width, int height, {int seed = 1, int? orientation}) {
  final random = Random(seed);
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = random.nextInt(256)
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  final jpeg = Uint8List.fromList(img.encodeJpg(image, quality: 90));
  if (orientation == null) return jpeg;
  return _jpegWithOrientation(jpeg, orientation);
}

/// [jpeg] with an EXIF Orientation APP1 after SOI. The `image` package drops
/// EXIF when encoding, so tagged previews are built this way.
Uint8List _jpegWithOrientation(Uint8List jpeg, int orientation) {
  final tiff = BytesBuilder()
    ..add([0x49, 0x49, 0x2A, 0x00, 0x08, 0x00, 0x00, 0x00])
    ..add([0x01, 0x00])
    ..add([
      0x12,
      0x01,
      0x03,
      0x00,
      0x01,
      0x00,
      0x00,
      0x00,
      orientation,
      0x00,
      0x00,
      0x00,
    ])
    ..add([0x00, 0x00, 0x00, 0x00]);
  final payload = BytesBuilder()
    ..add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
    ..add(tiff.toBytes());
  final body = payload.toBytes();
  final app1Len = body.length + 2;
  return (BytesBuilder()
        ..add([0xFF, 0xD8])
        ..add([0xFF, 0xE1, (app1Len >> 8) & 0xFF, app1Len & 0xFF])
        ..add(body)
        ..add(jpeg.sublist(2)))
      .toBytes();
}

/// A smooth [width]x[height] JPEG, tiny, like a camera's thumbnail.
Uint8List _smallJpeg(int width, int height) {
  final image = img.Image(width: width, height: height);
  for (final pixel in image) {
    pixel
      ..r = pixel.x * 255 ~/ width
      ..g = pixel.y * 255 ~/ height
      ..b = 128;
  }
  // The search ignores anything under 4 KB as not worth showing, so even a
  // thumbnail here is made a little bigger than that.
  return img.encodeJpg(image, quality: 100);
}

/// A little-endian TIFF structure, laid out like a camera raw: a first
/// directory with the picture's size, orientation and date, an EXIF directory
/// with the shot time, a thumbnail named by the JPEG tags and a preview
/// placed in the file without being named.
Uint8List _tiffFile({
  int width = 6000,
  int height = 4000,
  int orientation = 1,
  String? modified,
  String? shot,
  Uint8List? named,
  Uint8List? unnamed,
  Uint8List? stripJpeg,
}) {
  final out = BytesBuilder();
  final blobs = BytesBuilder();

  // Entries as [tag, type, count, value | blob]. A value that fits in four
  // bytes is stored in the entry, as TIFF does, and anything else is put
  // after the directories and pointed to.
  final ifd0 = <List<Object?>>[
    [0x0100, 4, 1, width],
    [0x0101, 4, 1, height],
    if (stripJpeg != null) [0x0103, 3, 1, 7],
    [0x0112, 3, 1, orientation],
    if (modified != null) [0x0132, 2, modified.length + 1, _ascii(modified)],
    if (stripJpeg != null) ...[
      [0x0111, 4, 1, _Pointer(stripJpeg)],
      [0x0117, 4, 1, stripJpeg.length],
    ],
    if (shot != null) [0x8769, 4, 1, 'exif'],
    if (named != null) ...[
      [0x0201, 4, 1, _Pointer(named)],
      [0x0202, 4, 1, named.length],
    ],
  ];
  final exif = <List<Object?>>[
    if (shot != null) [0x9003, 2, shot.length + 1, _ascii(shot)],
  ];

  final ifd0Size = 2 + ifd0.length * 12 + 4;
  final exifSize = exif.isEmpty ? 0 : 2 + exif.length * 12 + 4;
  final exifStart = 8 + ifd0Size;
  final blobStart = exifStart + exifSize;
  final offsets = <Object, int>{};

  int place(Uint8List bytes) {
    final at = blobStart + blobs.length;
    blobs.add(bytes);
    if (blobs.length.isOdd) blobs.addByte(0); // keep entries on even offsets
    return at;
  }

  Uint8List directory(List<List<Object?>> entries) {
    final data = ByteData(2 + entries.length * 12 + 4);
    data.setUint16(0, entries.length, Endian.little);
    for (var i = 0; i < entries.length; i++) {
      final [tag, type, count, value] = entries[i];
      final at = 2 + i * 12;
      data.setUint16(at, tag! as int, Endian.little);
      data.setUint16(at + 2, type! as int, Endian.little);
      data.setUint32(at + 4, count! as int, Endian.little);
      if (value is Uint8List) {
        data.setUint32(at + 8, place(value), Endian.little);
      } else if (value is _Pointer) {
        data.setUint32(
          at + 8,
          offsets.putIfAbsent(value.bytes, () => place(value.bytes)),
          Endian.little,
        );
      } else if (value == 'exif') {
        data.setUint32(at + 8, exifStart, Endian.little);
      } else if (type == 3) {
        data.setUint16(at + 8, value! as int, Endian.little);
      } else {
        data.setUint32(at + 8, value! as int, Endian.little);
      }
    }
    return data.buffer.asUint8List();
  }

  final header = ByteData(8)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, 8, Endian.little);
  out
    ..add(header.buffer.asUint8List())
    ..add(directory(ifd0));
  if (exif.isNotEmpty) out.add(directory(exif));
  out.add(blobs.takeBytes());
  if (unnamed != null) {
    // Sensor data stand-in, then the preview nobody points to.
    out
      ..add(Uint8List(300 * 1024))
      ..add(unnamed);
  }
  return out.takeBytes();
}

/// A little-endian TIFF with one 8-bit plane after the other
/// (PlanarConfiguration 2), each cut into strips of [rowsPerStrip] rows and
/// packed as [compression] says (1 none, 5 LZW, 8 deflate, 32773 PackBits).
Uint8List _planarTiff({
  required int width,
  required int height,
  required List<Uint8List> planes,
  int compression = 1,
  bool predictor = false,
  int rowsPerStrip = 16,
  bool alpha = false,
  bool interleaved = false,
  bool sixteenBit = false,
}) {
  final body = BytesBuilder();
  int at() => 8 + body.length;
  final offsets = <int>[];
  final counts = <int>[];
  // A strip holds one plane, or every plane woven together pixel by pixel.
  final groups = interleaved
      ? [planes]
      : [
          for (final plane in planes) [plane],
        ];
  final bytes = sixteenBit ? 2 : 1;
  for (final group in groups) {
    final per = group.length;
    for (var row = 0; row < height; row += rowsPerStrip) {
      final rows = min(rowsPerStrip, height - row);
      // Samples of the strip, row after row; 16 bits are the value in the top
      // byte and 7 below it.
      final values = [
        for (var i = row * width; i < (row + rows) * width; i++)
          for (final plane in group) sixteenBit ? plane[i] * 256 + 7 : plane[i],
      ];
      final modulus = sixteenBit ? 0x10000 : 0x100;
      if (predictor) {
        for (var r = 0; r < rows; r++) {
          for (var x = width * per - 1; x >= per; x--) {
            final at = r * width * per + x;
            values[at] = (values[at] - values[at - per]) % modulus;
          }
        }
      }
      final strip = Uint8List(values.length * bytes);
      for (var i = 0; i < values.length; i++) {
        strip[i * bytes] = values[i] & 0xFF;
        if (sixteenBit) strip[i * bytes + 1] = values[i] >> 8;
      }
      final packed = switch (compression) {
        1 => strip,
        5 => _lzwEncode(strip),
        8 => Uint8List.fromList(zlib.encode(strip)),
        32773 => _packBitsEncode(strip),
        _ => throw ArgumentError('compression $compression'),
      };
      offsets.add(at());
      counts.add(packed.length);
      body.add(packed);
      if (body.length.isOdd) body.addByte(0);
    }
  }

  Uint8List numbers(List<int> values, int size) {
    final data = ByteData(values.length * size);
    for (var i = 0; i < values.length; i++) {
      if (size == 2) {
        data.setUint16(i * 2, values[i], Endian.little);
      } else {
        data.setUint32(i * 4, values[i], Endian.little);
      }
    }
    return data.buffer.asUint8List();
  }

  final samples = planes.length;
  final bitsAt = at();
  final depth = sixteenBit ? 16 : 8;
  body.add(numbers(List.filled(samples, depth), 2));
  final offsetsAt = at();
  body.add(numbers(offsets, 4));
  final countsAt = at();
  body.add(numbers(counts, 4));

  // [tag, type, count, value or where it is]
  final entries = <List<int>>[
    [0x0100, 4, 1, width],
    [0x0101, 4, 1, height],
    [0x0102, 3, samples, samples == 1 ? depth : bitsAt],
    [0x0103, 3, 1, compression],
    [0x0106, 3, 1, samples == 1 ? 1 : 2],
    [0x0111, 4, offsets.length, offsets.length == 1 ? offsets[0] : offsetsAt],
    [0x0115, 3, 1, samples],
    [0x0116, 4, 1, rowsPerStrip],
    [0x0117, 4, counts.length, counts.length == 1 ? counts[0] : countsAt],
    [0x011C, 3, 1, interleaved ? 1 : 2],
    if (predictor) [0x013D, 3, 1, 2],
    if (alpha) [0x0152, 3, 1, 2],
  ];
  final directory = ByteData(2 + entries.length * 12 + 4);
  directory.setUint16(0, entries.length, Endian.little);
  for (var i = 0; i < entries.length; i++) {
    final [tag, type, count, value] = entries[i];
    final entry = 2 + i * 12;
    directory.setUint16(entry, tag, Endian.little);
    directory.setUint16(entry + 2, type, Endian.little);
    directory.setUint32(entry + 4, count, Endian.little);
    if (type == 3 && count == 1) {
      directory.setUint16(entry + 8, value, Endian.little);
    } else {
      directory.setUint32(entry + 8, value, Endian.little);
    }
  }

  final header = ByteData(8)
    ..setUint8(0, 0x49)
    ..setUint8(1, 0x49)
    ..setUint16(2, 42, Endian.little)
    ..setUint32(4, at(), Endian.little);
  return (BytesBuilder()
        ..add(header.buffer.asUint8List())
        ..add(body.takeBytes())
        ..add(directory.buffer.asUint8List()))
      .takeBytes();
}

/// TIFF's flavour of LZW.
Uint8List _lzwEncode(Uint8List data) {
  final out = <int>[];
  var buffer = 0;
  var bits = 0;
  void put(int code, int size) {
    buffer = (buffer << size) | code;
    bits += size;
    while (bits >= 8) {
      out.add((buffer >> (bits - 8)) & 0xFF);
      bits -= 8;
    }
    buffer &= (1 << bits) - 1;
  }

  var table = <int, int>{};
  var next = 258;
  var size = 9;
  put(256, size);
  var current = -1;
  for (final byte in data) {
    if (current == -1) {
      current = byte;
      continue;
    }
    final known = table[current * 256 + byte];
    if (known != null) {
      current = known;
      continue;
    }
    put(current, size);
    table[current * 256 + byte] = next++;
    if (next >= 4094) {
      put(256, size);
      table = {};
      next = 258;
      size = 9;
    } else if (next == (1 << size) && size < 12) {
      size++;
    }
    current = byte;
  }
  if (current != -1) {
    put(current, size);
    // The reader adds an entry for this code too, and may widen because of it.
    if (next + 1 == (1 << size) && size < 12) size++;
  }
  put(257, size);
  if (bits > 0) put(0, 8 - bits);
  return Uint8List.fromList(out);
}

Uint8List _packBitsEncode(Uint8List data) {
  final out = <int>[];
  var i = 0;
  while (i < data.length) {
    var run = 1;
    while (i + run < data.length && run < 128 && data[i + run] == data[i]) {
      run++;
    }
    if (run >= 3) {
      out
        ..add(257 - run)
        ..add(data[i]);
      i += run;
      continue;
    }
    final start = i;
    while (i < data.length &&
        i - start < 128 &&
        !(i + 2 < data.length &&
            data[i] == data[i + 1] &&
            data[i] == data[i + 2])) {
      i++;
    }
    out
      ..add(i - start - 1)
      ..addAll(data.sublist(start, i));
  }
  return Uint8List.fromList(out);
}

class _Pointer {
  const _Pointer(this.bytes);
  final Uint8List bytes;
}

Uint8List _ascii(String text) => Uint8List.fromList([...text.codeUnits, 0]);

Size _sizeOf(Uint8List bytes) {
  final image = img.decodeImage(bytes)!;
  return Size(image.width.toDouble(), image.height.toDouble());
}

void main() {
  late Directory temp;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('image_album_raw_test');
  });

  tearDown(() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      try {
        if (await temp.exists()) await temp.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<File> write(String name, List<int> bytes) async {
    final file = File(p.join(temp.path, name));
    await file.writeAsBytes(bytes);
    return file;
  }

  group('what counts as an image', () {
    test('TIFF, FFF and ARW are listed, in any case', () {
      for (final extension in ['.tif', '.tiff', '.fff', '.arw']) {
        expect(albumImageExtensions, contains(extension));
        expect(albumNeedsConversion('x$extension'), isTrue);
        expect(albumNeedsConversion('X${extension.toUpperCase()}'), isTrue);
      }
      expect(albumNeedsConversion('x.jpg'), isFalse);
      expect(albumNeedsConversion('x.heic'), isFalse);
    });

    test('they have short type labels, .tif and .tiff sharing one', () {
      expect(albumFileType('a.tif'), 'TIFF');
      expect(albumFileType('a.TIFF'), 'TIFF');
      expect(albumFileType('a.arw'), 'ARW');
      expect(albumFileType('a.FFF'), 'FFF');
    });

    test('a scan lists them, dated from inside', () async {
      await write('a.tif', img.encodeTiff(img.Image(width: 4, height: 4)));
      await write('b.TIFF', img.encodeTiff(img.Image(width: 4, height: 4)));
      await write(
        'c.arw',
        _tiffFile(shot: '2024:03:05 14:15:16', named: _smallJpeg(160, 120)),
      );
      await write('d.fff', _tiffFile(modified: '2023:01:02 03:04:05'));
      await write('e.txt', [1, 2, 3]);

      final photos = await loadAlbumPhotos(
        temp.path,
        cacheDirectory: Directory(p.join(temp.path, 'cache')),
        useCatalog: false,
      );

      expect(photos.map((photo) => photo.fileName).toSet(), {
        'a.tif',
        'b.TIFF',
        'c.arw',
        'd.fff',
      });
      DateTime? taken(String name) =>
          photos.singleWhere((photo) => photo.fileName == name).takenAt;
      expect(taken('c.arw'), DateTime(2024, 3, 5, 14, 15, 16));
      expect(taken('d.fff'), DateTime(2023, 1, 2, 3, 4, 5));
    });
  });

  group('reading the TIFF structure', () {
    test('the shot time wins over the file time', () async {
      final file = await write(
        'a.arw',
        _tiffFile(modified: '2020:01:01 00:00:00', shot: '2024:03:05 14:15:16'),
      );
      expect(
        await albumTiffCaptureDate(file),
        DateTime(2024, 3, 5, 14, 15, 16),
      );
    });

    test('the file time is the second choice', () async {
      final file = await write(
        'a.arw',
        _tiffFile(modified: '2020:01:01 00:00:00'),
      );
      expect(await albumTiffCaptureDate(file), DateTime(2020));
    });

    test('no date at all is null, and so is a zeroed clock', () async {
      expect(
        await albumTiffCaptureDate(await write('a.arw', _tiffFile())),
        isNull,
      );
      final zero = await write('b.arw', _tiffFile(shot: '0000:00:00 00:00:00'));
      expect(await albumTiffCaptureDate(zero), isNull);
    });

    test('something that is not a TIFF is not read', () async {
      final file = await write('a.arw', List.filled(100, 7));
      expect(await albumTiffCaptureDate(file), isNull);
      expect(await albumTiffSize(file), isNull);
    });

    test('the size is read without the picture', () async {
      final file = await write('a.arw', _tiffFile(width: 7040, height: 4688));
      final size = await albumTiffSize(file);
      expect(size!.width, 7040);
      expect(size.height, 4688);
    });
  });

  group('a camera raw shows its preview', () {
    test('the preview the file names is used as it is', () async {
      final preview = _noisyJpeg(600, 400);
      expect(preview.length, greaterThan(120 * 1024));
      final file = await write('a.arw', _tiffFile(named: preview));

      final bytes = await albumDecodableBytes(file.path);

      expect(bytes, preview);
    });

    test(
      'a bigger one the file does not name is found past a thumbnail',
      () async {
        final thumbnail = _smallJpeg(160, 120);
        final preview = _noisyJpeg(800, 500, seed: 3);
        final file = await write(
          'a.arw',
          _tiffFile(named: thumbnail, unnamed: preview),
        );

        final bytes = await albumDecodableBytes(file.path);

        expect(bytes, preview);
      },
    );

    test('a JPEG strip in a directory is a preview too', () async {
      final preview = _noisyJpeg(640, 480, seed: 5);
      final file = await write('a.fff', _tiffFile(stripJpeg: preview));

      expect(await albumDecodableBytes(file.path), preview);
    });

    test('a jpeg saved beside the raw is its full picture', () async {
      final raw = await write('shot.arw', _tiffFile());
      final jpeg = File('${p.dirname(raw.path)}/shot.JPG');
      await jpeg.writeAsBytes(_smallJpeg(32, 24));

      expect(
        p.basename(albumSiblingJpeg(raw)!.path).toLowerCase(),
        'shot.jpg',
      );
    });

    test('a full jpeg past a large named preview is the one shown', () async {
      // Big enough that the old search treated the named preview as final
      // and never read the full picture stored further on.
      final preview = _noisyJpeg(800, 700, seed: 2);
      expect(preview.length, greaterThan(120 * 1024));
      final full = _noisyJpeg(1200, 800, seed: 4);
      final file = await write(
        'a.arw',
        (BytesBuilder()
              ..add(_tiffFile(named: preview))
              ..add(Uint8List(5 << 20))
              ..add(full))
            .toBytes(),
      );

      expect(
        _sizeOf((await albumDecodableBytes(file.path))!),
        const Size(1200, 800),
      );
    });

    test('the biggest of several is the one', () async {
      final big = _noisyJpeg(900, 600, seed: 8);
      final middling = _noisyJpeg(240, 160, seed: 9);
      // Too small to be taken as the preview, so the file is searched.
      expect(middling.length, lessThan(120 * 1024));
      final file = await write(
        'a.arw',
        _tiffFile(named: middling, unnamed: big),
      );

      expect(await albumDecodableBytes(file.path), big);
    });

    test('lossless sensor data is never taken for a preview', () async {
      // What a Sony raw keeps beside its JPEG: a big "JPEG" that is the sensor
      // data, 14 bits a sample and lossless, which nothing can draw.
      final sensor = BytesBuilder()
        ..add([0xFF, 0xD8, 0xFF, 0xC3, 0x00, 0x0B, 0x0E])
        ..add([0x0F, 0xA0, 0x17, 0x70, 0x01, 0x01, 0x11, 0x00]) // 6000x4000
        ..add([0xFF, 0xDA, 0x00, 0x08, 0x01, 0x01, 0x00, 0x01, 0x00, 0x00])
        ..add(List.filled(400 * 1024, 0x55))
        ..add([0xFF, 0xD9]);
      final preview = _noisyJpeg(640, 420, seed: 4);
      final file = await write(
        'a.arw',
        _tiffFile(named: sensor.takeBytes(), unnamed: preview),
      );

      expect(await albumDecodableBytes(file.path), preview);
    });

    test('the camera\'s rotation is applied', () async {
      final preview = _noisyJpeg(600, 400, seed: 2);
      final file = await write(
        'a.arw',
        _tiffFile(named: preview, orientation: 6),
      );

      final bytes = await albumDecodableBytes(file.path);

      // Taken on its side: shown 400 wide and 600 tall.
      expect(_sizeOf(bytes!), const Size(400, 600));
    });

    test('an upright one is not touched', () async {
      final preview = _noisyJpeg(600, 400, seed: 2);
      final file = await write('a.arw', _tiffFile(named: preview));

      expect(
        _sizeOf((await albumDecodableBytes(file.path))!),
        const Size(600, 400),
      );
    });

    test(
      'a preview that claims to be upright is still turned from the raw',
      () async {
        // Sony often stamps Orientation=1 on landscape preview pixels while
        // the ARW's own IFD0 says the camera was on its side.
        final preview = _noisyJpeg(600, 400, seed: 2, orientation: 1);
        final file = await write(
          'a.arw',
          _tiffFile(named: preview, orientation: 6),
        );

        expect(
          _sizeOf((await albumDecodableBytes(file.path))!),
          const Size(400, 600),
        );
      },
    );

    test(
      'a preview that already carries the raw\'s orientation is not turned twice',
      () async {
        // decodeJpg applies the JPEG tag; handing the tagged bytes to Flutter
        // would turn them again (or leave them sideways). The result must be
        // upright pixels with no Orientation tag.
        final preview = _noisyJpeg(600, 400, seed: 2, orientation: 6);
        final file = await write(
          'a.arw',
          _tiffFile(named: preview, orientation: 6),
        );

        final bytes = await albumDecodableBytes(file.path);
        expect(_sizeOf(bytes!), const Size(400, 600));
        // A second decode must not swap the sides again.
        expect(_sizeOf(bytes), const Size(400, 600));
        final decoded = img.decodeJpg(bytes)!;
        expect(decoded.exif.imageIfd.hasOrientation, isFalse);
        expect(decoded.width, 400);
        expect(decoded.height, 600);
      },
    );

    test('a raw with no preview and no picture gives nothing', () async {
      final file = await write('a.arw', _tiffFile());
      expect(await albumDecodableBytes(file.path), isNull);
    });

    test('a file that is not a TIFF gives nothing', () async {
      final file = await write('a.arw', List.filled(5000, 1));
      expect(await albumDecodableBytes(file.path), isNull);
    });
  });

  group('a TIFF is decoded', () {
    Uint8List tiff(
      int width,
      int height, {
      bool alpha = false,
      int opacity = 200,
    }) {
      final image = img.Image(
        width: width,
        height: height,
        numChannels: alpha ? 4 : 3,
      );
      for (final pixel in image) {
        pixel
          ..r = pixel.x % 256
          ..g = pixel.y % 256
          ..b = 99;
        if (alpha) pixel.a = opacity;
      }
      return img.encodeTiff(image);
    }

    test('into something Flutter can draw, at its own size', () async {
      final file = await write('a.tif', tiff(300, 200));
      final bytes = await albumDecodableBytes(file.path);
      expect(_sizeOf(bytes!), const Size(300, 200));
    });

    test('shrunk when a size limit is given', () async {
      final file = await write('a.tiff', tiff(400, 200));
      final bytes = await albumDecodableBytes(file.path, maxSide: 100);
      expect(_sizeOf(bytes!), const Size(100, 50));
    });

    test('shrunk by its height when that is the longer side', () async {
      final file = await write('a.tiff', tiff(200, 400));
      final bytes = await albumDecodableBytes(file.path, maxSide: 100);
      expect(_sizeOf(bytes!), const Size(50, 100));
    });

    test('never made bigger than it is', () async {
      final file = await write('a.tif', tiff(80, 40));
      final bytes = await albumDecodableBytes(file.path, maxSide: 1000);
      expect(_sizeOf(bytes!), const Size(80, 40));
    });

    test('keeping see-through areas', () async {
      final file = await write('a.tif', tiff(30, 30, alpha: true));
      final bytes = await albumDecodableBytes(file.path);
      // A PNG, since a JPEG would turn transparency black.
      expect(bytes!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('with a spare fourth channel that is empty all through', () async {
      final file = await write('a.tif', tiff(30, 30, alpha: true, opacity: 0));
      final bytes = await albumDecodableBytes(file.path);
      // Shown as the picture it is, a JPEG, not as nothing at all.
      expect(bytes!.sublist(0, 3), [0xFF, 0xD8, 0xFF]);
    });
  });

  group('a TIFF with its colours in planes is decoded', () {
    // Pixels of random values with runs in them, so every kind of packing has
    // something to do.
    List<Uint8List> noisyPlanes(int width, int height, int count) {
      final random = Random(7);
      return [
        for (var plane = 0; plane < count; plane++)
          Uint8List.fromList([
            for (var i = 0; i < width * height; i++)
              if (i % 7 < 3) 40 * plane + 9 else random.nextInt(256),
          ]),
      ];
    }

    for (final compression in const {
      'uncompressed': 1,
      'LZW': 5,
      'deflate': 8,
      'PackBits': 32773,
    }.entries) {
      for (final predictor in const [false, true]) {
        for (final rows in const [16, 50]) {
          test(
            '${compression.key}, predictor $predictor, $rows rows a strip',
            () async {
              final planes = noisyPlanes(70, 50, 4);
              final file = await write(
                'a.tif',
                _planarTiff(
                  width: 70,
                  height: 50,
                  planes: planes,
                  compression: compression.value,
                  predictor: predictor,
                  rowsPerStrip: rows,
                  alpha: true,
                ),
              );

              // With see-through areas it comes out as a PNG, which loses
              // nothing, so every sample can be checked.
              final bytes = await albumDecodableBytes(file.path);
              final decoded = img.decodePng(bytes!)!;
              expect(decoded.width, 70);
              expect(decoded.height, 50);
              for (final pixel in decoded) {
                final at = pixel.y * 70 + pixel.x;
                expect(
                  [pixel.r, pixel.g, pixel.b, pixel.a],
                  [for (final plane in planes) plane[at]],
                  reason: 'pixel ${pixel.x},${pixel.y}',
                );
              }
            },
          );
        }
      }
    }

    // What an editor writes: the colours woven together, packed with the
    // predictor, in strips. The image package undoes the predictor for LZW
    // only, so a deflate one came out as a grey picture of edges.
    for (final compression in const {
      'uncompressed': 1,
      'LZW': 5,
      'deflate': 8,
      'PackBits': 32773,
    }.entries) {
      for (final sixteen in const [false, true]) {
        for (final predictor in const [false, true]) {
          test('woven, ${compression.key}, '
              '${sixteen ? 16 : 8} bits, predictor $predictor', () async {
            final planes = noisyPlanes(60, 45, 4);
            final file = await write(
              'a.tif',
              _planarTiff(
                width: 60,
                height: 45,
                planes: planes,
                compression: compression.value,
                predictor: predictor,
                rowsPerStrip: 10,
                alpha: true,
                interleaved: true,
                sixteenBit: sixteen,
              ),
            );

            final bytes = await albumDecodableBytes(file.path);
            final decoded = img.decodePng(bytes!)!;
            for (final pixel in decoded) {
              final at = pixel.y * 60 + pixel.x;
              expect(
                [pixel.r, pixel.g, pixel.b, pixel.a],
                [for (final plane in planes) plane[at]],
                reason: 'pixel ${pixel.x},${pixel.y}',
              );
            }
          });
        }
      }
    }

    test('greyscale, deflate with the predictor', () async {
      final plane = Uint8List(50 * 40);
      for (var i = 0; i < plane.length; i++) {
        plane[i] = (i % 50) * 5;
      }
      final file = await write(
        'a.tif',
        _planarTiff(
          width: 50,
          height: 40,
          planes: [plane],
          compression: 8,
          predictor: true,
          rowsPerStrip: 40,
          interleaved: true,
        ),
      );

      final decoded = img.decodeJpg((await albumDecodableBytes(file.path))!)!;
      final pixel = decoded.getPixel(20, 10);
      expect(pixel.r, closeTo(100, 6));
      expect(pixel.g, closeTo(100, 6));
      expect(pixel.b, closeTo(100, 6));
    });

    test('in colour, not black', () async {
      final planes = [
        Uint8List(40 * 30)..fillRange(0, 40 * 30, 200),
        Uint8List(40 * 30)..fillRange(0, 40 * 30, 100),
        Uint8List(40 * 30)..fillRange(0, 40 * 30, 50),
      ];
      final file = await write(
        'a.tif',
        _planarTiff(
          width: 40,
          height: 30,
          planes: planes,
          compression: 5,
          rowsPerStrip: 8,
        ),
      );

      final decoded = img.decodeJpg((await albumDecodableBytes(file.path))!)!;
      final pixel = decoded.getPixel(20, 15);
      expect(pixel.r, closeTo(200, 6));
      expect(pixel.g, closeTo(100, 6));
      expect(pixel.b, closeTo(50, 6));
    });
  });

  group('drawing them', () {
    Future<ui.Image> resolve(
      WidgetTester tester,
      ImageProvider provider,
    ) async {
      PaintingBinding.instance.imageCache
        ..clear()
        ..clearLiveImages();
      return (await tester.runAsync(() {
        final done = Completer<ui.Image>();
        final stream = provider.resolve(ImageConfiguration.empty);
        late final ImageStreamListener listener;
        listener = ImageStreamListener(
          (info, _) {
            if (!done.isCompleted) done.complete(info.image.clone());
            stream.removeListener(listener);
          },
          onError: (error, stack) {
            if (!done.isCompleted) done.completeError(error, stack);
          },
        );
        stream.addListener(listener);
        return done.future.timeout(const Duration(seconds: 30));
      }))!;
    }

    testWidgets('a raw gets a grid thumbnail from its preview', (tester) async {
      final file = (await tester.runAsync(
        () => write('a.arw', _tiffFile(named: _noisyJpeg(600, 400))),
      ))!;

      final image = await resolve(
        tester,
        AlbumThumbnailProvider(
          file,
          cacheDirectory: Directory(p.join(temp.path, 'cache')),
        ),
      );

      expect(image.width, albumThumbnailWidth);
      expect(image.height, 160);
    });

    testWidgets('a sideways raw gets an upright grid thumbnail', (
      tester,
    ) async {
      final file = (await tester.runAsync(
        () => write(
          'a.arw',
          _tiffFile(
            named: _noisyJpeg(600, 400, orientation: 1),
            orientation: 6,
          ),
        ),
      ))!;

      final image = await resolve(
        tester,
        AlbumThumbnailProvider(
          file,
          cacheDirectory: Directory(p.join(temp.path, 'cache')),
        ),
      );

      // 400×600 after the turn, then fitted to thumbnail width.
      expect(image.width, albumThumbnailWidth);
      expect(image.height, 360);
    });

    testWidgets('a sideways raw fits upright in the preview', (tester) async {
      final file = (await tester.runAsync(
        () => write(
          'a.arw',
          _tiffFile(
            named: _noisyJpeg(600, 400, seed: 7, orientation: 1),
            orientation: 6,
          ),
        ),
      ))!;

      final image = await resolve(
        tester,
        albumFittedProvider(file, const Size(400, 400)),
      );

      // 400×600 into a 400×400 box: height fills, width shrinks.
      expect(image.width, lessThan(image.height));
      expect(image.height, 400);
    });

    testWidgets('a TIFF gets one too', (tester) async {
      final image = img.Image(width: 1200, height: 800);
      for (final pixel in image) {
        pixel
          ..r = pixel.x % 256
          ..g = pixel.y % 256
          ..b = 1;
      }
      final file = (await tester.runAsync(
        () => write('a.tif', img.encodeTiff(image)),
      ))!;

      final thumbnail = await resolve(
        tester,
        AlbumThumbnailProvider(
          file,
          cacheDirectory: Directory(p.join(temp.path, 'cache')),
        ),
      );

      expect(thumbnail.width, albumThumbnailWidth);
      expect(thumbnail.height, 160);
    });

    testWidgets('the preview fits a raw to the window', (tester) async {
      final file = (await tester.runAsync(
        () => write('a.arw', _tiffFile(named: _noisyJpeg(800, 500))),
      ))!;

      final image = await resolve(
        tester,
        albumFittedProvider(file, const Size(400, 400)),
      );

      expect(image.width, 400);
      expect(image.height, 250);
    });

    testWidgets('a file with nothing to show is an error, not a hang', (
      tester,
    ) async {
      final file = (await tester.runAsync(
        () => write('a.arw', List.filled(5000, 1)),
      ))!;

      final error = await tester.runAsync(() {
        final failed = Completer<Object>();
        albumFittedProvider(file, const Size(400, 400))
            .resolve(ImageConfiguration.empty)
            .addListener(
              ImageStreamListener(
                (_, _) {},
                onError: (error, _) => failed.complete(error),
              ),
            );
        return failed.future.timeout(const Duration(seconds: 30));
      });

      expect(error, isA<FileSystemException>());
    });
  });

  test('a camera JPEG gives up its small preview without the whole file', () {
    // A thumbnail of four bytes, named by the EXIF directory that follows the
    // first one, which is where a camera puts it.
    final thumb = [0xFF, 0xD8, 0x11, 0xFF, 0xD9];
    final tiff = BytesBuilder();
    void longEntry(ByteData data, int at, int tag, int value) {
      data.setUint16(at, tag, Endian.little);
      data.setUint16(at + 2, 4, Endian.little);
      data.setUint32(at + 4, 1, Endian.little);
      data.setUint32(at + 8, value, Endian.little);
    }

    final ifd1 = 8 + 2 + 12 + 4;
    final thumbAt = ifd1 + 2 + 24 + 4;
    final bytes = ByteData(thumbAt);
    bytes
      ..setUint8(0, 0x49)
      ..setUint8(1, 0x49)
      ..setUint16(2, 42, Endian.little)
      ..setUint32(4, 8, Endian.little)
      ..setUint16(8, 1, Endian.little);
    longEntry(bytes, 10, 0x0100, 1);
    bytes.setUint32(22, ifd1, Endian.little);
    bytes.setUint16(ifd1, 2, Endian.little);
    longEntry(bytes, ifd1 + 2, 0x0201, thumbAt);
    longEntry(bytes, ifd1 + 14, 0x0202, thumb.length);
    tiff
      ..add(bytes.buffer.asUint8List())
      ..add(thumb);

    final exif = BytesBuilder()
      ..add([0x45, 0x78, 0x69, 0x66, 0x00, 0x00])
      ..add(tiff.takeBytes());
    final block = exif.takeBytes();
    final length = 2 + block.length;
    final jpeg = BytesBuilder()
      ..add([0xFF, 0xD8, 0xFF, 0xE1, length >> 8, length & 0xFF])
      ..add(block)
      ..add(List.filled(2 * 1024 * 1024, 0));

    expect(albumJpegEmbeddedThumbnailBytes(jpeg.takeBytes()), thumb);
  });
}
