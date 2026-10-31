import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'album_images.dart';
import 'album_library.dart';
import 'album_photo.dart';
import 'album_widgets.dart';
import 'photo_info_panel.dart';

/// Longest side, in pixels, of the sharper decode swapped in once a photo is
/// zoomed past the screen-sized one. Bounded so a zoomed 100 MP panorama does
/// not need hundreds of megabytes.
const int _zoomedDecodeSide = 4096;

/// Scale beyond which the sharper decode is requested.
const double _zoomedDecodeScale = 1.5;

/// Scale a double-tap zooms to.
const double _doubleTapScale = 2.5;

/// Image cache budget while a preview is open. The default 100 MB holds only
/// a few screen-sized decodes on a large display, which would evict the
/// neighbors that were just pre-cached.
const int _previewCacheBytes = 256 << 20;

/// Window width from which on-screen previous/next buttons are shown. Narrower
/// screens are assumed to be touch devices that swipe.
const double _sideButtonsMinWidth = 700;

/// Width of the info sidebar.
const double _infoWidth = 340;

/// Window width from which the info sidebar sits beside the photo, which then
/// shrinks to make room. On narrower screens it slides over the photo instead.
const double _infoDockMinWidth = 900;

/// Full-screen viewer for photos already on disk. Swiping moves through
/// [photos] in the same order the grid shows them.
///
/// Tap the photo to hide or show the bars, double-tap to zoom, pinch or scroll
/// to zoom further. On desktop the arrow keys and side buttons move between
/// photos and Escape closes the viewer.
///
/// The info button opens a sidebar on the right with the current photo's
/// details. On a wide window it sits beside the photo, which shrinks to make
/// room; on a narrow one it slides over the photo. It follows the photo as you
/// swipe.
class AlbumPreviewPage extends StatefulWidget {
  const AlbumPreviewPage({
    super.key,
    required this.photos,
    required this.initialIndex,
    this.library,
  });

  final List<AlbumPhoto> photos;
  final int initialIndex;

  /// The album file the grid's thumbnails are kept in, so the preview finds
  /// the same ones already decoded.
  final AlbumLibrary? library;

  @override
  State<AlbumPreviewPage> createState() => _AlbumPreviewPageState();
}

