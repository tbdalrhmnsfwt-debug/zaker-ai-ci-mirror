/// One page of the reader: the page box plus whatever tile arrived for it.
///
/// The page is laid out in unrotated page space and rotated for display, so
/// the tile's normalized [source] always maps straight onto the box.
/// Annotations use the same normalized coordinates, which is what lets a
/// highlight stay on its sentence through zoom, rotation and a new device.
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../../core/pdf/pdf_annotations.dart';
import '../../../core/pdf/pdf_page_geometry.dart';

/// What a touch on the page does while a studio tool is active.
enum PdfPageTool {
  none,
  ink,
  highlight,
  underline,
  strike,
  arrow,
  shape,
  image,
  eraseStroke,
  eraseObject,
  text,
  stamp;

  /// Tools that record a freehand path while the finger moves.
  bool get isStroke =>
      this == ink ||
      this == highlight ||
      this == underline ||
      this == strike ||
      this == eraseStroke;

  /// Tools that turn one drag into a rectangle.
  bool get isDragRect => this == arrow || this == shape || this == image;
}

/// A single page at [zoom], with night mode, rotation, search hits, the
/// studio's annotations and, while a tool is active, the drawing layer.
///
/// The drawing layer owns the gesture arena for its page: an eager pan
/// recognizer is installed only when a pen, marker, shape or eraser tool is
/// active, so normal scrolling and pinch-zoom keep working untouched.
class PdfPageView extends StatefulWidget {
  const PdfPageView({
    super.key,
    required this.geometry,
    required this.fitScale,
    required this.zoom,
    this.quarterTurns = 0,
    this.nightMode = false,
    this.tile,
    this.source,
    this.highlights = const [],
    this.annotations = const [],
    this.onLongPress,
    this.onAnnotationTap,
    this.tool = PdfPageTool.none,
    this.toolColor = 0xFF4779FF,
    this.toolOpacity = 1,
    this.toolStrokeWidth = 0.004,
    this.eraserRadius = 0.02,
    this.shape = PdfShapeKind.rectangle,
    this.onStrokeEnd,
    this.onRectDrag,
    this.onTapPoint,
    this.onErasePoint,
    this.onEraseStart,
    this.onEraseEnd,
  });

  final PdfPageGeometry geometry;
  final double fitScale;
  final double zoom;
  final int quarterTurns;
  final bool nightMode;

  /// PNG bytes for [source], or null while the first tile is rendering.
  final Uint8List? tile;

  /// The normalized page rect [tile] covers.
  final NormalizedRect? source;

  /// Search hits painted over the page, in unrotated page coordinates.
  final List<NormalizedRect> highlights;

  /// Studio annotations that belong to this page.
  final List<PdfAnnotation> annotations;

  /// Emits a zero-sized rect at the long-pressed point, already unrotated.
  final ValueChanged<NormalizedRect>? onLongPress;

  /// Opens the editor for a tapped annotation.
  final ValueChanged<PdfAnnotation>? onAnnotationTap;

  /// The active studio tool; [PdfPageTool.none] keeps the page passive.
  final PdfPageTool tool;

  /// Colour of the in-progress stroke or shape (ARGB).
  final int toolColor;

  /// Opacity of the in-progress stroke (used by the highlighter).
  final double toolOpacity;

  /// Stroke width as a fraction of the page width.
  final double toolStrokeWidth;

  /// Eraser radius as a fraction of the page width.
  final double eraserRadius;

  /// The geometry the shape tool previews and inserts.
  final PdfShapeKind shape;

  /// A completed freehand path, in unrotated page coordinates.
  final ValueChanged<List<PdfPoint>>? onStrokeEnd;

  /// A completed drag for an arrow or shape.
  final void Function(PdfPoint start, PdfPoint end)? onRectDrag;

  /// A tap while the text, stamp or object-eraser tool is active.
  final ValueChanged<PdfPoint>? onTapPoint;

  /// One eraser sample while the finger drags.
  final ValueChanged<PdfPoint>? onErasePoint;

  /// The start of one eraser gesture; the reader snapshots undo here.
  final VoidCallback? onEraseStart;

  /// The end of one eraser gesture; the reader commits one undo entry.
  final VoidCallback? onEraseEnd;

  @override
  State<PdfPageView> createState() => _PdfPageViewState();
}

