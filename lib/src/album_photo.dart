import 'dart:io';

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

  /// When the shot was taken. The directory scan uses the file's modification
  /// time, which is the capture date when the caller stamped it on the way in.
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
        photos: byDay[day]!..sort((a, b) => b.takenAt.compareTo(a.takenAt)),
      ),
  ];
}

/// Image files sitting directly in [path], newest first.
///
/// A missing directory is an empty album. Subfolders are not walked, and
/// anything whose extension is not in [albumImageExtensions] is skipped, so a
/// leftover partial download never shows up as a tile.
Future<List<AlbumPhoto>> loadAlbumPhotos(String path) async {
  final dir = Directory(path);
  if (!await dir.exists()) return const [];

  final photos = <AlbumPhoto>[];
  await for (final entity in dir.list(followLinks: false)) {
    if (entity is! File) continue;
    final extension = p.extension(entity.path).toLowerCase();
    if (!albumImageExtensions.contains(extension)) continue;
    photos.add(
      AlbumPhoto(
        file: entity,
        takenAt: await entity.lastModified(),
      ),
    );
  }
  photos.sort((a, b) => b.takenAt.compareTo(a.takenAt));
  return photos;
}
