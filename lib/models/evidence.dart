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

  /// 证据等级：指南推荐 / 系统评价 / RCT / 古籍
  ///
  /// 「古籍」为中医经典原文的单独口径（传统学说记载，非临床证据等级），
  /// 排序时始终位于最低位，避免与指南/系统评价混列。
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

/// 本体术语（P6-D1）—— 运动医学本体 EXMO 与康复本体 RehabO
///
/// 硬约束：字段自上游本体文件（exmo.obo / rehabo-edit.owl）**原样搬运**，
/// 仅保留 id / label / 同义词 / 定义 / 父类；**不翻译、不改写、不推断**，
/// 避免自造术语污染语义标准。EXMO 为 CC BY 4.0（须署名），RehabO 为 CC0。
class OntologyTerm {
  /// 术语 CURIE（EXM:0000001 / REHABO:0000000）
  final String id;

  /// 所属本体：EXMO（运动医学）/ RehabO（康复）
  final String ontology;

  /// 原始英文标签
  final String label;

  /// 精确同义词（原始标签，可为空）
  final List<String> altLabels;

  /// 原始定义（英文；无定义为空串）
  final String definition;

  /// 父类 CURIE（可为空）
  final List<String> parents;

  const OntologyTerm({
    required this.id,
    required this.ontology,
    required this.label,
    this.altLabels = const [],
    this.definition = '',
    this.parents = const [],
  });

  /// 参与检索的文本
  String get searchText =>
      '$id $ontology $label ${altLabels.join(' ')} $definition';

  /// 引用一行（供智能体输出出处）
  String get citation => '$ontology $id ($label)';

  Map<String, dynamic> toMap() => {
        'id': id,
        'ontology': ontology,
        'label': label,
        'altLabels': altLabels,
        'definition': definition,
        'parents': parents,
      };

