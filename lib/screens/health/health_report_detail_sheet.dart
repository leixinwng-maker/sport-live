import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:provider/provider.dart';

import '../../models/health_data_extraction.dart';
import '../../models/health_metric.dart';
import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../services/database_helper.dart';
import '../../theme/taoist_theme.dart';
import 'health_extraction_review_screen.dart';
import 'health_light.dart';

/// 报告详情底部抽屉（P7-T5）：灯色总览 + 指标分组 + 行动清单（勾选/改期回写）
/// + 附件首页缩略 + AI 解读 + 识别原文 + 重新归纳入口。
class HealthReportDetailSheet {
  HealthReportDetailSheet._();

  /// 打开详情。内部用 [reportId] 从 Provider 实时取最新报告，
  /// 勾选行动 / 改复查日期后 UI 自动刷新。
  static Future<void> show(BuildContext context, String reportId) {
    return showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.88,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (sheetContext, scrollController) => Container(
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: _DetailBody(
            reportId: reportId,
            scrollController: scrollController,
          ),
        ),
      ),
    );
  }
}

class _DetailBody extends StatelessWidget {
  final String reportId;
  final ScrollController scrollController;

  const _DetailBody({required this.reportId, required this.scrollController});

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    HealthReport? r;
    for (final x in provider.healthReports) {
      if (x.id == reportId) {
        r = x;
        break;
      }
    }
    if (r == null) {
      // 报告已被删除（如列表侧滑时详情仍开着），自动收起抽屉
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (Navigator.of(context).canPop()) Navigator.of(context).pop();
      });
      return const SizedBox.shrink();
    }

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      children: [
        _buildHeader(context, r),
        _buildLightOverview(r),
        _buildAttachment(r),
        _buildMetricsGrouped(reportId),
        _buildActions(context, r),
        if (r.aiSummary.isNotEmpty) _buildAiSummary(r),
        if (r.ocrText.isNotEmpty) _buildOcrText(r),
        const SizedBox(height: 12),
        _buildReIngestButton(context, r),
      ],
    );
  }

  // ==================== 头部 ====================

  Widget _buildHeader(BuildContext context, HealthReport r) {
    final d = r.date;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(
              r.fileType == 'pdf'
                  ? Icons.picture_as_pdf_outlined
                  : Icons.description_outlined,
              color: TaoistTheme.teaBrown,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                r.title,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              onPressed: () => Navigator.pop(context),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              '体检日期 ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}',
              style: const TextStyle(
                  fontSize: 12, color: TaoistTheme.cloudGray),
            ),
            const SizedBox(width: 8),
            _typeTag(r.reportType),
          ],
        ),
      ],
    );
  }

  Widget _typeTag(String type) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        type,
        style:
            const TextStyle(fontSize: 10, color: TaoistTheme.teaBrown),
      ),
    );
  }

  // ==================== 灯色总览 ====================

  Widget _buildLightOverview(HealthReport r) {
    // 统计来源：报告总评 + 行动灯色（指标灯色由分组区展示，计入总评但不重复计数条）
    final lights = <RiskLight>[
      if (r.riskLevel.isNotEmpty) RiskLight.fromCode(r.riskLevel),
      for (final a in r.actions)
        if (a.light != RiskLight.unknown) a.light,
    ];
    final total = r.riskLevel.isNotEmpty
        ? RiskLight.fromCode(r.riskLevel)
        : HealthLightUI.worst(lights);
    final counts = <RiskLight, int>{};
    for (final l in lights) {
      counts[l] = (counts[l] ?? 0) + 1;
    }

    return Container(
      margin: const EdgeInsets.only(top: 14),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('总评',
                  style: TextStyle(
                      fontSize: 11, color: TaoistTheme.cloudGray)),
              const SizedBox(height: 4),
              HealthLightUI.dot(total, size: 10, label: total.label),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Wrap(
              spacing: 10,
              runSpacing: 4,
              children: [
                for (final light in [
                  RiskLight.red,
                  RiskLight.yellow,
                  RiskLight.blue,
                  RiskLight.green,
                ])
                  if ((counts[light] ?? 0) > 0)
                    HealthLightUI.dot(
                      light,
                      label: '${light.label} ${counts[light]}',
                    ),
                if (counts.isEmpty)
                  const Text(
                    '暂无灯色评级',
                    style: TextStyle(
                        fontSize: 11, color: TaoistTheme.cloudGray),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 附件缩略 ====================

  Widget _buildAttachment(HealthReport r) {
    if (r.filePath.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: SizedBox(
          width: double.infinity,
          height: 150,
          child: r.fileType == 'pdf'
              ? _PdfFirstPageThumb(path: r.filePath)
              : Image.file(
                  File(r.filePath),
                  fit: BoxFit.cover,
                  alignment: Alignment.topCenter,
                  errorBuilder: (_, __, ___) => _filePlaceholder(
                    icon: Icons.broken_image_outlined,
                    text: '图片文件缺失或无法读取',
                  ),
                ),
        ),
      ),
    );
  }

  Widget _filePlaceholder({required IconData icon, required String text}) {
    return Container(
      color: TaoistTheme.mistGray.withValues(alpha: 0.4),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 32, color: TaoistTheme.cloudGray),
          const SizedBox(height: 4),
          Text(text,
              style: const TextStyle(
                  fontSize: 11, color: TaoistTheme.cloudGray)),
        ],
      ),
    );
  }

  // ==================== 指标分组（红→黄→蓝→绿→未评级） ====================

  Widget _buildMetricsGrouped(String reportId) {
    return FutureBuilder<List<HealthMetric>>(
      future: DatabaseHelper.instance.getHealthMetricsByReport(reportId),
      builder: (context, snap) {
        final metrics = snap.data ?? const <HealthMetric>[];
        if (snap.connectionState != ConnectionState.done) {
          return const Padding(
            padding: EdgeInsets.only(top: 20),
            child: Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
        }
        // 按灯色权重分组，空组跳过
        final groups = <RiskLight, List<HealthMetric>>{};
        for (final m in metrics) {
          groups
              .putIfAbsent(RiskLight.fromCode(m.riskLevel), () => [])
              .add(m);
        }
        final order = RiskLight.values.toList()
            ..sort((a, b) => HealthLightUI
                .weightOf(a)
                .compareTo(HealthLightUI.weightOf(b)));
        final sections = <Widget>[];
        for (final light in order) {
          final list = groups[light];
          if (list == null || list.isEmpty) continue;
          sections.add(Padding(
            padding: const EdgeInsets.only(top: 14, bottom: 6),
            child: Row(
              children: [
                HealthLightUI.dot(light),
                const SizedBox(width: 6),
                Text(
                  '${light.label}指标（${list.length}）',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ],
            ),
          ));
          for (final m in list) {
            sections.add(_metricRow(m));
          }
        }
        if (sections.isEmpty) return const SizedBox.shrink();
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 18),
              child: Text(
                '入库指标',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: TaoistTheme.inkBlack,
                ),
              ),
            ),
            ...sections,
          ],
        );
      },
    );
  }

  Widget _metricRow(HealthMetric m) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        border: Border.all(color: TaoistTheme.mistGray),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${m.type}  ${_fmtValue(m.value)}${m.unit?.isEmpty ?? true ? '' : ' ${m.unit}'}',
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ),
              if (m.referenceRange.isNotEmpty)
                Text(
                  '参考 ${m.referenceRange}',
                  style: const TextStyle(
                      fontSize: 11, color: TaoistTheme.cloudGray),
                ),
            ],
          ),
          if (m.note.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(
              m.note,
              style: const TextStyle(
                  fontSize: 11, color: TaoistTheme.teaBrown, height: 1.4),
            ),
          ],
        ],
      ),
    );
  }

  String _fmtValue(double v) {
    if (v.isNaN) return '-';
    return v == v.truncateToDouble()
        ? v.truncate().toString()
        : v.toStringAsFixed(2);
  }

  // ==================== 行动清单 ====================

  Widget _buildActions(BuildContext context, HealthReport r) {
    final actions = r.actions;
    if (actions.isEmpty) return const SizedBox.shrink();
    final provider = context.read<AppProvider>();
    final widgets = <Widget>[
      const Padding(
        padding: EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          '行动清单',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
        ),
      ),
    ];
    for (var i = 0; i < actions.length; i++) {
      widgets.add(_actionTile(context, provider, r.id!, i, actions[i]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: widgets,
    );
  }

  Widget _actionTile(BuildContext context, AppProvider provider,
      String reportId, int index, HealthAction a) {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    final overdue = a.dueDate != null &&
        a.dueDate!.isBefore(todayStart);
    final urgent = a.dueDate != null &&
        !overdue &&
        a.dueDate!.isBefore(todayStart.add(const Duration(days: 8)));
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(4, 0, 8, 0),
      decoration: BoxDecoration(
        border: Border.all(
          color: overdue
              ? HealthLightUI.red.withValues(alpha: 0.5)
              : urgent
                  ? HealthLightUI.yellow.withValues(alpha: 0.5)
                  : TaoistTheme.mistGray,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Checkbox(
            value: a.done,
            activeColor: TaoistTheme.jadeGreen,
            onChanged: (v) =>
                provider.toggleActionDone(reportId, index, v ?? false),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      _categoryTag(a.category),
                      const SizedBox(width: 6),
                      if (a.light != RiskLight.unknown)
                        HealthLightUI.dot(a.light, label: ''),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          a.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: a.done
                                ? TaoistTheme.cloudGray
                                : TaoistTheme.inkBlack,
                            decoration: a.done
                                ? TextDecoration.lineThrough
                                : TextDecoration.none,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (a.detail.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        a.detail,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            fontSize: 11,
                            color: TaoistTheme.cloudGray,
                            height: 1.4),
                      ),
                    ),
                ],
              ),
            ),
          ),
          // 复查到期日：可点击改期
          if (a.dueDate != null)
            Tooltip(
              message: '点击修改复查日期',
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: () => _pickDueDate(context, provider, reportId, index, a),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: a.done
                        ? TaoistTheme.mistGray.withValues(alpha: 0.5)
                        : overdue
                            ? HealthLightUI.red.withValues(alpha: 0.1)
                            : urgent
                                ? HealthLightUI.yellow.withValues(alpha: 0.14)
                                : TaoistTheme.jadeGreen.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        a.needsFollowup
                            ? Icons.alarm_outlined
                            : Icons.event_outlined,
                        size: 13,
                        color: a.done
                            ? TaoistTheme.cloudGray
                            : overdue
                                ? HealthLightUI.red
                                : urgent
                                    ? HealthLightUI.yellow
                                    : TaoistTheme.jadeGreen,
                      ),
                      const SizedBox(width: 3),
                      Text(
                        '${a.dueDate!.month}/${a.dueDate!.day}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: a.done
                              ? TaoistTheme.cloudGray
                              : overdue
                                  ? HealthLightUI.red
                                  : urgent
                                      ? const Color(0xFFB77B24)
                                      : TaoistTheme.jadeGreen,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryTag(String category) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(
        color: TaoistTheme.teaBrown.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        category,
        style: const TextStyle(fontSize: 10, color: TaoistTheme.teaBrown),
      ),
    );
  }

  Future<void> _pickDueDate(
    BuildContext context,
    AppProvider provider,
    String reportId,
    int index,
    HealthAction a,
  ) async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: a.dueDate ?? now,
      firstDate: now.subtract(const Duration(days: 365)),
      lastDate: now.add(const Duration(days: 365 * 5)),
      helpText: '选择复查日期',
    );
    if (picked == null || !context.mounted) return;
    await provider.updateAction(
      reportId,
      index,
      a.copyWith(dueDate: DateTime(picked.year, picked.month, picked.day)),
    );
  }

  // ==================== AI 解读 / 识别原文 ====================

  Widget _buildAiSummary(HealthReport r) {
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AI 解读',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              r.aiSummary,
              style: const TextStyle(fontSize: 13, height: 1.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOcrText(HealthReport r) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 8),
        title: const Text(
          '识别原文',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.inkBlack,
          ),
        ),
        iconColor: TaoistTheme.cloudGray,
        collapsedIconColor: TaoistTheme.cloudGray,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: TaoistTheme.mistGray.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SelectableText(
              r.ocrText,
              style: const TextStyle(
                  fontSize: 12, height: 1.6, color: TaoistTheme.cloudGray),
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 重新归纳 ====================

  Widget _buildReIngestButton(BuildContext context, HealthReport r) {
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton.icon(
        onPressed: () => _reIngest(context, r),
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('重新归纳（重跑 AI 提取并覆盖旧指标）'),
        style: OutlinedButton.styleFrom(
          foregroundColor: TaoistTheme.teaBrown,
          side: BorderSide(color: TaoistTheme.teaBrown.withValues(alpha: 0.4)),
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
      ),
    );
  }

  Future<void> _reIngest(BuildContext context, HealthReport r) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('重新归纳'),
        content: const Text(
          '将重跑 AI 结构化提取，确认入库后会覆盖该报告已入库的旧指标（本地与云端同步删除）。继续吗？',
          style: TextStyle(fontSize: 14, height: 1.6),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // loading
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const AlertDialog(
        content: Row(
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 16),
            Text('AI 正在重新提取...'),
          ],
        ),
      ),
    );
    final provider = context.read<AppProvider>();
    try {
      final extraction = await provider.extractHealthData(r);
      if (!context.mounted) return;
      // 关 loading → 关 sheet → 进确认页（reIngest 模式）
      Navigator.of(context)
        ..pop()
        ..pop();
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => HealthExtractionReviewScreen(
            report: r,
            extraction: extraction,
            reIngest: true,
          ),
        ),
      );
    } catch (e) {
      if (!context.mounted) return;
      Navigator.of(context).pop(); // 关 loading
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('重新归纳失败：$e（可稍后重试）')),
      );
    }
  }
}

