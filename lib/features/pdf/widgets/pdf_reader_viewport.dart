/// The tiled page viewport of the native reader.
///
/// Android's `PdfRenderer` paints one PNG tile per request; this widget decides
/// which normalized page rect each visible page needs, requests it at the right
/// pixel scale, caches the bytes in a bounded [PdfTileCache], and paints the
/// arrivals with [PdfPageView].
///
/// The viewport never logs document content and never closes the native
/// handle — `PdfReaderScreen` owns that.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/pdf/pdf_annotations.dart';
import '../../../core/pdf/pdf_page_geometry.dart';
import '../../../core/pdf/pdf_render_channel.dart';
import '../../../core/pdf/pdf_tile_cache.dart';
import '../../../providers/pdf_providers.dart';

import 'pdf_page_view.dart';

/// Vertical space between pages in continuous mode.
const double _pageGap = 8;

const double _minZoom = 1;
const double _maxZoom = 5;

/// Longest-edge cap passed to the native renderer.
const int _maxTilePixels = 2048;

/// How many times a tile render may be retried before it is marked failed.
const int _maxTileAttempts = 2;

/// Renders one document: continuous by default, one page at a time otherwise.
class PdfReaderViewport extends ConsumerStatefulWidget {
  const PdfReaderViewport({
    super.key,
    required this.handle,
    required this.geometry,
    required this.initialPage,
    required this.onPageChanged,
    this.vertical = true,
    this.nightMode = false,
    this.quarterTurns = 0,
    this.initialZoom = 1,
    this.onZoomChanged,
    this.highlights = const [],
    this.highlightPage,
    this.annotations = const [],
    this.onPageLongPress,
    this.onAnnotationTap,
    this.pageTool = PdfPageTool.none,
    this.toolColor = 0xFF4779FF,
    this.toolOpacity = 1,
    this.toolStrokeWidth = 0.004,
    this.eraserRadius = 0.02,
    this.toolShape = PdfShapeKind.rectangle,
    this.onStrokeEnd,
    this.onRectDrag,
    this.onTapPoint,
    this.onErasePoint,
    this.onEraseStart,
    this.onEraseEnd,
  });

  final PdfRendererHandle handle;

  /// One geometry per page, in page order.
  final List<PdfPageGeometry> geometry;

  /// The zero-based page to show first and to jump to when it changes.
  final int initialPage;

  /// Called when scrolling or paging settles on another page.
  final ValueChanged<int> onPageChanged;

  /// Continuous scrolling when true, one page at a time when false.
  final bool vertical;

  /// Dims tiles with a warm colour matrix; geometry is untouched.
  final bool nightMode;

  /// Quarter turns applied to every page (0–3).
  final int quarterTurns;

  /// Starting zoom; 1 is fit-width, 5 is five times fit-width.
  final double initialZoom;

  /// Called when pinch zoom changes the scale.
  final ValueChanged<double>? onZoomChanged;

  /// Search hits to paint over the page in [highlightPage].
  final List<NormalizedRect> highlights;

  /// The page [highlights] belong to.
  final int? highlightPage;

  /// Every studio annotation for the document; the viewport shows the ones
  /// whose [PdfAnnotation.pageIndex] matches the page it is building.
  final List<PdfAnnotation> annotations;

  /// A long press on a page, with the point in unrotated page coordinates.
  final void Function(int pageIndex, NormalizedRect point)? onPageLongPress;

  /// A tap on a sticky note, media card or image.
  final ValueChanged<PdfAnnotation>? onAnnotationTap;

  /// The active drawing tool, applied to every page.
  final PdfPageTool pageTool;
  final int toolColor;
  final double toolOpacity;
  final double toolStrokeWidth;
  final double eraserRadius;
  final PdfShapeKind toolShape;

  /// A finished freehand stroke on [pageIndex].
  final void Function(int pageIndex, List<PdfPoint> points)? onStrokeEnd;

  /// A finished arrow/shape drag on [pageIndex].
  final void Function(int pageIndex, PdfPoint start, PdfPoint end)? onRectDrag;

  /// A tap on [pageIndex] while a tap tool is active.
  final void Function(int pageIndex, PdfPoint point)? onTapPoint;

