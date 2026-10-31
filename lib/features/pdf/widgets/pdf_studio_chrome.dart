/// The dark chrome that floats over the studio reader.
///
/// The reader screen owns the document; this file owns the bars around it:
/// the translucent top bar with the title menu, page stepper and zoom
/// controls, the bottom slider and quick actions, the vertical view controls
/// and the page grid. Keeping them here means the reader's state machine stays
/// readable.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/theme/pdf_studio_theme.dart';
import '../../../widgets/tr_text.dart';

/// The top bar: document title menu, bookmark, search and the page/zoom row.
class PdfStudioTopBar extends StatelessWidget {
  const PdfStudioTopBar({
    super.key,
    required this.title,
    required this.favorite,
    required this.canFavorite,
    required this.page,
    required this.pageCount,
    required this.zoom,
    required this.onBack,
    required this.onMenu,
    required this.onSearch,
    required this.onFavorite,
    required this.onPreviousPage,
    required this.onNextPage,
    required this.onJump,
    required this.onZoomOut,
    required this.onZoomIn,
    required this.onFit,
  });

  final String title;
  final bool favorite;
  final bool canFavorite;
  final int page;
  final int pageCount;

  /// The live zoom scale; a notifier so pinching updates the label without
  /// rebuilding the whole reader.
  final ValueListenable<double> zoom;

