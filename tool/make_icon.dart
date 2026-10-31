// Draws the app icon and writes it where each platform expects it.
//
//   dart run tool/make_icon.dart
//
// The picture is drawn here, shape by shape, rather than kept as a binary, so
// it can be tuned and redrawn at every size. Run it from the package root.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// Side of the master picture, in pixels.
const int _master = 1024;

// Colors match the demo app's theme: a near-black surface with an amber accent.
const _surfaceTop = (0x24, 0x24, 0x29);
const _surfaceBottom = (0x10, 0x10, 0x12);
const _amberTop = (0xFF, 0xCF, 0x66);
const _amberBottom = (0xF0, 0x93, 0x0F);
const _cream = (0xFF, 0xF6, 0xE0);
const _ink = (0x1C, 0x14, 0x08);
const _farMountain = (0x8A, 0x5A, 0x12);

void main() {
  final picture = _render(_master);

  final example = Directory('example');
  if (!example.existsSync()) {
    stderr.writeln(
      'Run this from the package root (the folder with example/).',
    );
    exit(1);
  }

  // Master copy, for anything that wants a big version of the icon.
  _write('example/icon/app_icon.png', img.encodePng(picture));

  // Windows: one .ico holding every size the shell asks for.
  final sizes = [16, 24, 32, 48, 64, 128, 256];
  _write('example/windows/runner/resources/app_icon.ico', _ico(picture, sizes));

  // Android launcher icons, one per screen density.
  const densities = {
    'mdpi': 48,
    'hdpi': 72,
    'xhdpi': 96,
    'xxhdpi': 144,
    'xxxhdpi': 192,
  };
  densities.forEach((name, side) {
    _write(
      'example/android/app/src/main/res/mipmap-$name/ic_launcher.png',
      img.encodePng(_resize(picture, side)),
    );
  });
}

void _write(String path, List<int> bytes) {
  final file = File(path)..createSync(recursive: true);
  file.writeAsBytesSync(bytes);
  stdout.writeln('wrote $path (${bytes.length} bytes)');
}

img.Image _resize(img.Image picture, int side) => img.copyResize(
  picture,
  width: side,
  height: side,
  interpolation: img.Interpolation.average,
);

/// An .ico with a PNG for each of [sizes], which Windows has read since Vista.
Uint8List _ico(img.Image picture, List<int> sizes) {
  final pngs = [
    for (final side in sizes)
      Uint8List.fromList(img.encodePng(_resize(picture, side))),
  ];
  final header = 6 + 16 * sizes.length;
  final total = header + pngs.fold<int>(0, (sum, png) => sum + png.length);
  final data = ByteData(total);
  data
    ..setUint16(0, 0, Endian.little) // reserved
    ..setUint16(2, 1, Endian.little) // type: icon
    ..setUint16(4, sizes.length, Endian.little);
  final out = Uint8List.view(data.buffer);
  var offset = header;
  for (var i = 0; i < sizes.length; i++) {
    final entry = 6 + 16 * i;
    final side = sizes[i];
    data
      ..setUint8(entry, side >= 256 ? 0 : side) // 0 means 256
      ..setUint8(entry + 1, side >= 256 ? 0 : side)
      ..setUint8(entry + 2, 0) // palette size
      ..setUint8(entry + 3, 0)
      ..setUint16(entry + 4, 1, Endian.little) // planes
      ..setUint16(entry + 6, 32, Endian.little) // bits per pixel
      ..setUint32(entry + 8, pngs[i].length, Endian.little)
      ..setUint32(entry + 12, offset, Endian.little);
    out.setRange(offset, offset + pngs[i].length, pngs[i]);
    offset += pngs[i].length;
  }
  return out;
}

// ---------------------------------------------------------------------------
// Drawing. Each shape is a signed distance: negative inside, positive outside,
// in pixels. One pixel of distance becomes one pixel of soft edge, so every
// edge is smooth without drawing the picture larger and shrinking it.

double _clamp01(double v) => v < 0 ? 0 : (v > 1 ? 1 : v);

double _cover(double distance) => _clamp01(0.5 - distance);

double _mix(num a, num b, double t) => a + (b - a) * t;

/// Distance to a box with rounded corners, centred on the origin.
double _roundBox(double x, double y, double halfW, double halfH, double r) {
  final qx = x.abs() - halfW + r;
  final qy = y.abs() - halfH + r;
  final outside = math.sqrt(
    math.pow(math.max(qx, 0), 2) + math.pow(math.max(qy, 0), 2),
  );
  return outside + math.min(math.max(qx, qy), 0) - r;
}

/// Distance to a convex polygon, whatever way round its points are listed.
double _polygon(double x, double y, List<(double, double)> points) {
  var area = 0.0;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    area += a.$1 * b.$2 - b.$1 * a.$2;
  }
  final sign = area > 0 ? 1.0 : -1.0;
  var worst = -double.infinity;
  for (var i = 0; i < points.length; i++) {
    final a = points[i];
    final b = points[(i + 1) % points.length];
    final ex = b.$1 - a.$1;
    final ey = b.$2 - a.$2;
    final length = math.sqrt(ex * ex + ey * ey);
    // Outward normal of the edge.
    final nx = sign * ey / length;
    final ny = -sign * ex / length;
    worst = math.max(worst, (x - a.$1) * nx + (y - a.$2) * ny);
  }
  return worst;
}

