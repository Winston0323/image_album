import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import 'album_cache.dart';

/// How a photo is shown. Nothing here is written into the file.
///
/// A fixed frame, the same shape as the picture, stays still. [degrees] turns
/// the picture behind that frame and [panX]/[panY] slide it, as fractions of
/// the frame. Whatever falls outside the frame is the crop.
@immutable
class AlbumViewAdjustment {
  const AlbumViewAdjustment({this.degrees = 0, this.panX = 0, this.panY = 0});

  final double degrees;

  /// Slide of the picture under the frame, as a fraction of the frame size.
  final double panX;
  final double panY;

  Offset get pan => Offset(panX, panY);

  bool get isOriginal =>
      degrees == 0 && panX.abs() < 0.001 && panY.abs() < 0.001;

  AlbumViewAdjustment copyWith({double? degrees, double? panX, double? panY}) {
    return AlbumViewAdjustment(
      degrees: degrees ?? this.degrees,
      panX: panX ?? this.panX,
      panY: panY ?? this.panY,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is AlbumViewAdjustment &&
      other.degrees == degrees &&
      other.panX == panX &&
      other.panY == panY;

  @override
  int get hashCode => Object.hash(degrees, panX, panY);
}

/// How much to enlarge a picture of [imageAspect] (width / height) after
/// turning it by [degrees], so it still covers a frame of the same shape.
double albumCoverScale({required double degrees, required double imageAspect}) {
  if (!imageAspect.isFinite || imageAspect <= 0) return 1;
  final radians = degrees * math.pi / 180;
  final cosine = math.cos(radians);
  final sine = math.sin(radians);
  final halfW = imageAspect / 2;
  final halfH = 0.5;
  final corners = <(double, double)>[
    (halfW, halfH),
    (halfW, -halfH),
    (-halfW, halfH),
    (-halfW, -halfH),
  ];
  var scale = 1.0;
  for (final (fx, fy) in corners) {
    // Undo the turn. Every corner of the frame has to land on the picture,
    // otherwise turning it would show empty corners.
    final x = fx * cosine + fy * sine;
    final y = -fx * sine + fy * cosine;
    if (halfW > 0) scale = math.max(scale, x.abs() / halfW);
    if (halfH > 0) scale = math.max(scale, y.abs() / halfH);
  }
  return scale.isFinite && scale > 0 ? scale : 1;
}

/// Pulls [pan] back until the fixed frame stays covered by the turned picture.
Offset albumClampPan({
  required double degrees,
  required double imageAspect,
  required Offset pan,
}) {
  if (!pan.dx.isFinite || !pan.dy.isFinite) return Offset.zero;
  if (_frameCovered(degrees, imageAspect, pan)) return pan;
  var current = pan;
  for (var step = 0; step < 24; step++) {
    current *= 0.75;
    if (_frameCovered(degrees, imageAspect, current)) return current;
  }
  return Offset.zero;
}

bool _frameCovered(double degrees, double imageAspect, Offset pan) {
  final scale = albumCoverScale(degrees: degrees, imageAspect: imageAspect);
  final radians = degrees * math.pi / 180;
  final cosine = math.cos(radians);
  final sine = math.sin(radians);
  final halfW = imageAspect / 2;
  final halfH = 0.5;
  final corners = [
    Offset(-halfW, -halfH),
    Offset(halfW, -halfH),
    Offset(halfW, halfH),
    Offset(-halfW, halfH),
  ];
  for (final corner in corners) {
    final qx = (corner.dx - pan.dx * imageAspect) / scale;
    final qy = (corner.dy - pan.dy) / scale;
    final x = qx * cosine + qy * sine;
    final y = -qx * sine + qy * cosine;
    if (x.abs() > halfW + 1e-4 || y.abs() > halfH + 1e-4) return false;
  }
  return true;
}

/// Turns [degrees] into the same rotation in the range (-180, 180].
double albumNormalizeDegrees(double degrees) {
  if (!degrees.isFinite) return 0;
  var wrapped = degrees % 360;
  if (wrapped > 180) wrapped -= 360;
  if (wrapped <= -180) wrapped += 360;
  final rounded = (wrapped * 10).round() / 10;
  if (rounded == -180) return 180;
  return rounded == 0 ? 0 : rounded;
}

/// Keeps [crop] inside the picture and at least 5% of it on each side.
/// Saved crop and rotation for [file]. The original when none was saved.
///
/// This is not read from the photo. The file and its properties are never
/// consulted or changed.
/// Every saved view adjustment, keyed by the photo's absolute path.
Future<Map<String, AlbumViewAdjustment>> albumViewAdjustments({
  Directory? store,
}) async {
  final saved = await _read(store);
  return Map.unmodifiable(saved);
}

Future<AlbumViewAdjustment> albumViewAdjustment(
  File file, {
  Directory? store,
}) async {
  final saved = await _read(store);
  return saved[_key(file)] ?? const AlbumViewAdjustment();
}

/// Remembers [adjustment] as how [file] is shown. The original clears it.
///
/// The photo file is not opened for writing.
Future<void> albumSetViewAdjustment(
  File file,
  AlbumViewAdjustment adjustment, {
  Directory? store,
}) {
  return _serialized(() async {
    final saved = await _read(store);
    final key = _key(file);
    final normalized = AlbumViewAdjustment(
      degrees: albumNormalizeDegrees(adjustment.degrees),
      panX: adjustment.panX,
      panY: adjustment.panY,
    );
    if (normalized.isOriginal) {
      saved.remove(key);
    } else {
      saved[key] = normalized;
    }
    await _write(saved, store);
  });
}

String _key(File file) => file.absolute.path;

Directory _storeOf(Directory? store) => store ?? albumCacheRoot();

File _storeFile(Directory? store) =>
    File(p.join(_storeOf(store).path, 'view-adjustments.json'));

Future<void> _queue = Future<void>.value();

Future<void> _serialized(Future<void> Function() action) {
  final run = _queue.then((_) => action());
  _queue = run.then((_) {}, onError: (_) {});
  return run;
}

Future<Map<String, AlbumViewAdjustment>> _read(Directory? store) async {
  final file = _storeFile(store);
  if (!await file.exists()) return {};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map) return {};
    return {
      for (final entry in decoded.entries)
        if (entry.key is String && _adjustmentFrom(entry.value) != null)
          entry.key as String: _adjustmentFrom(entry.value)!,
    };
  } on Object {
    return {};
  }
}

AlbumViewAdjustment? _adjustmentFrom(Object? value) {
  if (value is num) {
    return AlbumViewAdjustment(
      degrees: albumNormalizeDegrees(value.toDouble()),
    );
  }
  if (value is! Map) return null;
  double pick(String key, double fallback) {
    final raw = value[key];
    return raw is num ? raw.toDouble() : fallback;
  }

  return AlbumViewAdjustment(
    degrees: albumNormalizeDegrees(pick('degrees', 0)),
    panX: pick('panX', 0),
    panY: pick('panY', 0),
  );
}

Future<void> _write(
  Map<String, AlbumViewAdjustment> saved,
  Directory? store,
) async {
  final directory = _storeOf(store);
  await directory.create(recursive: true);
  final file = _storeFile(store);
  if (saved.isEmpty) {
    if (await file.exists()) await file.delete();
    return;
  }
  final text = const JsonEncoder.withIndent('  ').convert({
    for (final entry in saved.entries)
      entry.key: {
        'degrees': entry.value.degrees,
        'panX': entry.value.panX,
        'panY': entry.value.panY,
      },
  });
  await file.writeAsString(text);
}