  final VoidCallback onBack;
  final VoidCallback onMenu;
  final VoidCallback onSearch;
  final VoidCallback? onFavorite;
  final VoidCallback onPreviousPage;
  final VoidCallback onNextPage;
  final VoidCallback onJump;
  final VoidCallback onZoomOut;
  final VoidCallback onZoomIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdfStudioColors.glass,
      child: Container(
        decoration: const BoxDecoration(
          border: Border(
            bottom: BorderSide(color: PdfStudioColors.stroke),
          ),
        ),
        child: SafeArea(
          bottom: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 6, 8, 10),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    IconButton(
                      tooltip: 'رجوع',
                      onPressed: onBack,
                      icon: const Icon(Icons.arrow_back_rounded),
                    ),
                    Expanded(
                      child: InkWell(
                        onTap: onMenu,
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 6,
                          ),
                          child: Row(
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topRight,
                                    end: Alignment.bottomLeft,
                                    colors: [
                                      PdfStudioColors.violet,
                                      PdfStudioColors.blue,
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(9),
                                ),
                                child: const Center(
                                  child: Icon(
                                    Icons.description_rounded,
                                    size: 15,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: TrText(
                                  title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w800,
                                    color: PdfStudioColors.text,
                                  ),
                                ),
                              ),
                              const Icon(
                                Icons.expand_more_rounded,
                                color: PdfStudioColors.muted,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      tooltip: favorite ? 'شيل من المفضلة' : 'ضيف للمفضلة',
                      onPressed: canFavorite ? onFavorite : null,
                      icon: Icon(
                        favorite
                            ? Icons.star_rounded
                            : Icons.star_border_rounded,
                        color: favorite ? PdfStudioColors.yellow : null,
                      ),
                    ),
                    IconButton(
                      tooltip: 'بحث جوه الملف',
                      onPressed: onSearch,
                      icon: const Icon(Icons.search_rounded),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      _PageStepper(
                        page: page,
                        pageCount: pageCount,
                        onPrevious: onPreviousPage,
                        onNext: onNextPage,
                        onJump: onJump,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: _ZoomStepper(
                          zoom: zoom,
                          onOut: onZoomOut,
                          onIn: onZoomIn,
                          onFit: onFit,
                        ),
                      ),
                    ],
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

class _PageStepper extends StatelessWidget {
  const _PageStepper({
    required this.page,
    required this.pageCount,
    required this.onPrevious,
    required this.onNext,
    required this.onJump,
  });

  final int page;
  final int pageCount;
  final VoidCallback onPrevious;
  final VoidCallback onNext;
  final VoidCallback onJump;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PdfStudioColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            tooltip: 'الصفحة السابقة',
            icon: Icons.chevron_right_rounded,
            onTap: page > 1 ? onPrevious : null,
          ),
          InkWell(
            onTap: onJump,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Text(
                '$page / $pageCount',
                textDirection: TextDirection.ltr,
                style: const TextStyle(
                  fontFamily: PdfStudioTheme.font,
                  color: PdfStudioColors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w800,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ),
          _StepButton(
            tooltip: 'الصفحة التالية',
            icon: Icons.chevron_left_rounded,
            onTap: page < pageCount ? onNext : null,
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.tooltip,
    required this.icon,
    required this.onTap,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      padding: EdgeInsets.zero,
      onPressed: onTap,
      icon: Icon(icon, size: 19),
    );
  }
}

class _ZoomStepper extends StatelessWidget {
  const _ZoomStepper({
    required this.zoom,
    required this.onOut,
    required this.onIn,
    required this.onFit,
  });

  final ValueListenable<double> zoom;
  final VoidCallback onOut;
  final VoidCallback onIn;
  final VoidCallback onFit;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      decoration: BoxDecoration(
        color: PdfStudioColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PdfStudioColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _StepButton(
            tooltip: 'تصغير',
            icon: Icons.remove_rounded,
            onTap: onOut,
          ),
          Expanded(
            child: ValueListenableBuilder<double>(
              valueListenable: zoom,
              builder: (context, value, _) => Center(
                child: Text(
                  '${(value * 100).round()}%',
                  textDirection: TextDirection.ltr,
                  style: const TextStyle(
                    fontFamily: PdfStudioTheme.font,
                    color: PdfStudioColors.text,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          _StepButton(
            tooltip: 'تكبير',
            icon: Icons.add_rounded,
            onTap: onIn,
          ),
          _StepButton(
            tooltip: 'ملاءمة الصفحة',
            icon: Icons.fit_screen_rounded,
            onTap: onFit,
          ),
        ],
      ),
    );
  }
}

/// The bottom chrome: the page slider and the studio quick actions.
class PdfStudioBottomChrome extends StatelessWidget {
  const PdfStudioBottomChrome({
    super.key,
    required this.page,
    required this.pageCount,
    required this.onJump,
    required this.onScrub,
    required this.canUndo,
    required this.canRedo,
    required this.onTools,
    required this.onPages,
    required this.onUndo,
    required this.onRedo,
    this.eraserActive = false,
    this.onEraser,
  });

  final int page;
  final int pageCount;
  final VoidCallback onJump;
  final ValueChanged<int> onScrub;
  final bool canUndo;
  final bool canRedo;
  final VoidCallback onTools;
  final VoidCallback onPages;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool eraserActive;
  final VoidCallback? onEraser;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(10, 0, 10, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _QuickBar(
            canUndo: canUndo,
            canRedo: canRedo,
            onTools: onTools,
            onPages: onPages,
            onUndo: onUndo,
            onRedo: onRedo,
            eraserActive: eraserActive,
            onEraser: onEraser,
          ),
          const SizedBox(height: 7),
          Material(
            color: PdfStudioColors.glass,
            borderRadius: BorderRadius.circular(18),
            child: Container(
              padding: const EdgeInsetsDirectional.fromSTEB(4, 2, 8, 2),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(18),
                border: Border.all(color: PdfStudioColors.stroke),
              ),
              child: Row(
                children: [
                  TextButton(
                    onPressed: onJump,
                    child: TrText('صفحة $page من $pageCount'),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 3,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                      ),
                      child: Slider(
                        value: page.toDouble().clamp(
                              1,
                              pageCount.toDouble(),
                            ),
                        min: 1,
                        max: pageCount < 2 ? 2 : pageCount.toDouble(),
                        divisions: pageCount < 2 ? 1 : pageCount - 1,
                        onChanged: (value) => onScrub(value.round()),
                      ),
                    ),
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

class _QuickBar extends StatelessWidget {
  const _QuickBar({
    required this.canUndo,
    required this.canRedo,
    required this.onTools,
    required this.onPages,
    required this.onUndo,
    required this.onRedo,
    required this.eraserActive,
    required this.onEraser,
  });

  final bool canUndo;
  final bool canRedo;
  final VoidCallback onTools;
  final VoidCallback onPages;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final bool eraserActive;
  final VoidCallback? onEraser;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdfStudioColors.glass,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: PdfStudioColors.stroke),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _QuickAction(
              icon: Icons.auto_fix_high_rounded,
              label: 'أدوات',
              color: PdfStudioColors.violetText,
              onTap: onTools,
            ),
            _QuickAction(
              icon: Icons.auto_fix_normal_rounded,
              label: 'ممحاة',
              color: eraserActive
                  ? PdfStudioColors.yellow
                  : PdfStudioColors.cyanText,
              onTap: onEraser,
            ),
            _QuickAction(
              icon: Icons.grid_view_rounded,
              label: 'صفحات',
              color: PdfStudioColors.cyanText,
              onTap: onPages,
            ),
            _QuickAction(
              icon: Icons.undo_rounded,
              label: 'تراجع',
              color: PdfStudioColors.text,
              onTap: canUndo ? onUndo : null,
            ),
            _QuickAction(
              icon: Icons.redo_rounded,
              label: 'إعادة',
              color: PdfStudioColors.text,
              onTap: canRedo ? onRedo : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _QuickAction extends StatelessWidget {
  const _QuickAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(13),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 19,
                color: enabled ? color : PdfStudioColors.muted,
              ),
              const SizedBox(height: 2),
              TrText(
                label,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w700,
                  color:
                      enabled ? PdfStudioColors.muted : PdfStudioColors.stroke,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Scroll mode, rotation, night mode and settings, floating at the edge.
class PdfStudioViewControls extends StatelessWidget {
  const PdfStudioViewControls({
    super.key,
    required this.vertical,
    required this.nightMode,
    required this.onMode,
    required this.onRotate,
    required this.onNight,
    required this.onSettings,
  });

  final bool vertical;
  final bool nightMode;
  final VoidCallback onMode;
  final VoidCallback onRotate;
  final VoidCallback onNight;
  final VoidCallback onSettings;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdfStudioColors.glass,
      borderRadius: BorderRadius.circular(18),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: PdfStudioColors.stroke),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              tooltip: vertical ? 'صفحة واحدة' : 'عرض مستمر',
              onPressed: onMode,
              icon: Icon(
                vertical
                    ? Icons.crop_portrait_rounded
                    : Icons.view_agenda_rounded,
              ),
            ),
            IconButton(
              tooltip: 'تدوير الصفحة',
              onPressed: onRotate,
              icon: const Icon(Icons.rotate_right_rounded),
            ),
            IconButton(
              tooltip: 'الوضع الليلي',
              onPressed: onNight,
              icon: Icon(
                nightMode ? Icons.dark_mode_rounded : Icons.dark_mode_outlined,
                color: nightMode ? PdfStudioColors.yellow : null,
              ),
            ),
            IconButton(
              tooltip: 'إعدادات القراءة',
              onPressed: onSettings,
              icon: const Icon(Icons.tune_rounded),
            ),
          ],
        ),
      ),
    );
  }
}

/// A slim hint shown while an annotation tool waits for a long press.
class PdfStudioHintBanner extends StatelessWidget {
  const PdfStudioHintBanner({
    super.key,
    required this.message,
    required this.onClose,
  });

  final String message;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: PdfStudioColors.surfaceAlt,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 4, 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: PdfStudioColors.violet.withValues(alpha: 0.55),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.touch_app_rounded,
              size: 17,
              color: PdfStudioColors.violetText,
            ),
            const SizedBox(width: 7),
            Flexible(
              child: TrText(
                message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 11,
                  color: PdfStudioColors.text,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              tooltip: 'إلغاء الأداة',
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: 30,
                height: 30,
              ),
              padding: EdgeInsets.zero,
              onPressed: onClose,
              icon: const Icon(Icons.close_rounded, size: 16),
            ),
          ],
        ),
      ),
    );
  }
}

