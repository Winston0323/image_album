import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'album_photo.dart';

/// How a chosen folder is added: film scans, or digital photos.
enum AlbumFolderKind { film, digital }

/// Asks whether [path] should be imported as film scans or digital photos.
/// Null when cancelled.
Future<AlbumFolderKind?> askAlbumFolderKind(BuildContext context, String path) {
  final name = p.basename(path);
  final label = name.isEmpty ? path : name;
  return showDialog<AlbumFolderKind>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Import folder'),
      content: Text(
        'Import "$label" as film scans, or as digital photos?\n\n'
        'Film scans: each folder is a film, and every folder inside it is listed. '
        'Digital photos are added to the album grid.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, AlbumFolderKind.digital),
          child: const Text('Digital'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, AlbumFolderKind.film),
          child: const Text('Film'),
        ),
      ],
    ),
  );
}

/// Hidden file in a roll folder. It records whether that roll is `135` or
/// `120`, so the scans can sit directly under the film.
const String albumFilmMetaName = '.image_album.film';

/// Remembers a film kind whose folder could not be renamed.
const String albumFilmLinksName = '.image_album.film-links.json';

/// One scanned roll: a folder of pictures directly under a film.
class AlbumFilmRoll {
  const AlbumFilmRoll({
    required this.name,
    required this.format,
    required this.path,
  });

  /// The roll folder's name. The waterfall uses it as the section title.
  final String name;

  /// `135`, `120`, or empty when the roll's meta file has not been written.
  final String format;

  final String path;
}

/// One film stock: a folder directly under the film library.
///
/// ```
/// library/
///   Kodak Portra 400/
///     2024-tokyo/          <- one roll
///       .image_album.film  <- {"format":"135"}
///       001.jpg
///     summer/
///       .image_album.film  <- {"format":"120"}
/// ```
///
/// A film that still uses a `135` or `120` folder is read the same way, and
/// each roll under it receives [albumFilmMetaName] when it does not have one.
class AlbumFilm {
  const AlbumFilm({
    required this.name,
    required this.path,
    required this.iconAsset,
    required this.rolls,
    this.hasPictures = false,
  });

  final String name;
  final String path;

  /// Box art from the same set ApertureDiary uses, or null for a letter tile.
  final String? iconAsset;

  final List<AlbumFilmRoll> rolls;

  /// Whether this film has a picture in any folder. An empty film, such as a
  /// Superia folder whose `120` and `135` folders have no scans, is not shown.
  final bool hasPictures;
}

/// Camera, lens, and film recorded for one folder.
class AlbumFolderMeta {
  const AlbumFolderMeta({
    this.format = '',
    this.filmId,
    this.filmName,
    this.iso,
    this.frameFormat,
    this.cameraId,
    this.cameraLabel,
    this.lensId,
    this.lensLabel,
    this.notes,
  });

  /// `135`, `120`, or empty.
  final String format;
  final String? filmId;
  final String? filmName;
  final int? iso;

  /// ApertureDiary frame id, such as `36x24` or `6x6`.
  final String? frameFormat;
  final String? cameraId;
  final String? cameraLabel;
  final String? lensId;
  final String? lensLabel;
  final String? notes;

  bool get isEmpty =>
      format.isEmpty &&
      filmId == null &&
      filmName == null &&
      iso == null &&
      cameraId == null &&
      lensId == null &&
      (notes == null || notes!.isEmpty);
}

/// The format recorded in a roll folder, or null when it has no usable meta.
Future<String?> readAlbumFilmFormat(String rollPath) async {
  final format = (await readAlbumFolderMeta(rollPath)).format;
  return format == '135' || format == '120' ? format : null;
}

