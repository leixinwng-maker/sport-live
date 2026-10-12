import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_recognition_error.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../../models/diet.dart';
import '../../providers/app_provider.dart';
import '../../services/voice_diet_parser.dart';
import '../../theme/taoist_theme.dart';
import 'diet_list_screen.dart' show FoodCatalogScreen;

/// 语音记录的待确认结果：由本页返回给调用方合并进当前草稿
///
/// 沿用 FIT-2「待确认载荷」范式：本页不落库，用户确认后才交回调用方，
/// 由调用方（[DietEditScreen]）统一保存。
class VoiceDietDraft {
  /// 餐次：早餐 / 午餐 / 晚餐 / 加餐
  final String mealType;

  /// 已匹配食物库并换算好的条目
  final List<FoodItem> foods;

  const VoiceDietDraft({required this.mealType, required this.foods});
}

/// 语音快速记录饮食页
///
/// 流程：语音识别（或手动输入）→ [VoiceDietParser] 解析 → 匹配本地食物库
/// → 可编辑预览（餐次 / 克数 / 增删）→ 返回待确认结果。
///
/// 离线优先：解析与匹配全部本地完成，语音识别走系统能力，
/// 不可用时自动回落为文本输入，不阻断记录流程。
class VoiceDietScreen extends StatefulWidget {
  const VoiceDietScreen({super.key});

  @override
  State<VoiceDietScreen> createState() => _VoiceDietScreenState();
}

class _VoiceDietScreenState extends State<VoiceDietScreen> {
  final SpeechToText _speech = SpeechToText();
  final TextEditingController _textController = TextEditingController();

  bool _speechReady = false;
  bool _listening = false;
  String? _speechError;

  String _mealType = VoiceDietParser.defaultMealType(DateTime.now());
  bool _mealTouched = false;

  final List<_VoiceEntry> _entries = [];

  Timer? _debounce;
  int _parseToken = 0;
  bool _parsing = false;

  @override
  void initState() {
    super.initState();
    _initSpeech();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _textController.dispose();
    // 页面销毁务必停止拾音，避免麦克风常驻
    _speech.cancel();
    super.dispose();
  }

  // ============ 语音能力 ============