/// A photo: a rounded square, turned by [angle] about its centre.
class _Card {
  const _Card(this.cx, this.cy, this.half, this.radius, this.angle);

  final double cx;
  final double cy;
  final double half;
  final double radius;
  final double angle;

  /// Point in the card's own frame, origin at its centre.
  (double, double) local(double x, double y) {
    final dx = x - cx;
    final dy = y - cy;
    final c = math.cos(angle);
    final s = math.sin(angle);
    return (dx * c + dy * s, -dx * s + dy * c);
  }

  double distance(double x, double y) {
    final (lx, ly) = local(x, y);
    return _roundBox(lx, ly, half, half, radius);
  }
}

/// Colour being built up, premultiplied, drawn over layer by layer.
class _Pixel {
  double r = 0, g = 0, b = 0, a = 0;

  void over((int, int, int) color, double alpha) {
    if (alpha <= 0) return;
    final keep = 1 - alpha;
    r = r * keep + color.$1 * alpha;
    g = g * keep + color.$2 * alpha;
    b = b * keep + color.$3 * alpha;
    a = a * keep + alpha;
  }
}

img.Image _render(int side) {
  final scale = side / 1024.0;
  final picture = img.Image(width: side, height: side, numChannels: 4);

  // Everything below is laid out on a 1024 grid and scaled to [side].
  final backCard = _Card(512, 512, 290, 70, -0.21);
  final midCard = _Card(512, 512, 290, 70, 0.17);
  final front = _Card(512, 520, 290, 70, 0);

  // Mountains and sun, in the front card's own frame (origin at its centre).
  final farPeak = <(double, double)>[(-30, 340), (130, 60), (350, 340)];
  final nearPeak = <(double, double)>[(-360, 340), (-70, -50), (230, 340)];
  const sun = (130.0, -130.0, 56.0);

  for (var py = 0; py < side; py++) {
    for (var px = 0; px < side; px++) {
      final x = (px + 0.5) / scale;
      final y = (py + 0.5) / scale;
      final pixel = _Pixel();

      // Rounded-square surface with a soft top-to-bottom shade.
      final surface = _cover(
        _roundBox(x - 512, y - 512, 512, 512, 232) * scale,
      );
      if (surface <= 0) {
        // Outside the icon: transparent, but coloured like the edge so a
        // smaller copy does not pick up a dark fringe.
        picture.setPixelRgba(px, py, 0x10, 0x10, 0x12, 0);
        continue;
      }
      final shade = _clamp01(y / 1024);
      pixel.over((
        _mix(_surfaceTop.$1, _surfaceBottom.$1, shade).round(),
        _mix(_surfaceTop.$2, _surfaceBottom.$2, shade).round(),
        _mix(_surfaceTop.$3, _surfaceBottom.$3, shade).round(),
      ), 1);

      // Two photos behind, peeking out at the corners.
      pixel.over(_amberBottom, 0.30 * _cover(backCard.distance(x, y) * scale));
      pixel.over(_amberTop, 0.55 * _cover(midCard.distance(x, y) * scale));

      // The front photo's shadow, then the photo itself.
      final shadowDistance = front.distance(x, y - 30);
      final shadow = shadowDistance <= 0
          ? 1.0
          : math.pow(_clamp01(1 - shadowDistance / 60), 2).toDouble();
      pixel.over((0, 0, 0), 0.5 * shadow);

      final onCard = _cover(front.distance(x, y) * scale);
      if (onCard > 0) {
        final (lx, ly) = front.local(x, y);
        final t = _clamp01((ly + front.half) / (2 * front.half));
        pixel.over((
          _mix(_amberTop.$1, _amberBottom.$1, t).round(),
          _mix(_amberTop.$2, _amberBottom.$2, t).round(),
          _mix(_amberTop.$3, _amberBottom.$3, t).round(),
        ), onCard);

        // The picture on the photo, kept inside its edge.
        final sunDistance =
            math.sqrt(math.pow(lx - sun.$1, 2) + math.pow(ly - sun.$2, 2)) -
            sun.$3;
        pixel.over(_cream, onCard * _cover(sunDistance * scale));
        pixel.over(
          _farMountain,
          onCard * _cover(_polygon(lx, ly, farPeak) * scale),
        );
        pixel.over(_ink, onCard * _cover(_polygon(lx, ly, nearPeak) * scale));
      }

      final alpha = pixel.a * surface;
      if (alpha <= 0) {
        picture.setPixelRgba(px, py, 0x10, 0x10, 0x12, 0);
        continue;
      }
      picture.setPixelRgba(
        px,
        py,
        (pixel.r / pixel.a).round().clamp(0, 255),
        (pixel.g / pixel.a).round().clamp(0, 255),
        (pixel.b / pixel.a).round().clamp(0, 255),
        (alpha * 255).round().clamp(0, 255),
      );
    }
  }
  return picture;
}
