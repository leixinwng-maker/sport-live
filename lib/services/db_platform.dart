import 'dart:io' show Platform;

/// P2 隐私设计（设计文档 §3.4）：
/// - 移动端（Android/iOS）：SQLCipher 加密库，密钥存系统安全存储；
/// - 桌面端（Windows/macOS/Linux 开发调试）：普通 ffi，不做加密，避免 ffi 兼容折腾。
/// 发布产物仅包含移动端路径，运行时判定即可。
final bool kUseEncryption = Platform.isAndroid || Platform.isIOS;
