/// Flutter-free verification of the PDF Studio data layer.
///
/// Run with the local Dart SDK:
///
///     dart run tool/verify_pdf_studio.dart
///
/// The annotation model and the ZIP container are plain Dart, so they can be
/// checked without a widget tree. Painting flattening needs the Syncfusion
/// engine inside a Flutter build and is covered by CI's `flutter test`.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../lib/core/pdf/pdf_annotations.dart';
import '../lib/core/pdf/pdf_page_geometry.dart';
import '../lib/core/pdf/zip_store.dart';

var _checks = 0;
final _failures = <String>[];

void check(bool condition, String description) {
  _checks++;
  if (!condition) _failures.add(description);
}

void checkClose(num actual, num expected, String description) {
  check(
    (actual - expected).abs() < 1e-9,
    '$description (expected $expected, got $actual)',
  );
}

bool throwsFormat(void Function() action) {
  try {
    action();
    return false;
  } on FormatException {
    return true;
  } on Object {
    return false;
  }
}

PdfAnnotation annotation({
  String id = 'a1',
  int page = 2,
  PdfAnnotationKind kind = PdfAnnotationKind.note,
  NormalizedRect rect = const NormalizedRect(0.2, 0.3, 0.4, 0.1),
  int color = 0,
  double opacity = 0.6,
  String text = 'ملاحظة عربية',
  String? mediaPath,
  String mediaName = '',
  int mediaBytes = 0,
  int durationMs = 0,
  List<PdfPoint> points = const [],
  double strokeWidth = 0,
  double fontScale = 0,
  PdfTextAlign textAlign = PdfTextAlign.center,
  PdfShapeKind shape = PdfShapeKind.rectangle,
  DateTime? createdAt,
}) {
  return PdfAnnotation(
    id: id,
    pageIndex: page,
    kind: kind,
    rect: rect,
    color: color,
    opacity: opacity,
    text: text,
    mediaPath: mediaPath,
    mediaName: mediaName,
    mediaBytes: mediaBytes,
    durationMs: durationMs,
    points: points,
    strokeWidth: strokeWidth,
    fontScale: fontScale,
    textAlign: textAlign,
    shape: shape,
    createdAt: createdAt ?? DateTime.utc(2026, 10, 30, 12),
  );
}

/// Fields a stored annotation must preserve.
bool _sameAnnotation(PdfAnnotation a, PdfAnnotation b) {
  return a.id == b.id &&
      a.pageIndex == b.pageIndex &&
      a.kind == b.kind &&
      (a.rect.left - b.rect.left).abs() < 1e-9 &&
      (a.rect.top - b.rect.top).abs() < 1e-9 &&
      (a.rect.width - b.rect.width).abs() < 1e-9 &&
      (a.rect.height - b.rect.height).abs() < 1e-9 &&
      a.effectiveColor == b.effectiveColor &&
      (a.opacity - b.opacity).abs() < 1e-9 &&
      a.text == b.text &&
      a.mediaPath == b.mediaPath &&
      a.mediaName == b.mediaName &&
      a.mediaBytes == b.mediaBytes &&
      a.durationMs == b.durationMs &&
      a.points.length == b.points.length &&
      List.generate(a.points.length, (i) => a.points[i] == b.points[i])
          .every((same) => same) &&
      (a.strokeWidth - b.strokeWidth).abs() < 1e-9 &&
      (a.fontScale - b.fontScale).abs() < 1e-9 &&
      a.textAlign == b.textAlign &&
      a.shape == b.shape &&
      a.createdAt.toUtc() == b.createdAt.toUtc();
}

void main() {
  _annotationJson();
  _annotationDefaults();
  _annotationSafety();
  _annotationDrawing();
  _annotationCodec();
  _zipRoundTrip();
  _zipRejects();
  _zipUnsafety();

  if (_failures.isEmpty) {
    // ignore: avoid_print
    print('All $_checks PDF Studio checks passed');
    return;
  }
  // ignore: avoid_print
  print('$_failures.length of $_checks PDF Studio checks failed:');
  for (final failure in _failures) {
    // ignore: avoid_print
    print(' - $failure');
  }
  throw StateError('PDF Studio verification failed');
}

