import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../models/evidence.dart';
import '../../providers/app_provider.dart';
import '../../services/dataset_service.dart';
import '../../theme/taoist_theme.dart';

/// P6-D 开放数据与本体浏览页（本地离线只读，不写库）
///
/// 四个分区：
/// 1. 本体术语 —— EXMO 运动医学本体 + RehabO 康复本体（上游英文原文，未翻译）
/// 2. 数据源登记表 —— 开放数据/知识图谱/本体/食品数据库/开源软件（仅元数据）
/// 3. 开放动作库 —— Exercises Dataset（含中文说明）+ Free Exercise DB（按需懒加载）
/// 4. 精选数据集 —— 登记表「已接入」条目中许可已核实的小体量文件按需下载到本机，
///    以及 HuggingFace 数据集目录检索（仅拉取元数据，不做批量抓取）
///
/// 前三个分区完全不联网；第四分区仅在用户主动检索/下载时联网。
class OpenDataScreen extends StatefulWidget {
  const OpenDataScreen({super.key});

  @override
  State<OpenDataScreen> createState() => _OpenDataScreenState();
}

class _OpenDataScreenState extends State<OpenDataScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  static const _tabLabels = ['本体术语', '数据源登记表', '开放动作库', '精选数据集'];

  // 本体术语
  String _ontoQuery = '';
  String? _ontoFilter; // null = 全部

  // 数据源登记表
  String? _kindFilter; // null = 全部

  // 开放动作库
  bool _catalogReady = false;
  bool _catalogLoading = false;
  String? _bodyPart;
  String? _equipment;
  String _catalogQuery = '';
  bool _zhOnly = false;
  List<CatalogExercise> _catalogHits = const [];
  List<String> _bodyParts = const [];
  List<String> _equipments = const [];

  // 精选数据集
  final DatasetService _datasetService = DatasetService();
  Map<String, DatasetDownloadRecord> _records =
      <String, DatasetDownloadRecord>{}; // 子集id → 下载记录
  final Map<String, _SubsetUiState> _subsetStates = {}; // 子集id → 下载中状态
  String _hfQuery = '';
  bool _hfSearching = false;
  String? _hfDetailLoadingId; // 正在加载详情的数据集 id
  String? _hfError;
  List<HFDatasetSummary> _hfHits = const [];

  /// 列表展示上限，避免一次性构建上千个 item
  static const int _listCap = 300;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: _tabLabels.length, vsync: this);
    _tab.addListener(() {
      if (_tab.index == 2) _loadCatalog();
      if (_tab.index == 3) _loadRecords();
    });
    _loadRecords(); // 进入页面即读取本机下载记录（不联网）
  }

  @override
  void dispose() {
    _tab.dispose();
    _datasetService.close();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // 开放动作库：按需加载（约 2 MB，独立资产，不随启动加载）
  // ---------------------------------------------------------------------------
  Future<void> _loadCatalog() async {
    if (_catalogReady || _catalogLoading) return;
    _catalogLoading = true;
    final p = Provider.of<AppProvider>(context, listen: false);
    await p.ensureExerciseCatalogLoaded();
    final bp = await p.exerciseCatalogBodyParts();
    final eq = await p.exerciseCatalogEquipment();
    if (!mounted) return;
    setState(() {
      _bodyParts = bp;
      _equipments = eq;
      _catalogReady = true;
      _catalogLoading = false;
    });
    _refreshCatalog();
  }

  void _refreshCatalog() {
    if (!mounted) return;
    final all = Provider.of<AppProvider>(context, listen: false).exerciseCatalog;
    final kw = _catalogQuery.trim().toLowerCase();
    final out = <CatalogExercise>[];
    for (final x in all) {
      if (_zhOnly && x.lang != 'zh') continue;
      if (_bodyPart != null && !x.bodyPart.contains(_bodyPart!)) continue;
      if (_equipment != null && !x.equipment.contains(_equipment!)) continue;
      if (kw.isNotEmpty && !x.searchText.toLowerCase().contains(kw)) continue;
      out.add(x);
      if (out.length >= _listCap) break;
    }
    setState(() => _catalogHits = out);
  }

  // ---------------------------------------------------------------------------
  // build
  // ---------------------------------------------------------------------------
  @override
  Widget build(BuildContext context) {
    final p = Provider.of<AppProvider>(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('开放数据与本体'),
        bottom: TabBar(
          controller: _tab,
          labelColor: TaoistTheme.jadeGreen,
          unselectedLabelColor: TaoistTheme.cloudGray,
          indicatorColor: TaoistTheme.jadeGreen,
          tabs: [for (final t in _tabLabels) Tab(text: t)],
        ),
      ),
      body: TabBarView(
        controller: _tab,
        children: [
          _buildOntologyTab(p),
          _buildRegistryTab(p),
          _buildCatalogTab(p),
          _buildDatasetsTab(p),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 1：本体术语
  // ---------------------------------------------------------------------------
  Widget _buildOntologyTab(AppProvider p) {
    final counts = p.ontologyCounts;
    final q = _ontoQuery.trim();
    final List<OntologyTerm> terms;
    if (q.isEmpty && _ontoFilter == null) {
      terms = p.ontologyTerms.take(_listCap).toList();
    } else {
      terms = p.searchOntology(_ontoQuery, ontology: _ontoFilter, topN: _listCap);
    }

    return Column(
      children: [
        _banner(
          'EXMO（运动医学本体）与 RehabO（康复本体）术语，'
          '均为上游英文原文与定义、未翻译改写；用于对齐专业概念，'
          '不构成医疗建议',
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: '检索术语（建议英文），如 exercise、rehabilitation',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _ontoQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _ontoQuery = ''),
                    ),
            ),
            onChanged: (v) => setState(() => _ontoQuery = v),
          ),
        ),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _chip(
                label: '全部（${counts.values.fold<int>(0, (s, v) => s + v)}）',
                selected: _ontoFilter == null,
                onTap: () => setState(() => _ontoFilter = null),
              ),
              for (final e in counts.entries)
                _chip(
                  label: '${e.key}（${e.value}）',
                  selected: _ontoFilter == e.key,
                  onTap: () => setState(() => _ontoFilter = e.key),
                ),
            ],
          ),
        ),
        _hitCount('共 ${terms.length} 条'
            '${terms.length >= _listCap ? '（仅显示前 $_listCap 条）' : ''}'),
        Expanded(
          child: terms.isEmpty
              ? _empty('未找到匹配术语，可改用英文关键词')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: terms.length,
                  itemBuilder: (_, i) => _termCard(terms[i]),
                ),
        ),
      ],
    );
  }

  Widget _termCard(OntologyTerm t) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(t.label, [
          _kv('术语 ID', t.id),
          _kv('归属本体', t.ontology),
          if (t.altLabels.isNotEmpty) _kv('同义词', t.altLabels.join('；')),
          if (t.parents.isNotEmpty) _kv('上级术语', t.parents.join('；')),
          if (t.definition.isNotEmpty) _kv('定义', t.definition),
        ]),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _badge(t.ontology, TaoistTheme.jadeGreen),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.label,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                t.id,
                style: const TextStyle(
                  fontSize: 10,
                  color: TaoistTheme.cloudGray,
                ),
              ),
              if (t.definition.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  t.definition,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.72),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 2：数据源登记表
  // ---------------------------------------------------------------------------
  Widget _buildRegistryTab(AppProvider p) {
    final counts = p.datasetRegistryCounts;
    final rows = _kindFilter == null
        ? p.datasetRegistry
        : p.searchDatasetRegistry(kind: _kindFilter, topN: 100);

    return Column(
      children: [
        _banner('仅登记元数据，不含任何正文数据。'
            '「已接入 / 可接入」为本地可直接使用；'
            '「登记题录」仅为线索条目，尚未入库'),
        SizedBox(
          height: 36,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              _chip(
                label: '全部（${rowsTotal(counts)}）',
                selected: _kindFilter == null,
                onTap: () => setState(() => _kindFilter = null),
              ),
              for (final e in counts.entries)
                _chip(
                  label: '${e.key}（${e.value}）',
                  selected: _kindFilter == e.key,
                  onTap: () => setState(() => _kindFilter = e.key),
                ),
            ],
          ),
        ),
        _hitCount('共 ${rows.length} 条'),
        Expanded(
          child: rows.isEmpty
              ? _empty('暂无该类型条目')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  itemCount: rows.length,
                  itemBuilder: (_, i) => _registryCard(rows[i]),
                ),
        ),
      ],
    );
  }

  int rowsTotal(Map<String, int> counts) =>
      counts.values.fold<int>(0, (s, v) => s + v);

  Widget _registryCard(DatasetRegistryEntry r) {
    final usable = r.isUsable;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(r.name, [
          _kv('类型', r.kind),
          _kv('接入状态', r.access),
          if (r.nameEn.isNotEmpty) _kv('英文名', r.nameEn),
          if (r.domain.isNotEmpty) _kv('领域', r.domain),
          if (r.scale.isNotEmpty) _kv('规模', r.scale),
          if (r.license.isNotEmpty) _kv('许可协议', r.license),
          if (r.url.isNotEmpty) _kv('主页', r.url),
          if (r.dataUrl.isNotEmpty) _kv('数据地址', r.dataUrl),
          if (r.note.isNotEmpty) _kv('说明', r.note),
        ]),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _badge(r.kind, TaoistTheme.bambooGreen),
                  const SizedBox(width: 6),
                  _badge(
                    r.access,
                    usable ? TaoistTheme.jadeGreen : TaoistTheme.cloudGray,
                  ),
                  const Spacer(),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                r.name,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              if (r.scale.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  r.scale,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 11,
                    color: TaoistTheme.teaBrown,
                  ),
                ),
              ],
              if (r.note.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  r.note,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.5,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.72),
                  ),
                ),
              ],
              const SizedBox(height: 6),
              Text(
                r.license.isEmpty ? '许可：未注明' : '许可：${r.license}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 10,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 3：开放动作库
  // ---------------------------------------------------------------------------
  Widget _buildCatalogTab(AppProvider p) {
    if (!_catalogReady) {
      // TabBarView 可能直接构建本页，兜底触发一次懒加载
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadCatalog());
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 12),
              Text(
                '正在加载开放动作库…',
                style: TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      children: [
        _banner('Exercises Dataset（含中文步骤）+ Free Exercise DB，'
            '共 ${p.exerciseCatalog.length} 条；仅公开许可的名称与说明文本，'
            '不含任何图片/视频资源'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            decoration: InputDecoration(
              isDense: true,
              hintText: '检索动作（中英文均可）',
              prefixIcon: const Icon(Icons.search, size: 18),
              suffixIcon: _catalogQuery.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear, size: 18),
                      onPressed: () => setState(() => _catalogQuery = ''),
                    ),
            ),
            onChanged: (v) {
              setState(() => _catalogQuery = v);
              _refreshCatalog();
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              Expanded(
                child: _dropdown(
                  hint: '身体部位',
                  value: _bodyPart,
                  items: _bodyParts,
                  onChanged: (v) {
                    setState(() => _bodyPart = v);
                    _refreshCatalog();
                  },
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: _dropdown(
                  hint: '器械',
                  value: _equipment,
                  items: _equipments,
                  onChanged: (v) {
                    setState(() => _equipment = v);
                    _refreshCatalog();
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Row(
            children: [
              const Text(
                '仅看含中文说明',
                style: TextStyle(fontSize: 12, color: TaoistTheme.teaBrown),
              ),
              Switch(
                value: _zhOnly,
                activeThumbColor: TaoistTheme.jadeGreen,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                onChanged: (v) {
                  setState(() => _zhOnly = v);
                  _refreshCatalog();
                },
              ),
              const Spacer(),
              Text(
                '共 ${_catalogHits.length} 条'
                '${_catalogHits.length >= _listCap ? '（仅前 $_listCap 条）' : ''}',
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _catalogHits.isEmpty
              ? _empty('未找到匹配动作，可放宽部位/器械条件或换关键词')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                  itemCount: _catalogHits.length,
                  itemBuilder: (_, i) => _catalogCard(_catalogHits[i]),
                ),
        ),
      ],
    );
  }

  Widget _catalogCard(CatalogExercise x) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => _showDetail(x.displayName, [
          if (x.name.isNotEmpty && x.nameZh.isNotEmpty) _kv('英文名', x.name),
          if (x.bodyPart.isNotEmpty) _kv('身体部位', x.bodyPart),
          if (x.target.isNotEmpty) _kv('目标肌群', x.target),
          if (x.secondary.isNotEmpty) _kv('协同肌群', x.secondary.join('、')),
          if (x.equipment.isNotEmpty) _kv('器械', x.equipment),
          if (x.level.isNotEmpty) _kv('难度', x.level),
          if (x.steps.isNotEmpty) _kv('步骤说明', x.steps),
          _kv('来源', '${x.source}${x.lang == 'zh' ? '（中文）' : '（英文）'}'),
          if (x.license.isNotEmpty) _kv('许可', x.license),
        ]),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                x.displayName,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                  color: TaoistTheme.inkBlack,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                [
                  if (x.bodyPart.isNotEmpty) x.bodyPart,
                  if (x.equipment.isNotEmpty) x.equipment,
                  if (x.level.isNotEmpty) x.level,
                ].join(' · '),
                style: const TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.teaBrown,
                ),
              ),
              if (x.target.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  '目标：${x.target}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: TaoistTheme.inkBlack.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Tab 4：精选数据集（按需联网：许可已核实的小文件下载 + 目录元数据检索）
  // ---------------------------------------------------------------------------
  Widget _buildDatasetsTab(AppProvider p) {
    final regById = {for (final r in p.datasetRegistry) r.id: r};
    return Column(
      children: [
        _banner('精选子集均来自登记表「已接入」条目的公开直链'
            '（CC BY 4.0 / CC0 / MIT），仅下载小体量文件到本机；'
            '目录检索仅拉取元数据，不做批量抓取、不再分发远端数据'),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            children: [
              _sectionHeader('精选子集（可下载）'),
              for (final s in DatasetService.curatedSubsets)
                _subsetCard(s, regById[s.registryId]),
              const SizedBox(height: 12),
              _sectionHeader('数据集目录检索（HuggingFace，仅元数据）'),
              _hfSearchField(),
              if (_hfSearching)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                )
              else if (_hfError != null)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _hfError!,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                )
              else if (_hfHits.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    _hfQuery.trim().isEmpty
                        ? '输入英文关键词检索 HuggingFace 上的开放数据集，'
                            '或直接使用上方精选子集'
                        : '未找到匹配数据集，可换关键词重试',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        fontSize: 12, color: TaoistTheme.cloudGray),
                  ),
                )
              else
                for (final d in _hfHits) _hfCard(d),
            ],
          ),
        ),
      ],
    );
  }

  Widget _sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: Text(
          text,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: TaoistTheme.inkBlack,
          ),
        ),
      );

  Widget _hfSearchField() {
    return TextField(
      decoration: InputDecoration(
        isDense: true,
        hintText: '英文关键词检索 HuggingFace 数据集，如 fitness',
        prefixIcon: const Icon(Icons.search, size: 18),
        suffixIcon: IconButton(
          icon: const Icon(Icons.arrow_forward, size: 18),
          onPressed: _hfSearching ? null : _searchHf,
        ),
      ),
      textInputAction: TextInputAction.search,
      onSubmitted: (_) => _searchHf(),
      onChanged: (v) => setState(() => _hfQuery = v),
    );
  }

  Widget _subsetCard(CuratedDataset s, DatasetRegistryEntry? reg) {
    final record = _records[s.id];
    final st = _subsetStates[s.id];
    final downloading = st?.downloading ?? false;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    s.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.bold,
                      color: TaoistTheme.inkBlack,
                    ),
                  ),
                ),
                _badge(s.license, TaoistTheme.jadeGreen),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              s.description,
              style: TextStyle(
                fontSize: 12,
                height: 1.5,
                color: TaoistTheme.inkBlack.withValues(alpha: 0.72),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              [
                if (reg != null) '登记条目：${reg.name}（${reg.access}）',
                '来源：${s.sourceName}',
                '文件：${s.fileName}',
              ].join(' · '),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  fontSize: 10, color: TaoistTheme.cloudGray),
            ),
            if (record != null) ...[
              const SizedBox(height: 6),
              Text(
                '已下载 · ${DatasetService.formatBytes(record.fileSizeBytes)}'
                ' · ${_formatTime(record.downloadedAt)}',
                style: const TextStyle(
                    fontSize: 11, color: TaoistTheme.teaBrown),
              ),
            ],
            if (downloading && st != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(
                value: (st.total != null && st.total! > 0)
                    ? st.received / st.total!
                    : null,
                backgroundColor: TaoistTheme.cloudGray.withValues(alpha: 0.2),
                valueColor: const AlwaysStoppedAnimation<Color>(
                    TaoistTheme.jadeGreen),
              ),
              const SizedBox(height: 4),
              Text(
                '下载中 ${DatasetService.formatBytes(st.received)}'
                '${st.total != null ? ' / ${DatasetService.formatBytes(st.total!)}' : ''}',
                style: const TextStyle(
                    fontSize: 11, color: TaoistTheme.cloudGray),
              ),
            ],
            if (st?.error != null) ...[
              const SizedBox(height: 6),
              Text(
                st!.error!,
                style: TextStyle(
                  fontSize: 11,
                  color: Theme.of(context).colorScheme.error,
                ),
              ),
            ],
            const SizedBox(height: 4),
            Row(
              children: [
                if (!downloading)
                  TextButton.icon(
                    onPressed: () => _downloadSubset(s),
                    icon: Icon(
                      record == null ? Icons.download : Icons.refresh,
                      size: 16,
                    ),
                    label: Text(record == null ? '下载' : '重新下载'),
                    style: TextButton.styleFrom(
                      foregroundColor: TaoistTheme.jadeGreen,
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                if (!downloading && record != null) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => _deleteSubset(s),
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('删除'),
                    style: TextButton.styleFrom(
                      foregroundColor: TaoistTheme.cloudGray,
                      textStyle: const TextStyle(fontSize: 12),
                      visualDensity: VisualDensity.compact,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _hfCard(HFDatasetSummary d) {
    final loadingDetail = _hfDetailLoadingId == d.id;
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: loadingDetail ? null : () => _showHfDetail(d),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      d.id,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                  if (loadingDetail)
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                '下载 ${d.downloads} · 点赞 ${d.likes}'
                '${d.lastModified.isNotEmpty ? ' · 更新于 ${_shortDate(d.lastModified)}' : ''}',
                style: const TextStyle(
                    fontSize: 11, color: TaoistTheme.teaBrown),
              ),
              if (d.tags.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  d.tags.take(5).join(' · '),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      fontSize: 10, color: TaoistTheme.cloudGray),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// 读取本机下载记录（不联网）
  Future<void> _loadRecords() async {
    final records = await _datasetService.loadRecords();
    if (!mounted) return;
    setState(() {
      _records = {for (final r in records) r.subsetId: r};
    });
  }

  Future<void> _downloadSubset(CuratedDataset s) async {
    setState(() {
      final st = _subsetStates.putIfAbsent(s.id, _SubsetUiState.new);
      st
        ..downloading = true
        ..error = null
        ..received = 0
        ..total = null;
    });
    try {
      final record = await _datasetService.downloadSubset(
        s,
        onProgress: (received, total) {
          if (!mounted) return;
          final st = _subsetStates[s.id];
          if (st == null) return;
          setState(() {
            st
              ..received = received
              ..total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _subsetStates[s.id]?.downloading = false;
        _records[s.id] = record;
      });
    } on DatasetException catch (e) {
      if (!mounted) return;
      setState(() {
        final st = _subsetStates[s.id];
        if (st != null) {
          st
            ..downloading = false
            ..error = e.message;
        }
      });
    }
  }

  Future<void> _deleteSubset(CuratedDataset s) async {
    // 先捕获 messenger 再 await，规避 use_build_context_synchronously
    final messenger = ScaffoldMessenger.of(context);
    await _datasetService.deleteDownload(s.id);
    if (!mounted) return;
    setState(() {
      _records.remove(s.id);
      _subsetStates.remove(s.id);
    });
    messenger.showSnackBar(SnackBar(content: Text('已删除「${s.name}」')));
  }

  Future<void> _searchHf() async {
    final q = _hfQuery.trim();
    if (q.isEmpty || _hfSearching) return;
    setState(() {
      _hfSearching = true;
      _hfError = null;
      _hfHits = const [];
    });
    try {
      final hits =
          await _datasetService.searchHuggingFaceDatasets(q, limit: 10);
      if (!mounted) return;
      setState(() {
        _hfHits = hits;
        _hfSearching = false;
      });
    } on DatasetException catch (e) {
      if (!mounted) return;
      setState(() {
        _hfError = e.message;
        _hfSearching = false;
      });
    }
  }

  Future<void> _showHfDetail(HFDatasetSummary d) async {
    setState(() => _hfDetailLoadingId = d.id);
    try {
      final detail = await _datasetService.fetchHuggingFaceDatasetDetail(d.id);
      if (!mounted) return;
      _showDetail(d.id, [
        _kv('作者', detail.author.isEmpty ? '未知' : detail.author),
        _kv('下载数', '${detail.summary.downloads}'),
        _kv('点赞数', '${detail.summary.likes}'),
        if (detail.summary.lastModified.isNotEmpty)
          _kv('最后更新', detail.summary.lastModified),
        if (detail.description.isNotEmpty) _kv('简介', detail.description),
        _kv(
          '文件清单（${detail.files.length} 个）',
          detail.files.isEmpty ? '（无）' : detail.files.join('\n'),
        ),
        _kv('提示', '仅展示元数据；本项目不批量抓取、不再分发该数据集内容'),
      ]);
    } on DatasetException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _hfDetailLoadingId = null);
    }
  }

  String _formatTime(String iso) {
    final t = DateTime.tryParse(iso);
    if (t == null) return iso;
    String two(int n) => n.toString().padLeft(2, '0');
    return '${t.year}-${two(t.month)}-${two(t.day)} '
        '${two(t.hour)}:${two(t.minute)}';
  }

  String _shortDate(String iso) =>
      iso.length >= 10 ? iso.substring(0, 10) : iso;

  // ---------------------------------------------------------------------------
  // 通用小组件
  // ---------------------------------------------------------------------------
  Widget _banner(String text) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: TaoistTheme.jadeGreen.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          color: TaoistTheme.teaBrown,
          height: 1.5,
        ),
      ),
    );
  }

  Widget _hitCount(String text) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            text,
            style: const TextStyle(fontSize: 11, color: TaoistTheme.cloudGray),
          ),
        ),
      );

  Widget _empty(String text) => Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: TaoistTheme.cloudGray),
        ),
      );

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          text,
          style: TextStyle(fontSize: 10, color: color),
        ),
      );

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label, style: const TextStyle(fontSize: 11)),
        selected: selected,
        onSelected: (_) => onTap(),
        visualDensity: VisualDensity.compact,
        selectedColor: TaoistTheme.jadeGreen.withValues(alpha: 0.15),
        labelStyle: TextStyle(
          fontSize: 11,
          color: selected ? TaoistTheme.jadeGreen : TaoistTheme.cloudGray,
        ),
      ),
    );
  }

  Widget _dropdown({
    required String hint,
    required String? value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isDense: true,
      decoration: InputDecoration(
        isDense: true,
        hintText: hint,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      ),
      style: const TextStyle(fontSize: 12, color: TaoistTheme.inkBlack),
      items: [
        DropdownMenuItem<String>(
          value: null,
          child: Text('全部$hint', style: const TextStyle(fontSize: 12)),
        ),
        for (final it in items)
          DropdownMenuItem<String>(
            value: it,
            child: Text(it,
                style: const TextStyle(fontSize: 12),
                overflow: TextOverflow.ellipsis),
          ),
      ],
      onChanged: onChanged,
    );
  }

  Widget _kv(String k, String v) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            k,
            style: const TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.bold,
              color: TaoistTheme.jadeGreen,
            ),
          ),
          const SizedBox(height: 2),
          SelectableText(
            v,
            style: TextStyle(
              fontSize: 13,
              height: 1.6,
              color: TaoistTheme.inkBlack.withValues(alpha: 0.85),
            ),
          ),
        ],
      ),
    );
  }

  void _showDetail(String title, List<Widget> rows) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: TaoistTheme.paperWhite,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 20,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 20,
        ),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: TaoistTheme.inkBlack,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 18),
                    onPressed: () => Navigator.pop(ctx),
                  ),
                ],
              ),
              const Divider(height: 20),
              ...rows,
            ],
          ),
        ),
      ),
    );
  }
}

/// 精选子集下载的临时 UI 状态（仅存内存，不持久化）
class _SubsetUiState {
  bool downloading = false;
  int received = 0;
  int? total;
  String? error;
}