/// The page grid opened from the bottom quick bar.
Future<void> showPdfPageGrid(
  BuildContext context, {
  required int pageCount,
  required int current,
  required ValueChanged<int> onPick,
}) {
  return PdfStudioTheme.showSheet<void>(
    context: context,
    builder: (sheetContext) => _PageGridSheet(
      pageCount: pageCount,
      current: current,
      onPick: (index) {
        Navigator.of(sheetContext).pop();
        onPick(index);
      },
    ),
  );
}

class _PageGridSheet extends StatelessWidget {
  const _PageGridSheet({
    required this.pageCount,
    required this.current,
    required this.onPick,
  });

  final int pageCount;
  final int current;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 12, 12),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        TrText(
                          'الصفحات',
                          style: TextStyle(
                            color: PdfStudioColors.text,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        SizedBox(height: 2),
                        TrText(
                          'اختَر صفحة للانتقال إليها.',
                          style: TextStyle(
                            color: PdfStudioColors.muted,
                            fontSize: 11.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: 'قفل الصفحات',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Flexible(
              child: GridView.builder(
                padding: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 20),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  childAspectRatio: 0.78,
                ),
                itemCount: pageCount,
                itemBuilder: (context, index) {
                  final selected = index == current;
                  return Material(
                    color: selected
                        ? PdfStudioColors.blue.withValues(alpha: 0.2)
                        : PdfStudioColors.surfaceAlt,
                    borderRadius: BorderRadius.circular(12),
                    child: InkWell(
                      onTap: () => onPick(index),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: selected
                                ? PdfStudioColors.blue
                                : PdfStudioColors.stroke,
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.insert_drive_file_outlined,
                              size: 22,
                              color: selected
                                  ? PdfStudioColors.blueText
                                  : PdfStudioColors.muted,
                            ),
                            const SizedBox(height: 7),
                            Text(
                              '${index + 1}',
                              textDirection: TextDirection.ltr,
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w800,
                                color: selected
                                    ? PdfStudioColors.blueText
                                    : PdfStudioColors.text,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
