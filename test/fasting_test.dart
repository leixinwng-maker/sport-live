import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_planner/models/fasting.dart';
import 'package:ai_planner/services/fasting_service.dart';
import 'package:ai_planner/services/fasting_settings.dart';

/// FIT-7 断食模块单测
///
/// 覆盖：`FastingPlan` 档位与回落、`FastingSession` 时长/达成/序列化、
/// `FastingService` 状态机（idle / fasting / goalReached）与窗口统计、
/// 四种时间格式化，以及 `FastingSettingsStore` 持久化往返。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('FastingPlan 档位', () {
    test('预设共 5 档且和为 24 小时', () {
      expect(FastingPlan.presets.length, 5);
      for (final p in FastingPlan.presets) {
        expect(p.fastHours + p.eatHours, 24, reason: '${p.label} 应满足 24 小时制');
      }
      expect(FastingPlan.defaults, FastingPlan.h16x8);
    });

    test('label / description / duration', () {
      expect(FastingPlan.h16x8.label, '16:8');
      expect(FastingPlan.h16x8.description, '禁食 16 小时 · 进食 8 小时');
      expect(FastingPlan.h16x8.duration, const Duration(hours: 16));
    });

    test('isAdvanced：禁食 ≥18 小时为进阶档', () {
      expect(FastingPlan.h12x12.isAdvanced, isFalse);
      expect(FastingPlan.h16x8.isAdvanced, isFalse);
      expect(FastingPlan.h18x6.isAdvanced, isTrue);
      expect(FastingPlan.h20x4.isAdvanced, isTrue);
    });

    test('fromFastHours 命中预设；未命中回落默认档', () {
      expect(FastingPlan.fromFastHours(12), FastingPlan.h12x12);
      expect(FastingPlan.fromFastHours(16), FastingPlan.h16x8);
      expect(FastingPlan.fromFastHours(20), FastingPlan.h20x4);
      expect(FastingPlan.fromFastHours(17), FastingPlan.defaults,
          reason: '非预设小时数应回落 16:8');
      expect(FastingPlan.fromFastHours(0), FastingPlan.defaults);
    });

    test('== 按两字段比较', () {
      expect(const FastingPlan(fastHours: 16, eatHours: 8), FastingPlan.h16x8);
      expect(const FastingPlan(fastHours: 16, eatHours: 8) == FastingPlan.h18x6,
          isFalse);
    });
  });

  group('FastingSession 时长与达成', () {
    final start = DateTime(2026, 10, 8, 20, 0);

    test('isActive：endAt 为空表示进行中', () {
      expect(FastingSession(startAt: start).isActive, isTrue);
      expect(
        FastingSession(startAt: start, endAt: start.add(const Duration(hours: 16)))
            .isActive,
        isFalse,
      );
    });

    test('elapsedAt：进行中按当前时间算，已结束按起止差算', () {
      final running = FastingSession(startAt: start, targetHours: 16);
      expect(running.elapsedAt(start.add(const Duration(hours: 8))),
          const Duration(hours: 8));

      final ended = FastingSession(
        startAt: start,
        endAt: start.add(const Duration(hours: 14)),
      );
      expect(ended.elapsedAt(start.add(const Duration(hours: 99))),
          const Duration(hours: 14),
          reason: '已结束的记录不随后续时间变化');
    });

    test('elapsedAt：负差值归零', () {
      final s = FastingSession(startAt: start);
      expect(s.elapsedAt(start.subtract(const Duration(hours: 1))), Duration.zero);
    });

    test('actualDuration：进行中为 0；负差值归零', () {
      expect(FastingSession(startAt: start).actualDuration, Duration.zero);
      final bad = FastingSession(
        startAt: start,
        endAt: start.subtract(const Duration(hours: 1)),
      );
      expect(bad.actualDuration, Duration.zero);
    });

    test('goalMet：仅已结束且达到目标时长才算达成', () {
      expect(FastingSession(startAt: start).goalMet, isFalse,
          reason: '进行中不算达成');
      final met = FastingSession(
        startAt: start,
        endAt: start.add(const Duration(hours: 16)),
        targetHours: 16,
      );
      expect(met.goalMet, isTrue);
      final early = FastingSession(
        startAt: start,
        endAt: start.add(const Duration(hours: 15, minutes: 59)),
        targetHours: 16,
      );
      expect(early.goalMet, isFalse);
    });

    test('target 由 targetHours 换算，默认 16 小时', () {
      expect(FastingSession(startAt: start).target, const Duration(hours: 16));
      expect(FastingSession(startAt: start, targetHours: 18).target,
          const Duration(hours: 18));
    });

    test('copyWith：clearEndAt 可显式清空结束时间', () {
      final ended = FastingSession(
        startAt: start,
        endAt: start.add(const Duration(hours: 16)),
      );
      expect(ended.copyWith().isActive, isFalse);
      expect(ended.copyWith(clearEndAt: true).isActive, isTrue,
          reason: 'clearEndAt 应清空 endAt');
      expect(ended.copyWith(targetHours: 18).targetHours, 18);
    });

    test('toMap / fromMap 往返', () {
      final ended = FastingSession(
        id: 'fast_x',
        startAt: start,
        endAt: start.add(const Duration(hours: 16)),
        targetHours: 18,
      );
      final map = ended.toMap();
      expect(map['id'], 'fast_x');
      expect(map['target_hours'], 18);
      final back = FastingSession.fromMap(map);
      expect(back.id, 'fast_x');
      expect(back.startAt, start);
      expect(back.endAt, start.add(const Duration(hours: 16)));
      expect(back.targetHours, 18);
    });

    test('fromMap：end_at 空串/null → 进行中；非法 target_hours → 16', () {
      final nullEnd = FastingSession.fromMap({
        'id': 'a',
        'start_at': start.toIso8601String(),
        'end_at': null,
        'target_hours': 16,
      });
      expect(nullEnd.endAt, isNull);

      final emptyEnd = FastingSession.fromMap({
        'id': 'b',
        'start_at': start.toIso8601String(),
        'end_at': '',
        'target_hours': 16,
      });
      expect(emptyEnd.endAt, isNull, reason: '空串应视为进行中');

      final badHours = FastingSession.fromMap({
        'id': 'c',
        'start_at': start.toIso8601String(),
        'end_at': null,
        'target_hours': 18.0,
      });
      expect(badHours.targetHours, 16, reason: '非 int 的 target_hours 回落 16');
    });

    test('newFastingId 前缀为 fast_ 且互不相同', () {
      final a = newFastingId();
      final b = newFastingId();
      expect(a.startsWith('fast_'), isTrue);
      expect(a == b, isFalse);
    });
  });

  group('FastingService 状态机', () {
    final now = DateTime(2026, 10, 8, 12, 0);

    test('status(null) 或已结束 → idle', () {
      final s1 = FastingService.status(null, now);
      expect(s1.phase, FastingPhase.idle);
      expect(s1.isActive, isFalse);
      expect(s1.goalReached, isFalse);

      final ended = FastingSession(
        startAt: now.subtract(const Duration(hours: 20)),
        endAt: now.subtract(const Duration(hours: 4)),
        targetHours: 16,
      );
      final s2 = FastingService.status(ended, now);
      expect(s2.phase, FastingPhase.idle);
    });

    test('进行中未达标 → fasting，remaining 为正', () {
      final active = FastingSession(
        startAt: now.subtract(const Duration(hours: 8)),
        targetHours: 16,
      );
      final s = FastingService.status(active, now);
      expect(s.phase, FastingPhase.fasting);
      expect(s.isActive, isTrue);
      expect(s.elapsed, const Duration(hours: 8));
      expect(s.remaining, const Duration(hours: 8));
      expect(s.overtime, Duration.zero);
      expect(s.targetHours, 16);
      expect(s.progress, closeTo(0.5, 0.0001));
    });

    test('正好达到目标 → goalReached，overtime 为零', () {
      final active = FastingSession(
        startAt: now.subtract(const Duration(hours: 16)),
        targetHours: 16,
      );
      final s = FastingService.status(active, now);
      expect(s.phase, FastingPhase.goalReached);
      expect(s.goalReached, isTrue);
      expect(s.remaining, Duration.zero);
      expect(s.overtime, Duration.zero);
      expect(s.progress, 1.0);
    });

    test('超出目标 → goalReached，overtime 为超出部分', () {
      final active = FastingSession(
        startAt: now.subtract(const Duration(hours: 18)),
        targetHours: 16,
      );
      final s = FastingService.status(active, now);
      expect(s.phase, FastingPhase.goalReached);
      expect(s.overtime, const Duration(hours: 2));
      expect(s.remaining, Duration.zero);
      expect(s.progress, 1.0, reason: '进度条收敛到满格');
    });

    test('activeOf：多条进行中取开始最晚的一条', () {
      final older = FastingSession(startAt: now.subtract(const Duration(hours: 20)));
      final newer = FastingSession(startAt: now.subtract(const Duration(hours: 2)));
      final ended = FastingSession(
        startAt: now.subtract(const Duration(hours: 30)),
        endAt: now.subtract(const Duration(hours: 14)),
      );
      expect(FastingService.activeOf([older, ended, newer]), newer);
      expect(FastingService.activeOf([older, ended]), older);
      expect(FastingService.activeOf([ended]), isNull);
      expect(FastingService.activeOf([]), isNull);
    });

    test('sortedDesc：按开始时间倒序且不改动原列表', () {
      final a = FastingSession(startAt: DateTime(2026, 10, 6));
      final b = FastingSession(startAt: DateTime(2026, 10, 8));
      final c = FastingSession(startAt: DateTime(2026, 10, 7));
      final input = [a, b, c];
      final sorted = FastingService.sortedDesc(input);
      expect(sorted.map((s) => s.startAt).toList(), [
        DateTime(2026, 10, 8),
        DateTime(2026, 10, 7),
        DateTime(2026, 10, 6),
      ]);
      expect(input.first, a, reason: '原列表顺序不应被修改');
      expect(input.length, 3);
    });
  });

  group('FastingService 统计', () {
    final now = DateTime(2026, 10, 8, 12, 0);

    test('stats：跳过进行中与窗口外记录', () {
      final sessions = [
        FastingSession(
          startAt: DateTime(2026, 10, 7, 20),
          endAt: DateTime(2026, 10, 8, 12),
          targetHours: 16,
        ),
        FastingSession(
          startAt: DateTime(2026, 10, 6, 20),
          endAt: DateTime(2026, 10, 7, 10),
          targetHours: 16,
        ),
        // 窗口外（早于 10-01 12:00）
        FastingSession(
          startAt: DateTime(2026, 9, 20, 20),
          endAt: DateTime(2026, 9, 21, 12),
          targetHours: 16,
        ),
        // 进行中
        FastingSession(startAt: DateTime(2026, 10, 8, 10), targetHours: 16),
      ];

      final stats = FastingService.stats(sessions, now: now, days: 7);
      expect(stats.completedCount, 2);
      expect(stats.goalMetCount, 1);
      expect(stats.totalDuration, const Duration(hours: 30));
      expect(stats.longest, const Duration(hours: 16));
      expect(stats.goalRate, closeTo(0.5, 0.0001));
      expect(stats.averageDuration, const Duration(hours: 15));
    });

    test('stats：空列表 → 全零且达成率为 0', () {
      final stats = FastingService.stats([], now: now);
      expect(stats.completedCount, 0);
      expect(stats.goalMetCount, 0);
      expect(stats.totalDuration, Duration.zero);
      expect(stats.longest, Duration.zero);
      expect(stats.goalRate, 0);
      expect(stats.averageDuration, Duration.zero);
    });

    test('FastingStats.empty 常量符合预期', () {
      expect(FastingStats.empty.completedCount, 0);
      expect(FastingStats.empty.goalRate, 0);
      expect(FastingStats.empty.averageDuration, Duration.zero);
    });
  });

  group('FastingService 时间格式化', () {
    test('formatDuration：0 分 / 纯分钟 / 小时加分钟', () {
      expect(FastingService.formatDuration(Duration.zero), '0分');
      expect(FastingService.formatDuration(const Duration(minutes: 48)), '48分');
      expect(
        FastingService.formatDuration(const Duration(hours: 16, minutes: 8)),
        '16小时08分',
      );
      expect(FastingService.formatDuration(const Duration(seconds: -10)), '0分');
    });

    test('formatClock：有小时显示 h:mm:ss，否则 mm:ss', () {
      expect(FastingService.formatClock(Duration.zero), '00:00');
      expect(FastingService.formatClock(const Duration(minutes: 8, seconds: 32)),
          '08:32');
      expect(
        FastingService.formatClock(const Duration(hours: 16, minutes: 8, seconds: 32)),
        '16:08:32',
      );
      expect(FastingService.formatClock(const Duration(seconds: -5)), '00:00');
    });

    test('formatDateTime / formatTime 补零', () {
      final t = DateTime(2026, 10, 8, 20, 30);
      expect(FastingService.formatDateTime(t), '10-08 20:30');
      expect(FastingService.formatTime(t), '20:30');

      final early = DateTime(2026, 1, 5, 9, 5);
      expect(FastingService.formatDateTime(early), '01-05 09:05');
      expect(FastingService.formatTime(early), '09:05');
    });
  });

  group('FastingSettings 持久化', () {
    test('默认：16:8 且首页展示', () {
      const s = FastingSettings();
      expect(s.plan, FastingPlan.defaults);
      expect(s.showOnDietHome, isTrue);
    });

    test('copyWith 修改字段', () {
      const s = FastingSettings();
      final changed = s.copyWith(plan: FastingPlan.h18x6, showOnDietHome: false);
      expect(changed.plan, FastingPlan.h18x6);
      expect(changed.showOnDietHome, isFalse);
      expect(s.copyWith().plan, FastingPlan.defaults, reason: '未传字段保持');
    });

    test('Store：save → load 往返一致', () async {
      const store = FastingSettingsStore();
      const settings =
          FastingSettings(plan: FastingPlan.h18x6, showOnDietHome: false);
      await store.save(settings);
      final loaded = await store.load();
      expect(loaded, settings);
    });

    test('Store：无存储时回落默认', () async {
      final loaded = await const FastingSettingsStore().load();
      expect(loaded, const FastingSettings());
    });

    test('Store：存储小时数不在预设内 → 回落 16:8', () async {
      SharedPreferences.setMockInitialValues({
        'fasting_plan_fast_hours': 17,
        'fasting_show_on_diet_home': false,
      });
      final loaded = await const FastingSettingsStore().load();
      expect(loaded.plan, FastingPlan.defaults);
      expect(loaded.showOnDietHome, isFalse);
    });
  });
}
