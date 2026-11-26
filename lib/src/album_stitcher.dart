import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

/// How the photos of a group are laid out when stitched together.
enum AlbumStitchMode {
  /// Side by side, matched to the tallest photo's height.
  horizontal,

  /// Top to bottom, matched to the widest photo's width.
  vertical,
}

/// The color that badges stitch group [index] (0-based). Groups cycle through
/// a fixed palette, so each group stands out from its neighbors in the grid
/// and on the stitching page.
ui.Color albumStitchGroupColor(int index) {
  const palette = <ui.Color>[
    ui.Color(0xFFF5A623), // amber
    ui.Color(0xFF42A5F5), // blue
    ui.Color(0xFF66BB6A), // green
    ui.Color(0xFFEF5350), // red
    ui.Color(0xFFAB47BC), // purple
    ui.Color(0xFF26C6DA), // cyan
    ui.Color(0xFFFF7043), // deep orange
    ui.Color(0xFFEC407A), // pink
  ];
  return palette[index % palette.length];
}

/// Stitches a group of photos into one image on a GPU canvas. When the result
/// is larger than the GPU texture limit, the picture is rendered in tiles and
/// encoded with the `image` package instead.
class AlbumImageStitcher {
  AlbumImageStitcher._();

  /// The largest edge a single `Picture.toImage` is asked to render. Above it,
  /// the picture is split into tiles.
  static const int _gpuLimit = 4096;

  /// Stitches [images] (encoded bytes) into one PNG. Every image is scaled to
  /// match the tallest (horizontal) or widest (vertical) of the group, and a
  /// white background fills any gaps. [onProgress] runs from 0 to 1 and
  /// [onLog] reports each step.
  static Future<Uint8List> stitch(
    List<Uint8List> images, {
    required AlbumStitchMode mode,
    void Function(double progress)? onProgress,
    void Function(String message)? onLog,
  }) async {
    if (images.isEmpty) {
      throw ArgumentError('No images to stitch');
    }
    if (images.length == 1) return images.first;

    void log(String message) {
      onLog?.call(message);
      debugPrint('[AlbumImageStitcher] $message');
    }

    onProgress?.call(0.02);
    log('Decoding ${images.length} images…');
    final decoded = <ui.Image>[];
    for (var i = 0; i < images.length; i++) {
      final image = await _decode(images[i]);
      if (image != null) decoded.add(image);
      onProgress?.call(0.02 + 0.13 * ((i + 1) / images.length));
    }
    if (decoded.isEmpty) {
      throw StateError('Could not decode any image');
    }
    log('Decoded ${decoded.length} images');

    // The canvas size and each photo's destination rectangle.
    final rects = <ui.Rect>[];
    var canvasWidth = 0;
    var canvasHeight = 0;
    if (mode == AlbumStitchMode.horizontal) {
      final maxHeight = decoded.fold<int>(
        0,
        (height, image) => math.max(height, image.height),
      );
      var x = 0;
      for (final image in decoded) {
        final w = (image.width * maxHeight / image.height).round();
        rects.add(
          ui.Rect.fromLTWH(
            x.toDouble(),
            0,
            w.toDouble(),
            maxHeight.toDouble(),
          ),
        );
        x += w;
      }
      canvasWidth = x;
      canvasHeight = maxHeight;
    } else {
      final maxWidth = decoded.fold<int>(
        0,
        (width, image) => math.max(width, image.width),
      );
      var y = 0;
      for (final image in decoded) {
        final h = (image.height * maxWidth / image.width).round();
        rects.add(
          ui.Rect.fromLTWH(
            0,
            y.toDouble(),
            maxWidth.toDouble(),
            h.toDouble(),
          ),
        );
        y += h;
      }
      canvasWidth = maxWidth;
      canvasHeight = y;
    }
    log('Canvas $canvasWidth×$canvasHeight');

    onProgress?.call(0.18);
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawRect(
      ui.Rect.fromLTWH(
        0,
        0,
        canvasWidth.toDouble(),
        canvasHeight.toDouble(),
      ),
      ui.Paint()..color = const ui.Color(0xFFFFFFFF),
    );
    for (var i = 0; i < decoded.length; i++) {
      final image = decoded[i];
      canvas.drawImageRect(
        image,
        ui.Rect.fromLTWH(
          0,
          0,
          image.width.toDouble(),
          image.height.toDouble(),
        ),
        rects[i],
        ui.Paint()..filterQuality = ui.FilterQuality.medium,
      );
      image.dispose();
      onProgress?.call(0.18 + 0.42 * ((i + 1) / decoded.length));
    }
    final picture = recorder.endRecording();

    final Uint8List output;
    if (canvasWidth > _gpuLimit || canvasHeight > _gpuLimit) {
      log('Tiled render $canvasWidth×$canvasHeight (GPU limit $_gpuLimit)');
      output = await _renderTiled(
        picture,
        canvasWidth,
        canvasHeight,
        onProgress,
      );
    } else {
      onProgress?.call(0.6);
      final image = await picture.toImage(canvasWidth, canvasHeight);
      onProgress?.call(0.75);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (data == null) throw StateError('PNG encoding failed');
      output = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    }
    picture.dispose();
    onProgress?.call(1);
    log('Done: ${(output.length / 1024).toStringAsFixed(1)} KB');
    return output;
  }

