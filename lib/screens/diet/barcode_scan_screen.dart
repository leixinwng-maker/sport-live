import 'package:flutter/material.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../models/diet.dart';
import '../../providers/app_provider.dart';
import '../../services/food_lookup_service.dart';
import '../../theme/taoist_theme.dart';

/// FIT-7 条码扫描页
///
/// 场景：记录饮食时扫描食品包装条码，命中后复用既有的
/// [AppProvider.fetchFoodByBarcode]（Open Food Facts v2 单条码查询）拿回
/// 每 100g 营养值，并把结果作为 [FoodCatalog] 回传给「记录饮食」页，
/// 与从食物库选择食物的契约完全一致。
///
/// 合规约束：
/// - 仅按「单个条码」查询单条商品，不做批量抓取 / 整体库再分发（ODbL 条款）
/// - 相机画面仅在本机取景识别，不上传任何图像
/// - 联网查询需用户在设置页开启「循证文献联网检索」；未开启时本页会先弹窗
///   征得用户同意后才开启，绝不静默联网
class BarcodeScanScreen extends StatefulWidget {
  const BarcodeScanScreen({super.key});

  @override
  State<BarcodeScanScreen> createState() => _BarcodeScanScreenState();
}

class _BarcodeScanScreenState extends State<BarcodeScanScreen> {
  /// 限定为零售商品常见的一维码格式，避免误扫二维码等无关码制
  static const List<BarcodeFormat> _retailFormats = [
    BarcodeFormat.ean13,
    BarcodeFormat.ean8,
    BarcodeFormat.upcA,
    BarcodeFormat.upcE,
    BarcodeFormat.code128,
    BarcodeFormat.code39,
    BarcodeFormat.itf14,
  ];

  static const Duration _dedupeWindow = Duration(seconds: 3);

