import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/health_metric.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';

/// 健康指标录入页
class HealthMetricEditScreen extends StatefulWidget {
  const HealthMetricEditScreen({super.key});

  @override
  State<HealthMetricEditScreen> createState() => _HealthMetricEditScreenState();
}

class _HealthMetricEditScreenState extends State<HealthMetricEditScreen> {
  String _type = HealthMetric.metricTypes.first;
  final _valueController = TextEditingController();
  final _noteController = TextEditingController();
  String _unit = '';
  DateTime _date = DateTime.now();

  @override
  void dispose() {
    _valueController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _selectType(String type) {
    setState(() {
      _type = type;
      _unit = HealthMetric.typeUnits[type] ?? '';
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(2000),
      lastDate: DateTime.now(),
    );
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final value = double.tryParse(_valueController.text);
    if (value == null || value <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的数值')),
      );
      return;
    }
    final metric = HealthMetric(
      date: _date,
      type: _type,
      value: value,
      unit: _unit.isEmpty ? null : _unit,
      note: _noteController.text.trim(),
    );
    final provider = context.read<AppProvider>();
    await provider.addHealthMetric(metric);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('健康指标已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('记录健康指标')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '指标类型',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: HealthMetric.metricTypes.map((type) {
              final selected = _type == type;
              return ChoiceChip(
                label: Text(type),
                selected: selected,
                onSelected: (_) => _selectType(type),
                selectedColor: TaoistTheme.jadeGreen,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : TaoistTheme.inkBlack,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          const Text(
            '数值',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _valueController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    hintText: '如 120.5',
                    prefixIcon: const Icon(Icons.pin_outlined),
                    suffixText: _unit,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          const Text(
            '测量日期',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: _pickDate,
            child: InputDecorator(
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.calendar_today_outlined),
              ),
              child: Text(
                '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}',
              ),
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            '备注',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
              hintText: '如：空腹/餐后、晨起/晚间',
              prefixIcon: Icon(Icons.notes),
            ),
          ),
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存记录'),
            ),
          ),
        ],
      ),
    );
  }
}