class _PdfPageViewState extends State<PdfPageView> {
  final List<PdfPoint> _draft = [];
  PdfPoint? _dragStart;
  PdfPoint? _dragCurrent;
  PdfPoint? _eraserPoint;
  bool _erasing = false;

  double _boxWidth = 1;
  double _boxHeight = 1;

  bool get _panTool => widget.tool.isStroke || widget.tool.isDragRect;

  bool get _tapTool =>
      widget.tool == PdfPageTool.text ||
      widget.tool == PdfPageTool.stamp ||
      widget.tool == PdfPageTool.eraseObject;

  /// A pointer position inside the page box, mapped to the unrotated page.
  PdfPoint _pagePoint(Offset local) {
    if (_boxWidth <= 0 || _boxHeight <= 0) return const PdfPoint(0, 0);
    final display = NormalizedRect(
      (local.dx / _boxWidth).clamp(0.0, 1.0).toDouble(),
      (local.dy / _boxHeight).clamp(0.0, 1.0).toDouble(),
      0,
      0,
    );
    final unrotated = PdfPageGeometry.unrotateSource(
      display,
      widget.quarterTurns,
    );
    return PdfPoint(unrotated.left, unrotated.top);
  }

  void _onPanStart(DragStartDetails details) {
    final point = _pagePoint(details.localPosition);
    setState(() {
      _draft
        ..clear()
        ..add(point);
      _dragStart = widget.tool.isDragRect ? point : null;
      _dragCurrent = _dragStart;
      _eraserPoint = widget.tool == PdfPageTool.eraseStroke ? point : null;
      _erasing = widget.tool == PdfPageTool.eraseStroke;
    });
    if (_erasing) {
      widget.onEraseStart?.call();
      widget.onErasePoint?.call(point);
    }
  }

  void _onPanUpdate(DragUpdateDetails details) {
    final point = _pagePoint(details.localPosition);
    setState(() {
      if (widget.tool.isDragRect) {
        _dragCurrent = point;
      } else {
        final last = _draft.isEmpty ? null : _draft.last;
        if (last == null ||
            (point.x - last.x).abs() > 0.0008 ||
            (point.y - last.y).abs() > 0.0008) {
          _draft.add(point);
        }
        if (widget.tool == PdfPageTool.eraseStroke) _eraserPoint = point;
      }
    });
    if (widget.tool == PdfPageTool.eraseStroke) {
      widget.onErasePoint?.call(point);
    }
  }

  void _onPanEnd(DragEndDetails details) {
    final tool = widget.tool;
    final points = List<PdfPoint>.of(_draft);
    final start = _dragStart;
    final end = _dragCurrent;
    final erasing = _erasing;
    setState(() {
      _draft.clear();
      _dragStart = null;
      _dragCurrent = null;
      _eraserPoint = null;
      _erasing = false;
    });
    if (erasing) {
      widget.onEraseEnd?.call();
      return;
    }
    if (tool.isStroke && points.length >= 2) {
      widget.onStrokeEnd?.call(points);
      return;
    }
    if (tool.isDragRect &&
        start != null &&
        end != null &&
        ((end.x - start.x).abs() > 0.004 || (end.y - start.y).abs() > 0.004)) {
      widget.onRectDrag?.call(start, end);
    }
  }

