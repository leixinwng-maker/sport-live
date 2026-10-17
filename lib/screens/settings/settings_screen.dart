import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../providers/app_provider.dart';
import '../../theme/taoist_theme.dart';
import '../../models/user_profile.dart';
import '../../services/agreement_consent.dart';
import '../../services/app_lock_service.dart';
import '../../services/cloud_api.dart';
import '../../services/database_helper.dart';
import '../../services/rest_timer_settings.dart';
import '../../services/sync_engine.dart';
import '../legal/agreement_text_screen.dart';
import '../legal/legal_documents.dart';
import 'cloud_sync_screen.dart';
import '../ai/ai_screen.dart';
import '../knowledge/knowledge_screen.dart';
import '../knowledge/book_library_screen.dart';
import '../knowledge/open_data_screen.dart';
import '../health/health_data_source_screen.dart';
import '../diet/widgets/diet_target_card.dart';
import '../diet/fasting_screen.dart';

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

          // 开放数据与本体
          Card(
            child: ListTile(
              leading: const Icon(Icons.hub_outlined,
                  color: TaoistTheme.bambooGreen),
              title: const Text('开放数据与本体'),
              subtitle: const Text('运动医学/康复本体·数据源登记表·开放动作库'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const OpenDataScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 账号
          Card(
            child: ListTile(
              leading: const Icon(Icons.account_circle_outlined,
                  color: TaoistTheme.jadeGreen),
              title: Text(provider.needsLogin == false
                  ? (CloudApi.instance.userEmail ?? '已登录')
                  : '未登录'),
              subtitle: const Text('云端账号'),
              trailing: TextButton(
                onPressed: () => _confirmLogout(context, provider),
                child: const Text('退出登录'),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 云同步
          Card(
            child: AnimatedBuilder(
              animation: SyncEngine.instance,
              builder: (context, _) {
                final engine = SyncEngine.instance;
                String sub;
                if (provider.needsLogin != false) {
                  sub = '登录后自动同步';
                } else if (engine.isSyncing) {
                  sub = '正在同步...';
                } else if (engine.pendingCount > 0) {
                  sub = '待上传 ${engine.pendingCount} 项';
                } else {
                  sub = '已同步';
                }
                return ListTile(
                  leading: const Icon(Icons.sync,
                      color: TaoistTheme.bambooGreen),
                  title: const Text('云同步'),
                  subtitle: Text(sub),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CloudSyncScreen(),
                      ),
                    );
                  },
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 循证联网检索（P4-T3 食物条码 / P5 文献检索，默认关闭）
          Card(
            child: SwitchListTile(
              secondary: const Icon(Icons.science_outlined,
                  color: TaoistTheme.bambooGreen),
              title: const Text('循证文献联网检索'),
              subtitle: Text(
                provider.evidenceOnlineSearch
                    ? '已开启：食物条码可联网查询 Open Food Facts；'
                        '本地循证库无命中时可联网检索开源医学文献（Europe PMC / OpenAlex，仅元数据）'
                    : '已关闭（默认）：全部走本地库，不产生任何网络请求',
              ),
              value: provider.evidenceOnlineSearch,
              onChanged: (val) => provider.setEvidenceOnlineSearch(val),
            ),
          ),
          const SizedBox(height: 12),

          // 运动健康数据（P4-T6：单独同意 · 数据源诊断 · 撤回授权）
          Card(
            child: ListTile(
              leading: const Icon(Icons.monitor_heart_outlined,
                  color: TaoistTheme.bambooGreen),
              title: const Text('运动健康数据'),
              subtitle: const Text('授权读取穿戴数据 · 数据源诊断 · 撤回授权'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => const HealthDataSourceScreen(),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 12),

          // 组间休息计时（FIT-6）
          const RestTimerSettingsCard(),
          const SizedBox(height: 12),

          // 饮食增强（FIT-7）：每日营养目标 + 间歇性断食
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.flag_outlined,
                      color: TaoistTheme.jadeGreen),
                  title: const Text('每日营养目标'),
                  subtitle: Text(
                    provider.dietTarget.hasCalorieTarget
                        ? '${provider.dietTarget.calories.toStringAsFixed(0)} 千卡 · '
                            '蛋白 ${provider.dietTarget.protein.toStringAsFixed(0)}g · '
                            '碳水 ${provider.dietTarget.carbs.toStringAsFixed(0)}g · '
                            '脂肪 ${provider.dietTarget.fat.toStringAsFixed(0)}g'
                            '${provider.dietTarget.hasCarbCycle ? ' · 碳水循环' : ''}'
                        : '未设置，点击配置热量与三大营养素',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDietTargetEditor(context, provider),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.timelapse,
                      color: TaoistTheme.bambooGreen),
                  title: const Text('间歇性断食'),
                  subtitle: Text(provider.fastingSettings.plan.description),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showFastingSettingsSheet(context, provider),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // 安全
          Card(
            child: AnimatedBuilder(
              animation: AppLockService.instance,
              builder: (context, _) => Column(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.lock_outline,
                        color: TaoistTheme.teaBrown),
                    title: const Text('应用锁'),
                    subtitle: const Text('打开应用或回前台超过1分钟时验证身份'),
                    value: AppLockService.instance.enabled,
                    onChanged: (val) => _toggleAppLock(context, val),
                  ),
                  ListTile(
                    leading: const Icon(Icons.delete_sweep_outlined,
                        color: Colors.redAccent),
                    title: const Text('一键清除本地数据'),
                    subtitle: const Text('删除本机缓存与密钥，云端数据不受影响'),
                    onTap: () => _confirmWipeLocal(context, provider),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),

          // 协议与隐私
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined,
                      color: TaoistTheme.jadeGreen),
                  title: const Text('隐私政策'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const AgreementTextScreen(document: kPrivacyPolicy),
                    ),
                  ),
                ),
                const Divider(height: 1),
                ListTile(
                  leading: const Icon(Icons.article_outlined,
                      color: TaoistTheme.teaBrown),
                  title: const Text('用户协议'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          const AgreementTextScreen(document: kUserAgreement),
                    ),
                  ),
                ),
                FutureBuilder<AgreementConsent?>(
                  future: AgreementConsentStore().load(),
                  builder: (context, snap) {
                    final c = snap.data;
                    final subtitle = (c?.isActive ?? false)
                        ? '已同意 v${c!.version} · ${_fmtAgreedDate(c.agreedAt)}'
                        : '尚未同意';
                    return ListTile(
                      leading: const Icon(Icons.verified_user_outlined,
                          color: TaoistTheme.bambooGreen),
                      title: const Text('协议同意状态'),
                      subtitle: Text(subtitle),
                    );
                  },
                ),
              ],
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

  /// 协议同意时间格式化（仅日期）
  static String _fmtAgreedDate(DateTime? t) {
    if (t == null) return '';
    final local = t.toLocal();
    final mm = local.month.toString().padLeft(2, '0');
    final dd = local.day.toString().padLeft(2, '0');
    return '${local.year}-$mm-$dd';
  }

  /// 退出登录
  Future<void> _confirmLogout(BuildContext context, AppProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('退出登录'),
        content: const Text(
            '退出会停止同步并清空本机待传队列，云端数据保留，重新登录后自动拉取。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('退出')),
        ],
      ),
    );
    if (ok == true) await provider.logout();
  }

  /// 开启/关闭应用锁（开启时设置 6 位数字 PIN）
  Future<void> _toggleAppLock(BuildContext context, bool enable) async {
    if (!enable) {
      await AppLockService.instance.disable();
      return;
    }
    final pin = await _askPin(context, '设置应用锁 PIN（6位数字）');
    if (pin == null || !context.mounted) return;
    final again = await _askPin(context, '再次输入 PIN 确认');
    if (again == null) return;
    if (again != pin) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('两次输入不一致，未开启应用锁')),
        );
      }
      return;
    }
    final bio = await AppLockService.instance.biometricsAvailable();
    await AppLockService.instance.enable(pin: pin, biometric: bio);
  }

  Future<String?> _askPin(BuildContext context, String title) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
            obscureText: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            decoration: const InputDecoration(
              hintText: '●●●●●●',
              counterText: '',
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('取消')),
            ElevatedButton(
              onPressed: () {
                final pin = controller.text.trim();
                if (pin.length != 6 || int.tryParse(pin) == null) {
                  Navigator.pop(dialogContext);
                  return;
                }
                Navigator.pop(dialogContext, pin);
              },
              child: const Text('确定'),
            ),
          ],
        ),
      ),
    );
  }

  /// 一键清除本地数据：停引擎→清游标（重建后全量重拉）→删库与密钥→重启引擎
  Future<void> _confirmWipeLocal(
      BuildContext context, AppProvider provider) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清除本地数据'),
        content: const Text(
            '将删除本机加密数据库与密钥并重建为空库，随后自动从云端重新同步。云端数据不受影响。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清除并重建'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    SyncEngine.instance.stop();
    await SyncEngine.instance.clearPullCursor();
    await DatabaseHelper.instance.wipeLocalData();
    SyncEngine.instance.start();
    await provider.loadAllData();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('本地数据已清除，正在从云端重新同步')),
      );
    }
  }
}

