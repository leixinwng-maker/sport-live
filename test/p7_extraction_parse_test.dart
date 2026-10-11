import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/health_data_extraction.dart';

/// P7-T4 结构化提取解析单测：围栏剥离 / 字段缺失容错 / 坏数据降级
void main() {
  group('HealthDataExtraction.parse', () {
    test('剥离 ```json 围栏并解析完整字段', () {
      const output = '```json\n'
          '{\n'
          '  "reportType": "化验",\n'
          '  "metrics": [{\n'
          '    "rawName": "空腹血糖",\n'
          '    "type": "空腹血糖",\n'
          '    "value": "6.5",\n'
          '    "unit": "mmol/L",\n'
          '    "referenceRange": "3.9-6.1 mmol/L",\n'
          '    "light": "yellow",\n'
          '    "interpretation": "偏高"\n'
          '  }],\n'
          '  "actions": [{\n'
          '    "title": "复查空腹血糖",\n'
          '    "category": "复查",\n'
          '    "light": "yellow",\n'
          '    "needsFollowup": true,\n'
          '    "dueDate": "2026-11-01",\n'
          '    "detail": "90天内复查"\n'
          '  }],\n'
          '  "summary": "空腹血糖偏高"\n'
          '}\n'
          '```';
      final r = HealthDataExtraction.parse(output);
      expect(r.reportType, '化验');
      expect(r.metrics, hasLength(1));
      final m = r.metrics.first;
      expect(m.type, '空腹血糖');
      expect(m.hasValidValue, isTrue);
      expect(m.value, 6.5);
      expect(m.light, RiskLight.yellow);
      expect(r.actions, hasLength(1));
      final a = r.actions.first;
      expect(a.needsFollowup, isTrue);
      expect(a.dueDate, DateTime(2026, 11, 1));
      expect(r.summary, '空腹血糖偏高');
    });

    test('裸 JSON 字段缺失容错：value 缺失置 NaN，actions 空数组', () {
      const output =
          '{"reportType":"体检","metrics":[{"rawName":"血压 120/80"}],"summary":"无数据"}';
      final r = HealthDataExtraction.parse(output);
      expect(r.metrics, hasLength(1));
      final m = r.metrics.first;
      expect(m.hasValidValue, isFalse);
      expect(m.value.isNaN, isTrue);
      expect(m.light, RiskLight.unknown);
      expect(r.actions, isEmpty);
      expect(r.reportType, '体检');
    });

    test('坏数据抛 ExtractionException：非 JSON / 根不是对象', () {
      expect(
        () => HealthDataExtraction.parse('这不是 JSON'),
        throwsA(isA<ExtractionException>()),
      );
      expect(
        () => HealthDataExtraction.parse('```json\n[1,2,3]\n```'),
        throwsA(isA<ExtractionException>()),
      );
    });
  });

  group('HealthAction.listFromJson 兼容', () {
    test('v1 包装 / 裸数组 / 空串 / 坏数据', () {
      final action = HealthAction(
        title: '复查血脂',
        category: '复查',
        light: RiskLight.yellow,
        needsFollowup: true,
        dueDate: DateTime(2026, 12, 1),
      );
      // v1 包装往返
      final wrapped = HealthAction.listToJson([action]);
      final back = HealthAction.listFromJson(wrapped);
      expect(back, hasLength(1));
      expect(back.first.title, '复查血脂');
      expect(back.first.dueDate, DateTime(2026, 12, 1));
      // 裸数组兼容
      const bare = '[{"title":"多喝水","category":"生活"}]';
      final bareList = HealthAction.listFromJson(bare);
      expect(bareList, hasLength(1));
      expect(bareList.first.category, '生活');
      // 空串 / 坏数据返回空表
      expect(HealthAction.listFromJson(''), isEmpty);
      expect(HealthAction.listFromJson('bad json'), isEmpty);
    });
  });
}
