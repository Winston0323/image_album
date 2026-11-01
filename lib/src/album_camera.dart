import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'album_photo.dart';

/// Which files of a shot an import copies.
enum AlbumImportKind {
  /// The developed picture and the raw, whichever the shot has.
  both,

  /// The raw only. A shot with no raw is left on the card.
  raw,

  /// The developed picture only (JPEG, or HEIC). A shot with none is left.
  jpeg,
}

/// Whether a file is the developed picture, the raw, or something else.
enum AlbumCameraFileKind { jpeg, raw, other }

/// The developed picture a camera writes beside its raw.
const Set<String> _pictureExtensions = {'.jpg', '.jpeg', '.heic', '.heif'};

/// Camera raws. ARW and FFF are the ones the album can draw; the rest are
/// still grouped and copied, and shown from their picture when they have one.
const Set<String> _rawExtensions = {
  '.arw',
  '.fff',
  '.cr2',
  '.cr3',
  '.nef',
  '.nrw',
  '.dng',
  '.raf',
  '.orf',
  '.rw2',
  '.pef',
  '.srw',
};

AlbumCameraFileKind albumCameraFileKind(String path) {
  final extension = p.extension(path).toLowerCase();
  if (_pictureExtensions.contains(extension)) return AlbumCameraFileKind.jpeg;
  if (_rawExtensions.contains(extension)) return AlbumCameraFileKind.raw;
  return AlbumCameraFileKind.other;
}

/// One press of the shutter: the developed picture, the raw, or both. The two
/// can sit on different cards, so they are matched by file name.
class AlbumCameraShot {
  AlbumCameraShot(List<AlbumPhoto> files)
    : files = List.unmodifiable(_ordered(files));

  /// The picture first, then the raw, then anything else.
  final List<AlbumPhoto> files;

  /// The name the files share, without the extension.
  String get name => p.basenameWithoutExtension(files.first.file.path);

  AlbumPhoto? get picture => _ofKind(AlbumCameraFileKind.jpeg);

  AlbumPhoto? get raw => _ofKind(AlbumCameraFileKind.raw);

  /// What the grid and the preview show until another file of the shot is
  /// asked for: the picture, which is quick to draw, and the raw otherwise.
  AlbumPhoto get display => picture ?? files.first;

  bool get paired => picture != null && raw != null;

  /// The files [kind] copies. Empty when the shot has none of that kind.
  List<AlbumPhoto> filesFor(AlbumImportKind kind) => switch (kind) {
    AlbumImportKind.both => files,
    AlbumImportKind.raw => [?raw],
    AlbumImportKind.jpeg => [?picture],
  };

  AlbumPhoto? _ofKind(AlbumCameraFileKind kind) {
    for (final file in files) {
      if (albumCameraFileKind(file.file.path) == kind) return file;
    }
    return null;
  }

  static List<AlbumPhoto> _ordered(List<AlbumPhoto> files) {
    final copy = [...files];
    int rank(AlbumPhoto photo) =>
        switch (albumCameraFileKind(photo.file.path)) {
          AlbumCameraFileKind.jpeg => 0,
          AlbumCameraFileKind.raw => 1,
          AlbumCameraFileKind.other => 2,
        };
    copy.sort((a, b) => rank(a).compareTo(rank(b)));
    return copy;
  }
}

/// Groups [photos] into shots by file name, ignoring the extension and the
/// card a file is on. Two pictures with the same name stay separate shots, and
/// so do two raws: a shot holds one of each.
List<AlbumCameraShot> albumGroupCameraShots(List<AlbumPhoto> photos) {
  final byName = <String, List<AlbumPhoto>>{};
  final order = <String>[];
  final alone = <AlbumPhoto>[];

  for (final photo in photos) {
    final name = p.basenameWithoutExtension(photo.file.path).toLowerCase();
    final kind = albumCameraFileKind(photo.file.path);
    final group = byName[name];
    final taken =
        group != null &&
        group.any((other) => albumCameraFileKind(other.file.path) == kind);
    if (taken) {
      alone.add(photo);
      continue;
    }
    if (group == null) order.add(name);
    byName.putIfAbsent(name, () => []).add(photo);
  }

  return [
    for (final name in order) AlbumCameraShot(byName[name]!),
    for (final photo in alone) AlbumCameraShot([photo]),
  ];
}

/// [raw] made safe as a folder name: illegal characters dropped, and no
/// leading or trailing dots or spaces. Empty when nothing usable is left.
String albumFolderName(String raw) {
  var text = raw.trim();
  text = text.replaceAll(RegExp(r'[\\/:*?"<>|]'), ' ');
  text = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  text = text.replaceAll(RegExp(r'^[. ]+'), '');
  text = text.replaceAll(RegExp(r'[. ]+$'), '');
  if (_reservedNames.contains(text.toUpperCase())) return '';
  return text;
}

