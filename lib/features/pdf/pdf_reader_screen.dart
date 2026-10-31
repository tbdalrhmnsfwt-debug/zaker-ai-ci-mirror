/// The native PDF reader.
///
/// Android's `PdfRenderer` paints the pages (Task 9's viewport); this file
/// owns everything around the page: resolving which file to open, the
/// password prompt for locked documents, the chrome that hides on tap, and
/// the promise that a transient document leaves nothing behind.
///
/// Privacy notes:
///   * A password decrypts the document into a session temp copy and is never
///     stored, logged or put in a message; the copy is deleted on close.
///   * In-memory bytes are written to a session temp file and deleted when the
///     reader closes; library copies are never modified.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/local_store.dart';
import '../../core/pdf/pdf_annotations.dart';
import '../../core/pdf/pdf_export_manager.dart';
import '../../core/pdf/pdf_library_controller.dart';
import '../../core/pdf/pdf_library_store.dart';
import '../../core/pdf/pdf_page_geometry.dart';
import '../../core/pdf/pdf_render_channel.dart';
import '../../core/pdf/pdf_text_map.dart';
import '../../core/pdf/pdf_unlock.dart';
import '../../core/router.dart';
import '../../core/theme.dart';
import '../../core/theme/pdf_studio_theme.dart';
import '../../models/pdf_document.dart';
import '../../models/pdf_settings.dart';
import '../../providers/app_providers.dart';
import '../../providers/pdf_providers.dart';
import '../../widgets/common.dart';
import '../../widgets/tr_text.dart';
import 'widgets/pdf_page_view.dart';
import 'widgets/pdf_reader_viewport.dart';
import 'widgets/pdf_search_sheet.dart';
import 'widgets/pdf_settings_sheet.dart';
import 'widgets/pdf_studio_chrome.dart';
import 'widgets/pdf_tools_sheet.dart';

/// What the reader is allowed to do. Annotate and sign arrive with Plan 2.
enum PdfReaderMode { read }

/// Opens a PDF from the library, a path, or in-memory bytes.
class PdfReaderScreen extends ConsumerStatefulWidget {
  const PdfReaderScreen({
    super.key,
    this.path,
    this.title,
    this.bytes,
    this.fileName,
    this.docId,
    this.mode = PdfReaderMode.read,
  });

  /// A local file path to open.
  final String? path;

  /// The fallback title when no library entry names the document.
  final String? title;

  /// Bytes to render, materialised into a session temp file.
  final Uint8List? bytes;

  /// The picked file's name, used for titles and sharing.
  final String? fileName;

  /// The library entry to open, when the document belongs to «ملفاتي».
  final String? docId;

  final PdfReaderMode mode;

  @override
  ConsumerState<PdfReaderScreen> createState() => _PdfReaderScreenState();
}

class _PdfReaderScreenState extends ConsumerState<PdfReaderScreen> {
  late final PdfRenderChannel _channel;

  /// Captured in [initState] so [dispose] can flush the reading position
  /// without touching `ref` after the widget is gone.
  late final PdfLibraryController _library;
  PdfRendererHandle? _handle;
  String? _resolvedPath;
  File? _sessionFile;

  /// The decrypted copy of a protected document, deleted on close.
  File? _unlockedFile;
  late final PdfUnlocker _unlocker;
  PdfRenderFailure? _failure;
  Timer? _markTimer;
  bool _loading = true;
  bool _chromeVisible = true;
  int _quarterTurns = 0;

  /// Fit-width is 1; the viewport reports every pinch that changes it.
  double _zoom = 1;
  int _page = 0;
  int _attempts = 0;
  int _materialised = 0;
  List<PdfPageGeometry> _geometry = const [];
  List<NormalizedRect> _highlights = const [];
  int? _highlightPage;

  late final PdfLibraryStore _store;
  late final LocalStore _localStore;
  late final String _scratchKey;

  /// Live zoom for the top bar; pinching updates it without a full rebuild.
  final ValueNotifier<double> _zoomLabel = ValueNotifier<double>(1);

  List<PdfAnnotation> _annotations = const [];
  final List<List<PdfAnnotation>> _undoStack = [];
  final List<List<PdfAnnotation>> _redoStack = [];
  PdfAnnotationKind? _activeKind;
  int _highlightColor = 0xFFFFD84D;
  double _highlightOpacity = 0.55;
  bool _exporting = false;

  // Live tool state. The eraser is not a [PdfAnnotationKind]: it removes what
  // the other tools left behind, so it runs alongside them.
  bool _eraserActive = false;
  bool _eraserObjectMode = false;
  int _eraserSize = 1;
  PdfShapeKind _shapeKind = PdfShapeKind.rectangle;
  int _inkColor = 0xFF1E88E5;
  double _inkWidth = 0.004;
  int _textColor = 0xFF08152E;
  double _textScale = 0.024;
  PdfTextAlign _textAlign = PdfTextAlign.center;
  _StampPreset _stampPreset = _stampPresets.first;

  /// The annotation list from before one eraser gesture, committed to undo when
  /// the gesture ends and something was actually removed.
  List<PdfAnnotation>? _eraseSnapshot;

  /// The live text composer, when the text tool tapped a spot.
  _TextDraft? _textDraft;

  static const int _undoLimit = 50;

  static const List<double> _eraserRadii = [0.012, 0.024, 0.04];

  static const List<_StampPreset> _stampPresets = [
    _StampPreset('معتمد', 0xFF3DDC97),
    _StampPreset('صحيح', 0xFF4779FF),
    _StampPreset('مهم', 0xFFFFB020),
    _StampPreset('سؤال', 0xFF7C5CFF),
  ];

  /// The eraser's touch radius as a fraction of the page width.
  double get _eraserRadius =>
      _eraserRadii[_eraserSize.clamp(0, _eraserRadii.length - 1).toInt()];

