import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'providers/agent_provider.dart';
import 'providers/app_provider.dart';
import 'providers/wearable_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_screen.dart';
import 'screens/legal/agreement_screen.dart';
import 'screens/lock/lock_screen.dart';
import 'theme/taoist_theme.dart';

void main() {
  // Flutter 框架错误（构建/布局/绘制异常）与 Dart 层未捕获异步异常统一在此收敛，
  // 避免单颗 widget 抛错直接把整棵 UI 打黑屏，也不让异常静默吞掉难排查。
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('[FlutterError] ${details.exceptionAsString()}\n${details.stack}');
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    debugPrint('[PlatformDispatcher] $error\n$stack');
    return true; // 已处理，不再交给系统默认崩溃处理
  };

  runZonedGuarded(
    () {
      WidgetsFlutterBinding.ensureInitialized();
      // 桌面端使用 sqflite_common_ffi 初始化数据库工厂（必须在首次 openDatabase 之前执行）
      if (!kIsWeb &&
          (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        sqfliteFfiInit();
        databaseFactory = databaseFactoryFfi;
      }
      runApp(const MyApp());
    },
    (error, stack) {
      debugPrint('[ZoneUncaught] $error\n$stack');
    },
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppProvider()..init()),
        // P4-C 穿戴数据：仅探测可用性，不弹授权（授权须先经单独同意页）
        ChangeNotifierProvider(create: (_) => WearableProvider()..init()),
        // 智能体同时依赖 AppProvider（业务数据）与 WearableProvider（穿戴摘要）
        ChangeNotifierProxyProvider2<AppProvider, WearableProvider, AgentProvider>(
          create: (_) => AgentProvider(),
          update: (context, app, wearable, agent) =>
              agent!..attach(app)..attachWearable(wearable),
        ),
      ],
      child: MaterialApp(
        title: '问道 · 生活规划',
        debugShowCheckedModeBanner: false,
        theme: TaoistTheme.lightTheme,
        darkTheme: TaoistTheme.darkTheme,
        themeMode: ThemeMode.system,
        home: AgreementGate(
          child: AppLockGate(
            child: Consumer<AppProvider>(
              builder: (context, provider, _) {
                final need = provider.needsLogin;
                if (need == null) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                return need ? const LoginScreen() : const HomeScreen();
              },
            ),
          ),
        ),
      ),
    );
  }
}
