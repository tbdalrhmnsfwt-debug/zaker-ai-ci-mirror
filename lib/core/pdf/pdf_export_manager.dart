/// Exports a reading session in two shapes.
///
/// 1. **Flattened PDF** — every mark, sticky note and media card is painted
///    into a copy of the document, so the file opens in any PDF viewer with
///    nothing to install. The original is never touched.
/// 2. **Studio project** — a ZIP package with the source PDF, a JSON manifest
///    of every annotation in normalized page coordinates, and the original
///    audio/video/image bytes. Restoring the package gives the editor back
///    its full state, including media, offline.
///
/// The annotation codec and the archive layer under this file are plain Dart,
/// exercised by `tool/verify_pdf_studio.dart` on the VM. Painting needs the
/// Syncfusion engine in a Flutter build.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' show Offset, Rect, Size;

import 'package:syncfusion_flutter_pdf/pdf.dart' as sf;

import 'pdf_annotations.dart';
import 'zip_store.dart';

/// The manifest format written into a project package.
const String pdfStudioFormat = 'zaker.pdf-studio';
const int pdfStudioVersion = 1;
const String projectManifestName = 'manifest.json';
const String projectSourceName = 'source.pdf';

/// The paper patterns the notebook generator can draw.
enum PdfNotebookStyle {
  /// Horizontal study lines.
  ruled,

  /// A square maths grid.
  grid,

  /// An empty white page.
  plain;

  String get labelAr => switch (this) {
        ruled => 'مسطرة دراسية',
        grid => 'مربعات رياضية',
        plain => 'صفحة بيضاء',
      };
}

/// A project package read back from disk.
class PdfStudioProject {
  const PdfStudioProject({
    required this.documentId,
    required this.documentName,
    required this.sourcePdf,
    required this.annotations,
    required this.attachments,
    this.pageCount,
    this.lastPage = 1,
    this.lastZoom = 1,
    this.quarterTurns = 0,
    this.createdAt,
  });

  final String documentId;
  final String documentName;
  final Uint8List sourcePdf;

  /// Annotations with `mediaPath` left null; use [attachments] to materialise
  /// the media next to the restored document.
  final List<PdfAnnotation> annotations;

  /// Archive paths (`attachments/<id>.mp3`) to their bytes.
  final Map<String, Uint8List> attachments;

  final int? pageCount;
  final int lastPage;
  final double lastZoom;
  final int quarterTurns;
  final DateTime? createdAt;
}

/// A package could not be written or read.
class PdfProjectException implements Exception {
  const PdfProjectException(this.message);

  final String message;

  @override
  String toString() => 'PdfProjectException: $message';
}

/// Builds flattened PDFs and project packages.
class PdfExportManager {
  const PdfExportManager();

  /// Paints [annotations] into a copy of [sourceBytes] and returns the new
  /// PDF bytes. [fontBytes] should be a Unicode TTF so Arabic note text is
  /// embedded; without it, text falls back to Helvetica and non-Latin glyphs
  /// may be omitted rather than drawn as garbage.
  Uint8List flattenPdf({
    required List<int> sourceBytes,
    required List<PdfAnnotation> annotations,
    Uint8List? fontBytes,
    Map<String, List<int>> mediaById = const {},
  }) {
    final document = sf.PdfDocument(inputBytes: sourceBytes);
    try {
      final fonts = _Fonts(fontBytes);
      for (final annotation in annotations) {
        if (annotation.pageIndex < 0 ||
            annotation.pageIndex >= document.pages.count) {
          continue;
        }
        _paint(
            document.pages[annotation.pageIndex], annotation, fonts, mediaById);
      }
      return Uint8List.fromList(document.saveSync());
    } finally {
      document.dispose();
    }
  }

