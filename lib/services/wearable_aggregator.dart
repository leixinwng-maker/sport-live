/// P4-C 穿戴数据映射与聚合（纯 Dart，无平台依赖，便于单测注入模拟数据）
library;

import '../models/wearable.dart';

/// 读取类型规格：一级映射表（设计 §6.1）
///
/// [dataType] 为 `health` 插件 `HealthDataType` 的枚举名；
/// [metricType] 为项目健康指标落点（`HealthMetric.metricTypes` 中的一项），
/// 无落点的类型（步数/睡眠/锻炼等）仅进摘要与生活状态。
class WearableTypeSpec {
  /// `HealthDataType` 枚举名
  final String dataType;

  /// 中文展示名
  final String label;

  /// 项目健康指标落点；null 表示仅用于摘要
  final String? metricType;

  /// 项目侧展示单位（网关已做单位归一化）
  final String unit;

  const WearableTypeSpec({
    required this.dataType,
    required this.label,
    required this.unit,
    this.metricType,
  });
}

/// 本项目读取的数据类型（与 AndroidManifest 的授权声明一一对应，最小化原则）
///
/// 注：`metricType` 中「肌肉量」「血氧」为 T7 计划扩展的项目健康指标类型；
/// 未落指标的记录仍保留在本地快照中，供摘要与数据源诊断使用。
const List<WearableTypeSpec> kReadTypeSpecs = [
  WearableTypeSpec(dataType: 'STEPS', label: '步数', unit: '步'),
  WearableTypeSpec(
      dataType: 'DISTANCE_WALKING_RUNNING', label: '行走跑步距离', unit: '公里'),
  WearableTypeSpec(
      dataType: 'ACTIVE_ENERGY_BURNED', label: '活动热量', unit: '千卡'),
  WearableTypeSpec(
      dataType: 'HEART_RATE',
      label: '心率',
      unit: '次/分',
      metricType: null),
  WearableTypeSpec(
      dataType: 'RESTING_HEART_RATE',
      label: '静息心率',
      unit: '次/分',
      metricType: '静息心率'),
  WearableTypeSpec(
      dataType: 'HEART_RATE_VARIABILITY_SDNN', label: '心率变异性', unit: '毫秒'),
  WearableTypeSpec(dataType: 'SLEEP_DEEP', label: '深睡', unit: '分钟'),
  WearableTypeSpec(dataType: 'SLEEP_LIGHT', label: '浅睡', unit: '分钟'),
  WearableTypeSpec(dataType: 'SLEEP_REM', label: '快速眼动睡眠', unit: '分钟'),
  WearableTypeSpec(dataType: 'SLEEP_ASLEEP', label: '睡眠', unit: '分钟'),
  WearableTypeSpec(
      dataType: 'WEIGHT', label: '体重', unit: 'kg', metricType: '体重'),
  WearableTypeSpec(
      dataType: 'BODY_FAT_PERCENTAGE',
      label: '体脂率',
      unit: '%',
      metricType: '体脂率'),
  WearableTypeSpec(
      dataType: 'LEAN_BODY_MASS',
      label: '肌肉量',
      unit: 'kg',
      metricType: '肌肉量'),
  WearableTypeSpec(
      dataType: 'BLOOD_OXYGEN',
      label: '血氧饱和度',
      unit: '%',
      metricType: '血氧'),
  WearableTypeSpec(
      dataType: 'BLOOD_PRESSURE_SYSTOLIC',
      label: '收缩压',
      unit: 'mmHg',
      metricType: '收缩压'),
  WearableTypeSpec(
      dataType: 'BLOOD_PRESSURE_DIASTOLIC',
      label: '舒张压',
      unit: 'mmHg',
      metricType: '舒张压'),
  // 血糖：穿戴侧无法得知空腹/餐后上下文，故不落健康指标，仅进摘要
  WearableTypeSpec(
      dataType: 'BLOOD_GLUCOSE', label: '血糖', unit: 'mmol/L', metricType: null),
  WearableTypeSpec(dataType: 'WORKOUT', label: '锻炼记录', unit: '次'),
];

/// 全部读取类型名（授权与同步请求用）
List<String> get kReadTypeNames =>
    kReadTypeSpecs.map((s) => s.dataType).toList(growable: false);

/// 取类型规格；未知类型返回 null（未知类型不落库）
WearableTypeSpec? specOf(String dataType) {
  for (final s in kReadTypeSpecs) {
    if (s.dataType == dataType) return s;
  }
  return null;
}