/// The metadata file in [folder], or an empty record when there is none.
Future<AlbumFolderMeta> readAlbumFolderMeta(String folder) async {
  final raw = await _readMetaMap(folder);
  if (raw == null) return const AlbumFolderMeta();
  final format = raw['format'];
  final iso = raw['iso'];
  return AlbumFolderMeta(
    format: format == '135' || format == '120' ? format : '',
    filmId: _metaString(raw['filmId']),
    filmName: _metaString(raw['filmName']),
    iso: iso is num ? iso.toInt() : int.tryParse('$iso'),
    frameFormat: _metaString(raw['frameFormat']),
    cameraId: _metaString(raw['cameraId']),
    cameraLabel: _metaString(raw['cameraLabel']),
    lensId: _metaString(raw['lensId']),
    lensLabel: _metaString(raw['lensLabel']),
    notes: _metaString(raw['notes']),
  );
}

/// Writes [meta] into the folder, keeping any other keys already in the file.
Future<void> writeAlbumFolderMeta(String folder, AlbumFolderMeta meta) async {
  final raw = await _readMetaMap(folder) ?? <String, dynamic>{};
  void put(String key, Object? value) {
    if (value == null || (value is String && value.isEmpty)) {
      raw.remove(key);
    } else {
      raw[key] = value;
    }
  }

  put(
    'format',
    meta.format == '135' || meta.format == '120' ? meta.format : null,
  );
  put('filmId', meta.filmId);
  put('filmName', meta.filmName);
  put('iso', meta.iso);
  put('frameFormat', meta.frameFormat);
  put('cameraId', meta.cameraId);
  put('cameraLabel', meta.cameraLabel);
  put('lensId', meta.lensId);
  put('lensLabel', meta.lensLabel);
  put('notes', meta.notes);
  final file = File(p.join(folder, albumFilmMetaName));
  await _writeFilmFile(file, jsonEncode(raw));
}

/// Writes [format] into the roll folder's hidden meta file.
///
/// [format] is `135` or `120`. Nothing is rewritten when that is already what
/// the file says. Other metadata in the file is left in place.
Future<void> writeAlbumFilmFormat(String rollPath, String format) async {
  if (format != '135' && format != '120') {
    throw ArgumentError.value(format, 'format', 'Use 135 or 120');
  }
  if (await readAlbumFilmFormat(rollPath) == format) return;
  final current = await readAlbumFolderMeta(rollPath);
  await writeAlbumFolderMeta(
    rollPath,
    AlbumFolderMeta(
      format: format,
      filmId: current.filmId,
      filmName: current.filmName,
      iso: current.iso,
      frameFormat: current.frameFormat,
      cameraId: current.cameraId,
      cameraLabel: current.cameraLabel,
      lensId: current.lensId,
      lensLabel: current.lensLabel,
      notes: current.notes,
    ),
  );
}

Future<Map<String, dynamic>?> _readMetaMap(String folder) async {
  final file = File(p.join(folder, albumFilmMetaName));
  if (!await file.exists()) return null;
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
  } on Object {
    return null;
  }
  return null;
}

String? _metaString(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

/// Which film folders are in [root], without opening the pictures inside them.
///
/// The film list uses this so Located and No location can appear before the
/// rolls are walked.
Future<List<AlbumFilm>> listAlbumFilmPlaces(String root) async {
  final directory = Directory(root);
  if (!await directory.exists()) return const [];
  final linked = await _filmLinksByPath(root);
  final films = <AlbumFilm>[];
  final used = <String>{};
  final seen = <String>{};
  final children = <Directory>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    if (p.basename(entity.path).startsWith('.')) continue;
    children.add(Directory(entity.path));
  }

  void addDirectory(Directory filmDir, AlbumFilmKind? forced) {
    if (!seen.add(_pathKey(filmDir.path))) return;
    final name = p.basename(filmDir.path);
    final kind = forced ?? albumFilmKindForFolder(name);
    if (kind != null && !used.add(kind.iconKey)) return;
    films.add(
      AlbumFilm(
        name: kind?.name ?? name,
        path: filmDir.path,
        iconAsset: kind?.iconAsset ?? albumFilmIconAsset(name),
        rolls: const [],
      ),
    );
  }

  for (final child in children) {
    final forced = linked[_pathKey(child.path)];
    if (forced == null) continue;
    addDirectory(child, forced.kind);
  }
  for (final item in linked.values) {
    final folder = Directory(item.path);
    if (!folder.existsSync()) continue;
    addDirectory(folder, item.kind);
  }
  for (final child in children) {
    if (linked.containsKey(_pathKey(child.path))) continue;
    if (albumFilmFolderIsClearedSync(child.path)) continue;
    addDirectory(child, null);
  }
  films.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return films;
}

