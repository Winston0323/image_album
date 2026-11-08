import 'dart:async';
import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'album_cache.dart';
import 'album_library.dart';
import 'album_libraw.dart';
import 'album_raw.dart';

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
ImageProvider albumThumbnailProvider(File file, {AlbumLibrary? library}) =>
    _thumbnailProvider(file, library);

AlbumThumbnailProvider _thumbnailProvider(File file, AlbumLibrary? library) {
  if (library == null) {
    return AlbumThumbnailProvider(file, revision: _thumbnailRevision);
  }
  final cache = library.cache;
  return AlbumThumbnailProvider(
    file,
    width: cache.thumbnailWidth,
    quality: cache.thumbnailQuality,
    maxCacheBytes: cache.thumbnailMaxBytes,
    cacheDirectory: library.thumbnailDirectory,
    revision: _thumbnailRevision,
  );
}

/// Makes sure a stored thumbnail exists for [file], building it on a worker
/// when missing. Safe to call for photos that are not on screen yet.
///
/// [priority] is higher for tiles the user can see (default) than for
/// background prefetch, so scrolling keeps the isolate pool.
Future<void> albumEnsureThumbnail(
  File file, {
  AlbumLibrary? library,
  int priority = 1,
}) async {
  await _thumbnailProvider(file, library)._ensure(priority: priority);
}

/// Builds missing thumbnails for [files] in the background, a few at a time,
/// without starving tiles that are already on screen. Returns how many were
/// newly made (already-cached files are skipped).
Future<int> albumPrefetchThumbnails(
  Iterable<File> files, {
  AlbumLibrary? library,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
  int concurrency = 2,
}) async {
  final seen = <String>{};
  final list = <File>[
    for (final file in files)
      if (seen.add(p.normalize(file.path))) file,
  ];
  final total = list.length;
  if (total == 0) {
    onProgress?.call(0, 0);
    return 0;
  }

  var next = 0;
  var done = 0;
  var made = 0;
  onProgress?.call(0, total);

  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() ?? false) return;
      final i = next++;
      if (i >= list.length) return;
      if (await _thumbnailProvider(list[i], library)._ensure(priority: 0)) {
        made++;
      }
      done++;
      onProgress?.call(done, total);
    }
  }

  final workers = math.max(1, math.min(concurrency, total));
  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  return made;
}

/// Bumped by [albumRegenerateThumbnails], so providers made afterwards are new
/// to Flutter's image cache and read the remade files rather than the
/// pictures decoded before.
int _thumbnailRevision = 0;

/// Empties the thumbnail cache ([library]'s, or the shared one without) and
/// makes the thumbnails of [files] again. Returns how many were made; a file
/// that cannot be shown is skipped.
///
/// For when stored thumbnails are wrong, such as ones made before a decoding
/// fix. Pass photos currently on screen first so they remake before the rest;
/// [ImageAlbumState.regenerateCache] does that.
///
/// [onProgress] gets the count done and the total. Updates are coalesced so a
/// busy album does not flood the UI. [cancelled] is checked between files;
/// thumbnails not made yet are then made when next shown.
Future<int> albumRegenerateThumbnails(
  Iterable<File> files, {
  AlbumLibrary? library,
  void Function(int done, int total)? onProgress,
  bool Function()? cancelled,
}) async {
  // One entry per path, order kept: callers put visible photos first.
  final seen = <String>{};
  final list = <File>[
    for (final file in files)
      if (seen.add(p.normalize(file.path))) file,
  ];
  _thumbnailRevision++;

  final directory = library?.thumbnailDirectory ?? _defaultThumbnailDirectory();
  await _wipeThumbnails(directory);
  try {
    await directory.create(recursive: true);
  } catch (_) {}
  // Fresh cache: skip the first-write prune that would scan an empty folder.
  _prunedDirectories.add(directory.path);

  final total = list.length;
  var next = 0;
  var done = 0;
  var made = 0;
  var lastReported = -1;
  var revealed = false;
  final reportEvery = total <= 40 ? 1 : (total / 40).ceil().clamp(2, 25);
  void report({bool force = false}) {
    if (!force && done != total && done - lastReported < reportEvery) return;
    lastReported = done;
    onProgress?.call(done, total);
  }

  report(force: true);

  // One feeder per pool worker: the pool itself is the multithread limit.
  final workers = _ThumbnailPool.instance.workerCount;
  Future<void> worker() async {
    while (true) {
      if (cancelled?.call() ?? false) return;
      final i = next++;
      if (i >= list.length) return;
      if (await _thumbnailProvider(list[i], library)._remake()) made++;
      done++;
      report();
      // Once a screenful is remade, drop live tiles so the grid can show them
      // while the rest of the album continues in the background.
      if (!revealed && done >= math.min(48, total)) {
        revealed = true;
        _evictThumbnailImages();
      }
    }
  }

  await Future.wait([for (var i = 0; i < workers; i++) worker()]);
  report(force: true);
  _evictThumbnailImages();
  return made;
}