  late final MobileScannerController _controller;
  bool _processing = false;
  bool _torchOn = false;
  String? _lastCode;
  DateTime? _lastAt;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      formats: _retailFormats,
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_processing) return;

    String? code;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null && FoodLookupService.isBarcode(value)) {
        code = value.trim();
        break;
      }
    }
    if (code == null) return;

    // 取景框会连续回传同一条码：同码在去重窗口内只处理一次
    final now = DateTime.now();
    final last = _lastAt;
    if (code == _lastCode && last != null && now.difference(last) < _dedupeWindow) {
      return;
    }
    _lastCode = code;
    _lastAt = now;

    _lookup(code);
  }

  Future<void> _lookup(String code) async {
    if (_processing) return;
    setState(() => _processing = true);

    final provider = context.read<AppProvider>();
    try {
      if (!provider.evidenceOnlineSearch) {
        final agreed = await _confirmEnableOnline();
        if (!mounted) return;
        if (!agreed) {
          setState(() => _processing = false);
          return;
        }
        await provider.setEvidenceOnlineSearch(true);
        if (!mounted) return;
      }

      final item = await provider.fetchFoodByBarcode(code);
      if (!mounted) return;

      if (item != null) {
        Navigator.pop(context, item);
        return;
      }

      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('未找到条码 $code 对应的商品，可换一件或手动输入条码')),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _processing = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('查询失败，请检查网络后重试')),
      );
    }
  }

  Future<bool> _confirmEnableOnline() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('需要联网查询'),
        content: const Text(
          '条码商品信息来自 Open Food Facts（开放数据）。\n\n'
          '本应用默认不联网，是否开启「循证文献联网检索」并继续查询？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('开启并查询'),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _manualInput() async {
    if (_processing) return;

    final controller = TextEditingController();
    final code = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('手动输入条码'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: '条码（6~20 位数字）',
            hintText: '例如 6901234567892',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final value = controller.text.trim();
              if (!FoodLookupService.isBarcode(value)) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('条码格式不正确')),
                );
                return;
              }
              Navigator.pop(ctx, value);
            },
            child: const Text('查询'),
          ),
        ],
      ),
    );
    controller.dispose();

    if (code != null && code.isNotEmpty && mounted) {
      _lookup(code);
    }
  }

  Future<void> _toggleTorch() async {
    await _controller.toggleTorch();
    if (!mounted) return;
    setState(() => _torchOn = !_torchOn);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('扫描条码'),
        actions: [
          IconButton(
            tooltip: '手动输入条码',
            onPressed: _manualInput,
            icon: const Icon(Icons.keyboard_alt_outlined),
          ),
          IconButton(
            tooltip: _torchOn ? '关闭闪光灯' : '打开闪光灯',
            onPressed: _toggleTorch,
            icon: Icon(_torchOn ? Icons.flashlight_on : Icons.flashlight_off),
          ),
        ],
      ),
      body: Stack(
        children: [
          MobileScanner(
            controller: _controller,
            onDetect: _onDetect,
            errorBuilder: (context, error) => _buildCameraError(context, error),
            overlayBuilder: (context, constraints) =>
                _buildScanOverlay(constraints),
          ),
          if (_processing)
            Container(
              color: Colors.black54,
              alignment: Alignment.center,
              child: const Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: TaoistTheme.jadeGreen),
                  SizedBox(height: 12),
                  Text(
                    '正在查询商品信息…',
                    style: TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 36,
            child: _buildHint(),
          ),
        ],
      ),
    );
  }

  Widget _buildHint() {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(20),
        ),
        child: const Text(
          '将食品包装条码放入取景框内',
          style: TextStyle(color: Colors.white, fontSize: 13),
        ),
      ),
    );
  }

  Widget _buildScanOverlay(BoxConstraints constraints) {
    final size = constraints.biggest;
    final windowWidth = size.width * 0.78;
    final windowHeight = windowWidth * 0.5;
    final window = Rect.fromCenter(
      center: Offset(size.width / 2, size.height / 2 - 40),
      width: windowWidth,
      height: windowHeight,
    );
    return CustomPaint(
      size: size,
      painter: _ScanOverlayPainter(window: window),
    );
  }

  Widget _buildCameraError(BuildContext context, MobileScannerException error) {
    final bool permissionDenied =
        error.errorCode == MobileScannerErrorCode.permissionDenied;
    final detail = error.errorDetails?.message;

    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.no_photography_outlined,
            color: Colors.white70,
            size: 46,
          ),
          const SizedBox(height: 14),
          Text(
            permissionDenied ? '未获得相机权限' : '相机初始化失败',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            permissionDenied
                ? '请在系统「设置 → 应用 → 问道 → 权限」中允许使用相机，'
                    '然后返回本页重试。也可以在下方手动输入条码。'
                : '${error.errorCode.message}${detail == null ? '' : '（$detail）'}',
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 18),
          OutlinedButton.icon(
            onPressed: _manualInput,
            icon: const Icon(Icons.keyboard_alt_outlined, size: 18),
            label: const Text('手动输入条码'),
            style: OutlinedButton.styleFrom(foregroundColor: Colors.white),
          ),
        ],
      ),
    );
  }
}

/// 取景框遮罩：四周压暗 + 中央透明窗口 + 四角高亮括号
class _ScanOverlayPainter extends CustomPainter {
  const _ScanOverlayPainter({required this.window});

  final Rect window;

  @override
  void paint(Canvas canvas, Size size) {
    final scrim = Paint()..color = Colors.black.withValues(alpha: 0.55);
    final outer = Path()..addRect(Offset.zero & size);
    final hole = Path()
      ..addRRect(RRect.fromRectAndRadius(window, const Radius.circular(14)));
    canvas.drawPath(Path.combine(PathOperation.difference, outer, hole), scrim);

    final bracket = Paint()
      ..color = TaoistTheme.jadeGreen
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;

    const len = 26.0;
    final r = window;
    // 左上
    canvas.drawLine(Offset(r.left, r.top), Offset(r.left + len, r.top), bracket);
    canvas.drawLine(Offset(r.left, r.top), Offset(r.left, r.top + len), bracket);
    // 右上
    canvas.drawLine(Offset(r.right, r.top), Offset(r.right - len, r.top), bracket);
    canvas.drawLine(Offset(r.right, r.top), Offset(r.right, r.top + len), bracket);
    // 左下
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.left + len, r.bottom), bracket);
    canvas.drawLine(Offset(r.left, r.bottom), Offset(r.left, r.bottom - len), bracket);
    // 右下
    canvas.drawLine(Offset(r.right, r.bottom), Offset(r.right - len, r.bottom), bracket);
    canvas.drawLine(
        Offset(r.right, r.bottom), Offset(r.right, r.bottom - len), bracket);
  }

  @override
  bool shouldRepaint(_ScanOverlayPainter oldDelegate) =>
      oldDelegate.window != window;
}