/// Reads [root] as a film library.
///
/// Each child folder of [root] is a film. Each folder under a film is one
/// roll, and its format comes from [albumFilmMetaName]. A folder with no
/// pictures is skipped, including an empty `135` or `120` folder. A `135` or
/// `120` folder is still the old layout: the folders inside it are the rolls,
/// and each one that holds pictures is given a meta file when it lacks one.
/// Names that start with a dot are skipped.
Future<List<AlbumFilm>> scanAlbumFilms(String root) async {
  await albumRenameMatchedFilmFolders(root);
  final directory = Directory(root);
  if (!await directory.exists()) return const [];
  final linked = await _filmLinksByPath(root);
  final films = <AlbumFilm>[];
  final used = <String>{};
  final seen = <String>{};
  final children = <Directory>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    if (p.basename(entity.path).startsWith('.')) continue;
    children.add(Directory(entity.path));
  }

  Future<void> addDirectory(Directory filmDir, AlbumFilmKind? forced) async {
    if (!seen.add(_pathKey(filmDir.path))) return;
    final name = p.basename(filmDir.path);
    if (forced == null && await albumFilmFolderIsCleared(filmDir.path)) {
      return;
    }
    final kind = forced ?? albumFilmKindForFolder(name);
    if (kind != null && !used.add(kind.iconKey)) return;
    final rolls = await _rollsOf(filmDir);
    films.add(
      AlbumFilm(
        name: kind?.name ?? name,
        path: filmDir.path,
        iconAsset: kind?.iconAsset ?? albumFilmIconAsset(name),
        rolls: rolls,
        hasPictures: rolls.isNotEmpty || await _containsScan(filmDir),
      ),
    );
  }

  // An explicit folder wins over a name match, including one Windows would
  // not rename into the canonical name.
  for (final child in children) {
    final forced = linked[_pathKey(child.path)];
    if (forced == null) continue;
    await addDirectory(child, forced.kind);
  }
  for (final item in linked.values) {
    final folder = Directory(item.path);
    if (!await folder.exists()) continue;
    await addDirectory(folder, item.kind);
  }
  for (final child in children) {
    await addDirectory(child, null);
  }
  films.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  return films;
}

Future<List<AlbumFilmRoll>> _rollsOf(Directory film) async {
  final rolls = <AlbumFilmRoll>[];
  await for (final entity in film.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    if (name == '135' || name == '120') {
      final folder = Directory(entity.path);
      // Pictures can sit in the format folder itself. An empty one is not a
      // roll, so Superia's unused 120 or 135 folder stays off the film page.
      if (await _hasScan(folder)) {
        rolls.add(AlbumFilmRoll(name: name, format: name, path: folder.path));
      }
      await for (final rollDir in folder.list(followLinks: false)) {
        if (rollDir is! Directory) continue;
        final rollName = p.basename(rollDir.path);
        if (rollName.startsWith('.')) continue;
        if (rollName == '135' || rollName == '120') continue;
        if (rollName.toLowerCase() == 'jpg' && await _hasScan(folder)) {
          continue;
        }
        await _considerRoll(
          Directory(rollDir.path),
          rollName,
          rolls,
          format: name,
        );
      }
      continue;
    }
    await _considerRoll(Directory(entity.path), name, rolls);
  }
  rolls.sort((a, b) {
    final byName = b.name.toLowerCase().compareTo(a.name.toLowerCase());
    if (byName != 0) return byName;
    return a.format.compareTo(b.format);
  });
  return rolls;
}