/// PDF 首页缩略（pdfx 渲染，失败给文件图标）
class _PdfFirstPageThumb extends StatefulWidget {
  final String path;
  const _PdfFirstPageThumb({required this.path});

  @override
  State<_PdfFirstPageThumb> createState() => _PdfFirstPageThumbState();
}

class _PdfFirstPageThumbState extends State<_PdfFirstPageThumb> {
  late Future<Uint8List?> _future;

  @override
  void initState() {
    super.initState();
    _future = _renderFirstPage();
  }

  @override
  void didUpdateWidget(covariant _PdfFirstPageThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.path != widget.path) {
      _future = _renderFirstPage();
    }
  }

  Future<Uint8List?> _renderFirstPage() async {
    pdfx.PdfDocument? doc;
    try {
      doc = await pdfx.PdfDocument.openFile(widget.path);
      final page = await doc.getPage(1);
      try {
        final scale = 240 / page.width;
        final rendered = await page.render(
          width: page.width * scale,
          height: page.height * scale,
          format: pdfx.PdfPageImageFormat.jpeg,
          quality: 85,
        );
        return rendered?.bytes;
      } finally {
        await page.close();
      }
    } catch (_) {
      return null;
    } finally {
      await doc?.close();
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _future,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Container(
            color: TaoistTheme.mistGray.withValues(alpha: 0.4),
            alignment: Alignment.center,
            child: const SizedBox(
              width: 22,
              height: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final bytes = snap.data;
        if (bytes == null || bytes.isEmpty) {
          return Container(
            color: TaoistTheme.mistGray.withValues(alpha: 0.4),
            alignment: Alignment.center,
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.picture_as_pdf_outlined,
                    size: 32, color: TaoistTheme.teaBrown),
                SizedBox(height: 4),
                Text('无法预览 PDF 首页',
                    style: TextStyle(
                        fontSize: 11, color: TaoistTheme.cloudGray)),
              ],
            ),
          );
        }
        return Image.memory(
          bytes,
          fit: BoxFit.cover,
          alignment: Alignment.topCenter,
          errorBuilder: (_, __, ___) => const SizedBox.shrink(),
        );
      },
    );
  }
}
