import 'dart:convert';
import 'package:csv/csv.dart';

/// 导入的单条账单记录
class ImportedRecord {
  final DateTime date;
  final String merchant; // 交易对方
  final String description; // 商品/备注
  final String type; // income / expense
  final double amount;
  String category;

  ImportedRecord({
    required this.date,
    required this.merchant,
    required this.description,
    required this.type,
    required this.amount,
    required this.category,
  });

  ImportedRecord copyWith({String? category}) {
    return ImportedRecord(
      date: date,
      merchant: merchant,
      description: description,
      type: type,
      amount: amount,
      category: category ?? this.category,
    );
  }
}

/// 账单来源
enum BillSource { wechat, alipay }

/// 账单导入服务 - 解析微信/支付宝导出的CSV账单
class BillImportService {
  /// 识别账单来源
  static BillSource? detectSource(String content) {
    if (content.contains('微信支付账单明细') || content.contains('微信昵称')) {
      return BillSource.wechat;
    }
    if (content.contains('支付宝交易记录明细')) {
      return BillSource.alipay;
    }
    return null;
  }

  /// 解析CSV文本为行数据
  static List<List<String>> _parseCsv(String content) {
    final csv = Csv();
    final rows = csv.decode(content);
    return rows
        .map((row) => row.map((e) => e.toString()).toList())
        .toList();
  }

  /// 解析微信账单
  static List<ImportedRecord> parseWechat(String content) {
    final rows = _parseCsv(content);
    final records = <ImportedRecord>[];

    for (final row in rows) {
      if (row.length < 11) continue;

      final time = row[0].trim();
      // 跳过非交易行（表头、元数据）
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(time)) continue;

      final typeText = row[4].trim(); // 收/支
      if (typeText != '收入' && typeText != '支出') continue;

      final merchant = row[2].trim();
      final description = row[3].trim();
      final amountStr = row[5].trim().replaceAll('¥', '').replaceAll(',', '');

      final amount = double.tryParse(amountStr);
      if (amount == null) continue;

      final date = DateTime.tryParse(time.replaceFirst(' ', 'T'));
      if (date == null) continue;

      records.add(ImportedRecord(
        date: date,
        merchant: merchant,
        description: description,
        type: typeText == '支出' ? 'expense' : 'income',
        amount: amount,
        category: _categorize(merchant, description),
      ));
    }

    return records;
  }

  /// 解析支付宝账单
  static List<ImportedRecord> parseAlipay(String content) {
    final rows = _parseCsv(content);
    final records = <ImportedRecord>[];

    for (final row in rows) {
      // 支付宝表头行：交易号,商家订单号,交易创建时间,...,类型,交易对方,商品名称,金额（元）,收/支,交易状态,...
      if (row.length < 10) continue;
      if (row[0].contains('交易号')) continue;

      final time = row[2].trim(); // 交易创建时间
      if (!RegExp(r'^\d{4}-\d{2}-\d{2}').hasMatch(time)) continue;

      final typeText = row[10].trim(); // 收/支
      if (typeText != '支出' && typeText != '收入') continue;

      final merchant = row[7].trim(); // 交易对方
      final description = row[8].trim(); // 商品名称
      final amountStr = row[9].trim().replaceAll(',', '');
      // 支付宝的支出金额可能带负号或正数
      final amount = double.tryParse(amountStr.replaceAll('-', '')) ?? 0;

      final date = DateTime.tryParse(time.replaceFirst(' ', 'T'));
      if (date == null) continue;

      records.add(ImportedRecord(
        date: date,
        merchant: merchant,
        description: description,
        type: typeText == '支出' ? 'expense' : 'income',
        amount: amount,
        category: _categorize(merchant, description),
      ));
    }

    return records;
  }

  /// 主解析入口
  static List<ImportedRecord> parse(String content, BillSource source) {
    switch (source) {
      case BillSource.wechat:
        return parseWechat(content);
      case BillSource.alipay:
        return parseAlipay(content);
    }
  }

  /// 根据交易对方/商品名自动分类
  static String _categorize(String merchant, String description) {
    final text = '$merchant$description';

    const categories = {
      '饮食': ['餐', '食', '外卖', '美团', '饿了么', '餐厅', '早餐', '午餐', '晚餐', '咖啡',
          '奶茶', '茶饮', '零食', '水果', '买菜', '生鲜', '便利店', '超市'],
      '训练': ['健身', '健身房', '蛋白', '运动', '瑜伽', '游泳', '跑步', '体育'],
      '交通': ['地铁', '公交', '滴滴', '打车', '出租车', '铁路', '机票', '加油',
          '充电', '停车', '共享单车'],
      '生活': ['水电', '燃气', '物业', '话费', '网费', '宽带', '房租', '日用品',
          '理发', '洗衣'],
      '娱乐': ['电影', '游戏', '音乐', '视频', 'KTV', '演出', '旅游'],
      '学习': ['书店', '课程', '考试', '培训', '教育', '图书', '文具'],
      '医疗': ['药', '医院', '诊所', '体检', '口腔', '挂号'],
      '购物': ['淘宝', '京东', '拼多多', '商城', '旗舰店', '唯品会', '天猫'],
    };

    for (final entry in categories.entries) {
      for (final keyword in entry.value) {
        if (text.contains(keyword)) {
          return entry.key;
        }
      }
    }
    return '其他';
  }

  /// 预览解析结果（转JSON供调试/展示）
  static String recordsToJson(List<ImportedRecord> records) {
    return jsonEncode(records.map((r) => {
          'date': r.date.toIso8601String(),
          'merchant': r.merchant,
          'description': r.description,
          'type': r.type,
          'amount': r.amount,
          'category': r.category,
        }).toList());
  }
}
