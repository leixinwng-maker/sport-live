import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/health_profile.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';

/// 健康档案基础信息编辑页
class HealthProfileEditScreen extends StatefulWidget {
  const HealthProfileEditScreen({super.key});

  @override
  State<HealthProfileEditScreen> createState() => _HealthProfileEditScreenState();
}

class _HealthProfileEditScreenState extends State<HealthProfileEditScreen> {
  final _bloodTypeController = TextEditingController();
  final _chronicController = TextEditingController();
  final _allergyController = TextEditingController();
  final _familyController = TextEditingController();
  final _medicationController = TextEditingController();
  final _surgeryController = TextEditingController();
  final _noteController = TextEditingController();

  String _bloodType = '';

  @override
  void initState() {
    super.initState();
    final p = context.read<AppProvider>().healthProfile;
    if (p != null) {
      _bloodType = p.bloodType;
      _bloodTypeController.text = p.bloodType;
      _chronicController.text = p.chronicDiseases;
      _allergyController.text = p.allergies;
      _familyController.text = p.familyHistory;
      _medicationController.text = p.medications;
      _surgeryController.text = p.surgeries;
      _noteController.text = p.specialNotes;
    }
  }

  @override
  void dispose() {
    _bloodTypeController.dispose();
    _chronicController.dispose();
    _allergyController.dispose();
    _familyController.dispose();
    _medicationController.dispose();
    _surgeryController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final existing = context.read<AppProvider>().healthProfile;
    final profile = HealthProfile(
      id: existing?.id,
      bloodType: _bloodType,
      chronicDiseases: _chronicController.text.trim(),
      allergies: _allergyController.text.trim(),
      familyHistory: _familyController.text.trim(),
      medications: _medicationController.text.trim(),
      surgeries: _surgeryController.text.trim(),
      specialNotes: _noteController.text.trim(),
    );
    final provider = context.read<AppProvider>();
    await provider.saveHealthProfile(profile);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('健康档案已保存')),
      );
    }
  }

  Widget _field({
    required String label,
    TextEditingController? controller,
    int maxLines = 2,
    String hint = '',
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: TaoistTheme.teaBrown,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hint,
            alignLabelWithHint: true,
          ),
        ),
        const SizedBox(height: 16),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('健康档案')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '血型',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: ['A', 'B', 'AB', 'O', '未知'].map((type) {
              final selected = _bloodType == type;
              return ChoiceChip(
                label: Text(type),
                selected: selected,
                onSelected: (_) => setState(() => _bloodType = type),
                selectedColor: TaoistTheme.jadeGreen,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : TaoistTheme.inkBlack,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          _field(
            label: '慢性病史',
            controller: _chronicController,
            hint: '如：高血压、糖尿病、脂肪肝等（无则留空）',
          ),
          _field(
            label: '过敏史',
            controller: _allergyController,
            hint: '如：青霉素过敏、花粉过敏等',
          ),
          _field(
            label: '家族病史',
            controller: _familyController,
            hint: '如：父母有高血压、糖尿病等',
          ),
          _field(
            label: '用药情况',
            controller: _medicationController,
            hint: '如：长期服用降压药等',
          ),
          _field(
            label: '手术史',
            controller: _surgeryController,
            hint: '如：2020年阑尾炎手术',
          ),
          _field(
            label: '其他注意事项',
            controller: _noteController,
            maxLines: 3,
            hint: '如：膝盖旧伤、椎间盘突出、运动禁忌等，AI 会据此调整训练',
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存档案'),
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: TaoistTheme.mistGray.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '提示：档案信息会同步给 AI，用于调整训练强度、动作选择和饮食方案。例如膝盖旧伤时会避免深蹲跳跃类动作。',
              style: TextStyle(
                fontSize: 12,
                color: TaoistTheme.cloudGray,
                height: 1.6,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
