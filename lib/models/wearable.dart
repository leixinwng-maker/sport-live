/// P4-C 运动健康数据接入：穿戴/健康平台的数据结构
///
/// 三层结构：
/// 1. [WearableRawPoint]：网关（`health` 插件）拍平后的原始点，与插件模型解耦，
///    便于单测直接注入模拟数据（不触碰平台通道）；
/// 2. [WearableSample]：落库后的本地快照行；
/// 3. [WearableSnapshot] / [WearableSourceDiagnosis]：聚合摘要与数据源诊断。
library;

import 'dart:convert';

/// 穿戴/健康平台原始数据点（网关 → Provider 的传输结构）
class WearableRawPoint {
  /// `HealthDataType` 的枚举名，如 `STEPS`、`RESTING_HEART_RATE`
  final String dataType;

  /// 数值（睡眠类为分钟数；`WORKOUT` 为 null，信息在 [extra] 中）
  final double? value;

  final DateTime start;
  final DateTime end;

  /// 数据来源 App（如「小米运动健康」）
  final String? sourceName;
  final String? sourceDeviceId;

  /// 记录方式（`RecordingMethod` 枚举名）
  final String? recordingMethod;

  /// 附加信息：锻炼记录为 `{'activity': '跑步', 'energyKcal': 320}`
  final Map<String, dynamic>? extra;

  const WearableRawPoint({
    required this.dataType,
    required this.value,
    required this.start,
    required this.end,
    this.sourceName,
    this.sourceDeviceId,
    this.recordingMethod,
    this.extra,
  });
}

/// 本地留存的穿戴数据快照（只读拉取，不回写健康平台）
///
/// 合规要点（P4-C / PIPL §7）：
/// - 该表默认**不参与云同步**：仅当用户在同意页开启 `cloudSyncEnabled` 后，
///   写路径才把同步列写入 `sync_queue` 参与上传；未开启时绝不出本机；
/// - 去重键为「数据类型 + 起始时间」，重复同步只刷新数值、不新增行；
/// - 仅用于本地摘要与智能体建议，原始记录集不整体外发大模型。
class WearableSample {
  /// 去重键：`dataType|startTime(ISO8601)`
  final String id;

  /// `HealthDataType` 枚举名
  final String dataType;

  /// 中文展示名（如「静息心率」）
  final String label;

  /// 对应的项目健康指标类型（如「体重」「收缩压」）；无落点则为 null
  final String? metricType;

  final double? value;

  /// 项目侧展示单位（如 kg / % / 次/分）
  final String? unit;

  final DateTime startTime;
  final DateTime endTime;

  final String? sourceName;
  final String? sourceDeviceId;
  final String? recordingMethod;

  /// 附加信息 JSON 字符串（睡眠分期、锻炼类型与消耗等）
  final String? extra;

  final DateTime createdAt;

  const WearableSample({
    required this.id,
    required this.dataType,
    required this.label,
    required this.metricType,
    required this.value,
    required this.unit,
    required this.startTime,
    required this.endTime,
    required this.createdAt,
    this.sourceName,
    this.sourceDeviceId,
    this.recordingMethod,
    this.extra,
  });

  /// 去重键生成：类型 + 起始时间
  static String dedupId(String dataType, DateTime startTime) =>
      '$dataType|${startTime.toIso8601String()}';

  /// 解析 [extra] JSON（失败返回空 Map）
  Map<String, dynamic> get extraMap {
    final raw = extra;
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
    } catch (_) {
      return const {};
    }
  }

  Map<String, Object?> toMap() => {
        'id': id,
        'data_type': dataType,
        'label': label,
        'metric_type': metricType,
        'value': value,
        'unit': unit,
        'start_time': startTime.toIso8601String(),
        'end_time': endTime.toIso8601String(),
        'source_name': sourceName,
        'source_device_id': sourceDeviceId,
        'recording_method': recordingMethod,
        'extra': extra,
        'created_at': createdAt.toIso8601String(),
      };

  factory WearableSample.fromMap(Map<String, dynamic> map) => WearableSample(
        id: map['id'] as String,
        dataType: map['data_type'] as String,
        label: map['label'] as String,
        metricType: map['metric_type'] as String?,
        value: (map['value'] as num?)?.toDouble(),
        unit: map['unit'] as String?,
        startTime: DateTime.parse(map['start_time'] as String),
        endTime: DateTime.parse(map['end_time'] as String),
        sourceName: map['source_name'] as String?,
        sourceDeviceId: map['source_device_id'] as String?,
        recordingMethod: map['recording_method'] as String?,
        extra: map['extra'] as String?,
        createdAt: DateTime.parse(map['created_at'] as String),
      );
}

