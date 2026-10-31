/// The PDF Studio tool palette.
///
/// A single dark sheet groups every tool by what it does, so the reader's
/// chrome stays quiet. Picking an annotation tool does not draw immediately:
/// the reader asks the user to long-press the spot on the page, which keeps
/// scrolling and pinch-zoom untouched.
library;

import 'package:flutter/material.dart';

import '../../../core/pdf/pdf_annotations.dart';
import '../../../core/theme/pdf_studio_theme.dart';
import '../../../widgets/tr_text.dart';

/// Tools that act on the document rather than adding a mark.
enum PdfStudioAction {
  text,
  image,
  stamp,
  stampPicker,
  note,
  arrow,
  audio,
  video,
  pages,
  notebook,
  clearPage,
  compress,
  merge,
  split,
  ocr,
  search,
  exportPdf,
  exportProject,
}

/// Opens the studio tool sheet.
Future<void> showPdfToolsSheet(
  BuildContext context, {
  required PdfAnnotationKind? activeKind,
  required ValueChanged<PdfAnnotationKind?> onKind,
  required ValueChanged<PdfStudioAction> onAction,
  required bool canUndo,
  required bool canRedo,
  required VoidCallback onUndo,
  required VoidCallback onRedo,
  required int highlightColor,
  required double highlightOpacity,
  required ValueChanged<int> onHighlightColor,
  required ValueChanged<double> onHighlightOpacity,
  required bool eraserActive,
  required bool eraserObjectMode,
  required int eraserSize,
  required ValueChanged<bool> onEraser,
  required ValueChanged<bool> onEraserObjectMode,
  required ValueChanged<int> onEraserSize,
  required PdfShapeKind shape,
  required ValueChanged<PdfShapeKind> onShape,
}) {
  return PdfStudioTheme.showSheet<void>(
    context: context,
    // The sheet is its own route: reader state changes do not rebuild it, so
    // the toggles that stay open (eraser, shape, marker colour) mirror their
    // value locally and repaint through this builder.
    builder: (sheetContext) {
      var currentKind = activeKind;
      var markerColor = highlightColor;
      var markerOpacity = highlightOpacity;
      var eraserOn = eraserActive;
      var objectOnly = eraserObjectMode;
      var radiusStep = eraserSize;
      var currentShape = shape;
      return StatefulBuilder(
        builder: (context, setSheetState) => PdfToolsSheet(
          activeKind: currentKind,
          onKind: (kind) {
            currentKind = kind;
            onKind(kind);
            setSheetState(() {});
          },
          onAction: onAction,
          canUndo: canUndo,
          canRedo: canRedo,
          onUndo: onUndo,
          onRedo: onRedo,
          highlightColor: markerColor,
          highlightOpacity: markerOpacity,
          onHighlightColor: (value) {
            markerColor = value;
            onHighlightColor(value);
            setSheetState(() {});
          },
          onHighlightOpacity: (value) {
            markerOpacity = value;
            onHighlightOpacity(value);
            setSheetState(() {});
          },
          eraserActive: eraserOn,
          eraserObjectMode: objectOnly,
          eraserSize: radiusStep,
          onEraser: (value) {
            eraserOn = value;
            if (value) {
              currentKind = null;
            } else {
              objectOnly = false;
            }
            onEraser(value);
            setSheetState(() {});
          },
          onEraserObjectMode: (value) {
            objectOnly = value;
            if (value) eraserOn = true;
            onEraserObjectMode(value);
            setSheetState(() {});
          },
          onEraserSize: (value) {
            radiusStep = value;
            onEraserSize(value);
            setSheetState(() {});
          },
          shape: currentShape,
          onShape: (value) {
            currentShape = value;
            onShape(value);
            setSheetState(() {});
          },
        ),
      );
    },
  );
}

