import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'album_images.dart';
import 'album_view.dart';

/// Page behind the crop frame, matched to a dark photo editor.
const Color _cropPageColor = Color(0xFF1E1E1E);

/// Quiet button on the crop bar.
const Color _cropChipColor = Color(0xFF3A3A3A);

/// Primary action on the crop bar.
const Color _cropDoneColor = Color(0xFFD978E0);

/// The picture turned by [adjustment.degrees] and slid by its pan, clipped to
/// a frame of the picture's own shape. The frame does not move; the picture does.
class AlbumFramedPhoto extends StatelessWidget {
  const AlbumFramedPhoto({
    super.key,
    required this.adjustment,
    required this.pixels,
    required this.image,
  });

  final AlbumViewAdjustment adjustment;
  final Size pixels;
  final Widget image;

  @override
  Widget build(BuildContext context) {
    if (adjustment.isOriginal) return image;
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final width = pixels.width / dpr;
    final height = pixels.height / dpr;
    if (!width.isFinite || !height.isFinite || width <= 0 || height <= 0) {
      return image;
    }
    final scale = albumCoverScale(
      degrees: adjustment.degrees,
      imageAspect: width / height,
    );
    // The preview viewer passes unbounded constraints. A stack told to expand
    // then tries to be infinite, layout stops, and the transform has no size.
    // Every later mouse move reports that it was not laid out. Size the frame
    // to the picture first, then turn and slide inside it.
    return ClipRect(
      child: SizedBox(
        width: width,
        height: height,
        child: FractionalTranslation(
          translation: Offset(adjustment.panX, adjustment.panY),
          child: Transform.scale(
            scale: scale,
            child: Transform.rotate(
              angle: adjustment.degrees * math.pi / 180,
              child: image,
            ),
          ),
        ),
      ),
    );
  }
}

/// Chooses the visible region of [file] and how far that region is turned.
/// Done returns the choice. The file and its properties are left as they are.
class AlbumAdjustPage extends StatefulWidget {
  const AlbumAdjustPage({
    super.key,
    required this.file,
    this.initial = const AlbumViewAdjustment(),
  });

  final File file;
  final AlbumViewAdjustment initial;

  @override
  State<AlbumAdjustPage> createState() => _AlbumAdjustPageState();
}

