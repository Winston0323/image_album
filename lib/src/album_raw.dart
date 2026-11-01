import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

/// Extensions of files Flutter cannot draw by itself, which the album turns
/// into something it can: TIFF, Hasselblad/Imacon FFF and Sony ARW.
///
/// All of them are TIFF containers. Camera raws (ARW, FFF) carry a JPEG
/// preview made by the camera, which is what the album shows, rather than
/// developing the sensor data. A plain TIFF is decoded.
const Set<String> albumConvertedExtensions = {'.tif', '.tiff', '.fff', '.arw'};

/// Whether the file at [path] has to go through [albumDecodableBytes] before
/// Flutter can draw it.
bool albumNeedsConversion(String path) =>
    albumConvertedExtensions.contains(p.extension(path).toLowerCase());

/// Largest TIFF, in pixels, that is decoded in full. A decoded frame takes
/// four bytes a pixel and more while it is worked on, so beyond this the
/// photo is shown without rather than risk running out of memory.
const int _maxDecodePixels = 120 * 1000 * 1000;

/// A preview with at least this many pixels is taken as the photo's real
/// preview. A smaller one is only a thumbnail, and the rest of the file is
/// searched for better.
const int _goodPreviewPixels = 500 * 1000;

/// How far into a file the search for a preview goes.
const int _searchBytes = 96 << 20;

/// How far past a good preview the search goes for a better one.
const int _searchPastBest = 4 << 20;

/// Bytes read at a time while searching.
const int _chunkBytes = 1 << 20;

/// The photo in [path] as bytes Flutter can decode (a JPEG or a PNG), or null
/// when there is nothing to show.
///
/// Camera raws give their embedded JPEG preview, as it is. A TIFF is decoded,
/// shrunk so its longer side is at most [maxSide] when given, and encoded
/// again. The camera's rotation is applied to either, so the result is the
/// right way up.
///
/// This is slow and heavy, so run it on a background isolate.
Future<Uint8List?> albumDecodableBytes(String path, {int? maxSide}) async {
  try {
    final extension = p.extension(path).toLowerCase();
    final file = File(path);
    final tiff = extension == '.tif' || extension == '.tiff';

    final orientation = await _orientationOf(file);

    if (!tiff) {
      final preview = await _embeddedJpeg(file);
      if (preview != null) {
        return orientation == 1 ? preview : _rotated(preview, orientation);
      }
    }

    final decoded = await _decodeTiff(file, orientation, maxSide);
    if (decoded != null) return decoded;

    if (tiff) {
      // A TIFF that will not decode may still carry a JPEG.
      final preview = await _embeddedJpeg(file);
      if (preview != null) {
        return orientation == 1 ? preview : _rotated(preview, orientation);
      }
    }
  } catch (_) {
    // Unreadable or not what its name says: nothing to show.
  }
  return null;
}

