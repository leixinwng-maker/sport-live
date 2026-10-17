import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 云端 API 异常：code/message 来自服务端统一错误格式 {code, message}。
class ApiException implements Exception {
  ApiException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;

  /// HTTP 状态码（无响应时为 null）
  final int? statusCode;

  /// 4xx 客户端错误：自动重试无意义（401/403 会话问题另见 [isAuthError]）
  bool get isClientError =>
      statusCode != null && statusCode! >= 400 && statusCode! < 500;

  /// 会话失效：触发登录门，不做退避重试
  bool get isAuthError => statusCode == 401 || statusCode == 403;

  @override
  String toString() => message;
}

/// 云端 API 客户端（P2-T4）：
/// - 统一 Bearer 注入；401 自动 refresh 一次并重放，仍失败则清会话并广播
/// - token 存 flutter_secure_storage；服务器地址存 SharedPreferences
/// - 后端实际路径无 /api 前缀：/auth/register|login|refresh|me
class CloudApi {
  CloudApi._internal();
  static final CloudApi instance = CloudApi._internal();

  static const _kBaseUrl = 'api_base_url';
  static const _kAccess = 'auth_access_token';
  static const _kRefresh = 'auth_refresh_token';
  static const _kUserId = 'auth_user_id';
  static const _kEmail = 'auth_email';
  static const _kName = 'auth_display_name';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  late final Dio dio;
  Dio? _bare; // refresh 专用裸实例，避免经过拦截器造成循环

  String? accessToken;
  String? refreshToken;
  String? userId;
  String? userEmail;
  String? displayName;
  bool authenticated = false;
  bool initialized = false;

  final StreamController<void> _expiredCtrl =
      StreamController<void>.broadcast();

  /// refresh 失败 / 会话失效广播（登录门监听后切回登录页）。
  Stream<void> get sessionExpired => _expiredCtrl.stream;

  Future<bool>? _refreshing;