Future<void> _wipeThumbnails(Directory directory) async {
  // Delete files in parallel: a recursive folder delete fails on Windows when
  // any thumbnail is still open by a live tile.
  try {
    if (!await directory.exists()) return;
    final pending = <Future<void>>[];
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) pending.add(_deleteQuietly(entity));
      if (pending.length >= 32) {
        await Future.wait(pending);
        pending.clear();
      }
    }
    if (pending.isNotEmpty) await Future.wait(pending);
  } catch (_) {}
}

void _evictThumbnailImages() {
  try {
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
  } catch (_) {}
}

/// [file] decoded to fit inside [box] pixels, keeping its aspect ratio and
/// never upscaling.
///
/// Decoding a 24 MP photo at full size costs roughly 96 MB and a few hundred
/// milliseconds, only to draw it into a screen that has a tenth of the pixels.
/// Prefer [albumFullProvider] in the preview once the photo is on screen.
ImageProvider albumFittedProvider(File file, Size box) => ResizeImage(
  albumNeedsConversion(file.path)
      ? AlbumConvertedImage(
          file,
          maxSide: (box.width > box.height ? box.width : box.height).ceil(),
        )
      : FileImage(file),
  width: box.width.round(),
  height: box.height.round(),
  policy: ResizeImagePolicy.fit,
);

/// [file] at its native pixel size.
///
/// A JPEG or PNG is the file itself. On Windows a raw is developed with
/// LibRaw (the sensor image, not the embedded preview). The Windows codec is
/// the fallback when LibRaw cannot read the file.
ImageProvider albumFullProvider(File file) {
  if (!albumNeedsConversion(file.path)) return FileImage(file);
  if (Platform.isWindows) return AlbumLibRawImage(file);
  final sibling = albumSiblingJpeg(file);
  if (sibling != null) return FileImage(sibling);
  return AlbumConvertedImage(file);
}

/// A Windows raw decode is the whole sensor image, so neighbors are not
/// decoded ahead of time.
bool albumFullDecodeIsHeavy(File file) =>
    Platform.isWindows && albumNeedsConversion(file.path);

