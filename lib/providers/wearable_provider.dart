import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:health/health.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/wearable.dart';
import '../services/database_helper.dart';
import '../services/gadgetbridge_gateway.dart';
import '../services/health_consent.dart';
import '../services/wearable_aggregator.dart';

/// P4-C 穿戴数据接入：平台网关抽象
///
/// 把 `health` 插件（MethodChannel）隔离在实现类 [HealthPluginGateway] 内，
/// 使 [WearableProvider] 可在单测中注入假网关，完全不触碰平台通道。
abstract class WearableGateway {
  /// 平台/健康服务是否可用（Android：Health Connect；iOS：健康 App）
  Future<bool> isAvailable();

  /// 是否已获得读取授权（Android 为聚合结果；iOS READ 可能返回 null）
  Future<bool?> hasPermissions();

  /// 发起授权请求（真机弹窗）
  Future<bool> requestAuthorization();

  /// 撤回授权（Android：拔权限，需重启 App 生效；iOS 为空操作）
  Future<void> revokeAuthorization();

  /// 读取 [start]~[end] 区间的原始数据点（只读）
  Future<List<WearableRawPoint>> fetch({
    required DateTime start,
    required DateTime end,
  });
}

/// `health` 插件实现：Health Connect（Android）/ HealthKit（iOS）
class HealthPluginGateway implements WearableGateway {
  HealthPluginGateway({Health? health}) : _health = health ?? Health();

  final Health _health;
  bool _configured = false;
  List<HealthDataType>? _readTypes;

  /// 仅在移动端使用插件（桌面端调试无健康平台实现）
  bool get _supported => !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// 读取类型（由 [kReadTypeNames] 解析为插件枚举）
  List<HealthDataType> get _types {
    final cached = _readTypes;
    if (cached != null) return cached;
    final out = <HealthDataType>[];
    for (final name in kReadTypeNames) {
      for (final t in HealthDataType.values) {
        if (t.name == name) {
          out.add(t);
          break;
        }
      }
    }
    _readTypes = out;
    return out;
  }

  List<HealthDataAccess> get _readOnly =>
      List<HealthDataAccess>.filled(_types.length, HealthDataAccess.READ);

  Future<void> _ensureConfigured() async {
    if (_configured) return;
    await _health.configure();
    _configured = true;
  }

  @override
  Future<bool> isAvailable() async {
    if (!_supported) return false;
    await _ensureConfigured();
    try {
      return await _health.isHealthConnectAvailable();
    } catch (e) {
      debugPrint('WearableGateway.isAvailable 失败：$e');
      return false;
    }
  }

  @override
  Future<bool?> hasPermissions() async {
    if (!_supported) return false;
    await _ensureConfigured();
    try {
      return await _health.hasPermissions(_types, permissions: _readOnly);
    } catch (e) {
      debugPrint('WearableGateway.hasPermissions 失败：$e');
      return false;
    }
  }

  @override
  Future<bool> requestAuthorization() async {
    if (!_supported) return false;
    await _ensureConfigured();
    return _health.requestAuthorization(_types, permissions: _readOnly);
  }

  @override
  Future<void> revokeAuthorization() async {
    if (!_supported) return;
    await _ensureConfigured();
    await _health.revokePermissions();
  }

  @override
  Future<List<WearableRawPoint>> fetch({
    required DateTime start,
    required DateTime end,
  }) async {
    if (!_supported) return const [];
    await _ensureConfigured();
    final points = await _health.getHealthDataFromTypes(
      types: _types,
      startTime: start,
      endTime: end,
    );
    final out = <WearableRawPoint>[];
    for (final p in points) {
      final raw = _toRaw(p);
      if (raw != null) out.add(raw);
    }
    return out;
  }

  /// 插件数据点 → 平台无关原始点；未知类型返回 null（直接丢弃）
  WearableRawPoint? _toRaw(HealthDataPoint p) {
    final spec = specOf(p.type.name);
    if (spec == null) return null;

    double? value;
    Map<String, dynamic>? extra;
    final v = p.value;
    if (v is NumericHealthValue) {
      value = _normalize(p.type.name, v.numericValue.toDouble(), p.unit);
    } else if (v is WorkoutHealthValue) {
      extra = {
        'activity': v.workoutActivityType.name,
        if (v.totalEnergyBurned != null) 'energyKcal': v.totalEnergyBurned,
      };
    }

    return WearableRawPoint(
      dataType: p.type.name,
      value: value,
      start: p.dateFrom,
      end: p.dateTo,
      sourceName: p.sourceName.isEmpty ? null : p.sourceName,
      sourceDeviceId: p.sourceDeviceId.isEmpty ? null : p.sourceDeviceId,
      recordingMethod: p.recordingMethod.name,
      extra: extra,
    );
  }

