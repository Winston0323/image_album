import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Folder ApertureDiary uses for cameras, lenses, and films.
///
/// Kept in step with `ApertureDiary/lib/shared_gear_dir.dart`. Both apps read
/// and write `cameras.json`, `lenses.json`, and `films.json` here, so a body
/// added in one shows up in the other.
Directory albumSharedGearDirectory() {
  final appData = Platform.environment['APPDATA'];
  final root = appData != null && appData.isNotEmpty
      ? appData
      : Platform.environment['HOME'] ??
            Platform.environment['USERPROFILE'] ??
            '.';
  final folder = appData != null && appData.isNotEmpty
      ? p.join(root, 'ApertureDiary', 'shared')
      : p.join(root, '.aperture_diary', 'shared');
  return Directory(folder);
}

const albumCameraBrands = [
  'Hasselblad',
  'Leica',
  'Nikon',
  'Canon',
  'Fujifilm',
  'Pentax',
  'Rollei',
  'Mamiya',
  'Contax',
  'Other',
];

/// One camera body, stored as ApertureDiary's `cameras.json` object.
class AlbumSharedCamera {
  AlbumSharedCamera(Map<String, dynamic> raw)
    : map = Map<String, dynamic>.from(raw);

  final Map<String, dynamic> map;

  String get id => map['id'] as String? ?? '';
  String get brand => map['brand'] as String? ?? 'Other';
  String get name => map['name'] as String? ?? '';
  String get formatId => map['formatId'] as String? ?? '36x24';
  String? get mount => _text(map['mount']);
  bool get interchangeableLenses => map['interchangeableLenses'] == true;
  String? get notes => _text(map['notes']);

  String get label => '$brand $name'.trim();

  String get summary {
    final parts = <String>[albumFrameLabel(formatId)];
    if (interchangeableLenses) {
      final m = mount;
      parts.add(m == null ? 'Interchangeable' : 'Mount $m');
    } else {
      parts.add('Fixed lens');
    }
    return parts.join('  ·  ');
  }
}

/// One lens, stored as ApertureDiary's `lenses.json` object.
class AlbumSharedLens {
  AlbumSharedLens(Map<String, dynamic> raw)
    : map = Map<String, dynamic>.from(raw);

  final Map<String, dynamic> map;

  String get id => map['id'] as String? ?? '';
  String get brand => map['brand'] as String? ?? 'Other';
  String get name => map['name'] as String? ?? '';
  String? get mount => _text(map['mount']);
  double? get minFocalMm => _num(map['minFocalMm']);
  double? get maxFocalMm => _num(map['maxFocalMm']);
  double? get maxAperture => _num(map['maxAperture']);
  double? get minAperture => _num(map['minAperture']);

  String get label => '$brand $name'.trim();

  String get summary {
    final min = minFocalMm;
    final max = maxFocalMm;
    final focal = min == null
        ? ''
        : (max != null && (max - min).abs() > 0.5
              ? '${min.round()}–${max.round()} mm'
              : '${min.round()} mm');
    final parts = <String>[if (focal.isNotEmpty) focal, ?mount];
    return parts.join('  ·  ');
  }
}

/// One film roll, stored as ApertureDiary's `films.json` object.
class AlbumSharedFilm {
  AlbumSharedFilm(Map<String, dynamic> raw)
    : map = Map<String, dynamic>.from(raw);

  final Map<String, dynamic> map;

  String get id => map['id'] as String? ?? '';
  String get name => map['name'] as String? ?? '';
  String get type => map['type'] as String? ?? '135';
  int get iso => _num(map['iso'])?.round() ?? 100;
  String get frameFormat => map['frameFormat'] as String? ?? '36x24';
  String? get cameraId => _text(map['cameraId']);
  String? get cameraLabel => _text(map['cameraLabel']);
  String? get lensId => _text(map['lensId']);
  String? get lensLabel => _text(map['lensLabel']);

