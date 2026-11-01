import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;

import 'album_cache.dart';
import 'album_catalog.dart';
import 'album_raw.dart';

/// Extensions [loadAlbumPhotos] treats as images. Compared case-insensitively,
/// so `DSC0001.JPG` and `photo.png` both qualify.
const Set<String> albumImageExtensions = {
  '.jpg',
  '.jpeg',
  '.png',
  '.gif',
  '.webp',
  '.bmp',
  '.heic',
  '.heif',
  // Not drawn by Flutter itself: the album shows a TIFF as decoded, and the
  // camera's own preview for a raw. See album_raw.dart.
  '.tif',
  '.tiff',
  '.fff',
  '.arw',
};

/// One image file found under an album directory.
class AlbumPhoto {
  const AlbumPhoto({required this.file, required this.takenAt});

  final File file;

  /// When the shot was taken. The scan uses the capture time stored in the
  /// file when it has one, and the file's modification time otherwise.
  final DateTime takenAt;

  String get id => file.path;

  String get fileName => p.basename(file.path);

  /// What kind of file this is. See [albumFileType].
  String get fileType => albumFileType(file.path);
}

/// The kind of image [path] is, as a short upper-case label such as `JPG`,
/// `PNG` or `HEIC`. Variant spellings share a label (`.jpeg` is `JPG`, `.heif`
/// is `HEIC`), so a filter on one catches them all.
String albumFileType(String path) {
  final extension = p.extension(path).toLowerCase();
  return switch (extension) {
    '.jpg' || '.jpeg' => 'JPG',
    '.heic' || '.heif' => 'HEIC',
    '.tif' || '.tiff' => 'TIFF',
    '' => '',
    _ => extension.substring(1).toUpperCase(),
  };
}

/// One day's worth of photos, newest day first when produced by [groupAlbumByDay].
class AlbumDaySection {
  const AlbumDaySection({required this.day, required this.photos});

  /// Local midnight of the day these [photos] belong to.
  final DateTime day;
  final List<AlbumPhoto> photos;
}

/// Groups [photos] by the calendar day of [AlbumPhoto.takenAt], newest day
/// first and newest shot first within each day.
///
/// Input that is already newest first, which is what [loadAlbumPhotos]
/// produces, is grouped in a single pass without sorting.
List<AlbumDaySection> groupAlbumByDay(List<AlbumPhoto> photos) {
  final byDay = <DateTime, List<AlbumPhoto>>{};
  for (final photo in photos) {
    final at = photo.takenAt;
    final day = DateTime(at.year, at.month, at.day);
    byDay.putIfAbsent(day, () => []).add(photo);
  }

  final days = byDay.keys.toList()..sort((a, b) => b.compareTo(a));
  return [
    for (final day in days)
      AlbumDaySection(day: day, photos: _sortedNewestFirst(byDay[day]!)),
  ];
}

List<AlbumPhoto> _sortedNewestFirst(List<AlbumPhoto> photos) {
  for (var i = 1; i < photos.length; i++) {
    if (_newestFirst(photos[i - 1], photos[i]) > 0) {
      return photos..sort(_newestFirst);
    }
  }
  return photos;
}

