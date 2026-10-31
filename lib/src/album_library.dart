import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'album_cache.dart';
import 'album_images.dart';

/// How the caches inside an [AlbumLibrary] are made and kept.
@immutable
class AlbumCacheOptions {
  const AlbumCacheOptions({
    this.thumbnailWidth = albumThumbnailWidth,
    this.thumbnailQuality = albumThumbnailQuality,
    this.thumbnailMaxBytes = albumThumbnailCacheMaxBytes,
  }) : assert(thumbnailWidth > 0),
       assert(thumbnailQuality >= 1 && thumbnailQuality <= 100),
       assert(thumbnailMaxBytes > 0);

  /// Width, in pixels, grid thumbnails are stored at. Larger is sharper on
  /// dense screens and costs more space and decode time.
  final int thumbnailWidth;

  /// JPEG quality, 1 to 100, of stored thumbnails.
  final int thumbnailQuality;

  /// Most the thumbnails may take up. Past it the oldest are deleted.
  final int thumbnailMaxBytes;

  /// Reads options saved by [toJson]. Missing or out-of-range values fall back
  /// to the defaults, so a hand-edited file cannot break the album.
  factory AlbumCacheOptions.fromJson(Object? json) {
    if (json is! Map) return const AlbumCacheOptions();
    int pick(String key, int fallback, int min, int max) {
      final value = json[key];
      if (value is! int || value < min || value > max) return fallback;
      return value;
    }

    return AlbumCacheOptions(
      thumbnailWidth: pick('thumbnailWidth', albumThumbnailWidth, 32, 4096),
      thumbnailQuality: pick('thumbnailQuality', albumThumbnailQuality, 1, 100),
      thumbnailMaxBytes: pick(
        'thumbnailMaxBytes',
        albumThumbnailCacheMaxBytes,
        1 << 20,
        1 << 50,
      ),
    );
  }

  Map<String, Object?> toJson() => {
    'thumbnailWidth': thumbnailWidth,
    'thumbnailQuality': thumbnailQuality,
    'thumbnailMaxBytes': thumbnailMaxBytes,
  };

  @override
  bool operator ==(Object other) =>
      other is AlbumCacheOptions &&
      other.thumbnailWidth == thumbnailWidth &&
      other.thumbnailQuality == thumbnailQuality &&
      other.thumbnailMaxBytes == thumbnailMaxBytes;

  @override
  int get hashCode =>
      Object.hash(thumbnailWidth, thumbnailQuality, thumbnailMaxBytes);
}

/// What the album file knows about the index of one source folder.
@immutable
class AlbumIndexInfo {
  const AlbumIndexInfo({
    required this.source,
    required this.recursive,
    required this.file,
    required this.photoCount,
    required this.scannedAt,
  });

  /// The source folder, normalized.
  final String source;

  /// Whether the index covers subfolders too.
  final bool recursive;

  /// Name of the index file in [AlbumLibrary.indexDirectory].
  final String file;

  /// Photos found at the last scan.
  final int photoCount;

  /// When that scan finished.
  final DateTime scannedAt;

  static AlbumIndexInfo? _fromJson(Object? json) {
    if (json is! Map) return null;
    final source = json['source'];
    final recursive = json['recursive'];
    final file = json['file'];
    final count = json['photos'];
    final scanned = json['scannedAt'];
    if (source is! String ||
        recursive is! bool ||
        file is! String ||
        count is! int ||
        scanned is! String) {
      return null;
    }
    final at = DateTime.tryParse(scanned);
    if (at == null) return null;
    return AlbumIndexInfo(
      source: source,
      recursive: recursive,
      file: file,
      photoCount: count,
      scannedAt: at,
    );
  }

  Map<String, Object?> _toJson() => {
    'source': source,
    'recursive': recursive,
    'file': file,
    'photos': photoCount,
    'scannedAt': scannedAt.toUtc().toIso8601String(),
  };
}

/// An album kept in a folder of its own: which folders it shows, which
/// subfolders are hidden, and the caches that make opening it fast.
///
/// The folder holds
///
/// - `album.json`, the manifest: [sources], [excluded], the [cache] options,
///   and a record of each source's index;
/// - `index/`, one file per source folder listing its photos with their sizes,
///   modification times and capture dates. Open it again and the album shows
///   those photos at once, then checks the folder and applies what changed;
/// - `thumbs/`, the small JPEG copies shown in the grid.
///
/// Both `index/` and `thumbs/` can be rebuilt from the photos, so deleting them
/// only makes the next opening slower. Only the manifest holds choices that
/// cannot be recovered.
///
/// Pass a library to [ImageAlbum] to use its caches, and use [addSource],
/// [removeSource] and [setExcluded] to keep the user's choices in it. It
/// notifies its listeners when those choices change.
class AlbumLibrary extends ChangeNotifier {
  AlbumLibrary._(this.directory);