void _annotationJson() {
  final note = annotation();
  final json = note.toJson();
  final round = PdfAnnotation.fromJson(json);
  check(round.id == note.id, 'annotation keeps its id');
  check(round.pageIndex == note.pageIndex, 'annotation keeps its page');
  check(round.kind == note.kind, 'annotation keeps its kind');
  checkClose(round.rect.left, note.rect.left, 'annotation keeps left');
  checkClose(round.rect.top, note.rect.top, 'annotation keeps top');
  checkClose(round.rect.width, note.rect.width, 'annotation keeps width');
  checkClose(round.rect.height, note.rect.height, 'annotation keeps height');
  check(round.text == note.text, 'annotation keeps its text');
  checkClose(round.opacity, note.opacity, 'annotation keeps its opacity');
  check(
    round.createdAt.toUtc() == note.createdAt.toUtc(),
    'annotation keeps its creation time',
  );

  final media = annotation(
    id: 'm1',
    kind: PdfAnnotationKind.audio,
    mediaPath: '/data/app/clip.MP3',
    mediaName: 'شرح.mp3',
    mediaBytes: 2048,
    durationMs: 1500,
  );
  final reference = media.mediaReference;
  check(
    reference == 'attachments/m1.mp3',
    'media reference uses the sanitized extension',
  );
  final mediaJson = media.toJson(mediaReference: reference);
  check(mediaJson['media'] == reference, 'manifest stores the attachment path');
  check(
    !mediaJson.containsKey('mediaPath'),
    'a project manifest never stores a device path',
  );
  final mediaRound = PdfAnnotation.fromJson(mediaJson);
  check(mediaRound.mediaPath == null, 'manifest does not leak absolute paths');
  check(mediaRound.mediaName == 'شرح.mp3', 'media keeps its display name');
  check(mediaRound.mediaBytes == 2048, 'media keeps its byte count');
  check(mediaRound.durationMs == 1500, 'media keeps its duration');
  check(mediaRound.mediaExtension == 'mp3', 'media extra keeps its extension');
}

void _annotationDefaults() {
  final note = annotation(color: 0);
  check(
    note.effectiveColor == PdfAnnotationKind.note.defaultColor,
    'zero color falls back to the kind accent',
  );
  final custom = annotation(color: 0xFF123456);
  check(custom.effectiveColor == 0xFF123456, 'custom color wins');

  check(
    PdfAnnotationKind.highlight.isMark &&
        PdfAnnotationKind.underline.isMark &&
        PdfAnnotationKind.strike.isMark &&
        PdfAnnotationKind.ink.isMark,
    'highlight, underline, strike and ink are marks',
  );
  check(!PdfAnnotationKind.note.isMark, 'a note is not a mark');
  check(!PdfAnnotationKind.image.isMark, 'an image is not a mark');
  check(
    PdfAnnotationKind.image.hasMedia &&
        PdfAnnotationKind.audio.hasMedia &&
        PdfAnnotationKind.video.hasMedia,
    'image, audio and video own media',
  );
  check(!PdfAnnotationKind.stamp.hasMedia, 'a stamp has no media');

  check(annotation().mediaReference == null, 'a note has no attachment path');
  final noExtension = annotation(
    kind: PdfAnnotationKind.image,
    mediaPath: '/data/app/no-extension',
  );
  check(noExtension.mediaExtension == 'bin', 'a missing extension becomes bin');
  final longExtension = annotation(
    kind: PdfAnnotationKind.image,
    mediaPath: '/data/app/file.verylongext',
  );
  check(
    longExtension.mediaExtension == 'bin',
    'an overlong extension becomes bin',
  );
  final upper = annotation(
    kind: PdfAnnotationKind.video,
    mediaPath: '/data/app/MOVIE.MP4',
  );
  check(upper.mediaExtension == 'mp4', 'extensions are lowercased');

  final copy = annotation().copyWith(text: 'جديد', opacity: 0.9);
  check(copy.text == 'جديد' && copy.opacity == 0.9, 'copyWith replaces fields');
  check(copy.id == 'a1', 'copyWith keeps untouched fields');
}

