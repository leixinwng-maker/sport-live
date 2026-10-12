import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/health_metric.dart';
import '../../providers/app_provider.dart';
import '../../services/body_composition_parser.dart';
import '../../theme/taoist_theme.dart';

/// 体测批量录入页
///
/// 一次录入一组体成分（同一日期 + 统一备注），支持两种方式：
/// 1. 手动逐项填写（体脂秤没有开放接口时的兜底路径，如乐刻门店体测）；
/// 2. 拍照识别秤屏自动回填 —— 优先视觉模型（要求输出结构化 JSON），
///    未配置或失败时降级本地 OCR（免费离线），解析失败则提示手动填写。
class BodyCompositionScreen extends StatefulWidget {
  const BodyCompositionScreen({super.key});

  @override
  State<BodyCompositionScreen> createState() => _BodyCompositionScreenState();
}

class _BodyCompositionScreenState extends State<BodyCompositionScreen> {
  DateTime _date = DateTime.now();
  final TextEditingController _noteController =
      TextEditingController(text: '乐刻门店体测');
  final Map<String, TextEditingController> _controllers = {
    for (final type in HealthMetric.bodyCompositionTypes)
      type: TextEditingController(),
  };

  String? _imagePath;
  String _recognizedText = '';
  bool _recognizing = false;
  bool _saving = false;
  String _error = '';

  @override
  void dispose() {
    _noteController.dispose();
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
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

  Future<void> _pickAndRecognize() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'webp'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    setState(() {
      _imagePath = path;
      _error = '';
      _recognizedText = '';
    });
    await _recognize();
  }