  /// Packages the session for offline restoration.
  Uint8List buildProjectPackage({
    required String documentId,
    required String documentName,
    required List<int> sourceBytes,
    required List<PdfAnnotation> annotations,
    Map<String, List<int>> mediaById = const {},
    int? pageCount,
    int lastPage = 1,
    double lastZoom = 1,
    int quarterTurns = 0,
    DateTime? createdAt,
  }) {
    if (sourceBytes.isEmpty) {
      throw const PdfProjectException('The source PDF is empty.');
    }
    final when = createdAt ?? DateTime.now().toUtc();
    final attachments = <ZipArchiveEntry>[];
    final manifestAnnotations = <Map<String, dynamic>>[];
    for (final annotation in annotations) {
      final reference =
          annotation.mediaPath == null ? null : annotation.mediaReference;
      final media = mediaById[annotation.id];
      if (reference != null && media != null) {
        attachments.add(ZipArchiveEntry(reference, media));
      }
      manifestAnnotations.add(
        annotation.toJson(
          mediaReference: reference != null && media != null ? reference : null,
        ),
      );
    }
    final manifest = <String, dynamic>{
      'format': pdfStudioFormat,
      'version': pdfStudioVersion,
      'createdAt': when.toIso8601String(),
      'document': {
        'id': documentId,
        'name': documentName,
        if (pageCount != null) 'pages': pageCount,
        'lastPage': lastPage,
        'lastZoom': lastZoom,
        'quarterTurns': quarterTurns,
      },
      'annotations': manifestAnnotations,
      'attachments': [
        for (final entry in attachments)
          {
            'path': entry.name,
            'bytes': entry.bytes.length,
          },
      ],
    };
    return buildStoredZip(
      [
        ZipArchiveEntry(
          projectManifestName,
          utf8.encode(jsonEncode(manifest)),
        ),
        ZipArchiveEntry(projectSourceName, sourceBytes),
        ...attachments,
      ],
      modified: when,
    );
  }

  /// Builds a standalone notebook PDF: one A4 page per [pageCount], each with
  /// ruled, squared or plain paper.
  ///
  /// The result is a real PDF, so the reader's pen, highlighter, eraser, text
  /// overlay and export work on it exactly as they do on an imported document.
  Uint8List buildNotebookPdf({
    PdfNotebookStyle style = PdfNotebookStyle.ruled,
    int pageCount = 1,
  }) {
    final count = pageCount.clamp(1, 50);
    final document = sf.PdfDocument();
    try {
      document.pageSettings.margins.all = 0;
      for (var index = 0; index < count; index++) {
        final page = document.pages.add();
        _paintNotebook(page, style);
      }
      return Uint8List.fromList(document.saveSync());
    } finally {
      document.dispose();
    }
  }

  void _paintNotebook(sf.PdfPage page, PdfNotebookStyle style) {
    final size = page.size;
    final graphics = page.graphics;
    final line = sf.PdfPen(
      sf.PdfColor(209, 222, 242),
      width: 0.7,
    );
    const inset = 26.0;
    switch (style) {
      case PdfNotebookStyle.plain:
        break;
      case PdfNotebookStyle.ruled:
        const spacing = 26.0;
        for (var y = inset + spacing; y < size.height - inset; y += spacing) {
          graphics.drawLine(
            line,
            Offset(inset, y),
            Offset(size.width - inset, y),
          );
        }
        // A notebook margin line, on the right for a right-to-left page.
        final margin = sf.PdfPen(sf.PdfColor(224, 115, 128), width: 1);
        graphics.drawLine(
          margin,
          Offset(size.width - inset - 30, inset),
          Offset(size.width - inset - 30, size.height - inset),
        );
      case PdfNotebookStyle.grid:
        const spacing = 22.0;
        for (var y = inset + spacing; y < size.height - inset; y += spacing) {
          graphics.drawLine(
            line,
            Offset(inset, y),
            Offset(size.width - inset, y),
          );
        }
        for (var x = inset + spacing; x < size.width - inset; x += spacing) {
          graphics.drawLine(
            line,
            Offset(x, inset),
            Offset(x, size.height - inset),
          );
        }
    }
  }