/// Adds [directory] when it is a roll, then looks inside it for more.
Future<void> _considerRoll(
  Directory directory,
  String name,
  List<AlbumFilmRoll> rolls, {
  String? format,
}) async {
  if (await _hasScan(directory)) {
    final recorded = await readAlbumFilmFormat(directory.path);
    final resolved = recorded ?? format ?? '';
    if (recorded == null && (format == '135' || format == '120')) {
      await writeAlbumFilmFormat(directory.path, format!);
    }
    rolls.add(
      AlbumFilmRoll(name: name, format: resolved, path: directory.path),
    );
  }
  await _rollsInto(directory, rolls, format: format);
}

Future<void> _rollsInto(
  Directory film,
  List<AlbumFilmRoll> rolls, {
  String? format,
}) async {
  await for (final entity in film.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    if (name == '135' || name == '120') continue;
    if (name.toLowerCase() == 'jpg' && await _hasScan(film)) continue;
    await _considerRoll(Directory(entity.path), name, rolls, format: format);
  }
}

/// Pictures to show for a roll that Lightroom Classic has exported.
///
/// A folder that already holds pictures and also has a `JPG` folder is one
/// roll: the `JPG` folder is the export. A file there replaces the picture
/// of the same name (any extension) in the parent. Exports with no match
/// stay, and so do originals with no export.
class AlbumLightroomRolls {
  const AlbumLightroomRolls(this.photos, this.jpegFolders);

  final List<AlbumPhoto> photos;

  /// `JPG` folders that were folded into the roll above them.
  final Set<String> jpegFolders;
}

AlbumLightroomRolls albumPreferLightroomJpeg(List<AlbumPhoto> photos) {
  final byDir = <String, List<AlbumPhoto>>{};
  for (final photo in photos) {
    byDir
        .putIfAbsent(p.normalize(p.dirname(photo.file.path)), () => [])
        .add(photo);
  }
  final drop = <String>{};
  final jpegFolders = <String>{};
  for (final entry in byDir.entries) {
    if (p.basename(entry.key).toLowerCase() != 'jpg') continue;
    final parent = p.normalize(p.dirname(entry.key));
    final originals = byDir[parent];
    if (originals == null || originals.isEmpty) continue;
    jpegFolders.add(entry.key);
    final exported = <String, AlbumPhoto>{};
    for (final photo in entry.value) {
      exported[p.basenameWithoutExtension(photo.file.path).toLowerCase()] =
          photo;
    }
    for (final photo in originals) {
      final stem = p.basenameWithoutExtension(photo.file.path).toLowerCase();
      if (exported.containsKey(stem)) drop.add(photo.id);
    }
  }
  return AlbumLightroomRolls([
    for (final photo in photos)
      if (!drop.contains(photo.id)) photo,
  ], jpegFolders);
}

/// The roll a picture belongs to. Lightroom's `JPG` export folder counts as
/// its parent.
String albumRollFolder(String directory, Set<String> jpegFolders) {
  final normalized = p.normalize(directory);
  if (jpegFolders.contains(normalized)) {
    return p.normalize(p.dirname(normalized));
  }
  return normalized;
}

/// Whether [directory] holds a picture in this folder or any folder inside it.
Future<bool> _containsScan(Directory directory) async {
  if (await _hasScan(directory)) return true;
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    if (p.basename(entity.path).startsWith('.')) continue;
    if (await _containsScan(Directory(entity.path))) return true;
  }
  return false;
}

/// Whether [directory] holds a picture directly inside it.
Future<bool> _hasScan(Directory directory) async {
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! File) continue;
    if (albumImageExtensions.contains(p.extension(entity.path).toLowerCase())) {
      return true;
    }
  }
  return false;
}