void _annotationSafety() {
  final raw = <String, dynamic>{
    'id': 'a1',
    'page': -4,
    'kind': 'laser',
    'rect': [-0.2, -0.2, 0.5, 0.5],
    'opacity': 0.01,
    'createdAt': 'not-a-date',
  };
  final parsed = PdfAnnotation.fromJson(raw);
  check(parsed.pageIndex == 0, 'a negative page is clamped to the first page');
  check(
    parsed.kind == PdfAnnotationKind.highlight,
    'an unknown kind falls back to highlight',
  );
  check(parsed.rect.left == 0 && parsed.rect.top == 0, 'rect starts on page');
  checkClose(parsed.rect.width, 0.3, 'rect width is clamped to the page');
  checkClose(parsed.rect.height, 0.3, 'rect height is clamped to the page');
  checkClose(parsed.opacity, 0.1, 'opacity never drops below 0.1');
  check(
    parsed.createdAt == DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    'an unreadable date becomes the Unix epoch',
  );

  final high = PdfAnnotation.fromJson({
    'id': 'a2',
    'page': 0,
    'kind': 'stamp',
    'rect': [0.8, 0.8, 0.5, 0.5],
    'opacity': 5,
    'createdAt': '2026-10-30T12:00:00.000Z',
  });
  checkClose(high.opacity, 1.0, 'opacity never grows past 1.0');
  checkClose(high.rect.right, 1.0, 'rect right edge stays on the page');
  checkClose(high.rect.bottom, 1.0, 'rect bottom edge stays on the page');

  final smuggled = PdfAnnotation.fromJson({
    'id': 'a9',
    'page': 0,
    'kind': 'image',
    'rect': [0, 0, 0.2, 0.2],
    'mediaPath': '/data/user/0/secret.txt',
    'mediaName': 'secret.txt',
    'createdAt': '2026-10-30T12:00:00.000Z',
  });
  check(
    smuggled.mediaPath == null,
    'a manifest cannot inject a device path',
  );

  check(
    throwsFormat(
      () => PdfAnnotation.fromJson({'page': 0}),
    ),
    'an annotation without an id is rejected',
  );
  check(
    throwsFormat(
      () => PdfAnnotation.fromJson({
        'id': 'a1',
        'page': 0,
        'rect': [0, 0, 1],
      }),
    ),
    'a rectangle without four values is rejected',
  );
}

void _annotationDrawing() {
  check(
    annotation().effectiveStrokeWidth == 0.004,
    'a stroke width of zero means the default pen',
  );
  check(
    annotation().effectiveFontScale == 0.022,
    'a font scale of zero means the default text size',
  );

  final points = const [
    PdfPoint(0.2, 0.3),
    PdfPoint(0.4, 0.35),
    PdfPoint(0.45, 0.5),
  ];
  final bounds = pdfBoundsOfPoints(points, padding: 0.01);
  check(bounds != null, 'a stroke produces bounds');
  checkClose(bounds!.left, 0.19, 'stroke bounds pad the left edge');
  checkClose(bounds.top, 0.29, 'stroke bounds pad the top edge');
  checkClose(bounds.right, 0.46, 'stroke bounds pad the right edge');
  checkClose(bounds.bottom, 0.51, 'stroke bounds pad the bottom edge');
  check(pdfBoundsOfPoints(const []) == null, 'an empty stroke has no bounds');

  final clamped = pdfBoundsOfPoints(
    const [PdfPoint(-0.2, -0.3), PdfPoint(1.4, 1.6)],
  );
  check(
    clamped != null &&
        clamped.left == 0 &&
        clamped.top == 0 &&
        clamped.right == 1 &&
        clamped.bottom == 1,
    'stroke bounds stay inside the page',
  );

  final ink = annotation(
    kind: PdfAnnotationKind.ink,
    points: points,
    strokeWidth: 0.006,
    rect: const NormalizedRect(0.19, 0.29, 0.27, 0.22),
  );
  checkClose(ink.effectiveStrokeWidth, 0.006, 'a custom pen width wins');
  check(ink.startPoint == points.first, 'the first point starts the stroke');
  check(ink.endPoint == points.last, 'the last point ends the stroke');
  final inkJson = ink.toJson();
  final inkRound = PdfAnnotation.fromJson(inkJson);
  check(inkRound.points.length == 3, 'an ink path keeps every point');
  check(inkRound.points[1] == points[1], 'ink points keep their coordinates');
  checkClose(inkRound.strokeWidth, 0.006, 'ink keeps its pen width');

  final label = annotation(
    kind: PdfAnnotationKind.text,
    fontScale: 0.034,
    textAlign: PdfTextAlign.right,
    color: 0xFF2E9E5B,
  );
  final labelRound = PdfAnnotation.fromJson(label.toJson());
  checkClose(labelRound.fontScale, 0.034, 'text keeps its font scale');
  check(
    labelRound.textAlign == PdfTextAlign.right,
    'text keeps its alignment',
  );
  check(labelRound.effectiveColor == 0xFF2E9E5B, 'text keeps its colour');

  final shape = annotation(
    kind: PdfAnnotationKind.shape,
    shape: PdfShapeKind.ellipse,
  );
  final shapeRound = PdfAnnotation.fromJson(shape.toJson());
  check(shapeRound.shape == PdfShapeKind.ellipse, 'a shape keeps its geometry');
  check(
    PdfAnnotation.fromJson(annotation().toJson()).shape ==
        PdfShapeKind.rectangle,
    'a plain annotation defaults to a rectangle',
  );

  final hostile = PdfAnnotation.fromJson({
    'id': 'hostile',
    'page': 0,
    'kind': 'ink',
    'rect': [0, 0, 0.2, 0.2],
    'points': [
      [-1, -1],
      [2, 2],
      ['bad', 0.5],
      [0.5],
    ],
    'strokeWidth': 9,
    'fontScale': 9,
    'align': 'diagonal',
    'shape': 'triangle',
    'createdAt': '2026-10-30T12:00:00.000Z',
  });
  check(
    hostile.points.length == 2,
    'a hostile path drops malformed points instead of failing',
  );
  check(
    hostile.points.every((p) => p.x >= 0 && p.x <= 1 && p.y >= 0 && p.y <= 1),
    'hostile points are clamped to the page',
  );
  checkClose(hostile.strokeWidth, 0.08, 'a pen width above the cap is clamped');
  checkClose(hostile.fontScale, 0.25, 'a font scale above the cap is clamped');
  check(
    hostile.textAlign == PdfTextAlign.center,
    'an unknown alignment falls back to centre',
  );
  check(
    hostile.shape == PdfShapeKind.rectangle,
    'an unknown shape falls back to a rectangle',
  );
}