/// The sheet body: three tool groups and the undo/redo bar.
class PdfToolsSheet extends StatelessWidget {
  const PdfToolsSheet({
    super.key,
    required this.activeKind,
    required this.onKind,
    required this.onAction,
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
    required this.highlightColor,
    required this.highlightOpacity,
    required this.onHighlightColor,
    required this.onHighlightOpacity,
    required this.eraserActive,
    required this.eraserObjectMode,
    required this.eraserSize,
    required this.onEraser,
    required this.onEraserObjectMode,
    required this.onEraserSize,
    required this.shape,
    required this.onShape,
  });

  final PdfAnnotationKind? activeKind;
  final ValueChanged<PdfAnnotationKind?> onKind;
  final ValueChanged<PdfStudioAction> onAction;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final int highlightColor;
  final double highlightOpacity;
  final ValueChanged<int> onHighlightColor;
  final ValueChanged<double> onHighlightOpacity;

  /// Whether the eraser tool is the active tool.
  final bool eraserActive;

  /// Object mode removes whole annotations; stroke mode erases what it crosses.
  final bool eraserObjectMode;

  /// 0 = small, 1 = medium, 2 = large.
  final int eraserSize;
  final ValueChanged<bool> onEraser;
  final ValueChanged<bool> onEraserObjectMode;
  final ValueChanged<int> onEraserSize;

  /// The geometry the shape tool draws.
  final PdfShapeKind shape;
  final ValueChanged<PdfShapeKind> onShape;

  void _pick(BuildContext context, PdfAnnotationKind kind) {
    onKind(activeKind == kind ? null : kind);
    Navigator.of(context).pop();
  }