  Future<void> init() async {
    if (initialized) return;
    initialized = true;
    final prefs = await SharedPreferences.getInstance();
    final base = prefs.getString(_kBaseUrl) ?? '';
    dio = Dio(
      BaseOptions(
        baseUrl: base,
        connectTimeout: const Duration(seconds: 10),
        receiveTimeout: const Duration(seconds: 30),
      ),
    );

    accessToken = await _storage.read(key: _kAccess);
    refreshToken = await _storage.read(key: _kRefresh);
    userId = await _storage.read(key: _kUserId);
    userEmail = await _storage.read(key: _kEmail);
    displayName = await _storage.read(key: _kName);
    authenticated =
        (accessToken?.isNotEmpty ?? false) && (refreshToken?.isNotEmpty ?? false);

    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) {
          final t = accessToken;
          if (t != null && t.isNotEmpty) {
            options.headers['Authorization'] = 'Bearer $t';
          }
          handler.next(options);
        },
        onError: (e, handler) async {
          if (e.response?.statusCode == 401 &&
              e.requestOptions.extra['noRetry'] != true) {
            final ok = await _tryRefresh();
            if (ok) {
              try {
                final opts = e.requestOptions..extra['noRetry'] = true;
                opts.headers['Authorization'] = 'Bearer $accessToken';
                final res = await dio.fetch<dynamic>(opts);
                return handler.resolve(res);
              } on DioException catch (retryErr) {
                return handler.next(retryErr);
              }
            }
            _expiredCtrl.add(null);
          }
          handler.next(e);
        },
      ),
    );
  }

  // ---------- 服务器地址 ----------

  String get baseUrl => dio.options.baseUrl;

  Future<void> setBaseUrl(String url) async {
    final base = url.trim();
    final normalized =
        base.endsWith('/') ? base.substring(0, base.length - 1) : base;
    dio.options.baseUrl = normalized;
    _bare?.options.baseUrl = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kBaseUrl, normalized);
  }

  // ---------- 认证 ----------

  /// 注册并保存会话。返回最终展示昵称（后端缺省取邮箱前缀）。
  Future<String> register({
    required String email,
    required String password,
    String displayName = '',
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/auth/register',
        data: {
          'email': email,
          'password': password,
          'display_name': displayName,
        },
      );
      await _saveAccount(_data(res), email);
      return displayName.isNotEmpty ? displayName : email.split('@').first;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// 登录并保存会话。
  Future<void> login({required String email, required String password}) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/auth/login',
        data: {'email': email, 'password': password},
      );
      await _saveAccount(_data(res), email);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// 验证当前会话（测试连接 / 会话健康检查）。
  Future<Map<String, dynamic>?> me() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/auth/me');
      return res.data;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// 清除本地会话（token 全删，不动本地缓存数据）。
  Future<void> clearSession() async {
    accessToken = null;
    refreshToken = null;
    userId = null;
    userEmail = null;
    displayName = null;
    authenticated = false;
    for (final key in [_kAccess, _kRefresh, _kUserId, _kEmail, _kName]) {
      await _storage.delete(key: key);
    }
  }

  // ---------- 同步（P2-T5）----------

  /// POST /sync/push：批量上传变更。
  /// 返回 {results: [{table,id,status,server_version,conflict,server_record}], server_time}
  Future<Map<String, dynamic>> pushChanges({
    required String deviceId,
    required String platform,
    required List<Map<String, dynamic>> changes,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/sync/push',
        data: {
          'device_id': deviceId,
          'platform': platform,
          'changes': changes,
        },
      );
      return _data(res);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// POST /sync/pull：游标翻页拉取增量。
  /// 返回 {changes: [{table,id,op,version,updated_at,data}], has_more, next_since, next_cursor_id}
  Future<Map<String, dynamic>> pullChanges({
    required String deviceId,
    String? since,
    String? cursorId,
    int? limit,
  }) async {
    try {
      final res = await dio.post<Map<String, dynamic>>(
        '/sync/pull',
        data: {
          'device_id': deviceId,
          'since': since,
          'cursor_id': cursorId,
          if (limit != null) 'limit': limit,
        },
      );
      return _data(res);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  // ---------- AI 服务配置云端备份 ----------

  /// GET /ai-settings：拉取云端 AI 配置（未备份过时 models 为空数组）。
  Future<Map<String, dynamic>> fetchAiSettings() async {
    try {
      final res = await dio.get<Map<String, dynamic>>('/ai-settings');
      return _data(res);
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// PUT /ai-settings：整体覆盖上传（含明文 API Key，走 HTTPS + Bearer）。
  Future<String?> uploadAiSettings({
    required List<Map<String, dynamic>> models,
    String? activeId,
    Map<String, dynamic>? vision,
  }) async {
    try {
      final res = await dio.put<Map<String, dynamic>>(
        '/ai-settings',
        data: {
          'models': models,
          'activeId': activeId,
          if (vision != null) 'vision': vision,
        },
      );
      return _data(res)['updatedAt'] as String?;
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  /// DELETE /ai-settings：清空云端备份。
  Future<void> deleteAiSettings() async {
    try {
      await dio.delete<Map<String, dynamic>>('/ai-settings');
    } on DioException catch (e) {
      throw _wrap(e);
    }
  }

  // ---------- 内部 ----------

  Map<String, dynamic> _data(Response<Map<String, dynamic>?> res) {
    final data = res.data;
    if (data == null) throw ApiException('server', '服务端返回为空');
    return data;
  }

  Future<void> _saveAccount(Map<String, dynamic> data, String email) async {
    userEmail = email;
    await _persist(data);
    await _storage.write(key: _kEmail, value: email);
  }

  Future<void> _persist(Map<String, dynamic> data) async {
    accessToken = data['access_token'] as String?;
    refreshToken = data['refresh_token'] as String? ?? refreshToken;
    userId = data['user_id'] as String? ?? userId;
    authenticated =
        (accessToken?.isNotEmpty ?? false) && (refreshToken?.isNotEmpty ?? false);
    await _storage.write(key: _kAccess, value: accessToken);
    await _storage.write(key: _kRefresh, value: refreshToken);
    await _storage.write(key: _kUserId, value: userId);
  }

  Future<bool> _tryRefresh() async {
    final pending = _refreshing;
    if (pending != null) return pending;
    final task = _doRefresh();
    _refreshing = task;
    final ok = await task;
    _refreshing = null;
    return ok;
  }

  Future<bool> _doRefresh() async {
    final rt = refreshToken;
    if (rt == null || rt.isEmpty) return false;
    try {
      final bare = _bare ??= Dio(
        BaseOptions(
          baseUrl: dio.options.baseUrl,
          connectTimeout: const Duration(seconds: 10),
          receiveTimeout: const Duration(seconds: 30),
        ),
      );
      final res = await bare.post<Map<String, dynamic>>(
        '/auth/refresh',
        data: {'refresh_token': rt},
      );
      final data = res.data;
      if (data == null) return false;
      await _persist(data);
      return true;
    } catch (_) {
      await clearSession();
      return false;
    }
  }

  ApiException _wrap(DioException e) {
    final status = e.response?.statusCode;
    final data = e.response?.data;
    if (data is Map) {
      final msg = data['message'];
      final code = data['code'];
      if (msg is String && msg.isNotEmpty) {
        return ApiException(code is String ? code : 'error', msg,
            statusCode: status);
      }
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
      case DioExceptionType.connectionError:
        return ApiException('network', '网络连接失败，请检查网络或服务器地址',
            statusCode: status);
      default:
        return ApiException('server', '服务异常（${status ?? e.type.name}）',
            statusCode: status);
    }
  }
}