  /// Reads a package written by [buildProjectPackage].
  PdfStudioProject readProjectPackage(Uint8List bytes) {
    final Map<String, Uint8List> archive;
    try {
      archive = readStoredZip(bytes);
    } on FormatException catch (error) {
      throw PdfProjectException(error.message);
    }
    final manifestBytes = archive[projectManifestName];
    final source = archive[projectSourceName];
    if (manifestBytes == null || source == null) {
      throw const PdfProjectException(
        'This file does not look like a PDF Studio project.',
      );
    }
    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(manifestBytes));
    } on Object {
      throw const PdfProjectException('The project manifest is damaged.');
    }
    if (decoded is! Map) {
      throw const PdfProjectException('The project manifest is damaged.');
    }
    final manifest = Map<String, dynamic>.from(decoded);
    if (manifest['format'] != pdfStudioFormat) {
      throw const PdfProjectException('This package uses an unknown format.');
    }
    final version = (manifest['version'] as num?)?.toInt() ?? 0;
    if (version != pdfStudioVersion) {
      throw PdfProjectException(
        'This project was made by a different PDF Studio version ($version).',
      );
    }
    final document = manifest['document'];
    if (document is! Map) {
      throw const PdfProjectException('The project manifest is damaged.');
    }
    final doc = Map<String, dynamic>.from(document);
    final annotations = <PdfAnnotation>[];
    final rawAnnotations = manifest['annotations'];
    if (rawAnnotations is List) {
      for (final element in rawAnnotations) {
        if (element is! Map) continue;
        try {
          annotations.add(
            PdfAnnotation.fromJson(Map<String, dynamic>.from(element)),
          );
        } on Object {
          // One bad annotation must not make the whole project unreadable.
          // A mistyped field throws a TypeError, not only a FormatException.
        }
      }
    }
    final attachments = <String, Uint8List>{
      for (final entry in archive.entries)
        if (entry.key.startsWith('attachments/')) entry.key: entry.value,
    };
    return PdfStudioProject(
      documentId: doc['id'] as String? ?? '',
      documentName: doc['name'] as String? ?? 'PDF Studio project',
      sourcePdf: source,
      annotations: annotations,
      attachments: attachments,
      pageCount: (doc['pages'] as num?)?.toInt(),
      lastPage: (doc['lastPage'] as num?)?.toInt() ?? 1,
      lastZoom: ((doc['lastZoom'] as num?)?.toDouble() ?? 1)
          .clamp(1.0, 5.0)
          .toDouble(),
      quarterTurns: ((doc['quarterTurns'] as num?)?.toInt() ?? 0) % 4,
      createdAt: DateTime.tryParse(manifest['createdAt'] as String? ?? ''),
    );
  }

  // ------------------------------------------------------------------ paint

  void _paint(
    sf.PdfPage page,
    PdfAnnotation annotation,
    _Fonts fonts,
    Map<String, List<int>> mediaById,
  ) {
    final size = page.size;
    final rect = annotation.rect.clampToPage();
    final bounds = Rect.fromLTWH(
      rect.left * size.width,
      rect.top * size.height,
      rect.width * size.width,
      rect.height * size.height,
    );
    if (bounds.width <= 0 || bounds.height <= 0) return;
    final graphics = page.graphics;
    final color = annotation.effectiveColor;
    final opacity = annotation.opacity.clamp(0.1, 1.0);

    switch (annotation.kind) {
      case PdfAnnotationKind.highlight:
        final state = graphics.save();
        graphics.setTransparency((opacity * 0.5).clamp(0.08, 0.55));
        graphics.drawRectangle(
          brush: sf.PdfSolidBrush(_color(color)),
          bounds: bounds,
        );
        graphics.restore(state);
      case PdfAnnotationKind.underline:
        graphics.drawLine(
          sf.PdfPen(_color(color), width: 1.6),
          Offset(bounds.left, bounds.bottom - 1),
          Offset(bounds.right, bounds.bottom - 1),
        );
      case PdfAnnotationKind.strike:
        final middle = bounds.top + bounds.height / 2;
        graphics.drawLine(
          sf.PdfPen(_color(color), width: 1.4),
          Offset(bounds.left, middle),
          Offset(bounds.right, middle),
        );
      case PdfAnnotationKind.ink:
        _drawInk(graphics, annotation, color, bounds, size);
      case PdfAnnotationKind.note:
        _drawCard(
          graphics,
          bounds,
          fill: 0xFFF5D45A,
          stroke: 0xFFB88B12,
          text: annotation.text.isEmpty ? 'ملاحظة' : annotation.text,
          textColor: 0xFF3B2C00,
          fonts: fonts,
        );
      case PdfAnnotationKind.text:
        _drawCard(
          graphics,
          bounds,
          fill: 0xFFF2F6FF,
          stroke: 0xFF9FB1D1,
          text: annotation.text,
          textColor: annotation.effectiveColor | 0xFF000000,
          fonts: fonts,
          fontSize:
              (annotation.effectiveFontScale * size.height).clamp(6.0, 48.0),
          align: annotation.textAlign,
        );
      case PdfAnnotationKind.image:
        final bytes = mediaById[annotation.id];
        if (bytes != null && bytes.isNotEmpty) {
          try {
            graphics.drawImage(sf.PdfBitmap(bytes), bounds);
            break;
          } on Object {
            // A damaged image becomes a labelled card rather than failing the
            // whole export.
          }
        }
        _drawCard(
          graphics,
          bounds,
          fill: 0xFFE8E2FF,
          stroke: 0xFF7C5CFF,
          text: annotation.mediaName.isEmpty ? 'صورة' : annotation.mediaName,
          textColor: 0xFF2A1B66,
          fonts: fonts,
        );
      case PdfAnnotationKind.stamp:
        final state = graphics.save();
        graphics.setTransparency(0.18);
        graphics.drawRectangle(
          brush: sf.PdfSolidBrush(_color(color)),
          bounds: bounds,
        );
        graphics.restore(state);
        graphics.drawRectangle(
          pen: sf.PdfPen(_color(color), width: 1.4),
          bounds: bounds,
        );
        _drawText(
          graphics,
          annotation.text.isEmpty ? 'تم' : annotation.text,
          bounds,
          _color(color),
          fonts,
          center: true,
          bold: true,
        );
      case PdfAnnotationKind.arrow:
        final startPoint = annotation.startPoint;
        final endPoint = annotation.endPoint;
        final start = startPoint == null
            ? Offset(bounds.left, bounds.bottom)
            : Offset(startPoint.x * size.width, startPoint.y * size.height);
        final end = endPoint == null
            ? Offset(bounds.right, bounds.top)
            : Offset(endPoint.x * size.width, endPoint.y * size.height);
        _drawArrow(graphics, start, end, _color(color));
      case PdfAnnotationKind.shape:
        final pen = sf.PdfPen(_color(color), width: 2);
        switch (annotation.shape) {
          case PdfShapeKind.rectangle:
            graphics.drawRectangle(pen: pen, bounds: bounds);
          case PdfShapeKind.ellipse:
            graphics.drawEllipse(bounds, pen: pen);
          case PdfShapeKind.line:
            graphics.drawLine(
              pen,
              Offset(bounds.left, bounds.bottom),
              Offset(bounds.right, bounds.top),
            );
        }
      case PdfAnnotationKind.audio:
      case PdfAnnotationKind.video:
        _drawCard(
          graphics,
          bounds,
          fill: annotation.kind == PdfAnnotationKind.audio
              ? 0xFFEDE8FF
              : 0xFFE2F7FD,
          stroke: annotation.kind == PdfAnnotationKind.audio
              ? 0xFF7C5CFF
              : 0xFF35BCE8,
          text: _mediaLabel(annotation),
          textColor: 0xFF14213D,
          fonts: fonts,
          leadingDot: true,
        );
    }
  }

  void _drawInk(
    sf.PdfGraphics graphics,
    PdfAnnotation annotation,
    int color,
    Rect bounds,
    Size pageSize,
  ) {
    final width = (annotation.effectiveStrokeWidth * pageSize.width)
        .clamp(0.8, 24.0)
        .toDouble();
    final pen = sf.PdfPen(_color(color), width: width)
      ..lineCap = sf.PdfLineCap.round
      ..lineJoin = sf.PdfLineJoin.round;
    final points = annotation.points;
    if (points.length >= 2) {
      // One polyline, so a long stroke exports as a path rather than dozens
      // of independent segments.
      final path = sf.PdfPath();
      path.addLine(
        Offset(
            points.first.x * pageSize.width, points.first.y * pageSize.height),
        Offset(points[1].x * pageSize.width, points[1].y * pageSize.height),
      );
      for (var i = 2; i < points.length; i++) {
        path.addLine(
          Offset(points[i - 1].x * pageSize.width,
              points[i - 1].y * pageSize.height),
          Offset(points[i].x * pageSize.width, points[i].y * pageSize.height),
        );
      }
      graphics.drawPath(path, pen: pen);
      return;
    }
    final steps = 14;
    var previous = Offset(bounds.left, bounds.top + bounds.height * 0.7);
    for (var i = 1; i <= steps; i++) {
      final t = i / steps;
      final next = Offset(
        bounds.left + bounds.width * t,
        bounds.top + bounds.height * (0.7 - 0.35 * (i.isOdd ? 1 : 0) - 0.1 * t),
      );
      graphics.drawLine(pen, previous, next);
      previous = next;
    }
  }

  void _drawArrow(
    sf.PdfGraphics graphics,
    Offset start,
    Offset end,
    sf.PdfColor color,
  ) {
    final pen = sf.PdfPen(color, width: 2)..lineCap = sf.PdfLineCap.round;
    graphics.drawLine(pen, start, end);
    final angle = math.atan2(end.dy - start.dy, end.dx - start.dx);
    final length =
        math.min(16.0, (end - start).distance * 0.4).clamp(4.0, 16.0);
    final spread = math.pi * 0.82;
    graphics.drawLine(
      pen,
      end,
      end +
          Offset(
            math.cos(angle + spread) * length,
            math.sin(angle + spread) * length,
          ),
    );
    graphics.drawLine(
      pen,
      end,
      end +
          Offset(
            math.cos(angle - spread) * length,
            math.sin(angle - spread) * length,
          ),
    );
  }

  void _drawCard(
    sf.PdfGraphics graphics,
    Rect bounds, {
    required int fill,
    required int stroke,
    required String text,
    required int textColor,
    required _Fonts fonts,
    bool leadingDot = false,
    double? fontSize,
    PdfTextAlign? align,
  }) {
    graphics.drawRectangle(
      brush: sf.PdfSolidBrush(_color(fill)),
      bounds: bounds,
    );
    graphics.drawRectangle(
      pen: sf.PdfPen(_color(stroke), width: 1),
      bounds: bounds,
    );
    var textBounds = Rect.fromLTWH(
      bounds.left + 6,
      bounds.top + 5,
      bounds.width - 12,
      bounds.height - 10,
    );
    if (leadingDot) {
      final radius = (bounds.height * 0.18).clamp(2.0, 7.0);
      graphics.drawEllipse(
        Rect.fromLTWH(
          bounds.left + 7,
          bounds.top + bounds.height / 2 - radius,
          radius * 2,
          radius * 2,
        ),
        brush: sf.PdfSolidBrush(_color(stroke)),
      );
      textBounds = Rect.fromLTWH(
        bounds.left + radius * 2 + 14,
        bounds.top + 5,
        bounds.width - radius * 2 - 20,
        bounds.height - 10,
      );
    }
    _drawText(
      graphics,
      text,
      textBounds,
      _color(textColor),
      fonts,
      bold: true,
      fontSize: fontSize,
      align: align,
    );
  }

  void _drawText(
    sf.PdfGraphics graphics,
    String text,
    Rect bounds,
    sf.PdfColor color,
    _Fonts fonts, {
    bool center = false,
    bool bold = false,
    double? fontSize,
    PdfTextAlign? align,
  }) {
    if (text.trim().isEmpty) return;
    final size = (fontSize ?? (bounds.height * 0.42).clamp(6.0, 15.0))
        .clamp(6.0, 48.0)
        .toDouble();
    final font = fonts.font(size, bold: bold);
    if (font == null) return;
    final rtl = _isArabic(text);
    final alignment = switch (align) {
      PdfTextAlign.left => sf.PdfTextAlignment.left,
      PdfTextAlign.right => sf.PdfTextAlignment.right,
      PdfTextAlign.center => sf.PdfTextAlignment.center,
      null =>
        center || rtl ? sf.PdfTextAlignment.center : sf.PdfTextAlignment.left,
    };
    graphics.drawString(
      text,
      font,
      brush: sf.PdfSolidBrush(color),
      bounds: bounds,
      format: sf.PdfStringFormat(
        alignment: alignment,
        textDirection: rtl
            ? sf.PdfTextDirection.rightToLeft
            : sf.PdfTextDirection.leftToRight,
        wordWrap: sf.PdfWordWrapType.word,
      ),
    );
  }

  String _mediaLabel(PdfAnnotation annotation) {
    final name = annotation.mediaName.trim();
    if (name.isNotEmpty) return name;
    return annotation.kind == PdfAnnotationKind.audio
        ? 'شرح صوتي'
        : 'شرح بالفيديو';
  }

  sf.PdfColor _color(int argb) {
    return sf.PdfColor(
      (argb >> 16) & 0xff,
      (argb >> 8) & 0xff,
      argb & 0xff,
      (argb >> 24) & 0xff,
    );
  }

  bool _isArabic(String text) => RegExp(r'[؀-ۿ]').hasMatch(text);
}

/// Fonts are created per size on demand; a project with many notes would
/// otherwise embed the same face dozens of times.
class _Fonts {
  _Fonts(this._bytes);

  final Uint8List? _bytes;
  final Map<String, sf.PdfFont?> _cache = {};

  sf.PdfFont? font(double size, {bool bold = false}) {
    final key = '${size.toStringAsFixed(1)}-${bold ? 'b' : 'r'}';
    if (_cache.containsKey(key)) return _cache[key];
    sf.PdfFont? font;
    final bytes = _bytes;
    if (bytes != null && bytes.isNotEmpty) {
      try {
        font = sf.PdfTrueTypeFont(
          bytes,
          size,
          style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
        );
      } on Object {
        font = null;
      }
    }
    font ??= sf.PdfStandardFont(
      sf.PdfFontFamily.helvetica,
      size,
      style: bold ? sf.PdfFontStyle.bold : sf.PdfFontStyle.regular,
    );
    _cache[key] = font;
    return font;
  }
}