/// Opens the system file manager with [file] selected / highlighted.
///
/// On Windows this asks the shell to open the parent folder and select the
/// file. `explorer.exe /select` is not used: Dart's command-line quoting
/// makes Explorer ignore the path and open Documents instead.
/// On macOS this is Finder's `open -R`. Linux asks the file manager via
/// D-Bus when available, otherwise opens the parent folder.
Future<void> albumRevealInFileManager(File file) async {
  final absolute = file.absolute;
  if (!await absolute.exists()) {
    throw FileSystemException('File not found', absolute.path);
  }
  if (Platform.isWindows) {
    _revealInWindowsExplorer(absolute);
    return;
  }
  if (Platform.isMacOS) {
    await Process.start('open', [
      '-R',
      absolute.path,
    ], mode: ProcessStartMode.detached);
    return;
  }
  if (Platform.isLinux) {
    final uri = absolute.uri.toString();
    try {
      final result = await Process.run('dbus-send', [
        '--session',
        '--print-reply',
        '--dest=org.freedesktop.FileManager1',
        '--type=method_call',
        '/org/freedesktop/FileManager1',
        'org.freedesktop.FileManager1.ShowItems',
        'array:string:$uri',
        'string:',
      ]);
      if (result.exitCode == 0) return;
    } on Object {
      // Fall through to opening the folder.
    }
    await Process.start('xdg-open', [
      p.dirname(absolute.path),
    ], mode: ProcessStartMode.detached);
    return;
  }
  throw UnsupportedError(
    'Showing a file in the file manager is not supported on this platform',
  );
}

/// Opens Explorer with [file] selected, via `SHOpenFolderAndSelectItems`.
void _revealInWindowsExplorer(File file) {
  final path = p.windows.normalize(file.path);
  final hr = _WindowsExplorer.selectFile(path);
  if (hr < 0) {
    throw FileSystemException(
      'Explorer could not select this file '
      '(0x${hr.toUnsigned(32).toRadixString(16)})',
      path,
    );
  }
}

/// Windows shell calls used to highlight one file. Loaded only when a reveal
/// runs, so other platforms never open these libraries.
class _WindowsExplorer {
  static final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');
  static final DynamicLibrary _shell32 = DynamicLibrary.open('shell32.dll');
  static final DynamicLibrary _ole32 = DynamicLibrary.open('ole32.dll');

  static final Pointer<Void> _heap = _kernel32
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      )();

  static final Pointer<Void> Function(Pointer<Void>, int, int) _heapAlloc =
      _kernel32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');

  static final int Function(Pointer<Void>, int, Pointer<Void>) _heapFree =
      _kernel32.lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');

  static final int Function(Pointer<Void>, int) _coInitializeEx = _ole32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int)
      >('CoInitializeEx');

  static final void Function() _coUninitialize = _ole32
      .lookupFunction<Void Function(), void Function()>('CoUninitialize');

  static final Pointer<Void> Function(Pointer<Uint16>) _ilCreateFromPath =
      _shell32.lookupFunction<
        Pointer<Void> Function(Pointer<Uint16>),
        Pointer<Void> Function(Pointer<Uint16>)
      >('ILCreateFromPathW');

  static final void Function(Pointer<Void>) _ilFree = _shell32
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('ILFree');

  static final int Function(Pointer<Void>, int, Pointer<Void>, int)
  _selectItems = _shell32
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SHOpenFolderAndSelectItems');

  static const int _heapZeroMemory = 0x8;
  static const int _coinitApartmentThreaded = 0x2;

  /// COM is already initialized on this thread with a different model.
  static const int _rpcEChangedMode = 0x80010106;

  /// Selects [path] in its parent folder. Returns an HRESULT.
  static int selectFile(String path) {
    final init = _coInitializeEx(nullptr, _coinitApartmentThreaded);
    final uninit = init != _rpcEChangedMode && init >= 0;
    final wide = _utf16(path);
    try {
      final pidl = _ilCreateFromPath(wide);
      if (pidl == nullptr) {
        throw FileSystemException('Explorer could not open this file', path);
      }
      try {
        // A file PIDL opens the parent folder and highlights that file.
        return _selectItems(pidl, 0, nullptr, 0);
      } finally {
        _ilFree(pidl);
      }
    } finally {
      _heapFree(_heap, 0, wide.cast());
      if (uninit) _coUninitialize();
    }
  }

  static Pointer<Uint16> _utf16(String value) {
    final units = value.codeUnits;
    final data = _heapAlloc(
      _heap,
      _heapZeroMemory,
      (units.length + 1) * 2,
    ).cast<Uint16>();
    if (data == nullptr) {
      throw StateError('Could not allocate the file path');
    }
    final view = data.asTypedList(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      view[i] = units[i];
    }
    return data;
  }
}