/// Writes [contents] over [file]. A hidden file on Windows cannot be opened
/// for writing, which surfaces as "Cannot open file", so the hidden flag is
/// cleared first and put back afterwards.
Future<void> _writeFilmFile(File file, String contents) async {
  if (Platform.isWindows && await file.exists()) {
    await Process.run('attrib', ['-h', '-r', file.path]);
  }
  await file.writeAsString(contents);
  await _hideFilmMeta(file);
}

/// Sets the hidden attribute. Only Windows has one; elsewhere the leading
/// dot already hides the file. `attrib` is not awaited: under a widget test
/// a real process never finishes.
Future<void> _hideFilmMeta(File file) async {
  if (!Platform.isWindows || !await file.exists()) return;
  try {
    unawaited(Process.run('attrib', ['+h', file.path]));
  } catch (_) {}
}

/// One film kind from ApertureDiary's list, such as Gold 200 or Ultramax.
class AlbumFilmKind {
  const AlbumFilmKind({
    required this.name,
    required this.iconKey,
    required this.folderName,
  });

  /// Display name, for example `Kodak Gold 200`.
  final String name;

  final String iconKey;

  /// Folder name: brand, series, then the film, such as `KODAK_GOLD_200`.
  final String folderName;

  String get iconAsset => 'assets/films/$iconKey.png';
}

/// Folder name for a catalog display name.
///
/// `Kodak Vision3 250D (5207)` becomes `KODAK_VISION3_5207`.
/// `Kodak Gold 200` becomes `KODAK_GOLD_200`.
String albumFilmFolderName(String displayName) {
  var rest = displayName.trim();
  final lower = rest.toLowerCase();
  String brand = '';
  const brands = [
    ('kodak ', 'KODAK'),
    ('fujichrome ', 'FUJICHROME'),
    ('fujifilm ', 'FUJIFILM'),
    ('ilford ', 'ILFORD'),
    ('cinestill ', 'CINESTILL'),
  ];
  for (final (prefix, token) in brands) {
    if (lower.startsWith(prefix)) {
      brand = token;
      rest = rest.substring(prefix.length).trim();
      break;
    }
  }

  final code = RegExp(r'\(([^)]+)\)').firstMatch(rest);
  String series;
  String filmName;
  if (code != null) {
    filmName = _folderToken(code.group(1)!);
    final words = rest
        .substring(0, code.start)
        .trim()
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    if (words.length >= 2 && RegExp(r'^\d+[A-Za-z]$').hasMatch(words.last)) {
      words.removeLast();
    }
    series = _folderToken(words.join(' '));
  } else {
    final words = rest
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    final roman = RegExp(r'^(?i:[ivx]+)$');
    if (words.length >= 2 &&
        roman.hasMatch(words.last) &&
        RegExp(r'^\d').hasMatch(words[words.length - 2])) {
      filmName = _folderToken('${words[words.length - 2]}_${words.last}');
      series = _folderToken(words.sublist(0, words.length - 2).join(' '));
    } else if (words.isNotEmpty && _looksLikeFilmName(words.last)) {
      filmName = _folderToken(words.last);
      series = _folderToken(words.sublist(0, words.length - 1).join(' '));
    } else if (words.length >= 2) {
      filmName = _folderToken(words.last);
      series = _folderToken(words.sublist(0, words.length - 1).join(' '));
    } else {
      filmName = _folderToken(words.join(' '));
      series = '';
    }
  }
  return [
    if (brand.isNotEmpty) brand,
    if (series.isNotEmpty) series,
    if (filmName.isNotEmpty) filmName,
  ].join('_');
}

String _folderToken(String value) => value
    .toUpperCase()
    .replaceAll(RegExp(r'[^A-Z0-9]+'), '_')
    .replaceAll(RegExp(r'_+'), '_')
    .replaceAll(RegExp(r'^_|_$'), '');

bool _looksLikeFilmName(String word) =>
    RegExp(r'^[A-Za-z]*\d+[A-Za-z]*$').hasMatch(word);

