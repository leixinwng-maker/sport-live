import 'package:ai_planner/models/health_metric.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/body_composition_parser.dart';
import 'package:ai_planner/services/database_helper.dart';
import 'package:flutter_test/flutter_test.dart';

/// P4-T7 单测：体成分类型扩展 + 体测批量录入的数据落库 + 拍照回填解析
///
/// 覆盖计划验收项：
/// 1. 一次录入 7 项体成分成功；
/// 2. 清晰照片（视觉模型返回 JSON）能回填；
/// 3. 未配置视觉模型时走本地 OCR（纯文本解析）且不崩溃。
///
/// 全离线：解析器为纯函数；落库走桌面端 ffi 本地库，无网络、无平台通道。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;

  group('T7-1 视觉模型 JSON 解析（首选回填路径）', () {
    test('标准 JSON：体成分 9 项全部归一', () {
      const raw = '{"体重":62.5,"体脂率":18.3,"肌肉量":49.2,"体水分率":55.1,'
          '"骨量":2.6,"蛋白质率":17.2,"基础代谢":1420,"内脏脂肪等级":8,"腰围":78}';
      final parsed = BodyCompositionParser.fromVisionJson(raw);
      expect(parsed.length, 9);
      expect(parsed['体重'], 62.5);
      expect(parsed['体脂率'], 18.3);
      expect(parsed['肌肉量'], 49.2);
      expect(parsed['体水分率'], 55.1);
      expect(parsed['骨量'], 2.6);
      expect(parsed['蛋白质率'], 17.2);
      expect(parsed['基础代谢'], 1420);
      expect(parsed['内脏脂肪等级'], 8);
      expect(parsed['腰围'], 78);
    });

    test('容忍 ```json 包裹与前后解释文字', () {
      const raw = '好的，识别结果如下：\n```json\n{"体重": 70, "体脂率": 22.4}\n```\n'
          '以上数据请核对。';
      final parsed = BodyCompositionParser.fromVisionJson(raw);
      expect(parsed['体重'], 70);
      expect(parsed['体脂率'], 22.4);
    });

    test('别名与英文键归一（骨骼肌量/BMR/内脏脂肪/weight）', () {
      const raw = '{"Weight":"65.5kg","骨骼肌量":48.7,"体脂肪率":"20.1%",'
          '"BMR":1500,"内脏脂肪":9,"Body Water":56.2,"Bone Mass":2.8,'
          '"蛋白质":16.9}';
      final parsed = BodyCompositionParser.fromVisionJson(raw);
      expect(parsed['体重'], 65.5);
      expect(parsed['肌肉量'], 48.7);
      expect(parsed['体脂率'], 20.1);
      expect(parsed['基础代谢'], 1500);
      expect(parsed['内脏脂肪等级'], 9);
      expect(parsed['体水分率'], 56.2);
      expect(parsed['骨量'], 2.8);
      expect(parsed['蛋白质率'], 16.9);
    });

    test('嵌套取值：值为对象时取 value/数值', () {
      const raw = '{"体重":{"value":61.2,"unit":"kg"},"腰围":{"数值":"76 cm"}}';
      final parsed = BodyCompositionParser.fromVisionJson(raw);
      expect(parsed['体重'], 61.2);
      expect(parsed['腰围'], 76);
    });

    test('无关键与非法数值被忽略，不产生脏数据', () {
      const raw = '{"体重":62.5,"测量时间":"2026-10-07 08:30","内脏脂肪等级":"偏低",'
          '"备注":""}';
      final parsed = BodyCompositionParser.fromVisionJson(raw);
      expect(parsed.keys, ['体重']);
    });
  });

  group('T7-2 本地 OCR 纯文本解析（降级路径）', () {
    test('逐行匹配「指标名 + 数值」', () {
      const raw = '体脂秤测量结果\n'
          '体重 62.5kg\n'
          '体脂率 18.3%\n'
          '骨骼肌量 49.2kg\n'
          '体水分率：55.1%\n'
          '骨量 2.6kg\n'
          '蛋白质率 17.2%\n'
          '基础代谢 1420kcal\n'
          '内脏脂肪等级 8\n'
          '腰围 78cm';
      final parsed = BodyCompositionParser.fromPlainText(raw);
      expect(parsed.length, 9);
      expect(parsed['体重'], 62.5);
      expect(parsed['肌肉量'], 49.2);
      expect(parsed['基础代谢'], 1420);
      expect(parsed['内脏脂肪等级'], 8);
      expect(parsed['腰围'], 78);
    });

    test('空输入与垃圾输入返回空表且不抛异常（本地 OCR 不可用时不崩溃）', () {
      expect(BodyCompositionParser.fromPlainText(''), isEmpty);
      expect(BodyCompositionParser.fromPlainText('   \n  \n'), isEmpty);
      expect(BodyCompositionParser.fromPlainText('？？？？ ----'), isEmpty);
      expect(BodyCompositionParser.fromVisionJson(''), isEmpty);
      expect(BodyCompositionParser.fromVisionJson('无法识别'), isEmpty);
      expect(BodyCompositionParser.fromVisionJson('{不是合法JSON'), isEmpty);
      expect(BodyCompositionParser.fromVisionJson('[1,2,3]'), isEmpty);
    });
  });

  group('T7-3 指标类型登记表', () {
    test('体成分类型全部在 metricTypes 与 typeUnits 中登记，且两表一致', () {
      expect(
        HealthMetric.bodyCompositionTypes.length,
        greaterThanOrEqualTo(7),
        reason: '体测批量录入一次至少覆盖 7 项体成分',
      );
      for (final type in HealthMetric.bodyCompositionTypes) {
        expect(HealthMetric.metricTypes, contains(type));
        expect(HealthMetric.typeUnits.containsKey(type), isTrue,
            reason: '$type 缺少默认单位');
      }
      // metricTypes 与 typeUnits 必须一一对应，避免两处登记表漂移
      expect(HealthMetric.metricTypes.toSet(), HealthMetric.typeUnits.keys.toSet());
      // T5 记录：穿戴聚合会产出「血氧」，此处补齐类型
      expect(HealthMetric.metricTypes, contains('血氧'));
    });
  });

  group('T7-4 体测批量录入落库', () {
    test('一次录入 7 项体成分成功，单位自动带出，可逐条删除', () async {
      final provider = AppProvider();
      final note = 'T7验收体测-${DateTime.now().microsecondsSinceEpoch}';
      const values = {
        '体重': 62.5,
        '体脂率': 18.3,
        '肌肉量': 49.2,
        '体水分率': 55.1,
        '骨量': 2.6,
        '蛋白质率': 17.2,
        '基础代谢': 1420.0,
      };
      final batch = [
        for (final entry in values.entries)
          HealthMetric(
            date: DateTime(2026, 10, 7),
            type: entry.key,
            value: entry.value,
            unit: HealthMetric.typeUnits[entry.key],
            note: note,
          ),
      ];

      // 批量落库：一次体测 = 一组同日期、同备注的记录
      await provider.addHealthMetrics(batch);

      final saved =
          provider.healthMetrics.where((m) => m.note == note).toList();
      expect(saved.length, 7, reason: '一次体测应落库 7 项');
      expect(saved.map((m) => m.type).toSet(), values.keys.toSet());
      expect(saved.firstWhere((m) => m.type == '体重').unit, 'kg');
      expect(saved.firstWhere((m) => m.type == '基础代谢').unit, 'kcal');
      expect(saved.firstWhere((m) => m.type == '体脂率').value, 18.3);
      expect(saved.every((m) => m.date == DateTime(2026, 10, 7)), isTrue);

      // 空列表为幂等空操作
      await provider.addHealthMetrics(const []);

      // 清理本次写入，避免污染其他用例
      for (final metric in saved) {
        await provider.deleteHealthMetric(metric.id!);
      }
      expect(provider.healthMetrics.where((m) => m.note == note), isEmpty);
    });

    test('体测数据入同步队列（健康指标参与云同步，与穿戴快照不同）', () async {
      final db = await helper.database;
      final note = 'T7队列体测-${DateTime.now().microsecondsSinceEpoch}';
      final provider = AppProvider();
      await provider.addHealthMetrics([
        HealthMetric(
          date: DateTime(2026, 10, 7),
          type: '肌肉量',
          value: 49.2,
          unit: HealthMetric.typeUnits['肌肉量'],
          note: note,
        ),
      ]);

      final rows = await db.query(
        'sync_queue',
        where: 'table_name = ?',
        whereArgs: ['health_metrics'],
        orderBy: 'op_id DESC',
        limit: 1,
      );
      expect(rows, isNotEmpty);
      expect(rows.first['op'], 'upsert');

      final saved = provider.healthMetrics.where((m) => m.note == note).toList();
      for (final metric in saved) {
        await provider.deleteHealthMetric(metric.id!);
      }
    });
  });
}