  void _onPanCancel() {
    final erasing = _erasing;
    setState(() {
      _draft.clear();
      _dragStart = null;
      _dragCurrent = null;
      _eraserPoint = null;
      _erasing = false;
    });
    if (erasing) widget.onEraseEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    final pageWidth = widget.geometry
        .displayWidth(fitScale: widget.fitScale, zoom: widget.zoom);
    final pageHeight = widget.geometry
        .displayHeight(fitScale: widget.fitScale, zoom: widget.zoom);
    final turns = ((widget.quarterTurns % 4) + 4) % 4;
    final swapped = turns.isOdd;
    final boxWidth = swapped ? pageHeight : pageWidth;
    final boxHeight = swapped ? pageWidth : pageHeight;
    _boxWidth = boxWidth;
    _boxHeight = boxHeight;

    final showDraft = _draft.length > 1 ||
        _dragStart != null ||
        _dragCurrent != null ||
        _eraserPoint != null;

    final content = SizedBox(
      width: pageWidth,
      height: pageHeight,
      child: Stack(
        fit: StackFit.expand,
        children: [
          const ColoredBox(color: Colors.white),
          if (widget.tile != null && widget.source != null)
            Positioned(
              left: widget.source!.left * pageWidth,
              top: widget.source!.top * pageHeight,
              width: widget.source!.width * pageWidth,
              height: widget.source!.height * pageHeight,
              child: widget.nightMode
                  ? _night(_tileImage(widget.tile!))
                  : _tileImage(widget.tile!),
            ),
          for (final rect in widget.highlights)
            Positioned(
              left: rect.left * pageWidth,
              top: rect.top * pageHeight,
              width: rect.width * pageWidth,
              height: rect.height * pageHeight,
              child: const IgnorePointer(
                child: ColoredBox(color: Color(0x66FFC107)),
              ),
            ),
          for (final annotation in widget.annotations)
            _positionedAnnotation(annotation, pageWidth, pageHeight),
          if (showDraft)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _DraftPainter(
                    tool: widget.tool,
                    points: _draft,
                    dragStart: _dragStart,
                    dragCurrent: _dragCurrent,
                    color: Color(widget.toolColor | 0xFF000000),
                    opacity: widget.toolOpacity.clamp(0.05, 1.0),
                    strokeWidth: widget.toolStrokeWidth,
                    eraserPoint: _eraserPoint,
                    eraserRadius: widget.eraserRadius,
                    shape: widget.shape,
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    final box = SizedBox(
      width: boxWidth,
      height: boxHeight,
      child: DecoratedBox(
        decoration: const BoxDecoration(
          border: Border.fromBorderSide(BorderSide(color: Colors.black12)),
          boxShadow: [
            BoxShadow(
              color: Color(0x22000000),
              blurRadius: 6,
              offset: Offset(0, 2),
            ),
          ],
        ),
        child: turns == 0
            ? content
            : RotatedBox(quarterTurns: turns, child: content),
      ),
    );

    Widget page = box;
    if (_panTool) {
      // The page, not the scroll view, wins the arena while a pen or eraser is
      // active: the recognizer accepts on pointer-down, so a drag draws instead
      // of panning the document.
      page = RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          _EagerPanGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<_EagerPanGestureRecognizer>(
            () => _EagerPanGestureRecognizer(),
            (recognizer) {
              recognizer
                ..onStart = _onPanStart
                ..onUpdate = _onPanUpdate
                ..onEnd = _onPanEnd
                ..onCancel = _onPanCancel;
            },
          ),
        },
        child: box,
      );
    } else if (_tapTool) {
      page = GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (details) =>
            widget.onTapPoint?.call(_pagePoint(details.localPosition)),
        child: box,
      );
    }

    final onLongPress = widget.onLongPress;
    if (onLongPress == null) return page;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPressStart: (details) {
        final point = _pagePoint(details.localPosition);
        onLongPress(NormalizedRect(point.x, point.y, 0, 0));
      },
      child: page,
    );
  }

