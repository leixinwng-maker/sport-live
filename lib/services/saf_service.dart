import 'package:flutter/services.dart';

/// Gadgetbridge 导出文件元信息
class GbExportFile {
  final String name;

  /// 拷贝到应用缓存后的路径（仅 copyExport 返回时有效）
  final String? path;
  final DateTime? lastModified;
  final int size;

  const GbExportFile({
    required this.name,
    this.path,
    this.lastModified,
    this.size = 0,
  });
}

/// Gadgetbridge 导出文件夹访问（SAF / MethodChannel 封装）
///
/// Android 11+ 无法直接读取 `/Android/data` 下的 GB 数据目录，
/// 由用户在系统文件选择器中授权 GB「自动导出」目标文件夹，
/// 原生侧持久化该授权并负责查找/拷贝导出文件。
class SafService {
  const SafService();

  static const MethodChannel _channel = MethodChannel('wendao/gadgetbridge_saf');

  /// GB 自动导出的候选文件名（不同 GB 版本可能带/不带 .db 后缀）
  static const List<String> exportNameCandidates = ['Gadgetbridge', 'Gadgetbridge.db'];

  /// 发起文件夹选择（系统 SAF 选择器）；取消返回 null
  Future<String?> pickFolder() async {
    try {
      return await _channel.invokeMethod<String>('pickFolder');
    } on PlatformException {
      rethrow;
    }
  }

  /// 已持久化的导出文件夹 treeUri（未选择过返回 null）
  Future<String?> getSavedFolder() async {
    try {
      return await _channel.invokeMethod<String>('getSavedFolder');
    } on PlatformException {
      return null;
    }
  }

  /// 清除文件夹授权（撤回时调用）
  Future<void> clearSavedFolder() async {
    try {
      await _channel.invokeMethod('clearSavedFolder');
    } on PlatformException {
      // 忽略：清除失败不影响本地数据清空
    }
  }

  /// 查询导出文件是否存在于已授权文件夹（未授权/不存在返回 null）
  Future<GbExportFile?> statExport() async {
    try {
      final map = await _channel.invokeMethod<Map<Object?, Object?>>(
        'statExportFile',
        {'candidates': exportNameCandidates},
      );
      return _mapToFile(map);
    } on PlatformException {
      return null;
    }
  }

  /// 拷贝导出文件到应用缓存，返回缓存路径与元信息（未授权/不存在返回 null）
  Future<GbExportFile?> copyExport() async {
    final map = await _channel.invokeMethod<Map<Object?, Object?>>(
      'copyExportFile',
      {'candidates': exportNameCandidates},
    );
    return _mapToFile(map);
  }

  GbExportFile? _mapToFile(Map<Object?, Object?>? map) {
    if (map == null) return null;
    final name = map['name'] as String?;
    if (name == null) return null;
    final lastModMs = (map['lastModified'] as num?)?.toInt();
    return GbExportFile(
      name: name,
      path: map['path'] as String?,
      lastModified:
          lastModMs == null ? null : DateTime.fromMillisecondsSinceEpoch(lastModMs),
      size: (map['size'] as num?)?.toInt() ?? 0,
    );
  }
}
