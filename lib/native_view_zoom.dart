import 'package:flutter/material.dart';

/// Pinch-zoom/pan for a child that must be resized via real layout changes
/// rather than a paint-time transform.
///
/// `InteractiveViewer` zooms by applying a `Transform` (a paint-time matrix)
/// to its child. That works for ordinary Flutter content, but Android's
/// `SurfaceView` — used by the native HDR video player
/// ([HdrVideoPlayerController], to preserve true HDR luminance — see that
/// file's doc comment) — is composited directly by the OS as a separate
/// hardware layer and does not follow `View.scaleX`/`scaleY` set by a paint
/// transform. It *does* respond correctly to being actually re-laid-out at a
/// new size/position, which is what this widget drives instead.
class NativeViewZoom extends StatefulWidget {
  const NativeViewZoom({
    super.key,
    required this.aspectRatio,
    required this.child,
    this.minScale = 1.0,
    this.maxScale = 5.0,
    this.onTap,
  });

  final double aspectRatio;
  final Widget child;
  final double minScale;
  final double maxScale;

  /// Forwarded onto the same GestureDetector as the pinch/pan handling
  /// (tap and scale are different gesture families, so both can coexist).
  final VoidCallback? onTap;

  @override
  State<NativeViewZoom> createState() => _NativeViewZoomState();
}

class _NativeViewZoomState extends State<NativeViewZoom> {
  double _scale = 1.0;
  Offset _topLeft = Offset.zero;
  double _scaleAtGestureStart = 1.0;
  Size? _lastViewport;

  @override
  void didUpdateWidget(covariant NativeViewZoom oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.aspectRatio != widget.aspectRatio) {
      // A differently-shaped video (e.g. the real, rotation-applied aspect
      // ratio just arrived from native) — drop any zoom so it re-centers
      // cleanly against the new shape instead of keeping a stale offset.
      _scale = 1.0;
    }
  }

  Rect _baseRect(Size viewport) {
    final viewportAspect = viewport.width / viewport.height;
    double w, h;
    if (viewportAspect > widget.aspectRatio) {
      h = viewport.height;
      w = h * widget.aspectRatio;
    } else {
      w = viewport.width;
      h = w / widget.aspectRatio;
    }
    return Rect.fromLTWH((viewport.width - w) / 2, (viewport.height - h) / 2, w, h);
  }

  Offset _clampTopLeft(Offset topLeft, Size contentSize, Size viewport) {
    double dx = topLeft.dx;
    double dy = topLeft.dy;
    if (contentSize.width <= viewport.width) {
      dx = (viewport.width - contentSize.width) / 2;
    } else {
      dx = dx.clamp(viewport.width - contentSize.width, 0.0);
    }
    if (contentSize.height <= viewport.height) {
      dy = (viewport.height - contentSize.height) / 2;
    } else {
      dy = dy.clamp(viewport.height - contentSize.height, 0.0);
    }
    return Offset(dx, dy);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewport = Size(constraints.maxWidth, constraints.maxHeight);
        if (_lastViewport != null && _lastViewport != viewport) {
          // The viewport changed shape (e.g. a rotation) — a zoom/pan
          // offset computed for the old viewport doesn't mean anything
          // against the new one, so drop it and recenter instead of
          // leaving the content at a stale, now-nonsensical position.
          _scale = 1.0;
        }
        _lastViewport = viewport;
        final base = _baseRect(viewport);
        final rect = _scale == 1.0
            ? base
            : Rect.fromLTWH(_topLeft.dx, _topLeft.dy, base.width * _scale, base.height * _scale);

        return ClipRect(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onScaleStart: (_) => _scaleAtGestureStart = _scale,
            onScaleUpdate: (details) {
              setState(() {
                final newScale = (_scaleAtGestureStart * details.scale).clamp(
                  widget.minScale,
                  widget.maxScale,
                );
                // Keep the pinch focal point stationary on screen while the
                // content scales around it, then apply this frame's pan.
                final focal = details.localFocalPoint;
                final ratio = newScale / _scale;
                final newLeft = focal.dx - (focal.dx - rect.left) * ratio + details.focalPointDelta.dx;
                final newTop = focal.dy - (focal.dy - rect.top) * ratio + details.focalPointDelta.dy;
                _scale = newScale;
                _topLeft = _clampTopLeft(
                  Offset(newLeft, newTop),
                  Size(base.width * newScale, base.height * newScale),
                  viewport,
                );
              });
            },
            onDoubleTap: () => setState(() => _scale = 1.0),
            onTap: widget.onTap,
            child: Stack(
              children: [
                Positioned(
                  left: rect.left,
                  top: rect.top,
                  width: rect.width,
                  height: rect.height,
                  child: widget.child,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
