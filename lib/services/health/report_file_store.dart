import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// 报告文件归档存储。
///
/// 现状问题：报告直接引用 FilePicker/image_picker 的缓存路径，系统清缓存会丢文件。
/// 保存报告时把文件复制进应用文档目录 `reports/yyyy/uuid.ext`，
/// DB 存归档路径；删除报告时同步删除文件。
class ReportFileStore {
  static final ReportFileStore instance = ReportFileStore._();
  ReportFileStore._();

  static const _dirName = 'reports';

  /// 归档根目录：应用文档目录/reports
  Future<String> archiveRoot() async {
    final docs = await getApplicationDocumentsDirectory();
    return '${docs.path}${Platform.pathSeparator}$_dirName';
  }

  /// 把选中的文件复制进归档目录，返回归档路径。
  Future<String> importToArchive(String srcPath) async {
    final src = File(srcPath);
    if (!await src.exists()) {
      throw Exception('源文件不存在：$srcPath');
    }
    final year = DateTime.now().year.toString();
    final dir = Directory('${await archiveRoot()}'
        '${Platform.pathSeparator}$year');
    await dir.create(recursive: true);
    final dotIndex = srcPath.lastIndexOf('.');
    final ext =
        dotIndex >= 0 ? srcPath.substring(dotIndex + 1).toLowerCase() : 'dat';
    final destPath =
        '${dir.path}${Platform.pathSeparator}${const Uuid().v4()}.$ext';
    await src.copy(destPath);
    return destPath;
  }

  /// 安静删除归档文件：只允许删除归档目录内的文件（防越界），不存在不报错。
  Future<void> delete(String? archivedPath) async {
    if (archivedPath == null || archivedPath.isEmpty) return;
    try {
      final root = await archiveRoot();
      final prefix = '$root${Platform.pathSeparator}';
      final normalized = archivedPath.replaceAll('/', Platform.pathSeparator);
      if (!normalized.startsWith(prefix)) return; // 非归档路径，拒绝删除
      final f = File(normalized);
      if (await f.exists()) {
        await f.delete();
      }
    } catch (_) {
      // 安静失败：文件残留不影响数据正确性
    }
  }
}