/// 单点转换：原始点 → 落库快照
///
/// 未知类型（不在 [kReadTypeSpecs] 中）返回 null，直接忽略。
WearableSample? toSample(WearableRawPoint raw, {DateTime? now}) {
  final spec = specOf(raw.dataType);
  if (spec == null) return null;
  final extra = raw.extra;
  return WearableSample(
    id: WearableSample.dedupId(raw.dataType, raw.start),
    dataType: raw.dataType,
    label: spec.label,
    metricType: spec.metricType,
    value: raw.value,
    unit: spec.unit,
    startTime: raw.start,
    endTime: raw.end,
    sourceName: raw.sourceName,
    sourceDeviceId: raw.sourceDeviceId,
    recordingMethod: raw.recordingMethod,
    extra: extra == null || extra.isEmpty ? null : _encodeExtra(extra),
    createdAt: now ?? DateTime.now(),
  );
}

/// 批量转换
List<WearableSample> toSamples(List<WearableRawPoint> raws, {DateTime? now}) {
  final out = <WearableSample>[];
  for (final raw in raws) {
    final s = toSample(raw, now: now);
    if (s != null) out.add(s);
  }
  return out;
}

String _encodeExtra(Map<String, dynamic> extra) {
  final parts = extra.entries
      .map((e) => '"${e.key}":${e.value is String ? '"${e.value}"' : '${e.value}'}')
      .join(',');
  return '{$parts}';
}

/// 逐类型最近一条数据时间（全局，用于「我的数据源诊断」）
Map<String, DateTime?> lastDataAtOf(List<WearableSample> samples) {
  final out = <String, DateTime?>{for (final s in kReadTypeSpecs) s.label: null};
  for (final s in samples) {
    final prev = out[s.label];
    if (prev == null || s.startTime.isAfter(prev)) out[s.label] = s.startTime;
  }
  return out;
}

/// 聚合为窗口摘要（供智能体工具与诊断页）
///
/// [days] 为统计窗口天数（含今天）；窗口起点为「今天 00:00 - (days-1) 天」。
WearableSnapshot aggregate(
  List<WearableSample> samples, {
  required int days,
  DateTime? now,
}) {
  final ref = now ?? DateTime.now();
  final today = DateTime(ref.year, ref.month, ref.day);
  final start = today.subtract(Duration(days: days <= 1 ? 0 : days - 1));

  final win = samples
      .where((s) =>
          !s.startTime.isBefore(start) && !s.startTime.isAfter(ref))
      .toList()
    ..sort((a, b) => a.startTime.compareTo(b.startTime));

  double sumOf(String dataType) => win
      .where((s) => s.dataType == dataType)
      .fold<double>(0, (acc, s) => acc + (s.value ?? 0));

  List<double> valuesOf(String dataType) => win
      .where((s) => s.dataType == dataType && s.value != null)
      .map((s) => s.value!).toList();

  // 步数：窗口内总步数 ÷ 天数
  final stepSamples = win.where((s) => s.dataType == 'STEPS').toList();
  final avgSteps = stepSamples.isEmpty ? null : sumOf('STEPS') / days;

  // 静息心率：区间与均值
  final rhr = valuesOf('RESTING_HEART_RATE');
  final rhrMin = rhr.isEmpty ? null : rhr.reduce((a, b) => a < b ? a : b);
  final rhrMax = rhr.isEmpty ? null : rhr.reduce((a, b) => a > b ? a : b);
  final rhrAvg =
      rhr.isEmpty ? null : rhr.fold<double>(0, (a, b) => a + b) / rhr.length;

  // 睡眠：分期时长（分钟）。设备可能只上报未分期的 SLEEP_ASLEEP，
  // 此时以 SLEEP_ASLEEP 作为总睡眠，避免与分期重复累加。
  final deep = sumOf('SLEEP_DEEP');
  final light = sumOf('SLEEP_LIGHT');
  final rem = sumOf('SLEEP_REM');
  final asleep = sumOf('SLEEP_ASLEEP');
  final stagedMinutes = deep + light + rem;
  final totalSleepMinutes = stagedMinutes > 0 ? stagedMinutes : asleep;
  final sleepAvgHours =
      totalSleepMinutes > 0 ? totalSleepMinutes / days / 60 : null;

  // 体重 / 体脂：窗口内首末值反映趋势
  final weights = valuesOf('WEIGHT');
  final bodyFats = valuesOf('BODY_FAT_PERCENTAGE');

  return WearableSnapshot(
    days: days,
    sampleCount: win.length,
    avgSteps: avgSteps,
    restingHrMin: rhrMin,
    restingHrMax: rhrMax,
    restingHrAvg: rhrAvg,
    sleepAvgHours: sleepAvgHours,
    sleepStagesMinutes: {
      '深睡': deep,
      '浅睡': light,
      '快速眼动': rem,
    },
    weightFirst: weights.isEmpty ? null : weights.first,
    weightLast: weights.isEmpty ? null : weights.last,
    bodyFatFirst: bodyFats.isEmpty ? null : bodyFats.first,
    bodyFatLast: bodyFats.isEmpty ? null : bodyFats.last,
    workoutCount: win.where((s) => s.dataType == 'WORKOUT').length,
    lastDataAt: lastDataAtOf(win),
  );
}
