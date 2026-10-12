import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/services/voice_diet_parser.dart';

/// FIT-7 语音饮食解析层单测
///
/// 纯计算层（无 IO / 无 Flutter 依赖），直接断言中文口语 → 结构化条目：
/// 餐次识别、数量与量词切分、克数估算、中文数字误切防护、默认餐次推断。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('餐次识别', () {
    test('mealTypes 固定四项', () {
      expect(VoiceDietParser.mealTypes, ['早餐', '午餐', '晚餐', '加餐']);
    });

    test('口语关键词映射到四个餐次', () {
      expect(VoiceDietParser.parse('早饭一个鸡蛋').mealType, '早餐');
      expect(VoiceDietParser.parse('中午一碗米饭').mealType, '午餐');
      expect(VoiceDietParser.parse('晚饭一个苹果').mealType, '晚餐');
      expect(VoiceDietParser.parse('夜宵一碗面').mealType, '加餐');
      expect(VoiceDietParser.parse('下午茶一块蛋糕').mealType, '加餐');
    });

    test('未指明餐次时按当前时间推断（四时段）', () {
      String at(int hour) =>
          VoiceDietParser.parse('一个鸡蛋', now: DateTime(2026, 10, 8, hour))
              .mealType;
      expect(at(8), '早餐');
      expect(at(12), '午餐');
      expect(at(18), '晚餐');
      expect(at(23), '加餐');
      expect(at(3), '加餐');
    });

    test('defaultMealType 边界：04 / 11 / 15 / 22 点切换', () {
      String at(int hour) => VoiceDietParser.defaultMealType(DateTime(2026, 10, 8, hour));
      expect(at(3), '加餐');
      expect(at(4), '早餐');
      expect(at(10), '早餐');
      expect(at(11), '午餐');
      expect(at(14), '午餐');
      expect(at(15), '晚餐');
      expect(at(21), '晚餐');
      expect(at(22), '加餐');
    });
  });

  group('数量与量词切分', () {
    test('「早餐两个鸡蛋一杯牛奶」→ 两条：鸡蛋 100g、牛奶 250g', () {
      final result = VoiceDietParser.parse('早餐两个鸡蛋一杯牛奶');
      expect(result.mealType, '早餐');
      expect(result.items.length, 2, reason: '一段内含两条应被切出');

      final egg = result.items[0];
      expect(egg.name, '鸡蛋');
      expect(egg.quantity, 2);
      expect(egg.unit, '个');
      expect(egg.grams, 100, reason: '2 个鸡蛋 × 单件 50g');

      final milk = result.items[1];
      expect(milk.name, '牛奶');
      expect(milk.quantity, 1);
      expect(milk.unit, '杯');
      expect(milk.grams, 250, reason: '1 杯 × 250g');
    });

    test('「中午吃了碗米饭和鸡胸肉200克」→ 连接词切分 + 尾随数量', () {
      final result = VoiceDietParser.parse('中午吃了碗米饭和鸡胸肉200克');
      expect(result.mealType, '午餐');
      expect(result.items.length, 2);

      expect(result.items[0].name, '米饭');
      expect(result.items[0].quantity, 1);
      expect(result.items[0].unit, '碗');
      expect(result.items[0].grams, 150);

      expect(result.items[1].name, '鸡胸肉');
      expect(result.items[1].quantity, 200);
      expect(result.items[1].unit, '克');
      expect(result.items[1].grams, 200);
    });

    test('「加餐一杯酸奶，一根香蕉」→ 标点切分为两条', () {
      final result = VoiceDietParser.parse('加餐一杯酸奶，一根香蕉');
      expect(result.mealType, '加餐');
      expect(result.items.length, 2);
      expect(result.items[0].name, '酸奶');
      expect(result.items[0].grams, 250);
      expect(result.items[1].name, '香蕉');
      expect(result.items[1].grams, 100);
    });

    test('中文数字「半」解析为 0.5', () {
      final result = VoiceDietParser.parse('加餐半个苹果');
      expect(result.items.length, 1);
      final apple = result.items[0];
      expect(apple.name, '苹果');
      expect(apple.quantity, 0.5);
      expect(apple.grams, 100, reason: '0.5 × 苹果单件 200g');
      expect(apple.quantityLabel, '0.5 个');
    });

    test('中文数字「十 / 十四 / 二十」正确解析', () {
      expect(VoiceDietParser.parse('十个鸡蛋').items.first.quantity, 10);
      expect(VoiceDietParser.parse('十四个鸡蛋').items.first.quantity, 14);
      expect(VoiceDietParser.parse('二十个鸡蛋').items.first.quantity, 20);
    });

    test('全角数字「１」被归一化为半角', () {
      final result = VoiceDietParser.parse('早餐１个鸡蛋');
      expect(result.items.length, 1);
      expect(result.items.first.name, '鸡蛋');
      expect(result.items.first.quantity, 1);
      expect(result.items.first.grams, 50);
    });

    test('「三文鱼」不被中文数字误切', () {
      final result = VoiceDietParser.parse('三文鱼');
      expect(result.items.length, 1);
      expect(result.items.first.name, '三文鱼', reason: '「三」后无量词应整体作食物名');
      expect(result.items.first.quantity, 1);
    });
  });

  group('空输入与容错', () {
    test('空串 / 纯空白 → isEmpty，餐次按当前时间推断', () {
      final empty = VoiceDietParser.parse('', now: DateTime(2026, 10, 8, 12));
      expect(empty.isEmpty, isTrue);
      expect(empty.isNotEmpty, isFalse);
      expect(empty.mealType, '午餐');
      expect(empty.rawText, '');

      final blank =
          VoiceDietParser.parse('   ', now: DateTime(2026, 10, 8, 8));
      expect(blank.isEmpty, isTrue);
      expect(blank.mealType, '早餐');
    });

    test('纯动词噪声（「吃了」）被剥离后不产生条目', () {
      expect(VoiceDietParser.parse('吃了').items, isEmpty);
      expect(VoiceDietParser.parse('喝了').items, isEmpty);
    });

    test('rawText 保留原始文本，item 提供人类可读数量描述', () {
      final result = VoiceDietParser.parse('早餐两个鸡蛋');
      expect(result.rawText, '早餐两个鸡蛋');
      expect(result.items.first.quantityLabel, '2 个');

      final noUnit = VoiceDietParser.parse('早餐鸡蛋');
      expect(noUnit.items.first.unit, '');
      expect(noUnit.items.first.quantityLabel, '1 份', reason: '无量词按「份」展示');
    });
  });

  group('estimateGrams 量词换算', () {
    double grams(String name, double quantity, String unit) => VoiceDietParser
        .estimateGrams(name: name, quantity: quantity, unit: unit);

    test('重量与体积：克 / g / 毫升 / ml 按原值', () {
      expect(grams('鸡胸肉', 200, '克'), 200);
      expect(grams('鸡胸肉', 200, 'g'), 200);
      expect(grams('水', 300, '毫升'), 300);
      expect(grams('水', 300, 'ml'), 300);
    });

    test('中式重量：两 ×50、斤 ×500', () {
      expect(grams('牛肉', 1, '两'), 50);
      expect(grams('西瓜', 1, '斤'), 500);
      expect(grams('西瓜', 2, '斤'), 1000);
    });

    test('容器量词：碗 ×150、杯 ×250、瓶 ×500、罐/听 ×330', () {
      expect(grams('米饭', 1, '碗'), 150);
      expect(grams('牛奶', 1, '杯'), 250);
      expect(grams('可乐', 1, '瓶'), 500);
      expect(grams('可乐', 1, '罐'), 330);
      expect(grams('可乐', 1, '听'), 330);
    });

    test('小量词：勺/汤匙 ×15、片 ×25、根/条 ×100', () {
      expect(grams('橄榄油', 1, '勺'), 15);
      expect(grams('橄榄油', 1, '汤匙'), 15);
      expect(grams('面包', 2, '片'), 50);
      expect(grams('香蕉', 1, '根'), 100);
      expect(grams('黄瓜', 1, '条'), 100);
    });

    test('块 / 袋 / 份 统一按 100g', () {
      expect(grams('豆腐', 1, '块'), 100);
      expect(grams('坚果', 1, '袋'), 100);
      expect(grams('沙拉', 1, '份'), 100);
    });

    test('计件食物按单件克数表，未知食物按 100g', () {
      expect(grams('鸡蛋', 1, '个'), 50);
      expect(grams('苹果', 1, '个'), 200);
      expect(grams('香蕉', 1, '个'), 120);
      expect(grams('核桃', 1, '颗'), 10);
      expect(grams('未知食物', 1, '个'), 100, reason: '未命中表回落 100g');
    });

    test('计件食物支持模糊命中（「水煮鸡蛋」→ 鸡蛋）', () {
      expect(grams('水煮鸡蛋', 1, '个'), 50);
    });

    test('无量词按每份 100g', () {
      expect(grams('米饭', 1, ''), 100);
      expect(grams('米饭', 2, ''), 200);
    });

    test('数量 ≤ 0 时按 1 计算，避免产出 0g', () {
      expect(grams('鸡蛋', 0, '个'), 50);
      expect(grams('鸡蛋', -1, '个'), 50);
      expect(grams('米饭', 0, '碗'), 150);
    });
  });

  group('数量展示', () {
    test('整数不显示小数位，非整数原样展示', () {
      const whole = VoiceFoodItem(name: '鸡蛋', quantity: 2, unit: '个', grams: 100);
      expect(whole.quantityLabel, '2 个');

      const fraction =
          VoiceFoodItem(name: '苹果', quantity: 0.5, unit: '个', grams: 100);
      expect(fraction.quantityLabel, '0.5 个');

      const noUnit = VoiceFoodItem(name: '鸡蛋', quantity: 1, unit: '', grams: 50);
      expect(noUnit.quantityLabel, '1 份');
    });
  });
}