/// A TIFF or camera raw, turned into something Flutter can draw: the camera's
/// own JPEG preview for a raw, the decoded picture for a TIFF. See
/// [albumDecodableBytes]. Wrap it in a [ResizeImage] to decode it smaller.
///
/// [maxSide] caps the longer side of a decoded TIFF, so a huge scan is not
/// brought back at full size to be drawn in a window.
@immutable
class AlbumConvertedImage extends ImageProvider<AlbumConvertedImage> {
  const AlbumConvertedImage(
    this.file, {
    this.maxSide,
    this.embeddedOnly = false,
  });

  final File file;
  final int? maxSide;

  /// Use only the JPEG the file names, without scanning the rest of a raw
  /// for a larger one. The preview shows this immediately while LibRaw develops
  /// the sensor image.
  final bool embeddedOnly;

  @override
  Future<AlbumConvertedImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture<AlbumConvertedImage>(this);

  @override
  ImageStreamCompleter loadImage(
    AlbumConvertedImage key,
    ImageDecoderCallback decode,
  ) {
    return MultiFrameImageStreamCompleter(
      codec: _load(decode),
      scale: 1.0,
      debugLabel: file.path,
    );
  }

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    final path = file.path;
    final side = maxSide;
    final embeddedOnly = this.embeddedOnly;
    final bytes = await _conversionGate.run(
      () => Isolate.run(() async {
        if (embeddedOnly) {
          // The JPEG the raw names, which is what a Sony viewer opens first.
          final thumb = albumLibRawThumbBytes(path);
          if (thumb != null) return albumApplyRawOrientation(thumb, path);
          return albumQuickPreviewBytes(path);
        }
        return albumDecodableBytes(path, maxSide: side);
      }),
    );
    if (bytes == null) {
      throw FileSystemException('Nothing to show in this file', path);
    }
    return _decodeBytes(bytes, decode);
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumConvertedImage &&
      other.file.path == file.path &&
      other.maxSide == maxSide &&
      other.embeddedOnly == embeddedOnly;

  @override
  int get hashCode => Object.hash(file.path, maxSide, embeddedOnly);