/// When the shot was taken, read from the EXIF block of a TIFF-based file
/// without reading the file: only a few small pieces are fetched, wherever
/// they lie. Null when it has no date.
Future<DateTime?> albumTiffCaptureDate(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final tiff = await _Tiff.open(raf);
    if (tiff == null) return null;
    final ifd0 = await tiff.readIfd(tiff.firstIfd);
    if (ifd0 == null) return null;

    final exifOffset = await tiff.integer(ifd0.entries[0x8769]);
    if (exifOffset != null) {
      final exif = await tiff.readIfd(exifOffset);
      if (exif != null) {
        for (final tag in const [0x9003, 0x9004]) {
          final date = _parseExifDate(await tiff.text(exif.entries[tag]));
          if (date != null) return date;
        }
      }
    }
    return _parseExifDate(await tiff.text(ifd0.entries[0x0132]));
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// Pixel size of a TIFF-based file: the largest picture in it, which for a
/// camera raw is the sensor data rather than the preview. Null when it cannot
/// be told.
Future<({int width, int height})?> albumTiffSize(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final tiff = await _Tiff.open(raf);
    if (tiff == null) return null;

    ({int width, int height})? best;
    final queue = <int>[tiff.firstIfd];
    final seen = <int>{};
    while (queue.isNotEmpty && seen.length < 24) {
      final offset = queue.removeAt(0);
      if (!seen.add(offset)) continue;
      final ifd = await tiff.readIfd(offset);
      if (ifd == null) continue;
      final width = await tiff.integer(ifd.entries[0x0100]);
      final height = await tiff.integer(ifd.entries[0x0101]);
      if (width != null && height != null && width > 0 && height > 0) {
        if (best == null || width * height > best.width * best.height) {
          best = (width: width, height: height);
        }
      }
      queue.addAll(await tiff.integers(ifd.entries[0x014A], 16));
      if (ifd.next != 0) queue.add(ifd.next);
    }
    return best;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

DateTime? _parseExifDate(String? raw) {
  if (raw == null) return null;
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(raw.trim());
  if (match == null) return null;
  final year = int.parse(match[1]!);
  // An unset camera clock writes zeros.
  if (year == 0) return null;
  return DateTime(
    year,
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

/// The EXIF orientation of a TIFF-based file, 1 (upright) when unknown.
Future<int> _orientationOf(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final tiff = await _Tiff.open(raf);
    if (tiff == null) return 1;
    final ifd0 = await tiff.readIfd(tiff.firstIfd);
    final value = await tiff.integer(ifd0?.entries[0x0112]);
    return value != null && value >= 1 && value <= 8 ? value : 1;
  } catch (_) {
    return 1;
  } finally {
    await raf?.close();
  }
}

/// [jpeg] turned to the upright position for EXIF [orientation].
Uint8List? _rotated(Uint8List jpeg, int orientation) {
  final decoded = img.decodeJpg(jpeg);
  if (decoded == null) return jpeg;
  // A preview that says which way up it is has already been dealt with by
  // whoever made it, and Flutter honours that. Only one that says nothing is
  // turned here.
  if (decoded.exif.imageIfd.hasOrientation) return jpeg;
  final upright = _bake(decoded, orientation);
  return img.encodeJpg(upright, quality: 92);
}

img.Image _bake(img.Image image, int orientation) {
  if (orientation == 1) return image;
  image.exif.imageIfd.orientation = orientation;
  return img.bakeOrientation(image);
}

Future<Uint8List?> _decodeTiff(File file, int orientation, int? maxSide) async {
  final size = await albumTiffSize(file);
  if (size != null && size.width * size.height > _maxDecodePixels) return null;

  // The decoder of the image package reads the colours of a TIFF that keeps
  // them in separate planes (what some scanners and converters write) as
  // black or grey, so those are read here.
  final decoded =
      await _decodeStripTiff(file) ?? img.decodeTiff(await file.readAsBytes());
  if (decoded == null) return null;

  // Whatever the decoder produced, down to 8 bits of colour, with a channel
  // for see-through only when there is one. A fourth channel that is empty
  // all through is not see-through, it is a scanner's spare, and would make
  // the picture vanish.
  var image = decoded.convert(
    format: img.Format.uint8,
    numChannels: decoded.hasAlpha && !_allTransparent(decoded) ? 4 : 3,
    noAnimation: true,
  );

  if (maxSide != null && maxSide > 0) {
    final longest = image.width > image.height ? image.width : image.height;
    if (longest > maxSide) {
      image = image.width >= image.height
          ? img.copyResize(
              image,
              width: maxSide,
              interpolation: img.Interpolation.average,
            )
          : img.copyResize(
              image,
              height: maxSide,
              interpolation: img.Interpolation.average,
            );
    }
  }

  image = _bake(image, orientation);

  return image.hasAlpha
      ? img.encodePng(image)
      : img.encodeJpg(image, quality: 92);
}

bool _allTransparent(img.Image image) {
  for (final pixel in image) {
    if (pixel.a != 0) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// TIFFs the image package reads wrongly

/// The first picture of a TIFF cut in strips, as 8-bit RGB (or RGBA), or null
/// for one this does not read, which is then left to the decoder of the image
/// package.
///
/// That decoder undoes the horizontal predictor only for LZW (so a deflate
/// TIFF with a predictor, which Photoshop and many editors write, comes out as
/// a grey picture of edges), does it a byte at a time for 16-bit samples, and
/// reads colours kept in separate planes as black or grey. This reads
/// greyscale and RGB(A) of 8 or 16 bits a sample, interleaved or in planes,
/// uncompressed, LZW, deflate or PackBits, with or without the predictor. Tiled
/// and JPEG-compressed TIFFs are not taken here.
Future<img.Image?> _decodeStripTiff(File file) async {
  final raf = await file.open();
  try {
    final tiff = await _Tiff.open(raf);
    if (tiff == null) return null;
    final ifd = await tiff.readIfd(tiff.firstIfd);
    if (ifd == null) return null;

    Future<int?> one(int tag) => tiff.integer(ifd.entries[tag]);

    final planar = await one(0x011C) ?? 1;
    final width = await one(0x0100);
    final height = await one(0x0101);
    final samples = await one(0x0115) ?? 1;
    final compression = await one(0x0103) ?? 1;
    final photometric = await one(0x0106);
    final predictor = await one(0x013D) ?? 1;
    final format = await one(0x0153) ?? 1;
    if (width == null || height == null || width < 1 || height < 1) return null;
    if (width * height > _maxDecodePixels) return null;
    // Tiles, other layouts, floating point and signed samples are not read.
    if (ifd.entries.containsKey(0x0142) || (planar != 1 && planar != 2)) {
      return null;
    }
    if (format != 1 || (predictor != 1 && predictor != 2)) return null;

    final gray = photometric == 0 || photometric == 1;
    if (gray
        ? samples != 1
        : (photometric != 2 || samples < 3 || samples > 4)) {
      return null;
    }

    final bits = await tiff.integers(ifd.entries[0x0102], 4);
    if (bits.length < samples || bits.any((b) => b != bits.first)) return null;
    final bytesPerSample = switch (bits.first) {
      8 => 1,
      16 => 2,
      _ => 0,
    };
    if (bytesPerSample == 0) return null;

    // The alpha channel is only kept when the file says it is one.
    final extra = await tiff.integers(ifd.entries[0x0152], 4);
    final keepAlpha = samples == 4 && extra.isNotEmpty && extra.first != 0;
    final channels = keepAlpha ? 4 : 3;
    final inPlanes = planar == 2 && samples > 1;

    final rowsPerStrip = math.min(await one(0x0116) ?? height, height);
    final strips = (height + rowsPerStrip - 1) ~/ rowsPerStrip;
    final planes = inPlanes ? channels : 1;
    final offsets = await tiff.integers(ifd.entries[0x0111], 1 << 20);
    final counts = await tiff.integers(ifd.entries[0x0117], 1 << 20);
    final needed = strips * (inPlanes ? samples : 1);
    if (offsets.length < needed || counts.length < needed) return null;

    // What a strip holds a pixel as: all its samples together, or one.
    final perPixel = inPlanes ? 1 : samples;
    // Sixteen bits are cut to their top byte.
    final high = bytesPerSample == 1 ? 0 : (tiff.isLittle ? 1 : 0);

    final pixels = Uint8List(width * height * channels);
    for (var plane = 0; plane < planes; plane++) {
      for (var strip = 0; strip < strips; strip++) {
        final index = plane * strips + strip;
        final firstRow = strip * rowsPerStrip;
        final rows = math.min(rowsPerStrip, height - firstRow);
        final expected = rows * width * perPixel * bytesPerSample;

        await raf.setPosition(offsets[index]);
        final packed = await raf.read(counts[index]);
        if (packed.length < counts[index]) return null;
        final data = _unpack(packed, compression, expected);
        if (data == null || data.length < expected) return null;

        if (predictor == 2) {
          _undoPredictor(
            data,
            width * perPixel,
            rows,
            perPixel,
            bytesPerSample,
            tiff.isLittle,
          );
        }

        final step = perPixel * bytesPerSample;
        for (var i = 0; i < rows * width; i++) {
          final at = (firstRow * width + i) * channels;
          final from = i * step + high;
          if (inPlanes) {
            pixels[at + plane] = data[from];
          } else if (gray) {
            final value = photometric == 0 ? 255 - data[from] : data[from];
            pixels[at] = value;
            pixels[at + 1] = value;
            pixels[at + 2] = value;
          } else {
            for (var c = 0; c < channels; c++) {
              pixels[at + c] = data[from + c * bytesPerSample];
            }
          }
        }
      }
    }
    return img.Image.fromBytes(
      width: width,
      height: height,
      bytes: pixels.buffer,
      numChannels: channels,
    );
  } catch (_) {
    return null;
  } finally {
    await raf.close();
  }
}

/// [packed] with TIFF compression number [compression] undone, or null for one
/// that is not handled. [expected] is the size it comes to.
Uint8List? _unpack(Uint8List packed, int compression, int expected) {
  switch (compression) {
    case 1:
      return packed;
    case 5:
      return _lzwDecode(packed, expected);
    case 8:
    case 32946:
      return Uint8List.fromList(zlib.decode(packed));
    case 32773:
      return _packBitsDecode(packed, expected);
    default:
      return null;
  }
}

/// Adds each sample to the one [stride] samples before it along its row,
/// which undoes the horizontal predictor TIFF writers may apply before
/// compressing. A row is [samplesPerRow] samples, of 1 or 2 bytes each.
void _undoPredictor(
  Uint8List data,
  int samplesPerRow,
  int rows,
  int stride,
  int bytesPerSample,
  bool little,
) {
  if (bytesPerSample == 1) {
    for (var row = 0; row < rows; row++) {
      final start = row * samplesPerRow;
      for (var x = stride; x < samplesPerRow; x++) {
        data[start + x] = (data[start + x] + data[start + x - stride]) & 0xFF;
      }
    }
    return;
  }
  final view = ByteData.sublistView(data);
  final order = little ? Endian.little : Endian.big;
  for (var row = 0; row < rows; row++) {
    final start = row * samplesPerRow * 2;
    for (var x = stride; x < samplesPerRow; x++) {
      final at = start + x * 2;
      view.setUint16(
        at,
        (view.getUint16(at, order) + view.getUint16(at - stride * 2, order)) &
            0xFFFF,
        order,
      );
    }
  }
}

Uint8List _packBitsDecode(Uint8List data, int expected) {
  final out = Uint8List(expected);
  var read = 0;
  var write = 0;
  while (read < data.length && write < expected) {
    final control = data[read++];
    if (control < 128) {
      // That many bytes plus one, as they are.
      final count = control + 1;
      for (
        var i = 0;
        i < count && read < data.length && write < expected;
        i++
      ) {
        out[write++] = data[read++];
      }
    } else if (control > 128) {
      // The next byte, repeated.
      final count = 257 - control;
      if (read >= data.length) break;
      final value = data[read++];
      for (var i = 0; i < count && write < expected; i++) {
        out[write++] = value;
      }
    }
  }
  return out;
}

/// TIFF's LZW: codes from 9 to 12 bits, most significant bit first, with the
/// code width growing one code early.
Uint8List? _lzwDecode(Uint8List data, int expected) {
  const clear = 256;
  const end = 257;
  // The longest string a code can stand for is 4096 bytes, so a little room
  // past the end lets the last string be written without checking.
  final out = Uint8List(expected + 4096);
  final prefix = Int32List(4096);
  final suffix = Uint8List(4096);
  final length = Int32List(4096);
  for (var i = 0; i < 256; i++) {
    length[i] = 1;
  }

  var written = 0;
  var bitBuffer = 0;
  var bitCount = 0;
  var position = 0;
  var codeSize = 9;
  var next = 258;
  var previous = -1;

  int readCode() {
    while (bitCount < codeSize) {
      if (position >= data.length) return end;
      bitBuffer = (bitBuffer << 8) | data[position++];
      bitCount += 8;
    }
    final code = (bitBuffer >> (bitCount - codeSize)) & ((1 << codeSize) - 1);
    bitCount -= codeSize;
    bitBuffer &= (1 << bitCount) - 1;
    return code;
  }

  /// Writes what [code] stands for and returns its first byte.
  int emit(int code) {
    final size = length[code];
    var at = written + size - 1;
    var current = code;
    while (current >= 258) {
      out[at--] = suffix[current];
      current = prefix[current];
    }
    out[at] = current;
    written += size;
    return current;
  }

  while (written < expected) {
    final code = readCode();
    if (code == end) break;
    if (code == clear) {
      codeSize = 9;
      next = 258;
      previous = -1;
      continue;
    }
    if (previous == -1) {
      if (code >= 256) return null;
      out[written++] = code;
      previous = code;
      continue;
    }

    final int first;
    if (code < next) {
      first = emit(code);
    } else if (code == next) {
      // A string that starts with itself: what came before, and its own first
      // byte once more.
      first = emit(previous);
      out[written] = first;
      written++;
    } else {
      return null;
    }

    if (next < 4096) {
      prefix[next] = previous;
      suffix[next] = first;
      length[next] = length[previous] + 1;
      next++;
      if (next >= (1 << codeSize) - 1 && codeSize < 12) codeSize++;
    }
    previous = code;
  }
  return Uint8List.sublistView(out, 0, expected);
}

// ---------------------------------------------------------------------------
// Finding the preview

/// The preview a raw names in its TIFF directories. Only those directories
/// are read, not the rest of the file, so a grid tile can be drawn while the
/// card is still being listed. Null when the file names none.
Future<Uint8List?> albumEmbeddedPreview(File file) async {
  RandomAccessFile? raf;
  try {
    raf = await file.open();
    final best = await _jpegFromDirectories(raf, await raf.length());
    // A pointer at the sensor data is not a preview.
    if (best == null || best.length < 4096 || best.length > (8 << 20)) {
      return null;
    }
    await raf.setPosition(best.offset);
    final bytes = await raf.read(best.length);
    return bytes.length == best.length ? bytes : null;
  } catch (_) {
    return null;
  } finally {
    await raf?.close();
  }
}

/// The biggest JPEG inside [file], or null when there is none.
///
/// First the picture directories of the TIFF structure are asked, which is
/// quick. When they only hold a thumbnail, the file is searched for JPEG data
/// itself, since cameras keep their large previews in places (a maker note)
/// that differ from one to the next.
Future<Uint8List?> _embeddedJpeg(File file) async {
  final raf = await file.open();
  try {
    final length = await raf.length();
    var best = await _jpegFromDirectories(raf, length);
    if (best == null || best.pixels < _goodPreviewPixels) {
      final found = await _searchJpegs(raf, length);
      if (found != null && (best == null || found.pixels > best.pixels)) {
        best = found;
      }
    }
    if (best == null) return null;
    await raf.setPosition(best.offset);
    final bytes = await raf.read(best.length);
    return bytes.length == best.length ? bytes : null;
  } finally {
    await raf.close();
  }
}

/// A JPEG found in a file: where it starts, how long it is and how many
/// pixels.
typedef _Span = ({int offset, int length, int width, int height});

extension on _Span {
  int get pixels => width * height;
}

/// JPEGs the TIFF structure points at: thumbnails and previews named by the
/// JPEG-interchange tags, or held as the one strip of a JPEG-compressed
/// picture. The biggest is returned.
Future<_Span?> _jpegFromDirectories(RandomAccessFile raf, int length) async {
  final tiff = await _Tiff.open(raf);
  if (tiff == null) return null;

  final candidates = <(int, int)>[];
  final queue = <int>[tiff.firstIfd];
  final seen = <int>{};
  while (queue.isNotEmpty && seen.length < 24) {
    final offset = queue.removeAt(0);
    if (!seen.add(offset)) continue;
    final ifd = await tiff.readIfd(offset);
    if (ifd == null) continue;

    final start = await tiff.integer(ifd.entries[0x0201]);
    final size = await tiff.integer(ifd.entries[0x0202]);
    if (start != null && size != null) candidates.add((start, size));

    final compression = await tiff.integer(ifd.entries[0x0103]);
    if (compression == 6 || compression == 7) {
      final starts = await tiff.integers(ifd.entries[0x0111], 2);
      final sizes = await tiff.integers(ifd.entries[0x0117], 2);
      if (starts.length == 1 && sizes.length == 1) {
        candidates.add((starts.single, sizes.single));
      }
    }

    queue.addAll(await tiff.integers(ifd.entries[0x014A], 16));
    if (ifd.next != 0) queue.add(ifd.next);
  }

  _Span? best;
  for (final (offset, size) in candidates) {
    if (offset < 8 || size < 4 || offset + size > length) continue;
    // What is named may be sensor data that only looks like a JPEG, so it
    // is checked, not taken on trust.
    final found = await _probeJpeg(raf, offset, length);
    if (found != null && (best == null || found.pixels > best.pixels)) {
      best = found;
    }
  }
  return best;
}

/// Looks through the start of [raf] for JPEG data and returns the biggest
/// piece. A JPEG is recognised by its start and measured by walking its
/// segments to the end marker, so one found inside another is not counted.
Future<_Span?> _searchJpegs(RandomAccessFile raf, int length) async {
  final limit = length < _searchBytes ? length : _searchBytes;
  _Span? best;
  var position = 0;
  while (position + 4 <= limit) {
    await raf.setPosition(position);
    final chunk = await raf.read(
      limit - position < _chunkBytes ? limit - position : _chunkBytes,
    );
    if (chunk.length < 4) break;

    var skipTo = -1;
    var at = chunk.indexOf(0xFF);
    while (at >= 0 && at + 3 < chunk.length) {
      if (chunk[at + 1] == 0xD8 && chunk[at + 2] == 0xFF) {
        final found = await _probeJpeg(raf, position + at, length);
        if (found != null && found.length >= 4096) {
          if (best == null || found.pixels > best.pixels) best = found;
          // Whatever lies inside it belongs to it.
          skipTo = found.offset + found.length;
          break;
        }
      }
      at = chunk.indexOf(0xFF, at + 1);
    }

    if (skipTo >= 0) {
      position = skipTo;
    } else {
      // Overlap the next read, so a start marker on the boundary is found.
      position += chunk.length - 3;
    }

    // A real preview is found early. Once one is in hand and a few more
    // megabytes hold nothing bigger, the sensor data that follows is not
    // worth reading through.
    if (best != null &&
        best.pixels >= _goodPreviewPixels &&
        position > best.offset + best.length + _searchPastBest) {
      break;
    }
  }
  return best;
}

/// The JPEG that starts at [start]: its length and size in pixels. Null when
/// what is there is not a whole JPEG, or not one Flutter can draw.
///
/// Camera raws keep their sensor data as a JPEG too, a lossless one at 12 to
/// 16 bits, which shares the start of an ordinary photo and is of no use as a
/// picture. Only the kinds a browser would show (baseline, extended and
/// progressive Huffman, 8 bits) are accepted.
Future<_Span?> _probeJpeg(
  RandomAccessFile raf,
  int start,
  int fileLength,
) async {
  await raf.setPosition(start);
  final soi = await raf.read(3);
  if (soi.length < 3 || soi[0] != 0xFF || soi[1] != 0xD8 || soi[2] != 0xFF) {
    return null;
  }
  var position = start + 2;
  int? width;
  int? height;
  while (true) {
    if (position + 4 > fileLength) return null;
    await raf.setPosition(position);
    final head = await raf.read(4);
    if (head.length < 4 || head[0] != 0xFF) return null;
    final marker = head[1];
    if (marker == 0xFF) {
      position++; // padding
      continue;
    }
    if (marker == 0xD9) {
      return width == null
          ? null
          : (
              offset: start,
              length: position + 2 - start,
              width: width,
              height: height!,
            );
    }
    if (marker == 0x01 || (marker >= 0xD0 && marker <= 0xD8)) {
      position += 2; // a marker without a body
      continue;
    }
    final size = (head[2] << 8) | head[3];
    if (size < 2) return null;

    // A frame header: the kind of coding, the precision and the size.
    final isFrame =
        marker >= 0xC0 &&
        marker <= 0xCF &&
        marker != 0xC4 &&
        marker != 0xC8 &&
        marker != 0xCC;
    if (isFrame) {
      if (marker > 0xC2 || size < 8) return null;
      await raf.setPosition(position + 4);
      final frame = await raf.read(5);
      if (frame.length < 5 || frame[0] != 8) return null;
      height = (frame[1] << 8) | frame[2];
      width = (frame[3] << 8) | frame[4];
      if (width < 1 || height < 1) return null;
    }

    position += 2 + size;
    if (marker == 0xDA) {
      if (width == null) return null;
      final end = await _findEndMarker(raf, position, fileLength);
      return end == null
          ? null
          : (offset: start, length: end - start, width: width, height: height!);
    }
  }
}

/// Where the first end-of-image marker at or after [from] finishes. Inside
/// compressed data a 0xFF is always followed by 0x00 or a restart marker, so
/// 0xFF 0xD9 is the end.
Future<int?> _findEndMarker(
  RandomAccessFile raf,
  int from,
  int fileLength,
) async {
  var position = from;
  while (position < fileLength) {
    await raf.setPosition(position);
    final chunk = await raf.read(
      fileLength - position < 256 * 1024 ? fileLength - position : 256 * 1024,
    );
    if (chunk.isEmpty) return null;
    var at = chunk.indexOf(0xFF);
    while (at >= 0 && at + 1 < chunk.length) {
      if (chunk[at + 1] == 0xD9) return position + at + 2;
      at = chunk.indexOf(0xFF, at + 1);
    }
    position += chunk.length - 1;
    if (chunk.length < 2) return null;
  }
  return null;
}

/// The small JPEG a camera stores inside a JPEG's EXIF, or null when [file]
/// has none in its opening bytes. A large camera JPEG can be read as a
/// thumbnail from this instead of from the whole file.
Future<Uint8List?> albumJpegEmbeddedThumbnail(File file) async {
  if (await file.length() < 1024 * 1024) return null;
  final raf = await file.open();
  try {
    final head = await raf.read(512 * 1024);
    final found = albumJpegEmbeddedThumbnailBytes(head);
    if (found != null) return found;
    return null;
  } catch (_) {
    return null;
  } finally {
    await raf.close();
  }
}

/// [albumJpegEmbeddedThumbnail] for bytes already in hand: the start of a
/// JPEG. The thumbnail's position is measured from the EXIF block.
Uint8List? albumJpegEmbeddedThumbnailBytes(Uint8List data) {
  if (data.length < 4 || data[0] != 0xFF || data[1] != 0xD8) return null;
  var i = 2;
  while (i + 4 < data.length) {
    if (data[i] != 0xFF) return null;
    while (i < data.length && data[i] == 0xFF) {
      i++;
    }
    if (i >= data.length) return null;
    final marker = data[i++];
    // The compressed image starts here, and a restart marker has no length.
    if (marker == 0xDA || marker == 0xD9) return null;
    if (marker >= 0xD0 && marker <= 0xD7) continue;
    if (i + 2 > data.length) return null;
    final length = (data[i] << 8) | data[i + 1];
    if (length < 2 || i + length > data.length) return null;
    if (marker == 0xE1) {
      final thumb = _thumbnailInExif(data.sublist(i + 2, i + length));
      if (thumb != null) return thumb;
    }
    i += length;
  }
  return null;
}

/// The JPEG named by an EXIF block's thumbnail tags, or null.
Uint8List? _thumbnailInExif(Uint8List payload) {
  const exif = [0x45, 0x78, 0x69, 0x66, 0x00, 0x00];
  if (payload.length < exif.length + 8) return null;
  for (var i = 0; i < exif.length; i++) {
    if (payload[i] != exif[i]) return null;
  }
  final tiff = Uint8List.sublistView(payload, exif.length);
  final little = tiff[0] == 0x49 && tiff[1] == 0x49;
  final big = tiff[0] == 0x4D && tiff[1] == 0x4D;
  if (!little && !big) return null;
  final order = little ? Endian.little : Endian.big;
  final view = ByteData.sublistView(tiff);
  int u16(int offset) => offset >= 0 && offset + 2 <= tiff.length
      ? view.getUint16(offset, order)
      : -1;
  int u32(int offset) => offset >= 0 && offset + 4 <= tiff.length
      ? view.getUint32(offset, order)
      : -1;
  if (u16(2) != 42) return null;

  var directory = u32(4);
  for (var hop = 0; hop < 4 && directory > 0; hop++) {
    final count = u16(directory);
    if (count <= 0 || count > 2000) return null;
    int? at;
    int? bytes;
    for (var entry = 0; entry < count; entry++) {
      final start = directory + 2 + entry * 12;
      if (start + 12 > tiff.length) break;
      final tag = u16(start);
      final type = u16(start + 2);
      final countOf = u32(start + 4);
      final inline = type == 3 ? u16(start + 8) : u32(start + 8);
      final value = countOf > 1 ? u32(start + 8) : inline;
      if (tag == 0x0201) at = value;
      if (tag == 0x0202) bytes = value;
    }
    if (at != null &&
        bytes != null &&
        bytes > 4 &&
        at >= 0 &&
        at + bytes <= tiff.length &&
        tiff[at] == 0xFF &&
        tiff[at + 1] == 0xD8) {
      return Uint8List.sublistView(tiff, at, at + bytes);
    }
    final nextAt = directory + 2 + count * 12;
    directory = u32(nextAt);
  }
  return null;
}

// ---------------------------------------------------------------------------
// A small TIFF reader

/// One entry of a TIFF directory: where its value lies and how it is stored.
class _Entry {
  const _Entry(this.type, this.count, this.position);

  final int type;
  final int count;

  /// Where the value's bytes begin in the file.
  final int position;

  int get size => count * _typeSize(type);
}

int _typeSize(int type) => switch (type) {
  1 || 2 || 6 || 7 => 1,
  3 || 8 => 2,
  4 || 9 || 11 => 4,
  5 || 10 || 12 => 8,
  _ => 0,
};

class _Ifd {
  const _Ifd(this.entries, this.next);

  final Map<int, _Entry> entries;

  /// Offset of the next directory, 0 for the last.
  final int next;
}

/// Reads directories and values of a TIFF file with seeks, so a file of
/// hundreds of megabytes costs a few kilobytes of reading.
class _Tiff {
  _Tiff._(this._raf, this._order, this.length, this.firstIfd);

  final RandomAccessFile _raf;
  final Endian _order;
  final int length;
  final int firstIfd;

  bool get isLittle => _order == Endian.little;

  /// Null when [raf] does not hold a classic TIFF structure.
  static Future<_Tiff?> open(RandomAccessFile raf) async {
    final length = await raf.length();
    if (length < 8) return null;
    await raf.setPosition(0);
    final head = await raf.read(8);
    if (head.length < 8) return null;
    final Endian order;
    if (head[0] == 0x49 && head[1] == 0x49) {
      order = Endian.little;
    } else if (head[0] == 0x4D && head[1] == 0x4D) {
      order = Endian.big;
    } else {
      return null;
    }
    final data = ByteData.sublistView(head);
    if (data.getUint16(2, order) != 42) return null;
    return _Tiff._(raf, order, length, data.getUint32(4, order));
  }

  Future<_Ifd?> readIfd(int offset) async {
    if (offset < 8 || offset + 2 > length) return null;
    await _raf.setPosition(offset);
    final countBytes = await _raf.read(2);
    if (countBytes.length < 2) return null;
    final count = ByteData.sublistView(countBytes).getUint16(0, _order);
    if (count == 0 || count > 2000) return null;

    final body = await _raf.read(count * 12 + 4);
    if (body.length < count * 12 + 4) return null;
    final data = ByteData.sublistView(body);
    final entries = <int, _Entry>{};
    for (var i = 0; i < count; i++) {
      final at = i * 12;
      final tag = data.getUint16(at, _order);
      final type = data.getUint16(at + 2, _order);
      final n = data.getUint32(at + 4, _order);
      final size = n * _typeSize(type);
      final position = size <= 4
          ? offset + 2 + at + 8
          : data.getUint32(at + 8, _order);
      if (_typeSize(type) == 0 || position + size > length) continue;
      entries[tag] = _Entry(type, n, position);
    }
    return _Ifd(entries, data.getUint32(count * 12, _order));
  }

  /// The first number of a short, long or byte entry.
  Future<int?> integer(_Entry? entry) async {
    final values = await integers(entry, 1);
    return values.isEmpty ? null : values.first;
  }

  /// Up to [max] numbers of a short, long or byte entry.
  Future<List<int>> integers(_Entry? entry, int max) async {
    if (entry == null) return const [];
    final size = _typeSize(entry.type);
    if (entry.type != 1 && entry.type != 3 && entry.type != 4) return const [];
    final n = entry.count < max ? entry.count : max;
    await _raf.setPosition(entry.position);
    final bytes = await _raf.read(n * size);
    if (bytes.length < n * size) return const [];
    final data = ByteData.sublistView(bytes);
    return [
      for (var i = 0; i < n; i++)
        switch (size) {
          1 => data.getUint8(i),
          2 => data.getUint16(i * 2, _order),
          _ => data.getUint32(i * 4, _order),
        },
    ];
  }

  /// An ASCII entry, without its terminating zero.
  Future<String?> text(_Entry? entry) async {
    if (entry == null || entry.type != 2 || entry.count > 4096) return null;
    await _raf.setPosition(entry.position);
    final bytes = await _raf.read(entry.count);
    final end = bytes.indexOf(0);
    return String.fromCharCodes(end < 0 ? bytes : bytes.sublist(0, end));
  }
}