  /// One eraser sample on [pageIndex].
  final void Function(int pageIndex, PdfPoint point)? onErasePoint;

  final ValueChanged<int>? onEraseStart;
  final ValueChanged<int>? onEraseEnd;

  @override
  PdfReaderViewportState createState() => PdfReaderViewportState();
}

class PdfReaderViewportState extends ConsumerState<PdfReaderViewport>
    with WidgetsBindingObserver {
  final PdfTileCache _cache = PdfTileCache();
  final Map<int, Uint8List> _tiles = {};
  final Map<int, NormalizedRect> _tileSources = {};
  final Map<int, PdfTileKey> _requestedKeys = {};
  final Map<int, PdfTileKey> _inFlight = {};
  final Map<int, PdfTileKey> _pending = {};
  final Map<int, NormalizedRect> _pendingSources = {};
  final Map<int, int> _requestGenerations = {};
  final Map<int, Offset> _pointerPositions = {};
  final Map<int, int> _tileAttempts = {};
  final Set<int> _failedTiles = {};
  final Set<Timer> _retryTimers = {};

  final ScrollController _verticalScroll = ScrollController();
  final ScrollController _horizontalScroll = ScrollController();
  late final PageController _pageController = PageController(
    initialPage: widget.initialPage,
  );

  late double _zoom = widget.initialZoom.clamp(_minZoom, _maxZoom);
  late int _page = widget.geometry.isEmpty
      ? 0
      : widget.initialPage.clamp(0, widget.geometry.length - 1);

  double _fitScale = 1;
  double _pixelRatio = 1;
  double _contentWidth = 0;
  Size? _lastViewport;

  /// How far the single-page view has scrolled into the current page.
  double _pageScrollX = 0;
  double _pageScrollY = 0;

  bool _pinching = false;
  double _pinchStartDistance = 0;
  double _pinchStartZoom = 1;
  int _generation = 0;

  bool get _oddTurns => widget.quarterTurns.isOdd;

  /// Pages whose decoded tile is still held in memory. Test hook.
  @visibleForTesting
  Set<int> get retainedTilePages => _tiles.keys.toSet();

  /// Pages whose tile could not be rendered at all. Test hook.
  @visibleForTesting
  Set<int> get failedTilePages => Set.unmodifiable(_failedTiles);

  /// Bytes held by the tile cache. Test hook.
  @visibleForTesting
  int get cachedTileBytes => _cache.bytes;

  @override
  void didHaveMemoryPressure() {
    handleMemoryPressure();
  }

  /// Drops everything this reader can rebuild from the native renderer.
  ///
  /// The tiles already in flight are not cancelled — the native executor has
  /// accepted them — so a visible page is repainted as soon as its render
  /// returns rather than staying blank.
  @visibleForTesting
  void handleMemoryPressure() {
    _cache.clear();
    _tiles.clear();
    _tileSources.clear();
    _requestedKeys.clear();
    _pending.clear();
    _pendingSources.clear();
    _failedTiles.clear();
    _tileAttempts.clear();
    PaintingBinding.instance.imageCache
      ..clear()
      ..clearLiveImages();
    if (mounted) setState(() {});
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _verticalScroll.addListener(_onVerticalScroll);
    _horizontalScroll.addListener(_onHorizontalScroll);
    // Opening at a saved page should show that page, not the first one.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToPage(widget.initialPage);
    });
  }

  @override
  void didUpdateWidget(PdfReaderViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.initialZoom != widget.initialZoom) {
      _zoom = widget.initialZoom.clamp(_minZoom, _maxZoom);
      widget.onZoomChanged?.call(_zoom);
    }
    if (oldWidget.quarterTurns != widget.quarterTurns ||
        oldWidget.vertical != widget.vertical ||
        oldWidget.initialZoom != widget.initialZoom) {
      _requestedKeys.clear();
      // Zoom, rotation and mode are the user asking for a fresh look, so the
      // pages that ran out of attempts get them again.
      _failedTiles.clear();
      _tileAttempts.clear();
      final viewport = _lastViewport;
      if (viewport != null) _scheduleRequests(viewport);
    }
    if (oldWidget.vertical != widget.vertical) _jumpToPage(_page);
    if (oldWidget.initialPage != widget.initialPage &&
        widget.initialPage != _page) {
      _jumpToPage(widget.initialPage);
    }
  }

  @override
  void dispose() {
    _generation += 1;
    WidgetsBinding.instance.removeObserver(this);
    for (final timer in _retryTimers) {
      timer.cancel();
    }
    _retryTimers.clear();
    _cache.clear();
    _verticalScroll.removeListener(_onVerticalScroll);
    _horizontalScroll.removeListener(_onHorizontalScroll);
    _verticalScroll.dispose();
    _horizontalScroll.dispose();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    _pixelRatio = MediaQuery.devicePixelRatioOf(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.hasBoundedWidth ? constraints.maxWidth : screen.width;
        final height = constraints.hasBoundedHeight
            ? constraints.maxHeight
            : screen.height;
        final viewport = Size(width, height);
        _lastViewport = viewport;
        if (widget.geometry.isEmpty) return const SizedBox.shrink();
        _fitScale = widget.geometry.first.fitScale(width);
        _contentWidth = widget.geometry
            .map(
              (geometry) => _displayGeometry(geometry)
                  .displayWidth(fitScale: _fitScale, zoom: _zoom),
            )
            .fold<double>(0, (widest, page) => math.max(widest, page));
        _contentWidth = math.max(_contentWidth, viewport.width);
        _scheduleRequests(viewport);
        return Listener(
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerEnd,
          onPointerCancel: _onPointerEnd,
          child: widget.vertical ? _continuousPages(viewport) : _singlePages(),
        );
      },
    );
  }

  Widget _continuousPages(Size viewport) {
    final count = widget.geometry.length;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: SingleChildScrollView(
        key: const PageStorageKey<String>('pdf-reader-horizontal'),
        scrollDirection: Axis.horizontal,
        controller: _horizontalScroll,
        child: SizedBox(
          width: _contentWidth,
          height: viewport.height,
          child: ListView.builder(
            key: const PageStorageKey<String>('pdf-reader-pages'),
            controller: _verticalScroll,
            itemCount: count,
            itemBuilder: (context, index) => Padding(
              padding: EdgeInsets.only(
                bottom: index == count - 1 ? 0 : _pageGap,
              ),
              child: Center(child: _pageView(index)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _singlePages() {
    final count = widget.geometry.length;
    return PageView.builder(
      key: const PageStorageKey<String>('pdf-reader-page-view'),
      controller: _pageController,
      itemCount: count,
      onPageChanged: (index) {
        if (index == _page) return;
        setState(() => _page = index);
        _pageScrollX = 0;
        _pageScrollY = 0;
        widget.onPageChanged(index);
      },
      itemBuilder: (context, index) => Center(
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            // Only the page on screen contributes offsets; the PageView keeps
            // its neighbours built, and their scroll positions are stale.
            if (index != _page) return false;
            final metrics = notification.metrics;
            if (metrics.axis == Axis.horizontal) {
              _pageScrollX = metrics.pixels;
            } else {
              _pageScrollY = metrics.pixels;
            }
            // Panning a zoomed page exposes a region no tile covers; without
            // this the reader scrolls into white until the finger lifts.
            final viewport = _lastViewport;
            if (viewport != null) _scheduleRequests(viewport);
            return false;
          },
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SingleChildScrollView(child: _pageView(index)),
          ),
        ),
      ),
    );
  }

  Widget _pageView(int index) {
    return RepaintBoundary(
      child: PdfPageView(
        geometry: widget.geometry[index],
        fitScale: _fitScale,
        zoom: _zoom,
        quarterTurns: widget.quarterTurns,
        nightMode: widget.nightMode,
        tile: _tiles[index],
        source: _tileSources[index],
        highlights:
            widget.highlightPage == index ? widget.highlights : const [],
        annotations: [
          for (final annotation in widget.annotations)
            if (annotation.pageIndex == index) annotation,
        ],
        onLongPress: widget.onPageLongPress == null
            ? null
            : (point) => widget.onPageLongPress!(index, point),
        onAnnotationTap: widget.onAnnotationTap,
        tool: widget.pageTool,
        toolColor: widget.toolColor,
        toolOpacity: widget.toolOpacity,
        toolStrokeWidth: widget.toolStrokeWidth,
        eraserRadius: widget.eraserRadius,
        shape: widget.toolShape,
        onStrokeEnd: widget.onStrokeEnd == null
            ? null
            : (points) => widget.onStrokeEnd!(index, points),
        onRectDrag: widget.onRectDrag == null
            ? null
            : (start, end) => widget.onRectDrag!(index, start, end),
        onTapPoint: widget.onTapPoint == null
            ? null
            : (point) => widget.onTapPoint!(index, point),
        onErasePoint: widget.onErasePoint == null
            ? null
            : (point) => widget.onErasePoint!(index, point),
        onEraseStart: widget.onEraseStart == null
            ? null
            : () => widget.onEraseStart!(index),
        onEraseEnd:
            widget.onEraseEnd == null ? null : () => widget.onEraseEnd!(index),
      ),
    );
  }

  /// The page as laid out on screen: swapped for odd quarter turns.
  PdfPageGeometry _displayGeometry(PdfPageGeometry geometry) {
    if (!_oddTurns) return geometry;
    return PdfPageGeometry(
      widthPoints: geometry.heightPoints,
      heightPoints: geometry.widthPoints,
    );
  }

  /// A page's height in the continuous list, after rotation.
  ///
  /// [PdfPageView] lays [geometry] out and swaps the outer box for odd turns,
  /// so the height on screen is always the display height — swapping here as
  /// well would count each rotated page as its unrotated height.
  double _pageExtent(int index) {
    final display = _displayGeometry(widget.geometry[index]);
    return display.displayHeight(fitScale: _fitScale, zoom: _zoom);
  }

  /// How far the page list has scrolled above [index].
  double _pageTop(int index) {
    var top = 0.0;
    for (var i = 0; i < index; i++) {
      top += _pageExtent(i) + _pageGap;
    }
    return top;
  }

  /// A page's left edge inside the horizontally scrollable content.
  double _pageLeft(int index) {
    final display = _displayGeometry(widget.geometry[index]);
    final width = display.displayWidth(fitScale: _fitScale, zoom: _zoom);
    return math.max(0, (_contentWidth - width) / 2);
  }

  void _onVerticalScroll() {
    final viewport = _lastViewport;
    if (viewport == null || !widget.vertical) return;
    _scheduleRequests(viewport);
    final index = _pageAtOffset(_verticalScroll.offset + viewport.height / 2);
    if (index == _page) return;
    setState(() => _page = index);
    widget.onPageChanged(index);
  }

  /// Sideways panning in continuous mode exposes a column no tile covers.
  ///
  /// Single-page mode scrolls through its own nested views and reports
  /// through the [NotificationListener] in [_singlePages] instead.
  void _onHorizontalScroll() {
    final viewport = _lastViewport;
    if (viewport == null || !widget.vertical) return;
    _scheduleRequests(viewport);
  }

  int _pageAtOffset(double offset) {
    final count = widget.geometry.length;
    if (count == 0) return 0;
    var top = 0.0;
    for (var i = 0; i < count; i++) {
      if (offset < top + _pageExtent(i) + _pageGap) return i;
      top += _pageExtent(i) + _pageGap;
    }
    return count - 1;
  }

  void _jumpToPage(int raw) {
    final count = widget.geometry.length;
    if (count == 0) return;
    final index = raw.clamp(0, count - 1);
    _page = index;
    _pageScrollX = 0;
    _pageScrollY = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.vertical) {
        if (!_verticalScroll.hasClients) return;
        final target = _pageTop(index)
            .clamp(0.0, _verticalScroll.position.maxScrollExtent);
        _verticalScroll.jumpTo(target);
      } else if (_pageController.hasClients) {
        _pageController.jumpToPage(index);
      }
    });
  }

  void _scheduleRequests(Size viewport) {
    if (_pinching) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _releaseOffscreenTiles(viewport);
      for (final index in _visiblePages(viewport)) {
        _requestTile(index, viewport);
      }
    });
  }

  /// Drops the bytes of pages that scrolled away.
  ///
  /// [_tiles] holds decoded PNGs, so leaving an entry per visited page would
  /// grow without limit and keep the tile cache from ever freeing anything.
  /// The bounded [PdfTileCache] still has them, so scrolling back is a hit.
  void _releaseOffscreenTiles(Size viewport) {
    final keep = _visiblePages(viewport).toSet();
    _tiles.removeWhere((index, _) => !keep.contains(index));
    _tileSources.removeWhere((index, _) => !keep.contains(index));
    _requestedKeys.removeWhere((index, _) => !keep.contains(index));
    // The in-flight render is not cancelled — the native executor already
    // accepted it — but a page that scrolled away no longer holds a pending
    // slot.
    _pending.removeWhere((index, _) => !keep.contains(index));
    _pendingSources.removeWhere((index, _) => !keep.contains(index));
    // A page that scrolled away gets a fresh chance when it comes back.
    _tileAttempts.removeWhere((index, _) => !keep.contains(index));
    _failedTiles.removeWhere((index) => !keep.contains(index));
  }

  /// The visible pages plus one neighbour on each side, for prefetching.
  List<int> _visiblePages(Size viewport) {
    final count = widget.geometry.length;
    if (count == 0) return const [];
    if (!widget.vertical) {
      final first = math.max(0, _page - 1);
      final last = math.min(count - 1, _page + 1);
      return [for (var i = first; i <= last; i++) i];
    }
    final offset = _verticalScroll.hasClients ? _verticalScroll.offset : 0.0;
    final visible = <int>[];
    var top = 0.0;
    for (var i = 0; i < count; i++) {
      final height = _pageExtent(i);
      if (top + height >= offset && top <= offset + viewport.height) {
        visible.add(i);
      }
      top += height + _pageGap;
    }
    final anchor = _page.clamp(0, count - 1);
    final first = math.max(0, (visible.isEmpty ? anchor : visible.first) - 1);
    final last = math.min(
      count - 1,
      (visible.isEmpty ? anchor : visible.last) + 1,
    );
    return [for (var i = first; i <= last; i++) i];
  }

  void _requestTile(int index, Size viewport) {
    // A page that used up its attempts keeps its mark until the zoom, rotation
    // or visibility changes; without this guard the scheduler would re-dispatch
    // it on every frame, forever.
    if (_failedTiles.contains(index)) return;
    final display = _displayGeometry(widget.geometry[index]);
    // Continuous mode scrolls a page inside a shared list; single-page mode
    // scrolls it inside its own two scroll views. Both end up as "how far into
    // the page is the viewport", which is what visibleSource expects.
    //
    // Only the page on screen contributes offsets in single-page mode: the
    // PageView keeps its neighbours built, but their scroll positions are
    // stale, so prefetching them with the current page's offset would request
    // a wrong tile for every pan.
    final currentPage = widget.vertical || index == _page;
    final scrollX = widget.vertical
        ? (_horizontalScroll.hasClients ? _horizontalScroll.offset : 0.0) -
            _pageLeft(index)
        : (currentPage ? _pageScrollX : 0.0);
    final scrollY = widget.vertical
        ? (_verticalScroll.hasClients ? _verticalScroll.offset : 0.0) -
            _pageTop(index)
        : (currentPage ? _pageScrollY : 0.0);
    final source = PdfPageGeometry.unrotateSource(
      display.visibleSource(
        scrollX: scrollX,
        scrollY: scrollY,
        viewportWidth: viewport.width,
        viewportHeight: viewport.height,
        fitScale: _fitScale,
        zoom: _zoom,
      ),
      widget.quarterTurns,
    );

    final rawScale = _zoom * _fitScale * _pixelRatio;
    final scale = (rawScale.clamp(0.05, 8.0) * 100).roundToDouble() / 100;
    final key = PdfTileKey.fromSource(
      pageIndex: index,
      scale: scale,
      source: source,
    );
    if (_requestedKeys[index] == key) return;

    if (_inFlight.containsKey(index)) {
      // One render per page at a time: the newest request waits here and is
      // issued when the current one returns or fails, so a pinch cannot push
      // a queue of renders onto the native executor.
      _pending[index] = key;
      _pendingSources[index] = source;
      return;
    }

    final cached = _cache.get(key);
    if (cached != null) {
      _requestedKeys[index] = key;
      _paint(index, cached, source);
      return;
    }

    _requestedKeys[index] = key;
    _dispatch(index, key, source);
  }

  void _dispatch(int index, PdfTileKey key, NormalizedRect source) {
    final generation = ++_generation;
    _requestGenerations[index] = generation;
    _inFlight[index] = key;
    unawaited(
      ref
          .read(pdfRenderChannelProvider)
          .render(
            handle: widget.handle.id,
            pageIndex: index,
            // From the key, so the native call and the cache entry agree.
            scale: key.scaleBucket / 100,
            source: source,
            maxPixels: _maxTilePixels,
          )
          .then((bytes) {
        _inFlight.remove(index);
        if (!mounted || _requestGenerations[index] != generation) {
          _drainPending(index);
          return;
        }
        _tileAttempts.remove(index);
        _cache.put(key, bytes);
        _paint(index, bytes, source);
        _drainPending(index);
      }).catchError((Object _) {
        _inFlight.remove(index);
        if (!mounted || _requestGenerations[index] != generation) {
          _drainPending(index);
          return;
        }
        // One failed tile is not a reader failure, but leaving its key
        // reserved would keep the page blank for the session.
        _retryTile(index);
        _drainPending(index);
      }),
    );
  }

  /// Issues the newest request that arrived while a page was rendering.
  void _drainPending(int index) {
    final key = _pending.remove(index);
    if (key == null) return;
    final source =
        _pendingSources.remove(index) ?? const NormalizedRect(0, 0, 1, 1);
    if (!mounted || _failedTiles.contains(index)) return;
    final cached = _cache.get(key);
    if (cached != null) {
      _requestedKeys[index] = key;
      _paint(index, cached, source);
      return;
    }
    _requestedKeys[index] = key;
    _dispatch(index, key, source);
  }

  /// Retries a tile that failed to render, a bounded number of times.
  ///
  /// Clearing the reserved key is what lets the next attempt through; after
  /// [_maxTileAttempts] the page is marked failed and keeps its placeholder.
  void _retryTile(int index) {
    _requestedKeys.remove(index);
    final attempts = (_tileAttempts[index] ?? 0) + 1;
    _tileAttempts[index] = attempts;
    if (attempts > _maxTileAttempts) {
      setState(() => _failedTiles.add(index));
      return;
    }
    late final Timer timer;
    timer = Timer(const Duration(milliseconds: 400), () {
      _retryTimers.remove(timer);
      if (!mounted) return;
      final viewport = _lastViewport;
      if (viewport == null) return;
      _requestTile(index, viewport);
    });
    _retryTimers.add(timer);
  }

  void _paint(int index, Uint8List bytes, NormalizedRect source) {
    setState(() {
      _tiles[index] = bytes;
      _tileSources[index] = source;
    });
  }

  void _onPointerDown(PointerDownEvent event) {
    _pointerPositions[event.pointer] = event.localPosition;
    if (_pointerPositions.length != 2) return;
    _pinching = true;
    _pinchStartZoom = _zoom;
    _pinchStartDistance = _pointerDistance() ?? 0;
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!_pointerPositions.containsKey(event.pointer)) return;
    _pointerPositions[event.pointer] = event.localPosition;
    if (!_pinching || _pinchStartDistance <= 0) return;
    final distance = _pointerDistance();
    if (distance == null) return;
    final next = (_pinchStartZoom * (distance / _pinchStartDistance)).clamp(
      _minZoom,
      _maxZoom,
    );
    if ((next - _zoom).abs() < 0.005) return;
    setState(() => _zoom = next);
    widget.onZoomChanged?.call(next);
  }

  void _onPointerEnd(PointerEvent event) {
    _pointerPositions.remove(event.pointer);
    if (_pointerPositions.length >= 2) return;
    _pinching = false;
    _pinchStartDistance = 0;
    _requestedKeys.clear();
    final viewport = _lastViewport;
    if (viewport == null) return;
    final page = _pageAtOffset(
      (_verticalScroll.hasClients ? _verticalScroll.offset : 0.0) +
          viewport.height / 2,
    );
    if (widget.vertical && page != _page) {
      setState(() => _page = page);
      widget.onPageChanged(page);
    }
    _scheduleRequests(viewport);
  }

  double? _pointerDistance() {
    if (_pointerPositions.length < 2) return null;
    final points = _pointerPositions.values.take(2).toList();
    return (points[0] - points[1]).distance;
  }
}