  @override
  void initState() {
    super.initState();
    _channel = ref.read(pdfRenderChannelProvider);
    _unlocker = ref.read(pdfUnlockerProvider);
    _library = ref.read(pdfLibraryControllerProvider.notifier);
    _store = ref.read(pdfLibraryStoreProvider);
    _localStore = ref.read(localStoreProvider);
    _scratchKey =
        'local-${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    _loadAnnotations();
    // The first frame shows the loading state; the open starts right after.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _open();
    });
  }

  @override
  void dispose() {
    _markTimer?.cancel();
    _zoomLabel.dispose();
    _textDraft?.controller.dispose();
    if (widget.docId == null) {
      // Media belongs to annotations that are only in memory here; nothing
      // outside this screen can restore them, so they leave with it.
      _cleanupScratchMedia();
    }
    // The debounce loses the position when the reader closes within 500 ms;
    // flush whatever the reader is showing right now.
    //
    // The library notifies its listeners synchronously, and by now this
    // element is defunct, so [build] must not watch the whole index: it
    // watches only the entry's title and favourite flag, which this flush
    // does not change, so the notification cannot mark this element dirty.
    final id = widget.docId;
    final handle = _handle;
    if (id != null && handle != null) {
      unawaited(
        _library.markOpened(
          id,
          page: _page + 1,
          zoom: _zoom,
          quarterTurns: _quarterTurns,
        ),
      );
    }
    if (handle != null) unawaited(_channel.close(handle.id));
    _deleteQuietly(_sessionFile);
    _deleteQuietly(_unlockedFile);
    super.dispose();
  }

  /// Deletes [file], leaving anything a failed delete leaves to the startup
  /// sweep in `PdfLibraryStore.sweepTemp`.
  void _deleteQuietly(File? file) {
    if (file == null) return;
    try {
      if (file.existsSync()) file.deleteSync();
    } on FileSystemException {
      // Best effort: a temp file must never stop the reader from closing.
    }
  }

  /// Opens the resolved file.
  Future<void> _open() async {
    if (!mounted) return;
    setState(() {
      _loading = true;
      _failure = null;
    });
    final String? path;
    try {
      path = _resolvePath();
    } on FileSystemException {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.storage;
      });
      return;
    }
    if (path == null) {
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.corrupt;
      });
      return;
    }
    _resolvedPath = path;
    try {
      final handle = await _channel.open(path);
      if (!mounted) {
        unawaited(_channel.close(handle.id));
        return;
      }
      if (handle.pageCount <= 0) {
        // A zero-page file cannot be shown, and clamping against it throws
        // inside setState; the handle must not outlive the attempt either.
        unawaited(_channel.close(handle.id));
        setState(() {
          _handle = null;
          _loading = false;
          _failure = PdfRenderFailure.corrupt;
        });
        return;
      }
      final entry = _entry;
      final lastPage = entry?.lastPage ?? 1;
      setState(() {
        _handle = handle;
        _loading = false;
        _failure = null;
        _page = lastPage.clamp(1, handle.pageCount) - 1;
        _quarterTurns = entry?.lastQuarterTurns ?? 0;
        _zoom = entry?.lastZoom ?? 1;
        _geometry = [
          for (final page in handle.pages)
            PdfPageGeometry(
              widthPoints: page.widthPoints,
              heightPoints: page.heightPoints,
            ),
        ];
      });
      _zoomLabel.value = _zoom;
      _scheduleMarkOpened();
    } on PdfRenderException catch (error) {
      if (!mounted) return;
      switch (error.failure) {
        case PdfRenderFailure.passwordRequired:
        case PdfRenderFailure.wrongPassword:
          setState(() => _loading = false);
          await _promptPassword(
            wrong: error.failure == PdfRenderFailure.wrongPassword,
          );
        default:
          setState(() {
            _loading = false;
            _failure = error.failure;
          });
      }
    } on Object {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.unavailable;
      });
    }
  }

  /// Retries after a failure.
  ///
  /// The attempt counter resets here: after three wrong passwords the user may
  /// still remember the right one, and the retry button must offer the prompt
  /// again instead of re-showing the same error forever.
  Future<void> _retry() {
    _attempts = 0;
    return _open();
  }

  /// Asks for the document password. Three failures stop the loop.
  Future<void> _promptPassword({required bool wrong}) async {
    if (_attempts >= 3) {
      setState(() => _failure = PdfRenderFailure.wrongPassword);
      return;
    }
    _attempts += 1;
    final password = await _askPassword(wrong: wrong);
    if (!mounted) return;
    if (password == null) {
      setState(() => _failure = PdfRenderFailure.passwordRequired);
      return;
    }
    await _unlockWith(password);
  }

  /// Decrypts the document into a session copy and opens that copy.
  ///
  /// `PdfRenderer` cannot take a password below Android 15, so the password is
  /// answered here rather than by the platform: the copy is what both the
  /// renderer and the text extractor see. Nothing about it is kept longer than
  /// the reader — [dispose] deletes it and the store sweeps the directory at
  /// startup.
  Future<void> _unlockWith(String password) async {
    final source = _sourcePath();
    if (source == null) {
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.corrupt;
      });
      return;
    }
    final store = ref.read(pdfLibraryStoreProvider);
    final noise = Random.secure().nextInt(1 << 24).toRadixString(16);
    final target = store.sessionTempFile(
      'unlocked-${DateTime.now().microsecondsSinceEpoch}-$noise',
    );
    final bool unlocked;
    try {
      unlocked = await _unlocker(
        input: File(source),
        password: password,
        output: target,
      );
    } on FileSystemException {
      // A decrypt that failed midway may have left a partial copy behind; it
      // must not outlive the attempt that produced it.
      _deleteQuietly(target);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.storage;
      });
      return;
    } on Object {
      // The decryptor throws on documents it cannot parse at all. That is not
      // a wrong password — re-prompting would loop forever on a broken file —
      // so the reader reports the document instead.
      _deleteQuietly(target);
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failure = PdfRenderFailure.corrupt;
      });
      return;
    }
    if (!mounted) return;
    if (!unlocked) {
      _deleteQuietly(target);
      await _promptPassword(wrong: true);
      return;
    }
    _deleteQuietly(_unlockedFile);
    _unlockedFile = target;
    await _open();
  }

  Future<String?> _askPassword({required bool wrong}) async {
    // The text is captured as it changes rather than held in a controller:
    // a controller disposed when `showDialog` returns is still being read by
    // the field while the dialog's exit animation rebuilds it.
    var typed = '';
    return showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const TrText('الملف محمي بكلمة سر'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TrText(
              wrong
                  ? 'كلمة السر مش صح — جرّب تاني.'
                  : 'اكتب كلمة سر الملف عشان نعرضه على الجهاز.',
            ),
            const SizedBox(height: ZakerSpacing.md),
            TextFormField(
              autofocus: true,
              obscureText: true,
              textDirection: TextDirection.ltr,
              textInputAction: TextInputAction.done,
              onChanged: (value) => typed = value,
              onFieldSubmitted: (value) => Navigator.of(context).pop(value),
              decoration: const InputDecoration(hintText: 'كلمة السر'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const TrText('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(typed),
            child: const TrText('فتح'),
          ),
        ],
      ),
    );
  }

  /// The file to open: the decrypted copy once the password is known, the
  /// source file before that.
  String? _resolvePath() {
    final unlocked = _unlockedFile;
    if (unlocked != null && unlocked.existsSync()) return unlocked.path;
    return _sourcePath();
  }

  /// The file the user opened, before any decryption.
  ///
  /// Sharing and retrying a password use this one, so the protected original
  /// never leaves the device decrypted.
  String? _sourcePath() {
    final docId = widget.docId;
    if (docId != null) {
      final file = ref.read(pdfLibraryStoreProvider).baseFile(docId);
      return file.existsSync() ? file.path : null;
    }
    if (widget.bytes != null) {
      final session = _sessionFile ??= _writeSessionFile(widget.bytes!);
      return session.path;
    }
    final path = widget.path;
    if (path == null || path.isEmpty) return null;
    return path;
  }

  /// Materialises in-memory bytes for the native renderer.
  File _writeSessionFile(Uint8List bytes) {
    final store = ref.read(pdfLibraryStoreProvider);
    final noise = Random.secure().nextInt(1 << 24).toRadixString(16);
    final id =
        'session-${DateTime.now().microsecondsSinceEpoch}-${_materialised++}-$noise';
    final file = store.sessionTempFile(id);
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes, flush: true);
    _sessionFile = file;
    return file;
  }

  PdfDocumentEntry? get _entry {
    final id = widget.docId;
    if (id == null) return null;
    for (final entry in ref.read(pdfLibraryControllerProvider).entries) {
      if (entry.id == id) return entry;
    }
    return null;
  }

  void _scheduleMarkOpened() {
    final id = widget.docId;
    if (id == null) return;
    _markTimer?.cancel();
    _markTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      unawaited(
        _library.markOpened(
          id,
          page: _page + 1,
          zoom: _zoom,
          quarterTurns: _quarterTurns,
        ),
      );
    });
  }

  void _toggleChrome() {
    setState(() => _chromeVisible = !_chromeVisible);
  }

  Future<void> _toggleFavorite(PdfDocumentEntry entry) {
    return ref
        .read(pdfLibraryControllerProvider.notifier)
        .setFavorite(entry.id, !entry.favorite);
  }

  Future<void> _jumpToPage(int pageCount) async {
    // See [_askPassword]: the typed text is captured as it changes so nothing
    // has to be disposed while the dialog is still animating out.
    var typed = '${_page + 1}';
    final target = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const TrText('روح لصفحة'),
        content: TextFormField(
          initialValue: typed,
          autofocus: true,
          keyboardType: TextInputType.number,
          onChanged: (value) => typed = value,
          onFieldSubmitted: (value) =>
              Navigator.of(context).pop(int.tryParse(value.trim())),
          decoration: InputDecoration(hintText: '1 — $pageCount'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const TrText('إلغاء'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(int.tryParse(typed.trim())),
            child: const TrText('انتقال'),
          ),
        ],
      ),
    );
    if (target == null || !mounted) return;
    setState(() => _page = target.clamp(1, pageCount) - 1);
    _scheduleMarkOpened();
  }

  /// Opens in-document search over the resolved file.
  Future<void> _openSearch() async {
    final handle = _handle;
    final path = _resolvedPath;
    if (handle == null || path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final textMap = PdfTextMap.fromFile(file, pageCount: handle.pageCount);
    if (!mounted) return;
    await showPdfSearchSheet(
      context,
      textMap: textMap,
      onJump: (match) {
        Navigator.of(context).pop();
        _jumpToMatch(match);
      },
    );
  }

  void _jumpToMatch(PdfTextMatch match) {
    final count = _handle?.pageCount ?? 1;
    setState(() {
      _page = match.pageIndex.clamp(0, count - 1);
      _highlightPage = match.pageIndex;
      _highlights = [match.bounds];
    });
    _scheduleMarkOpened();
  }

  Future<void> _shareFile() async {
    // The original, never the decrypted session copy.
    final path = _sourcePath();
    if (path == null) return;
    final file = File(path);
    if (!file.existsSync()) return;
    final entry = _entry;
    await Share.shareXFiles(
      [XFile(path)],
      subject: entry?.displayName ??
          widget.title ??
          widget.fileName ??
          'zaker-document.pdf',
    );
  }

  // ------------------------------------------------------------------ studio

  /// The folder that owns this document's copied media. Library documents use
  /// their catalog id; an unsaved document gets a session folder that leaves
  /// with the screen.
  String get _docKey => widget.docId ?? _scratchKey;

  void _loadAnnotations() {
    final id = widget.docId;
    if (id == null) return;
    final raw = _localStore.getString(pdfAnnotationsStoreKey(id));
    if (raw == null) return;
    try {
      _annotations = decodePdfAnnotations(raw);
    } on Object {
      // Corrupt annotations must never stop the document from opening.
      _annotations = const [];
    }
  }

  void _persistAnnotations() {
    final id = widget.docId;
    if (id == null) return;
    unawaited(
      _localStore
          .setString(
            pdfAnnotationsStoreKey(id),
            encodePdfAnnotations(_annotations),
          )
          .catchError((Object _) {}),
    );
  }

  void _setAnnotations(List<PdfAnnotation> next) {
    _undoStack.add(_annotations);
    if (_undoStack.length > _undoLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    setState(() => _annotations = next);
    _persistAnnotations();
  }

  void _undoAnnotation() {
    if (_undoStack.isEmpty) return;
    final previous = _undoStack.removeLast();
    _redoStack.add(_annotations);
    setState(() => _annotations = previous);
    _persistAnnotations();
  }

  void _redoAnnotation() {
    if (_redoStack.isEmpty) return;
    final next = _redoStack.removeLast();
    _undoStack.add(_annotations);
    setState(() => _annotations = next);
    _persistAnnotations();
  }

  void _addAnnotation({
    required int pageIndex,
    required PdfAnnotationKind kind,
    required NormalizedRect rect,
    String? id,
    String text = '',
    String? mediaPath,
    String mediaName = '',
    int mediaBytes = 0,
    int durationMs = 0,
    int color = 0,
    double? opacity,
    List<PdfPoint> points = const [],
    double? strokeWidth,
    double? fontScale,
    PdfTextAlign? textAlign,
    PdfShapeKind? shape,
  }) {
    final annotation = PdfAnnotation(
      id: id ?? _newAnnotationId(),
      pageIndex: pageIndex,
      kind: kind,
      rect: rect.clampToPage(),
      color: color != 0
          ? color
          : (kind == PdfAnnotationKind.highlight ? _highlightColor : 0),
      opacity: opacity ??
          (kind == PdfAnnotationKind.highlight ? _highlightOpacity : 1),
      text: text,
      mediaPath: mediaPath,
      mediaName: mediaName,
      mediaBytes: mediaBytes,
      durationMs: durationMs,
      points: points,
      strokeWidth: strokeWidth ?? 0,
      fontScale: fontScale ?? 0,
      textAlign: textAlign ?? PdfTextAlign.center,
      shape: shape ?? PdfShapeKind.rectangle,
      createdAt: DateTime.now(),
    );
    _setAnnotations([..._annotations, annotation]);
  }

  String _newAnnotationId() {
    final stamp = DateTime.now().microsecondsSinceEpoch.toRadixString(36);
    final noise = Random().nextInt(1 << 20).toRadixString(36);
    return 'a$stamp$noise';
  }

  /// A default-sized rectangle for [kind], anchored at the long-pressed point.
  NormalizedRect _rectFor(PdfAnnotationKind kind, NormalizedRect point) {
    final (width, height) = switch (kind) {
      PdfAnnotationKind.highlight ||
      PdfAnnotationKind.underline ||
      PdfAnnotationKind.strike =>
        (0.42, 0.035),
      PdfAnnotationKind.ink => (0.34, 0.08),
      PdfAnnotationKind.note => (0.32, 0.10),
      PdfAnnotationKind.text => (0.36, 0.09),
      PdfAnnotationKind.image => (0.36, 0.22),
      PdfAnnotationKind.stamp => (0.22, 0.055),
      PdfAnnotationKind.arrow => (0.28, 0.12),
      PdfAnnotationKind.shape => (0.28, 0.16),
      PdfAnnotationKind.audio => (0.42, 0.075),
      PdfAnnotationKind.video => (0.46, 0.11),
    };
    final left = point.left.clamp(0.0, 1.0 - width).toDouble();
    final top = (point.top - height / 2).clamp(0.0, 1.0 - height).toDouble();
    return NormalizedRect(left, top, width, height);
  }

  Future<void> _onPageLongPress(
    int pageIndex,
    NormalizedRect point,
  ) async {
    final kind = _activeKind;
    if (kind == null) {
      await _openTools();
      return;
    }
    final rect = _rectFor(kind, point);
    switch (kind) {
      case PdfAnnotationKind.text:
        final text = await _askText(
          title: 'إضافة نص',
          hint: 'اكتب النص اللي عايز يظهر على الصفحة',
        );
        if (text == null || !mounted || text.trim().isEmpty) return;
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          text: text.trim(),
        );
      case PdfAnnotationKind.note:
        final text = await _askText(
          title: 'ملاحظة لاصقة',
          hint: 'اكتب الملاحظة',
        );
        if (text == null || !mounted || text.trim().isEmpty) return;
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          text: text.trim(),
        );
      case PdfAnnotationKind.stamp:
        final text = await _askText(
          title: 'نص الختم',
          initial: 'تم',
          hint: 'تم',
        );
        if (text == null || !mounted) return;
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          text: text.trim().isEmpty ? 'تم' : text.trim(),
        );
      case PdfAnnotationKind.image:
      case PdfAnnotationKind.audio:
      case PdfAnnotationKind.video:
        await _insertMedia(kind, pageIndex, rect);
      case PdfAnnotationKind.shape:
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          shape: _shapeKind,
        );
      case PdfAnnotationKind.highlight:
      case PdfAnnotationKind.underline:
      case PdfAnnotationKind.strike:
      case PdfAnnotationKind.ink:
      case PdfAnnotationKind.arrow:
        _addAnnotation(pageIndex: pageIndex, kind: kind, rect: rect);
    }
  }

  Future<String?> _askText({
    required String title,
    String initial = '',
    String hint = '',
  }) {
    var typed = initial;
    return showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: TrText(title),
        content: TextFormField(
          initialValue: initial,
          autofocus: true,
          minLines: 1,
          maxLines: 4,
          textDirection: TextDirection.rtl,
          onChanged: (value) => typed = value,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const TrText('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(typed),
            child: const TrText('إضافة'),
          ),
        ],
      ),
    );
  }

  Future<void> _insertMedia(
    PdfAnnotationKind kind,
    int pageIndex,
    NormalizedRect rect,
  ) async {
    final type = switch (kind) {
      PdfAnnotationKind.image => FileType.image,
      PdfAnnotationKind.audio => FileType.audio,
      _ => FileType.video,
    };
    PlatformFile? file;
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: type,
        withData: true,
      );
      file = picked?.files.single;
    } on Object {
      if (mounted) _toast('مقدرناش نفتح اختيار الملفات.');
      return;
    }
    if (file == null) return;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      try {
        bytes = await File(file.path!).readAsBytes();
      } on Object {
        bytes = null;
      }
    }
    if (bytes == null || bytes.isEmpty) {
      if (mounted) _toast('مقدرناش نقرأ الملف.');
      return;
    }
    final id = _newAnnotationId();
    final target = _store.annotationAsset(
      _docKey,
      '$id.${_extensionOf(file.name)}',
    );
    try {
      await target.parent.create(recursive: true);
      await target.writeAsBytes(bytes, flush: true);
    } on Object {
      if (mounted) _toast('مقدرناش نحفظ الملف.');
      return;
    }
    if (!mounted) return;
    _addAnnotation(
      id: id,
      pageIndex: pageIndex,
      kind: kind,
      rect: rect,
      mediaPath: target.path,
      mediaName: file.name,
      mediaBytes: bytes.length,
      durationMs: kind == PdfAnnotationKind.video ? _videoDurationMs(bytes) : 0,
    );
  }

  /// Reads the duration from an MP4/MOV `mvhd` box without a media dependency.
  ///
  /// Only the timeline header is needed: the player itself lives outside the
  /// app, but the card can still show a real length. Unknown containers return
  /// zero, which the card renders as no duration.
  static int _videoDurationMs(Uint8List bytes) {
    for (var i = 0; i + 24 < bytes.length; i++) {
      if (bytes[i] != 0x6D || // m
          bytes[i + 1] != 0x76 || // v
          bytes[i + 2] != 0x68 || // h
          bytes[i + 3] != 0x64) {
        continue;
      }
      final data = i + 4;
      try {
        if (bytes[data] == 1) {
          final timescale = _u32(bytes, data + 16);
          final duration = _u64(bytes, data + 20);
          if (timescale == 0 || duration <= 0) return 0;
          return (duration * 1000 / timescale).round();
        }
        final timescale = _u32(bytes, data + 8);
        final duration = _u32(bytes, data + 12);
        if (timescale == 0 || duration <= 0) return 0;
        return (duration * 1000 / timescale).round();
      } on RangeError {
        return 0;
      }
    }
    return 0;
  }

  static int _u32(Uint8List bytes, int offset) =>
      (bytes[offset] << 24) |
      (bytes[offset + 1] << 16) |
      (bytes[offset + 2] << 8) |
      bytes[offset + 3];

  static int _u64(Uint8List bytes, int offset) =>
      (_u32(bytes, offset) << 32) | _u32(bytes, offset + 4);

  static String _extensionOf(String name) {
    final dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) return 'bin';
    final value = name.substring(dot + 1).toLowerCase();
    return RegExp(r'^[a-z0-9]{1,8}$').hasMatch(value) ? value : 'bin';
  }

  Future<void> _editAnnotation(PdfAnnotation annotation) async {
    if (annotation.kind.hasMedia) {
      await _openMedia(annotation);
      return;
    }
    final canEditText = annotation.kind == PdfAnnotationKind.note ||
        annotation.kind == PdfAnnotationKind.text ||
        annotation.kind == PdfAnnotationKind.stamp;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: TrText(canEditText ? 'تعديل المحتوى' : 'التعليق'),
        content: Text(
          canEditText
              ? (annotation.text.isEmpty ? 'مفيش نص.' : annotation.text)
              : '${_annotationKindLabel(annotation.kind)} — يمكنك حذفه.',
          textDirection: TextDirection.rtl,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const TrText('إغلاق'),
          ),
          if (canEditText)
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop('edit'),
              child: const TrText('تعديل'),
            ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('delete'),
            style: TextButton.styleFrom(
              foregroundColor: PdfStudioColors.pdfRed,
            ),
            child: const TrText('حذف'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      _removeAnnotation(annotation);
      return;
    }
    if (action == 'edit') {
      final text = await _askText(
        title: 'تعديل النص',
        initial: annotation.text,
        hint: 'اكتب النص',
      );
      if (text == null || !mounted) return;
      _setAnnotations([
        for (final item in _annotations)
          item.id == annotation.id ? item.copyWith(text: text.trim()) : item,
      ]);
    }
  }

  void _removeAnnotation(PdfAnnotation annotation) {
    _setAnnotations([
      for (final item in _annotations)
        if (item.id != annotation.id) item,
    ]);
  }

  // ------------------------------------------------------------ interaction

  /// The tool the pages should apply to touches right now.
  PdfPageTool get _pageTool {
    if (_eraserActive) {
      return _eraserObjectMode
          ? PdfPageTool.eraseObject
          : PdfPageTool.eraseStroke;
    }
    return switch (_activeKind) {
      PdfAnnotationKind.ink => PdfPageTool.ink,
      PdfAnnotationKind.highlight => PdfPageTool.highlight,
      PdfAnnotationKind.underline => PdfPageTool.underline,
      PdfAnnotationKind.strike => PdfPageTool.strike,
      PdfAnnotationKind.arrow => PdfPageTool.arrow,
      PdfAnnotationKind.shape => PdfPageTool.shape,
      PdfAnnotationKind.image => PdfPageTool.image,
      PdfAnnotationKind.text => PdfPageTool.text,
      PdfAnnotationKind.stamp => PdfPageTool.stamp,
      _ => PdfPageTool.none,
    };
  }

  int get _toolColor {
    if (_eraserActive) return 0xFF8A94A6;
    return switch (_activeKind) {
      PdfAnnotationKind.highlight => _highlightColor,
      PdfAnnotationKind.ink => _inkColor,
      PdfAnnotationKind.arrow => 0xFFFFB020,
      _ => 0xFF4779FF,
    };
  }

  double get _toolOpacity =>
      _activeKind == PdfAnnotationKind.highlight ? _highlightOpacity : 1;

  double get _toolStrokeWidth =>
      _activeKind == PdfAnnotationKind.ink ? _inkWidth : 0.004;

  void _onStrokeEnd(int pageIndex, List<PdfPoint> points) {
    final kind = _activeKind;
    if (_eraserActive || kind == null || points.length < 2) return;
    if (kind == PdfAnnotationKind.ink) {
      final bounds = pdfBoundsOfPoints(points, padding: _inkWidth * 0.5);
      if (bounds == null) return;
      _addAnnotation(
        pageIndex: pageIndex,
        kind: kind,
        rect: bounds,
        points: List<PdfPoint>.unmodifiable(points),
        color: _inkColor,
        strokeWidth: _inkWidth,
      );
      return;
    }
    if (kind == PdfAnnotationKind.highlight ||
        kind == PdfAnnotationKind.underline ||
        kind == PdfAnnotationKind.strike) {
      final bounds = _bandBounds(points);
      if (bounds == null) return;
      _addAnnotation(pageIndex: pageIndex, kind: kind, rect: bounds);
    }
  }

  /// The band a marker drag covers, with a floor so a straight swipe over one
  /// line stays visible.
  NormalizedRect? _bandBounds(List<PdfPoint> points) {
    final raw = pdfBoundsOfPoints(points, padding: 0.006);
    if (raw == null) return null;
    return NormalizedRect(
      raw.left,
      raw.top,
      max(raw.width, 0.02),
      max(raw.height, 0.02),
    ).clampToPage();
  }

  void _onRectDrag(int pageIndex, PdfPoint start, PdfPoint end) {
    final kind = _activeKind;
    if (_eraserActive || kind == null) return;
    final bounds = pdfBoundsOfPoints([start, end], padding: 0.004);
    if (bounds == null) return;
    final rect = NormalizedRect(
      bounds.left,
      bounds.top,
      max(bounds.width, 0.02),
      max(bounds.height, 0.02),
    ).clampToPage();
    switch (kind) {
      case PdfAnnotationKind.arrow:
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          points: [start, end],
          color: 0xFFFFB020,
        );
      case PdfAnnotationKind.shape:
        _addAnnotation(
          pageIndex: pageIndex,
          kind: kind,
          rect: rect,
          points: [start, end],
          shape: _shapeKind,
        );
      case PdfAnnotationKind.image:
        unawaited(_insertMedia(kind, pageIndex, rect));
      default:
        break;
    }
  }

  Future<void> _onPageTap(int pageIndex, PdfPoint point) async {
    if (_eraserActive) {
      _eraseObjectAt(pageIndex, point);
      return;
    }
    final kind = _activeKind;
    if (kind == PdfAnnotationKind.text) {
      _beginTextDraft(pageIndex, point);
    } else if (kind == PdfAnnotationKind.stamp) {
      _placeStamp(pageIndex, point);
    }
  }

  void _beginTextDraft(int pageIndex, PdfPoint point) {
    final previous = _textDraft;
    setState(() {
      _textDraft = _TextDraft(
        pageIndex: pageIndex,
        point: point,
        controller: TextEditingController(),
      );
    });
    if (previous != null) {
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => previous.controller.dispose(),
      );
    }
  }

  void _cancelTextDraft() {
    final draft = _textDraft;
    if (draft == null) return;
    setState(() => _textDraft = null);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => draft.controller.dispose(),
    );
  }

  void _commitTextDraft() {
    final draft = _textDraft;
    if (draft == null) return;
    final text = draft.controller.text.trim();
    if (text.isEmpty) {
      _toast('اكتب النص الأول.');
      return;
    }
    const width = 0.46;
    final height = (0.05 + _textScale * 2.4).clamp(0.06, 0.24).toDouble();
    final left = (draft.point.x - width / 2).clamp(0.0, 1 - width).toDouble();
    final top = (draft.point.y - height / 2).clamp(0.0, 1 - height).toDouble();
    _addAnnotation(
      pageIndex: draft.pageIndex,
      kind: PdfAnnotationKind.text,
      rect: NormalizedRect(left, top, width, height),
      text: text,
      color: _textColor,
      fontScale: _textScale,
      textAlign: _textAlign,
    );
    setState(() => _textDraft = null);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => draft.controller.dispose(),
    );
  }

  void _placeStamp(int pageIndex, PdfPoint point) {
    const width = 0.24;
    const height = 0.06;
    final left = (point.x - width / 2).clamp(0.0, 1 - width).toDouble();
    final top = (point.y - height / 2).clamp(0.0, 1 - height).toDouble();
    _addAnnotation(
      pageIndex: pageIndex,
      kind: PdfAnnotationKind.stamp,
      rect: NormalizedRect(left, top, width, height),
      text: _stampPreset.label,
      color: _stampPreset.color,
    );
    _toast('تم وضع ختم «${_stampPreset.label}».');
  }

  void _setEraserActive(bool active) {
    setState(() {
      _eraserActive = active;
      if (active) {
        _activeKind = null;
      } else {
        _eraserObjectMode = false;
      }
    });
    if (active && mounted) {
      _toast(
        _eraserObjectMode
            ? 'ممحاة العناصر: اضغط على العنصر نفسه لمسحه.'
            : 'ممحاة الرسم: مرّر على الرسم أو التظليل لمسحه.',
      );
    }
  }

  void _onEraseStart(int pageIndex) {
    _eraseSnapshot = _annotations;
  }

  void _onErasePoint(int pageIndex, PdfPoint point) {
    if (!_eraserActive || _eraserObjectMode) return;
    final radius = _eraserRadius;
    final kept = <PdfAnnotation>[];
    var changed = false;
    for (final annotation in _annotations) {
      if (annotation.pageIndex == pageIndex &&
          annotation.kind.isMark &&
          _touchHits(annotation, point, radius)) {
        changed = true;
        continue;
      }
      kept.add(annotation);
    }
    if (!changed) return;
    setState(() => _annotations = kept);
  }

  void _onEraseEnd(int pageIndex) {
    final snapshot = _eraseSnapshot;
    _eraseSnapshot = null;
    if (snapshot == null || identical(snapshot, _annotations)) return;
    _undoStack.add(snapshot);
    if (_undoStack.length > _undoLimit) _undoStack.removeAt(0);
    _redoStack.clear();
    _persistAnnotations();
    // The chrome reads the stack sizes for its undo/redo state.
    setState(() {});
  }

  /// Removes the topmost annotation under [point], for the object eraser.
  void _eraseObjectAt(int pageIndex, PdfPoint point) {
    for (var i = _annotations.length - 1; i >= 0; i--) {
      final annotation = _annotations[i];
      if (annotation.pageIndex != pageIndex) continue;
      final hit = annotation.kind.isMark
          ? _touchHits(annotation, point, max(_eraserRadius, 0.012))
          : _rectContains(annotation.rect, point);
      if (!hit) continue;
      _removeAnnotation(annotation);
      _toast('تم مسح ${_annotationKindLabel(annotation.kind)}.');
      return;
    }
    _toast('مفيش عنصر هنا. اضغط على العنصر نفسه.');
  }

  static bool _rectContains(NormalizedRect rect, PdfPoint point) =>
      point.x >= rect.left &&
      point.x <= rect.right &&
      point.y >= rect.top &&
      point.y <= rect.bottom;

  /// Whether [point] lands within [radius] of [annotation].
  static bool _touchHits(
    PdfAnnotation annotation,
    PdfPoint point,
    double radius,
  ) {
    final rect = annotation.rect;
    if (point.x < rect.left - radius ||
        point.x > rect.right + radius ||
        point.y < rect.top - radius ||
        point.y > rect.bottom + radius) {
      return false;
    }
    if (annotation.kind != PdfAnnotationKind.ink ||
        annotation.points.length < 2) {
      return true;
    }
    final threshold = radius + annotation.effectiveStrokeWidth / 2;
    for (var i = 1; i < annotation.points.length; i++) {
      if (_distanceToSegment(
            point,
            annotation.points[i - 1],
            annotation.points[i],
          ) <=
          threshold) {
        return true;
      }
    }
    return false;
  }

  static double _distanceToSegment(PdfPoint point, PdfPoint a, PdfPoint b) {
    final dx = b.x - a.x;
    final dy = b.y - a.y;
    final lengthSquared = dx * dx + dy * dy;
    if (lengthSquared <= 1e-9) return _distance(point, a);
    final t = (((point.x - a.x) * dx + (point.y - a.y) * dy) / lengthSquared)
        .clamp(0.0, 1.0);
    return _distance(point, PdfPoint(a.x + t * dx, a.y + t * dy));
  }

  static double _distance(PdfPoint a, PdfPoint b) =>
      sqrt(pow(a.x - b.x, 2) + pow(a.y - b.y, 2));

  Future<void> _clearPageAnnotations() async {
    final page = _page;
    final count = _annotations.where((a) => a.pageIndex == page).length;
    if (count == 0) {
      _toast('مفيش تعليقات على الصفحة دي.');
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const TrText('مسح تعليقات الصفحة'),
        content: TrText(
          'هيتم مسح $count تعليقًا من صفحة ${page + 1}. تقدر ترجّعهم بالتراجع.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const TrText('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: PdfStudioColors.pdfRed,
            ),
            child: const TrText('امسح'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _setAnnotations([
      for (final annotation in _annotations)
        if (annotation.pageIndex != page) annotation,
    ]);
    _toast('تم مسح $count تعليقًا من الصفحة ${page + 1}.');
  }

  Future<void> _openStampPicker() async {
    final picked = await PdfStudioTheme.showSheet<int>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TrText(
                'ملصق أو ختم',
                style: TextStyle(
                  color: PdfStudioColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              const TrText(
                'اختر ختمًا، وبعدها اضغط على مكانه في الصفحة.',
                style: TextStyle(
                  color: PdfStudioColors.muted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (var i = 0; i < _stampPresets.length; i++)
                    Material(
                      color: PdfStudioColors.surfaceAlt,
                      borderRadius: BorderRadius.circular(14),
                      child: InkWell(
                        onTap: () => Navigator.of(sheetContext).pop(i),
                        borderRadius: BorderRadius.circular(14),
                        child: Container(
                          width: 132,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 14,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Color(
                                _stampPresets[i].color | 0xFF000000,
                              ).withValues(alpha: 0.65),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                Icons.verified_rounded,
                                size: 18,
                                color: Color(
                                  _stampPresets[i].color | 0xFF000000,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TrText(
                                  _stampPresets[i].label,
                                  style: const TextStyle(
                                    color: PdfStudioColors.text,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 14),
              _StudioMenuTile(
                icon: Icons.add_photo_alternate_outlined,
                label: 'صورة مخصصة',
                onTap: () => Navigator.of(sheetContext).pop(-1),
              ),
            ],
          ),
        ),
      ),
    );
    if (!mounted || picked == null) return;
    if (picked < 0) {
      setState(() {
        _activeKind = PdfAnnotationKind.image;
        _eraserActive = false;
      });
      _toast('اسحب مستطيل مكان الصورة في الصفحة.');
      return;
    }
    setState(() {
      _activeKind = PdfAnnotationKind.stamp;
      _eraserActive = false;
      _stampPreset =
          _stampPresets[picked.clamp(0, _stampPresets.length - 1).toInt()];
    });
    _toast('اضغط على الصفحة لوضع «${_stampPreset.label}».');
  }

  Future<void> _insertNotebookPage() async {
    final choice = await showDialog<_NotebookChoice>(
      context: context,
      builder: (dialogContext) => const _NotebookDialog(),
    );
    if (choice == null || !mounted) return;
    _toast('بنجهّز الصفحة المسطرة…');
    try {
      final bytes = const PdfExportManager().buildNotebookPdf(
        style: choice.style,
        pageCount: choice.pageCount,
      );
      final name = 'notebook-${DateTime.now().millisecondsSinceEpoch}.pdf';
      final file = await _writeExport(name, bytes);
      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => PdfReaderScreen(
            path: file.path,
            title: 'صفحة مسطرة',
            fileName: name,
          ),
        ),
      );
    } on Object {
      if (mounted) _toast('مقدرناش نجهّز الصفحة المسطرة.');
    }
  }

  Future<void> _openMedia(PdfAnnotation annotation) async {
    final path = annotation.mediaPath;
    if (path == null || !File(path).existsSync()) {
      _toast('الملف المرفق مش موجود.');
      return;
    }
    final isImage = annotation.kind == PdfAnnotationKind.image;
    final isVideo = annotation.kind == PdfAnnotationKind.video;
    final action = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: TrText(_annotationKindLabel(annotation.kind)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isImage)
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Image.file(
                  File(path),
                  height: 150,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                ),
              )
            else
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    isVideo
                        ? Icons.play_circle_fill_rounded
                        : Icons.graphic_eq_rounded,
                    size: 42,
                    color: PdfStudioColors.cyanText,
                  ),
                  if (annotation.durationMs > 0) ...[
                    const SizedBox(width: 10),
                    TrText(_formatDuration(annotation.durationMs)),
                  ],
                ],
              ),
            const SizedBox(height: 10),
            TrText('الملف: ${annotation.mediaName}'),
            if (!isImage) ...[
              const SizedBox(height: 6),
              const TrText(
                'التشغيل بيتم في مشغل الجهاز لأن القارئ مش بيضم مشغل فيديو.',
                style: TextStyle(
                  fontSize: 11.5,
                  color: PdfStudioColors.muted,
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const TrText('إغلاق'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop('delete'),
            style: TextButton.styleFrom(
              foregroundColor: PdfStudioColors.pdfRed,
            ),
            child: const TrText('حذف'),
          ),
          if (!isImage)
            FilledButton.icon(
              onPressed: () => Navigator.of(dialogContext).pop('open'),
              icon: const Icon(Icons.open_in_new_rounded, size: 18),
              label: const TrText('فتح'),
            ),
        ],
      ),
    );
    if (!mounted) return;
    if (action == 'delete') {
      _removeAnnotation(annotation);
      return;
    }
    if (action == 'open') {
      await Share.shareXFiles([XFile(path)], subject: annotation.mediaName);
    }
  }

  static String _formatDuration(int milliseconds) {
    final total = (milliseconds / 1000).round();
    final minutes = total ~/ 60;
    final seconds = (total % 60).toString().padLeft(2, '0');
    return '$minutes:$seconds';
  }

  String get _hintMessage {
    if (_eraserActive) {
      return _eraserObjectMode
          ? 'اضغط على أي عنصر في الصفحة عشان تمسحه.'
          : 'مرّر الممحاة على الرسم أو التظليل عشان تمسحه.';
    }
    final kind = _activeKind;
    if (kind == null) return '';
    return switch (kind) {
      PdfAnnotationKind.ink => 'ارسم بإصبعك على الصفحة.',
      PdfAnnotationKind.highlight ||
      PdfAnnotationKind.underline ||
      PdfAnnotationKind.strike =>
        'اسحب على السطر عشان تحدّد ${_kindNoun(kind)}.',
      PdfAnnotationKind.arrow => 'اسحب من بداية السهم لنهايته.',
      PdfAnnotationKind.shape =>
        'اسحب على الصفحة لرسم ${_shapeNoun(_shapeKind)}.',
      PdfAnnotationKind.image => 'اسحب مستطيل مكان الصورة.',
      PdfAnnotationKind.text => 'اضغط على مكان النص عشان تكتبه.',
      PdfAnnotationKind.stamp => 'اضغط على مكان الختم «${_stampPreset.label}».',
      _ => 'اضغط مطوّل على مكان ${_kindNoun(kind)} في الصفحة.',
    };
  }

  static String _shapeNoun(PdfShapeKind shape) => switch (shape) {
        PdfShapeKind.rectangle => 'مستطيل',
        PdfShapeKind.ellipse => 'دائرة',
        PdfShapeKind.line => 'خط',
      };

  Future<void> _openTools() async {
    PdfStudioAction? pending;
    await showPdfToolsSheet(
      context,
      activeKind: _activeKind,
      onKind: (kind) => setState(() {
        _activeKind = kind;
        if (kind != null) _eraserActive = false;
      }),
      onAction: (action) {
        pending = action;
        Navigator.of(context).maybePop();
      },
      canUndo: _undoStack.isNotEmpty,
      canRedo: _redoStack.isNotEmpty,
      onUndo: _undoAnnotation,
      onRedo: _redoAnnotation,
      highlightColor: _highlightColor,
      highlightOpacity: _highlightOpacity,
      onHighlightColor: (value) => setState(() => _highlightColor = value),
      onHighlightOpacity: (value) => setState(() => _highlightOpacity = value),
      eraserActive: _eraserActive,
      eraserObjectMode: _eraserObjectMode,
      eraserSize: _eraserSize,
      onEraser: (value) => setState(() {
        _eraserActive = value;
        if (value) {
          _activeKind = null;
        } else {
          _eraserObjectMode = false;
        }
      }),
      onEraserObjectMode: (value) => setState(() {
        _eraserObjectMode = value;
        if (value) _eraserActive = true;
      }),
      onEraserSize: (value) => setState(() => _eraserSize = value),
      shape: _shapeKind,
      onShape: (value) => setState(() => _shapeKind = value),
    );
    if (!mounted || pending == null) return;
    await _runToolAction(pending!);
  }

  Future<void> _runToolAction(PdfStudioAction action) async {
    switch (action) {
      case PdfStudioAction.text:
        _activateTool(PdfAnnotationKind.text);
      case PdfStudioAction.image:
        _activateTool(PdfAnnotationKind.image);
      case PdfStudioAction.stamp:
        _activateTool(PdfAnnotationKind.stamp);
      case PdfStudioAction.stampPicker:
        await _openStampPicker();
      case PdfStudioAction.note:
        _activateTool(PdfAnnotationKind.note);
      case PdfStudioAction.arrow:
        _activateTool(PdfAnnotationKind.arrow);
      case PdfStudioAction.audio:
        _activateTool(PdfAnnotationKind.audio);
      case PdfStudioAction.video:
        _activateTool(PdfAnnotationKind.video);
      case PdfStudioAction.pages:
        _openPageGrid();
      case PdfStudioAction.notebook:
        await _insertNotebookPage();
      case PdfStudioAction.clearPage:
        await _clearPageAnnotations();
      case PdfStudioAction.search:
        await _openSearch();
      case PdfStudioAction.compress:
        unawaited(context.push(ZakerRoutes.pdfTools));
      case PdfStudioAction.ocr:
        unawaited(context.push(ZakerRoutes.scan));
      case PdfStudioAction.merge:
      case PdfStudioAction.split:
        _toast('الدمج والتقسيم محتاجين أكتر من مستند، ولسه مش متاحين هنا.');
      case PdfStudioAction.exportPdf:
        await _exportPdf();
      case PdfStudioAction.exportProject:
        await _exportProject();
    }
  }

  void _activateTool(PdfAnnotationKind kind) {
    setState(() {
      _activeKind = kind;
      _eraserActive = false;
    });
    _toast(_hintMessage);
  }

  void _openPageGrid() {
    final handle = _handle;
    if (handle == null) return;
    unawaited(
      showPdfPageGrid(
        context,
        pageCount: handle.pageCount,
        current: _page,
        onPick: _goToPage,
      ),
    );
  }

  void _goToPage(int raw) {
    final count = _handle?.pageCount;
    if (count == null || count <= 0) return;
    final index = raw.clamp(0, count - 1);
    if (index == _page) return;
    setState(() => _page = index);
    _scheduleMarkOpened();
  }

  void _applyZoom(double value) {
    final next = value.clamp(1.0, 5.0).toDouble();
    if ((next - _zoom).abs() < 0.005) return;
    setState(() => _zoom = next);
    _zoomLabel.value = next;
    _scheduleMarkOpened();
  }

  void _zoomBy(double delta) => _applyZoom(_zoom + delta);

  void _fitPage() => _applyZoom(1);

  Future<void> _openDocumentMenu() async {
    final isProtected = _unlockedFile != null;
    await PdfStudioTheme.showSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const TrText(
                'المستند',
                style: TextStyle(
                  color: PdfStudioColors.text,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 4),
              TrText(
                isProtected
                    ? 'المستند محمي؛ بعض الإجراءات مش متاحة.'
                    : 'إجراءات سريعة على الملف الحالي.',
                style: const TextStyle(
                  color: PdfStudioColors.muted,
                  fontSize: 12,
                ),
              ),
              const SizedBox(height: 14),
              _StudioMenuTile(
                icon: Icons.ios_share_rounded,
                label: 'مشاركة الملف',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_shareFile());
                },
              ),
              _StudioMenuTile(
                icon: Icons.picture_as_pdf_outlined,
                label: 'تصدير PDF مع الملاحظات',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_exportPdf());
                },
              ),
              _StudioMenuTile(
                icon: Icons.inventory_2_outlined,
                label: 'حزمة المشروع',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(_exportProject());
                },
              ),
              _StudioMenuTile(
                icon: Icons.grid_view_rounded,
                label: 'تنظيم الصفحات',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _openPageGrid();
                },
              ),
              _StudioMenuTile(
                icon: Icons.build_circle_outlined,
                label: 'أدوات PDF',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  unawaited(context.push(ZakerRoutes.pdfTools));
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _exportPdf() async {
    if (_exporting) {
      _toast('استنى التصدير الحالي يخلص.');
      return;
    }
    final source = _sourcePath();
    if (source == null) {
      _toast('الملف الأصلي مش موجود.');
      return;
    }
    if (_unlockedFile != null) {
      _toast('المستند محمي؛ التصدير متاح بعد إزالة الحماية.');
      return;
    }
    setState(() => _exporting = true);
    _toast('بنصدّر نسخة PDF بالملاحظات…');
    try {
      final sourceBytes = await File(source).readAsBytes();
      final media = await _readMediaBytes();
      final font = await _loadCairoFont();
      final flattened = const PdfExportManager().flattenPdf(
        sourceBytes: sourceBytes,
        annotations: _annotations,
        fontBytes: font,
        mediaById: media,
      );
      final file = await _writeExport(
        '${_exportBaseName()}-annotated.pdf',
        flattened,
      );
      await _shareExport(file, 'نسخة PDF مع الملاحظات');
    } on Object {
      if (mounted) _toast('مقدرناش نصدّر الملف.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _exportProject() async {
    if (_exporting) {
      _toast('استنى التصدير الحالي يخلص.');
      return;
    }
    final source = _sourcePath();
    if (source == null) {
      _toast('الملف الأصلي مش موجود.');
      return;
    }
    setState(() => _exporting = true);
    _toast('بنجهّز حزمة المشروع…');
    try {
      final sourceBytes = await File(source).readAsBytes();
      final media = await _readMediaBytes();
      final package = const PdfExportManager().buildProjectPackage(
        documentId: widget.docId ?? _scratchKey,
        documentName: _entry?.displayName ??
            widget.title ??
            widget.fileName ??
            'مشروع PDF',
        sourceBytes: sourceBytes,
        annotations: _annotations,
        mediaById: media,
        pageCount: _handle?.pageCount,
        lastPage: _page + 1,
        lastZoom: _zoom,
        quarterTurns: _quarterTurns,
      );
      final file = await _writeExport(
        '${_exportBaseName()}.zakerpdf',
        package,
      );
      await _shareExport(file, 'حزمة مشروع PDF');
    } on Object {
      if (mounted) _toast('مقدرناش نجهّز حزمة المشروع.');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<Map<String, List<int>>> _readMediaBytes() async {
    final media = <String, List<int>>{};
    for (final annotation in _annotations) {
      final path = annotation.mediaPath;
      if (path == null) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          media[annotation.id] = await file.readAsBytes();
        }
      } on Object {
        // A missing attachment still exports its card without the media.
        continue;
      }
    }
    return media;
  }

  Future<Uint8List?> _loadCairoFont() async {
    try {
      final data = await rootBundle.load('assets/fonts/CairoPdf-Regular.ttf');
      return data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
    } on Object {
      return null;
    }
  }

  Future<File> _writeExport(String name, Uint8List bytes) async {
    await _store.ensureReady();
    final file = _store.exportFile(name);
    await file.writeAsBytes(bytes, flush: true);
    return file;
  }

  Future<void> _shareExport(File file, String subject) {
    return Share.shareXFiles([XFile(file.path)], subject: subject);
  }

  String _exportBaseName() {
    final raw = _entry?.displayName ??
        widget.title ??
        widget.fileName ??
        'zaker-document';
    final cleaned = raw
        .replaceAll(RegExp(r'[\\/:*?"<>|]'), '_')
        .replaceFirst(RegExp(r'\.pdf$', caseSensitive: false), '')
        .trim();
    return cleaned.isEmpty ? 'zaker-document' : cleaned;
  }

  void _cleanupScratchMedia() {
    // Synchronous on purpose: [dispose] runs while the widget tree is going
    // away, and a pending asynchronous delete is not guaranteed to finish.
    try {
      final directory = _store.annotationDir(_scratchKey);
      if (directory.existsSync()) directory.deleteSync(recursive: true);
    } on Object {
      // Best effort: a leftover scratch folder is harmless.
    }
  }

  static String _kindNoun(PdfAnnotationKind kind) => switch (kind) {
        PdfAnnotationKind.highlight => 'التظليل',
        PdfAnnotationKind.underline => 'التسطير',
        PdfAnnotationKind.strike => 'الشطب',
        PdfAnnotationKind.ink => 'الرسم',
        PdfAnnotationKind.note => 'الملاحظة',
        PdfAnnotationKind.text => 'النص',
        PdfAnnotationKind.image => 'الصورة',
        PdfAnnotationKind.stamp => 'الختم',
        PdfAnnotationKind.arrow => 'السهم',
        PdfAnnotationKind.shape => 'الشكل',
        PdfAnnotationKind.audio => 'المقطع الصوتي',
        PdfAnnotationKind.video => 'الفيديو',
      };

  static String _annotationKindLabel(PdfAnnotationKind kind) => switch (kind) {
        PdfAnnotationKind.highlight => 'تظليل',
        PdfAnnotationKind.underline => 'تسطير',
        PdfAnnotationKind.strike => 'شطب',
        PdfAnnotationKind.ink => 'رسم حر',
        PdfAnnotationKind.note => 'ملاحظة لاصقة',
        PdfAnnotationKind.text => 'نص',
        PdfAnnotationKind.image => 'صورة',
        PdfAnnotationKind.stamp => 'ختم',
        PdfAnnotationKind.arrow => 'سهم',
        PdfAnnotationKind.shape => 'شكل',
        PdfAnnotationKind.audio => 'مقطع صوتي',
        PdfAnnotationKind.video => 'فيديو',
      };

  void _toast(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: TrText(message)));
  }

  @override
  Widget build(BuildContext context) {
    // The bar shows the entry's title and favourite flag, and whether the
    // document is still catalogued. Watch only those: watching the whole
    // index would also rebuild when [dispose] flushes the reading position,
    // and by then this element is already defunct.
    ref.watch(
      pdfLibraryControllerProvider.select((library) {
        final id = widget.docId;
        final entry = id == null ? null : library.entryById(id);
        return (entry?.displayName, entry?.favorite ?? false, entry != null);
      }),
    );
    final settings = ref.watch(pdfSettingsProvider);
    final entry = _entry;
    final handle = _handle;
    final vertical = settings.scrollMode == PdfScrollMode.vertical;
    final title =
        entry?.displayName ?? widget.title ?? widget.fileName ?? 'قارئ PDF';
    return Theme(
      data: PdfStudioTheme.dark(),
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: PdfStudioColors.background,
          body: Stack(
            children: [
              Positioned.fill(child: _body(context, settings)),
              if (_chromeVisible && handle != null)
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: PdfStudioTopBar(
                    title: title,
                    favorite: entry?.favorite ?? false,
                    canFavorite: entry != null,
                    page: _page + 1,
                    pageCount: handle.pageCount,
                    zoom: _zoomLabel,
                    onBack: () => Navigator.of(context).maybePop(),
                    onMenu: _openDocumentMenu,
                    onSearch: _openSearch,
                    onFavorite:
                        entry == null ? null : () => _toggleFavorite(entry),
                    onPreviousPage: () => _goToPage(_page - 1),
                    onNextPage: () => _goToPage(_page + 1),
                    onJump: () => _jumpToPage(handle.pageCount),
                    onZoomOut: () => _zoomBy(-0.25),
                    onZoomIn: () => _zoomBy(0.25),
                    onFit: _fitPage,
                  ),
                ),
              if (_chromeVisible && handle != null)
                Positioned(
                  right: ZakerSpacing.md,
                  bottom: 152,
                  child: PdfStudioViewControls(
                    vertical: vertical,
                    nightMode: settings.nightMode,
                    onMode: () =>
                        ref.read(pdfSettingsProvider.notifier).setScrollMode(
                              vertical
                                  ? PdfScrollMode.horizontal
                                  : PdfScrollMode.vertical,
                            ),
                    onRotate: () {
                      setState(
                        () => _quarterTurns = (_quarterTurns + 1) % 4,
                      );
                      _scheduleMarkOpened();
                    },
                    onNight: () => ref
                        .read(pdfSettingsProvider.notifier)
                        .setNightMode(!settings.nightMode),
                    onSettings: () => showPdfSettingsSheet(context),
                  ),
                ),
              if (_chromeVisible && handle != null)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: SafeArea(
                    top: false,
                    child: PdfStudioBottomChrome(
                      page: _page + 1,
                      pageCount: handle.pageCount,
                      onJump: () => _jumpToPage(handle.pageCount),
                      onScrub: (page) {
                        setState(() => _page = page - 1);
                        _scheduleMarkOpened();
                      },
                      canUndo: _undoStack.isNotEmpty,
                      canRedo: _redoStack.isNotEmpty,
                      onTools: _openTools,
                      onPages: _openPageGrid,
                      onUndo: _undoAnnotation,
                      onRedo: _redoAnnotation,
                      eraserActive: _eraserActive,
                      onEraser: () => _setEraserActive(!_eraserActive),
                    ),
                  ),
                ),
              if (_chromeVisible && (_eraserActive || _activeKind != null))
                Positioned(
                  top: MediaQuery.paddingOf(context).top + 112,
                  left: 16,
                  right: 16,
                  child: PdfStudioHintBanner(
                    message: _hintMessage,
                    onClose: () => setState(() {
                      _activeKind = null;
                      _eraserActive = false;
                    }),
                  ),
                ),
              if (_textDraft != null)
                Positioned.fill(
                  child: _TextComposer(
                    controller: _textDraft!.controller,
                    color: _textColor,
                    scale: _textScale,
                    align: _textAlign,
                    onColor: (value) => setState(() => _textColor = value),
                    onScale: (value) => setState(() => _textScale = value),
                    onAlign: (value) => setState(() => _textAlign = value),
                    onCancel: _cancelTextDraft,
                    onAdd: _commitTextDraft,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, PdfReaderSettings settings) {
    if (_failure != null) {
      return EmptyState(
        icon: Icons.error_outline_rounded,
        title: 'تعذّر فتح الملف',
        message: _failureMessage,
        action: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: _retry,
              icon: const Icon(Icons.refresh_rounded),
              label: const TrText('جرّب تاني'),
            ),
            if (_resolvedPath != null)
              TextButton.icon(
                onPressed: _shareFile,
                icon: const Icon(Icons.ios_share_rounded, size: 18),
                label: const TrText('شارك الملف'),
              ),
            TextButton(
              onPressed: () => Navigator.of(context).maybePop(),
              child: const TrText('رجوع'),
            ),
          ],
        ),
      );
    }
    if (_loading) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: ZakerSpacing.md),
            TrText('بنفتح الملف…'),
          ],
        ),
      );
    }
    if (_handle == null) {
      // No handle and no failure: the password prompt is open. A still
      // placeholder keeps the page calm underneath instead of a spinner that
      // would turn forever behind the dialog.
      return const EmptyState(
        icon: Icons.lock_outline_rounded,
        title: 'الملف مقفول',
        message: 'اكتب كلمة السر عشان نفتح الملف على الجهاز.',
      );
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _toggleChrome,
      child: ColoredBox(
        color: PdfStudioColors.background,
        child: PdfReaderViewport(
          handle: _handle!,
          geometry: _geometry,
          initialPage: _page,
          onPageChanged: (page) {
            if (page == _page) return;
            setState(() => _page = page);
            if (settings.haptics) HapticFeedback.lightImpact();
            _scheduleMarkOpened();
          },
          vertical: settings.scrollMode == PdfScrollMode.vertical,
          nightMode: settings.nightMode,
          quarterTurns: _quarterTurns,
          initialZoom: _zoom,
          onZoomChanged: (value) {
            _zoom = value;
            _zoomLabel.value = value;
            _scheduleMarkOpened();
          },
          highlights: _highlights,
          highlightPage: _highlightPage,
          annotations: _annotations,
          onPageLongPress: (page, point) =>
              unawaited(_onPageLongPress(page, point)),
          // With the object eraser active, a tap must reach the page instead of
          // opening the annotation it landed on.
          onAnnotationTap: _eraserActive
              ? null
              : (annotation) => unawaited(_editAnnotation(annotation)),
          pageTool: _pageTool,
          toolColor: _toolColor,
          toolOpacity: _toolOpacity,
          toolStrokeWidth: _toolStrokeWidth,
          eraserRadius: _eraserRadius,
          toolShape: _shapeKind,
          onStrokeEnd: _onStrokeEnd,
          onRectDrag: _onRectDrag,
          onTapPoint: (page, point) => unawaited(_onPageTap(page, point)),
          onErasePoint: _onErasePoint,
          onEraseStart: _onEraseStart,
          onEraseEnd: _onEraseEnd,
        ),
      ),
    );
  }

  String get _failureMessage {
    return switch (_failure) {
      PdfRenderFailure.passwordRequired ||
      PdfRenderFailure.wrongPassword =>
        'الملف محمي بكلمة سر ومقدرناش نفتحه.',
      PdfRenderFailure.passwordUnsupported =>
        'الملف محمي بكلمة سر، وفتحه محتاج أندرويد 15 أو أحدث.',
      PdfRenderFailure.unavailable => 'قارئ PDF مش متاح على الجهاز ده.',
      PdfRenderFailure.storage => 'مفيش مساحة كافية على الجهاز.',
      _ => 'الملف تالف أو مش مقروء.',
    };
  }
}