/// Image files in [path], newest shot first.
///
/// A missing directory is an empty album. Subfolders are skipped unless
/// [recursive] is true. Links are not followed. Anything whose extension is
/// not in [albumImageExtensions] is skipped, so a leftover partial download
/// never shows up as a tile.
///
/// The shot date is the capture time stored in the image, when it has one.
/// A copied file's modification time is often the moment it was copied, which
/// would bunch every nested photo onto that day, so that time is only the
/// fallback.
///
/// [onProgress] is called with the photos found so far, newest first, as
/// batches of files are dated. The album uses that to put tiles on screen
/// before the rest of the folder has been read. Each list it receives is a
/// snapshot that is never modified afterwards.
///
/// Listing and date reading run on a background isolate, so the UI isolate
/// only applies the batches. Several files are read at once, and only the
/// first [_headBytes] of a JPEG are read to find its capture time. [token]
/// cancels that work when the folder changes.
///
/// Dates are remembered in [cacheDirectory] (default: a folder in the system
/// temp directory), keyed by each file's size and modification time, so
/// opening the same folder again does not re-read the image files.
///
/// With [useCatalog] the same index is also kept in a hidden catalog file,
/// [albumCatalogName], inside [path]. It travels with the folder, so a folder
/// that was indexed once is quick to open even from a new install or another
/// machine, and it covers the whole tree whichever way the folder was scanned.
/// When the folder cannot be written to, the album carries on without it.
///
/// A scan normally checks every file's size and modification time against the
/// catalog, which costs a stat per file. Give [trustCatalog] a duration and a
/// catalog that was verified more recently than that is believed instead:
/// files it lists are not checked again, and only files that were added or
/// removed show up. A photo edited in place, under the same name, is picked up
/// once the catalog is older than [trustCatalog] or when it is not given.
Future<List<AlbumPhoto>> loadAlbumPhotos(
  String path, {
  bool recursive = false,
  void Function(List<AlbumPhoto> photos)? onProgress,
  AlbumLoadToken? token,
  Directory? cacheDirectory,
  bool useCatalog = true,
  Duration? trustCatalog,
}) async {
  final cachePath = (cacheDirectory ?? albumCacheRoot()).path;
  final port = ReceivePort();
  final isolate = await Isolate.spawn(_scanAlbum, (
    path,
    recursive,
    cachePath,
    useCatalog,
    trustCatalog?.inMicroseconds ?? 0,
    port.sendPort,
  ), debugName: 'image_album_scan');
  token?._attach(isolate);
  isolate.addOnExitListener(port.sendPort, response: const ['exit']);

  // Kept sorted. Every batch is merged in, which is linear in the list size,
  // rather than re-sorting the whole list each time.
  var photos = <AlbumPhoto>[];
  Object? failure;
  try {
    await for (final message in port) {
      if (message is! List || message.isEmpty) continue;
      final kind = message.first;
      if (kind == 'batch') {
        final incoming = <AlbumPhoto>[
          for (var i = 1; i + 1 < message.length; i += 2)
            AlbumPhoto(
              file: File(message[i] as String),
              takenAt: DateTime.fromMicrosecondsSinceEpoch(
                message[i + 1] as int,
              ),
            ),
        ]..sort(_newestFirst);
        photos = _merge(photos, incoming);
        onProgress?.call(photos);
        continue;
      }
      if (kind == 'error') {
        failure = message.length > 1 ? message[1] : 'Could not read the album';
      }
      break;
    }
  } finally {
    port.close();
  }
  if (failure != null) throw Exception(failure);
  return photos;
}

/// One list, newest first, from several that are each newest first.
///
/// A photo that is in more than one list, because one source folder sits inside
/// another, appears once. A single non-empty list is returned as it is.
List<AlbumPhoto> mergeAlbumPhotos(Iterable<List<AlbumPhoto>> lists) {
  final filled = [
    for (final list in lists)
      if (list.isNotEmpty) list,
  ];
  if (filled.isEmpty) return const [];
  if (filled.length == 1) return filled.first;
  var merged = filled.first;
  for (final next in filled.skip(1)) {
    merged = _merge(merged, next);
  }
  final seen = <String>{};
  return [
    for (final photo in merged)
      if (seen.add(photo.id)) photo,
  ];
}

/// The photos [loadAlbumPhotos] found in [path] last time, newest first, read
/// from the saved index in [cacheDirectory] without touching the photo files.
///
/// It is for putting tiles on screen at once while [loadAlbumPhotos] checks
/// the folder again. It can be out of date: files may have been added, moved
/// or deleted since. Empty when the folder has no index yet. Reading runs on a
/// background isolate.
///
/// The folder's own catalog is read first, when [useCatalog] is set and it
/// covers what is asked for: a recursive read needs a catalog made by a
/// recursive scan. Otherwise the index in [cacheDirectory] is used.
Future<List<AlbumPhoto>> readAlbumIndex(
  String path, {
  bool recursive = false,
  Directory? cacheDirectory,
  bool useCatalog = true,
}) async {
  if (useCatalog) {
    final rows = await Isolate.run(() => _readCatalogRows(path, recursive));
    if (rows != null) {
      return [
        for (var i = 0; i + 1 < rows.length; i += 2)
          AlbumPhoto(
            file: File(rows[i] as String),
            takenAt: DateTime.fromMicrosecondsSinceEpoch(rows[i + 1] as int),
          ),
      ];
    }
  }
  final file = File(
    p.join(
      (cacheDirectory ?? albumCacheRoot()).path,
      albumIndexName(path, recursive),
    ),
  );
  if (!await file.exists()) return const [];
  final filePath = file.path;
  final rows = await Isolate.run(() => _readIndexRows(filePath));
  return [
    for (var i = 0; i + 1 < rows.length; i += 2)
      AlbumPhoto(
        file: File(rows[i] as String),
        takenAt: DateTime.fromMicrosecondsSinceEpoch(rows[i + 1] as int),
      ),
  ];
}