  void _act(BuildContext context, PdfStudioAction action) {
    onAction(action);
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.86,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsetsDirectional.fromSTEB(18, 0, 18, 12),
                children: [
                  Row(
                    children: [
                      Container(
                        width: 38,
                        height: 38,
                        decoration: BoxDecoration(
                          color: PdfStudioColors.violet.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Icon(
                          Icons.auto_fix_high_rounded,
                          color: PdfStudioColors.violetText,
                          size: 21,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            TrText(
                              'أدوات PDF',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                                color: PdfStudioColors.text,
                              ),
                            ),
                            SizedBox(height: 2),
                            TrText(
                              'اختر أداة، وبعدها اضغط مطوّل على مكانها في الصفحة.',
                              style: TextStyle(
                                fontSize: 11.5,
                                color: PdfStudioColors.muted,
                              ),
                            ),
                          ],
                        ),
                      ),
                      IconButton(
                        tooltip: 'قفل الأدوات',
                        onPressed: () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close_rounded),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  const _SectionTitle(
                    title: 'التعليقات والتحديد',
                    icon: Icons.edit_note_rounded,
                  ),
                  const SizedBox(height: 10),
                  _ToolGrid(
                    children: [
                      _ToolTile(
                        label: 'قلم حر',
                        icon: Icons.gesture_rounded,
                        selected: activeKind == PdfAnnotationKind.ink,
                        onTap: () => _pick(context, PdfAnnotationKind.ink),
                      ),
                      _ToolTile(
                        label: 'شطب',
                        icon: Icons.format_strikethrough_rounded,
                        selected: activeKind == PdfAnnotationKind.strike,
                        onTap: () => _pick(context, PdfAnnotationKind.strike),
                      ),
                      _ToolTile(
                        label: 'تسطير',
                        icon: Icons.format_underline_rounded,
                        selected: activeKind == PdfAnnotationKind.underline,
                        onTap: () =>
                            _pick(context, PdfAnnotationKind.underline),
                      ),
                      _ToolTile(
                        label: 'تظليل',
                        icon: Icons.border_color_rounded,
                        selected: activeKind == PdfAnnotationKind.highlight,
                        onTap: () =>
                            _pick(context, PdfAnnotationKind.highlight),
                      ),
                      _ToolTile(
                        label: 'ممحاة',
                        icon: Icons.auto_fix_normal_rounded,
                        selected: eraserActive,
                        onTap: () => onEraser(!eraserActive),
                      ),
                      _ToolTile(
                        label: 'مسح تعليقات الصفحة',
                        icon: Icons.delete_sweep_rounded,
                        onTap: () => _act(context, PdfStudioAction.clearPage),
                      ),
                    ],
                  ),
                  if (activeKind == PdfAnnotationKind.highlight) ...[
                    const SizedBox(height: 14),
                    _HighlightOptions(
                      color: highlightColor,
                      opacity: highlightOpacity,
                      onColor: onHighlightColor,
                      onOpacity: onHighlightOpacity,
                    ),
                  ],
                  if (eraserActive) ...[
                    const SizedBox(height: 14),
                    _EraserOptions(
                      objectMode: eraserObjectMode,
                      size: eraserSize,
                      onObjectMode: onEraserObjectMode,
                      onSize: onEraserSize,
                    ),
                  ],
                  const SizedBox(height: 20),
                  const _SectionTitle(
                    title: 'إضافة محتوى',
                    icon: Icons.add_box_outlined,
                  ),
                  const SizedBox(height: 10),
                  _ToolGrid(
                    children: [
                      _ToolTile(
                        label: 'أشكال',
                        icon: Icons.change_history_rounded,
                        selected: activeKind == PdfAnnotationKind.shape,
                        onTap: () => _pick(context, PdfAnnotationKind.shape),
                      ),
                      _ToolTile(
                        label: 'حجم الخط',
                        icon: Icons.format_size_rounded,
                        onTap: () => _act(context, PdfStudioAction.text),
                      ),
                      _ToolTile(
                        label: 'لون النص',
                        icon: Icons.palette_outlined,
                        onTap: () => _act(context, PdfStudioAction.text),
                      ),
                      _ToolTile(
                        label: 'نص',
                        icon: Icons.title_rounded,
                        onTap: () => _act(context, PdfStudioAction.text),
                      ),
                    ],
                  ),
                  if (activeKind == PdfAnnotationKind.shape) ...[
                    const SizedBox(height: 14),
                    _ShapeOptions(shape: shape, onShape: onShape),
                  ],
                  const SizedBox(height: 20),
                  const _SectionTitle(
                    title: 'إضافات متقدمة',
                    icon: Icons.layers_rounded,
                  ),
                  const SizedBox(height: 10),
                  _ToolGrid(
                    children: [
                      _ToolTile(
                        label: 'صورة',
                        icon: Icons.image_outlined,
                        onTap: () => _act(context, PdfStudioAction.image),
                      ),
                      _ToolTile(
                        label: 'ملصق/ختم',
                        icon: Icons.verified_outlined,
                        selected: activeKind == PdfAnnotationKind.stamp,
                        onTap: () => _act(context, PdfStudioAction.stampPicker),
                      ),
                      _ToolTile(
                        label: 'ملاحظة لاصقة',
                        icon: Icons.sticky_note_2_outlined,
                        selected: activeKind == PdfAnnotationKind.note,
                        onTap: () => _pick(context, PdfAnnotationKind.note),
                      ),
                      _ToolTile(
                        label: 'سهم',
                        icon: Icons.north_east_rounded,
                        selected: activeKind == PdfAnnotationKind.arrow,
                        onTap: () => _pick(context, PdfAnnotationKind.arrow),
                      ),
                      _ToolTile(
                        label: 'صوت',
                        icon: Icons.graphic_eq_rounded,
                        onTap: () => _act(context, PdfStudioAction.audio),
                      ),
                      _ToolTile(
                        label: 'فيديو',
                        icon: Icons.play_circle_outline_rounded,
                        onTap: () => _act(context, PdfStudioAction.video),
                      ),
                      _ToolTile(
                        label: 'تنظيم الصفحات',
                        icon: Icons.view_carousel_outlined,
                        onTap: () => _act(context, PdfStudioAction.pages),
                      ),
                      _ToolTile(
                        label: 'صفحة بيضاء مسطرة',
                        icon: Icons.menu_book_outlined,
                        onTap: () => _act(context, PdfStudioAction.notebook),
                      ),
                      _ToolTile(
                        label: 'ضغط PDF',
                        icon: Icons.compress_rounded,
                        onTap: () => _act(context, PdfStudioAction.compress),
                      ),
                      _ToolTile(
                        label: 'دمج',
                        icon: Icons.merge_rounded,
                        onTap: () => _act(context, PdfStudioAction.merge),
                      ),
                      _ToolTile(
                        label: 'تقسيم',
                        icon: Icons.call_split_rounded,
                        onTap: () => _act(context, PdfStudioAction.split),
                      ),
                      _ToolTile(
                        label: 'OCR',
                        icon: Icons.document_scanner_outlined,
                        onTap: () => _act(context, PdfStudioAction.ocr),
                      ),
                      _ToolTile(
                        label: 'بحث',
                        icon: Icons.search_rounded,
                        onTap: () => _act(context, PdfStudioAction.search),
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: _ExportTile(
                          label: 'تصدير PDF',
                          icon: Icons.picture_as_pdf_outlined,
                          onTap: () => _act(context, PdfStudioAction.exportPdf),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: _ExportTile(
                          label: 'حزمة المشروع',
                          icon: Icons.inventory_2_outlined,
                          onTap: () =>
                              _act(context, PdfStudioAction.exportProject),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            _UndoBar(
                canUndo: canUndo,
                canRedo: canRedo,
                onUndo: onUndo,
                onRedo: onRedo),
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.icon});

  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: PdfStudioColors.muted),
        const SizedBox(width: 7),
        TrText(
          title,
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.2,
            color: PdfStudioColors.muted,
          ),
        ),
      ],
    );
  }
}

class _ToolGrid extends StatelessWidget {
  const _ToolGrid({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        const gap = 8.0;
        final width = constraints.maxWidth;
        final columns = width >= 520 ? 6 : 4;
        final tileWidth = (width - gap * (columns - 1)) / columns;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final child in children)
              SizedBox(width: tileWidth, child: child),
          ],
        );
      },
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({
    required this.label,
    required this.icon,
    required this.onTap,
    this.selected = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      label: label,
      child: Material(
        color: selected
            ? PdfStudioColors.blue.withValues(alpha: 0.22)
            : PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            height: 82,
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 9),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: selected ? PdfStudioColors.blue : PdfStudioColors.stroke,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  icon,
                  size: 24,
                  color: selected
                      ? PdfStudioColors.blueText
                      : PdfStudioColors.text,
                ),
                const SizedBox(height: 7),
                TrText(
                  label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10.5,
                    height: 1.2,
                    fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    color: selected
                        ? PdfStudioColors.blueText
                        : PdfStudioColors.muted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HighlightOptions extends StatelessWidget {
  const _HighlightOptions({
    required this.color,
    required this.opacity,
    required this.onColor,
    required this.onOpacity,
  });

  final int color;
  final double opacity;
  final ValueChanged<int> onColor;
  final ValueChanged<double> onOpacity;

  static const List<int> _colors = [
    0xFFFFD84D,
    0xFF35BCE8,
    0xFF7C5CFF,
    0xFF3DDC97,
    0xFFE5484D,
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 8),
      decoration: BoxDecoration(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PdfStudioColors.stroke),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const TrText(
                'لون التظليل',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PdfStudioColors.muted,
                ),
              ),
              const Spacer(),
              for (final value in _colors) ...[
                _ColorDot(
                  value: value,
                  selected: value == color,
                  onTap: () => onColor(value),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
          Row(
            children: [
              const TrText(
                'الشفافية',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PdfStudioColors.muted,
                ),
              ),
              Expanded(
                child: Slider(
                  value: opacity.clamp(0.15, 1),
                  min: 0.15,
                  max: 1,
                  divisions: 17,
                  label: '${(opacity * 100).round()}%',
                  onChanged: onOpacity,
                ),
              ),
              Text(
                '${(opacity * 100).round()}%',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: PdfStudioColors.blueText,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Eraser mode and radius, shown while the eraser is the active tool.
class _EraserOptions extends StatelessWidget {
  const _EraserOptions({
    required this.objectMode,
    required this.size,
    required this.onObjectMode,
    required this.onSize,
  });

  final bool objectMode;
  final int size;
  final ValueChanged<bool> onObjectMode;
  final ValueChanged<int> onSize;

  static const List<String> _sizes = ['صغيرة', 'متوسطة', 'كبيرة'];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PdfStudioColors.stroke),
      ),
      child: Column(
        children: [
          Row(
            children: [
              const TrText(
                'نوع الممحاة',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PdfStudioColors.muted,
                ),
              ),
              const Spacer(),
              _OptionChip(
                label: 'نقاط',
                selected: !objectMode,
                onTap: () => onObjectMode(false),
              ),
              const SizedBox(width: 6),
              _OptionChip(
                label: 'كائنات',
                selected: objectMode,
                onTap: () => onObjectMode(true),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const TrText(
                'حجم الممحاة',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: PdfStudioColors.muted,
                ),
              ),
              const Spacer(),
              for (var index = 0; index < _sizes.length; index++) ...[
                _OptionChip(
                  label: _sizes[index],
                  selected: size == index,
                  onTap: () => onSize(index),
                ),
                if (index != _sizes.length - 1) const SizedBox(width: 6),
              ],
            ],
          ),
          const SizedBox(height: 8),
          const TrText(
            'اسحب على الخط أو الرسم لمحوه، والتراجع يرجّعه.',
            style: TextStyle(fontSize: 10.5, color: PdfStudioColors.muted),
          ),
        ],
      ),
    );
  }
}

/// Rectangle / ellipse / line choice for the shape tool.
class _ShapeOptions extends StatelessWidget {
  const _ShapeOptions({required this.shape, required this.onShape});

  final PdfShapeKind shape;
  final ValueChanged<PdfShapeKind> onShape;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PdfStudioColors.stroke),
      ),
      child: Row(
        children: [
          const TrText(
            'الشكل',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: PdfStudioColors.muted,
            ),
          ),
          const Spacer(),
          _OptionChip(
            label: 'مستطيل',
            selected: shape == PdfShapeKind.rectangle,
            onTap: () => onShape(PdfShapeKind.rectangle),
          ),
          const SizedBox(width: 6),
          _OptionChip(
            label: 'دائرة',
            selected: shape == PdfShapeKind.ellipse,
            onTap: () => onShape(PdfShapeKind.ellipse),
          ),
          const SizedBox(width: 6),
          _OptionChip(
            label: 'خط',
            selected: shape == PdfShapeKind.line,
            onTap: () => onShape(PdfShapeKind.line),
          ),
        ],
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? PdfStudioColors.blue.withValues(alpha: 0.22)
          : PdfStudioColors.surface,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected ? PdfStudioColors.blue : PdfStudioColors.stroke,
            ),
          ),
          child: TrText(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
              color:
                  selected ? PdfStudioColors.blueText : PdfStudioColors.muted,
            ),
          ),
        ),
      ),
    );
  }
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.value,
    required this.selected,
    required this.onTap,
  });

  final int value;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          color: Color(value | 0xFF000000),
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: selected
            ? const Icon(Icons.check_rounded, size: 14, color: Colors.black)
            : null,
      ),
    );
  }
}

class _ExportTile extends StatelessWidget {
  const _ExportTile({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdfStudioColors.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: PdfStudioColors.stroke),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: PdfStudioColors.cyanText),
              const SizedBox(width: 8),
              Expanded(
                child: TrText(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: PdfStudioColors.text,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UndoBar extends StatelessWidget {
  const _UndoBar({
    required this.canUndo,
    required this.canRedo,
    required this.onUndo,
    required this.onRedo,
  });

  final bool canUndo;
  final bool canRedo;
  final VoidCallback onUndo;
  final VoidCallback onRedo;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(18, 8, 18, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: PdfStudioColors.stroke)),
      ),
      child: Row(
        children: [
          Expanded(
            child: OutlinedButton.icon(
              onPressed: canUndo ? onUndo : null,
              icon: const Icon(Icons.undo_rounded, size: 18),
              label: const TrText('تراجع'),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton.icon(
              onPressed: canRedo ? onRedo : null,
              icon: const Icon(Icons.redo_rounded, size: 18),
              label: const TrText('إعادة'),
            ),
          ),
        ],
      ),
    );
  }
}