  Future<void> _initSpeech() async {
    try {
      final ok = await _speech.initialize(
        onStatus: _onSpeechStatus,
        onError: _onSpeechError,
      );
      if (!mounted) return;
      setState(() => _speechReady = ok);
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _speechReady = false;
        _speechError = '语音识别初始化失败，请改用下方文本输入';
      });
    }
  }

  void _onSpeechStatus(String status) {
    if (!mounted) return;
    if (status == SpeechToText.doneStatus ||
        status == SpeechToText.notListeningStatus) {
      setState(() => _listening = false);
    } else if (status == SpeechToText.listeningStatus) {
      setState(() => _listening = true);
    }
  }

  void _onSpeechError(SpeechRecognitionError error) {
    if (!mounted) return;
    setState(() {
      _listening = false;
      _speechError = '语音识别出错：${error.errorMsg}';
    });
  }

  Future<void> _toggleListening() async {
    if (_listening) {
      await _speech.stop();
      if (mounted) setState(() => _listening = false);
      return;
    }
    if (!_speechReady) return;

    setState(() {
      _listening = true;
      _speechError = null;
      _textController.clear();
      _entries.clear();
    });

    try {
      await _speech.listen(
        onResult: (result) {
          if (!mounted) return;
          _setText(result.recognizedWords);
        },
        listenOptions: SpeechListenOptions(
          localeId: 'zh-CN',
          partialResults: true,
          cancelOnError: true,
          listenMode: ListenMode.dictation,
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _listening = false;
        _speechError = '无法启动语音识别，请改用下方文本输入';
      });
    }
  }

  // ============ 文本 → 解析 → 匹配 ============

  /// 统一入口：语音结果与手动输入共用同一文本源
  void _setText(String text) {
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    _scheduleParse(text);
  }

  void _scheduleParse(String text) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _runParse(text));
  }

  Future<void> _runParse(String source) async {
    final token = ++_parseToken;
    final provider = Provider.of<AppProvider>(context, listen: false);

    final result = VoiceDietParser.parse(source);
    if (token != _parseToken || !mounted) return;

    if (result.isEmpty) {
      setState(() {
        _parsing = false;
        _entries.clear();
      });
      return;
    }

    setState(() => _parsing = true);

    final entries = <_VoiceEntry>[];
    for (final item in result.items) {
      final candidates = await provider.searchFoodCatalog(item.name, limit: 8);
      if (token != _parseToken || !mounted) return;
      final match = _bestMatch(candidates, item.name);
      entries.add(_VoiceEntry(
        rawName: item.name,
        unit: item.unit,
        grams: item.grams,
        catalog: match,
        include: match != null,
      ));
    }

    if (token != _parseToken || !mounted) return;
    setState(() {
      _parsing = false;
      if (!_mealTouched) _mealType = result.mealType;
      _entries
        ..clear()
        ..addAll(entries);
    });
  }

  /// 在候选集中挑最贴近的一个：精确 > 去括号同名 > 互相包含 > 首个
  FoodCatalog? _bestMatch(List<FoodCatalog> candidates, String query) {
    if (candidates.isEmpty) return null;
    for (final c in candidates) {
      if (c.name == query) return c;
    }
    final q = _stripParen(query);
    for (final c in candidates) {
      if (_stripParen(c.name) == q) return c;
    }
    for (final c in candidates) {
      final cn = _stripParen(c.name);
      if (cn.contains(q) || q.contains(cn)) return c;
    }
    return candidates.first;
  }

  /// 去掉名称中的括号补充，如「牛奶(全脂)」→「牛奶」
  static String _stripParen(String s) =>
      s.replaceAll(RegExp(r'[（(][^（()）]*[)）]'), '').trim();

  // ============ 结果操作 ============

  Future<void> _pickCatalog(int index) async {
    final selected = await Navigator.push<FoodCatalog>(
      context,
      MaterialPageRoute(builder: (_) => const FoodCatalogScreen()),
    );
    if (selected != null && mounted) {
      setState(() {
        _entries[index].catalog = selected;
        _entries[index].include = true;
      });
    }
  }

  void _submit() {
    final foods = <FoodItem>[];
    for (final e in _entries) {
      if (!e.include) continue;
      final f = e.toFoodItem();
      if (f != null) foods.add(f);
    }
    if (foods.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('没有可添加的食物，请先说话识别或从食物库选择')),
      );
      return;
    }
    Navigator.pop(context, VoiceDietDraft(mealType: _mealType, foods: foods));
  }

  int get _includedCount => _entries.where((e) => e.include && e.matched).length;

  // ============ UI ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('语音记录饮食')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildMicCard(),
          const SizedBox(height: 16),
          _buildTextCard(),
          const SizedBox(height: 16),
          _buildMealSelector(),
          const SizedBox(height: 16),
          Row(
            children: [
              const Text(
                '识别结果',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const Spacer(),
              if (_parsing)
                const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          const SizedBox(height: 8),
          if (_entries.isEmpty)
            _buildResultEmpty()
          else
            ..._entries.asMap().entries.map((entry) => _VoiceEntryTile(
                  key: ValueKey(entry.value.id),
                  entry: entry.value,
                  onToggle: (v) => setState(() => entry.value.include = v),
                  onGramsChanged: (g) =>
                      setState(() => entry.value.grams = g),
                  onPick: () => _pickCatalog(entry.key),
                  onRemove: () => setState(() => _entries.removeAt(entry.key)),
                )),
          const SizedBox(height: 24),
          SizedBox(
            height: 48,
            child: ElevatedButton.icon(
              onPressed: _includedCount == 0 ? null : _submit,
              icon: const Icon(Icons.playlist_add_check, size: 20),
              label: Text('添加到记录（$_includedCount 项）'),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _buildMicCard() {
    final canTap = _speechReady;
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TaoistTheme.mistGray),
      ),
      child: Column(
        children: [
          GestureDetector(
            onTap: canTap ? _toggleListening : null,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _listening
                    ? const Color(0xFFE57373).withValues(alpha: 0.15)
                    : TaoistTheme.jadeGreen.withValues(alpha: 0.12),
                border: Border.all(
                  color: _listening
                      ? const Color(0xFFE57373)
                      : TaoistTheme.jadeGreen,
                  width: 2,
                ),
              ),
              child: Icon(
                _listening ? Icons.mic : Icons.mic_none,
                size: 36,
                color: _listening
                    ? const Color(0xFFE57373)
                    : TaoistTheme.jadeGreen,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _listening
                ? '正在聆听…点击结束'
                : (_speechReady ? '点击开始说话' : '本设备语音识别不可用'),
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.inkBlack,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _speechReady
                ? '例如：早餐两个鸡蛋一杯牛奶'
                : '请在下方直接输入，例如：早餐两个鸡蛋一杯牛奶',
            style: const TextStyle(
              fontSize: 12,
              color: TaoistTheme.cloudGray,
            ),
            textAlign: TextAlign.center,
          ),
          if (_speechError != null) ...[
            const SizedBox(height: 10),
            Text(
              _speechError!,
              style: const TextStyle(
                fontSize: 12,
                color: Color(0xFFE57373),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildTextCard() {
    return TextField(
      controller: _textController,
      maxLines: 3,
      minLines: 1,
      onChanged: _scheduleParse,
      decoration: const InputDecoration(
        labelText: '识别文本（可手动修改后自动重新解析）',
        hintText: '早餐两个鸡蛋一杯牛奶',
        prefixIcon: Icon(Icons.edit_note),
        alignLabelWithHint: true,
      ),
    );
  }

  Widget _buildMealSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          '餐次',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: TaoistTheme.inkBlack,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          children: VoiceDietParser.mealTypes.map((t) {
            return ChoiceChip(
              label: Text(t),
              selected: _mealType == t,
              onSelected: (v) {
                if (v) {
                  setState(() {
                    _mealType = t;
                    _mealTouched = true;
                  });
                }
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildResultEmpty() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: TaoistTheme.mistGray.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: TaoistTheme.mistGray),
      ),
      child: const Column(
        children: [
          Icon(Icons.record_voice_over, color: TaoistTheme.cloudGray, size: 32),
          SizedBox(height: 8),
          Text(
            '还没有识别到食物\n说出或输入「早餐两个鸡蛋一杯牛奶」试试',
            style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

/// 单条待确认条目
class _VoiceEntry {
  static int _seq = 0;

  final int id = ++_seq;

  /// 口语原文
  final String rawName;

  /// 量词（仅用于展示，换算已并入 [grams]）
  final String unit;

  double grams;

  /// 命中本地食物库的条目；null 表示未匹配
  FoodCatalog? catalog;

  /// 是否纳入本次记录
  bool include;

  _VoiceEntry({
    required this.rawName,
    required this.unit,
    required this.grams,
    this.catalog,
    this.include = true,
  });

  bool get matched => catalog != null;

  /// 换算为绝对营养值的 [FoodItem]（食物库为每 100g 基准）
  FoodItem? toFoodItem() {
    final c = catalog;
    if (c == null) return null;
    final ratio = grams / 100;
    return FoodItem(
      name: c.name,
      grams: grams,
      calories: c.caloriesPer100g * ratio,
      protein: c.proteinPer100g * ratio,
      fat: c.fatPer100g * ratio,
      carbs: c.carbsPer100g * ratio,
    );
  }
}

class _VoiceEntryTile extends StatefulWidget {
  final _VoiceEntry entry;
  final ValueChanged<bool> onToggle;
  final ValueChanged<double> onGramsChanged;
  final VoidCallback onPick;
  final VoidCallback onRemove;

  const _VoiceEntryTile({
    super.key,
    required this.entry,
    required this.onToggle,
    required this.onGramsChanged,
    required this.onPick,
    required this.onRemove,
  });

  @override
  State<_VoiceEntryTile> createState() => _VoiceEntryTileState();
}

class _VoiceEntryTileState extends State<_VoiceEntryTile> {
  late final TextEditingController _gramsController;

  @override
  void initState() {
    super.initState();
    _gramsController = TextEditingController(
      text: widget.entry.grams.toStringAsFixed(0),
    );
  }

  @override
  void dispose() {
    _gramsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.entry;
    final title = e.catalog?.name ?? e.rawName;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 8, 6),
        child: Row(
          children: [
            Checkbox(
              value: e.include,
              onChanged: e.matched ? (v) => widget.onToggle(v ?? false) : null,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: TaoistTheme.inkBlack,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (!e.matched) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: const Color(0xFFE57373).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '未匹配',
                            style: TextStyle(
                              fontSize: 10,
                              color: Color(0xFFE57373),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  Text(
                    e.matched
                        ? '${e.catalog!.caloriesPer100g.toStringAsFixed(0)}千卡/100g · 识别「${e.rawName}」'
                        : '食物库中未找到，请手动选择',
                    style: const TextStyle(
                      fontSize: 11,
                      color: TaoistTheme.cloudGray,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 62,
              child: TextField(
                controller: _gramsController,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.right,
                decoration: const InputDecoration(
                  isDense: true,
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 6, vertical: 10),
                  suffixText: 'g',
                ),
                onChanged: (v) {
                  final g = double.tryParse(v);
                  if (g != null && g > 0) widget.onGramsChanged(g);
                },
              ),
            ),
            if (!e.matched)
              IconButton(
                onPressed: widget.onPick,
                icon: const Icon(Icons.search, size: 20),
                color: TaoistTheme.jadeGreen,
                tooltip: '从食物库选择',
              ),
            IconButton(
              onPressed: widget.onRemove,
              icon: const Icon(Icons.close, size: 20),
              color: TaoistTheme.cloudGray,
              tooltip: '移除',
            ),
          ],
        ),
      ),
    );
  }
}
