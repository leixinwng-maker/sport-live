import '../models/diet.dart';

/// 内置常见食物营养数据（每100g）
class FoodCatalogData {
  static const List<FoodCatalog> foods = [
    // ========== 主食类 ==========
    FoodCatalog(name: '米饭', caloriesPer100g: 116, proteinPer100g: 2.6, fatPer100g: 0.3, carbsPer100g: 25.9, category: '主食'),
    FoodCatalog(name: '糙米饭', caloriesPer100g: 111, proteinPer100g: 2.6, fatPer100g: 0.9, carbsPer100g: 23, category: '主食'),
    FoodCatalog(name: '馒头', caloriesPer100g: 223, proteinPer100g: 7, fatPer100g: 1.1, carbsPer100g: 47, category: '主食'),
    FoodCatalog(name: '全麦面包', caloriesPer100g: 246, proteinPer100g: 8.5, fatPer100g: 3.4, carbsPer100g: 41, category: '主食'),
    FoodCatalog(name: '白面包', caloriesPer100g: 265, proteinPer100g: 8.9, fatPer100g: 3.2, carbsPer100g: 49, category: '主食'),
    FoodCatalog(name: '燕麦片', caloriesPer100g: 367, proteinPer100g: 15, fatPer100g: 6.7, carbsPer100g: 61, category: '主食'),
    FoodCatalog(name: '面条(熟)', caloriesPer100g: 109, proteinPer100g: 3.6, fatPer100g: 0.4, carbsPer100g: 22, category: '主食'),
    FoodCatalog(name: '玉米', caloriesPer100g: 112, proteinPer100g: 4, fatPer100g: 1.2, carbsPer100g: 22.8, category: '主食'),
    FoodCatalog(name: '红薯', caloriesPer100g: 102, proteinPer100g: 1.1, fatPer100g: 0.2, carbsPer100g: 24, category: '主食'),
    FoodCatalog(name: '土豆', caloriesPer100g: 77, proteinPer100g: 2, fatPer100g: 0.2, carbsPer100g: 17.5, category: '主食'),
    FoodCatalog(name: '山药', caloriesPer100g: 57, proteinPer100g: 1.9, fatPer100g: 0.2, carbsPer100g: 12.4, category: '主食'),

    // ========== 蛋白质类 ==========
    FoodCatalog(name: '鸡胸肉', caloriesPer100g: 133, proteinPer100g: 31, fatPer100g: 1.4, carbsPer100g: 0, category: '蛋白质'),
    FoodCatalog(name: '鸡腿肉', caloriesPer100g: 181, proteinPer100g: 16, fatPer100g: 13, carbsPer100g: 0, category: '蛋白质'),
    FoodCatalog(name: '鸡蛋白', caloriesPer100g: 52, proteinPer100g: 11, fatPer100g: 0.2, carbsPer100g: 0.7, category: '蛋白质'),
    FoodCatalog(name: '鸡蛋', caloriesPer100g: 155, proteinPer100g: 13, fatPer100g: 11, carbsPer100g: 1.1, category: '蛋白质'),
    FoodCatalog(name: '牛肉(瘦)', caloriesPer100g: 106, proteinPer100g: 20, fatPer100g: 2.3, carbsPer100g: 1.2, category: '蛋白质'),
    FoodCatalog(name: '猪肉(瘦)', caloriesPer100g: 143, proteinPer100g: 20, fatPer100g: 6, carbsPer100g: 1.5, category: '蛋白质'),
    FoodCatalog(name: '三文鱼', caloriesPer100g: 208, proteinPer100g: 20, fatPer100g: 13, carbsPer100g: 0, category: '蛋白质'),
    FoodCatalog(name: '金枪鱼(罐头)', caloriesPer100g: 116, proteinPer100g: 26, fatPer100g: 1, carbsPer100g: 0, category: '蛋白质'),
    FoodCatalog(name: '虾仁', caloriesPer100g: 99, proteinPer100g: 24, fatPer100g: 0.3, carbsPer100g: 0.2, category: '蛋白质'),
    FoodCatalog(name: '豆腐', caloriesPer100g: 82, proteinPer100g: 8.1, fatPer100g: 4.8, carbsPer100g: 4.2, category: '蛋白质'),
    FoodCatalog(name: '豆干', caloriesPer100g: 197, proteinPer100g: 14.5, fatPer100g: 13.8, carbsPer100g: 5.7, category: '蛋白质'),
    FoodCatalog(name: '牛奶(全脂)', caloriesPer100g: 66, proteinPer100g: 3.2, fatPer100g: 3.6, carbsPer100g: 4.8, category: '蛋白质'),
    FoodCatalog(name: '牛奶(脱脂)', caloriesPer100g: 35, proteinPer100g: 3.4, fatPer100g: 0.1, carbsPer100g: 5, category: '蛋白质'),
    FoodCatalog(name: '酸奶(无糖)', caloriesPer100g: 63, proteinPer100g: 3.5, fatPer100g: 3.3, carbsPer100g: 4.7, category: '蛋白质'),
    FoodCatalog(name: '乳清蛋白粉', caloriesPer100g: 380, proteinPer100g: 80, fatPer100g: 5, carbsPer100g: 8, category: '蛋白质'),
    FoodCatalog(name: '豆浆', caloriesPer100g: 31, proteinPer100g: 3, fatPer100g: 1.6, carbsPer100g: 1.2, category: '蛋白质'),

    // ========== 蔬菜类 ==========
    FoodCatalog(name: '西兰花', caloriesPer100g: 36, proteinPer100g: 4.1, fatPer100g: 0.6, carbsPer100g: 4.3, category: '蔬菜'),
    FoodCatalog(name: '菠菜', caloriesPer100g: 28, proteinPer100g: 2.6, fatPer100g: 0.3, carbsPer100g: 4.5, category: '蔬菜'),
    FoodCatalog(name: '生菜', caloriesPer100g: 13, proteinPer100g: 1.3, fatPer100g: 0.2, carbsPer100g: 2, category: '蔬菜'),
    FoodCatalog(name: '番茄', caloriesPer100g: 20, proteinPer100g: 0.9, fatPer100g: 0.2, carbsPer100g: 4, category: '蔬菜'),
    FoodCatalog(name: '黄瓜', caloriesPer100g: 16, proteinPer100g: 0.7, fatPer100g: 0.1, carbsPer100g: 2.9, category: '蔬菜'),
    FoodCatalog(name: '胡萝卜', caloriesPer100g: 41, proteinPer100g: 0.9, fatPer100g: 0.2, carbsPer100g: 9.6, category: '蔬菜'),
    FoodCatalog(name: '白菜', caloriesPer100g: 17, proteinPer100g: 1.5, fatPer100g: 0.2, carbsPer100g: 3.2, category: '蔬菜'),
    FoodCatalog(name: '芹菜', caloriesPer100g: 16, proteinPer100g: 0.7, fatPer100g: 0.2, carbsPer100g: 3.3, category: '蔬菜'),
    FoodCatalog(name: '青椒', caloriesPer100g: 22, proteinPer100g: 1, fatPer100g: 0.2, carbsPer100g: 4.6, category: '蔬菜'),
    FoodCatalog(name: '蘑菇', caloriesPer100g: 24, proteinPer100g: 2.7, fatPer100g: 0.3, carbsPer100g: 4, category: '蔬菜'),
    FoodCatalog(name: '木耳(干)', caloriesPer100g: 265, proteinPer100g: 12, fatPer100g: 1.5, carbsPer100g: 65, category: '蔬菜'),
    FoodCatalog(name: '海带', caloriesPer100g: 13, proteinPer100g: 1.2, fatPer100g: 0.1, carbsPer100g: 2.1, category: '蔬菜'),

    // ========== 水果类 ==========
    FoodCatalog(name: '苹果', caloriesPer100g: 52, proteinPer100g: 0.3, fatPer100g: 0.2, carbsPer100g: 13.8, category: '水果'),
    FoodCatalog(name: '香蕉', caloriesPer100g: 93, proteinPer100g: 1.4, fatPer100g: 0.2, carbsPer100g: 22, category: '水果'),
    FoodCatalog(name: '橙子', caloriesPer100g: 48, proteinPer100g: 0.9, fatPer100g: 0.2, carbsPer100g: 11.8, category: '水果'),
    FoodCatalog(name: '蓝莓', caloriesPer100g: 57, proteinPer100g: 0.7, fatPer100g: 0.3, carbsPer100g: 14.5, category: '水果'),
    FoodCatalog(name: '草莓', caloriesPer100g: 32, proteinPer100g: 0.7, fatPer100g: 0.3, carbsPer100g: 7.7, category: '水果'),
    FoodCatalog(name: '猕猴桃', caloriesPer100g: 61, proteinPer100g: 1.1, fatPer100g: 0.5, carbsPer100g: 14.7, category: '水果'),
    FoodCatalog(name: '葡萄', caloriesPer100g: 69, proteinPer100g: 0.7, fatPer100g: 0.2, carbsPer100g: 18.1, category: '水果'),
    FoodCatalog(name: '西瓜', caloriesPer100g: 30, proteinPer100g: 0.6, fatPer100g: 0.2, carbsPer100g: 7.5, category: '水果'),
    FoodCatalog(name: '牛油果', caloriesPer100g: 161, proteinPer100g: 2, fatPer100g: 15, carbsPer100g: 8.5, category: '水果'),
    FoodCatalog(name: '火龙果', caloriesPer100g: 55, proteinPer100g: 1.1, fatPer100g: 0.2, carbsPer100g: 13.3, category: '水果'),

    // ========== 坚果类 ==========
    FoodCatalog(name: '核桃', caloriesPer100g: 646, proteinPer100g: 15, fatPer100g: 65, carbsPer100g: 14, category: '坚果'),
    FoodCatalog(name: '杏仁', caloriesPer100g: 579, proteinPer100g: 21, fatPer100g: 50, carbsPer100g: 22, category: '坚果'),
    FoodCatalog(name: '花生', caloriesPer100g: 574, proteinPer100g: 24, fatPer100g: 44, carbsPer100g: 21, category: '坚果'),
    FoodCatalog(name: '腰果', caloriesPer100g: 559, proteinPer100g: 18, fatPer100g: 44, carbsPer100g: 30, category: '坚果'),
    FoodCatalog(name: '黑芝麻', caloriesPer100g: 559, proteinPer100g: 19, fatPer100g: 46, carbsPer100g: 24, category: '坚果'),

    // ========== 零食/饮品 ==========
    FoodCatalog(name: '黑咖啡', caloriesPer100g: 1, proteinPer100g: 0.1, fatPer100g: 0, carbsPer100g: 0, category: '饮品'),
    FoodCatalog(name: '绿茶', caloriesPer100g: 1, proteinPer100g: 0, fatPer100g: 0, carbsPer100g: 0.2, category: '饮品'),
    FoodCatalog(name: '可乐', caloriesPer100g: 43, proteinPer100g: 0, fatPer100g: 0, carbsPer100g: 10.6, category: '饮品'),
    FoodCatalog(name: '奶茶', caloriesPer100g: 65, proteinPer100g: 0.8, fatPer100g: 2.5, carbsPer100g: 9.8, category: '饮品'),
    FoodCatalog(name: '啤酒', caloriesPer100g: 43, proteinPer100g: 0.5, fatPer100g: 0, carbsPer100g: 3.6, category: '饮品'),
    FoodCatalog(name: '巧克力', caloriesPer100g: 589, proteinPer100g: 7, fatPer100g: 35, carbsPer100g: 59, category: '零食'),
    FoodCatalog(name: '薯片', caloriesPer100g: 548, proteinPer100g: 7, fatPer100g: 37, carbsPer100g: 49, category: '零食'),
    FoodCatalog(name: '蛋糕', caloriesPer100g: 347, proteinPer100g: 5.5, fatPer100g: 14, carbsPer100g: 51, category: '零食'),
    FoodCatalog(name: '坚果棒', caloriesPer100g: 480, proteinPer100g: 15, fatPer100g: 25, carbsPer100g: 50, category: '零食'),
  ];
}