  /// 单位归一化到项目展示单位（插件默认单位 → 项目单位）
  double? _normalize(String dataType, double value, HealthDataUnit unit) {
    switch (dataType) {
      case 'DISTANCE_WALKING_RUNNING':
        // 项目单位：公里
        return unit == HealthDataUnit.METER ? value / 1000 : value;
      case 'WEIGHT':
      case 'LEAN_BODY_MASS':
        // 项目单位：kg
        return unit == HealthDataUnit.GRAM ? value / 1000 : value;
      default:
        return value;
    }
  }
}

/// P4-C 穿戴数据状态与同步编排
///
/// 合规要点（PIPL §7）：
/// - 首次授权前必须经「单独同意页」（[hasConsent]），否则拒绝发起授权；
/// - 只读拉取，不回写健康平台；
/// - 本地快照存 `wearable_samples`（不进云、不入 sync_queue）；
/// - 撤回授权后立即清空本地快照，工具随即返回「未授权」。
class WearableProvider extends ChangeNotifier {
  WearableProvider({
    WearableGateway? gateway,
    DatabaseHelper? db,
    HealthConsentStore? consentStore,
  })  : _gateway = gateway ?? HealthPluginGateway(),
        _db = db ?? DatabaseHelper.instance,
        _consentStore = consentStore ?? HealthConsentStore();

  /// Gadgetbridge 模式开关的持久化键
  static const _prefGbMode = 'wearable_gateway_gb';

  /// 当前数据源网关（可在 Health Connect 与 Gadgetbridge 间切换）
  WearableGateway _gateway;
  final DatabaseHelper _db;
  final HealthConsentStore _consentStore;
  GadgetbridgeGateway? _gbGateway;
  bool _gbMode = false;

  bool _available = false;
  bool _authorized = false;
  bool _syncing = false;
  DateTime? _lastSync;
  String? _error;
  HealthConsent? _consent;

  /// 平台/健康服务是否可用
  bool get available => _available;

  /// 是否已授权读取
  bool get authorized => _authorized;

  /// 是否已完成「单独同意」（未同意不得发起授权请求）
  bool get hasConsent => _consent?.isActive ?? false;

  /// 同意留痕记录（含时间与版本号，供诊断页展示）
  HealthConsent? get consent => _consent;

  /// 健康数据是否参与云同步（默认关闭，需在同意页/诊断页单独开启）
  bool get cloudSyncEnabled => _consent?.cloudSyncEnabled ?? false;

  /// 已授权类型（中文名）；Android 授权为聚合结果，按请求类型整体给出
  List<String> get grantedTypes => _authorized
      ? kReadTypeSpecs.map((s) => s.label).toList(growable: false)
      : const [];

  /// 最近一次同步时间
  DateTime? get lastSync => _lastSync;

  /// 是否正在同步
  bool get syncing => _syncing;

  /// 最近一次错误（可读文案）
  String? get error => _error;

  /// 是否处于 Gadgetbridge 直连模式（否则走 Health Connect / HealthKit）
  bool get gbMode => _gbMode;

  /// 切换数据源：Gadgetbridge 导出库 / 平台健康服务（持久化，切换后重新探测）
  Future<void> setGadgetbridgeMode(bool on) async {
    if (_gbMode == on) return;
    _gbMode = on;
    if (on) {
      _gbGateway ??= GadgetbridgeGateway();
      _gateway = _gbGateway!;
    } else {
      _gateway = HealthPluginGateway();
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefGbMode, on);
    _available = false;
    _authorized = false;
    _error = null;
    await init();
  }

  /// 首次进入：读取同意留痕 + 探测平台可用性与现有授权状态（不弹窗）
  Future<void> init() async {
    final prefs = await SharedPreferences.getInstance();
    _gbMode = prefs.getBool(_prefGbMode) ?? false;
    if (_gbMode && _gateway is! GadgetbridgeGateway) {
      _gbGateway ??= GadgetbridgeGateway();
      _gateway = _gbGateway!;
    }
    _consent = await _consentStore.load();
    _available = await _gateway.isAvailable();
    if (_available) {
      final granted = await _gateway.hasPermissions();
      _authorized = granted ?? false;
    }
    notifyListeners();
  }