void _annotationCodec() {
  final list = [
    annotation(),
    annotation(id: 'a2', kind: PdfAnnotationKind.highlight, opacity: 0.55),
    annotation(
      id: 'a3',
      kind: PdfAnnotationKind.image,
      mediaPath: '/data/app/p.png',
      mediaName: 'p.png',
      mediaBytes: 12,
    ),
  ];
  final encoded = encodePdfAnnotations(list);
  final decoded = decodePdfAnnotations(encoded);
  check(decoded.length == list.length, 'codec keeps every annotation');
  var same = decoded.length == list.length;
  for (var i = 0; i < decoded.length && i < list.length; i++) {
    if (!_sameAnnotation(decoded[i], list[i])) same = false;
  }
  check(same, 'codec round-trips every annotation field');

  final damaged = jsonEncode([
    {
      'id': 'good',
      'page': 0,
      'kind': 'highlight',
      'rect': [0, 0, 0.2, 0.2],
      'createdAt': '2026-01-01T00:00:00.000Z',
    },
    {
      'id': 'bad-type',
      'page': 0,
      'rect': [0, 0, 0.2, 0.2],
      'createdAt': 123
    },
    {
      'id': 5,
      'page': 0,
      'rect': [0, 0, 0.2, 0.2]
    },
  ]);
  final survivors = decodePdfAnnotations(damaged);
  check(survivors.length == 1, 'one damaged annotation does not drop the rest');
  check(survivors.single.id == 'good', 'the healthy annotation survives');

  check(decodePdfAnnotations(null).isEmpty, 'null decodes to an empty list');
  check(decodePdfAnnotations('  ').isEmpty, 'blank text decodes to empty');
  check(decodePdfAnnotations('not json').isEmpty, 'garbage decodes to empty');
  check(decodePdfAnnotations('{}').isEmpty, 'a JSON object decodes to empty');
  check(decodePdfAnnotations('[]').isEmpty, 'an empty array decodes to empty');

  check(
    pdfAnnotationsStoreKey('doc-1') == 'pdf.studio.annotations.v1.doc-1',
    'the store key is namespaced per document',
  );
  check(
    pdfAnnotationsStoreKey('   ') == 'pdf.studio.annotations.v1.session',
    'a blank document key uses a session key',
  );
}