  @override
  String toString() =>
      'AlbumConvertedImage("${file.path}", maxSide: $maxSide, embeddedOnly: $embeddedOnly)';
}

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
    this.revision = 0,
  });

  final File file;
  final int width;

  /// JPEG quality, 1 to 100, of the stored copy.
  final int quality;

  /// Size the cache is pruned to stay under.
  final int maxCacheBytes;

  /// Where thumbnails are kept. Defaults to a folder under [albumCacheRoot].
  final Directory? cacheDirectory;

  /// Tells a provider made after [albumRegenerateThumbnails] from one made
  /// before, so the image cache does not hand back the old picture.
  final int revision;

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
    final stored = await _storedFile();
    final saved = await _readStored(stored);
    if (saved != null) {
      try {
        return await _decodeBytes(saved, decode);
      } catch (_) {
        // A damaged thumbnail: drop it and make a new one.
        await _deleteQuietly(stored);
      }
    }
    return _decodeBytes(await _makeOnce(stored), decode);
  }

  /// Where this photo's thumbnail is kept. Throws when the photo is gone.
  Future<File> _storedFile() async {
    final stat = await file.stat();
    if (stat.type != FileSystemEntityType.file) {
      throw FileSystemException('Not a file', file.path);
    }
    final key = albumCacheHash(
      '${file.path}|${stat.size}|${stat.modified.microsecondsSinceEpoch}'
      '|$width|$quality',
    );
    return File(p.join(_directory.path, '$key.thumb'));
  }

  Directory get _directory => cacheDirectory ?? _defaultThumbnailDirectory();

  /// Makes and saves the thumbnail at [stored], sharing the work with anyone
  /// already making it: a tile and background prefetch often ask for the same
  /// one at once.
  Future<Uint8List> _makeOnce(File stored, {int priority = 1}) =>
      _making.putIfAbsent(stored.path, () async {
        try {
          final made = await _ThumbnailPool.instance.run(
            file.path,
            width,
            quality,
            priority: priority,
          );
          await _store(stored, made, _directory, maxCacheBytes);
          return made;
        } finally {
          _making.remove(stored.path);
        }
      });

  /// Ensures a stored thumbnail exists. True when one was newly made, false
  /// when a good one was already on disk (or the photo cannot be shown).
  Future<bool> _ensure({int priority = 1}) async {
    try {
      final stored = await _storedFile();
      final saved = await _readStored(stored);
      if (saved != null) return false;
      await _makeOnce(stored, priority: priority);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Makes the thumbnail again in place of any stored one. False when the
  /// photo cannot be shown. Goes through the same isolate pool as a first
  /// load so regenerate and scrolling share workers.
  Future<bool> _remake() async {
    try {
      final stored = await _storedFile();
      final made = await _ThumbnailPool.instance.run(
        file.path,
        width,
        quality,
        priority: 1,
      );
      await _store(stored, made, _directory, maxCacheBytes);
      return true;
    } catch (_) {
      return false;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumThumbnailProvider &&
      other.file.path == file.path &&
      other.width == width &&
      other.quality == quality &&
      other.cacheDirectory?.path == cacheDirectory?.path &&
      other.revision == revision;

  @override
  int get hashCode =>
      Object.hash(file.path, width, quality, cacheDirectory?.path, revision);

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

/// Reads [path] and builds thumbnail bytes. Runs inside a pool worker so the
/// UI isolate only waits for the result.
Future<Uint8List> _buildThumbnailBytes(
  String path,
  int width,
  int quality,
) async {
  return _resizeEncode(await _readThumbnailSource(path, width), width, quality);
}

/// The original's bytes, or for a TIFF or camera raw the bytes of something
/// that can be drawn in its place — same choices the grid used to make on the
/// UI isolate, now free to run in parallel on workers.
Future<Uint8List> _readThumbnailSource(String path, int width) async {
  final file = File(path);
  final extension = p.extension(path).toLowerCase();
  // A camera JPEG is many megabytes; the EXIF thumbnail is enough for a tile.
  if (extension == '.jpg' || extension == '.jpeg') {
    final thumb = await albumJpegEmbeddedThumbnail(file);
    if (thumb != null) return thumb;
  }
  // A raw's own preview sits at a known offset.
  if (albumNeedsConversion(path)) {
    final preview = await albumEmbeddedPreview(file);
    if (preview != null) return preview;
  }
  if (!albumNeedsConversion(path)) return file.readAsBytes();
  // A decoded TIFF is brought back no bigger than twice the thumbnail.
  final bytes = await albumDecodableBytes(path, maxSide: width * 2);
  if (bytes == null) {
    throw FileSystemException('Nothing to show in this file', path);
  }
  return bytes;
}

/// [source] decoded, shrunk to [targetWidth] when wider, then compressed.
Uint8List _resizeEncode(Uint8List source, int targetWidth, int quality) {
  // JPEG first: raw/camera previews and most photos are JPEG, and decodeJpg
  // is much cheaper than the generic decoder. Non-JPEG bytes must not go
  // through decodeJpg — it throws instead of returning null.
  img.Image? decoded;
  if (source.length >= 2 && source[0] == 0xFF && source[1] == 0xD8) {
    decoded = img.decodeJpg(source);
  }
  decoded ??= img.decodeImage(source);
  if (decoded == null) {
    throw const FormatException('Could not decode the photo');
  }
  final image = decoded.width > targetWidth
      ? img.copyResize(
          decoded,
          width: targetWidth,
          interpolation: img.Interpolation.linear,
        )
      : decoded;
  if (image.hasAlpha) return img.encodePng(image);
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

/// Thumbnails being made, by the path they will be stored at.
final _making = <String, Future<Uint8List>>{};

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

/// Long-lived isolates that build thumbnails. Spawning per file was paying
/// isolate startup on every tile; a small pool keeps several cores busy while
/// the UI isolate only schedules work and draws.
class _ThumbnailPool {
  _ThumbnailPool._(this.workerCount);

  static _ThumbnailPool? _instance;

  static _ThumbnailPool get instance =>
      _instance ??= _ThumbnailPool._(_defaultWorkerCount());

  static int _defaultWorkerCount() =>
      math.min(math.max(Platform.numberOfProcessors - 1, 2), 8);

  final int workerCount;

  final _idle = <SendPort>[];
  final _waiting = <_ThumbnailRequest>[];
  var _spawned = 0;
  var _spawning = 0;

  Future<Uint8List> run(
    String path,
    int width,
    int quality, {
    int priority = 0,
  }) {
    final request = _ThumbnailRequest(path, width, quality, priority);
    // Higher priority first so on-screen tiles jump ahead of prefetch.
    final at = _waiting.indexWhere((job) => job.priority < priority);
    if (at < 0) {
      _waiting.add(request);
    } else {
      _waiting.insert(at, request);
    }
    _pump();
    return request.done.future;
  }

  void _pump() {
    while (_waiting.isNotEmpty && _idle.isNotEmpty) {
      _send(_idle.removeLast(), _waiting.removeAt(0));
    }
    while (_waiting.isNotEmpty &&
        _spawned + _spawning < workerCount &&
        _idle.isEmpty) {
      _spawning++;
      unawaited(_spawn());
    }
  }

  Future<void> _spawn() async {
    try {
      final ready = ReceivePort();
      await Isolate.spawn(_thumbnailWorkerMain, ready.sendPort);
      final worker = await ready.first as SendPort;
      ready.close();
      _spawned++;
      _idle.add(worker);
    } catch (_) {
      // A failed spawn leaves capacity; queued jobs stay until another works.
    } finally {
      _spawning--;
      _pump();
    }
  }

  void _send(SendPort worker, _ThumbnailRequest request) {
    final reply = ReceivePort();
    worker.send(<Object?>[
      request.path,
      request.width,
      request.quality,
      reply.sendPort,
    ]);
    reply.first.then(
      (message) {
        reply.close();
        if (message is Uint8List) {
          request.done.complete(message);
        } else if (message is List && message.isNotEmpty) {
          request.done.completeError(StateError('${message.first}'));
        } else {
          request.done.completeError(
            StateError('Thumbnail worker returned nothing'),
          );
        }
        _idle.add(worker);
        _pump();
      },
      onError: (Object error, StackTrace stack) {
        reply.close();
        if (!request.done.isCompleted) {
          request.done.completeError(error, stack);
        }
        _idle.add(worker);
        _pump();
      },
    );
  }
}

class _ThumbnailRequest {
  _ThumbnailRequest(this.path, this.width, this.quality, this.priority);

  final String path;
  final int width;
  final int quality;
  final int priority;
  final done = Completer<Uint8List>();
}

/// Entry point for each pool isolate: waits for jobs and replies with bytes.
void _thumbnailWorkerMain(SendPort ready) {
  final inbox = ReceivePort();
  ready.send(inbox.sendPort);
  inbox.listen((message) async {
    if (message is! List || message.length < 4) return;
    final path = message[0] as String;
    final width = message[1] as int;
    final quality = message[2] as int;
    final reply = message[3] as SendPort;
    try {
      reply.send(await _buildThumbnailBytes(path, width, quality));
    } catch (error) {
      reply.send(<Object>[error.toString()]);
    }
  });
}

/// Conversions of TIFFs and raws for the preview. Each holds a whole decoded
/// photo, so only a couple run at once.
final _conversionGate = _Gate(2);

/// Runs [limit] jobs at a time.
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
        _waiting.removeAt(0).complete();
      }
    }
  }
}
