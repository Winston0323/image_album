import 'dart:io';

import 'package:path/path.dart' as p;

/// Folder both caches (capture dates and thumbnails) live under. It is in the
/// system temp directory, which every platform provides without a plugin, and
/// which the OS may clear: everything in it can be rebuilt from the photos.
Directory albumCacheRoot() =>
    Directory(p.join(Directory.systemTemp.path, 'image_album'));

/// Stable 64-bit FNV-1a hash of [text] as 16 hex digits. Unlike
/// [String.hashCode] it is the same in every run, so it can name cache files.
String albumCacheHash(String text) {
  var hash = 0xcbf29ce484222325;
  for (final unit in text.codeUnits) {
    hash = (hash ^ unit) * 0x100000001b3;
  }
  return hash.toUnsigned(64).toRadixString(16).padLeft(16, '0');
}

/// Name of the file that indexes one source folder: what [loadAlbumPhotos] found
/// in it, and the date it settled on for each. The name depends on whether
/// subfolders were included, because that changes what the index holds.
String albumIndexName(String sourcePath, bool recursive) =>
    '${albumCacheHash('$sourcePath|$recursive')}.tsv';
