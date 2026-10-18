import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/screens/settings/settings_screen.dart';
import 'package:ai_planner/services/cloud_api.dart';

/// 设置页「智能体工具范围」开关：
/// 默认按意图路由（false），点击后切到全量工具（true）并写入本地设置。
void main() {
  testWidgets('智能体工具范围默认关闭，可切换为全量并持久化', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final provider = AppProvider();

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: provider,
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    expect(provider.agentFullTools, isFalse, reason: '默认应为自动路由');

    final tile = find.widgetWithText(SwitchListTile, '智能体工具范围');
    expect(tile, findsOneWidget);

    await tester.tap(find.descendant(of: tile, matching: find.byType(Switch)));
    await tester.pump();

    expect(provider.agentFullTools, isTrue);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('agent_full_tools'), isTrue, reason: '设置应落本地存储');
  });

  testWidgets('注销账号：未登录时提示先登录', (tester) async {
    SharedPreferences.setMockInitialValues({});
    CloudApi.instance.authenticated = false;

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: AppProvider(),
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    final tile = find.text('注销账号');
    await tester.dragUntilVisible(
      tile,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(tile);
    await tester.pump();

    expect(find.text('请先登录账号，再执行注销'), findsOneWidget);
  });

  testWidgets('注销账号：登录后弹确认框并说明删除范围与备份保留期', (tester) async {
    SharedPreferences.setMockInitialValues({});
    CloudApi.instance.authenticated = true;
    addTearDown(() => CloudApi.instance.authenticated = false);

    await tester.pumpWidget(
      ChangeNotifierProvider<AppProvider>.value(
        value: AppProvider(),
        child: const MaterialApp(home: SettingsScreen()),
      ),
    );
    await tester.pump();

    final tile = find.text('注销账号');
    await tester.dragUntilVisible(
      tile,
      find.byType(ListView),
      const Offset(0, -300),
    );
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.text('永久注销'), findsOneWidget);
    expect(find.textContaining('14 天'), findsOneWidget);
    expect(find.textContaining('此操作不可恢复'), findsOneWidget);
  });
}
