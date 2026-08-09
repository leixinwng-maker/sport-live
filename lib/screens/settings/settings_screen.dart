import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/user_profile.dart';
import '../../services/sync_service.dart';
import '../ai/ai_screen.dart';
import '../knowledge/knowledge_screen.dart';
import '../knowledge/book_library_screen.dart';

/// 设置页
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 个人资料
          Card(
            child: ListTile(
              leading: const Icon(Icons.person_outline, color: TaoistTheme.jadeGreen),
              title: const Text('个人资料'),
              subtitle: Text(
                provider.userProfile == null
                    ? '完善资料，AI才能为你制定专属计划'
                    : '${provider.userProfile!.height}cm · '
                        '${provider.userProfile!.weight}kg · '
                        '${provider.userProfile!.goal}',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const ProfileScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // AI配置
          Card(
            child: ListTile(
              leading: Icon(
                Icons.psychology_outlined,
                color: provider.aiConfigured
                    ? TaoistTheme.jadeGreen
                    : TaoistTheme.cloudGray,
              ),
              title: const Text('AI服务配置'),
              subtitle: Text(
                provider.aiConfigured ? '已配置' : '未配置，点击配置AI服务',
              ),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const AIConfigScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 智慧知识库
          Card(
            child: ListTile(
              leading: const Icon(Icons.auto_stories_outlined,
                  color: TaoistTheme.bambooGreen),
              title: const Text('智慧知识库'),
              subtitle: const Text('苗振运动康复·中医养生·财务大师智慧'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const KnowledgeScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 书籍库
          Card(
            child: ListTile(
              leading: const Icon(Icons.menu_book_outlined,
                  color: TaoistTheme.teaBrown),
              title: const Text('书籍库'),
              subtitle: const Text('导入中医/运动康复/健身书籍，阅读并摘录'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const BookLibraryScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 数据同步
          Card(
            child: ListTile(
              leading: const Icon(Icons.sync, color: TaoistTheme.bambooGreen),
              title: const Text('数据同步'),
              subtitle: const Text('局域网/云盘同步与备份'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const SyncScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 关于
          const Card(
            child: ListTile(
              leading: Icon(Icons.info_outline, color: TaoistTheme.teaBrown),
              title: Text('关于'),
              subtitle: Text('问道 · 个人全维度规划助手 v1.0.0'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 个人资料页
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  final _heightController = TextEditingController();
  final _weightController = TextEditingController();
  final _ageController = TextEditingController();
  final _bodyFatController = TextEditingController();
  final _customEquipController = TextEditingController();
  String _gender = '男';
  String _goal = '增肌';
  List<String> _equipment = [];

  static const List<String> _goals = ['增肌', '减脂', '保持健康', '增力', '塑形'];

  @override
  void initState() {
    super.initState();
    final profile = Provider.of<AppProvider>(context, listen: false).userProfile;
    if (profile != null) {
      _heightController.text = profile.height.toString();
      _weightController.text = profile.weight.toString();
      _ageController.text = profile.age.toString();
      _bodyFatController.text = profile.bodyFat?.toString() ?? '';
      _gender = profile.gender;
      _goal = profile.goal;
      _equipment = List.of(profile.gymEquipment);
    }
  }

  @override
  void dispose() {
    _heightController.dispose();
    _weightController.dispose();
    _ageController.dispose();
    _bodyFatController.dispose();
    _customEquipController.dispose();
    super.dispose();
  }

  /// 添加自定义器械（预设列表外的器械）
  void _addCustomEquipment() {
    final name = _customEquipController.text.trim();
    if (name.isEmpty) return;
    if (!_equipment.contains(name)) {
      setState(() => _equipment.add(name));
    }
    _customEquipController.clear();
  }

  double _calculateBMR(double height, double weight, int age, String gender) {
    // Mifflin-St Jeor 公式
    if (gender == '男') {
      return 10 * weight + 6.25 * height - 5 * age + 5;
    } else {
      return 10 * weight + 6.25 * height - 5 * age - 161;
    }
  }

  Future<void> _save() async {
    final height = double.tryParse(_heightController.text);
    final weight = double.tryParse(_weightController.text);
    final age = int.tryParse(_ageController.text);

    if (height == null || weight == null || age == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写完整的个人资料')),
      );
      return;
    }

    final bmr = _calculateBMR(height, weight, age, _gender);
    final bodyFat = double.tryParse(_bodyFatController.text);

    final profile = UserProfile(
      height: height,
      weight: weight,
      age: age,
      gender: _gender,
      goal: _goal,
      bmr: bmr,
      bodyFat: bodyFat,
      gymEquipment: _equipment,
    );

    final provider = Provider.of<AppProvider>(context, listen: false);
    await provider.saveUserProfile(profile);

    if (mounted) {
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('个人资料已保存')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('个人资料'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // 性别选择
          const Text(
            '性别',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: '男',
                label: Text('男'),
                icon: Icon(Icons.male),
              ),
              ButtonSegment(
                value: '女',
                label: Text('女'),
                icon: Icon(Icons.female),
              ),
            ],
            selected: {_gender},
            onSelectionChanged: (selection) {
              setState(() => _gender = selection.first);
            },
          ),
          const SizedBox(height: 20),

          // 身高体重年龄
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _heightController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '身高(cm)',
                    prefixIcon: Icon(Icons.height),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _weightController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '体重(kg)',
                    prefixIcon: Icon(Icons.monitor_weight_outlined),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _ageController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '年龄',
                    prefixIcon: Icon(Icons.cake_outlined),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 体脂率（可选）
          const Text(
            '体脂率（可选，填了才能评估减脂进度）',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: TaoistTheme.teaBrown,
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _bodyFatController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              labelText: '体脂率(%)，如 22.5',
              prefixIcon: Icon(Icons.percent),
              hintText: '可用体脂秤测量，或在健身房InBody测',
            ),
          ),
          const SizedBox(height: 20),

          // 健身房器械（多选）
          const Text(
            '健身房器械（多选，AI会按你有的器械安排动作）',
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
            children: UserProfile.equipmentOptions.map((equip) {
              final selected = _equipment.contains(equip);
              return FilterChip(
                label: Text(equip, style: const TextStyle(fontSize: 12)),
                selected: selected,
                onSelected: (val) {
                  setState(() {
                    if (val) {
                      _equipment.add(equip);
                    } else {
                      _equipment.remove(equip);
                    }
                  });
                },
                selectedColor: TaoistTheme.jadeGreen,
                checkmarkColor: Colors.white,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : TaoistTheme.inkBlack,
                ),
                side: BorderSide(
                  color: selected
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.mistGray,
                ),
              );
            }).toList(),
          ),
          if (_equipment.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                '未选择器械时，AI将使用最基础的动作（哑铃/自重）',
                style: TextStyle(
                  fontSize: 11,
                  color: TaoistTheme.cloudGray,
                ),
              ),
            ),
          const SizedBox(height: 8),

          // 自定义器械输入
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _customEquipController,
                  onSubmitted: (_) => _addCustomEquipment(),
                  decoration: const InputDecoration(
                    hintText: '输入你有的其他器械，如：牧羊人杠、甩棍',
                    isDense: true,
                    prefixIcon: Icon(Icons.add_box_outlined, size: 20),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton(
                onPressed: _addCustomEquipment,
                child: const Text('添加'),
              ),
            ],
          ),
          if (_equipment.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                children: _equipment
                    .where((e) => !UserProfile.equipmentOptions.contains(e))
                    .map((e) => Chip(
                          label: Text(e,
                              style: const TextStyle(fontSize: 11)),
                          deleteIcon: const Icon(Icons.close, size: 14),
                          onDeleted: () {
                            setState(() => _equipment.remove(e));
                          },
                          backgroundColor:
                              TaoistTheme.teaBrown.withValues(alpha: 0.08),
                        ))
                    .toList(),
              ),
            ),
          const SizedBox(height: 20),

          // 目标选择
          const Text(
            '健身目标',
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
            children: _goals.map((goal) {
              final selected = _goal == goal;
              return ChoiceChip(
                label: Text(goal),
                selected: selected,
                onSelected: (_) => setState(() => _goal = goal),
                selectedColor: TaoistTheme.jadeGreen,
                labelStyle: TextStyle(
                  color: selected ? Colors.white : TaoistTheme.inkBlack,
                ),
                side: BorderSide(
                  color: selected
                      ? TaoistTheme.jadeGreen
                      : TaoistTheme.mistGray,
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),

          SizedBox(
            height: 48,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存资料'),
            ),
          ),
        ],
      ),
    );
  }
}

/// 数据同步页
class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key});

  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final SyncService _syncService = SyncService();
  final _lanServerController = TextEditingController();
  final _webdavUrlController = TextEditingController();
  final _webdavUserController = TextEditingController();
  final _webdavPassController = TextEditingController();

  String? _status;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _lanServerController.dispose();
    _webdavUrlController.dispose();
    _webdavUserController.dispose();
    _webdavPassController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final lanUrl = await _syncService.getLanServerUrl();
    final webdav = await _syncService.getWebDAVConfig();
    if (mounted) {
      _lanServerController.text = lanUrl;
      _webdavUrlController.text = webdav['url'] ?? '';
      _webdavUserController.text = webdav['username'] ?? '';
      _webdavPassController.text = webdav['password'] ?? '';
    }
  }

  void _showMessage(String message) {
    if (!mounted) return;
    setState(() => _status = message);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _startLanServer() async {
    setState(() => _isLoading = true);
    try {
      await _syncService.startLanServer(8080);
      _showMessage('局域网同步服务已启动，请让其他设备连接本机IP的8080端口');
    } catch (e) {
      _showMessage('启动失败: $e');
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _sendToLanServer() async {
    setState(() => _isLoading = true);
    try {
      final dataJson = await _syncService.exportToJson();
      await _syncService.sendToLanServer(
        serverUrl: _lanServerController.text.trim(),
        dataJson: dataJson,
      );
      _showMessage('数据已发送到局域网服务器');
    } catch (e) {
      _showMessage('同步失败: $e');
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _saveWebDAV() async {
    await _syncService.saveWebDAVConfig(
      url: _webdavUrlController.text.trim(),
      username: _webdavUserController.text.trim(),
      password: _webdavPassController.text.trim(),
    );
    _showMessage('WebDAV配置已保存');
  }

  Future<void> _uploadWebDAV() async {
    setState(() => _isLoading = true);
    try {
      await _syncService.uploadToWebDAV();
      _showMessage('数据已上传到云盘');
    } catch (e) {
      _showMessage('上传失败: $e');
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _downloadWebDAV() async {
    setState(() => _isLoading = true);
    try {
      await _syncService.downloadFromWebDAV();
      if (!mounted) return;
      final provider = Provider.of<AppProvider>(context, listen: false);
      await provider.loadAllData();
      _showMessage('数据已从云盘下载');
    } catch (e) {
      _showMessage('下载失败: $e');
    }
    if (!mounted) return;
    setState(() => _isLoading = false);
  }

  Future<void> _exportToFile() async {
    try {
      final path = await _syncService.exportToFile();
      _showMessage('已导出到: $path');
    } catch (e) {
      _showMessage('导出失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据同步'),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                if (_status != null)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _status!,
                      style: const TextStyle(
                        color: TaoistTheme.jadeGreen,
                        fontSize: 13,
                      ),
                    ),
                  ),

                // ===== 局域网同步 =====
                const Text(
                  '局域网同步',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '在同一WiFi下，电脑端和手机端直接传输数据，无需互联网',
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _startLanServer,
                            icon: const Icon(Icons.router),
                            label: const Text('启动本机同步服务'),
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: _lanServerController,
                          decoration: const InputDecoration(
                            labelText: '对方服务器地址',
                            hintText: 'http://192.168.1.100:8080',
                            prefixIcon: Icon(Icons.dns_outlined),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            onPressed: _sendToLanServer,
                            icon: const Icon(Icons.send),
                            label: const Text('发送数据到对方'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ===== WebDAV云盘同步 =====
                const Text(
                  '云盘同步（WebDAV）',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  '支持坚果云、阿里云盘等支持WebDAV协议的云盘',
                  style: TextStyle(
                    fontSize: 12,
                    color: TaoistTheme.cloudGray,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      children: [
                        TextField(
                          controller: _webdavUrlController,
                          decoration: const InputDecoration(
                            labelText: 'WebDAV地址',
                            hintText: 'https://dav.jianguoyun.com/dav/',
                            prefixIcon: Icon(Icons.cloud_outlined),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _webdavUserController,
                          decoration: const InputDecoration(
                            labelText: '账号',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                        ),
                        const SizedBox(height: 8),
                        TextField(
                          controller: _webdavPassController,
                          obscureText: true,
                          decoration: const InputDecoration(
                            labelText: '密码',
                            prefixIcon: Icon(Icons.lock_outline),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: [
                            Expanded(
                              child: ElevatedButton(
                                onPressed: _saveWebDAV,
                                child: const Text('保存配置'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _uploadWebDAV,
                                child: const Text('上传数据'),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _downloadWebDAV,
                                child: const Text('下载数据'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),

                // ===== 本地备份 =====
                const Text(
                  '本地备份',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.inkBlack,
                  ),
                ),
                const SizedBox(height: 12),
                Card(
                  child: ListTile(
                    leading: const Icon(
                      Icons.file_download_outlined,
                      color: TaoistTheme.jadeGreen,
                    ),
                    title: const Text('导出备份文件'),
                    subtitle: const Text('将全部数据保存为JSON文件'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _exportToFile,
                  ),
                ),
                const SizedBox(height: 32),
              ],
            ),
    );
  }
}
