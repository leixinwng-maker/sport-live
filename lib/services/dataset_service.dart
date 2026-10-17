import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 数据集服务：数据集目录 API 接入 + 精选子集下载（P6-D 开放数据的联网延伸）。
///
/// 数据源（均为公开接口 / 公开直链，详见 assets/data/evidence_kb.json 登记表）：
/// - **HuggingFace Datasets Hub 公开 API**：登记表 `sr-rag` 等条目指向该平台，
///   仅拉取元数据（数据集 id / 作者 / 下载量 / 点赞 / 标签 / 最后更新 / 文件清单），
///   **不做批量抓取、不下载整库、不再分发任何远端数据**
/// - **精选子集**：从登记表中圈定「许可已核实 + 存在公开直链 + 体积小」的
///   少量文件（CC BY 4.0 / CC0 / MIT），供用户按需下载到本地文档目录
///
/// 合规约束（硬，与 P6-D 三硬约束一致）：
/// 1. 精选子集只允许来自登记表「已接入 / 可接入」条目（许可已核实），
///    「登记题录」（许可未确认）一律**不可下载**，只能展示元数据
/// 2. HuggingFace 检索只取元数据，失败时由调用方回落本地登记表，不阻塞页面
/// 3. 下载记录仅存于本机（SharedPreferences），不上传任何信息
class DatasetService {
  DatasetService({Dio? dio, Future<Directory> Function()? rootResolver})
      : _dio = dio ?? _createDefaultDio(),
        _ownsDio = dio == null,
        _rootResolver = rootResolver ?? getApplicationDocumentsDirectory;

  final Dio _dio;
  final bool _ownsDio;
  final Future<Directory> Function() _rootResolver;

  static const String _userAgent =
      'WenDao/1.2 (personal health assistant; local-only client)';
  static const Duration _connectTimeout = Duration(seconds: 10);
  static const Duration _receiveTimeout = Duration(seconds: 30);

  /// 下载记录的 SharedPreferences 键（JSON 数组字符串）
  static const String _recordsKey = 'dataset_download_records_v1';

  /// 下载根目录名：应用文档目录/datasets/<子集id>/<文件名>
  static const String _rootDirName = 'datasets';

  static Dio _createDefaultDio() {
    return Dio(BaseOptions(
      connectTimeout: _connectTimeout,
      receiveTimeout: _receiveTimeout,
      headers: {'User-Agent': _userAgent},
    ));
  }

  /// 关闭内部创建的 Dio（外部注入的实例由调用方自行管理）
  void close() {
    if (_ownsDio) _dio.close();
  }

  // ---------------------------------------------------------------------------
  // 精选子集清单（许可均已核实，来自登记表「已接入」条目的公开直链）
  // ---------------------------------------------------------------------------

  /// 精选子集清单：registryId 必须对应登记表「已接入」条目，
  /// url 均为公开 CDN 直链（jsDelivr），许可不含任何「未确认」字样。
  static const List<CuratedDataset> curatedSubsets = [
    CuratedDataset(
      id: 'exmo-obo',
      registryId: 'exmo',
      name: 'ExMO 中医本体（OBO）',
      description: '经络腧穴开源本体的 OBO 版本，可用于术语对齐与本体浏览。',
      url: 'https://cdn.jsdelivr.net/gh/DarkKnight0-0/exmo@master/exmo.obo',
      fileName: 'exmo.obo',
      license: 'CC BY 4.0',
      sourceName: 'ExMO Ontology',
    ),
    CuratedDataset(
      id: 'rehabo-owl',
      registryId: 'rehabo',
      name: 'RehabO 康复本体（OWL）',
      description: '康复训练开放本体的 OWL 版本，覆盖康复动作与禁忌关系。',
      url:
          'https://cdn.jsdelivr.net/gh/mcwdsi/rehabo@main/src/ontology/rehabo-edit.owl',
      fileName: 'rehabo-edit.owl',
      license: 'CC0 1.0',
      sourceName: 'RehabO',
    ),
    CuratedDataset(
      id: 'lhx-strength',
      registryId: 'longhaul-exercises',
      name: '长途训练库·力量动作',
      description: '长途旅行场景下的力量训练动作库（JSON 结构化数据）。',
      url:
          'https://cdn.jsdelivr.net/gh/longhaul-fitness/exercises@main/strength.json',
      fileName: 'strength.json',
      license: 'MIT',
      sourceName: 'longhaul-fitness/exercises',
    ),
    CuratedDataset(
      id: 'lhx-flexibility',
      registryId: 'longhaul-exercises',
      name: '长途训练库·柔韧动作',
      description: '长途旅行场景下的柔韧拉伸动作库（JSON 结构化数据）。',
      url:
          'https://cdn.jsdelivr.net/gh/longhaul-fitness/exercises@main/flexibility.json',
      fileName: 'flexibility.json',
      license: 'MIT',
      sourceName: 'longhaul-fitness/exercises',
    ),
    CuratedDataset(
      id: 'lhx-cardio',
      registryId: 'longhaul-exercises',
      name: '长途训练库·心肺动作',
      description: '长途旅行场景下的心肺耐力动作库（JSON 结构化数据）。',
      url:
          'https://cdn.jsdelivr.net/gh/longhaul-fitness/exercises@main/cardio.json',
      fileName: 'cardio.json',
      license: 'MIT',
      sourceName: 'longhaul-fitness/exercises',
    ),
  ];