  static Future<Uint8List> _renderTiled(
    ui.Picture picture,
    int width,
    int height,
    void Function(double progress)? onProgress,
  ) async {
    final full = Uint8List(width * height * 4);
    final tilesX = (width + _gpuLimit - 1) ~/ _gpuLimit;
    final tilesY = (height + _gpuLimit - 1) ~/ _gpuLimit;
    final total = tilesX * tilesY;
    var tile = 0;
    for (var ty = 0; ty < height; ty += _gpuLimit) {
      for (var tx = 0; tx < width; tx += _gpuLimit) {
        final tW = math.min(_gpuLimit, width - tx);
        final tH = math.min(_gpuLimit, height - ty);
        tile++;
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.clipRect(ui.Rect.fromLTWH(0, 0, tW.toDouble(), tH.toDouble()));
        canvas.translate(-tx.toDouble(), -ty.toDouble());
        canvas.drawPicture(picture);
        final tilePicture = recorder.endRecording();
        final tileImage = await tilePicture.toImage(tW, tH);
        tilePicture.dispose();
        final bytes = await tileImage.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        tileImage.dispose();
        if (bytes != null) {
          final src = bytes.buffer.asUint8List(
            bytes.offsetInBytes,
            tW * tH * 4,
          );
          for (var y = 0; y < tH; y++) {
            final dstOff = ((ty + y) * width + tx) * 4;
            full.setRange(dstOff, dstOff + tW * 4, src, y * tW * 4);
          }
        }
        onProgress?.call(0.6 + 0.22 * tile / total);
      }
    }
    onProgress?.call(0.82);
    return _encodeRgbaToPng(width, height, full);
  }

  /// Encodes raw RGBA into a PNG with the `image` package, for canvases too
  /// large for a single GPU texture. Runs on a worker isolate: the deflate of
  /// a huge canvas is the slowest part of a save, and doing it here keeps the
  /// UI isolate drawing the progress bar while it runs. The RGBA buffer moves
  /// to the worker with no copy.
  static Future<Uint8List> _encodeRgbaToPng(
    int width,
    int height,
    Uint8List rgba,
  ) {
    final transfer = TransferableTypedData.fromList([rgba]);
    return Isolate.run(() {
      final pixels = transfer.materialize().asUint8List();
      final image = img.Image.fromBytes(
        width: width,
        height: height,
        bytes: pixels.buffer,
        numChannels: 4,
      );
      return Uint8List.fromList(img.encodePng(image));
    });
  }

  static Future<ui.Image?> _decode(Uint8List bytes) {
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromList(bytes, completer.complete);
    return completer.future;
  }

}
