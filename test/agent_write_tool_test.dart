import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/agent_service.dart';
import 'package:ai_planner/services/ai_engine.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// FIT-2 单测：智能体「写工具」——只产待确认载荷，绝不落库
///
/// 覆盖：
/// 1. `propose_workout_plan` / `log_workout`：成功产 `PendingAction`，且 **AppProvider 数据不变**；
/// 2. `propose_diet_plan` / `log_diet`：同上；
/// 3. 参数校验失败分支文案（缺 name / days / meals，或条目内无有效明细）；
/// 4. 空明细过滤、可选字段落位、`mealType` 兼容键与默认值；
/// 5. [PendingAction] 的 JSON 往返与容错反序列化；
/// 6. 四个写工具已登记进工具表（含 required 与中文标签、描述含「不会直接保存」）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppProvider provider;
  late AgentService service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    provider = AppProvider();
    service = AgentService(AIEngine())..provider = provider;
  });

  // ---------------------------------------------------------------------------
  // W1 训练计划 / 训练记录
  // ---------------------------------------------------------------------------

  group('W1 propose_workout_plan / log_workout', () {
    final args = {
      'name': '三分化增肌计划',
      'goal': '增肌',
      'split': '三分化',
      'daysPerWeek': 3,
      'days': [
        {
          'name': '推日',
          'exercises': [
            {'name': '杠铃卧推', 'targetSets': 4, 'targetReps': 8, 'targetWeight': 60},
            {'name': '哑铃飞鸟', 'targetSets': 3, 'targetReps': 12},
          ],
        },
        {
          'name': '拉日',
          'exercises': [
            {'name': '硬拉', 'sets': 3, 'reps': 5, 'weight': 120},
          ],
        },
      ],
    };

    test('成功：产 PendingAction，文本含「尚未保存」，且不落库', () async {
      final res = await service.executeTool('propose_workout_plan', args);

      expect(res.action, isNotNull);
      expect(res.action!.type, 'workout_plan');
      expect(res.action!.data['name'], '三分化增肌计划');
      expect(res.action!.data['goal'], '增肌');
      expect(res.action!.data['split'], '三分化');
      expect(res.action!.data['daysPerWeek'], 3);
      expect(res.action!.data['days'], hasLength(2));
      expect(res.text, contains('尚未保存'));
      expect(res.text, contains('三分化增肌计划'));
      expect(res.text, contains('共 2 天'));

      // 核心安全断言：写工具绝不触碰 Provider 数据
      expect(provider.workoutPlans, isEmpty, reason: '待确认方案不得写入计划库');
      expect(provider.workouts, isEmpty, reason: '待确认记录不得写入训练记录');
    });

    test('log_workout：类型为 workout_log，文案为「训练记录」', () async {
      final res = await service.executeTool('log_workout', args);
      expect(res.action!.type, 'workout_log');
      expect(res.text, contains('训练记录'));
      expect(res.text, contains('尚未保存'));
      expect(provider.workouts, isEmpty);
    });

    test('空 exercises 的训练日被过滤，仅保留有效天', () async {
      final res = await service.executeTool('propose_workout_plan', {
        'name': '计划',
        'days': [
          {'name': '推日', 'exercises': [{'name': '卧推'}]},
          {'name': '空日', 'exercises': <Map<String, dynamic>>[]},
          {'name': '脏日', 'exercises': '不是列表'},
        ],
      });
      final days = res.action!.data['days'] as List;
      expect(days, hasLength(1));
      expect(days.first['name'], '推日');
      expect(res.text, contains('共 1 天'));
    });

    test('可选字段为空/缺失时不写入载荷', () async {
      final res = await service.executeTool('propose_workout_plan', {
        'name': '极简计划',
        'goal': '   ',
        'days': [
          {
            'name': '日',
            'exercises': [
              {'name': '深蹲'},
            ],
          },
        ],
      });
      expect(res.action!.data.containsKey('goal'), isFalse);
      expect(res.action!.data.containsKey('split'), isFalse);
      expect(res.action!.data.containsKey('daysPerWeek'), isFalse);
    });

    test('缺 name：校验失败且不产载荷', () async {
      final res = await service.executeTool('propose_workout_plan', {'days': args['days']});
      expect(res.text, '参数校验失败：缺少 name（计划名称）');
      expect(res.action, isNull);
    });

    test('name 仅空白视同缺失', () async {
      final res =
          await service.executeTool('propose_workout_plan', {'name': '  ', 'days': args['days']});
      expect(res.text, '参数校验失败：缺少 name（计划名称）');
      expect(res.action, isNull);
    });

    test('缺 days / days 非列表 / days 为空：统一校验失败', () async {
      const expected = '参数校验失败：缺少 days（至少一个训练日）';
      expect((await service.executeTool('propose_workout_plan', {'name': 'x'})).text, expected);
      expect((await service.executeTool('propose_workout_plan', {'name': 'x', 'days': 'oops'})).text,
          expected);
      expect((await service.executeTool('propose_workout_plan', {'name': 'x', 'days': []})).text,
          expected);
    });

    test('days 中每天都没有有效 exercises：校验失败', () async {
      final res = await service.executeTool('propose_workout_plan', {
        'name': 'x',
        'days': [
          {'name': 'd1', 'exercises': <Map<String, dynamic>>[]},
          '脏数据',
        ],
      });
      expect(res.text, '参数校验失败：days 中每天都需要至少一个 exercises 条目');
      expect(res.action, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // W2 饮食方案 / 饮食记录
  // ---------------------------------------------------------------------------

  group('W2 propose_diet_plan / log_diet', () {
    final args = {
      'targetCalories': 2200,
      'meals': [
        {
          'mealType': '早餐',
          'foods': [
            {'name': '燕麦', 'grams': 80, 'calories': 300},
            {'name': '鸡蛋', 'grams': 100, 'calories': 140},
          ],
        },
        {
          'meal_type': '午餐',
          'foods': [
            {'name': '鸡胸肉', 'grams': 200, 'calories': 330},
          ],
        },
      ],
    };

    test('成功：产 PendingAction，文本含「尚未保存」，且不落库', () async {
      final res = await service.executeTool('propose_diet_plan', args);

      expect(res.action, isNotNull);
      expect(res.action!.type, 'diet_plan');
      expect(res.action!.data['targetCalories'], 2200);
      final meals = res.action!.data['meals'] as List;
      expect(meals, hasLength(2));
      expect(meals[0]['mealType'], '早餐');
      expect(meals[1]['mealType'], '午餐', reason: 'meal_type 兼容键应被识别');
      expect(res.text, contains('尚未保存'));
      expect(res.text, contains('饮食方案'));
      expect(res.text, contains('共 2 餐'));

      expect(provider.dietRecords, isEmpty, reason: '待确认方案不得写入饮食记录');
    });

    test('log_diet：类型为 diet_log，文案为「饮食记录」', () async {
      final res = await service.executeTool('log_diet', args);
      expect(res.action!.type, 'diet_log');
      expect(res.text, contains('饮食记录'));
      expect(res.text, contains('尚未保存'));
      expect(provider.dietRecords, isEmpty);
    });

    test('mealType 缺失回落「正餐」，date 写入载荷', () async {
      final res = await service.executeTool('log_diet', {
        'date': '2026-10-08',
        'meals': [
          {
            'foods': [
              {'name': '米饭', 'grams': 150},
            ],
          },
        ],
      });
      final meals = res.action!.data['meals'] as List;
      expect(meals.first['mealType'], '正餐');
      expect(res.action!.data['date'], '2026-10-08');
    });

    test('无 foods 的餐次被过滤', () async {
      final res = await service.executeTool('propose_diet_plan', {
        'meals': [
          {
            'mealType': '早餐',
            'foods': [
              {'name': '鸡蛋', 'grams': 50},
            ],
          },
          {'mealType': '空餐', 'foods': <Map<String, dynamic>>[]},
        ],
      });
      expect(res.action!.data['meals'], hasLength(1));
      expect(res.text, contains('共 1 餐'));
    });

    test('缺 meals / 非列表 / 空列表：统一校验失败', () async {
      const expected = '参数校验失败：缺少 meals（至少一个餐次）';
      expect((await service.executeTool('propose_diet_plan', {})).text, expected);
      expect((await service.executeTool('log_diet', {'meals': 'oops'})).text, expected);
      expect((await service.executeTool('log_diet', {'meals': []})).text, expected);
    });

    test('每餐都没有 foods：校验失败', () async {
      final res = await service.executeTool('propose_diet_plan', {
        'meals': [
          {'mealType': '早餐', 'foods': <Map<String, dynamic>>[]},
        ],
      });
      expect(res.text, '参数校验失败：meals 中每一餐都需要至少一个 foods 条目');
      expect(res.action, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // W3 PendingAction JSON 往返与容错
  // ---------------------------------------------------------------------------

  group('W3 PendingAction 序列化', () {
    test('toJson / fromJson 往返一致', () {
      const action = PendingAction(
        type: 'workout_plan',
        data: {'name': 'x', 'days': []},
      );
      final back = PendingAction.fromJson(action.toJson());
      expect(back, isNotNull);
      expect(back!.type, 'workout_plan');
      expect(back.data['name'], 'x');
      expect(back.data['days'], isEmpty);
    });

    test('fromJson 容错：非法结构一律返回 null（调用方降级为纯文本）', () {
      expect(PendingAction.fromJson(null), isNull);
      expect(PendingAction.fromJson('字符串'), isNull);
      expect(PendingAction.fromJson(42), isNull);
      expect(PendingAction.fromJson(const {'data': {}}), isNull, reason: '缺 type');
      expect(PendingAction.fromJson(const {'type': '', 'data': {}}), isNull, reason: 'type 为空');
      expect(PendingAction.fromJson(const {'type': 'x'}), isNull, reason: '缺 data');
      expect(PendingAction.fromJson(const {'type': 'x', 'data': 'no'}),
          isNull, reason: 'data 非 Map');
    });

    test('fromJson 兼容 dynamic 来源（如 SharedPreferences 读回的 JSON）', () {
      final decoded = <String, dynamic>{
        'type': 'diet_plan',
        'data': <String, dynamic>{'meals': <dynamic>[]},
      };
      final back = PendingAction.fromJson(decoded);
      expect(back!.type, 'diet_plan');
      expect(back.data['meals'], isEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // W4 工具注册
  // ---------------------------------------------------------------------------

  group('W4 工具注册与 schema', () {
    Map<String, dynamic> paramsOf(String name) {
      final schema = service.toolSchemas.firstWhere(
        (s) => (s['function'] as Map)['name'] == name,
      );
      return (schema['function'] as Map)['parameters'] as Map<String, dynamic>;
    }

    test('四个写工具均已登记，中文标签正确', () {
      expect(service.toolLabel('propose_workout_plan'), '生成训练计划');
      expect(service.toolLabel('propose_diet_plan'), '生成饮食方案');
      expect(service.toolLabel('log_workout'), '记录训练');
      expect(service.toolLabel('log_diet'), '记录饮食');
    });

    test('required 参数符合约定', () {
      expect(paramsOf('propose_workout_plan')['required'], ['name', 'days']);
      expect(paramsOf('log_workout')['required'], ['name', 'days']);
      expect(paramsOf('propose_diet_plan')['required'], ['meals']);
      expect(paramsOf('log_diet')['required'], ['meals']);
    });

    test('描述显式声明「不会直接保存」（安全提示不得缺失）', () {
      for (final name in [
        'propose_workout_plan',
        'propose_diet_plan',
        'log_workout',
        'log_diet',
      ]) {
        final schema = service.toolSchemas.firstWhere(
          (s) => (s['function'] as Map)['name'] == name,
        );
        final desc = (schema['function'] as Map)['description'] as String;
        expect(desc, contains('不会直接保存'), reason: '$name 描述缺少安全声明');
      }
    });
  });
}
