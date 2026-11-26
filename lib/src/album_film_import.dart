import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'album_films.dart';
import 'album_photo.dart';

/// Copies a folder, or unzips a `.zip`, into a new roll under [filmFolder].
///
/// Extra nested folders with no pictures are removed, so the roll is one
/// folder of images. Returns that roll's path.
///
/// [onStatus] is called with short UI labels as the import moves along.
Future<String> albumImportFilmRoll({
  required String filmFolder,
  required String source,
  void Function(String status)? onStatus,
}) async {
  void status(String message) => onStatus?.call(message);

  status('Preparing roll');
  final film = Directory(filmFolder);
  await film.create(recursive: true);

  final sourceFile = File(source);
  final sourceDir = Directory(source);
  final isZip =
      await sourceFile.exists() && p.extension(source).toLowerCase() == '.zip';
  final isFolder = await sourceDir.exists();
  if (!isZip && !isFolder) {
    throw FileSystemException('Nothing to import at that path.', source);
  }

  final label = isZip ? p.basenameWithoutExtension(source) : p.basename(source);
  final roll = await _uniqueRollDirectory(film.path, _safeName(label));
  await roll.create(recursive: true);

  if (isZip) {
    status('Unpacking ${p.basename(source)}');
    await _unzipInto(sourceFile, roll, onStatus: onStatus);
  } else {
    status('Copying ${p.basename(source)}');
    await _copyTree(sourceDir, roll, onStatus: onStatus);
  }
  status('Finishing roll');
  await albumFlattenFilmRoll(roll.path);
  status('Import complete');
  return roll.path;
}

/// Creates [libraryRoot]/[kind.folderName] when the kind has no folder yet,
/// and remembers it. Returns the film folder path.
Future<String> albumEnsureFilmFolder({
  required String libraryRoot,
  required AlbumFilmKind kind,
}) async {
  final linked = await _linkedPath(libraryRoot, kind.iconKey);
  if (linked != null && await Directory(linked).exists()) {
    if (await albumFilmFolderIsCleared(linked)) {
      await albumSetFilmFolderCleared(linked, false);
    }
    await albumSetFilmLink(libraryRoot, kind.iconKey, linked);
    return linked;
  }

  final named = Directory(p.join(libraryRoot, kind.folderName));
  if (await named.exists()) {
    await albumSetFilmFolderCleared(named.path, false);
    await albumSetFilmLink(libraryRoot, kind.iconKey, named.path);
    return named.path;
  }

  await named.create(recursive: true);
  await albumSetFilmFolderCleared(named.path, false);
  await albumSetFilmLink(libraryRoot, kind.iconKey, named.path);
  return named.path;
}

/// Creates a dedicate folder under [libraryRoot] for every film kind that
/// does not already have one, so Import always has a place to put a roll.
/// A folder the user cleared is left alone.
Future<void> albumEnsureMissingFilmFolders(String libraryRoot) async {
  final root = Directory(libraryRoot);
  if (!await root.exists()) return;
  final located = <String>{};
  for (final film in await listAlbumFilmPlaces(libraryRoot)) {
    final kind = albumFilmKindForFolder(film.name);
    if (kind != null) located.add(kind.iconKey);
  }
  for (final kind in albumFilmKinds) {
    if (located.contains(kind.iconKey)) continue;
    final named = Directory(p.join(libraryRoot, kind.folderName));
    if (await named.exists() && await albumFilmFolderIsCleared(named.path)) {
      continue;
    }
    await albumEnsureFilmFolder(libraryRoot: libraryRoot, kind: kind);
  }
}