  /// Version written to the manifest.
  static const int version = 1;

  /// Name of the manifest inside [directory].
  static const String manifestName = 'album.json';

  /// How long an index nobody has refreshed is kept. An index of a source
  /// that is still shown is refreshed every time the album opens.
  static const Duration unusedIndexLifetime = Duration(days: 30);

  /// The folder the album file lives in.
  final Directory directory;

  List<String> _sources = [];
  Set<String> _excluded = {};
  AlbumCacheOptions _cache = const AlbumCacheOptions();
  final Map<String, AlbumIndexInfo> _indexes = {};

  Future<void> _writing = Future.value();

  /// Opens the album file in [directory], creating the folder and manifest
  /// when they are not there yet. A manifest that cannot be read is set aside
  /// as `album.json.damaged` and the album starts empty. Index files nothing
  /// refers to, and indexes unused for [unusedIndexLifetime], are deleted.
  ///
  /// [now] is the time used to judge which indexes are unused.
  static Future<AlbumLibrary> open(Directory directory, {DateTime? now}) async {
    final library = AlbumLibrary._(directory);
    await directory.create(recursive: true);
    await library._load();
    await library._tidy(now ?? DateTime.now());
    return library;
  }

  /// The manifest.
  File get file => File(p.join(directory.path, manifestName));

  /// Where the per-folder indexes are kept. Pass it to [loadAlbumPhotos] and
  /// [readAlbumIndex] as `cacheDirectory`.
  Directory get indexDirectory => Directory(p.join(directory.path, 'index'));

  /// Where thumbnails are kept.
  Directory get thumbnailDirectory =>
      Directory(p.join(directory.path, 'thumbs'));

  /// The folders the album shows, in the order added. Normalized.
  List<String> get sources => List.unmodifiable(_sources);

  /// The folders whose photos are hidden. Normalized.
  Set<String> get excluded => Set.unmodifiable(_excluded);

  /// How thumbnails are made and how much space they may take.
  AlbumCacheOptions get cache => _cache;

  /// What the manifest records about each source's index.
  List<AlbumIndexInfo> get indexes => List.unmodifiable(_indexes.values);

  /// The record for [source], or null when it has not been scanned here.
  AlbumIndexInfo? indexFor(String source, {bool recursive = false}) =>
      _indexes[_indexKey(p.normalize(source), recursive)];

  /// Adds [path] to the sources. Returns false, changing nothing, when it is
  /// already one.
  Future<bool> addSource(String path) async {
    final added = p.normalize(path);
    if (_sources.any((source) => p.equals(source, added))) return false;
    _sources = [..._sources, added];
    notifyListeners();
    await _save();
    return true;
  }

  /// Removes [path] from the sources. Returns false when it was not one. Its
  /// index is kept for a while, so adding the folder back is instant.
  Future<bool> removeSource(String path) async {
    final index = _sources.indexWhere((source) => p.equals(source, path));
    if (index < 0) return false;
    _sources = [..._sources]..removeAt(index);
    notifyListeners();
    await _save();
    return true;
  }

  /// Replaces the sources, dropping repeats.
  Future<void> setSources(Iterable<String> sources) async {
    final next = {for (final source in sources) p.normalize(source)}.toList();
    if (listEquals(next, _sources)) return;
    _sources = next;
    notifyListeners();
    await _save();
  }

  /// Replaces the hidden folders.
  Future<void> setExcluded(Iterable<String> folders) async {
    final next = {for (final folder in folders) p.normalize(folder)};
    if (setEquals(next, _excluded)) return;
    _excluded = next;
    notifyListeners();
    await _save();
  }

  /// Changes how thumbnails are made. Thumbnails already stored keep their
  /// old look until they age out; new ones follow the new options.
  Future<void> setCacheOptions(AlbumCacheOptions options) async {
    if (options == _cache) return;
    _cache = options;
    notifyListeners();
    await _save();
  }

  /// Notes that [source] was scanned and held [photoCount] photos. [ImageAlbum]
  /// calls this itself when given the library. A failure to save is ignored:
  /// the record is only a summary of the index file.
  Future<void> recordScan(
    String source,
    bool recursive,
    int photoCount, {
    DateTime? at,
  }) async {
    final normalized = p.normalize(source);
    _indexes[_indexKey(normalized, recursive)] = AlbumIndexInfo(
      source: normalized,
      recursive: recursive,
      file: albumIndexName(normalized, recursive),
      photoCount: photoCount,
      scannedAt: at ?? DateTime.now(),
    );
    try {
      await _save();
    } catch (_) {}
  }

  /// How much room the caches take.
  Future<AlbumCacheUsage> cacheUsage() async {
    final thumbnails = await _measure(thumbnailDirectory, '.thumb');
    final indexes = await _measure(indexDirectory, '.tsv');
    return AlbumCacheUsage(
      thumbnailCount: thumbnails.$1,
      thumbnailBytes: thumbnails.$2,
      indexCount: indexes.$1,
      indexBytes: indexes.$2,
    );
  }