class _AlbumPreviewPageState extends State<AlbumPreviewPage>
    with SingleTickerProviderStateMixin {
  late final PageController _controller = PageController(
    initialPage: widget.initialIndex,
  );
  late int _index = widget.initialIndex;
  bool _chromeVisible = true;
  bool _infoVisible = false;

  /// 0 with the info sidebar closed, 1 fully open.
  late final AnimationController _infoSlide = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
    reverseDuration: const Duration(milliseconds: 200),
  );
  late final Animation<double> _infoCurve = CurvedAnimation(
    parent: _infoSlide,
    curve: Curves.easeOutCubic,
    reverseCurve: Curves.easeInCubic,
  );

  /// True while the current photo is zoomed in. Swiping is switched off then,
  /// so dragging to pan the photo cannot also flip to the next one.
  final ValueNotifier<bool> _zoomed = ValueNotifier(false);

  late final ImageCache _imageCache = PaintingBinding.instance.imageCache;
  late final int _previousCacheBytes = _imageCache.maximumSizeBytes;

  /// Pixels the screen can show, rounded up to coarse steps so that resizing
  /// a desktop window does not change the decode (and re-decode) every frame.
  Size _box = const Size(1280, 1280);

  @override
  void initState() {
    super.initState();
    if (_previousCacheBytes < _previewCacheBytes) {
      _imageCache.maximumSizeBytes = _previewCacheBytes;
    }
  }

  @override
  void dispose() {
    _imageCache.maximumSizeBytes = _previousCacheBytes;
    _infoSlide.dispose();
    _zoomed.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final size = MediaQuery.sizeOf(context);
    final ratio = MediaQuery.devicePixelRatioOf(context);
    double bucket(double logical) =>
        ((logical * ratio / 256).ceil() * 256).clamp(256, 8192).toDouble();
    final box = Size(bucket(size.width), bucket(size.height));
    if (box == _box) return;
    _box = box;
    _precacheNeighborsAfterFrame(_index);
  }

  /// Starts decoding the shots on either side, so by the time a swipe lands
  /// the neighbor is already sitting decoded in the image cache.
  ///
  /// Run after the frame, so the photo on screen gets the decoder first.
  void _precacheNeighborsAfterFrame(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final neighbor in [index + 1, index - 1]) {
        if (neighbor < 0 || neighbor >= widget.photos.length) continue;
        precacheImage(
          albumFittedProvider(widget.photos[neighbor].file, _box),
          context,
          // A corrupt neighbor should surface when it is actually shown (the
          // error builder below), not as a stray exception during a swipe.
          onError: (_, _) {},
        );
      }
    });
  }

  /// Box for the sharper decode, or null when the screen-sized one is already
  /// that large.
  Size? get _zoomedBox {
    if (_box.longestSide >= _zoomedDecodeSide) return null;
    return Size.square(_zoomedDecodeSide.toDouble());
  }

  void _go(int delta) {
    if (_zoomed.value) return;
    final target = _index + delta;
    if (target < 0 || target >= widget.photos.length) return;
    _controller.animateToPage(
      target,
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
    );
  }

  void _toggleChrome() => setState(() => _chromeVisible = !_chromeVisible);

  void _toggleInfo() {
    setState(() => _infoVisible = !_infoVisible);
    if (_infoVisible) {
      _infoSlide.forward();
    } else {
      _infoSlide.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final photo = widget.photos[_index];
    final width = MediaQuery.sizeOf(context).width;
    final wide = width >= _sideButtonsMinWidth;
    final docked = width >= _infoDockMinWidth;

    final info = PhotoInfoPanel(photo: photo, onClose: _toggleInfo);

    return Scaffold(
      backgroundColor: Colors.black,
      body: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _go(-1),
          const SingleActivator(LogicalKeyboardKey.arrowRight): () => _go(1),
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).maybePop(),
        },
        child: Focus(
          autofocus: true,
          child: Stack(
            children: [
              Row(
                children: [
                  Expanded(child: _viewer(photo, wide)),
                  // The photo gives up room as the sidebar opens, and takes it
                  // back as it closes. The sidebar keeps its full width and is
                  // revealed from the right edge, so its text never reflows.
                  if (docked)
                    AnimatedBuilder(
                      animation: _infoCurve,
                      builder: (context, _) => _infoSlide.isDismissed
                          ? const SizedBox.shrink()
                          : ClipRect(
                              child: Align(
                                alignment: Alignment.centerRight,
                                widthFactor: _infoCurve.value,
                                child: SizedBox(width: _infoWidth, child: info),
                              ),
                            ),
                    ),
                ],
              ),
              if (!docked)
                AnimatedBuilder(
                  animation: _infoCurve,
                  builder: (context, _) => _infoSlide.isDismissed
                      ? const SizedBox.shrink()
                      : Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: math.min(_infoWidth, width * 0.85),
                          child: FractionalTranslation(
                            translation: Offset(1 - _infoCurve.value, 0),
                            child: Material(elevation: 8, child: info),
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// The photo pager with its bars and buttons. Fills whatever room the info
  /// sidebar leaves.
  Widget _viewer(AlbumPhoto photo, bool wide) {
    return Stack(
      children: [
        Positioned.fill(
          child: ValueListenableBuilder<bool>(
            valueListenable: _zoomed,
            builder: (context, zoomed, _) => PageView.builder(
              controller: _controller,
              physics: zoomed ? const NeverScrollableScrollPhysics() : null,
              itemCount: widget.photos.length,
              onPageChanged: (index) {
                setState(() => _index = index);
                _precacheNeighborsAfterFrame(index);
              },
              itemBuilder: (context, index) {
                final file = widget.photos[index].file;
                return _PreviewPhoto(
                  key: ValueKey(file.path),
                  file: file,
                  library: widget.library,
                  box: _box,
                  zoomedBox: _zoomedBox,
                  zoomed: _zoomed,
                  onTap: _toggleChrome,
                );
              },
            ),
          ),
        ),
        if (wide) ...[
          _SideButton(
            alignment: Alignment.centerLeft,
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous photo',
            visible: _chromeVisible && _index > 0,
            onPressed: () => _go(-1),
          ),
          _SideButton(
            alignment: Alignment.centerRight,
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next photo',
            visible: _chromeVisible && _index < widget.photos.length - 1,
            onPressed: () => _go(1),
          ),
        ],
        _Bar(
          visible: _chromeVisible,
          top: true,
          child: Row(
            children: [
              const BackButton(color: Colors.white),
              Expanded(
                child: Text(
                  '${_index + 1} / ${widget.photos.length}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Photo info',
                color: Colors.white,
                onPressed: _toggleInfo,
                style: IconButton.styleFrom(
                  backgroundColor: _infoVisible
                      ? Colors.white.withValues(alpha: 0.18)
                      : Colors.transparent,
                ),
                icon: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 180),
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: ScaleTransition(scale: animation, child: child),
                  ),
                  child: Icon(
                    _infoVisible
                        ? Icons.view_sidebar_rounded
                        : Icons.view_sidebar_outlined,
                    key: ValueKey(_infoVisible),
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
          ),
        ),
        _Bar(
          visible: _chromeVisible,
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  photo.fileName,
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  albumShortDateTime(photo.takenAt),
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white70),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Top or bottom bar laid over the photo on a fading shade, so the photo can
/// run edge to edge and the bar text stays readable on any picture.
class _Bar extends StatelessWidget {
  const _Bar({required this.visible, required this.top, required this.child});

  final bool visible;
  final bool top;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    const shade = Color(0xB3000000);
    return Positioned(
      left: 0,
      right: 0,
      top: top ? 0 : null,
      bottom: top ? null : 0,
      child: IgnorePointer(
        ignoring: !visible,
        child: AnimatedOpacity(
          opacity: visible ? 1 : 0,
          duration: const Duration(milliseconds: 180),
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: top ? Alignment.topCenter : Alignment.bottomCenter,
                end: top ? Alignment.bottomCenter : Alignment.topCenter,
                colors: const [shade, Color(0x00000000)],
              ),
            ),
            child: SafeArea(top: top, bottom: !top, child: child),
          ),
        ),
      ),
    );
  }
}

class _SideButton extends StatelessWidget {
  const _SideButton({
    required this.alignment,
    required this.icon,
    required this.tooltip,
    required this.visible,
    required this.onPressed,
  });

  final Alignment alignment;
  final IconData icon;
  final String tooltip;
  final bool visible;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Align(
        alignment: alignment,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedOpacity(
              opacity: visible ? 1 : 0,
              duration: const Duration(milliseconds: 180),
              child: IconButton(
                tooltip: tooltip,
                iconSize: 32,
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.16),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.all(10),
                ),
                onPressed: onPressed,
                icon: Icon(icon),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// One pannable, zoomable photo.
///
/// It is drawn from a decode sized to the screen, which is cheap and sharp at
/// 1x. Only when the user zooms in does a larger decode load, layered on top
/// of the first so nothing blinks while it arrives.
class _PreviewPhoto extends StatefulWidget {
  const _PreviewPhoto({
    super.key,
    required this.file,
    required this.library,
    required this.box,
    required this.zoomedBox,
    required this.zoomed,
    required this.onTap,
  });

  final AlbumLibrary? library;

  final File file;
  final Size box;
  final Size? zoomedBox;

  /// Set to whether this photo is currently zoomed in.
  final ValueNotifier<bool> zoomed;

  final VoidCallback onTap;

  @override
  State<_PreviewPhoto> createState() => _PreviewPhotoState();
}

class _PreviewPhotoState extends State<_PreviewPhoto>
    with SingleTickerProviderStateMixin {
  final TransformationController _transform = TransformationController();
  late final AnimationController _zoomAnimation = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  Animation<Matrix4>? _zoomTween;
  Offset _doubleTapAt = Offset.zero;
  bool _wantsSharper = false;

  @override
  void initState() {
    super.initState();
    _transform.addListener(_onTransform);
    _zoomAnimation.addListener(() {
      final tween = _zoomTween;
      if (tween != null) _transform.value = tween.value;
    });
  }

  @override
  void dispose() {
    _zoomAnimation.dispose();
    _transform.removeListener(_onTransform);
    _transform.dispose();
    super.dispose();
  }

  void _onTransform() {
    final scale = _transform.value.getMaxScaleOnAxis();
    final zoomed = scale > 1.01;
    if (widget.zoomed.value != zoomed) widget.zoomed.value = zoomed;
    if (!_wantsSharper && scale > _zoomedDecodeScale) {
      setState(() => _wantsSharper = true);
    }
  }

  /// Zooms in on the spot that was tapped, or back out when already zoomed.
  void _toggleZoom() {
    final Matrix4 end;
    if (_transform.value.getMaxScaleOnAxis() > 1.01) {
      end = Matrix4.identity();
    } else {
      // Scaling about the tapped point keeps that point under the finger.
      const s = _doubleTapScale;
      end = Matrix4.translationValues(
        -_doubleTapAt.dx * (s - 1),
        -_doubleTapAt.dy * (s - 1),
        0,
      )..multiply(Matrix4.diagonal3Values(s, s, 1));
    }
    _zoomTween = Matrix4Tween(begin: _transform.value, end: end).animate(
      CurvedAnimation(parent: _zoomAnimation, curve: Curves.easeOutCubic),
    );
    _zoomAnimation.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final zoomedBox = widget.zoomedBox;
    return GestureDetector(
      onTap: widget.onTap,
      onDoubleTapDown: (details) => _doubleTapAt = details.localPosition,
      onDoubleTap: _toggleZoom,
      child: InteractiveViewer(
        transformationController: _transform,
        minScale: 1,
        maxScale: 8,
        // A drag that starts while the zoom animation runs takes over.
        onInteractionStart: (_) => _zoomAnimation.stop(),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image(
              image: albumFittedProvider(widget.file, widget.box),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.medium,
              gaplessPlayback: true,
              // The sized decode can take a moment. Until it arrives, show the
              // thumbnail the grid already decoded, which is in the cache.
              frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
                if (wasSynchronouslyLoaded || frame != null) return child;
                return Image(
                  image: albumThumbnailProvider(
                    widget.file,
                    library: widget.library,
                  ),
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                );
              },
              errorBuilder: (_, _, _) => const Center(
                child: Icon(
                  Icons.broken_image_outlined,
                  color: Colors.white54,
                  size: 48,
                ),
              ),
            ),
            if (_wantsSharper && zoomedBox != null)
              Image(
                image: albumFittedProvider(widget.file, zoomedBox),
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                // Transparent until decoded, leaving the screen-sized photo
                // visible underneath.
                frameBuilder: (context, child, frame, wasSynchronouslyLoaded) =>
                    wasSynchronouslyLoaded || frame != null
                    ? child
                    : const SizedBox.shrink(),
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    );
  }
}