  /// 记录「单独同意」（同意页确认后调用；时间 + 版本号本地留痕）
  Future<void> agreeConsent({bool cloudSyncEnabled = false}) async {
    _consent = await _consentStore.agree(cloudSyncEnabled: cloudSyncEnabled);
    notifyListeners();
  }

  /// 单独切换健康数据云同步（默认关闭）
  Future<void> setCloudSyncEnabled(bool value) async {
    final updated = await _consentStore.setCloudSync(value);
    if (updated != null) _consent = updated;
    notifyListeners();
  }

  /// 发起授权（真机弹窗）
  ///
  /// 未完成「单独同意」或平台不可用时直接拒绝，不弹出系统授权框。
  Future<bool> requestAuthorization() async {
    _error = null;
    if (!hasConsent) {
      _error = '请先阅读并同意《健康数据单独同意》。';
      notifyListeners();
      return false;
    }
    if (!_available) {
      _error = _gbMode
          ? 'Gadgetbridge 同步仅支持 Android 设备。'
          : '当前设备不可用健康数据服务（Android 需安装并启用 Health Connect）。';
      notifyListeners();
      return false;
    }
    try {
      final ok = await _gateway.requestAuthorization();
      _authorized = ok;
      final granted = await _gateway.hasPermissions();
      if (granted != null) _authorized = granted;
      notifyListeners();
      return _authorized;
    } catch (e) {
      _error = '授权失败：$e';
      notifyListeners();
      return false;
    }
  }

  /// 撤回授权：断授权 + 清空本地快照 + 留痕撤回时间（合规要求）
  Future<void> revokeAuthorization() async {
    _error = null;
    try {
      await _gateway.revokeAuthorization();
    } catch (e) {
      debugPrint('撤回授权失败（仍继续清空本地数据）：$e');
    }
    await _db.clearWearableSamples();
    _authorized = false;
    _lastSync = null;
    _consent = await _consentStore.withdraw();
    notifyListeners();
  }

  /// 只读同步最近 [days] 天数据到本地快照（默认 30 天）
  ///
  /// 返回本次写入的样本条数；未授权或平台不可用时返回 0 并置 [error]。
  Future<int> syncRecent({int days = 30}) async {
    if (!_available) {
      _error = _gbMode
          ? 'Gadgetbridge 同步仅支持 Android 设备。'
          : '当前设备不可用健康数据服务（Android 需安装并启用 Health Connect）。';
      notifyListeners();
      return 0;
    }
    if (!_authorized) {
      _error = _gbMode
          ? '尚未选择 Gadgetbridge 导出文件夹，请先完成授权。'
          : '尚未授权健康数据，请先完成授权。';
      notifyListeners();
      return 0;
    }
    _syncing = true;
    _error = null;
    notifyListeners();
    try {
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final start = today.subtract(Duration(days: days <= 1 ? 0 : days - 1));
      final raws = await _gateway.fetch(start: start, end: now);
      final samples = toSamples(raws, now: now);
      final saved = await _db.saveWearableSamples(samples);
      _lastSync = DateTime.now();
      return saved;
    } catch (e) {
      _error = '同步失败：$e';
      return 0;
    } finally {
      _syncing = false;
      notifyListeners();
    }
  }

  /// 生成最近 [days] 天的聚合摘要（供智能体工具与诊断页）
  Future<WearableSnapshot> snapshot({int days = 7}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days <= 1 ? 0 : days - 1));
    final samples = await _db.getWearableSamples(from: start, to: now);
    return aggregate(samples, days: days, now: now);
  }

  /// 读取窗口内全部快照（诊断页展示用）
  Future<List<WearableSample>> samples({int days = 30}) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = today.subtract(Duration(days: days <= 1 ? 0 : days - 1));
    return _db.getWearableSamples(from: start, to: now);
  }

  /// 数据源诊断：可用性 / 授权 / 逐类型最近数据时间 / 最近同步
  Future<WearableSourceDiagnosis> sourceDiagnosis() async {
    final samples = await _db.getWearableSamples();
    return WearableSourceDiagnosis(
      available: _available,
      authorized: _authorized,
      grantedLabels: grantedTypes,
      lastDataAt: lastDataAtOf(samples),
      lastSync: _lastSync,
      error: _error,
    );
  }

  /// 清除已同步健康数据（用户主动删除）
  Future<void> clearSyncedData() async {
    await _db.clearWearableSamples();
    _lastSync = null;
    notifyListeners();
  }
}