  // ---------------------------------------------------------------------------
  // 数据集目录 API（HuggingFace Datasets Hub，仅元数据）
  // ---------------------------------------------------------------------------

  /// 检索 HuggingFace Datasets Hub 数据集目录（按下载量降序）。
  ///
  /// 只取元数据；空关键词直接返回空列表，不发起请求。
  /// 失败抛出 [DatasetException]（中文报错），由调用方回落本地登记表。
  Future<List<HFDatasetSummary>> searchHuggingFaceDatasets(
    String query, {
    int limit = 10,
  }) async {
    final keyword = query.trim();
    if (keyword.isEmpty || limit <= 0) return const [];
    try {
      final response = await _dio.get<String>(
        'https://huggingface.co/api/datasets',
        queryParameters: <String, dynamic>{
          'search': keyword,
          'limit': limit,
          'sort': 'downloads',
          'direction': -1,
        },
        options: Options(responseType: ResponseType.plain),
      );
      return parseHuggingFaceSearch(response.data ?? '', limit: limit);
    } on DioException catch (e) {
      throw _wrapDioError(e, '检索数据集目录');
    } on FormatException {
      throw const DatasetException('数据集目录解析失败：远端返回内容不是合法 JSON');
    }
  }

  /// 获取 HuggingFace 数据集详情（含文件清单 siblings）。
  ///
  /// 失败抛出 [DatasetException]；远端不存在时中文报错含「未找到」。
  Future<HFDatasetDetail> fetchHuggingFaceDatasetDetail(String datasetId) async {
    final id = datasetId.trim();
    if (id.isEmpty) {
      throw const DatasetException('获取数据集详情失败：数据集 ID 不能为空');
    }
    try {
      final response = await _dio.get<String>(
        'https://huggingface.co/api/datasets/$id',
        options: Options(responseType: ResponseType.plain),
      );
      final detail = parseHuggingFaceDetail(response.data ?? '');
      if (detail == null) {
        throw const DatasetException('数据集详情解析失败：远端返回内容缺少必要字段');
      }
      return detail;
    } on DioException catch (e) {
      throw _wrapDioError(e, '获取数据集详情');
    } on FormatException {
      throw const DatasetException('数据集详情解析失败：远端返回内容不是合法 JSON');
    }
  }

