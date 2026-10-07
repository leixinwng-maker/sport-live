import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'providers/app_provider.dart';
import 'screens/auth/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme/taoist_theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  // 桌面端使用 sqflite_common_ffi 初始化数据库工厂（必须在首次 openDatabase 之前执行）
  if (!kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => AppProvider()..init(),
      child: MaterialApp(
        title: '问道 · 生活规划',
        debugShowCheckedModeBanner: false,
        theme: TaoistTheme.lightTheme,
        darkTheme: TaoistTheme.darkTheme,
        themeMode: ThemeMode.system,
        home: Consumer<AppProvider>(
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
    );
  }
}