  Widget _positionedAnnotation(
    PdfAnnotation annotation,
    double pageWidth,
    double pageHeight,
  ) {
    final rect = annotation.rect.clampToPage();
    final left = rect.left * pageWidth;
    final top = rect.top * pageHeight;
    final width = math.max(rect.width * pageWidth, 1.0);
    final height = math.max(rect.height * pageHeight, 1.0);
    final color = Color(annotation.effectiveColor | 0xFF000000);

    switch (annotation.kind) {
      case PdfAnnotationKind.highlight:
        return Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: color.withValues(
                  alpha: annotation.opacity.clamp(0.1, 1) * 0.55,
                ),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        );
      case PdfAnnotationKind.underline:
        return Positioned(
          left: left,
          top: top + height - math.max(1.5, pageHeight * 0.004),
          width: width,
          height: math.max(1.5, pageHeight * 0.004),
          child: IgnorePointer(child: ColoredBox(color: color)),
        );
      case PdfAnnotationKind.strike:
        return Positioned(
          left: left,
          top: top + height / 2,
          width: width,
          height: math.max(1.2, pageHeight * 0.003),
          child: IgnorePointer(
            child: ColoredBox(
              color: color.withValues(alpha: annotation.opacity),
            ),
          ),
        );
      case PdfAnnotationKind.ink:
        return Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _InkPainter(
                color.withValues(alpha: annotation.opacity),
                points: annotation.points,
                rect: rect,
                strokeWidth: annotation.effectiveStrokeWidth,
              ),
            ),
          ),
        );
      case PdfAnnotationKind.note:
        return _card(
          annotation,
          left,
          top,
          width,
          height,
          background: const Color(0xFFFFF6D8),
          border: const Color(0xFFE2B93B),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(
                Icons.sticky_note_2_rounded,
                size: 12,
                color: Color(0xFF8A6500),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  annotation.text.isEmpty ? 'ملاحظة' : annotation.text,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  textDirection: TextDirection.rtl,
                  style: const TextStyle(
                    fontSize: 9,
                    height: 1.35,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF3B2C00),
                  ),
                ),
              ),
            ],
          ),
        );
      case PdfAnnotationKind.text:
        return _card(
          annotation,
          left,
          top,
          width,
          height,
          background: Colors.white.withValues(alpha: 0.92),
          border: const Color(0xFFCBD5E1),
          child: Text(
            annotation.text,
            maxLines: 6,
            overflow: TextOverflow.ellipsis,
            textDirection: TextDirection.rtl,
            textAlign: switch (annotation.textAlign) {
              PdfTextAlign.left => TextAlign.left,
              PdfTextAlign.center => TextAlign.center,
              PdfTextAlign.right => TextAlign.right,
            },
            style: TextStyle(
              fontSize:
                  (annotation.effectiveFontScale * pageHeight).clamp(7.0, 48.0),
              height: 1.3,
              fontWeight: FontWeight.w600,
              color: Color(annotation.effectiveColor | 0xFF000000),
            ),
          ),
        );
      case PdfAnnotationKind.image:
        return _imageAnnotation(annotation, left, top, width, height);
      case PdfAnnotationKind.stamp:
        return _card(
          annotation,
          left,
          top,
          width,
          height,
          background: color.withValues(alpha: 0.12),
          border: color,
          child: Center(
            child: Text(
              annotation.text.isEmpty ? 'تم' : annotation.text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: color,
              ),
            ),
          ),
        );
      case PdfAnnotationKind.arrow:
        return Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ArrowPainter(
                color,
                start: annotation.startPoint,
                end: annotation.endPoint,
                rect: rect,
              ),
            ),
          ),
        );
      case PdfAnnotationKind.shape:
        return Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: CustomPaint(
              painter: _ShapePainter(
                color.withValues(alpha: annotation.opacity),
                annotation.shape,
              ),
            ),
          ),
        );
      case PdfAnnotationKind.audio:
      case PdfAnnotationKind.video:
        return _card(
          annotation,
          left,
          top,
          width,
          height,
          background: Colors.white,
          border: color,
          child: _MediaCardBody(annotation: annotation, accent: color),
        );
    }
  }

  Widget _card(
    PdfAnnotation annotation,
    double left,
    double top,
    double width,
    double height, {
    required Color background,
    required Color border,
    required Widget child,
  }) {
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: widget.onAnnotationTap == null
            ? null
            : () => widget.onAnnotationTap!(annotation),
        child: Material(
          color: Colors.transparent,
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(
              color: background,
              borderRadius: BorderRadius.circular(5),
              border: Border.all(color: border, width: 0.9),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x1F000000),
                  blurRadius: 3,
                  offset: Offset(0, 1),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: child,
            ),
          ),
        ),
      ),
    );
  }

  Widget _imageAnnotation(
    PdfAnnotation annotation,
    double left,
    double top,
    double width,
    double height,
  ) {
    final path = annotation.mediaPath;
    Widget child;
    if (path == null || !File(path).existsSync()) {
      child = const ColoredBox(
        color: Color(0xFFF1ECFF),
        child: Center(
          child: Icon(
            Icons.broken_image_outlined,
            size: 16,
            color: Color(0xFF7C5CFF),
          ),
        ),
      );
    } else {
      child = Image.file(
        File(path),
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) => const ColoredBox(
          color: Color(0xFFF1ECFF),
          child: Center(
            child: Icon(
              Icons.broken_image_outlined,
              size: 16,
              color: Color(0xFF7C5CFF),
            ),
          ),
        ),
      );
    }
    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: GestureDetector(
        onTap: widget.onAnnotationTap == null
            ? null
            : () => widget.onAnnotationTap!(annotation),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: child,
        ),
      ),
    );
  }

  Widget _tileImage(Uint8List bytes) {
    return Image.memory(
      bytes,
      fit: BoxFit.fill,
      gaplessPlayback: true,
      errorBuilder: (context, error, stackTrace) =>
          const ColoredBox(color: Colors.white),
    );
  }

  Widget _night(Widget child) {
    return ColorFiltered(
      colorFilter: const ColorFilter.matrix([
        0.55, 0, 0, 0, 18, //
        0, 0.52, 0, 0, 8, //
        0, 0, 0.45, 0, 0, //
        0, 0, 0, 1, 0, //
      ]),
      child: child,
    );
  }
}