  /// 识别秤屏：优先视觉模型（结构化 JSON，直接回填），未配置或失败时降级本地 OCR
  Future<void> _recognize() async {
    final path = _imagePath;
    if (path == null) return;
    setState(() {
      _recognizing = true;
      _error = '';
    });
    final provider = context.read<AppProvider>();
    try {
      final bytes = await File(path).readAsBytes();
      String? raw;
      var usedVision = false;

      // 优先视觉模型（需在「AI服务配置」填写视觉模型，如 qwen-vl-plus）
      if (provider.hasVisionModel) {
        try {
          final visionText = await provider.recognizeImage(
            base64Encode(bytes),
            prompt: BodyCompositionParser.visionPrompt,
          );
          if (visionText != null && visionText.trim().isNotEmpty) {
            raw = visionText.trim();
            usedVision = true;
          }
        } catch (_) {
          // 视觉模型调用失败（网络/服务异常），降级本地 OCR
        }
      }

      // 未配置视觉模型，或识别失败/结果为空时，降级本地 OCR（免费离线）
      if (raw == null) {
        try {
          final ocrText = await provider.localOcrRecognize(bytes: bytes);
          if (ocrText.trim().isNotEmpty) raw = ocrText.trim();
        } catch (_) {
          // 当前平台不支持本地 OCR
        }
      }

      if (raw == null) {
        setState(() {
          _recognizing = false;
          _error = provider.hasVisionModel
              ? '未能识别出内容，请确认照片清晰（光线充足、秤屏文字端正），或手动填写下表'
              : '未配置视觉模型且本地 OCR 不可用。可到「AI服务配置」填写视觉模型（如 qwen-vl-plus）'
                  '以自动回填，或手动填写下表';
        });
        return;
      }

      // 视觉模型返回 JSON 直接回填；返回非 JSON（或走本地 OCR）时按纯文本兜底
      var filled = usedVision
          ? BodyCompositionParser.fromVisionJson(raw)
          : <String, double>{};
      if (filled.isEmpty) filled = BodyCompositionParser.fromPlainText(raw);

      for (final entry in filled.entries) {
        _controllers[entry.key]?.text = _format(entry.value);
      }
      final matched = filled.length;
      setState(() {
        _recognizedText = raw!;
        _recognizing = false;
        _error = matched == 0 ? '已识别文字，但未能自动匹配指标，请对照下方识别内容手动填写' : '';
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            matched == 0 ? '识别完成，请对照识别内容手动填写' : '识别完成，已回填 $matched 项，请校对后保存',
          ),
        ),
      );
    } catch (e) {
      setState(() {
        _recognizing = false;
        _error = '识别失败: $e';
      });
    }
  }

  String _format(double value) {
    if (value == value.roundToDouble()) return value.toInt().toString();
    return value.toString();
  }

  Future<void> _save() async {
    final note = _noteController.text.trim();
    final metrics = <HealthMetric>[];
    for (final type in HealthMetric.bodyCompositionTypes) {
      final text = _controllers[type]!.text.trim();
      if (text.isEmpty) continue;
      final value = double.tryParse(text);
      if (value == null || value <= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('「$type」数值无效，请检查后重试')),
        );
        return;
      }
      metrics.add(
        HealthMetric(
          date: _date,
          type: type,
          value: value,
          unit: HealthMetric.typeUnits[type],
          note: note,
        ),
      );
    }
    if (metrics.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请至少填写一项体测数据')),
      );
      return;
    }
    setState(() => _saving = true);
    await context.read<AppProvider>().addHealthMetrics(metrics);
    if (!mounted) return;
    Navigator.pop(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已保存 ${metrics.length} 项体测数据')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('体测批量录入')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Card(
            child: Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                '一次录入一组体测数据（同一日期、统一备注）。'
                '可手动填写，也可拍秤屏自动回填，识别结果仅供参考，请务必校对后保存。',
                style: TextStyle(
                  fontSize: 12,
                  color: TaoistTheme.cloudGray,
                  height: 1.6,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          _buildRecognizeCard(),
          const SizedBox(height: 16),
          const _FieldLabel('测量日期'),
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
          const _FieldLabel('统一备注'),
          const SizedBox(height: 8),
          TextField(
            controller: _noteController,
            decoration: const InputDecoration(
              hintText: '如：乐刻门店体测、晨起空腹',
              prefixIcon: Icon(Icons.notes),
            ),
          ),
          const SizedBox(height: 20),
          const _FieldLabel('体成分 / 围度数据（留空的项目不保存）'),
          const SizedBox(height: 8),
          ...HealthMetric.bodyCompositionTypes.map(_buildMetricRow),
          if (_error.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              _error,
              style: const TextStyle(fontSize: 12, color: Color(0xFFD9534F)),
            ),
          ],
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _saving ? null : _save,
              child: Text(_saving ? '保存中...' : '保存本组体测数据'),
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
              '说明：\n'
              '1. 识别优先使用视觉模型（需在「AI服务配置」填写视觉模型，如 qwen-vl-plus），未配置时降级本地 OCR（免费、离线）\n'
              '2. 体成分 / 围度数据保存在本机数据库，可在「健康指标」中查看长期趋势\n'
              '3. 结果仅供参考，不构成医疗诊断，异常指标请及时就医复查',
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

  Widget _buildRecognizeCard() {
    final path = _imagePath;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.photo_camera_outlined,
                    size: 18, color: TaoistTheme.jadeGreen),
                SizedBox(width: 8),
                Text(
                  '拍照识别秤屏',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _recognizing ? null : _pickAndRecognize,
                icon: _recognizing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_a_photo_outlined),
                label: Text(_recognizing ? '正在识别...' : '拍照 / 选择秤屏图片'),
              ),
            ),
            if (path != null) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.file(
                  File(path),
                  height: 160,
                  width: double.infinity,
                  fit: BoxFit.contain,
                  errorBuilder: (_, __, ___) => const Text('图片加载失败'),
                ),
              ),
            ],
            if (_recognizedText.isNotEmpty) ...[
              const SizedBox(height: 12),
              const Text(
                '识别内容（可对照校对）',
                style: TextStyle(fontSize: 12, color: TaoistTheme.teaBrown),
              ),
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                constraints: const BoxConstraints(maxHeight: 140),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  child: SelectableText(
                    _recognizedText,
                    style: const TextStyle(fontSize: 12, height: 1.6),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildMetricRow(String type) {
    final unit = HealthMetric.typeUnits[type] ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          SizedBox(
            width: 92,
            child: Text(
              type,
              style: const TextStyle(
                fontSize: 13,
                color: TaoistTheme.inkBlack,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: _controllers[type],
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                isDense: true,
                hintText: '请输入数值',
                suffixText: unit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: TaoistTheme.teaBrown,
      ),
    );
  }
}
