import 'package:uuid/uuid.dart';

import '../../models/health_metric.dart';
import '../../models/health_report.dart';
import '../database_helper.dart';
import 'report_file_store.dart';

/// 报告归纳入库服务（P7-T4）。
///
/// stage —— 添加页识别完成后生成「临时报告」中间态（文件未归档时先归档）；
/// commit —— 报告 + 指标同事务落库，指标回填来源关联与备注。
class ReportIngestionService {
  ReportIngestionService._();
  static final ReportIngestionService instance = ReportIngestionService._();
  static const Uuid _uuid = Uuid();

  /// 生成临时报告（未入库）。文件尚未归档时先归档，返回的报告 filePath 即归档路径。
  /// [ocrText] 为空抛 ArgumentError——识别必须在添加页完成。
  Future<HealthReport> stage({
    required String filePath,
    required String fileType,
    required String title,
    required String ocrText,
    required DateTime date,
    String archivedPath = '',
    String aiSummary = '',
    String reportType = '体检',
  }) async {
    if (ocrText.trim().isEmpty) {
      throw ArgumentError('识别文本为空，请先完成文件识别');
    }
    var archived = archivedPath.trim();
    if (filePath.trim().isNotEmpty && archived.isEmpty) {
      archived = await ReportFileStore.instance.importToArchive(filePath);
    }
    return HealthReport(
      id: _uuid.v4(),
      date: date,
      title: title,
      filePath: archived,
      fileType: fileType,
      ocrText: ocrText,
      aiSummary: aiSummary,
      reportType: reportType,
      createdAt: DateTime.now(),
    );
  }

  /// 确认入库：指标回填 id / source_report_id / 备注来源后，
  /// 与报告同一事务落库（DatabaseHelper.commitReportIngestion）。返回报告 rowId。
  /// [replaceMetrics] 为 true 时（P7-T5 重新归纳），同事务先删旧关联指标。
  Future<String> commit(
      HealthReport report, List<HealthMetric> metrics,
      {bool replaceMetrics = false}) async {
    final rowId = report.id ?? _uuid.v4();
    final source = '来源：《${report.title}》';
    final tagged = <HealthMetric>[];
    for (final m in metrics) {
      final note = m.note.trim();
      tagged.add(m.copyWith(
        id: m.id ?? _uuid.v4(),
        sourceReportId: m.sourceReportId.isEmpty ? rowId : m.sourceReportId,
        note: note.contains(source)
            ? note
            : (note.isEmpty ? source : '$note；$source'),
      ));
    }
    return DatabaseHelper.instance.commitReportIngestion(
        report.copyWith(id: rowId), tagged,
        replaceMetrics: replaceMetrics);
  }
}
