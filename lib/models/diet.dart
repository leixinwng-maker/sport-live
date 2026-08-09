import 'dart:convert';

class DietRecord {
  final int? id;
  final DateTime date;
  final String mealType;
  final List<FoodItem> foods;
  final double totalCalories;

  DietRecord({
    this.id,
    required this.date,
    required this.mealType,
    required this.foods,
    required this.totalCalories,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'date': date.toIso8601String(),
      'meal_type': mealType,
      'total_calories': totalCalories,
      'foods': jsonEncode(foods.map((f) => f.toMap()).toList()),
    };
  }

  factory DietRecord.fromMap(Map<String, dynamic> map) {
    final foodsJson = map['foods'] as String?;
    List<FoodItem> foods;
    if (foodsJson != null && foodsJson.isNotEmpty) {
      foods = (jsonDecode(foodsJson) as List)
          .map((f) => FoodItem.fromMap(f as Map<String, dynamic>))
          .toList();
    } else {
      foods = [];
    }
    return DietRecord(
      id: map['id'],
      date: DateTime.parse(map['date']),
      mealType: map['meal_type'],
      totalCalories: map['total_calories'],
      foods: foods,
    );
  }

  DietRecord copyWith({
    int? id,
    DateTime? date,
    String? mealType,
    List<FoodItem>? foods,
    double? totalCalories,
  }) {
    return DietRecord(
      id: id ?? this.id,
      date: date ?? this.date,
      mealType: mealType ?? this.mealType,
      foods: foods ?? this.foods,
      totalCalories: totalCalories ?? this.totalCalories,
    );
  }
}

class FoodItem {
  final String name;
  final double grams;
  final double calories;
  final double protein;
  final double fat;
  final double carbs;

  FoodItem({
    required this.name,
    required this.grams,
    required this.calories,
    required this.protein,
    required this.fat,
    required this.carbs,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'grams': grams,
      'calories': calories,
      'protein': protein,
      'fat': fat,
      'carbs': carbs,
    };
  }

  factory FoodItem.fromMap(Map<String, dynamic> map) {
    return FoodItem(
      name: map['name'],
      grams: map['grams'],
      calories: map['calories'],
      protein: map['protein'],
      fat: map['fat'],
      carbs: map['carbs'],
    );
  }

  FoodItem copyWith({
    String? name,
    double? grams,
    double? calories,
    double? protein,
    double? fat,
    double? carbs,
  }) {
    return FoodItem(
      name: name ?? this.name,
      grams: grams ?? this.grams,
      calories: calories ?? this.calories,
      protein: protein ?? this.protein,
      fat: fat ?? this.fat,
      carbs: carbs ?? this.carbs,
    );
  }
}

class FoodCatalog {
  final String name;
  final double caloriesPer100g;
  final double proteinPer100g;
  final double fatPer100g;
  final double carbsPer100g;
  final String category;

  const FoodCatalog({
    required this.name,
    required this.caloriesPer100g,
    required this.proteinPer100g,
    required this.fatPer100g,
    required this.carbsPer100g,
    required this.category,
  });

  Map<String, dynamic> toMap() {
    return {
      'name': name,
      'caloriesPer100g': caloriesPer100g,
      'proteinPer100g': proteinPer100g,
      'fatPer100g': fatPer100g,
      'carbsPer100g': carbsPer100g,
      'category': category,
    };
  }

  factory FoodCatalog.fromMap(Map<String, dynamic> map) {
    return FoodCatalog(
      name: map['name'],
      caloriesPer100g: map['caloriesPer100g'],
      proteinPer100g: map['proteinPer100g'],
      fatPer100g: map['fatPer100g'],
      carbsPer100g: map['carbsPer100g'],
      category: map['category'],
    );
  }
}