/// The index as `[path, microseconds, ...]`, newest first. Plain values, since
/// that is what can cross from the isolate.
Future<List<Object>> _readIndexRows(String path) async {
  final entries = (await _readDateCache(File(path))).entries.toList()
    ..sort((a, b) {
      final byDate = b.value.takenAt.compareTo(a.value.takenAt);
      return byDate != 0 ? byDate : a.key.compareTo(b.key);
    });
  return [
    for (final entry in entries) ...[entry.key, entry.value.takenAt],
  ];
}

/// What the catalog in [path] lists for a scan of [recursive] kind, as
/// `[path, microseconds, ...]` newest first, or null when it has nothing
/// usable to say: no catalog, or a shallow one when the whole tree is wanted.
Future<List<Object>?> _readCatalogRows(String path, bool recursive) async {
  final catalog = await readAlbumCatalog(path);
  if (catalog == null || (recursive && !catalog.deep)) return null;
  final rows =
      [
        for (final entry in catalog.inScope(recursive))
          (albumCatalogPath(path, entry.key), entry.value.takenAt),
      ]..sort((a, b) {
        final byDate = b.$2.compareTo(a.$2);
        return byDate != 0 ? byDate : a.$1.compareTo(b.$1);
      });
  return [
    for (final row in rows) ...[row.$1, row.$2],
  ];
}

/// Merges two lists that are each newest first into a new one.
List<AlbumPhoto> _merge(List<AlbumPhoto> a, List<AlbumPhoto> b) {
  if (a.isEmpty) return b;
  if (b.isEmpty) return a;
  final out = <AlbumPhoto>[];
  var i = 0;
  var j = 0;
  while (i < a.length && j < b.length) {
    out.add(_newestFirst(a[i], b[j]) <= 0 ? a[i++] : b[j++]);
  }
  while (i < a.length) {
    out.add(a[i++]);
  }
  while (j < b.length) {
    out.add(b[j++]);
  }
  return out;
}

/// Cancels the background scan started by [loadAlbumPhotos].
class AlbumLoadToken {
  Isolate? _isolate;
  var _cancelled = false;

  void cancel() {
    _cancelled = true;
    final isolate = _isolate;
    if (isolate == null) return;
    try {
      isolate.kill(priority: Isolate.immediate);
    } catch (_) {
      // The scan already finished.
    }
  }

  void _attach(Isolate isolate) {
    _isolate = isolate;
    if (_cancelled) cancel();
  }
}

/// How many files are dated at the same time on the scan isolate.
const int _scanConcurrency = 8;

/// A batch goes to the UI isolate once this many photos are ready...
const int _flushCount = 512;

/// ...or once this long has passed since the previous one, so the first tiles
/// appear quickly and later ones keep trickling in.
const int _flushMillis = 80;

/// EXIF sits at the start of a JPEG (a single APP1 segment, at most 64 KB), so
/// this much is enough to read the capture time with one read call.
const int _headBytes = 128 * 1024;