void _zipRoundTrip() {
  final manifest =
      utf8.encode('{"format":"zaker.pdf-studio","ملاحظة":"مرحبا"}');
  final media = Uint8List.fromList([0, 1, 2, 250, 255]);
  final entries = [
    ZipArchiveEntry('manifest.json', manifest),
    ZipArchiveEntry('source.pdf', Uint8List.fromList('%PDF-1.7'.codeUnits)),
    ZipArchiveEntry('attachments/a1.mp3', media),
    ZipArchiveEntry('notes/ملاحظة.txt', Uint8List(0)),
  ];
  final when = DateTime.utc(2026, 10, 30, 12);
  final bytes = buildStoredZip(entries, modified: when);

  check(
    bytes[0] == 0x50 && bytes[1] == 0x4b && bytes[2] == 3 && bytes[3] == 4,
    'the archive starts with a local file header',
  );
  final tail = bytes.sublist(bytes.length - 22, bytes.length);
  check(
    tail[0] == 0x50 && tail[1] == 0x4b && tail[2] == 5 && tail[3] == 6,
    'the archive ends with an end-of-central-directory record',
  );

  final archive = readStoredZip(bytes);
  check(archive.length == entries.length, 'every entry is read back');
  check(
    utf8.decode(archive['manifest.json']!) == utf8.decode(manifest),
    'the manifest bytes survive the round-trip',
  );
  check(
    utf8.decode(archive['source.pdf']!) == '%PDF-1.7',
    'the source PDF survives the round-trip',
  );
  check(
    archive['attachments/a1.mp3']!.length == media.length &&
        archive['attachments/a1.mp3']![3] == 250,
    'binary media survives the round-trip',
  );
  check(
    archive['notes/ملاحظة.txt']!.isEmpty,
    'an empty entry survives the round-trip',
  );

  final again = buildStoredZip(entries, modified: when);
  check(
    bytes.length == again.length,
    'the same input produces the same archive length',
  );
  var identical = true;
  for (var i = 0; i < bytes.length; i++) {
    if (bytes[i] != again[i]) {
      identical = false;
      break;
    }
  }
  check(identical, 'the same input produces byte-identical archives');

  check(crc32('123456789'.codeUnits) == 0xCBF43926, 'CRC-32 matches the spec');
}

void _zipRejects() {
  final one = buildStoredZip(
    [
      ZipArchiveEntry('a.txt', Uint8List.fromList([1, 2, 3, 4])),
    ],
    modified: DateTime.utc(2026, 10, 30, 12),
  );

  final corrupt = Uint8List.fromList(one);
  final dataStart = 30 + 'a.txt'.length;
  corrupt[dataStart] ^= 0xff;
  check(
    throwsFormat(() => readStoredZip(corrupt)),
    'a corrupted entry is rejected by its CRC',
  );

  final truncated = Uint8List.sublistView(one, 0, one.length - 10);
  check(
    throwsFormat(() => readStoredZip(truncated)),
    'a truncated archive is rejected',
  );

  check(
    throwsFormat(
      () => readStoredZip(Uint8List.fromList(List<int>.filled(64, 0))),
    ),
    'a file that is not a ZIP is rejected',
  );

  final deflated = Uint8List.fromList(one);
  final central = _centralOffset(deflated);
  deflated[central + 10] = 8; // compression method: deflate
  check(
    throwsFormat(() => readStoredZip(deflated)),
    'compressed entries are rejected',
  );

  final encrypted = Uint8List.fromList(one);
  encrypted[central + 8] |= 1; // general-purpose flag bit 0
  check(
    throwsFormat(() => readStoredZip(encrypted)),
    'encrypted entries are rejected',
  );
}

void _zipUnsafety() {
  for (final name in [
    '',
    '/absolute.txt',
    '../escape.txt',
    'folder/../../escape.txt',
    'folder//empty.txt',
    '..\\escape.txt',
    'nul\u0000byte.txt',
  ]) {
    check(
      throwsFormat(
        () => buildStoredZip([ZipArchiveEntry(name, Uint8List(1))]),
      ),
      'the writer rejects the unsafe archive name "$name"',
    );
  }

  // The reader runs the same name check, so a hand-edited archive cannot
  // smuggle a traversal path into the package. Both the local header and the
  // central directory carry the name, hence both are rewritten.
  final safe = buildStoredZip(
    [
      ZipArchiveEntry('safe', Uint8List.fromList([9]))
    ],
    modified: DateTime.utc(2026, 10, 30, 12),
  );
  final evil = Uint8List.fromList(safe);
  final central = _centralOffset(evil);
  const traversal = [0x2e, 0x2e, 0x2f, 0x78]; // ../x
  for (var i = 0; i < traversal.length; i++) {
    evil[30 + i] = traversal[i];
    evil[central + 46 + i] = traversal[i];
  }
  check(
    throwsFormat(() => readStoredZip(evil)),
    'the reader rejects a traversal name inside the archive',
  );
}

/// Offset of the central directory, read from the end record.
int _centralOffset(Uint8List bytes) {
  for (var cursor = bytes.length - 22; cursor >= 0; cursor--) {
    if (bytes[cursor] == 0x50 &&
        bytes[cursor + 1] == 0x4b &&
        bytes[cursor + 2] == 5 &&
        bytes[cursor + 3] == 6) {
      return ByteData.sublistView(bytes, cursor, cursor + 22)
          .getUint32(16, Endian.little);
    }
  }
  throw StateError('no end record');
}
