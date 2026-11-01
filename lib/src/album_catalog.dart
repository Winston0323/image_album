import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Name of the catalog kept inside a source folder.
///
/// The leading dot hides it on every platform but Windows, where the hidden
/// attribute is set as well. The extension is deliberately uncommon: `.ia`,
/// the obvious short choice, already belongs to Rollei RAW photos, which
/// darktable, XnView and the Explorer thumbnail extensions would try to open.
/// `.iacx` (image album catalog index) is not a registered type.
const String albumCatalogName = '.image_album.iacx';

/// First line of a catalog: the magic word, then the format version.
const String _magic = 'IACX';
// Raised when the kinds of file the album lists grow, so a catalog made
// before is not trusted to be complete.
const int _version = 2;

/// What the catalog knows about one image file: the size and modification time
/// it had when it was last read, and the date the album settled on for it, in
/// microseconds since the epoch.
class AlbumCatalogEntry {
  const AlbumCatalogEntry(this.size, this.modified, this.takenAt);

  final int size;
  final int modified;
  final int takenAt;
}

/// The index of a source folder as kept in its catalog file.
///
/// Paths are relative to the folder and use `/` on every platform, so the
/// folder can be moved, renamed or opened from another machine and its catalog
/// still fits.
class AlbumCatalog {
  const AlbumCatalog({
    required this.verifiedAt,
    required this.deep,
    required this.entries,
  });

  /// When every file in the catalog was last checked against the disk, in
  /// microseconds since the epoch. A scan that trusts the catalog leaves it
  /// alone, so it says how long ago the files were really looked at.
  final int verifiedAt;

  /// Whether subfolders were scanned, so the catalog holds the whole tree.
  /// When false it holds the files directly in the folder, and whatever deeper
  /// entries an earlier, deeper scan left.
  final bool deep;

  /// Photos by relative path.
  final Map<String, AlbumCatalogEntry> entries;

  /// The entries a scan of [recursive] kind covers: all of them, or only the
  /// files directly in the folder.
  Iterable<MapEntry<String, AlbumCatalogEntry>> inScope(bool recursive) =>
      recursive
      ? entries.entries
      : entries.entries.where((entry) => !entry.key.contains('/'));
}

/// The catalog file of [source].
File albumCatalogFile(String source) => File(p.join(source, albumCatalogName));

/// [path] relative to [source], with `/` separators.
String albumCatalogKey(String source, String path) =>
    p.relative(path, from: source).replaceAll(r'\', '/');

/// The path a catalog key stands for under [source].
String albumCatalogPath(String source, String key) =>
    p.joinAll([source, ...key.split('/')]);

/// Reads the catalog in [source], or null when there is none or it cannot be
/// used: wrong magic or version, or not text at all. Damaged lines are
/// skipped, so a hand-edited file loses only what was broken.
Future<AlbumCatalog?> readAlbumCatalog(String source) async {
  try {
    final file = albumCatalogFile(source);
    if (!await file.exists()) return null;
    final text = utf8.decode(await file.readAsBytes(), allowMalformed: true);
    final lines = const LineSplitter().convert(text);
    if (lines.isEmpty) return null;

    final head = lines.first.split('\t');
    if (head.length != 4 || head[0] != _magic) return null;
    if (int.tryParse(head[1]) != _version) return null;
    final verifiedAt = int.tryParse(head[2]);
    if (verifiedAt == null) return null;

    final entries = <String, AlbumCatalogEntry>{};
    for (final line in lines.skip(1)) {
      final parts = line.split('\t');
      if (parts.length != 4 || parts[0].isEmpty) continue;
      final size = int.tryParse(parts[1]);
      final modified = int.tryParse(parts[2]);
      final takenAt = int.tryParse(parts[3]);
      if (size == null || modified == null || takenAt == null) continue;
      entries[parts[0]] = AlbumCatalogEntry(size, modified, takenAt);
    }
    return AlbumCatalog(
      verifiedAt: verifiedAt,
      deep: head[3] == '1',
      entries: entries,
    );
  } catch (_) {
    return null;
  }
}

/// Writes [catalog] into [source], hidden. Returns false when it could not,
/// for instance on a read-only folder; the album then carries on with its
/// other caches.
///
/// The file is written beside the real one and renamed over it, so a scan that
/// is killed part-way never leaves a half-written catalog.
Future<bool> writeAlbumCatalog(String source, AlbumCatalog catalog) async {
  try {
    final buffer = StringBuffer()
      ..write(_magic)
      ..write('\t')
      ..write(_version)
      ..write('\t')
      ..write(catalog.verifiedAt)
      ..write('\t')
      ..writeln(catalog.deep ? '1' : '0');
    catalog.entries.forEach((key, entry) {
      // Tabs and newlines would break the line format. Such files are simply
      // read again every time.
      if (key.contains('\t') || key.contains('\n') || key.contains('\r')) {
        return;
      }
      buffer
        ..write(key)
        ..write('\t')
        ..write(entry.size)
        ..write('\t')
        ..write(entry.modified)
        ..write('\t')
        ..writeln(entry.takenAt);
    });

    final target = albumCatalogFile(source);
    final temp = File(
      p.join(
        source,
        '$albumCatalogName.${DateTime.now().microsecondsSinceEpoch}.tmp',
      ),
    );
    await temp.writeAsString(buffer.toString(), flush: true);
    try {
      // A hidden file will not be replaced on Windows until it is shown again.
      await _setHidden(target, false);
      await temp.rename(target.path);
    } catch (_) {
      try {
        await temp.delete();
      } catch (_) {}
      rethrow;
    }
    await _setHidden(target, true);
    return true;
  } catch (_) {
    return false;
  }
}

/// Deletes the catalog in [source], if there is one.
Future<void> deleteAlbumCatalog(String source) async {
  try {
    final file = albumCatalogFile(source);
    if (!await file.exists()) return;
    await _setHidden(file, false);
    await file.delete();
  } catch (_) {}
}

/// Sets or clears the hidden attribute. Only Windows has one; elsewhere the
/// leading dot already hides the file.
Future<void> _setHidden(File file, bool hidden) async {
  if (!Platform.isWindows || !await file.exists()) return;
  try {
    await Process.run('attrib', [hidden ? '+h' : '-h', file.path]);
  } catch (_) {
    // Still a dot file; only Explorer shows it.
  }
}