/// Entry point for the scan isolate. Messages are lists:
/// `['batch', path, microseconds, ...]`, `['done']`, `['error', message]`,
/// or `['exit']` when the isolate is killed.
Future<void> _scanAlbum(
  (String, bool, String, bool, int, SendPort) message,
) async {
  final (path, recursive, cachePath, useCatalog, trustMicros, send) = message;
  try {
    final dir = Directory(path);
    if (!await dir.exists()) {
      send.send(const ['done']);
      return;
    }

    final cacheFile = File(p.join(cachePath, albumIndexName(path, recursive)));
    final catalog = useCatalog ? await readAlbumCatalog(path) : null;

    // What is already known about the files, by absolute path. The folder's
    // own catalog comes first; the album file's index is the fallback.
    final Map<String, _DateEntry> known;
    // How many of those entries a scan of this kind is expected to meet again.
    final int expected;
    if (catalog != null) {
      known = {
        for (final entry in catalog.entries.entries)
          albumCatalogPath(path, entry.key): entry.value,
      };
      expected = catalog.inScope(recursive).length;
    } else {
      known = await _readDateCache(cacheFile);
      expected = known.length;
    }

    // A recent enough catalog is believed: its files are not stat'ed again.
    final now = DateTime.now().microsecondsSinceEpoch;
    final trusted =
        catalog != null &&
        trustMicros > 0 &&
        now >= catalog.verifiedAt &&
        now - catalog.verifiedAt < trustMicros;

    final seen = <String, _DateEntry>{};
    var misses = 0;
    var hits = 0;

    final clock = Stopwatch()..start();
    var lastFlush = 0;
    final ready = <Object?>['batch'];

    void flush() {
      if (ready.length == 1) return;
      send.send(List<Object?>.of(ready));
      ready
        ..clear()
        ..add('batch');
      lastFlush = clock.elapsedMilliseconds;
    }

    Future<void> process(File file) async {
      try {
        final cached = known[file.path];
        if (cached != null) hits++;

        if (trusted && cached != null) {
          // Listed, so it was here when the catalog was last verified.
          seen[file.path] = cached;
          ready
            ..add(file.path)
            ..add(cached.takenAt);
        } else {
          final stat = await file.stat();
          if (stat.type != FileSystemEntityType.file) {
            if (cached != null) hits--;
            return;
          }
          final modified = stat.modified.microsecondsSinceEpoch;

          int takenAt;
          if (cached != null &&
              cached.size == stat.size &&
              cached.modified == modified) {
            takenAt = cached.takenAt;
          } else {
            misses++;
            final date = await _captureDate(file, stat.size) ?? stat.modified;
            takenAt = date.microsecondsSinceEpoch;
          }

          seen[file.path] = _DateEntry(stat.size, modified, takenAt);
          ready
            ..add(file.path)
            ..add(takenAt);
        }
        if (ready.length ~/ 2 >= _flushCount ||
            clock.elapsedMilliseconds - lastFlush >= _flushMillis) {
          flush();
        }
      } catch (_) {
        // Unreadable or vanished mid-scan: leave it out.
      }
    }

    final active = <Future<void>>{};
    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (!albumImageExtensions.contains(extension)) continue;

      late final Future<void> task;
      task = process(entity).whenComplete(() => active.remove(task));
      active.add(task);
      if (active.length >= _scanConcurrency) await Future.any(active);
    }
    await Future.wait(active.toList());
    flush();

    // Something changed when a file is new or was read again, or when one the
    // index listed is gone.
    final changed = misses > 0 || hits != expected;
    if (changed || !await cacheFile.exists()) {
      await _writeDateCache(cacheFile, seen);
    }
    if (useCatalog &&
        (catalog == null || changed || (trustMicros > 0 && !trusted))) {
      final entries = <String, AlbumCatalogEntry>{};
      // A scan of the folder alone has not seen what is below it. Keep what
      // an earlier, deeper scan found there.
      if (!recursive && catalog != null) {
        for (final entry in catalog.entries.entries) {
          if (entry.key.contains('/')) entries[entry.key] = entry.value;
        }
      }
      seen.forEach((file, entry) {
        entries[albumCatalogKey(path, file)] = entry;
      });
      await writeAlbumCatalog(
        path,
        AlbumCatalog(
          // Trusting the catalog verified nothing, so its age stands.
          verifiedAt: trusted ? catalog.verifiedAt : now,
          deep: recursive || (catalog?.deep ?? false),
          entries: entries,
        ),
      );
    }
    send.send(const ['done']);
  } catch (error) {
    send.send(['error', '$error']);
  }
}