  /// 解析目录检索响应（公开以便单测注入固定 JSON，不触网）。
  ///
  /// 防御性解析：剔除非对象元素与空 id 条目；字段缺失安全回落。
  static List<HFDatasetSummary> parseHuggingFaceSearch(
    String body, {
    int limit = 10,
  }) {
    final decoded = json.decode(body);
    if (decoded is! List) return const [];

    final out = <HFDatasetSummary>[];
    for (final raw in decoded) {
      if (raw is! Map) continue;
      final id = (raw['id'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      final tags = <String>[];
      if (raw['tags'] is List) {
        for (final t in raw['tags'] as List) {
          final s = t.toString().trim();
          if (s.isNotEmpty) tags.add(s);
        }
      }
      out.add(HFDatasetSummary(
        id: id,
        likes: _asInt(raw['likes']),
        downloads: _asInt(raw['downloads']),
        lastModified: (raw['lastModified'] ?? '').toString(),
        tags: tags,
      ));
      if (out.length >= limit) break;
    }
    return out;
  }

  /// 解析数据集详情响应（公开以便单测注入固定 JSON，不触网）。
  ///
  /// 返回 null 表示缺少必要字段（如空 id）；文件清单取自 siblings[].rfilename。
  static HFDatasetDetail? parseHuggingFaceDetail(String body) {
    final decoded = json.decode(body);
    if (decoded is! Map) return null;
    final id = (decoded['id'] ?? '').toString().trim();
    if (id.isEmpty) return null;

    final files = <String>[];
    final siblings = decoded['siblings'];
    if (siblings is List) {
      for (final s in siblings) {
        if (s is! Map) continue;
        final name = (s['rfilename'] ?? '').toString().trim();
        if (name.isNotEmpty) files.add(name);
      }
    }
    return HFDatasetDetail(
      summary: HFDatasetSummary(
        id: id,
        likes: _asInt(decoded['likes']),
        downloads: _asInt(decoded['downloads']),
        lastModified: (decoded['lastModified'] ?? '').toString(),
        tags: (decoded['tags'] as List?)?.map((e) => e.toString()).toList() ??
            const <String>[],
      ),
      author: id.contains('/') ? id.split('/').first : '',
      files: files,
      description: (decoded['description'] ?? '').toString(),
    );
  }

  // ---------------------------------------------------------------------------
  // 精选子集下载
  // ---------------------------------------------------------------------------

  /// 下载精选子集到本地文档目录 `datasets/<子集id>/<文件名>`。
  ///
  /// 流程：先写入 `.part` 临时文件，成功后原子改名；请求失败时清理残留临时文件。
  /// [onProgress] 回调（已收字节数, 总字节数；总字节数未知时为 null）。
  /// 成功返回写入 [DatasetDownloadRecord]（重下会覆盖同 id 旧记录）。
  Future<DatasetDownloadRecord> downloadSubset(
    CuratedDataset subset, {
    void Function(int received, int? total)? onProgress,
    CancelToken? cancelToken,
  }) async {
    final root = await _rootDirectory();
    // _rootDirectory() 已含 datasets 目录名，这里不能再拼一次 _rootDirName
    final targetPath = path.join(root.path, subset.id, subset.fileName);
    try {
      final response = await _dio.get<List<int>>(
        subset.url,
        options: Options(responseType: ResponseType.bytes),
        onReceiveProgress: (received, total) =>
            onProgress?.call(received, total <= 0 ? null : total),
        cancelToken: cancelToken,
      );
      final bytes = response.data ?? const <int>[];
      if (bytes.isEmpty) {
        throw const DatasetException('下载失败：远端返回内容为空');
      }
      final tmp = File('$targetPath.part');
      await tmp.parent.create(recursive: true);
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(targetPath);

      final record = DatasetDownloadRecord(
        subsetId: subset.id,
        name: subset.name,
        fileName: subset.fileName,
        filePath: targetPath,
        url: subset.url,
        license: subset.license,
        fileSizeBytes: bytes.length,
        downloadedAt: DateTime.now().toIso8601String(),
      );
      await _saveRecord(record);
      return record;
    } on DioException catch (e) {
      await _cleanupPartFile(targetPath);
      throw _wrapDioError(e, '下载「${subset.name}」');
    }
  }

  /// 读取全部下载记录（按下载时间降序）。
  Future<List<DatasetDownloadRecord>> loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_recordsKey);
    if (raw == null || raw.isEmpty) return <DatasetDownloadRecord>[];
    final Object? decoded;
    try {
      decoded = json.decode(raw);
    } on FormatException {
      // 记录损坏时安全返回空，不阻塞页面（返回可变列表，调用方可能做增删）
      return <DatasetDownloadRecord>[];
    }
    if (decoded is! List) return <DatasetDownloadRecord>[];
    final records =
        decoded.whereType<Map>().map(DatasetDownloadRecord.fromMap).toList();
    records.sort((a, b) => b.downloadedAt.compareTo(a.downloadedAt));
    return records;
  }

  /// 删除已下载的子集：删除本地文件并移除记录。
  ///
  /// 路径防护：只允许删除下载根目录内的文件（防越界）；
  /// 记录不存在时静默返回（重复删除安全）。
  Future<void> deleteDownload(String subsetId) async {
    final records = await loadRecords();
    DatasetDownloadRecord? target;
    for (final r in records) {
      if (r.subsetId == subsetId) {
        target = r;
        break;
      }
    }
    if (target == null) return;

    final root = await _rootDirectory();
    final rootPrefix = '${path.normalize(root.path)}${path.separator}';
    final normalized = path.normalize(target.filePath);
    if (normalized.startsWith(rootPrefix)) {
      final f = File(normalized);
      if (await f.exists()) {
        await f.delete();
      }
    }
    // 无论文件能否删除，记录都移除（避免残留失效记录）
    records.removeWhere((r) => r.subsetId == subsetId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recordsKey,
      json.encode(records.map((r) => r.toMap()).toList()),
    );
  }

