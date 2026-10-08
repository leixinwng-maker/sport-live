import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ai_planner/models/evidence.dart';
import 'package:ai_planner/services/knowledge_engine.dart';

/// P4-T2 验收：循证库接入本地智脑 RAG
/// 1. 构建期产物 assets/data/evidence_kb.json 可解析为三类模型（离线，无网络）
/// 2. 检索「高血压 运动」命中循证条目，来源标记为「循证库」
/// 3. 循证条目无视领域过滤（alwaysSearch），健康问题不会被场景过滤误伤
/// 4. 注入文本保留出处（meta），满足强制引用要求
void main() {
  late List<EvidenceEntry> evidence;
  late List<MetEntry> met;
  late List<ExerciseRef> exercises;

  setUpAll(() {
    final file = File('assets/data/evidence_kb.json');
    expect(file.existsSync(), isTrue, reason: '缺少构建期产物，请先运行 scripts/import_knowledge.py');
    final map = json.decode(file.readAsStringSync()) as Map<String, dynamic>;
    evidence = (map['evidence'] as List)
        .map((e) => EvidenceEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    met = (map['met'] as List)
        .map((e) => MetEntry.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
    exercises = (map['exercises'] as List)
        .map((e) => ExerciseRef.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  });

  test('T2-1 构建期产物结构完整，条目均带出处', () {
    expect(evidence, isNotEmpty);
    expect(evidence.length, greaterThanOrEqualTo(30));
    expect(met, isNotEmpty);
    expect(exercises, isNotEmpty);
    for (final e in evidence) {
      expect(e.id, isNotEmpty);
      expect(e.condition, isNotEmpty);
      expect(e.recommendation, isNotEmpty);
      expect(e.source, isNotEmpty, reason: '${e.id} 缺出处');
      expect(e.license, isNotEmpty, reason: '${e.id} 缺许可标注');
      expect(e.evidenceLevel, anyOf('指南推荐', '系统评价', 'RCT'));
    }
  });

  test('T2-2 检索「高血压 运动」命中循证条目且来源为循证库', () {
    final chunks = KnowledgeEngine.retrieve(
      entries: const [],
      books: const [],
      evidence: evidence,
      query: '高血压 运动',
      topN: 5,
    );
    expect(chunks, isNotEmpty, reason: '未命中任何片段');
    expect(chunks.first.source, '循证库');
    expect(chunks.first.title, contains('高血压'));
    expect(chunks.any((c) => c.title.contains('高血压')), isTrue);
  });

  test('T2-3 循证条目无视领域过滤（alwaysSearch）', () {
    // 「高血压 训练」会推断出 fitness 域；循证条目 domain 为「慢病」，
    // 若不设 alwaysSearch 会被过滤掉，此处应仍能命中。
    final domains = KnowledgeEngine.inferDomains('高血压 训练');
    expect(domains, contains('fitness'));
    final chunks = KnowledgeEngine.retrieve(
      entries: const [],
      books: const [],
      evidence: evidence,
      query: '高血压 训练',
      topN: 5,
      domains: domains,
    );
    expect(chunks.any((c) => c.source == '循证库'), isTrue);
  });

  test('T2-4 注入文本保留出处（meta）', () {
    final chunks = KnowledgeEngine.retrieve(
      entries: const [],
      books: const [],
      evidence: evidence,
      query: '糖尿病 有氧运动',
      topN: 3,
    );
    final text = KnowledgeEngine.formatChunks(chunks, maxChars: 200);
    expect(text, contains('【循证库】'));
    expect(text, contains('出处：'));
  });

  test('T2-5 MET 表与动作库模型解析正确', () {
    final walk = met.firstWhere((m) => m.activity.contains('快走'));
    expect(walk.met, greaterThan(0));
    expect(walk.intensity, anyOf('低强度', '中等强度', '高强度'));
    expect(walk.kcalPerMin(70), greaterThan(0));

    final bench = exercises.firstWhere((x) => x.name == '杠铃卧推');
    expect(bench.muscle, '胸');
    expect(bench.equipment, '杠铃');
  });
}