int _newestFirst(AlbumPhoto a, AlbumPhoto b) {
  final byDate = b.takenAt.compareTo(a.takenAt);
  if (byDate != 0) return byDate;
  return a.file.path.compareTo(b.file.path);
}

/// Capture time written in the image, or null when the file has none.
Future<DateTime?> _captureDate(File file, int size) async {
  final extension = p.extension(file.path).toLowerCase();
  // Neither format carries EXIF.
  if (extension == '.gif' || extension == '.bmp') return null;

  // TIFF and the raws built on it can be huge, and the whole-file reader
  // below would load every one of them to find a line of text.
  if (albumNeedsConversion(file.path)) return albumTiffCaptureDate(file);

  if (extension == '.jpg' || extension == '.jpeg') {
    try {
      final raf = await file.open();
      final List<int> head;
      try {
        head = await raf.read(_headBytes);
      } finally {
        await raf.close();
      }
      final date = _dateFromTags(await readExifFromBytes(head, details: false));
      // Nothing in the head of a small file means nothing in the file.
      if (date != null || size <= head.length) return date;
    } catch (_) {
      // Fall through to the full reader below.
    }
  }

  // Other formats keep their EXIF at positions only a seeking reader can
  // reach, and a JPEG with no date in its head gets a second look here.
  try {
    return _dateFromTags(await readExifFromFile(file, details: false));
  } catch (_) {
    return null;
  }
}

DateTime? _dateFromTags(Map<String, IfdTag> tags) =>
    _exifDate(tags['EXIF DateTimeOriginal']) ??
    _exifDate(tags['EXIF DateTimeDigitized']) ??
    _exifDate(tags['Image DateTime']);

DateTime? _exifDate(IfdTag? tag) {
  final raw = tag?.printable.trim();
  if (raw == null || raw.isEmpty) return null;
  // EXIF writes 'YYYY:MM:DD HH:MM:SS' — colons in the date part too.
  final match = RegExp(
    r'^(\d{4}):(\d{2}):(\d{2})[ T](\d{2}):(\d{2}):(\d{2})',
  ).firstMatch(raw);
  if (match == null) return null;
  return DateTime(
    int.parse(match[1]!),
    int.parse(match[2]!),
    int.parse(match[3]!),
    int.parse(match[4]!),
    int.parse(match[5]!),
    int.parse(match[6]!),
  );
}

/// What the date cache remembers about one file. [takenAt] is the date the
/// album uses, in microseconds since the epoch.
typedef _DateEntry = AlbumCatalogEntry;

/// Reads `path<TAB>size<TAB>modified<TAB>takenAt` lines. A missing or damaged
/// cache is just an empty one.
Future<Map<String, _DateEntry>> _readDateCache(File file) async {
  final entries = <String, _DateEntry>{};
  try {
    if (!await file.exists()) return entries;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    for (final line in const LineSplitter().convert(text)) {
      final parts = line.split('\t');
      if (parts.length != 4) continue;
      final size = int.tryParse(parts[1]);
      final modified = int.tryParse(parts[2]);
      final takenAt = int.tryParse(parts[3]);
      if (size == null || modified == null || takenAt == null) continue;
      entries[parts[0]] = _DateEntry(size, modified, takenAt);
    }
  } catch (_) {
    // Start from scratch.
  }
  return entries;
}

Future<void> _writeDateCache(File file, Map<String, _DateEntry> entries) async {
  try {
    final buffer = StringBuffer();
    entries.forEach((path, entry) {
      // Tabs and newlines would break the line format. Such files are simply
      // re-read every time.
      if (path.contains('\t') || path.contains('\n') || path.contains('\r')) {
        return;
      }
      buffer
        ..write(path)
        ..write('\t')
        ..write(entry.size)
        ..write('\t')
        ..write(entry.modified)
        ..write('\t')
        ..writeln(entry.takenAt);
    });
    await file.parent.create(recursive: true);
    // Written beside the real file and renamed, so a scan that is killed
    // part-way never leaves a half-written cache behind.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(buffer.toString(), flush: true);
    await temp.rename(file.path);
  } catch (_) {
    // The cache is an optimisation only.
  }
}