/// Names Windows refuses for a file or a folder.
const _reservedNames = {
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};

/// Removable drives, as `D:\`. Fixed disks are left out; a folder on one is
/// added with "Choose a folder". Windows only; anywhere else, none.
///
/// The drive type is the one Windows already recorded. The card itself is not
/// opened, so a card that is asleep does not hold the list up.
Future<List<String>> albumCameraCards() async {
  if (!Platform.isWindows) return const [];
  final result = await Process.run('powershell.exe', [
    '-NoProfile',
    '-NonInteractive',
    '-Command',
    '[System.IO.DriveInfo]::GetDrives() | '
        'Where-Object { \$_.DriveType -eq \'Removable\' } | '
        'ForEach-Object { \$_.Name }',
  ]);
  if (result.exitCode != 0) return const [];
  return [
    for (final line in '${result.stdout}'.split(RegExp(r'\r?\n')))
      if (line.trim().isNotEmpty) _driveRoot(line),
  ];
}

/// A removable drive that has a `DCIM` folder. [name] is the card's volume
/// name, empty when the card has none.
class AlbumCameraDrive {
  const AlbumCameraDrive({required this.root, this.name = ''});

  /// `D:\`, or a folder a test points at.
  final String root;

  final String name;
}

/// [root] when it contains `DCIM`, with the card's name. Null when there is
/// no `DCIM`, or the card does not answer within [probe]. A card that does
/// not answer is left out, and is not waited on before the cards that
/// already answered are shown.
Future<AlbumCameraDrive?> albumDriveIfDcim(
  String root, {
  Duration probe = albumCameraProbe,
}) async {
  final dcim = p.normalize(p.join(root, 'DCIM'));
  try {
    if (!await Directory(dcim).exists().timeout(probe)) return null;
  } on TimeoutException {
    return null;
  } on FileSystemException {
    return null;
  }
  return AlbumCameraDrive(
    root: p.normalize(root),
    name: await _volumeLabel(root),
  );
}

/// The volume name of a drive such as `D:\`. Empty for anything else, and
/// when the card has no name. The card is only asked after [albumDriveIfDcim]
/// has found its `DCIM`, so a drive with none is never opened for this.
Future<String> _volumeLabel(String root) async {
  if (!Platform.isWindows) return '';
  final letter = RegExp(r'^[A-Za-z]:').stringMatch(root.trim());
  if (letter == null) return '';
  try {
    final result = await Process.run('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "([System.IO.DriveInfo]::new('$letter\\')).VolumeLabel",
    ]).timeout(const Duration(seconds: 2));
    if (result.exitCode != 0) return '';
    return '${result.stdout}'.trim();
  } on TimeoutException {
    return '';
  }
}

/// A folder the user pointed at, through the system folder dialog. Null when
/// cancelled, or when the dialog is not available. Windows only.
Future<String?> albumPickFolder() async {
  if (!Platform.isWindows) return null;
  final result = await Process.run('powershell.exe', [
    '-STA',
    '-NoProfile',
    '-Command',
    r'Add-Type -AssemblyName System.Windows.Forms; '
        r'$dialog = New-Object System.Windows.Forms.FolderBrowserDialog; '
        r"$dialog.Description = 'Choose a folder of photos'; "
        r'if ($dialog.ShowDialog() -eq '
        r'[System.Windows.Forms.DialogResult]::OK) { $dialog.SelectedPath }',
  ]);
  final path = '${result.stdout}'.trim();
  if (result.exitCode != 0 || path.isEmpty) return null;
  return path;
}

/// A short name for a card or a chosen folder: `D:` for a drive and its
/// `DCIM` folders, and the folder's own name otherwise.
String albumCardLabel(String path) {
  final parts = p
      .split(p.normalize(path))
      .where((part) => part.isNotEmpty)
      .toList();
  final dcim = parts.indexWhere((part) => part.toUpperCase() == 'DCIM');
  if (dcim > 0) return _volumeName(parts[dcim - 1]);
  if (parts.isEmpty) return path;
  return _volumeName(parts.last);
}

String _volumeName(String part) {
  final letter = part.replaceAll(RegExp(r'[\\/:]'), '');
  if (letter.length == 1 && part != letter) return '$letter:';
  return part;
}

/// The shot folders [path] refers to. A `DCIM\100MSDCF` folder is itself. A
/// drive, or a folder with a `DCIM` inside it, yields those shot folders. A
/// folder of photos is itself. Empty when nothing of either kind is there.
Future<List<String>> albumImportTargets(
  String path, {
  Duration probe = albumCameraProbe,
}) async {
  final normalized = p.normalize(path);
  final name = p.basename(normalized);
  if (_shotFolder.hasMatch(name)) return [normalized];
  if (name.toUpperCase() == 'DCIM') return _childShotFolders(normalized, probe);

  final targets = <String>[];
  if (await _containsImages(normalized, probe)) targets.add(normalized);
  final found = await albumCameraFolders([normalized], probe: probe);
  for (final folder in found.reading) {
    if (!targets.contains(folder)) targets.add(folder);
  }
  return targets;
}

