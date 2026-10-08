/// 循证证据条目（P4-A）
///
/// 把权威指南 / 系统评价中"什么运动、什么营养能改善什么疾病"的结论
/// 结构化为可检索条目，供本地智脑 RAG 检索与智能体工具返回。
///
/// 内容由 `scripts/import_knowledge.py` 从官方素材改写/摘要生成，
/// **不复制原文全文**，逐条带出处与许可标注。
class EvidenceEntry {
  final String id;

  /// 内容领域：慢病 / 运动 / 营养 / 中医
  final String domain;

  /// 目标疾病或健康目标（如 高血压 / 2型糖尿病 / 减脂）
  final String condition;

  /// 可检索主题词（空格分隔，供场景匹配）
  final String topic;

  /// 结构化推荐正文（宜含 FITT：频率 / 强度 / 时间 / 类型）
  final String recommendation;

  /// 证据等级：指南推荐 / 系统评价 / RCT
  final String evidenceLevel;

  /// 出处（机构 + 文献名）
  final String source;

  /// 来源链接
  final String url;

  /// 许可与使用限制
  final String license;

  EvidenceEntry({
    required this.id,
    required this.domain,
    required this.condition,
    required this.topic,
    required this.recommendation,
    required this.evidenceLevel,
    required this.source,
    required this.url,
    required this.license,
  });

  /// 参与 RAG 检索的文本（标题 + 主题词 + 正文）
  String get searchText =>
      '$condition $topic $recommendation $evidenceLevel';

  /// 引用一行（供智能体输出出处）
  String get citation => '《$source》$url';

  Map<String, dynamic> toMap() => {
        'id': id,
        'domain': domain,
        'condition': condition,
        'topic': topic,
        'recommendation': recommendation,
        'evidenceLevel': evidenceLevel,
        'source': source,
        'url': url,
        'license': license,
      };

  factory EvidenceEntry.fromMap(Map<String, dynamic> map) => EvidenceEntry(
        id: (map['id'] ?? '').toString(),
        domain: (map['domain'] ?? '运动').toString(),
        condition: (map['condition'] ?? '').toString(),
        topic: (map['topic'] ?? '').toString(),
        recommendation: (map['recommendation'] ?? '').toString(),
        evidenceLevel: (map['evidenceLevel'] ?? '指南推荐').toString(),
        source: (map['source'] ?? '').toString(),
        url: (map['url'] ?? '').toString(),
        license: (map['license'] ?? '').toString(),
      );

  /// 格式化供工具返回（含出处与等级）
  String toToolText() {
    final buf = StringBuffer();
    buf.writeln('【$condition｜$evidenceLevel】');
    buf.writeln(recommendation);
    buf.writeln('出处：$source');
    if (url.isNotEmpty) buf.writeln('链接：$url');
    return buf.toString().trimRight();
  }
}

/// 代谢当量（MET）条目 —— 摘自 Compendium of Physical Activities
///
/// 强度分级按通用标准：<3.0 低强度、3.0-5.9 中等强度、≥6.0 高强度。
class MetEntry {
  /// 活动名称
  final String activity;

  /// 代谢当量（1 MET ≈ 静息代谢，约 1 kcal/kg/h）
  final double met;

  /// 分类（步行/跑步/骑行/球类/力量/日常等）
  final String category;

  /// 补充说明（速度、强度等）
  final String note;

  MetEntry({
    required this.activity,
    required this.met,
    required this.category,
    this.note = '',
  });

  /// 强度分级：低 / 中等 / 高
  String get intensity {
    if (met < 3.0) return '低强度';
    if (met < 6.0) return '中等强度';
    return '高强度';
  }

  /// 按体重估算每分钟消耗（kcal/min）= MET × 3.5 × 体重(kg) / 200
  double kcalPerMin(double weightKg) => met * 3.5 * weightKg / 200.0;

  Map<String, dynamic> toMap() => {
        'activity': activity,
        'met': met,
        'category': category,
        if (note.isNotEmpty) 'note': note,
      };

  factory MetEntry.fromMap(Map<String, dynamic> map) => MetEntry(
        activity: (map['activity'] ?? '').toString(),
        met: (map['met'] as num?)?.toDouble() ?? 0,
        category: (map['category'] ?? '').toString(),
        note: (map['note'] ?? '').toString(),
      );
}

/// 动作库条目（供 query_exercise 工具与训练页复用）
class ExerciseRef {
  /// 中文动作名
  final String name;

  /// 英文名（对应 Free Exercise DB 等英文库）
  final String nameEn;

  /// 主要肌群：胸/背/肩/腿/臀/手臂/核心/全身
  final String muscle;

  /// 器械：杠铃/哑铃/器械/绳索/自重/壶铃等
  final String equipment;

  /// 难度：初级/中级/高级
  final String level;

  /// 动作要点（自撰，2-3 句）
  final String cues;

  ExerciseRef({
    required this.name,
    this.nameEn = '',
    required this.muscle,
    this.equipment = '自重',
    this.level = '初级',
    this.cues = '',
  });

