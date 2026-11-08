import 'package:flutter/material.dart';

/// Open/close motion that grows from [fromGlobal] (the tapped tile) to fill
/// its parent, and shrinks back into that rect on the way out.
///
/// [flight] should be the same screen-sized image the preview shows
/// ([albumFittedProvider]). Only that image is drawn while the motion runs;
/// the real [child] appears once open completes, already decoded from the
/// same provider so there is no thumbnail→preview swap.
class AlbumPreviewZoomTransition extends StatelessWidget {
  const AlbumPreviewZoomTransition({
    super.key,
    required this.animation,
    required this.child,
    this.fromGlobal,
    this.flight,
  });

  final Animation<double> animation;
  final Widget child;

  /// Global bounds of the tile the preview opens from / closes into.
  final Rect? fromGlobal;

  /// Screen-sized photo drawn during the flight; typically [albumFittedProvider].
  final ImageProvider? flight;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        final open = animation.status == AnimationStatus.completed;
        final t = _eased(animation);

        return LayoutBuilder(
          builder: (context, constraints) {
            final to = Offset.zero & constraints.biggest;
            final host = context.findRenderObject() as RenderBox?;

            // Never fall back to [to] while [fromGlobal] is set but the host
            // is not laid out yet — that one-frame fullscreen flash is a
            // glitch at the start of the open.
            final waitingForHost =
                fromGlobal != null &&
                (host == null || !host.hasSize || !host.attached);
            final showFlight = !open && !waitingForHost;

            Rect? flightRect;
            BorderRadius radius = BorderRadius.zero;
            if (showFlight) {
              final from = fromGlobal == null
                  ? to
                  : Rect.fromPoints(
                      host!.globalToLocal(fromGlobal!.topLeft),
                      host.globalToLocal(fromGlobal!.bottomRight),
                    );
              flightRect = Rect.lerp(from, to, t)!;
              radius = BorderRadius.lerp(
                BorderRadius.circular(8),
                BorderRadius.zero,
                t,
              )!;
            }

            return Stack(
              fit: StackFit.expand,
              children: [
                ColoredBox(
                  color: Color.fromRGBO(
                    0,
                    0,
                    0,
                    open ? 1.0 : t.clamp(0.0, 1.0),
                  ),
                ),
                if (flightRect != null)
                  Positioned(
                    left: flightRect.left,
                    top: flightRect.top,
                    width: flightRect.width.clamp(1.0, double.infinity),
                    height: flightRect.height.clamp(1.0, double.infinity),
                    child: ClipRRect(
                      borderRadius: radius,
                      clipBehavior: Clip.hardEdge,
                      child: flight == null
                          ? const ColoredBox(color: Colors.black)
                          : ColoredBox(
                              color: Colors.black,
                              child: Image(
                                image: flight!,
                                fit: BoxFit.contain,
                                gaplessPlayback: true,
                                filterQuality: FilterQuality.medium,
                              ),
                            ),
                    ),
                  ),
                // Full-size preview under the flight: invisible until open.
                Opacity(
                  opacity: open ? 1 : 0,
                  child: IgnorePointer(ignoring: !open, child: child),
                ),
              ],
            );
          },
        );
      },
      child: child,
    );
  }

  /// Ease out on open and ease in on close without allocating a CurvedAnimation.
  static double _eased(Animation<double> animation) {
    final v = animation.value.clamp(0.0, 1.0);
    final reverse =
        animation.status == AnimationStatus.reverse ||
        animation.status == AnimationStatus.dismissed;
    return reverse
        ? Curves.easeInCubic.transform(v)
        : Curves.easeOutCubic.transform(v);
  }
}

/// Global bounds of [context]'s render box, or null when it is not laid out.
Rect? albumRectOf(BuildContext context) {
  final box = context.findRenderObject() as RenderBox?;
  if (box == null || !box.hasSize || !box.attached) return null;
  return box.localToGlobal(Offset.zero) & box.size;
}