Future<List<String>> _childShotFolders(String dcim, Duration probe) async {
  final found = <String>[];
  try {
    final listing = Directory(dcim)
        .list(followLinks: false)
        .timeout(probe, onTimeout: (sink) => sink.close());
    await for (final entity in listing) {
      if (entity is! Directory) continue;
      if (!_shotFolder.hasMatch(p.basename(entity.path))) continue;
      found.add(p.normalize(entity.path));
    }
  } on Object {
    // No such folder, or it did not answer.
  }
  found.sort();
  return found;
}

/// Whether [folder] holds an image file directly inside it.
Future<bool> _containsImages(String folder, Duration probe) async {
  try {
    final listing = Directory(folder)
        .list(followLinks: false)
        .timeout(probe, onTimeout: (sink) => sink.close());
    await for (final entity in listing) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (_importExtensions.contains(extension)) return true;
    }
  } on Object {
    // Missing, or it did not answer.
  }
  return false;
}

String _driveRoot(String id) {
  final trimmed = id.trim();
  if (trimmed.endsWith('\\') || trimmed.endsWith('/')) return trimmed;
  return '$trimmed\\';
}

/// Where the photos on the cards are, and which cards never answered.
class AlbumCameraFolders {
  const AlbumCameraFolders({required this.reading, required this.silent});

  /// `DCIM\100MSDCF` folders that are there.
  final List<String> reading;

  /// `DCIM\100MSDCF` paths that were asked and did not answer in time.
  final List<String> silent;
}

/// How long a card is given to answer. A card that is asleep or stuck must
/// not hold up the one that is ready.
const Duration albumCameraProbe = Duration(seconds: 8);

/// A camera's folder of shots under `DCIM`, such as `100MSDCF`.
final _shotFolder = RegExp(r'^\d{3}[A-Za-z0-9]{5}$');

/// The folder of images on each card. A camera keeps its shots in a folder
/// like `DCIM\100MSDCF`, not in `DCIM` itself, so that folder is what is
/// read. A card with none is left out, and one that does not answer in time
/// is reported in [AlbumCameraFolders.silent] so the cards that did answer
/// are still shown.
///
/// [onPath] is called with each folder as it is tried. [onFolder] is called
/// the moment a shot folder answers, so that card can be listed while another
/// card is still being given its chance.
Future<AlbumCameraFolders> albumCameraFolders(
  List<String> cards, {
  Duration probe = albumCameraProbe,
  void Function(String path)? onPath,
  void Function(String folder)? onFolder,
}) async {
  final reading = <String>[];
  final silent = <String>[];
  await Future.wait([
    for (final card in cards)
      _shotFolders(card, probe, onPath, onFolder, reading, silent),
  ]);
  reading.sort();
  silent.sort();
  return AlbumCameraFolders(reading: reading, silent: silent);
}

Future<void> _shotFolders(
  String card,
  Duration probe,
  void Function(String path)? onPath,
  void Function(String folder)? onFolder,
  List<String> reading,
  List<String> silent,
) async {
  final dcim = p.normalize(p.join(card, 'DCIM'));
  final reference = p.normalize(p.join(dcim, '100MSDCF'));
  onPath?.call(reference);
  final found = <String>[];
  var answered = true;
  try {
    if (await Directory(reference).exists().timeout(probe)) {
      found.add(reference);
      onFolder?.call(reference);
    }
  } on TimeoutException {
    silent.add(reference);
    answered = false;
  } on FileSystemException {
    // The card has no such folder.
  }

  // A card that did not answer is not asked again. Listing its DCIM would
  // only sit there the same way.
  if (!answered) {
    reading.addAll(found);
    return;
  }

  // Other shot folders beside 100MSDCF, such as 101MSDCF.
  try {
    final listing = Directory(dcim)
        .list(followLinks: false)
        .timeout(probe, onTimeout: (sink) => sink.close());
    await for (final entity in listing) {
      if (entity is! Directory) continue;
      if (!_shotFolder.hasMatch(p.basename(entity.path))) continue;
      final path = p.normalize(entity.path);
      if (found.contains(path)) continue;
      found.add(path);
      onFolder?.call(path);
    }
  } on Object {
    // No DCIM, or it did not answer. The reference folder still stands.
  }
  reading.addAll(found);
}

/// Extensions worth offering to import: the album's own, plus camera raws.
Set<String> get _importExtensions => {
  ...albumImageExtensions,
  ..._pictureExtensions,
  ..._rawExtensions,
};