/// A built-in stamp the reader can drop on a page.
class _StampPreset {
  const _StampPreset(this.label, this.color);

  final String label;
  final int color;
}

/// The text composer's anchor and live controller.
class _TextDraft {
  _TextDraft({
    required this.pageIndex,
    required this.point,
    required this.controller,
  });

  final int pageIndex;
  final PdfPoint point;
  final TextEditingController controller;
}

/// The live text editor shown while the text tool has a tapped spot.
///
/// The controller belongs to the reader, so colour, size and alignment edits
/// rebuild this card without recreating the field or losing the cursor.
class _TextComposer extends StatelessWidget {
  const _TextComposer({
    required this.controller,
    required this.color,
    required this.scale,
    required this.align,
    required this.onColor,
    required this.onScale,
    required this.onAlign,
    required this.onCancel,
    required this.onAdd,
  });

  final TextEditingController controller;
  final int color;
  final double scale;
  final PdfTextAlign align;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onScale;
  final ValueChanged<PdfTextAlign> onAlign;
  final VoidCallback onCancel;
  final VoidCallback onAdd;

  static const List<int> _colors = [
    0xFF08152E,
    0xFF4779FF,
    0xFFE5484D,
    0xFF2E9E5B,
    0xFFFFB020,
  ];
  static const List<double> _sizes = [0.016, 0.024, 0.034];

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Material(
      color: selected
          ? PdfStudioColors.cyanText.withValues(alpha: 0.18)
          : PdfStudioColors.surfaceAlt,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  selected ? PdfStudioColors.cyanText : PdfStudioColors.stroke,
            ),
          ),
          child: TrText(
            label,
            style: TextStyle(
              color: selected ? PdfStudioColors.cyanText : PdfStudioColors.text,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xCC000712),
      child: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 430),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: PdfStudioColors.surface,
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: PdfStudioColors.stroke),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const TrText(
                      'إضافة نص',
                      style: TextStyle(
                        color: PdfStudioColors.text,
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: controller,
                      autofocus: true,
                      minLines: 1,
                      maxLines: 4,
                      textDirection: TextDirection.rtl,
                      textAlign: switch (align) {
                        PdfTextAlign.left => TextAlign.left,
                        PdfTextAlign.center => TextAlign.center,
                        PdfTextAlign.right => TextAlign.right,
                      },
                      style: TextStyle(
                        color: Color(color | 0xFF000000),
                        fontSize: (scale * 800).clamp(12.0, 34.0),
                        fontWeight: FontWeight.w600,
                      ),
                      decoration: InputDecoration(
                        hintText: 'اكتب النص هنا',
                        filled: true,
                        fillColor: PdfStudioColors.surfaceAlt,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                    const SizedBox(height: 14),
                    const TrText(
                      'الحجم',
                      style: TextStyle(
                        color: PdfStudioColors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (var i = 0; i < _sizes.length; i++)
                          _chip(
                            ['صغير', 'متوسط', 'كبير'][i],
                            (scale - _sizes[i]).abs() < 0.001,
                            () => onScale(_sizes[i]),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const TrText(
                      'اللون',
                      style: TextStyle(
                        color: PdfStudioColors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        for (final value in _colors)
                          GestureDetector(
                            onTap: () => onColor(value),
                            child: Container(
                              width: 28,
                              height: 28,
                              margin: const EdgeInsetsDirectional.only(end: 9),
                              decoration: BoxDecoration(
                                color: Color(value | 0xFF000000),
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: value == color
                                      ? Colors.white
                                      : Colors.transparent,
                                  width: 2,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    const TrText(
                      'المحاذاة',
                      style: TextStyle(
                        color: PdfStudioColors.muted,
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _chip('يمين', align == PdfTextAlign.right,
                            () => onAlign(PdfTextAlign.right)),
                        _chip('وسط', align == PdfTextAlign.center,
                            () => onAlign(PdfTextAlign.center)),
                        _chip('يسار', align == PdfTextAlign.left,
                            () => onAlign(PdfTextAlign.left)),
                      ],
                    ),
                    const SizedBox(height: 18),
                    Row(
                      children: [
                        TextButton(
                          onPressed: onCancel,
                          child: const TrText('إلغاء'),
                        ),
                        const Spacer(),
                        FilledButton.icon(
                          onPressed: onAdd,
                          icon: const Icon(Icons.check_rounded, size: 18),
                          label: const TrText('إضافة'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _NotebookChoice {
  const _NotebookChoice(this.style, this.pageCount);

  final PdfNotebookStyle style;
  final int pageCount;
}

/// Picks the paper style and page count for a generated notebook.
class _NotebookDialog extends StatefulWidget {
  const _NotebookDialog();

  @override
  State<_NotebookDialog> createState() => _NotebookDialogState();
}

class _NotebookDialogState extends State<_NotebookDialog> {
  PdfNotebookStyle _style = PdfNotebookStyle.ruled;
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const TrText('صفحة بيضاء مسطرة'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const TrText(
            'اختر شكل الصفحة، وبعدها اكتب أو ارسم عليها بكل أدوات الاستوديو.',
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final style in PdfNotebookStyle.values)
                ChoiceChip(
                  label: TrText(style.labelAr),
                  selected: _style == style,
                  onSelected: (_) => setState(() => _style = style),
                ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              const TrText('عدد الصفحات'),
              const Spacer(),
              IconButton(
                onPressed:
                    _pages > 1 ? () => setState(() => _pages -= 1) : null,
                icon: const Icon(Icons.remove_circle_outline_rounded),
              ),
              TrText('$_pages'),
              IconButton(
                onPressed:
                    _pages < 20 ? () => setState(() => _pages += 1) : null,
                icon: const Icon(Icons.add_circle_outline_rounded),
              ),
            ],
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const TrText('إلغاء'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(_NotebookChoice(_style, _pages)),
          child: const TrText('إنشاء'),
        ),
      ],
    );
  }
}

/// One row in the document menu sheet.
class _StudioMenuTile extends StatelessWidget {
  const _StudioMenuTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 13),
            child: Row(
              children: [
                Icon(icon, size: 20, color: PdfStudioColors.cyanText),
                const SizedBox(width: 11),
                Expanded(
                  child: TrText(
                    label,
                    style: const TextStyle(
                      color: PdfStudioColors.text,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const Icon(
                  Icons.chevron_left_rounded,
                  size: 19,
                  color: PdfStudioColors.muted,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
