import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'album_cache.dart';
import 'album_library.dart';

/// Width, in pixels, photos are decoded at for grid tiles.
const int albumThumbnailWidth = 240;

/// JPEG quality of stored thumbnails. At this size 80 is visually clean and
/// keeps a thumbnail around 10 KB.
const int albumThumbnailQuality = 80;

/// Most the thumbnail cache is allowed to grow to before the oldest are
/// deleted.
const int albumThumbnailCacheMaxBytes = 256 << 20;

/// Grid-tile image for [file]. Also the placeholder the preview shows while
/// the larger decode is still loading, and because both use this provider,
/// the preview finds it already in the image cache.
///
/// With a [library], the thumbnail is kept in that album file and made to its
/// cache options. Without, it goes in the system temp directory.
ImageProvider albumThumbnailProvider(File file, {AlbumLibrary? library}) {
  if (library == null) return AlbumThumbnailProvider(file);
  final cache = library.cache;
  return AlbumThumbnailProvider(
    file,
    width: cache.thumbnailWidth,
    quality: cache.thumbnailQuality,
    maxCacheBytes: cache.thumbnailMaxBytes,
    cacheDirectory: library.thumbnailDirectory,
  );
}

/// [file] decoded to fit inside [box] pixels, keeping its aspect ratio and
/// never upscaling.
///
/// Decoding a 24 MP photo at full size costs roughly 96 MB and a few hundred
/// milliseconds, only to draw it into a screen that has a tenth of the pixels.
ImageProvider albumFittedProvider(File file, Size box) => ResizeImage(
  FileImage(file),
  width: box.width.round(),
  height: box.height.round(),
  policy: ResizeImagePolicy.fit,
);

/// A small copy of a photo, kept on disk so it is made only once.
///
/// The first time a photo is shown, its file is decoded at thumbnail size,
/// compressed to a JPEG (a PNG when it has transparency) and saved. Every
/// later time, in this run or any other, only that ~10 KB file is read, not
/// the multi-megabyte original.
///
/// Saved copies are named after the original's path, size and modification
/// time, so an edited photo gets a fresh thumbnail. The cache is pruned to
/// [albumThumbnailCacheMaxBytes], oldest first, and is safe to delete.
@immutable
class AlbumThumbnailProvider extends ImageProvider<AlbumThumbnailProvider> {
  const AlbumThumbnailProvider(
    this.file, {
    this.width = albumThumbnailWidth,
    this.quality = albumThumbnailQuality,
    this.maxCacheBytes = albumThumbnailCacheMaxBytes,
    this.cacheDirectory,
  });

  final File file;
  final int width;

  /// JPEG quality, 1 to 100, of the stored copy.
  final int quality;

  /// Size the cache is pruned to stay under.
  final int maxCacheBytes;

  /// Where thumbnails are kept. Defaults to a folder under [albumCacheRoot].
  final Directory? cacheDirectory;

  @override
  Future<AlbumThumbnailProvider> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AlbumThumbnailProvider>(this);

  @override
  ImageStreamCompleter loadImage(
    AlbumThumbnailProvider key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: file.path,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Not a file', file.path);
    }
    final directory = cacheDirectory ?? _defaultThumbnailDirectory();
    final key = albumCacheHash(
      '${file.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}'
      '|$width|$quality',
    );
    final stored = File(p.join(directory.path, '$key.thumb'));

    final saved = await _readStored(stored);
    if (saved != null) {
      try {
        return await _decodeBytes(saved, decode);
      } catch (_) {
        // A damaged thumbnail: drop it and make a new one.
        await _deleteQuietly(stored);
      }
    }

