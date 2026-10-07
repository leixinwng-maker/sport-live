import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';

/// 体检报告添加页：选图/PDF → 本地OCR识别 → AI解读
class HealthReportAddScreen extends StatefulWidget {
  const HealthReportAddScreen({super.key});

  @override
  State<HealthReportAddScreen> createState() => _HealthReportAddScreenState();
}

class _HealthReportAddScreenState extends State<HealthReportAddScreen> {
  String? _filePath;
  String _fileType = 'image';
  String _title = '';
  String _ocrText = '';
  bool _recognizing = false;
  bool _analyzing = false;
  String? _aiSummary;
  String _lastError = '';
  final DateTime _date = DateTime.now();

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'pdf'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final ext = path.toLowerCase().split('.').last;
    setState(() {
      _filePath = path;
      _fileType = (ext == 'pdf') ? 'pdf' : 'image';
      _title = '${DateTime.now().year}年体检报告';
      _ocrText = '';
      _aiSummary = null;
      _lastError = '';
    });
  }

  /// 识别图片文字：优先视觉模型（识别更准），未配置或失败时降级本地 OCR
  Future<void> _recognize() async {
    if (_filePath == null) return;
    setState(() {
      _recognizing = true;
      _lastError = '';
    });
    try {
      final provider = context.read<AppProvider>();
      if (_fileType == 'pdf') {
        // PDF 无法按图片送视觉模型，提示手动录入
        setState(() {
          _recognizing = false;
          _lastError = 'PDF 报告暂不支持识别，请手动录入关键指标，或选择图片格式报告';
        });
        return;
      }
      final bytes = await File(_filePath!).readAsBytes();
      String? text;

      // 优先视觉模型（需在「AI服务配置」填写视觉模型，如 qwen-vl-plus）
      if (provider.hasVisionModel) {
        final b64 = base64Encode(bytes);
        try {
          final visionText = await provider.recognizeImage(b64);
          if (visionText != null && visionText.trim().isNotEmpty) {
            text = visionText;
          }
        } catch (_) {
          // 视觉模型调用失败（网络/服务异常），降级本地 OCR
        }
      }

      // 未配置视觉模型，或识别失败/结果为空时，降级本地 OCR（免费离线）
      if (text == null) {
        try {
          final ocrText = await provider.localOcrRecognize(bytes: bytes);
          if (ocrText.trim().isNotEmpty) text = ocrText;
        } catch (_) {
          // 当前平台不支持本地 OCR
        }
      }

      if (text == null || text.trim().isEmpty) {
        setState(() {
          _recognizing = false;
          _lastError = provider.hasVisionModel
              ? '未能识别出文字，请确认图片清晰（光线充足、文字端正），或手动录入'
              : '未配置视觉模型且本地OCR不可用。'
                  '可到「AI服务配置」填写视觉模型（如 qwen-vl-plus），或手动录入报告内容';
        });
        return;
      }
      final recognizedText = text.trim();
      setState(() {
        _ocrText = recognizedText;
        _recognizing = false;
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('识别完成，可查看/编辑识别内容')),
      );
    } catch (e) {
      setState(() {
        _recognizing = false;
        _lastError = '识别失败: $e';
      });
    }
  }

  Future<void> _analyze() async {
    final provider = context.read<AppProvider>();
    if (_ocrText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先识别图片文字或手动录入，再让AI解读')),
      );
      return;
    }
    setState(() {
      _analyzing = true;
      _lastError = '';
    });
    try {
      // 先临时保存报告，再让 AI 解读
      final report = HealthReport(
        date: _date,
        title: _title.isEmpty ? '${DateTime.now().year}年体检报告' : _title,
        filePath: _filePath ?? '',
        fileType: _fileType,
        ocrText: _ocrText,
        createdAt: DateTime.now(),
      );
      final summary = await provider.analyzeHealthReport(report);
      setState(() {
        _aiSummary = summary;
        _analyzing = false;
      });
    } catch (e) {
      setState(() {
        _analyzing = false;
        _lastError = 'AI解读失败: $e';
      });
    }
  }

  Future<void> _save() async {
    if (_filePath == null && _ocrText.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请先选择报告图片或录入文字')),
      );
      return;
    }
    final report = HealthReport(
      date: _date,
      title: _title.isEmpty ? '${DateTime.now().year}年体检报告' : _title,
      filePath: _filePath ?? '',
      fileType: _fileType,
      ocrText: _ocrText,
      aiSummary: _aiSummary ?? '',
      createdAt: DateTime.now(),
    );
    final provider = context.read<AppProvider>();
    await provider.addHealthReport(report);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('体检报告已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasImage = _filePath != null && _fileType == 'image';
    return Scaffold(
      appBar: AppBar(title: const Text('添加体检报告')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 选文件
          InkWell(
            onTap: _pickFile,
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 120,
              decoration: BoxDecoration(
                color: TaoistTheme.mistGray.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: TaoistTheme.jadeGreen.withValues(alpha: 0.5),
                ),
              ),
              child: _filePath == null
                  ? const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.add_photo_alternate_outlined,
                            size: 36, color: TaoistTheme.jadeGreen),
                        SizedBox(height: 8),
                        Text(
                          '选择体检报告图片（拍照/扫描件）',
                          style: TextStyle(
                            fontSize: 13,
                            color: TaoistTheme.cloudGray,
                          ),
                        ),
                      ],
                    )
                  : Center(
                      child: hasImage
                          ? Image.file(
                              File(_filePath!),
                              fit: BoxFit.contain,
                              errorBuilder: (_, __, ___) => const Text('图片加载失败'),
                            )
                          : const Text('已选择 PDF 报告'),
                    ),
            ),
          ),
          const SizedBox(height: 12),

          // 报告标题
          TextField(
            controller: TextEditingController(text: _title),
            onChanged: (v) => _title = v,
            decoration: const InputDecoration(
              labelText: '报告标题',
              hintText: '如：2026年健康体检报告',
              prefixIcon: Icon(Icons.description_outlined),
            ),
          ),
          const SizedBox(height: 12),

          // 本地识别按钮
          if (_fileType == 'image' && _filePath != null)
            SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _recognizing ? null : _recognize,
                icon: _recognizing
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.document_scanner_outlined),
                label: Text(_recognizing ? '正在本地识别...' : '本地识别图片文字（免费）'),
              ),
            ),
          const SizedBox(height: 12),

          // 识别结果编辑
          TextField(
            controller: TextEditingController(text: _ocrText),
            onChanged: (v) => _ocrText = v,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: '识别内容 / 手动录入',
              hintText: '在此查看识别出的体检项目文字，可直接编辑，或手动粘贴报告内容',
              alignLabelWithHint: true,
              border: OutlineInputBorder(),
            ),
          ),
          if (_lastError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _lastError,
              style: const TextStyle(fontSize: 12, color: Color(0xFFD9534F)),
            ),
          ],
          const SizedBox(height: 12),

          // AI 解读
          SizedBox(
            height: 44,
            child: ElevatedButton.icon(
              onPressed: _analyzing ? null : _analyze,
              icon: _analyzing
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome),
              label: Text(_analyzing ? 'AI 正在解读...' : 'AI 解读报告'),
            ),
          ),
          if (_aiSummary != null) ...[
            const SizedBox(height: 12),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: TaoistTheme.jadeGreen.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _aiSummary!,
                style: const TextStyle(fontSize: 13, height: 1.6),
              ),
            ),
          ],
          const SizedBox(height: 20),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存报告'),
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
              '说明：\n1. 图片识别使用本地算法（ML Kit / 系统OCR），免费、离线、不上传\n2. AI解读结果仅供参考，不构成医疗诊断，异常指标请及时就医复查',
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
