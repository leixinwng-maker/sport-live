import 'package:ai_planner/models/health_metric.dart';
import 'package:ai_planner/services/body_composition_parser.dart';
import 'package:ai_planner/services/body_stats_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// FIT-5 单测：身体数据统计纯计算层
///
/// 覆盖：
/// 1. 指标分组登记表 [BodyMetricGroup]（无重复、并集等于 `metricTypes`）；
/// 2. 日期归一化 [bodyDayOf] 与范围起始 [bodyRangeStart]；
/// 3. 时序构造 [bodySeries]（按类型过滤、无效值跳过、同日取均值、日期升序）；
/// 4. 区间裁剪 [bodyPointsInRange]（端点闭合、未来剔除、`全部` 不设下界）；
/// 5. 稀疏分桶 [bucketBodyPoints]（按距首日天数分组取均值）；
/// 6. 区间摘要 [summarizeBody]（极值/均值/首尾/变化量与变化率、除零保护）；
/// 7. 移动平均 [movingAverage]（仅输出完整窗口）；
/// 8. 展示格式化 [fmtBodyValue] / [fmtBodyDelta] / [fmtBodyPct] / [fmtBodyDate]；
/// 9. 围度类型扩展后解析器仍可识别。
void main() {
  // ---------- 造数工具 ----------

  HealthMetric hm(
    String type,
    double value, {
    DateTime? date,
    String note = '',
  }) =>
      HealthMetric(
        date: date ?? DateTime(2026, 3, 1),
        type: type,
        value: value,
        note: note,
      );

  group('指标分组登记表', () {
    test('每个指标只归属一个分组，且分组并集等于 metricTypes', () {
      final seen = <String>{};
      for (final group in BodyMetricGroup.values) {
        expect(group.types, isNotEmpty, reason: '${group.label} 分组不应为空');
        for (final type in group.types) {
          expect(seen.add(type), isTrue, reason: '$type 在分组中重复登记');
          expect(HealthMetric.metricTypes, contains(type),
              reason: '$type 未在 metricTypes 中登记');
        }
      }
      expect(seen, HealthMetric.metricTypes.toSet(),
          reason: '分组必须覆盖全部指标，避免新增指标时漏登记');
    });

    test('bodyGroupOf 能正确归类，未知类型兜底到体成分', () {
      expect(bodyGroupOf('体重'), BodyMetricGroup.composition);
      expect(bodyGroupOf('腰围'), BodyMetricGroup.girth);
      expect(bodyGroupOf('静息心率'), BodyMetricGroup.vital);
      expect(bodyGroupOf('尿酸'), BodyMetricGroup.lab);
      expect(bodyGroupOf('未知指标'), BodyMetricGroup.composition);
    });
  });

  group('日期与范围', () {
    test('bodyDayOf 丢弃时分秒', () {
      expect(
        bodyDayOf(DateTime(2026, 3, 8, 23, 59, 59)),
        DateTime(2026, 3, 8),
      );
    });

    test('bodyRangeStart：近 7 天含今天共 7 天，全部不设下界', () {
      final today = DateTime(2026, 3, 10, 15);
      expect(bodyRangeStart(BodyRange.week, today), DateTime(2026, 3, 4));
      expect(bodyRangeStart(BodyRange.month, today), DateTime(2026, 2, 9));
      expect(bodyRangeStart(BodyRange.all, today), isNull);
    });
  });

  group('时序构造 bodySeries', () {
    test('只取目标类型，且按日期升序', () {
      final list = [
        hm('体重', 62, date: DateTime(2026, 3, 3)),
        hm('体脂率', 18, date: DateTime(2026, 3, 2)),
        hm('体重', 61, date: DateTime(2026, 3, 1)),
      ];
      final series = bodySeries(list, '体重');
      expect(series.length, 2);
      expect(series.first.date, DateTime(2026, 3, 1));
      expect(series.first.value, 61);
      expect(series.last.value, 62);
    });

    test('同日多条取算术均值，避免单点抖动', () {
      final list = [
        hm('体重', 60, date: DateTime(2026, 3, 1, 7)),
        hm('体重', 62, date: DateTime(2026, 3, 1, 21)),
        hm('体重', 61, date: DateTime(2026, 3, 2)),
      ];
      final series = bodySeries(list, '体重');
      expect(series.length, 2);
      expect(series.first.value, 61);
      expect(series.last.value, 61);
    });

    test('0 / 负数 / NaN / Infinity 视为无效并跳过', () {
      final list = [
        hm('腰围', 0),
        hm('腰围', -1),
        hm('腰围', double.nan),
        hm('腰围', double.infinity),
        hm('腰围', 78),
      ];
      final series = bodySeries(list, '腰围');
      expect(series.length, 1);
      expect(series.first.value, 78);
    });

    test('无匹配记录返回空列表', () {
      expect(bodySeries([hm('体重', 60)], '体脂率'), isEmpty);
      expect(bodySeries(const [], '体重'), isEmpty);
    });
  });

  group('区间裁剪 bodyPointsInRange', () {
    final points = [
      BodyPoint(DateTime(2026, 2, 1), 70),
      BodyPoint(DateTime(2026, 3, 4), 69),
      BodyPoint(DateTime(2026, 3, 10), 68),
      BodyPoint(DateTime(2026, 3, 20), 67), // 未来
    ];

    test('下界含起始日当天、上界含今天，未来记录被剔除', () {
      final out = bodyPointsInRange(
        points,
        BodyRange.week,
        today: DateTime(2026, 3, 10, 9),
      );
      expect(out.map((p) => p.value).toList(), [69, 68]);
    });

    test('全部不设下界但仍剔除未来记录', () {
      final out = bodyPointsInRange(
        points,
        BodyRange.all,
        today: DateTime(2026, 3, 10),
      );
      expect(out.map((p) => p.value).toList(), [70, 69, 68]);
    });

    test('区间内无记录返回空', () {
      final out = bodyPointsInRange(
        points,
        BodyRange.week,
        today: DateTime(2026, 6, 1),
      );
      expect(out, isEmpty);
    });
  });

  group('稀疏分桶 bucketBodyPoints', () {
    test('bucketDays <= 1 原样返回同一实例', () {
      final points = [
        BodyPoint(DateTime(2026, 3, 1), 70),
        BodyPoint(DateTime(2026, 3, 2), 69),
      ];
      expect(identical(bucketBodyPoints(points, 1), points), isTrue);
    });

    test('单点不参与分桶，原样返回', () {
      final points = [BodyPoint(DateTime(2026, 3, 1), 70)];
      expect(identical(bucketBodyPoints(points, 7), points), isTrue);
    });

    test('按距首个记录日的天数分桶并取均值，日期取桶内首日', () {
      final points = [
        BodyPoint(DateTime(2026, 3, 1), 1),
        BodyPoint(DateTime(2026, 3, 2), 2),
        BodyPoint(DateTime(2026, 3, 3), 3),
        BodyPoint(DateTime(2026, 3, 4), 4),
        BodyPoint(DateTime(2026, 3, 5), 5),
      ];
      final out = bucketBodyPoints(points, 2);
      expect(out.length, 3);
      expect(out[0].value, 1.5);
      expect(out[0].date, DateTime(2026, 3, 1));
      expect(out[1].value, 3.5);
      expect(out[1].date, DateTime(2026, 3, 3));
      expect(out[2].value, 5);
      expect(out[2].date, DateTime(2026, 3, 5));
    });
  });

  group('区间摘要 summarizeBody', () {
    test('空集合返回空摘要且不除零', () {
      final s = summarizeBody(const []);
      expect(s.isEmpty, isTrue);
      expect(s.count, 0);
      expect(s.change, isNull);
      expect(s.changePct, isNull);
      expect(s.average, isNull);
    });

    test('极值 / 均值 / 首尾 / 变化量 / 变化率', () {
      final s = summarizeBody([
        BodyPoint(DateTime(2026, 3, 1), 60),
        BodyPoint(DateTime(2026, 3, 4), 63),
        BodyPoint(DateTime(2026, 3, 9), 58),
      ]);
      expect(s.count, 3);
      expect(s.first, 60);
      expect(s.last, 58);
      expect(s.min, 58);
      expect(s.max, 63);
      expect(s.average, closeTo((60 + 63 + 58) / 3, 1e-9));
      expect(s.firstDate, DateTime(2026, 3, 1));
      expect(s.lastDate, DateTime(2026, 3, 9));
      expect(s.change, -2);
      expect(s.changePct, closeTo(-2 / 60 * 100, 1e-9));
    });

    test('单点记录变化量为 0、变化率为 0', () {
      final s = summarizeBody([BodyPoint(DateTime(2026, 3, 1), 70)]);
      expect(s.change, 0);
      expect(s.changePct, 0);
    });

    test('起始值为 0 时变化率返回 null（除零保护）', () {
      final s = summarizeBody([
        BodyPoint(DateTime(2026, 3, 1), 0),
        BodyPoint(DateTime(2026, 3, 2), 10),
      ]);
      expect(s.change, 10);
      expect(s.changePct, isNull);
    });
  });

  group('移动平均 movingAverage', () {
    test('window <= 1 或点数不足窗口时返回空', () {
      final points = [
        BodyPoint(DateTime(2026, 3, 1), 1),
        BodyPoint(DateTime(2026, 3, 2), 2),
      ];
      expect(movingAverage(points, 1), isEmpty);
      expect(movingAverage(points, 0), isEmpty);
      expect(movingAverage(points, 3), isEmpty);
    });

    test('只输出完整窗口，日期跟随窗口末点', () {
      final points = [
        BodyPoint(DateTime(2026, 3, 1), 1),
        BodyPoint(DateTime(2026, 3, 2), 2),
        BodyPoint(DateTime(2026, 3, 3), 3),
        BodyPoint(DateTime(2026, 3, 4), 4),
      ];
      final out = movingAverage(points, 3);
      expect(out.length, 2);
      expect(out[0].value, closeTo(2, 1e-9));
      expect(out[0].date, DateTime(2026, 3, 3));
      expect(out[1].value, closeTo(3, 1e-9));
      expect(out[1].date, DateTime(2026, 3, 4));
    });
  });

  group('展示格式化', () {
    test('fmtBodyValue：整数不带小数点，否则保留一位', () {
      expect(fmtBodyValue(70), '70');
      expect(fmtBodyValue(70.5), '70.5');
      expect(fmtBodyValue(70.25), '70.3');
    });

    test('fmtBodyDelta 带符号', () {
      expect(fmtBodyDelta(0), '0');
      expect(fmtBodyDelta(1.5), '+1.5');
      expect(fmtBodyDelta(-0.8), '-0.8');
    });

    test('fmtBodyPct 带符号且保留一位', () {
      expect(fmtBodyPct(2.44), '+2.4%');
      expect(fmtBodyPct(-1), '-1.0%');
      expect(fmtBodyPct(0), '+0.0%');
    });

    test('fmtBodyDate 输出 M/D', () {
      expect(fmtBodyDate(DateTime(2026, 3, 8)), '3/8');
    });
  });

  group('围度类型扩展', () {
    test('6 项围度已登记且默认单位为 cm', () {
      const girth = ['腰围', '臀围', '胸围', '臂围', '大腿围', '小腿围'];
      for (final type in girth) {
        expect(HealthMetric.metricTypes, contains(type));
        expect(HealthMetric.bodyCompositionTypes, contains(type));
        expect(HealthMetric.typeUnits[type], 'cm');
      }
    });

    test('解析器可识别新增围度指标（视觉 JSON 与纯文本）', () {
      expect(BodyCompositionParser.matchType('臀围'), '臀围');
      expect(BodyCompositionParser.matchType('大腿围'), '大腿围');
      expect(BodyCompositionParser.matchType('上臂围'), '臂围');
      final filled =
          BodyCompositionParser.fromPlainText('腰围78cm，臀围96cm，胸围92cm');
      expect(filled['腰围'], 78);
      expect(filled['臀围'], 96);
      expect(filled['胸围'], 92);
    });
  });
}