/// The audio/video card drawn on the page: play control, title and metadata.
class _MediaCardBody extends StatelessWidget {
  const _MediaCardBody({required this.annotation, required this.accent});

  final PdfAnnotation annotation;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final isAudio = annotation.kind == PdfAnnotationKind.audio;
    final title = annotation.mediaName.trim().isEmpty
        ? (isAudio ? 'شرح صوتي' : 'شرح بالفيديو')
        : annotation.mediaName;
    final meta = [
      if (annotation.durationMs > 0) _duration(annotation.durationMs),
      if (annotation.mediaBytes > 0) _size(annotation.mediaBytes),
    ].join(' • ');
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 96;
        return Row(
          children: [
            Container(
              width: constraints.maxHeight.clamp(18.0, 34.0),
              height: constraints.maxHeight.clamp(18.0, 34.0),
              decoration: BoxDecoration(
                color: accent.withValues(alpha: 0.14),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Icon(
                isAudio ? Icons.graphic_eq_rounded : Icons.play_arrow_rounded,
                size: 14,
                color: accent,
              ),
            ),
            if (!compact) ...[
              const SizedBox(width: 5),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.w800,
                        color: Color(0xFF102344),
                      ),
                    ),
                    if (meta.isNotEmpty)
                      Text(
                        meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        textDirection: TextDirection.ltr,
                        style: const TextStyle(
                          fontSize: 7,
                          color: Color(0xFF64748B),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

String _duration(int milliseconds) {
  final total = (milliseconds / 1000).round();
  final minutes = total ~/ 60;
  final seconds = total % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String _size(int bytes) {
  if (bytes >= 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  if (bytes >= 1024) return '${(bytes / 1024).round()} KB';
  return '$bytes B';
}

/// Accepts as soon as the pointer lands, so a pen stroke wins over the
/// scroll view's drag recognizer instead of fighting it.
class _EagerPanGestureRecognizer extends PanGestureRecognizer {
  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

/// Maps a page-normalized point into the local box of an annotation.
Offset _localPoint(PdfPoint point, NormalizedRect rect, Size size) {
  final width = math.max(rect.width, 0.0001);
  final height = math.max(rect.height, 0.0001);
  return Offset(
    ((point.x - rect.left) / width).clamp(0.0, 1.0) * size.width,
    ((point.y - rect.top) / height).clamp(0.0, 1.0) * size.height,
  );
}

class _InkPainter extends CustomPainter {
  const _InkPainter(
    this.color, {
    this.points = const [],
    this.rect,
    this.strokeWidth = 0.004,
  });

  final Color color;
  final List<PdfPoint> points;
  final NormalizedRect? rect;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final box = rect;
    final path = Path();
    if (points.length >= 2 && box != null && box.width > 0) {
      // The stroke is stored in page coordinates; the box is the stroke's own
      // bounds, so the width scales with the page, not with the screen.
      final pageWidth = size.width / math.max(box.width, 0.0001);
      path.moveTo(
        _localPoint(points.first, box, size).dx,
        _localPoint(points.first, box, size).dy,
      );
      for (var i = 1; i < points.length; i++) {
        final local = _localPoint(points[i], box, size);
        path.lineTo(local.dx, local.dy);
      }
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.1, strokeWidth * pageWidth)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, paint);
      return;
    }
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.4, size.height * 0.08)
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    const steps = 14;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final x = size.width * t;
      final y = size.height * (0.62 - 0.28 * (i.isOdd ? 1 : 0) - 0.08 * t);
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_InkPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.points != points ||
      oldDelegate.rect != rect;
}

class _ArrowPainter extends CustomPainter {
  const _ArrowPainter(
    this.color, {
    this.start,
    this.end,
    this.rect,
  });

  final Color color;
  final PdfPoint? start;
  final PdfPoint? end;
  final NormalizedRect? rect;

  @override
  void paint(Canvas canvas, Size size) {
    final box = rect;
    final from = (start != null && box != null)
        ? _localPoint(start!, box, size)
        : Offset(size.width * 0.1, size.height * 0.9);
    final to = (end != null && box != null)
        ? _localPoint(end!, box, size)
        : Offset(size.width * 0.9, size.height * 0.1);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    _drawArrow(canvas, from, to, paint);
  }

  @override
  bool shouldRepaint(_ArrowPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.start != start ||
      oldDelegate.end != end;
}

/// Shared head maths for the arrow preview and the stored arrow.
void _drawArrow(Canvas canvas, Offset start, Offset end, Paint paint) {
  canvas.drawLine(start, end, paint);
  final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
  final length = math.min(14.0, (end - start).distance * 0.4).clamp(4.0, 14.0);
  for (final spread in [math.pi * 0.82, -math.pi * 0.82]) {
    canvas.drawLine(
      end,
      end +
          Offset(
            math.cos(angle + spread) * length,
            math.sin(angle + spread) * length,
          ),
      paint,
    );
  }
}

class _ShapePainter extends CustomPainter {
  const _ShapePainter(this.color, this.shape);

  final Color color;
  final PdfShapeKind shape;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;
    switch (shape) {
      case PdfShapeKind.rectangle:
        canvas.drawRect(Offset.zero & size, paint);
      case PdfShapeKind.ellipse:
        canvas.drawOval(Offset.zero & size, paint);
      case PdfShapeKind.line:
        canvas.drawLine(
          Offset(0, size.height),
          Offset(size.width, 0),
          paint,
        );
    }
  }

  @override
  bool shouldRepaint(_ShapePainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.shape != shape;
}

/// The in-progress stroke or drag, painted above the page until the finger
/// lifts and the reader turns it into an annotation.
class _DraftPainter extends CustomPainter {
  const _DraftPainter({
    required this.tool,
    required this.points,
    required this.color,
    required this.opacity,
    required this.strokeWidth,
    required this.eraserRadius,
    required this.shape,
    this.dragStart,
    this.dragCurrent,
    this.eraserPoint,
  });

  final PdfPageTool tool;
  final List<PdfPoint> points;
  final PdfPoint? dragStart;
  final PdfPoint? dragCurrent;
  final Color color;
  final double opacity;
  final double strokeWidth;
  final PdfPoint? eraserPoint;
  final double eraserRadius;
  final PdfShapeKind shape;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.length > 1 && !tool.isDragRect) {
      final paint = Paint()
        ..color = tool == PdfPageTool.highlight
            ? color.withValues(alpha: opacity * 0.55)
            : color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = tool == PdfPageTool.highlight
            ? math.max(6.0, strokeWidth * size.width * 3)
            : math.max(1.4, strokeWidth * size.width)
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path()
        ..moveTo(points.first.x * size.width, points.first.y * size.height);
      for (var i = 1; i < points.length; i++) {
        path.lineTo(points[i].x * size.width, points[i].y * size.height);
      }
      canvas.drawPath(path, paint);
    }

    final start = dragStart;
    final end = dragCurrent;
    if (start != null && end != null) {
      final from = Offset(start.x * size.width, start.y * size.height);
      final to = Offset(end.x * size.width, end.y * size.height);
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      if (tool == PdfPageTool.arrow) {
        _drawArrow(canvas, from, to, paint);
      } else if (tool == PdfPageTool.image) {
        canvas.drawRect(Rect.fromPoints(from, to), paint);
      } else {
        final rect = Rect.fromPoints(from, to);
        switch (shape) {
          case PdfShapeKind.rectangle:
            canvas.drawRect(rect, paint);
          case PdfShapeKind.ellipse:
            canvas.drawOval(rect, paint);
          case PdfShapeKind.line:
            canvas.drawLine(from, to, paint);
        }
      }
    }

    final eraser = eraserPoint;
    if (eraser != null) {
      final center = Offset(eraser.x * size.width, eraser.y * size.height);
      final radius = math.max(3.0, eraserRadius * size.width);
      canvas.drawCircle(
        center,
        radius,
        Paint()..color = Colors.white.withValues(alpha: 0.55),
      );
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(_DraftPainter oldDelegate) =>
      oldDelegate.points != points ||
      oldDelegate.dragStart != dragStart ||
      oldDelegate.dragCurrent != dragCurrent ||
      oldDelegate.eraserPoint != eraserPoint ||
      oldDelegate.color != color;
}