  factory OntologyTerm.fromMap(Map<String, dynamic> map) => OntologyTerm(
        id: (map['id'] ?? '').toString(),
        ontology: (map['ontology'] ?? '').toString(),
        label: (map['label'] ?? '').toString(),
        altLabels: ((map['altLabels'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        definition: (map['definition'] ?? '').toString(),
        parents: ((map['parents'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
      );

  /// 格式化供工具返回（术语原文 + 定义 + 出处）
  String toToolText() {
    final buf = StringBuffer();
    buf.writeln('$label ($id)');
    if (altLabels.isNotEmpty) buf.writeln('同义词：${altLabels.join(' / ')}');
    if (definition.isNotEmpty) buf.writeln(definition);
    if (parents.isNotEmpty) buf.writeln('上级术语：${parents.join(', ')}');
    buf.writeln('出处：$ontology（原始术语，未翻译）');
    return buf.toString().trimRight();
  }
}

/// 开放数据与本体登记条目（P6-D2）
///
/// **只承载元数据与获取指引**（名称/规模/许可/获取方式），不含任何正文数据。
/// [access] 三态：已接入（数据已随 App 打包）/ 可接入（许可已核实、待接入）/
/// 登记题录（许可或入口未核实，仅作线索登记，**不接入任何数据**）。
class DatasetRegistryEntry {
  final String id;

  /// 中文名
  final String name;

  /// 英文名 / 全称
  final String nameEn;

  /// 类型：本体 / 知识图谱 / 数据集 / 食品数据库 / 开源软件
  final String kind;

  /// 领域（运动医学 / 康复 / 营养 / 生物医学 等）
  final String domain;

  /// 规模描述
  final String scale;

  /// 许可协议
  final String license;

  /// 接入状态：已接入 / 可接入 / 登记题录
  final String access;

  /// 项目主页（登记题录条目可为空）
  final String url;

  /// 可直达的数据文件地址（可为空）
  final String dataUrl;

  /// 说明与合规备注
  final String note;

  const DatasetRegistryEntry({
    required this.id,
    required this.name,
    this.nameEn = '',
    required this.kind,
    required this.domain,
    this.scale = '',
    required this.license,
    required this.access,
    this.url = '',
    this.dataUrl = '',
    this.note = '',
  });

  /// 已接入/可接入为「可直接使用」，登记题录为「仅线索」
  bool get isUsable => access == '已接入' || access == '可接入';

  String get searchText =>
      '$name $nameEn $kind $domain $scale $license $access $note';

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'nameEn': nameEn,
        'kind': kind,
        'domain': domain,
        'scale': scale,
        'license': license,
        'access': access,
        'url': url,
        'dataUrl': dataUrl,
        'note': note,
      };

  factory DatasetRegistryEntry.fromMap(Map<String, dynamic> map) =>
      DatasetRegistryEntry(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        nameEn: (map['nameEn'] ?? '').toString(),
        kind: (map['kind'] ?? '').toString(),
        domain: (map['domain'] ?? '').toString(),
        scale: (map['scale'] ?? '').toString(),
        license: (map['license'] ?? '').toString(),
        access: (map['access'] ?? '').toString(),
        url: (map['url'] ?? '').toString(),
        dataUrl: (map['dataUrl'] ?? '').toString(),
        note: (map['note'] ?? '').toString(),
      );

  /// 格式化供工具返回
  String toToolText() {
    final buf = StringBuffer();
    buf.writeln('【$kind｜$access】$name${nameEn.isNotEmpty ? ' ($nameEn)' : ''}');
    if (domain.isNotEmpty) buf.writeln('领域：$domain');
    if (scale.isNotEmpty) buf.writeln('规模：$scale');
    if (license.isNotEmpty) buf.writeln('许可：$license');
    if (url.isNotEmpty) buf.writeln('主页：$url');
    if (dataUrl.isNotEmpty) buf.writeln('数据：$dataUrl');
    if (note.isNotEmpty) buf.writeln(note);
    return buf.toString().trimRight();
  }
}

/// 开放动作库条目（P6-D3）—— Exercises Dataset + Free Exercise DB 归并
///
/// 硬约束：构建期已**剥离全部媒体字段**（图片/动图/视频均不收录，其版权属原作者）；
/// 本类只承载文本数据。中文说明 [steps] 为上游提供的自然中文，非本应用翻译。
class CatalogExercise {
  /// 稳定 id（exds-0001 / fedb-xxxx）
  final String id;

  /// 英文动作名
  final String name;

  /// 中文名（可能为空，为 Gym visual 数据集附带的中文名）
  final String nameZh;

  /// 主要目标肌群（已中文化）
  final String target;

  /// 目标肌群原始英文值（如 abs / biceps）
  final String targetRaw;

  /// 协同肌群（已中文化）
  final List<String> secondary;

  /// 身体部位分类（胸/背/腿/肩/手臂/腰腹 等）
  final String bodyPart;

  /// 器械（自重/杠铃/哑铃/器械/绳索 等）
  final String equipment;

  /// 难度（可能为空）
  final String level;

  /// 动作说明（中文 lang=zh 时为中文；lang=en 时为英文原文）
  final String steps;

  /// 语言：zh / en
  final String lang;

  /// 来源库名
  final String source;

  final String license;
  final String url;

  const CatalogExercise({
    required this.id,
    required this.name,
    this.nameZh = '',
    required this.target,
    this.targetRaw = '',
    this.secondary = const [],
    required this.bodyPart,
    required this.equipment,
    this.level = '',
    this.steps = '',
    this.lang = 'zh',
    this.source = '',
    this.license = '',
    this.url = '',
  });

  /// 展示名：优先中文名，缺省回落英文名
  String get displayName => nameZh.isNotEmpty ? nameZh : name;

  /// 参与检索的文本
  String get searchText =>
      '$name $nameZh $target $targetRaw ${secondary.join(' ')} $bodyPart $equipment $steps';

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'nameZh': nameZh,
        'target': target,
        'targetRaw': targetRaw,
        'secondary': secondary,
        'bodyPart': bodyPart,
        'equipment': equipment,
        'level': level,
        'steps': steps,
        'lang': lang,
        'source': source,
        'license': license,
        'url': url,
      };

  factory CatalogExercise.fromMap(Map<String, dynamic> map) => CatalogExercise(
        id: (map['id'] ?? '').toString(),
        name: (map['name'] ?? '').toString(),
        nameZh: (map['nameZh'] ?? '').toString(),
        target: (map['target'] ?? '').toString(),
        targetRaw: (map['targetRaw'] ?? '').toString(),
        secondary: ((map['secondary'] as List?) ?? const [])
            .map((e) => e.toString())
            .toList(),
        bodyPart: (map['bodyPart'] ?? '').toString(),
        equipment: (map['equipment'] ?? '').toString(),
        level: (map['level'] ?? '').toString(),
        steps: (map['steps'] ?? '').toString(),
        lang: (map['lang'] ?? 'zh').toString(),
        source: (map['source'] ?? '').toString(),
        license: (map['license'] ?? '').toString(),
        url: (map['url'] ?? '').toString(),
      );

  /// 格式化供工具返回
  String toToolText() {
    final buf = StringBuffer();
    buf.writeln('$displayName${nameZh.isNotEmpty ? '（$name）' : ''}');
    buf.writeln('部位：$bodyPart｜目标肌群：$target'
        '${secondary.isNotEmpty ? '（协同：${secondary.join('、')}）' : ''}');
    buf.writeln('器械：$equipment${level.isNotEmpty ? '｜难度：$level' : ''}');
    if (steps.isNotEmpty) buf.writeln(steps);
    buf.writeln('来源：$source');
    return buf.toString().trimRight();
  }
}