  /// 字节数人性化展示（B / KB / MB / GB）。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    final kb = bytes / 1024;
    if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
    final mb = kb / 1024;
    if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
    return '${(mb / 1024).toStringAsFixed(1)} GB';
  }

  // ---------------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------------

  Future<Directory> _rootDirectory() async {
    final docs = await _rootResolver();
    return Directory(path.join(docs.path, _rootDirName));
  }

  Future<void> _saveRecord(DatasetDownloadRecord record) async {
    final records = await loadRecords();
    records.removeWhere((r) => r.subsetId == record.subsetId);
    records.insert(0, record);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _recordsKey,
      json.encode(records.map((r) => r.toMap()).toList()),
    );
  }

  Future<void> _cleanupPartFile(String targetPath) async {
    final part = File('$targetPath.part');
    if (await part.exists()) {
      try {
        await part.delete();
      } on FileSystemException {
        // 安静失败：临时文件残留不影响正确性
      }
    }
  }

  /// 把 DioException 包装为中文 DatasetException（对齐项目报错风格）
  DatasetException _wrapDioError(DioException e, String action) {
    final code = e.response?.statusCode;
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return DatasetException('$action失败：请求超时，请检查网络后重试', statusCode: code);
      case DioExceptionType.cancel:
        return DatasetException('$action已被取消', statusCode: code);
      case DioExceptionType.badResponse:
        if (code == 404) {
          return DatasetException('$action失败：远端未找到该数据集（HTTP 404）',
              statusCode: code);
        }
        return DatasetException('$action失败：服务返回异常（HTTP $code）', statusCode: code);
      case DioExceptionType.connectionError:
        return DatasetException('$action失败：网络连接异常，请检查网络后重试', statusCode: code);
      case DioExceptionType.badCertificate:
        return DatasetException('$action失败：证书校验未通过', statusCode: code);
      default:
        return DatasetException('$action失败：${e.message ?? '未知网络错误'}',
            statusCode: code);
    }
  }

  static int _asInt(Object? raw) {
    if (raw is int) return raw;
    if (raw is num) return raw.toInt();
    if (raw is String) return int.tryParse(raw.trim()) ?? 0;
    return 0;
  }
}

/// 数据集服务统一异常（中文报错，可带 HTTP 状态码）
class DatasetException implements Exception {
  const DatasetException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// 精选子集定义（许可均已核实的可下载小文件）
class CuratedDataset {
  const CuratedDataset({
    required this.id,
    required this.registryId,
    required this.name,
    required this.description,
    required this.url,
    required this.fileName,
    required this.license,
    required this.sourceName,
  });

  final String id;
  final String registryId;
  final String name;
  final String description;
  final String url;
  final String fileName;
  final String license;
  final String sourceName;
}

/// HuggingFace 数据集元数据摘要（仅元数据，不含任何数据内容）
class HFDatasetSummary {
  const HFDatasetSummary({
    required this.id,
    required this.likes,
    required this.downloads,
    required this.lastModified,
    required this.tags,
  });

  final String id;
  final int likes;
  final int downloads;
  final String lastModified;
  final List<String> tags;
}

/// HuggingFace 数据集详情（含文件清单）
class HFDatasetDetail {
  const HFDatasetDetail({
    required this.summary,
    required this.author,
    required this.files,
    required this.description,
  });

  final HFDatasetSummary summary;
  final String author;
  final List<String> files;
  final String description;
}

/// 精选子集下载记录（本机持久化，JSON 数组存于 SharedPreferences）
class DatasetDownloadRecord {
  const DatasetDownloadRecord({
    required this.subsetId,
    required this.name,
    required this.fileName,
    required this.filePath,
    required this.url,
    required this.license,
    required this.fileSizeBytes,
    required this.downloadedAt,
  });

  final String subsetId;
  final String name;
  final String fileName;
  final String filePath;
  final String url;
  final String license;
  final int fileSizeBytes;
  final String downloadedAt; // ISO8601

  Map<String, dynamic> toMap() => <String, dynamic>{
        'subsetId': subsetId,
        'name': name,
        'fileName': fileName,
        'filePath': filePath,
        'url': url,
        'license': license,
        'fileSizeBytes': fileSizeBytes,
        'downloadedAt': downloadedAt,
      };

  factory DatasetDownloadRecord.fromMap(Map<dynamic, dynamic> map) {
    final size = map['fileSizeBytes'];
    return DatasetDownloadRecord(
      subsetId: (map['subsetId'] ?? '').toString(),
      name: (map['name'] ?? '').toString(),
      fileName: (map['fileName'] ?? '').toString(),
      filePath: (map['filePath'] ?? '').toString(),
      url: (map['url'] ?? '').toString(),
      license: (map['license'] ?? '').toString(),
      fileSizeBytes: size is int ? size : int.tryParse('$size') ?? 0,
      downloadedAt: (map['downloadedAt'] ?? '').toString(),
    );
  }
}