    final made = await _thumbnailGate.run(_makeThumbnail);
    unawaited(_store(stored, made, directory, maxCacheBytes));
    return _decodeBytes(made, decode);
  }

  /// Decodes the original at thumbnail size and compresses the result.
  Future<Uint8List> _makeThumbnail() async {
    final source = await ui.ImmutableBuffer.fromUint8List(
      await file.readAsBytes(),
    );
    ui.Image? image;
    try {
      final descriptor = await ui.ImageDescriptor.encoded(source);
      try {
        // Not upscaled: a photo narrower than the thumbnail stays as it is.
        final codec = await descriptor.instantiateCodec(
          targetWidth: descriptor.width > width ? width : null,
        );
        try {
          image = (await codec.getNextFrame()).image;
        } finally {
          codec.dispose();
        }
      } finally {
        descriptor.dispose();
      }
      final data = await image.toByteData(
        format: ui.ImageByteFormat.rawStraightRgba,
      );
      if (data == null) throw StateError('Could not read the decoded pixels');
      final rgba = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      final w = image.width;
      final h = image.height;
      // Compression is the slow part of this step, so it runs off the UI
      // isolate.
      final jpegQuality = quality;
      return await Isolate.run(() => _compress(rgba, w, h, jpegQuality));
    } finally {
      image?.dispose();
      source.dispose();
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumThumbnailProvider &&
      other.file.path == file.path &&
      other.width == width &&
      other.quality == quality &&
      other.cacheDirectory?.path == cacheDirectory?.path;

  @override
  int get hashCode =>
      Object.hash(file.path, width, quality, cacheDirectory?.path);

  @override
  String toString() => 'AlbumThumbnailProvider("${file.path}", width: $width)';
}

Directory _defaultThumbnailDirectory() =>
    Directory(p.join(albumCacheRoot().path, 'thumbs'));

Future<ui.Codec> _decodeBytes(
  Uint8List bytes,
  ImageDecoderCallback decode,
) async {
  final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
  return decode(buffer);
}

/// JPEG for opaque pixels; PNG when any pixel is see-through, since JPEG
/// would turn transparency into black.
Uint8List _compress(Uint8List rgba, int width, int height, int quality) {
  var opaque = true;
  for (var i = 3; i < rgba.length; i += 4) {
    if (rgba[i] != 255) {
      opaque = false;
      break;
    }
  }

  if (!opaque) {
    final image = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
    );
    return img.encodePng(image);
  }

  final rgb = Uint8List(width * height * 3);
  for (var s = 0, d = 0; s < rgba.length; s += 4, d += 3) {
    rgb[d] = rgba[s];
    rgb[d + 1] = rgba[s + 1];
    rgb[d + 2] = rgba[s + 2];
  }
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: rgb.buffer,
    numChannels: 3,
  );
  return img.encodeJpg(image, quality: quality);
}

Future<Uint8List?> _readStored(File file) async {
  try {
    final bytes = await file.readAsBytes();
    return bytes.isEmpty ? null : bytes;
  } catch (_) {
    return null;
  }
}

Future<void> _deleteQuietly(File file) async {
  try {
    await file.delete();
  } catch (_) {}
}

/// Thumbnail folders already pruned in this run: once is enough, since the
/// cache only grows by what one session shows.
final _prunedDirectories = <String>{};

/// Saves [bytes] beside the other thumbnails. Failing to is fine: the photo
/// has already been shown and will just be made again next time.
Future<void> _store(
  File file,
  Uint8List bytes,
  Directory directory,
  int maxBytes,
) async {
  try {
    await directory.create(recursive: true);
    // Written under a temporary name and renamed, so a half-written file is
    // never mistaken for a thumbnail.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsBytes(bytes);
    await temp.rename(file.path);
    if (_prunedDirectories.add(directory.path)) {
      unawaited(pruneAlbumThumbnails(directory, maxBytes: maxBytes));
    }
  } catch (_) {}
}

/// Deletes the oldest thumbnails in [directory] until it holds at most 80% of
/// [maxBytes], leaving room to grow before the next prune. Abandoned
/// temporary files are removed regardless. Runs on its own isolate.
Future<void> pruneAlbumThumbnails(
  Directory directory, {
  int maxBytes = albumThumbnailCacheMaxBytes,
}) async {
  final path = directory.path;
  try {
    await Isolate.run(() => _prune(path, maxBytes));
  } catch (_) {}
}

Future<void> _prune(String path, int maxBytes) async {
  final directory = Directory(path);
  if (!await directory.exists()) return;

  final entries = <(File, int, DateTime)>[];
  var total = 0;
  final now = DateTime.now();
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    final FileStat stat;
    try {
      stat = await entity.stat();
    } catch (_) {
      continue;
    }
    if (entity.path.endsWith('.tmp')) {
      if (now.difference(stat.modified) > const Duration(hours: 1)) {
        await _deleteQuietly(entity);
      }
      continue;
    }
    if (!entity.path.endsWith('.thumb')) continue;
    entries.add((entity, stat.size, stat.modified));
    total += stat.size;
  }
  if (total <= maxBytes) return;

  entries.sort((a, b) => a.$3.compareTo(b.$3));
  final target = maxBytes * 8 ~/ 10;
  for (final (file, size, _) in entries) {
    if (total <= target) break;
    await _deleteQuietly(file);
    total -= size;
  }
}

/// Runs [limit] jobs at a time. Each thumbnail being made holds the whole
/// original in memory, so a screenful of tiles must not all start at once.
class _Gate {
  _Gate(this.limit);

  final int limit;
  var _running = 0;
  final _waiting = <Completer<void>>[];

  Future<T> run<T>(Future<T> Function() job) async {
    if (_running >= limit) {
      final turn = Completer<void>();
      _waiting.add(turn);
      await turn.future;
    } else {
      _running++;
    }
    try {
      return await job();
    } finally {
      if (_waiting.isEmpty) {
        _running--;
      } else {
        // Hand the slot straight to the next in line.
        _waiting.removeAt(0).complete();
      }
    }
  }
}

final _thumbnailGate = _Gate(3);