/// 组间休息计时设置卡片（FIT-6）
/// 独立加载与保存，避免把设置塞进 AppProvider 的全局状态里。
class RestTimerSettingsCard extends StatefulWidget {
  const RestTimerSettingsCard({super.key});

  @override
  State<RestTimerSettingsCard> createState() => _RestTimerSettingsCardState();
}

class _RestTimerSettingsCardState extends State<RestTimerSettingsCard> {
  static const RestTimerSettingsStore _store = RestTimerSettingsStore();

  RestTimerSettings _settings = const RestTimerSettings();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _store.load();
    if (!mounted) return;
    setState(() {
      _settings = settings;
      _loading = false;
    });
  }

  Future<void> _update(RestTimerSettings settings) async {
    setState(() => _settings = settings);
    await _store.save(settings);
  }

  /// 选择默认休息时长：预设 + 自定义
  Future<void> _pickDefaultSeconds() async {
    const customSentinel = -1;
    final picked = await showModalBottomSheet<int>(
      context: context,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text('默认休息时长',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
              ),
              for (final s in RestTimerSettings.presets)
                ListTile(
                  dense: true,
                  title: Text(RestTimerSettings.formatSeconds(s)),
                  trailing: _settings.defaultSeconds == s
                      ? const Icon(Icons.check, color: TaoistTheme.jadeGreen)
                      : null,
                  onTap: () => Navigator.pop(ctx, s),
                ),
              ListTile(
                dense: true,
                title: const Text('自定义…'),
                leading: const Icon(Icons.edit_outlined, size: 18),
                onTap: () => Navigator.pop(ctx, customSentinel),
              ),
            ],
          ),
        ),
      ),
    );

    if (picked == null) return;
    if (picked == customSentinel) {
      final custom = await _askCustomSeconds();
      if (custom == null) return;
      await _update(_settings.copyWith(defaultSeconds: custom));
      return;
    }
    await _update(_settings.copyWith(defaultSeconds: picked));
  }

  /// 自定义时长输入（5 ~ 1800 秒）
  Future<int?> _askCustomSeconds() async {
    final controller =
        TextEditingController(text: '${_settings.defaultSeconds}');
    final value = await showDialog<int>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义休息时长'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '秒',
            helperText: '范围 ${RestTimerSettings.minSeconds} ~ '
                '${RestTimerSettings.maxSeconds} 秒',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              final n = int.tryParse(controller.text.trim());
              Navigator.pop(
                  ctx, n == null ? null : RestTimerSettings.clampSeconds(n));
            },
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    return value;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Card(
        child: ListTile(
          leading:
              Icon(Icons.timer_outlined, color: TaoistTheme.bambooGreen),
          title: Text('组间休息计时'),
          subtitle: Text('读取设置中…'),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          ListTile(
            leading:
                const Icon(Icons.timer_outlined, color: TaoistTheme.bambooGreen),
            title: const Text('默认休息时长'),
            subtitle: const Text('逐组未单独设置时使用'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  RestTimerSettings.formatSeconds(_settings.defaultSeconds),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: TaoistTheme.teaBrown,
                  ),
                ),
                const Icon(Icons.chevron_right),
              ],
            ),
            onTap: _pickDefaultSeconds,
          ),
          SwitchListTile(
            secondary: const Icon(Icons.check_box_outlined,
                color: TaoistTheme.bambooGreen),
            title: const Text('打勾自动计时'),
            subtitle: const Text('训练记录页勾选完成一组时自动开始倒计时'),
            value: _settings.autoStartOnCheck,
            onChanged: (v) => _update(_settings.copyWith(autoStartOnCheck: v)),
          ),
          SwitchListTile(
            secondary:
                const Icon(Icons.vibration, color: TaoistTheme.bambooGreen),
            title: const Text('震动提醒'),
            subtitle: const Text('倒计时结束时震动一次'),
            value: _settings.vibrateEnabled,
            onChanged: (v) => _update(_settings.copyWith(vibrateEnabled: v)),
          ),
          SwitchListTile(
            secondary: const Icon(Icons.volume_up_outlined,
                color: TaoistTheme.bambooGreen),
            title: const Text('提示音'),
            subtitle: const Text('倒计时结束时播放系统提示音'),
            value: _settings.soundEnabled,
            onChanged: (v) => _update(_settings.copyWith(soundEnabled: v)),
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