/// Every film kind ApertureDiary ships, in catalog order.
final List<AlbumFilmKind> albumFilmKinds = [
  for (final film in _catalog)
    AlbumFilmKind(
      name: film.$1,
      iconKey: film.$2,
      folderName: albumFilmFolderName(film.$1),
    ),
];

/// The catalog kind [folderName] already refers to, if it is unambiguous.
AlbumFilmKind? albumFilmKindForFolder(String folderName) {
  final key = _fold(folderName);
  for (final film in albumFilmKinds) {
    if (key == _fold(film.name) ||
        key == _fold(film.iconKey) ||
        key == _fold(film.folderName)) {
      return film;
    }
  }
  if (key.length < 3) return null;
  final hits = [
    for (final film in albumFilmKinds)
      if (_fold(film.name).contains(key) || _fold(film.iconKey).startsWith(key))
        film,
  ];
  if (hits.length == 1) return hits.single;
  return null;
}

/// Renames library folders that already match a film kind.
///
/// `Gold 200` becomes `KODAK_GOLD_200`. A folder that is already named that
/// way is left alone, and so is a name that matches more than one kind.
Future<void> albumRenameMatchedFilmFolders(String root) async {
  final directory = Directory(root);
  if (!await directory.exists()) return;
  final linked = await _filmLinksByPath(root);
  final pending = <(Directory, String)>[];
  await for (final entity in directory.list(followLinks: false)) {
    if (entity is! Directory) continue;
    final name = p.basename(entity.path);
    if (name.startsWith('.')) continue;
    if (linked.containsKey(_pathKey(entity.path))) continue;
    final kind = albumFilmKindForFolder(name);
    if (kind == null || name == kind.folderName) continue;
    if (await albumFilmFolderIsCleared(entity.path)) continue;
    pending.add((entity, kind.folderName));
  }
  for (final (folder, next) in pending) {
    final dest = Directory(p.join(root, next));
    if (await dest.exists()) continue;
    try {
      await folder.rename(dest.path);
    } on FileSystemException {
      continue;
    }
  }
}

/// Renames [folder] to this kind's folder name.
///
/// When [libraryRoot] is set, the folder is placed directly under it. Returns
/// the new path, or null when the destination is already taken or [folder] is
/// the library itself.
Future<String?> albumPlaceFilmFolder({
  required String folder,
  required AlbumFilmKind kind,
  String? libraryRoot,
}) async {
  final source = Directory(folder);
  if (!await source.exists()) return null;
  final current = p.normalize(source.path);
  final root = libraryRoot == null || libraryRoot.isEmpty
      ? null
      : p.normalize(libraryRoot);
  if (root != null && _samePath(current, root)) return null;
  final parent = root ?? p.dirname(current);
  if (!_sameVolume(current, parent)) {
    throw FileSystemException(
      'The folder is on a different drive from the film library. '
      'Move it onto that drive, then choose it again.',
      current,
    );
  }
  final destPath = p.normalize(p.join(parent, kind.folderName));
  if (!_samePath(current, destPath) && p.isWithin(current, destPath)) {
    throw FileSystemException(
      'Choose the film folder itself, not the library that contains it.',
      current,
    );
  }
  final destTaken =
      !_samePath(destPath, current) && await Directory(destPath).exists();
  if (destTaken && !await albumFilmFolderIsCleared(destPath)) return null;
  // Keep a folder Windows will not rename, and a folder that already has the
  // canonical name. The link is what makes the film list show it.
  if (_samePath(destPath, current) || destTaken) {
    await _rememberFilmFolder(root, kind, current);
    return current;
  }
  try {
    await _renameDirectory(source, destPath);
  } on FileSystemException {
    await _rememberFilmFolder(root, kind, current);
    return current;
  }
  await _rememberFilmFolder(root, kind, destPath);
  return destPath;
}