  /// Deletes every thumbnail and index. The next opening rebuilds them, so it
  /// is slower. Sources, hidden folders and options are kept.
  Future<void> clearCaches() async {
    for (final directory in [thumbnailDirectory, indexDirectory]) {
      try {
        if (await directory.exists()) await directory.delete(recursive: true);
      } catch (_) {}
    }
    _indexes.clear();
    await _save();
  }

  static String _indexKey(String source, bool recursive) =>
      '$source|$recursive';

  Future<(int, int)> _measure(Directory directory, String extension) async {
    var count = 0;
    var bytes = 0;
    try {
      if (!await directory.exists()) return (0, 0);
      await for (final entity in directory.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith(extension)) continue;
        try {
          bytes += await entity.length();
          count++;
        } catch (_) {}
      }
    } catch (_) {}
    return (count, bytes);
  }

  Future<void> _load() async {
    final manifest = file;
    if (!await manifest.exists()) return;
    try {
      final json = jsonDecode(utf8.decode(await manifest.readAsBytes()));
      if (json is! Map) throw const FormatException('Not an album file');

      final sources = json['sources'];
      if (sources is List) {
        _sources = {
          for (final source in sources)
            if (source is String && source.isNotEmpty) p.normalize(source),
        }.toList();
      }
      final excluded = json['excluded'];
      if (excluded is List) {
        _excluded = {
          for (final folder in excluded)
            if (folder is String && folder.isNotEmpty) p.normalize(folder),
        };
      }
      _cache = AlbumCacheOptions.fromJson(json['cache']);
      final indexes = json['indexes'];
      if (indexes is List) {
        for (final entry in indexes) {
          final info = AlbumIndexInfo._fromJson(entry);
          if (info != null) {
            _indexes[_indexKey(info.source, info.recursive)] = info;
          }
        }
      }
    } catch (_) {
      // Keep what was there for the user to find rather than overwrite it.
      _sources = [];
      _excluded = {};
      _cache = const AlbumCacheOptions();
      _indexes.clear();
      try {
        await manifest.rename('${manifest.path}.damaged');
      } catch (_) {}
    }
  }

  /// Forgets indexes nobody has refreshed lately, and deletes index files the
  /// manifest does not mention, which a scan that was killed before it could
  /// be recorded leaves behind.
  Future<void> _tidy(DateTime now) async {
    final before = _indexes.length;
    _indexes.removeWhere(
      (_, info) => now.difference(info.scannedAt) > unusedIndexLifetime,
    );
    final known = {for (final info in _indexes.values) info.file};

    try {
      final directory = indexDirectory;
      if (await directory.exists()) {
        await for (final entity in directory.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          final orphan = name.endsWith('.tsv') && !known.contains(name);
          var leftover = false;
          if (name.endsWith('.tmp')) {
            final age = now.difference((await entity.stat()).modified);
            leftover = age > const Duration(hours: 1);
          }
          if (orphan || leftover) {
            try {
              await entity.delete();
            } catch (_) {}
          }
        }
      }
    } catch (_) {}

    if (_indexes.length != before) {
      try {
        await _save();
      } catch (_) {}
    }
  }

  Map<String, Object?> _toJson() => {
    'version': version,
    'sources': _sources,
    'excluded': _excluded.toList()..sort(),
    'cache': _cache.toJson(),
    'indexes': [for (final info in _indexes.values) info._toJson()],
  };

  /// Writes the manifest. Writes are queued, so two changes in quick succession
  /// cannot overwrite each other, and the content is taken now, so the file
  /// ends up with the last state.
  Future<void> _save() {
    final text = const JsonEncoder.withIndent('  ').convert(_toJson());
    final write = _writing.then((_) => _write(text));
    _writing = write.then((_) {}, onError: (_) {});
    return write;
  }

  Future<void> _write(String text) async {
    await directory.create(recursive: true);
    // Written beside the manifest and renamed, so a crash part-way never
    // leaves half a manifest.
    final temp = File(
      '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    await temp.writeAsString(text, flush: true);
    await temp.rename(file.path);
  }
}

/// How much space an [AlbumLibrary]'s caches use.
@immutable
class AlbumCacheUsage {
  const AlbumCacheUsage({
    required this.thumbnailCount,
    required this.thumbnailBytes,
    required this.indexCount,
    required this.indexBytes,
  });

  final int thumbnailCount;
  final int thumbnailBytes;
  final int indexCount;
  final int indexBytes;

  int get totalBytes => thumbnailBytes + indexBytes;

  @override
  String toString() =>
      'AlbumCacheUsage($thumbnailCount thumbnails, $thumbnailBytes bytes; '
      '$indexCount indexes, $indexBytes bytes)';
}