/// Collapses nested folders that hold no pictures into [rollPath], so the
/// roll is one folder of images.
Future<void> albumFlattenFilmRoll(String rollPath) async {
  var current = Directory(rollPath);
  if (!await current.exists()) return;

  while (true) {
    final dirs = <Directory>[];
    var hasImage = false;
    await for (final entity in current.list(followLinks: false)) {
      final name = p.basename(entity.path);
      if (name.startsWith('.')) continue;
      if (entity is File &&
          albumImageExtensions.contains(p.extension(name).toLowerCase())) {
        hasImage = true;
        break;
      }
      if (entity is Directory) dirs.add(entity);
    }
    if (hasImage || dirs.length != 1) break;

    final only = dirs.single;
    await for (final entity in only.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final dest = p.join(current.path, name);
      if (await FileSystemEntity.type(dest) != FileSystemEntityType.notFound) {
        final unique = await _uniqueSibling(dest);
        await entity.rename(unique);
      } else {
        await entity.rename(dest);
      }
    }
    await only.delete(recursive: true);
  }
}

Future<String?> _linkedPath(String libraryRoot, String iconKey) async {
  final links = await _readLinks(libraryRoot);
  return links[iconKey];
}

Future<Map<String, String>> _readLinks(String root) async {
  final file = File(p.join(root, albumFilmLinksName));
  if (!await file.exists()) return {};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && entry.value is String)
          entry.key as String: entry.value as String,
    };
  } on Object {
    return {};
  }
}

String _safeName(String raw) {
  final cleaned = raw
      .trim()
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .replaceAll(RegExp(r'^\.+'), '_')
      .trim();
  if (cleaned.isEmpty) return 'roll';
  return cleaned.length > 80 ? cleaned.substring(0, 80).trim() : cleaned;
}

Future<Directory> _uniqueRollDirectory(String parent, String base) async {
  var name = base;
  var n = 2;
  while (true) {
    final path = p.join(parent, name);
    if (!await Directory(path).exists() && !await File(path).exists()) {
      return Directory(path);
    }
    name = '${base}_$n';
    n++;
  }
}

Future<String> _uniqueSibling(String path) async {
  final dir = p.dirname(path);
  final base = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  var n = 2;
  while (true) {
    final next = p.join(dir, '${base}_$n$ext');
    if (await FileSystemEntity.type(next) == FileSystemEntityType.notFound) {
      return next;
    }
    n++;
  }
}

Future<void> _copyTree(
  Directory from,
  Directory to, {
  void Function(String status)? onStatus,
  int depth = 0,
}) async {
  await to.create(recursive: true);
  await for (final entity in from.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    final dest = p.join(to.path, name);
    if (entity is Directory) {
      if (depth < 2) onStatus?.call('Copying $name');
      await _copyTree(
        entity,
        Directory(dest),
        onStatus: onStatus,
        depth: depth + 1,
      );
    } else if (entity is File) {
      if (depth == 0) onStatus?.call('Copying $name');
      await entity.copy(dest);
    }
  }
}

Future<void> _unzipInto(
  File zip,
  Directory dest, {
  void Function(String status)? onStatus,
}) async {
  onStatus?.call('Reading ${p.basename(zip.path)}');
  final bytes = await zip.readAsBytes();
  final archive = ZipDecoder().decodeBytes(bytes);
  var written = 0;
  final total = archive.files.where((entry) => entry.isFile).length;
  for (final entry in archive) {
    var name = entry.name.replaceAll(r'\', '/');
    while (name.startsWith('/')) {
      name = name.substring(1);
    }
    if (name.isEmpty) continue;
    final parts = name.split('/');
    if (parts.any((part) => part == '__MACOSX' || part == '.DS_Store')) {
      continue;
    }
    if (parts.any((part) => part == '..')) continue;
    final outPath = p.join(dest.path, p.joinAll(parts));
    if (entry.isDirectory || name.endsWith('/')) {
      await Directory(outPath).create(recursive: true);
      continue;
    }
    written++;
    if (total > 0 && (written == 1 || written == total || written % 25 == 0)) {
      onStatus?.call('Unpacking $written of $total');
    }
    final out = File(outPath);
    await out.parent.create(recursive: true);
    await out.writeAsBytes(entry.content, flush: true);
  }
}
