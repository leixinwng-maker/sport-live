import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:ai_planner/providers/agent_provider.dart';
import 'package:ai_planner/providers/app_provider.dart';
import 'package:ai_planner/services/database_helper.dart';

/// 智能体对话持久化：从 SharedPreferences 明文迁入 SQLCipher 本地库，并支持多会话。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    sqfliteFfiInit();
    tmp = await Directory.systemTemp.createTemp('wendao_agent_');
    await databaseFactoryFfi.setDatabasesPath(tmp.path);
    await DatabaseHelper.reset();
  });

  tearDown(() async {
    await DatabaseHelper.reset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> waitUntil(bool Function() cond) async {
    for (var i = 0; i < 100 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  test('首次加载创建会话；新会话保留旧记录；切换与删除生效', () async {
    SharedPreferences.setMockInitialValues({});
    final agent = AgentProvider()..attach(AppProvider());
    await waitUntil(() => agent.sessions.isNotEmpty);

    expect(agent.sessions.length, 1, reason: '首次加载应自动建一个会话');
    final firstId = agent.sessionId;
    expect(firstId, isNotNull);

    await agent.startNewSession();
    expect(agent.sessions.length, 2, reason: '新会话不应删除旧会话');
    expect(agent.sessionId, isNot(firstId));

    await agent.loadSession(firstId!);
    expect(agent.sessionId, firstId);

    await agent.deleteSession(firstId);
    expect(agent.sessions.length, 1);
    expect(agent.sessionId, isNot(firstId));
  });

  test('旧版 SharedPreferences 明文记录迁入本地库并清除旧键', () async {
    SharedPreferences.setMockInitialValues({
      'agent_chat_history': jsonEncode([
        {'role': 'user', 'content': '我最近睡不好', 'time': 1700000000000},
        {'role': 'assistant', 'content': '先看看睡眠数据', 'time': 1700000001000},
      ]),
    });

    final agent = AgentProvider()..attach(AppProvider());
    await waitUntil(() => agent.messages.isNotEmpty);

    expect(agent.sessions.length, 1);
    expect(agent.messages.length, 2);
    expect(agent.messages.first.content, '我最近睡不好');

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('agent_chat_history'), isNull, reason: '迁移后应清除明文旧键');
  });
}