Future<void> _rememberFilmFolder(
  String? libraryRoot,
  AlbumFilmKind kind,
  String folder,
) async {
  await albumSetFilmFolderCleared(folder, false);
  if (libraryRoot != null) {
    await albumSetFilmLink(libraryRoot, kind.iconKey, folder);
  }
}

/// Points [kind] at [folder] without renaming it.
Future<void> albumSetFilmLink(
  String libraryRoot,
  String iconKey,
  String folder,
) async {
  final links = await _readFilmLinks(libraryRoot);
  final normal = p.normalize(folder);
  final key = _pathKey(normal);
  links.removeWhere((_, path) => _pathKey(path) == key);
  links[iconKey] = normal;
  await _writeFilmLinks(libraryRoot, links);
}

/// Forgets the remembered folder for [iconKey].
Future<void> albumClearFilmLink(String libraryRoot, String iconKey) async {
  final links = await _readFilmLinks(libraryRoot);
  if (links.remove(iconKey) == null) return;
  await _writeFilmLinks(libraryRoot, links);
}

Future<Map<String, String>> _readFilmLinks(String root) async {
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

Future<void> _writeFilmLinks(String root, Map<String, String> links) async {
  final file = File(p.join(root, albumFilmLinksName));
  await _writeFilmFile(file, jsonEncode(links));
}

Future<Map<String, ({String path, AlbumFilmKind kind})>> _filmLinksByPath(
  String root,
) async {
  final links = await _readFilmLinks(root);
  final byPath = <String, ({String path, AlbumFilmKind kind})>{};
  for (final entry in links.entries) {
    AlbumFilmKind? kind;
    for (final item in albumFilmKinds) {
      if (item.iconKey == entry.key) kind = item;
    }
    if (kind == null) continue;
    final path = p.normalize(entry.value);
    byPath[_pathKey(path)] = (path: path, kind: kind);
  }
  return byPath;
}

/// Same folder on Windows even when the drive letter or name differs in case.
String _pathKey(String path) {
  final normal = p.normalize(path);
  return Platform.isWindows ? normal.toLowerCase() : normal;
}

bool _samePath(String a, String b) => _pathKey(a) == _pathKey(b);

/// Whether this film folder was cleared and should not be matched again.
Future<bool> albumFilmFolderIsCleared(String folder) async {
  final raw = await _readMetaMap(folder);
  return raw?['cleared'] == true;
}

/// Same as [albumFilmFolderIsCleared], for a listing that must stay quick.
bool albumFilmFolderIsClearedSync(String folder) {
  final file = File(p.join(folder, albumFilmMetaName));
  if (!file.existsSync()) return false;
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    return decoded is Map && decoded['cleared'] == true;
  } on Object {
    return false;
  }
}

/// Marks or unmarks [folder] so a cleared film is not picked up by its name.
Future<void> albumSetFilmFolderCleared(String folder, bool cleared) async {
  final raw = await _readMetaMap(folder) ?? <String, dynamic>{};
  if (cleared) {
    raw['cleared'] = true;
  } else {
    raw.remove('cleared');
  }
  final file = File(p.join(folder, albumFilmMetaName));
  await _writeFilmFile(file, jsonEncode(raw));
}

bool _sameVolume(String a, String b) {
  if (!Platform.isWindows) return true;
  String drive(String path) {
    final match = RegExp(r'^([A-Za-z]):').firstMatch(path);
    return match?.group(1)?.toUpperCase() ?? '';
  }

  final left = drive(a);
  final right = drive(b);
  if (left.isEmpty || right.isEmpty) return true;
  return left == right;
}

/// Windows denies a rename while a file inside the folder is open, and also
/// when the folder itself is marked read-only. Clear that flag and try once
/// more before giving up.
Future<void> _renameDirectory(Directory source, String destPath) async {
  Future<void> attempt() => source.rename(destPath);
  try {
    await attempt();
    return;
  } on FileSystemException {
    // Tried again below.
  }
  if (Platform.isWindows) {
    await Process.run('attrib', ['-r', source.path]);
  }
  try {
    await attempt();
    return;
  } on FileSystemException {
    await Future<void>.delayed(const Duration(milliseconds: 300));
  }
  try {
    await attempt();
  } on FileSystemException {
    throw FileSystemException(
      'Windows would not rename ${p.basename(source.path)}. '
      'Close any window that has this folder open, then try again.',
      source.path,
    );
  }
}