  Map<String, dynamic> toMap() => {
        'name': name,
        if (nameEn.isNotEmpty) 'nameEn': nameEn,
        'muscle': muscle,
        'equipment': equipment,
        'level': level,
        'cues': cues,
      };

  factory ExerciseRef.fromMap(Map<String, dynamic> map) => ExerciseRef(
        name: (map['name'] ?? '').toString(),
        nameEn: (map['nameEn'] ?? '').toString(),
        muscle: (map['muscle'] ?? '').toString(),
        equipment: (map['equipment'] ?? '自重').toString(),
        level: (map['level'] ?? '初级').toString(),
        cues: (map['cues'] ?? '').toString(),
      );
}

/// 运动类别 → 具体动作示例（P5 第二层，弱证据）
///
/// 仅提供「示例动作名称 + 一般性注意」，**不提供任何疗效主张**，
/// 绝不表述为「某动作改善某病」。动作名称须能在 [ExerciseRef] 库中找到。
class ExerciseExampleEntry {
  /// 运动类别：有氧 / 抗阻 / 柔韧 / 平衡 / 身心
  final String category;

  /// 动作中文名（须能在动作库中找到）
  final List<String> examples;

  /// 通用动作要领（自撰改写）
  final String cues;

  /// 禁忌 / 注意（须可溯源到指南或常识性安全原则）
  final List<String> cautions;

  /// 出处（动作来源 + 禁忌来源）
  final String source;

  final String url;
  final String license;

  ExerciseExampleEntry({
    required this.category,
    required this.examples,
    this.cues = '',
    this.cautions = const [],
    this.source = '',
    this.url = '',
    this.license = '',
  });

  /// 参与检索的文本（类别 + 动作名 + 要领）
  String get searchText => '$category ${examples.join(' ')} $cues';

  Map<String, dynamic> toMap() => {
        'category': category,
        'examples': examples,
        'cues': cues,
        'cautions': cautions,
        'source': source,
        'url': url,
        'license': license,
      };

  factory ExerciseExampleEntry.fromMap(Map<String, dynamic> map) =>
      ExerciseExampleEntry(
        category: (map['category'] ?? '').toString(),
        examples: ((map['examples'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        cues: (map['cues'] ?? '').toString(),
        cautions: ((map['cautions'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        source: (map['source'] ?? '').toString(),
        url: (map['url'] ?? '').toString(),
        license: (map['license'] ?? '').toString(),
      );
}

/// 「疾病—运动」检索结果：两层结构，强证据在前、弱证据在后。
class ConditionExerciseResult {
  /// 第一层：疾病/人群 → 运动类别 + 剂量（强证据，domain='疾病运动'）
  final List<EvidenceEntry> evidence;

  /// 第二层：运动类别 → 动作示例 + 禁忌（弱证据，永不含疗效主张）
  final List<ExerciseExampleEntry> examples;

  const ConditionExerciseResult({
    this.evidence = const [],
    this.examples = const [],
  });

  bool get isEmpty => evidence.isEmpty && examples.isEmpty;
}

/// 开源医学文献条目（P5 联网文献检索）
///
/// 合规要点（硬约束，详见 docs/research/2026-10-08-p5-literature-databases-research.md）：
/// - **只承载「元数据 + 链接」**，不含摘要或正文原文 —— 规避出版商摘要版权；
///   要点由模型按需改写，本地不落正文、不再分发，符合「不整篇转载」底线。
/// - [license] 逐条标注，用于判断该文是否可再分发；NC（非商用）条目在服务层已过滤。
class LiteratureRef {
  /// 论文标题（已去标签与结尾句点）
  final String title;

  /// 作者（最多 3 位，超出以「等」结尾）
  final String authors;

  /// 期刊 / 来源名
  final String journal;

  /// 发表年份（0 表示未知）
  final int year;

  /// DOI（不含 https://doi.org/ 前缀，可为空）
  final String doi;

  /// 是否开放获取
  final bool isOpenAccess;

  /// 许可标识，如 cc by / cc0 / cc by-nd；空表示未标注
  final String license;

  /// 著录 / 原文落地页链接（始终为合法可访问地址）
  final String url;

  /// 合法开放获取全文直链（无则为空）—— 仅指 OA 版本，不含订阅版正文
  final String pdfUrl;

  /// 来源库：Europe PMC / OpenAlex
  final String source;

  /// 被引次数（用于判断证据影响力，0 表示未知）
  final int citations;

  const LiteratureRef({
    required this.title,
    this.authors = '',
    this.journal = '',
    this.year = 0,
    this.doi = '',
    this.isOpenAccess = false,
    this.license = '',
    this.url = '',
    this.pdfUrl = '',
    this.source = '',
    this.citations = 0,
  });

  /// 许可显示：有标注则大写（如 CC BY）；未标注时按开放状态给中文描述
  String get licenseLabel {
    if (license.isNotEmpty) return license.toUpperCase();
    return isOpenAccess ? '开放获取（许可未标注）' : '非开放获取';
  }
}