/// 聚合摘要（供智能体工具 `get_wearable_summary` 与数据源诊断页复用）
class WearableSnapshot {
  /// 统计窗口（天）
  final int days;

  /// 窗口内样本条数
  final int sampleCount;

  /// 日均步数
  final double? avgSteps;

  /// 静息心率区间与均值（次/分）
  final double? restingHrMin;
  final double? restingHrMax;
  final double? restingHrAvg;

  /// 日均睡眠时长（小时）
  final double? sleepAvgHours;

  /// 睡眠分期时长（分钟）：键为中文分期名
  final Map<String, double> sleepStagesMinutes;

  /// 体重/体脂率窗口内的首末值
  final double? weightFirst;
  final double? weightLast;
  final double? bodyFatFirst;
  final double? bodyFatLast;

  /// 锻炼记录次数
  final int workoutCount;

  /// 逐类型（中文名）最近一条数据时间；null 表示该类型暂无数据
  final Map<String, DateTime?> lastDataAt;

  const WearableSnapshot({
    required this.days,
    required this.sampleCount,
    required this.lastDataAt,
    this.avgSteps,
    this.restingHrMin,
    this.restingHrMax,
    this.restingHrAvg,
    this.sleepAvgHours,
    this.sleepStagesMinutes = const {},
    this.weightFirst,
    this.weightLast,
    this.bodyFatFirst,
    this.bodyFatLast,
    this.workoutCount = 0,
  });

  bool get isEmpty => sampleCount == 0;

  /// 文本化摘要（脱敏、仅统计量；可直接回填智能体上下文）
  String describe() {
    if (isEmpty) {
      return '近 $days 天未读到穿戴数据（可能尚未授权、尚未同步，或设备未把数据写入健康平台）。';
    }
    final buf = StringBuffer('近 $days 天穿戴数据摘要（共 $sampleCount 条记录）：');
    if (avgSteps != null) {
      buf.write('\n· 日均步数：${avgSteps!.round()} 步');
    }
    if (restingHrAvg != null) {
      buf.write(
          '\n· 静息心率：${restingHrMin!.round()}–${restingHrMax!.round()} 次/分（均值 ${restingHrAvg!.round()}）');
    }
    if (sleepAvgHours != null) {
      buf.write('\n· 睡眠：日均 ${sleepAvgHours!.toStringAsFixed(1)} 小时');
      final stages = sleepStagesMinutes.entries
          .where((e) => e.value > 0)
          .map((e) => '${e.key} ${(e.value / 60).toStringAsFixed(1)}h')
          .join(' / ');
      if (stages.isNotEmpty) buf.write('（$stages）');
    }
    if (weightFirst != null && weightLast != null) {
      buf.write(
          '\n· 体重：${weightFirst!.toStringAsFixed(1)} → ${weightLast!.toStringAsFixed(1)} kg');
    }
    if (bodyFatFirst != null && bodyFatLast != null) {
      buf.write(
          '\n· 体脂率：${bodyFatFirst!.toStringAsFixed(1)} → ${bodyFatLast!.toStringAsFixed(1)} %');
    }
    if (workoutCount > 0) {
      buf.write('\n· 锻炼记录：$workoutCount 次');
    }
    return buf.toString();
  }
}

/// 数据源诊断结果（设置页「我的数据源诊断」子页展示用）
class WearableSourceDiagnosis {
  /// 平台是否支持（Android：Health Connect 可用；iOS：健康 App 可用）
  final bool available;

  /// 是否已获得授权
  final bool authorized;

  /// 已授权类型的中文名
  final List<String> grantedLabels;

  /// 逐类型（中文名）最近一条本地数据时间；null 表示该类型暂无数据
  final Map<String, DateTime?> lastDataAt;

  /// 最近一次同步时间
  final DateTime? lastSync;

  /// 不可用/失败原因（可读文案）
  final String? error;

  const WearableSourceDiagnosis({
    required this.available,
    required this.authorized,
    required this.grantedLabels,
    required this.lastDataAt,
    this.lastSync,
    this.error,
  });
}