  String get summary {
    final parts = <String>[
      type,
      'ISO $iso',
      albumFrameLabel(frameFormat),
      ?cameraLabel,
      ?lensLabel,
    ];
    return parts.join('  ·  ');
  }
}

/// `36x24` reads as 135, `645` and `6x6` as 120.
String albumFrameLabel(String id) => switch (id) {
  '36x24' => '135',
  '645' => '645',
  '6x6' => '6×6',
  'instax-mini' => 'Instax Mini',
  'instax-sq' => 'Instax SQ',
  _ => id,
};

String albumFilmBrandName(String filmName) {
  final hay = filmName.toLowerCase();
  if (hay.contains('kodak') ||
      hay.contains('portra') ||
      hay.contains('tri-x') ||
      hay.contains('tmax') ||
      hay.contains('ektar') ||
      hay.contains('ektachrome')) {
    return 'kodak';
  }
  if (hay.contains('fuji') ||
      hay.contains('velvia') ||
      hay.contains('provia') ||
      hay.contains('acros') ||
      hay.contains('instax')) {
    return 'fujifilm';
  }
  if (hay.contains('ilford') || hay.contains('hp5') || hay.contains('delta')) {
    return 'ilford';
  }
  if (hay.contains('cinestill')) return 'cinestill';
  return 'other';
}

Future<List<AlbumSharedCamera>> albumLoadCameras({Directory? directory}) async {
  final rows = await _loadList('cameras.json', directory);
  return [
    for (final row in rows)
      if ((row['id'] as String?)?.isNotEmpty == true &&
          (row['name'] as String?)?.isNotEmpty == true)
        AlbumSharedCamera(row),
  ];
}

Future<void> albumSaveCameras(
  List<AlbumSharedCamera> cameras, {
  Directory? directory,
}) => _saveList('cameras.json', cameras.map((c) => c.map).toList(), directory);

Future<List<AlbumSharedLens>> albumLoadLenses({Directory? directory}) async {
  final rows = await _loadList('lenses.json', directory);
  return [
    for (final row in rows)
      if ((row['id'] as String?)?.isNotEmpty == true &&
          (row['name'] as String?)?.isNotEmpty == true)
        AlbumSharedLens(row),
  ];
}

Future<void> albumSaveLenses(
  List<AlbumSharedLens> lenses, {
  Directory? directory,
}) => _saveList('lenses.json', lenses.map((l) => l.map).toList(), directory);

Future<List<AlbumSharedFilm>> albumLoadFilms({Directory? directory}) async {
  final rows = await _loadList('films.json', directory);
  return [
    for (final row in rows)
      if ((row['id'] as String?)?.isNotEmpty == true &&
          (row['name'] as String?)?.isNotEmpty == true)
        AlbumSharedFilm(row),
  ];
}

Future<void> albumSaveFilms(
  List<AlbumSharedFilm> films, {
  Directory? directory,
}) => _saveList('films.json', films.map((f) => f.map).toList(), directory);

Map<String, dynamic> albumNewCamera({
  required String brand,
  required String name,
  required String formatId,
  required bool interchangeable,
  String? mount,
  String? notes,
}) {
  return {
    'id': 'cam-${DateTime.now().microsecondsSinceEpoch}',
    'brand': brand,
    'name': name,
    'interchangeableLenses': interchangeable,
    'changeableBack': false,
    'formatId': formatId,
    'mount': mount,
    'fixedFocalMm': null,
    'fixedMaxAperture': null,
    'fixedMinAperture': null,
    'fastestShutter': 1 / 500,
    'slowestShutter': 1.0,
    'hasBulb': true,
    'notes': notes,
    'addedAt': DateTime.now().toIso8601String(),
  };
}

