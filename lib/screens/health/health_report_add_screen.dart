import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import 'package:provider/provider.dart';

import '../../models/health_report.dart';
import '../../providers/app_provider.dart';
import '../../services/health/report_file_store.dart';
import '../../services/vision/vision_exceptions.dart';
import '../../theme/taoist_theme.dart';
import '../ai/ai_screen.dart';

/// 体检报告添加页：拍照/相册/文件 → 视觉识别（图片可本地OCR兜底）/ PDF 逐页识别 → AI解读
class HealthReportAddScreen extends StatefulWidget {
  const HealthReportAddScreen({super.key});

  @override
  State<HealthReportAddScreen> createState() => _HealthReportAddScreenState();
}

class _HealthReportAddScreenState extends State<HealthReportAddScreen> {
  final ImagePicker _picker = ImagePicker();

  String? _filePath;
  String _fileType = 'image';
  String _title = '';
  String _ocrText = '';
  bool _recognizing = false;
  bool _analyzing = false;
  String? _aiSummary;
  String _lastError = '';
  final DateTime _date = DateTime.now();

  /// 已复制进归档目录的文件路径（保存前是临时副本，未保存退出时清理）
  String? _archivedPath;
  bool _saved = false;

  /// PDF 页数（选中后异步读取，仅展示；读取失败不提示，识别时会报具体错误）
  int? _pdfPages;

  /// PDF 识别批次进度，如「2/5 批」
  String? _progressText;

  /// 远程视觉识别失败标记：显示「改用本地识别」入口（图片场景，移动端）
  bool _visionFailed = false;

  bool get _onMobile => Platform.isAndroid || Platform.isIOS;

  @override
  void dispose() {
    // 兜底：未保存离开页面时清理临时归档文件（保存成功后 _saved=true 不清理）
    if (!_saved) {
      ReportFileStore.instance.delete(_archivedPath);
    }
    super.dispose();
  }

  // ============ 选取文件 ============

