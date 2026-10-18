import 'package:flutter_test/flutter_test.dart';

import 'package:ai_planner/services/agent_experts.dart';

/// 专家模式：场景识别与专用指令（不发起额外模型调用）
void main() {
  test('体检报告类问题识别为 healthReport', () {
    expect(detectExpert('帮我看看今年的体检报告'), AgentExpert.healthReport);
    expect(detectExpert('这个化验指标偏高要紧吗'), AgentExpert.healthReport);
  });

  test('训练计划类问题识别为 workoutPlan', () {
    expect(detectExpert('给我排一个增肌训练计划'), AgentExpert.workoutPlan);
    expect(detectExpert('一周练几次、怎么练比较合适'), AgentExpert.workoutPlan);
  });

  test('饮食类问题识别为 diet', () {
    expect(detectExpert('帮我看看今天的饮食热量'), AgentExpert.diet);
    expect(detectExpert('减脂期三餐怎么吃'), AgentExpert.diet);
  });

  test('普通问题不进入专家模式', () {
    expect(detectExpert('我今天走了多少步'), AgentExpert.none);
    expect(detectExpert(''), AgentExpert.none);
  });

  test('多场景命中时优先体检报告', () {
    expect(
      detectExpert('体检报告血脂高，顺便给我个训练计划'),
      AgentExpert.healthReport,
    );
  });

  test('专家指令包含安全边界', () {
    final report = expertPrompt(AgentExpert.healthReport);
    expect(report, contains('不做疾病诊断'));
    expect(report, contains('不给用药方案'));

    final workout = expertPrompt(AgentExpert.workoutPlan);
    expect(workout, contains('伤病史'));
    expect(workout, contains('停止信号'));

    final diet = expertPrompt(AgentExpert.diet);
    expect(diet, contains('估算值'));
    expect(diet, contains('不推荐补剂剂量'));
  });

  test('none 返回空串，不增加系统提示长度', () {
    expect(expertPrompt(AgentExpert.none), isEmpty);
  });
}