Map<String, dynamic> albumNewLens({
  required String brand,
  required String name,
  required double minFocalMm,
  double? maxFocalMm,
  double? maxAperture,
  double? minAperture,
  String? mount,
  String? notes,
}) {
  return {
    'id': 'lens-${DateTime.now().microsecondsSinceEpoch}',
    'brand': brand,
    'name': name,
    'minFocalMm': minFocalMm,
    'maxFocalMm': maxFocalMm,
    'maxAperture': maxAperture,
    'minAperture': minAperture,
    'mount': mount,
    'cameraIds': <String>[],
    'notes': notes,
    'addedAt': DateTime.now().toIso8601String(),
  };
}

Map<String, dynamic> albumNewFilm({
  required String name,
  required String type,
  required int iso,
  required String frameFormat,
  String? cameraId,
  String? cameraLabel,
  String? lensId,
  String? lensLabel,
}) {
  return {
    'id': 'roll-${DateTime.now().microsecondsSinceEpoch}',
    'name': name,
    'type': type,
    'frameFormat': frameFormat,
    'iso': iso,
    'brand': albumFilmBrandName(name),
    'balance': 'daylight',
    'isCustom': true,
    'meterDaylight85': false,
    'addedAt': DateTime.now().toIso8601String(),
    'cameraId': ?cameraId,
    'cameraLabel': ?cameraLabel,
    'lensId': ?lensId,
    'lensLabel': ?lensLabel,
  };
}

String? _text(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}

double? _num(Object? value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

Future<List<Map<String, dynamic>>> _loadList(
  String name,
  Directory? directory,
) async {
  try {
    final dir = directory ?? albumSharedGearDirectory();
    if (directory == null) await _migrateSharedGear(dir);
    final file = File(p.join(dir.path, name));
    if (!await file.exists()) return const [];
    final data = jsonDecode(await file.readAsString());
    if (data is! List) return const [];
    return [
      for (final item in data)
        if (item is Map) Map<String, dynamic>.from(item),
    ];
  } on Object {
    return const [];
  }
}

Future<void> _saveList(
  String name,
  List<Map<String, dynamic>> rows,
  Directory? directory,
) async {
  final dir = directory ?? albumSharedGearDirectory();
  if (directory == null) await _migrateSharedGear(dir);
  if (!await dir.exists()) await dir.create(recursive: true);
  final file = File(p.join(dir.path, name));
  await file.writeAsString(jsonEncode(rows));
}

/// Copies cameras, lenses, and films out of ApertureDiary's old private
/// folder the first time the shared folder is used.
Future<void> _migrateSharedGear(Directory shared) async {
  try {
    if (!await shared.exists()) await shared.create(recursive: true);
    final marker = File(p.join(shared.path, '.migrated'));
    if (await marker.exists()) return;
    final appData = Platform.environment['APPDATA'];
    if (appData != null && appData.isNotEmpty) {
      final legacy = Directory(
        p.join(appData, 'com.example', 'aperture_diary'),
      );
      const names = [
        'cameras.json',
        'lenses.json',
        'backs.json',
        'lens_mounts.json',
        'camera_brands.json',
        'films.json',
      ];
      for (final name in names) {
        final source = File(p.join(legacy.path, name));
        final dest = File(p.join(shared.path, name));
        if (!await source.exists() || p.equals(source.path, dest.path)) {
          continue;
        }
        if (!await dest.exists()) {
          await source.copy(dest.path);
          continue;
        }
        final sharedRaw = jsonDecode(await dest.readAsString());
        final legacyRaw = jsonDecode(await source.readAsString());
        if (sharedRaw is! List || legacyRaw is! List) continue;
        final ids = <String>{
          for (final item in sharedRaw)
            if (item is Map && item['id'] is String) item['id'] as String,
        };
        await dest.writeAsString(
          jsonEncode([
            ...sharedRaw,
            for (final item in legacyRaw)
              if (item is Map &&
                  item['id'] is String &&
                  !ids.contains(item['id']))
                item,
          ]),
        );
      }
    }
    await marker.writeAsString('1');
  } on Object {
    // The lists still load from whatever is already in the shared folder.
  }
}