  /// 拍照选取（仅移动端）
  Future<void> _pickFromCamera() async {
    try {
      final x = await _picker.pickImage(
        source: ImageSource.camera,
        imageQuality: 90,
      );
      if (x == null) return;
      await _onFilePicked(x.path, 'image');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('相机不可用：$e')),
      );
    }
  }

  /// 相册/文件选取（支持图片与 PDF）
  Future<void> _pickFromFiles() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['jpg', 'jpeg', 'png', 'bmp', 'pdf'],
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    final ext = path.toLowerCase().split('.').last;
    await _onFilePicked(path, ext == 'pdf' ? 'pdf' : 'image');
  }

  /// 统一处理选中文件：清理上一次临时归档 → 重置状态 → PDF 读页数
  Future<void> _onFilePicked(String path, String type) async {
    if (_archivedPath != null) {
      await ReportFileStore.instance.delete(_archivedPath);
    }
    setState(() {
      _filePath = path;
      _fileType = type;
      _title = '${DateTime.now().year}年体检报告';
      _ocrText = '';
      _aiSummary = null;
      _lastError = '';
      _archivedPath = null;
      _pdfPages = null;
      _progressText = null;
      _visionFailed = false;
    });
    if (type == 'pdf') {
      // 轻量打开读页数（仅元数据，不渲染页面）
      try {
        final doc = await pdfx.PdfDocument.openFile(path);
        final n = doc.pagesCount;
        await doc.close();
        if (mounted) setState(() => _pdfPages = n);
      } catch (_) {}
    }
  }

  /// 重选：清空当前选择并删除临时归档
  Future<void> _clearSelection() async {
    await ReportFileStore.instance.delete(_archivedPath);
    setState(() {
      _filePath = null;
      _fileType = 'image';
      _ocrText = '';
      _aiSummary = null;
      _lastError = '';
      _archivedPath = null;
      _pdfPages = null;
      _progressText = null;
      _visionFailed = false;
    });
  }

  // ============ 识别 ============

  /// 识别报告文字。
  /// 图片：独立视觉配置 → 旧通道 → 本地 OCR 三级链（VisionService 内部完成）；
  /// PDF：逐页渲染 → 视觉模型分批识别（本地 OCR 无法处理 PDF）。
  /// 已配置但调用失败不静默降级，分型异常直接展示原因。
  Future<void> _recognize() async {
    if (_filePath == null) return;
    final provider = context.read<AppProvider>();
    setState(() {
      _recognizing = true;
      _lastError = '';
      _progressText = null;
    });
    try {
      if (_fileType == 'pdf') {
        final text = await provider.recognizePdf(
          _filePath!,
          onProgress: (done, total) {
            if (!mounted) return;
            setState(() => _progressText = '$done/$total 批');
          },
        );
        _applyRecognized(text);
        return;
      }

      // 图片：走统一视觉链（无远程通道时内部自动落本地 OCR）
      final bytes = await File(_filePath!).readAsBytes();
      String? text;
      try {
        text = await provider.recognizeImage(base64Encode(bytes));
      } on VisionException {
        // 已配置但失败：不静默降级，提示原因并给出本地识别入口（移动端）
        if (mounted && _onMobile) setState(() => _visionFailed = true);
        rethrow;
      }
      _applyRecognized(text ?? '');
    } on VisionException catch (e) {
      setState(() {
        _recognizing = false;
        _lastError = e.message;
      });
    } catch (e) {
      setState(() {
        _recognizing = false;
        _lastError = '识别失败: $e';
      });
    }
  }

  /// 远程识别失败后，用户主动改用本地 OCR（免费离线，仅移动端图片）
  Future<void> _recognizeLocally() async {
    if (_filePath == null) return;
    final provider = context.read<AppProvider>();
    setState(() {
      _recognizing = true;
      _lastError = '';
    });
    try {
      final bytes = await File(_filePath!).readAsBytes();
      final text = await provider.localOcrRecognize(bytes: bytes);
      if (text.trim().isEmpty) {
        setState(() {
          _recognizing = false;
          _lastError = '未能识别出文字，请确认图片清晰（光线充足、文字端正），或手动录入';
        });
        return;
      }
      _applyRecognized(text);
    } catch (e) {
      setState(() {
        _recognizing = false;
        _lastError = '本地识别失败: $e';
      });
    }
  }

  void _applyRecognized(String text) {
    final t = text.trim();
    if (!mounted) return;
    if (t.isEmpty) {
      setState(() {
        _recognizing = false;
        _lastError = _fileType == 'pdf'
            ? 'PDF 识别结果为空，请确认文件内容清晰，或手动录入关键内容'
            : '未能识别出文字，请确认图片清晰（光线充足、文字端正），或手动录入';
      });
      return;
    }
    setState(() {
      _ocrText = t;
      _recognizing = false;
      _progressText = null;
      _visionFailed = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('识别完成，可查看/编辑识别内容')),
    );
  }

  // ============ AI 解读 / 保存 ============

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
      // 临时组装报告供 AI 解读（不落库）
      final report = HealthReport(
        date: _date,
        title: _title.isEmpty ? '${DateTime.now().year}年体检报告' : _title,
        filePath: _archivedPath ?? '',
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
    final provider = context.read<AppProvider>();
    // 文件归档：复制进应用文档目录，DB 存归档路径（避免系统清缓存丢文件）
    var archived = _archivedPath ?? '';
    if (_filePath != null) {
      try {
        archived = _archivedPath ??
            await ReportFileStore.instance.importToArchive(_filePath!);
        _archivedPath = archived;
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('文件归档失败：$e')),
          );
        }
        return;
      }
    }
    final report = HealthReport(
      date: _date,
      title: _title.isEmpty ? '${DateTime.now().year}年体检报告' : _title,
      filePath: archived,
      fileType: _fileType,
      ocrText: _ocrText,
      aiSummary: _aiSummary ?? '',
      createdAt: DateTime.now(),
    );
    _saved = true;
    await provider.addHealthReport(report);
    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('体检报告已保存')),
      );
    }
  }

  // ============ UI ============

  Widget _buildPickButtons() {
    return Row(
      children: [
        if (_onMobile) ...[
          Expanded(
            child: SizedBox(
              height: 44,
              child: OutlinedButton.icon(
                onPressed: _pickFromCamera,
                icon: const Icon(Icons.photo_camera_outlined, size: 20),
                label: const Text('拍照'),
              ),
            ),
          ),
          const SizedBox(width: 10),
        ],
        Expanded(
          child: SizedBox(
            height: 44,
            child: OutlinedButton.icon(
              onPressed: _pickFromFiles,
              icon: const Icon(Icons.folder_open, size: 20),
              label: const Text('相册 / 文件'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildPreview() {
    final hasImage = _filePath != null && _fileType == 'image';
    return Container(
      height: 140,
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TaoistTheme.jadeGreen.withValues(alpha: 0.5)),
      ),
      child: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: hasImage
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: Image.file(
                        File(_filePath!),
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) =>
                            const Center(child: Text('图片加载失败')),
                      ),
                    )
                  : Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.picture_as_pdf_outlined,
                              size: 36, color: TaoistTheme.jadeGreen),
                          const SizedBox(height: 6),
                          Text(
                            _pdfPages != null
                                ? '已选择 PDF 报告（共 $_pdfPages 页）'
                                : '已选择 PDF 报告',
                            style: const TextStyle(
                              fontSize: 13,
                              color: TaoistTheme.cloudGray,
                            ),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
          Positioned(
            top: 4,
            right: 4,
            child: InkWell(
              onTap: _clearSelection,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: const BoxDecoration(
                  color: Colors.black38,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close,
                    size: 16, color: Colors.white),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 识别按钮：按文件类型与可用通道切换（不允许静默失败）
  Widget _buildRecognizeButton(bool hasRemote) {
    // 无任何远程视觉通道时：
    // PDF（或桌面端图片，本地OCR不可用）→ 引导去配置识别服务
    final needConfig = !hasRemote && (_fileType == 'pdf' || !_onMobile);
    if (needConfig) {
      return SizedBox(
        height: 44,
        child: ElevatedButton.icon(
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AIConfigScreen()),
            );
          },
          icon: const Icon(Icons.settings_outlined, size: 20),
          label: Text(
            _fileType == 'pdf'
                ? '去配置识别服务（PDF 识别必需）'
                : '去配置识别服务（本机不支持本地识别）',
          ),
        ),
      );
    }

    // 图片 + 无远程通道 + 移动端：直接走本地 OCR（免费离线）
    if (!hasRemote) {
      return SizedBox(
        height: 44,
        child: OutlinedButton.icon(
          onPressed: _recognizing ? null : _recognizeLocally,
          icon: _recognizing
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.document_scanner_outlined),
          label: Text(_recognizing ? '正在本地识别...' : '本地识别图片文字（免费）'),
        ),
      );
    }

    final isPdf = _fileType == 'pdf';
    return SizedBox(
      height: 44,
      child: ElevatedButton.icon(
        onPressed: _recognizing ? null : _recognize,
        icon: _recognizing
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(isPdf ? Icons.menu_book_outlined : Icons.document_scanner_outlined),
        label: Text(
          _recognizing
              ? (isPdf
                  ? (_progressText == null ? '正在渲染 PDF...' : '识别中 $_progressText')
                  : '正在识别...')
              : (isPdf ? '识别 PDF（逐页）' : '识别图片文字'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final provider = context.watch<AppProvider>();
    final hasRemote = provider.hasVisionModel;
    return Scaffold(
      appBar: AppBar(title: const Text('添加体检报告')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildPickButtons(),
          if (_filePath != null) ...[
            const SizedBox(height: 12),
            _buildPreview(),
          ],
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

          // 识别按钮（按类型/通道切换）
          if (_filePath != null) _buildRecognizeButton(hasRemote),
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
          // 远程识别失败后的本地兜底入口（仅移动端图片）
          if (_visionFailed && _onMobile && _fileType == 'image') ...[
            const SizedBox(height: 4),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _recognizing ? null : _recognizeLocally,
                icon: const Icon(Icons.document_scanner_outlined, size: 18),
                label: const Text('改用本地识别（免费，不上传）'),
              ),
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
              '说明：\n'
              '1. 图片优先用识别服务（可在「AI服务配置」配置），移动端也可用本地OCR（免费、离线、不上传）\n'
              '2. PDF 报告会逐页渲染后交给识别服务识别（支持 20 页以内）\n'
              '3. 报告文件保存后会归档到应用目录，删除报告时同步删除文件\n'
              '4. AI解读结果仅供参考，不构成医疗诊断，异常指标请及时就医复查',
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