class _AlbumAdjustPageState extends State<AlbumAdjustPage> {
  late double _degrees = albumNormalizeDegrees(widget.initial.degrees);
  late double _panX = widget.initial.panX;
  late double _panY = widget.initial.panY;
  ImageStream? _stream;
  ImageStreamListener? _listener;
  Size? _pixels;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final stream = albumFullProvider(
      widget.file,
    ).resolve(createLocalImageConfiguration(context));
    if (stream == _stream) return;
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    _listener = ImageStreamListener((info, _) {
      final next = Size(
        info.image.width.toDouble(),
        info.image.height.toDouble(),
      );
      if (!mounted || next == _pixels) return;
      setState(() => _pixels = next);
    }, onError: (_, _) {});
    _stream = stream;
    stream.addListener(_listener!);
  }

  @override
  void dispose() {
    final listener = _listener;
    if (listener != null) _stream?.removeListener(listener);
    super.dispose();
  }

  double get _aspect {
    final pixels = _pixels;
    if (pixels == null || pixels.height == 0) return 1;
    return pixels.width / pixels.height;
  }

  void _setDegrees(double value) {
    setState(() {
      _degrees = albumNormalizeDegrees(value);
      final pan = albumClampPan(
        degrees: _degrees,
        imageAspect: _aspect,
        pan: Offset(_panX, _panY),
      );
      _panX = pan.dx;
      _panY = pan.dy;
    });
  }

  /// Degrees within the current quarter-turn, in [-45, 45].
  ///
  /// The slider is this short span. The handle moves along a fixed line;
  /// the quarter-turn buttons move to the next span.
  double get _fineAngle {
    final remainder = _degrees % 90;
    if (remainder > 45) return remainder - 90;
    if (remainder < -45) return remainder + 90;
    return remainder;
  }

  void _setFineAngle(double fine) {
    final quarter = _degrees - _fineAngle;
    _setDegrees(quarter + fine);
  }

  void _spin(double delta) => _setDegrees(_degrees + delta);

  void _slide(Offset delta, Size frame) {
    if (frame.width <= 0 || frame.height <= 0) return;
    setState(() {
      final pan = albumClampPan(
        degrees: _degrees,
        imageAspect: _aspect,
        pan: Offset(
          _panX + delta.dx / frame.width,
          _panY + delta.dy / frame.height,
        ),
      );
      _panX = pan.dx;
      _panY = pan.dy;
    });
  }

  var _left = false;

  /// Leaves on the next frame. Popping inside the click that is still being
  /// hit-tested removes the page's mouse regions mid-update, and the tracker
  /// then asserts on every following move.
  void _leave([AlbumViewAdjustment? result]) {
    if (_left) return;
    _left = true;
    WidgetsBinding.instance.scheduleFrame();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Navigator.of(context).pop(result);
    });
  }

  void _done() {
    _leave(AlbumViewAdjustment(degrees: _degrees, panX: _panX, panY: _panY));
  }

  String get _fileName {
    final parts = widget.file.uri.pathSegments;
    final name = parts.isEmpty ? '' : parts.last;
    return name.isEmpty ? widget.file.path : name;
  }

  void _reset() {
    setState(() {
      _degrees = 0;
      _panX = 0;
      _panY = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final label = _degrees == _degrees.roundToDouble()
        ? '${_degrees.toStringAsFixed(0)}°'
        : '${_degrees.toStringAsFixed(1)}°';
    final changed = !AlbumViewAdjustment(
      degrees: _degrees,
      panX: _panX,
      panY: _panY,
    ).isOriginal;
    return Scaffold(
      backgroundColor: _cropPageColor,
      appBar: AppBar(
        backgroundColor: _cropPageColor,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        foregroundColor: Colors.white,
        titleSpacing: 0,
        title: Text(
          _fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        leading: IconButton(
          tooltip: 'Cancel',
          onPressed: _leave,
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          Tooltip(
            message: 'Reset',
            child: TextButton(
              onPressed: changed ? _reset : null,
              child: const Text('Reset'),
            ),
          ),
          _BarButton(label: 'Done', filled: true, onPressed: _done),
          _BarButton(label: 'Cancel', onPressed: _leave),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(48, 12, 48, 8),
              child: _FixedCropStage(
                pixels: _pixels,
                degrees: _degrees,
                panX: _panX,
                panY: _panY,
                onSlide: _slide,
                image: Image(
                  image: albumFullProvider(widget.file),
                  fit: BoxFit.fill,
                  filterQuality: FilterQuality.high,
                  errorBuilder: (_, _, _) => const ColoredBox(
                    color: Colors.white12,
                    child: Icon(
                      Icons.broken_image_outlined,
                      color: Colors.white54,
                      size: 48,
                    ),
                  ),
                ),
              ),
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(36, 0, 36, 8),
              child: Column(
                children: [
                  Align(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: Column(
                        children: [
                          Text(
                            label,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                          SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              trackHeight: 16,
                              activeTrackColor: Colors.transparent,
                              inactiveTrackColor: Colors.transparent,
                              thumbColor: Colors.white,
                              overlayColor: const Color(0x22FFFFFF),
                              showValueIndicator: ShowValueIndicator.never,
                              trackShape: const _DottedSliderTrackShape(),
                              thumbShape: const _PillSliderThumbShape(),
                              overlayShape: const RoundSliderOverlayShape(
                                overlayRadius: 16,
                              ),
                            ),
                            child: Slider(
                              value: _fineAngle.clamp(-45, 45),
                              min: -45,
                              max: 45,
                              onChanged: _setFineAngle,
                            ),
                          ),
                          const Text(
                            '0',
                            style: TextStyle(
                              color: Colors.white54,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      _SpinButton(
                        tooltip: 'Turn left 90 degrees',
                        icon: Icons.rotate_left,
                        onPressed: () => _spin(-90),
                      ),
                      _SpinButton(
                        tooltip: 'Turn right 90 degrees',
                        icon: Icons.rotate_right,
                        onPressed: () => _spin(90),
                      ),
                      const Spacer(),
                      _SpinButton(
                        tooltip: 'Turn left 1 degree',
                        label: '−1°',
                        onPressed: () => _spin(-1),
                      ),
                      _SpinButton(
                        tooltip: 'Turn right 1 degree',
                        label: '+1°',
                        onPressed: () => _spin(1),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.onPressed,
    this.filled = false,
  });

  final String label;
  final VoidCallback onPressed;
  final bool filled;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: TextButton(
        style: TextButton.styleFrom(
          backgroundColor: filled ? _cropDoneColor : _cropChipColor,
          foregroundColor: Colors.white,
          disabledForegroundColor: Colors.white38,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          minimumSize: const Size(0, 36),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        onPressed: onPressed,
        child: Text(label, style: const TextStyle(fontSize: 14)),
      ),
    );
  }
}

/// Fixed frame. The picture turns and slides behind it.
class _FixedCropStage extends StatelessWidget {
  const _FixedCropStage({
    required this.pixels,
    required this.degrees,
    required this.panX,
    required this.panY,
    required this.onSlide,
    required this.image,
  });

  final Size? pixels;
  final double degrees;
  final double panX;
  final double panY;
  final void Function(Offset delta, Size frame) onSlide;
  final Widget image;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stage = constraints.biggest;
        final fitted = pixels == null
            ? stage
            : applyBoxFit(BoxFit.contain, pixels!, stage).destination;
        final frame = Alignment.center.inscribe(fitted, Offset.zero & stage);
        final aspect = pixels == null || pixels!.height == 0
            ? 1.0
            : pixels!.width / pixels!.height;
        final scale = albumCoverScale(degrees: degrees, imageAspect: aspect);
        return GestureDetector(
          onPanUpdate: (details) => onSlide(details.delta, frame.size),
          child: Stack(
            children: [
              Positioned.fromRect(
                rect: frame,
                child: ClipRect(
                  clipBehavior: Clip.none,
                  child: FractionalTranslation(
                    translation: Offset(panX, panY),
                    child: Transform.scale(
                      scale: scale,
                      child: Transform.rotate(
                        angle: degrees * math.pi / 180,
                        child: image,
                      ),
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _FixedFramePainter(frame: frame)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FixedFramePainter extends CustomPainter {
  const _FixedFramePainter({required this.frame});

  final Rect frame;

  @override
  void paint(Canvas canvas, Size size) {
    if (!frame.isFinite || !size.isFinite) return;
    final shade = Path()
      ..addRect(Offset.zero & size)
      ..addRect(frame)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      shade,
      Paint()..color = _cropPageColor.withValues(alpha: 0.72),
    );
    canvas.drawRect(
      frame.deflate(0.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white,
    );
    final handle = Paint()..color = Colors.white;
    const side = 10.0;
    final spots = <Offset>[
      frame.topLeft,
      frame.topCenter,
      frame.topRight,
      frame.centerLeft,
      frame.centerRight,
      frame.bottomLeft,
      frame.bottomCenter,
      frame.bottomRight,
    ];
    for (final spot in spots) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: spot, width: side, height: side),
          const Radius.circular(1.5),
        ),
        handle,
      );
    }
  }

  @override
  bool shouldRepaint(_FixedFramePainter oldDelegate) =>
      oldDelegate.frame != frame;
}

/// Dots along the angle track, with the thumb free to sit between them.
class _DottedSliderTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  const _DottedSliderTrackShape();

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    final canvas = context.canvas;
    final y = rect.center.dy;
    canvas.drawLine(
      Offset(rect.left, y),
      Offset(rect.right, y),
      Paint()
        ..color = const Color(0x55FFFFFF)
        ..strokeWidth = 1,
    );
    final dots = Paint()..color = const Color(0xCCFFFFFF);
    const gap = 14.0;
    for (var x = rect.left; x <= rect.right + 0.5; x += gap) {
      canvas.drawCircle(Offset(x, y), 1.6, dots);
    }
  }
}

/// Vertical grip, like the angle handle in a photo crop tool.
class _PillSliderThumbShape extends SliderComponentShape {
  const _PillSliderThumbShape();

  @override
  Size getPreferredSize(bool isEnabled, bool isDiscrete) => const Size(8, 22);

  @override
  void paint(
    PaintingContext context,
    Offset center, {
    required Animation<double> activationAnimation,
    required Animation<double> enableAnimation,
    required bool isDiscrete,
    required TextPainter labelPainter,
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required TextDirection textDirection,
    required double value,
    required double textScaleFactor,
    required Size sizeWithOverflow,
  }) {
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: center, width: 8, height: 22),
        const Radius.circular(4),
      ),
      Paint()..color = sliderTheme.thumbColor ?? Colors.white,
    );
  }
}

class _SpinButton extends StatelessWidget {
  const _SpinButton({
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.label,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? label;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      color: Colors.white,
      onPressed: onPressed,
      icon: label != null
          ? Text(
              label!,
              style: const TextStyle(color: Colors.white, fontSize: 16),
            )
          : Icon(icon),
    );
  }
}
