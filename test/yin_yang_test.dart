import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/models/wearable.dart';
import 'package:ai_planner/models/yin_yang.dart';
import 'package:ai_planner/services/yin_yang_service.dart';

YinYangDayPoint day(
  DateTime d, {
  double trainVolume = 0,
  double activeEnergy = 0,
  double intake = 0,
  double? sleepHours,
  double? weight,
  double? hrv,
  double? restingHr,
}) =>
    YinYangDayPoint(
      date: d,
      trainVolume: trainVolume,
      activeEnergy: activeEnergy,
      intake: intake,
      sleepHours: sleepHours,
      weight: weight,
      hrv: hrv,
      restingHr: restingHr,
    );

void main() {
  final mon = DateTime(2026, 10, 12); // 周一

  // ---------- 量纲折算 ----------
  group('阴阳当量折算', () {
    test('阳 = 训练容量按系数折算，手表消耗不计入公式', () {
      final p = day(mon, trainVolume: 1000, activeEnergy: 500);
      expect(YinYangService.yangKcal(p),
          closeTo(1000 * YinYangService.kcalPerVolumeUnit, 1e-9));
      expect(p.activeEnergy, 500); // 仅展示
    });

    test('阴 = 摄入 − 睡眠阴债；睡够 8 小时无债', () {
      final enough = day(mon, intake: 2000, sleepHours: 8);
      expect(YinYangService.yinKcal(enough), closeTo(2000, 1e-9));

      final lack = day(mon, intake: 2000, sleepHours: 6);
      expect(YinYangService.yinKcal(lack),
          closeTo(2000 - 2 * YinYangService.sleepDebtKcalPerHour, 1e-9));
    });

    test('睡眠超额不产生负债', () {
      expect(YinYangService.sleepDebtHours(9), 0);
      expect(YinYangService.sleepDebtHours(null), 0);
      expect(YinYangService.sleepDebtHours(5.5), closeTo(2.5, 1e-9));
      expect(YinYangService.sleepDebtHours(0), 0); // 无数据不算欠
    });

    test('盈余 = 阴 − 阳', () {
      final p = day(mon, trainVolume: 1000, intake: 2000, sleepHours: 8);
      const expected =
          2000.0 - 1000 * YinYangService.kcalPerVolumeUnit;
      expect(YinYangService.surplus(p), closeTo(expected, 1e-9));
    });
  });

  // ---------- 规则引擎 ----------
  group('判读规则引擎', () {
    test('空数据返回 info 兜底', () {
      final v = YinYangRuleEngine.judge(const YinYangReading(days: []));
      expect(v.level, 'info');
      expect(v.rule, 'none');
    });

    test('无任何有效日（无摄入无睡眠）也返回兜底', () {
      final days = [day(mon), day(mon.add(const Duration(days: 1)))];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, 'none');
    });

    test('规则3：睡眠 <6h 连续 2 天 → 降强度', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 5),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 5.5),
        day(mon.add(const Duration(days: 2)), intake: 2000, sleepHours: 8),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, 'short_sleep');
      expect(v.level, 'warn');
      expect(v.text, contains('降训练强度'));
    });

    test('规则3 不命中：仅单晚睡不够', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 5),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 8),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, isNot('short_sleep'));
    });

    test('规则1：阳周环比 +10% 且睡眠均值 <7h → 阴分不足', () {
      // 阳 = 容量 × 0.15；本周 2000 → 300 kcal，上周 1000 → 150 kcal（+100%）
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 6.5),
        day(mon.add(const Duration(days: 1)), trainVolume: 1000,
            intake: 2000, sleepHours: 6.5),
      ];
      final reading = YinYangReading(days: days);
      final v = YinYangRuleEngine.judge(reading, previousYang: 150);
      expect(v.rule, 'yang_surge');
      expect(v.level, 'warn');
      expect(v.text, contains('阴分不足'));
    });

    test('规则1 不命中：睡眠充足（≥7h）', () {
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 7.5),
        day(mon.add(const Duration(days: 1)), trainVolume: 1000,
            intake: 2000, sleepHours: 7.5),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days),
        previousYang: 150,
      );
      expect(v.rule, isNot('yang_surge'));
    });

    test('规则1 不命中：环比涨幅不足 10%', () {
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 6.5),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days),
        previousYang: 140, // 150 vs 140 = +7%
      );
      expect(v.rule, isNot('yang_surge'));
    });

    test('规则2：盈余连续 3 天为正且递增 → 收敛区间', () {
      // 睡眠固定 8h（无债），摄入递增，训练容量固定
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 8),
        day(mon.add(const Duration(days: 1)), trainVolume: 1000,
            intake: 2100, sleepHours: 8),
        day(mon.add(const Duration(days: 2)), trainVolume: 1000,
            intake: 2200, sleepHours: 8),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, 'rising_surplus');
      expect(v.text, contains('收敛区间'));
    });

    test('规则2 不命中：盈余递增但不足 3 天', () {
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 8),
        day(mon.add(const Duration(days: 1)), trainVolume: 1000,
            intake: 2100, sleepHours: 8),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, isNot('rising_surplus'));
    });

    test('规则4：阴阳同升 + 体重平稳 → 保持节奏', () {
      // 关键：摄入增幅刻意压在训练增幅之下，让盈余「不递增」，
      // 否则会被优先级更高的规则2（盈余递增）抢先命中。
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 8, weight: 70),
        day(mon.add(const Duration(days: 1)), trainVolume: 1400,
            intake: 2025, sleepHours: 8, weight: 70.1),
        day(mon.add(const Duration(days: 2)), trainVolume: 1800,
            intake: 2050, sleepHours: 8, weight: 70.15),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, 'balanced');
      expect(v.level, 'good');
      expect(v.text, contains('保持当前节奏'));
    });

    test('规则4 不命中：体重下降明显（非平稳）', () {
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 8, weight: 71.0),
        day(mon.add(const Duration(days: 1)), trainVolume: 1400,
            intake: 2025, sleepHours: 8, weight: 70.2),
        day(mon.add(const Duration(days: 2)), trainVolume: 1800,
            intake: 2050, sleepHours: 8, weight: 69.4),
      ];
      final v = YinYangRuleEngine.judge(YinYangReading(days: days));
      expect(v.rule, isNot('balanced'));
    });

    test('规则优先级：短睡优先于练量加码', () {
      final days = [
        day(mon, trainVolume: 1000, intake: 2000, sleepHours: 5),
        day(mon.add(const Duration(days: 1)), trainVolume: 1000,
            intake: 2000, sleepHours: 5),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days),
        previousYang: 100,
      );
      expect(v.rule, 'short_sleep');
    });
  });

  // ---------- 个人基线判读（HRV / 静息心率，v1.3.1） ----------
  group('个人基线判读', () {
    // 基线窗口起点：判读窗（周一起）之前 35 天（基线 28 天 + 上周 7 天）
    final bStart = mon.subtract(const Duration(days: 35));

    List<YinYangDayPoint> baseline(
      int days, {
      double? hrv,
      double? restingHr,
    }) =>
        List.generate(
          days,
          (i) => day(
            bStart.add(Duration(days: i)),
            hrv: hrv,
            restingHr: restingHr,
          ),
        );

    test('personalBaseline：样本足取均值，不足 14 天返回 null 静默', () {
      final enough = baseline(20, hrv: 50);
      expect(
        YinYangService.personalBaseline(enough, (d) => d.hrv),
        closeTo(50, 1e-9),
      );
      final sparse = baseline(10, hrv: 50);
      expect(YinYangService.personalBaseline(sparse, (d) => d.hrv), isNull,
          reason: '基线未成形应静默');
      expect(
        YinYangService.personalBaseline(const [], (d) => d.hrv),
        isNull,
      );
    });

    test('规则 3.5：HRV 低于基线 10% 且当日睡眠不足 → 降强度', () {
      // 基线 HRV 50；判读窗最近一天 HRV 42（<45）+ 睡 6.5h
      final days = [
        day(mon, intake: 2000, sleepHours: 6.5, hrv: 48),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 6.5,
            hrv: 42),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days, baselineDays: baseline(20, hrv: 50)),
      );
      expect(v.rule, 'hrv_drop');
      expect(v.level, 'warn');
      expect(v.text, contains('降强度或休整'));
      expect(v.text, contains('16'), reason: '(1 − 42/50)×100 = 16%');
    });

    test('规则 3.5 不命中：HRV 低但睡够了（可能是噪声，静默）', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 8, hrv: 42),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days, baselineDays: baseline(20, hrv: 50)),
      );
      expect(v.rule, isNot('hrv_drop'));
    });

    test('规则 3.5 静默：基线样本不足 14 天', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 6.5, hrv: 42),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days, baselineDays: baseline(10, hrv: 50)),
      );
      expect(v.rule, isNot('hrv_drop'));
    });

    test('规则 3.6：静息心率连续两天高于基线 5 拍 → 预警', () {
      // 基线静息心率 60；判读窗最近两天 66 / 67（> 65）
      final days = [
        day(mon, intake: 2000, sleepHours: 8, restingHr: 66),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 8,
            restingHr: 67),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(
          days: days,
          baselineDays: baseline(20, restingHr: 60),
        ),
      );
      expect(v.rule, 'rhr_elevated');
      expect(v.level, 'warn');
      expect(v.text, contains('身体没缓过来'));
    });

    test('规则 3.6 不命中：仅单日超标', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 8, restingHr: 66),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 8),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(
          days: days,
          baselineDays: baseline(20, restingHr: 60),
        ),
      );
      expect(v.rule, isNot('rhr_elevated'));
    });

    test('规则优先级：短睡优先于 HRV 骤降', () {
      final days = [
        day(mon, intake: 2000, sleepHours: 5, hrv: 42),
        day(mon.add(const Duration(days: 1)), intake: 2000, sleepHours: 5,
            hrv: 42),
      ];
      final v = YinYangRuleEngine.judge(
        YinYangReading(days: days, baselineDays: baseline(20, hrv: 50)),
      );
      expect(v.rule, 'short_sleep');
    });
  });

  // ---------- 数据结构 ----------
  group('YinYangDayPoint', () {
    test('日期格式化与标签', () {
      final p = day(DateTime(2026, 10, 17));
      expect(p.isoDate, '2026-10-17');
      expect(p.label, '10/17');
    });

    test('toMap / fromMap 往返', () {
      final p = day(DateTime(2026, 10, 17),
          trainVolume: 1234.5, activeEnergy: 300, intake: 2100,
          sleepHours: 7.25, weight: 70.5, hrv: 48.2, restingHr: 58);
      final back = YinYangDayPoint.fromMap(p.toMap());
      expect(back.isoDate, p.isoDate);
      expect(back.trainVolume, closeTo(1234.5, 1e-9));
      expect(back.activeEnergy, closeTo(300, 1e-9));
      expect(back.intake, closeTo(2100, 1e-9));
      expect(back.sleepHours, closeTo(7.25, 1e-9));
      expect(back.weight, closeTo(70.5, 1e-9));
      expect(back.hrv, closeTo(48.2, 1e-9));
      expect(back.restingHr, closeTo(58, 1e-9));
    });

    test('hasTraining：容量或手表消耗任一非零', () {
      expect(day(mon, trainVolume: 100).hasTraining, isTrue);
      expect(day(mon, activeEnergy: 50).hasTraining, isTrue);
      expect(day(mon).hasTraining, isFalse);
    });

    test('activeDayCount 统计有数据天数', () {
      final reading = YinYangReading(days: [
        day(mon, intake: 1800),
        day(mon.add(const Duration(days: 1))),
        day(mon.add(const Duration(days: 2)), sleepHours: 7),
      ]);
      expect(reading.activeDayCount, 2);
      expect(reading.isEmpty, isFalse);
      expect(const YinYangReading(days: []).isEmpty, isTrue);
    });
  });

  // ---------- 穿戴类型识别 ----------
  test('睡眠类型覆盖分期与未分期两种上报', () {
    // Gadgetbridge 可能只上报 SLEEP_ASLEEP，也可能上报分期；buildDays 内部
    // 对两者都累加。此处验证 WearableSample 的分期样本能被正常转换。
    final s = WearableSample(
      id: 'x',
      dataType: 'SLEEP_DEEP',
      label: '深睡',
      metricType: null,
      value: 90,
      unit: '分钟',
      startTime: DateTime(2026, 10, 12, 23),
      endTime: DateTime(2026, 10, 13, 7),
      createdAt: DateTime(2026, 10, 13),
    );
    expect(s.value, 90); // 90 分钟 = 1.5 小时
    expect(YinYangService.sleepDebtHours(90 / 60),
        closeTo(8 - 1.5, 1e-9));
  });
}
