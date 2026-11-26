import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'album_images.dart';
import 'album_library.dart';
import 'album_photo.dart';

/// Height a justified row aims for, in logical pixels. Rows are closed when
/// adding one more photo would pull them below this, so every row ends up
/// around this tall however wide its photos are.
const double albumJustifyRowTarget = 180;

/// Once a floor for justified rows, now unused: enforcing it would stretch a
/// row of very wide photos beyond the grid width and clip their edges. Kept
/// for source compatibility.
const double albumJustifyRowMin = 140;

/// Highest a justified row is allowed to get, so a single ultra-wide photo
/// does not take over the screen.
const double albumJustifyRowMax = 300;

/// Gap between photos in a row, and between rows.
const double albumJustifySpacing = 8;

/// One row of the justified layout: [count] photos starting at [start], all
/// [height] tall, each as wide as its aspect makes it.
///
/// A [filled] row was closed by reaching the target height, so its photos
/// together fill the width; the one row that is not [filled] is the trailing
/// partial row, which keeps its natural widths and sits left-aligned rather
/// than being stretched.
class AlbumJustifiedRow {
  const AlbumJustifiedRow(this.start, this.count, this.height, this.filled);

  /// Index of the first photo of the row in the section's photo list.
  final int start;

  /// How many photos the row holds.
  final int count;

  /// Display height of the row, in logical pixels.
  final double height;

  /// Whether the row's photos fill the available width.
  final bool filled;

  /// Display width of photo [j] of this row (0 to [count] - 1).
  double widthOf(int j, double aspect) {
    final value = aspect.isFinite && aspect > 0 ? aspect : 1.0;
    return value * height;
  }
}

/// Splits [count] photos into rows that fill [maxWidth], Google Photos style.
///
/// Photos are added to a row until the height the row would need to fill the
/// width drops to [targetHeight]; the row is closed there, so its height sits
/// just under the target while its photos keep their own aspect ratios. The
/// last, partly filled row keeps its natural height instead of stretching.
///
/// Rows are only clamped downward, to [maxHeight] ([targetHeight] for the
/// trailing row). No lower bound is applied: raising a row of very wide photos
/// (such as stitched panoramas) would make it wider than [maxWidth], and the
/// grid would then clip their right and bottom edges.
List<AlbumJustifiedRow> albumJustifyRows(
  int count,
  double Function(int index) aspectOf, {
  required double maxWidth,
  double targetHeight = albumJustifyRowTarget,
  double minHeight = albumJustifyRowMin,
  double maxHeight = albumJustifyRowMax,
  double spacing = albumJustifySpacing,
}) {
  if (count <= 0 || maxWidth <= 0) return const [];

  double aspect(int index) {
    final value = aspectOf(index);
    return value.isFinite && value > 0 ? value : 1.0;
  }

  final rows = <AlbumJustifiedRow>[];
  var start = 0;
  var aspectSum = 0.0;
  for (var i = 0; i < count; i++) {
    aspectSum += aspect(i);
    final n = i - start + 1;
    final height = (maxWidth - spacing * (n - 1)) / aspectSum;
    if (height <= targetHeight) {
      rows.add(
        AlbumJustifiedRow(start, n, math.min(height, maxHeight), true),
      );
      start = i + 1;
      aspectSum = 0.0;
    }
  }
  if (start < count) {
    final n = count - start;
    final height = (maxWidth - spacing * (n - 1)) / aspectSum;
    // The last row is not stretched to the full width: shown at the target
    // height, left-aligned, it says plainly that the album ends here.
    rows.add(
      AlbumJustifiedRow(start, n, math.min(height, targetHeight), false),
    );
  }
  return rows;
}

/// Aspect ratios (width / height) of the photos on show, for the justified
/// row layout.
///
/// A photo is measured from its stored thumbnail — the very bytes the tile
/// draws, so the aspect is what the user sees, orientation included. Asking
/// for a photo that has not been measured returns 1 and schedules the
/// measurement, then the store [notifyListeners] once new aspects arrive, in
/// batches, so rows can be laid out again. A photo that cannot be read keeps
/// an aspect of 1 rather than being measured again on every build.
class AlbumAspectStore extends ChangeNotifier {
  AlbumAspectStore({AlbumLibrary? library}) : _library = library;

  final AlbumLibrary? _library;
  final Map<String, double> _aspects = HashMap();
  final Set<String> _measuring = HashSet();
  final List<AlbumPhoto> _pending = [];
  bool _flushScheduled = false;
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// The aspect of [photo], 1 while it is being measured.
  double aspectOf(AlbumPhoto photo) {
    final id = photo.id;
    final known = _aspects[id];
    if (known != null) return known;
    if (_measuring.add(id)) {
      _pending.add(photo);
      _scheduleFlush();
    }
    return 1.0;
  }

  /// Measures [photos] ahead of layout, so rows are right the first time.
  void preload(Iterable<AlbumPhoto> photos) {
    for (final photo in photos) {
      aspectOf(photo);
    }
  }

  /// The queue is emptied once per frame and measured in a single background
  /// pass, so a folder of photos costs one worker isolate rather than a stat
  /// and a header parse per photo on the UI isolate.
  void _scheduleFlush() {
    if (_disposed || _flushScheduled) return;
    _flushScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _flushScheduled = false;
      if (_disposed || _pending.isEmpty) return;
      final batch = List<AlbumPhoto>.of(_pending);
      _pending.clear();
      unawaited(_measureBatch(batch));
    });
  }

  Future<void> _measureBatch(List<AlbumPhoto> batch) async {
    try {
      final sizes = await albumThumbnailDimensionsBatch(
        [for (final photo in batch) photo.file],
        library: _library,
      );
      if (_disposed) return;
      for (final photo in batch) {
        final size = sizes[photo.id];
        if (size == null) {
          // No stored thumbnail yet: make and measure it through the normal
          // thumbnail pool instead.
          unawaited(_measure(photo));
        } else {
          _aspects[photo.id] = size.$1 / size.$2;
          _measuring.remove(photo.id);
        }
      }
      _notifyChanged();
    } catch (_) {
      // The batch pass itself failed. Fall back to per-photo measurement,
      // which also tries the source header, rather than pinning every photo
      // to a square 1.0 and clipping their edges in the grid.
      for (final photo in batch) {
        unawaited(_measure(photo));
      }
    }
  }

  Future<void> _measure(AlbumPhoto photo) async {
    final id = photo.id;
    try {
      var size = await albumThumbnailDimensions(
        photo.file,
        library: _library,
      );
      // The thumbnail could not be made (a very large stitched composite can
      // exhaust memory on a full decode). Fall back to the source header, which
      // gives the same aspect ratio without decoding a single pixel, so a
      // stitched photo is never pinned to a square 1.0 and clipped by cover.
      size ??= await albumSourceDimensions(photo.file);
      _aspects[id] = size == null ? 1.0 : size.$1 / size.$2;
    } catch (_) {
      _aspects[id] = 1.0;
    } finally {
      _measuring.remove(id);
      _notifyChanged();
    }
  }

  /// Coalesces notifications: measuring a whole folder of photos notifies once
  /// at the end of the frame the results landed in, instead of once per photo.
  /// A post-frame callback rather than a timer, so nothing is left pending.
  void _notifyChanged() {
    if (_disposed || _notifyScheduled) return;
    _notifyScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _notifyScheduled = false;
      if (_disposed) return;
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