/// Box art for [name], the same pictures ApertureDiary uses for that stock.
String? albumFilmIconAsset(String name) =>
    albumFilmKindForFolder(name)?.iconAsset;

String _fold(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '');

/// Name and icon file, matching ApertureDiary's film boxes.
const List<(String, String)> _catalog = [
  ('Kodak Portra 160', 'portra-160'),
  ('Kodak Portra 400', 'portra-400'),
  ('Kodak Portra 800', 'portra-800'),
  ('Kodak Gold 200', 'gold-200'),
  ('Kodak Ultramax 400', 'ultramax-400'),
  ('Kodak Ektar 100', 'ektar-100'),
  ('CineStill 800T', 'cinestill-800t'),
  ('Fujifilm Pro 400H', 'fuji-pro-400h'),
  ('Fujifilm Superia X-TRA 400', 'fuji-superia-400'),
  ('Fujifilm 200', 'fuji-200'),
  ('Fujifilm 400', 'fuji-400'),
  ('Fujifilm Instax', 'fuji-instax-800'),
  ('Kodak Vision3 250D (5207)', 'kodak-vision3-250d'),
  ('Kodak Vision3 500T (5219)', 'kodak-vision3-500t'),
  ('Kodak Vision3 50D (5203)', 'kodak-vision3-50d'),
  ('Kodak Aerocolor IV (2460)', 'kodak-aerocolor-2460'),
  ('Kodak Tri-X 400', 'tri-x-400'),
  ('Kodak T-Max 100', 'tmax-100'),
  ('Kodak T-Max 400', 'tmax-400'),
  ('Ilford HP5 Plus', 'hp5-400'),
  ('Ilford Delta 100', 'delta-100'),
  ('Ilford Delta 400', 'delta-400'),
  ('Ilford FP4 Plus', 'fp4-125'),
  ('Fujifilm Neopan Acros 100 II', 'fuji-acros-100'),
  ('Kodak Ektachrome E100', 'ektachrome-100'),
  ('Kodak Ektachrome 100D (5294)', 'kodak-ektachrome-100d-5294'),
  ('Fujichrome Velvia 50', 'fuji-velvia-50'),
  ('Fujichrome Velvia 100', 'fuji-velvia-100'),
  ('Fujichrome Provia 100F', 'fuji-provia-100'),
];

/// The film box. [asset] is a package asset; without one, the name's initials.
class AlbumFilmIcon extends StatelessWidget {
  const AlbumFilmIcon({
    super.key,
    this.asset,
    required this.name,
    this.marked = false,
  });

  final String? asset;
  final String name;
  final bool marked;

  @override
  Widget build(BuildContext context) {
    final letters = name
        .split(RegExp(r'[^A-Za-z0-9]+'))
        .where((part) => part.isNotEmpty)
        .take(2)
        .map((part) => part[0].toUpperCase())
        .join();
    final fallback = ColoredBox(
      color: const Color(0xFF221C0A),
      child: Center(
        child: Text(
          letters.isEmpty ? '?' : letters,
          style: const TextStyle(
            color: Color(0xFFFFB300),
            fontWeight: FontWeight.w800,
          ),
        ),
      ),
    );
    return SizedBox.expand(
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: marked ? const Color(0xFFFFB300) : Colors.transparent,
            width: 2,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: asset == null
              ? fallback
              : Image.asset(
                  asset!,
                  package: 'image_album',
                  fit: BoxFit.cover,
                  width: double.infinity,
                  height: double.infinity,
                  errorBuilder: (_, _, _) => fallback,
                ),
        ),
      ),
    );
  }
}
