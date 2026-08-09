import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/database_helper.dart';

/// 数据同步模块
/// 支持三种方式：
/// 1. 局域网同步（同一WiFi下，电脑端开启服务，手机端连接）
/// 2. 云盘同步（通过WebDAV协议，兼容坚果云/阿里云盘等）
/// 3. 文件导出/导入（手动备份）
class SyncService {
  static const String _syncServerKey = 'sync_server_url';
  static const String _webdavUrlKey = 'webdav_url';
  static const String _webdavUserKey = 'webdav_user';
  static const String _webdavPassKey = 'webdav_pass';

  // ============ 局域网同步 ============
  /// 导出数据为JSON字符串（发送端）
  Future<String> exportToJson() async {
    final data = await DatabaseHelper.instance.exportAllData();
    return jsonEncode(data);
  }

  /// 导入JSON数据（接收端）
  Future<void> importFromJson(String jsonString) async {
    final data = jsonDecode(jsonString) as Map<String, dynamic>;
    await DatabaseHelper.instance.importAllData(data);
  }

  /// 发送数据到局域网服务端
  Future<void> sendToLanServer({
    required String serverUrl,
    required String dataJson,
  }) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(Uri.parse('$serverUrl/sync'));
      request.headers.contentType = ContentType.json;
      request.write(dataJson);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200) {
        throw Exception('同步失败: ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  // ============ WebDAV云盘同步 ============
  /// 保存WebDAV配置
  Future<void> saveWebDAVConfig({
    required String url,
    required String username,
    required String password,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_webdavUrlKey, url);
    await prefs.setString(_webdavUserKey, username);
    await prefs.setString(_webdavPassKey, password);
  }

  Future<Map<String, String>> getWebDAVConfig() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'url': prefs.getString(_webdavUrlKey) ?? '',
      'username': prefs.getString(_webdavUserKey) ?? '',
      'password': prefs.getString(_webdavPassKey) ?? '',
    };
  }

  /// 上传数据到WebDAV（坚果云/阿里云盘等支持WebDAV的网盘）
  Future<void> uploadToWebDAV() async {
    final config = await getWebDAVConfig();
    if (config['url']!.isEmpty) {
      throw Exception('请先配置WebDAV同步');
    }

    final dataJson = await exportToJson();
    final client = HttpClient();
    try {
      final uri = Uri.parse('${config['url']}/ai_planner_backup.json');
      final request = await client.putUrl(uri);
      final credentials =
          base64Encode(utf8.encode('${config['username']}:${config['password']}'));
      request.headers.set('Authorization', 'Basic $credentials');
      request.headers.contentType = ContentType.json;
      request.write(dataJson);
      final response = await request.close();
      await response.drain<void>();
      if (response.statusCode != 200 && response.statusCode != 201) {
        throw Exception('上传失败: ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  /// 从WebDAV下载数据
  Future<void> downloadFromWebDAV() async {
    final config = await getWebDAVConfig();
    if (config['url']!.isEmpty) {
      throw Exception('请先配置WebDAV同步');
    }

    final client = HttpClient();
    try {
      final uri = Uri.parse('${config['url']}/ai_planner_backup.json');
      final request = await client.getUrl(uri);
      final credentials =
          base64Encode(utf8.encode('${config['username']}:${config['password']}'));
      request.headers.set('Authorization', 'Basic $credentials');
      final response = await request.close();
      if (response.statusCode == 200) {
        final data = await response.transform(utf8.decoder).join();
        await importFromJson(data);
      } else {
        throw Exception('下载失败: ${response.statusCode}');
      }
    } finally {
      client.close();
    }
  }

  // ============ 本地文件备份 ============
  /// 导出到本地文件
  Future<String> exportToFile() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File('${dir.path}/ai_planner_backup_'
        '${DateTime.now().millisecondsSinceEpoch}.json');
    final dataJson = await exportToJson();
    await file.writeAsString(dataJson);
    return file.path;
  }

  /// 从本地文件导入
  Future<void> importFromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在');
    }
    final dataJson = await file.readAsString();
    await importFromJson(dataJson);
  }

  // ============ 局域网服务端（电脑端运行） ============
  /// 启动局域网同步服务器（电脑端）
  Future<void> startLanServer(int port) async {
    final server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    // ignore: avoid_print
    print('局域网同步服务器已启动: http://${server.address.address}:$port');
    await for (final request in server) {
      if (request.uri.path == '/sync' && request.method == 'POST') {
        final data = await utf8.decoder.bind(request).join();
        await importFromJson(data);
        request.response
          ..statusCode = 200
          ..write('{"status":"ok"}');
      } else if (request.uri.path == '/ping' && request.method == 'GET') {
        request.response
          ..statusCode = 200
          ..write('{"status":"online"}');
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    }
  }

  // ============ 保存局域网服务器地址 ============
  Future<void> saveLanServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_syncServerKey, url);
  }

  Future<String> getLanServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_syncServerKey) ?? '';
  }
}
