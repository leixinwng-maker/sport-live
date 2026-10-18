/// 专家模式：在不额外发起第二轮模型调用的前提下，为特定场景追加专用指令。
///
/// 之所以不做「独立子智能体」：端上嵌套调用会翻倍延迟与费用，还要处理递归、
/// 超时与结果汇总；而这些场景的收益主要来自"先读数据、再按固定结构输出"，
/// 用提示词 + 既有工具路由即可覆盖。
library;

/// 可识别的专家场景
enum AgentExpert { none, healthReport, workoutPlan, diet }

/// 从用户输入（含最近两轮上下文）识别专家场景。
///
/// 按关键词命中数打分，避免单词误判：
/// - 「减脂」既可能指训练也可能指饮食，单靠关键词先后顺序会误判；
/// - 体检报告命中优先（≥ 其他场景），其余场景按命中数取高者，
///   平手时饮食优先（「减脂期三餐怎么吃」应判为饮食）。
AgentExpert detectExpert(String text) {
  if (text.trim().isEmpty) return AgentExpert.none;

  const healthReportKeys = [
    '体检',
    '化验',
    '报告单',
    '指标',
    '参考范围',
    '血常规',
    '肝功能',
    '肾功能',
    '血脂',
    '尿酸',
    'b超',
    'ct',
    '核磁',
    '片子',
    '结节',
    '阳性',
  ];
  const workoutKeys = [
    '训练计划',
    '怎么练',
    '练什么',
    '增肌',
    '减脂',
    '塑形',
    '力量训练',
    '有氧计划',
    '周计划',
    '动作安排',
    '练几',
  ];
  const dietKeys = [
    '饮食',
    '食谱',
    '热量',
    '营养',
    '碳水',
    '蛋白质',
    '三餐',
    '早餐',
    '午餐',
    '晚餐',
    '加餐',
    '外卖',
    '怎么吃',
  ];

  final lower = text.toLowerCase();
  int hits(List<String> keys) => keys.where(lower.contains).length;

  final healthHits = hits(healthReportKeys);
  final workoutHits = hits(workoutKeys);
  final dietHits = hits(dietKeys);

  if (healthHits > 0 &&
      healthHits >= workoutHits &&
      healthHits >= dietHits) {
    return AgentExpert.healthReport;
  }
  if (dietHits > 0 && dietHits >= workoutHits) return AgentExpert.diet;
  if (workoutHits > 0) return AgentExpert.workoutPlan;
  if (dietHits > 0) return AgentExpert.diet;
  return AgentExpert.none;
}

/// 场景专用指令块；无场景返回空串，避免系统提示无谓变长。
String expertPrompt(AgentExpert expert) {
  switch (expert) {
    case AgentExpert.healthReport:
      return '''
【本轮专家模式：体检报告解读】
1. 先调用工具读取报告原文与结构化指标，不凭用户口述猜测数值。
2. 逐项对照参考范围，说明偏高/偏低方向与幅度；报告未提供的项目不要编造。
3. 按「建议尽快就医 / 建议复查 / 观察随访」三档给出分级，并写明依据。
4. 不做疾病诊断，不给用药方案与剂量。
5. 结尾给出「就诊时可向医生确认的问题」清单。''';
    case AgentExpert.workoutPlan:
      return '''
【本轮专家模式：训练计划】
1. 先确认目标、每周可训练天数与单次时长、器械条件、伤病史；缺关键信息先追问，不要直接排计划。
2. 按 FITT-VP 输出周计划（频率/强度/时间/类型/总量/进阶）。
3. 强度用 RPE 或心率区间标注；说明渐进超负荷的具体做法。
4. 列出禁忌与停止信号（疼痛、眩晕、胸闷等）。
5. 不承诺具体减重斤数或时间表。''';
    case AgentExpert.diet:
      return '''
【本轮专家模式：饮食分析】
1. 先调用工具读取饮食记录，按餐次列出实际摄入。
2. 估算总热量与三大营养素，明确标注「估算值」。
3. 给 2–3 条可执行的替换建议，优先常见食材与家常做法。
4. 不推荐补剂剂量，不提供极端节食或断食方案。
5. 若有慢病、孕期或用药情况，提示先咨询医生或营养师。''';
    case AgentExpert.none:
      return '';
  }
}