/// The image files in one shot folder, dated by the time the camera wrote
/// them. Contents are not read. [onProgress] is given this folder's files so
/// far: the first file at once, then every 24. It is awaited, so the grid can
/// paint a batch before the next files are listed.
Future<List<AlbumPhoto>> albumListCameraFiles(
  String folder, {
  FutureOr<void> Function(List<AlbumPhoto> files)? onProgress,
}) async {
  final photos = <AlbumPhoto>[];
  var since = 0;
  try {
    await for (final entity in Directory(folder).list(followLinks: false)) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (!_importExtensions.contains(extension)) continue;
      DateTime taken;
      try {
        taken = (await entity.stat()).modified;
      } on FileSystemException {
        taken = DateTime.fromMillisecondsSinceEpoch(0);
      }
      photos.add(AlbumPhoto(file: File(entity.path), takenAt: taken));
      since++;
      if (photos.length == 1 || since >= 24) {
        since = 0;
        await onProgress?.call(List<AlbumPhoto>.unmodifiable(photos));
      }
    }
  } on FileSystemException {
    return photos;
  }
  return photos;
}

/// The shots on [folders], pictures and raws with the same name as one shot
/// even when they were found in different folders.
///
/// Files are listed and dated by the time the camera wrote them. Their
/// contents are not read, so the grid can appear while a card is still being
/// listed. [onProgress] is given the shots found so far.
Future<List<AlbumCameraShot>> albumLoadCameraShots(
  List<String> folders, {
  void Function(List<AlbumCameraShot> shots)? onProgress,
  void Function(String path)? onPath,
}) async {
  final photos = <AlbumPhoto>[];
  for (final folder in folders) {
    onPath?.call(folder);
    final found = await albumListCameraFiles(
      folder,
      onProgress: onProgress == null
          ? null
          : (files) => onProgress(albumGroupCameraShots([...photos, ...files])),
    );
    photos.addAll(found);
    onProgress?.call(albumGroupCameraShots(photos));
  }
  return albumGroupCameraShots(photos);
}

/// What [albumCopyShots] did.
class AlbumImportResult {
  const AlbumImportResult({
    required this.copied,
    required this.deleted,
    required this.skipped,
    required this.stopped,
    required this.errors,
  });

  /// Files copied.
  final int copied;

  /// Files removed from the card after a copy.
  final int deleted;

  /// Shots that had nothing of the kind asked for.
  final int skipped;

  /// Whether the copy was stopped before every shot.
  final bool stopped;

  final List<String> errors;
}

/// Copies the files [kind] chooses from [shots] into [destination], keeping
/// each file's name. A file already there under that name is left alone and
/// reported, and its original is not deleted.
///
/// With [deleteAfter], an original is removed only once its copy is in place
/// and the same size. [cancelled] is checked between files.
Future<AlbumImportResult> albumCopyShots({
  required List<AlbumCameraShot> shots,
  required AlbumImportKind kind,
  required String destination,
  bool deleteAfter = false,
  bool Function()? cancelled,
  void Function(int done, int total)? onProgress,
}) async {
  await Directory(destination).create(recursive: true);

  final jobs = <AlbumPhoto>[];
  var skipped = 0;
  for (final shot in shots) {
    final files = shot.filesFor(kind);
    if (files.isEmpty) {
      skipped++;
      continue;
    }
    jobs.addAll(files);
  }

  final errors = <String>[];
  var copied = 0;
  var deleted = 0;
  var stopped = false;
  for (var i = 0; i < jobs.length; i++) {
    if (cancelled?.call() ?? false) {
      stopped = true;
      break;
    }
    final file = jobs[i];
    final source = file.file;
    final target = File(p.join(destination, file.fileName));
    try {
      if (await target.exists()) {
        errors.add('${file.fileName} is already in the folder');
        onProgress?.call(i + 1, jobs.length);
        continue;
      }
      await source.copy(target.path);
      try {
        await target.setLastModified(await source.lastModified());
      } on FileSystemException {
        // The copy is in place; the date inside the file is what is shown.
      }
      final same = await target.length() == await source.length();
      if (!same) {
        errors.add('${file.fileName} was copied short');
        onProgress?.call(i + 1, jobs.length);
        continue;
      }
      copied++;
      if (deleteAfter) {
        try {
          await source.delete();
          deleted++;
        } on FileSystemException catch (error) {
          errors.add(
            '${file.fileName} was copied, and could not be removed '
            'from the card: ${error.osError?.message ?? error.message}',
          );
        }
      }
    } on FileSystemException catch (error) {
      errors.add(
        '${file.fileName}: ${error.osError?.message ?? error.message}',
      );
    }
    onProgress?.call(i + 1, jobs.length);
  }
  return AlbumImportResult(
    copied: copied,
    deleted: deleted,
    skipped: skipped,
    stopped: stopped,
    errors: errors,
  );
}
