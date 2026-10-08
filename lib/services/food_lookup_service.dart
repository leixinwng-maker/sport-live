import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/diet.dart';

/// 食物条码联网查询（Open Food Facts，数据许可 ODbL）
///
/// 合规约束：
/// - 仅在用户于设置页开启「循证文献联网检索」后才会被调用（默认关闭，完全不联网）
/// - 只按「单个条码」查询单条商品，不做批量抓取 / 整体库再分发，符合 ODbL 条款
/// - 任一环节失败（超时 / 非 200 / 无该条码 / 解析异常）统一返回 null，
///   由调用方回落本地食物库并在结果中标注，绝不抛出异常打断智能体流程
class FoodLookupService {
  static const String _userAgent =
      'WenDao/1.2 (personal health assistant; local-only client)';
  static const Duration _timeout = Duration(seconds: 8);

  /// 条码格式校验：6~20 位纯数字
  static bool isBarcode(String value) =>
      RegExp(r'^\d{6,20}$').hasMatch(value.trim());

  /// 按条码查询单个食品的营养成分（统一换算为每 100g）
  ///
  /// [client] 仅测试注入用（可传 MockClient 做全 fake 无网络单测）
  static Future<FoodCatalog?> fetchByBarcode(
    String barcode, {
    http.Client? client,
  }) async {
    final code = barcode.trim();
    if (!isBarcode(code)) return null;

    final c = client ?? http.Client();
    try {
      final uri = Uri.parse(
        'https://world.openfoodfacts.org/api/v2/product/$code.json'
        '?fields=product_name,product_name_zh,generic_name_zh,nutriments,categories',
      );
      final resp =
          await c.get(uri, headers: {'User-Agent': _userAgent}).timeout(_timeout);
      if (resp.statusCode != 200) return null;

      final map = json.decode(resp.body);
      if (map is! Map) return null;
      // v2 接口：命中 status==1，未命中 status==0
      final status = map['status'];
      if (status != 1 && status != 'success') return null;

      final product = map['product'];
      if (product is! Map) return null;
      final n = product['nutriments'];
      if (n is! Map) return null;

      final name = (product['product_name_zh'] ??
              product['product_name'] ??
              product['generic_name_zh'] ??
              '')
          .toString()
          .trim();
      if (name.isEmpty) return null;

      double num100(String key) {
        final v = n[key];
        if (v is num) return v.toDouble();
        if (v is String) return double.tryParse(v) ?? 0;
        return 0;
      }

      return FoodCatalog(
        name: name,
        caloriesPer100g: num100('energy-kcal_100g'),
        proteinPer100g: num100('proteins_100g'),
        fatPer100g: num100('fat_100g'),
        carbsPer100g: num100('carbohydrates_100g'),
        category: '联网·OpenFoodFacts',
      );
    } catch (_) {
      return null;
    } finally {
      if (client == null) c.close();
    }
  }
}
