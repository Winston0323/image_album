import 'dart:io';
import 'dart:isolate';

import 'package:exif/exif.dart';
import 'package:path/path.dart' as p;

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
      AlbumDaySection(
        day: day,
        photos: byDay[day]!..sort(_newestFirst),
      ),
  ];
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
/// [onProgress] is called with the photos found so far, newest first, as each
/// batch of files is dated. The album uses that to put tiles on screen before
/// the rest of the folder has been read.
///
/// Listing and date reading run on a background isolate, so the UI isolate
/// only applies the batches. [token] cancels that work when the folder changes.
Future<List<AlbumPhoto>> loadAlbumPhotos(
  String path, {
  bool recursive = false,
  void Function(List<AlbumPhoto> photos)? onProgress,
  AlbumLoadToken? token,
}) async {
  final port = ReceivePort();
  final isolate = await Isolate.spawn(
    _scanAlbum,
    (path, recursive, port.sendPort),
    debugName: 'image_album_scan',
  );
  token?._attach(isolate);
  isolate.addOnExitListener(port.sendPort, response: const ['exit']);

  final photos = <AlbumPhoto>[];
  Object? failure;
  try {
    await for (final message in port) {
      if (message is! List || message.isEmpty) continue;
      final kind = message.first;
      if (kind == 'batch') {
        for (var i = 1; i + 1 < message.length; i += 2) {
          photos.add(
            AlbumPhoto(
              file: File(message[i] as String),
              takenAt: DateTime.fromMicrosecondsSinceEpoch(message[i + 1] as int),
            ),
          );
        }
        photos.sort(_newestFirst);
        onProgress?.call(List<AlbumPhoto>.of(photos));
        continue;
      }
      if (kind == 'error') {
        failure = message.length > 1
            ? message[1]
            : 'Could not read the album';
      }
      break;
    }
  } finally {
    port.close();
  }
  if (failure != null) throw Exception(failure);
  return photos;
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

/// Entry point for the scan isolate. Messages are lists:
/// `['batch', path, microseconds, ...]`, `['done']`, `['error', message]`,
/// or `['exit']` when the isolate is killed.
Future<void> _scanAlbum((String, bool, SendPort) message) async {
  final (path, recursive, send) = message;
  try {
    final dir = Directory(path);
    if (!await dir.exists()) {
      send.send(const ['done']);
      return;
    }

    final pending = <File>[];
    Future<void> publish() async {
      if (pending.isEmpty) return;
      final batch = List<File>.of(pending);
      pending.clear();
      final found = await Future.wait(batch.map(_photoFromFile));
      final payload = <Object?>['batch'];
      for (final photo in found) {
        payload
          ..add(photo.file.path)
          ..add(photo.takenAt.microsecondsSinceEpoch);
      }
      send.send(payload);
    }

    await for (final entity in dir.list(
      recursive: recursive,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      final extension = p.extension(entity.path).toLowerCase();
      if (!albumImageExtensions.contains(extension)) continue;
      pending.add(entity);
      if (pending.length >= 8) await publish();
    }
    await publish();
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

Future<AlbumPhoto> _photoFromFile(File file) async {
  final modified = await file.lastModified();
  return AlbumPhoto(file: file, takenAt: await _captureDate(file) ?? modified);
}

/// Capture time written in the image, or null when the file has none.
Future<DateTime?> _captureDate(File file) async {
  try {
    final tags = await readExifFromFile(file, details: false);
    return _exifDate(tags['EXIF DateTimeOriginal']) ??
        _exifDate(tags['EXIF DateTimeDigitized']) ??
        _exifDate(tags['Image DateTime']);
  } catch (_) {
    return null;
  }
}

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
