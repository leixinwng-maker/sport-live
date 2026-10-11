import 'package:flutter/material.dart';

import '../../models/health_data_extraction.dart';

/// 灯色 UI 工具（P7-T4）：颜色 / 语义 / 排序权重 / 最差聚合 / 圆点组件。
/// 颜色映射独立于模型层，模型只存字符串编码。
class HealthLightUI {
  HealthLightUI._();

  static const Color red = Color(0xFFD9534F);
  static const Color yellow = Color(0xFFF0AD4E);
  static const Color blue = Color(0xFF4A90D9);
  static const Color green = Color(0xFF5CB85C);
  static const Color unknown = Color(0xFF9E9E9E);

  static Color colorOf(RiskLight light) => switch (light) {
        RiskLight.red => red,
        RiskLight.yellow => yellow,
        RiskLight.blue => blue,
        RiskLight.green => green,
        RiskLight.unknown => unknown,
      };

  static String semanticOf(RiskLight light) => switch (light) {
        RiskLight.red => '需尽快就医复查',
        RiskLight.yellow => '建议定期复查',
        RiskLight.blue => '需持续关注',
        RiskLight.green => '指标正常',
        RiskLight.unknown => '未评级',
      };

  /// 排序权重：red 0 > yellow 1 > blue 2 > green 3 > unknown 4
  static int weightOf(RiskLight light) => switch (light) {
        RiskLight.red => 0,
        RiskLight.yellow => 1,
        RiskLight.blue => 2,
        RiskLight.green => 3,
        RiskLight.unknown => 4,
      };

  /// 聚合取最差灯色；全部未评级时返回 unknown
  static RiskLight worst(Iterable<RiskLight> lights) {
    var worst = RiskLight.unknown;
    for (final l in lights) {
      if (weightOf(l) < weightOf(worst)) worst = l;
    }
    return worst;
  }

  /// 圆点 + 可选文字标签（10 号字）
  static Widget dot(RiskLight light, {double size = 8, String? label}) {
    final dot = Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: colorOf(light),
        shape: BoxShape.circle,
      ),
    );
    final text = label ?? light.label;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dot,
        const SizedBox(width: 3),
        Text(
          text,
          style: TextStyle(fontSize: 10, color: colorOf(light)),
        ),
      ],
    );
  }
}
