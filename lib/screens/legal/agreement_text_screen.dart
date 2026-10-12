import 'package:flutter/material.dart';

import '../../theme/taoist_theme.dart';
import 'legal_documents.dart';

/// 协议全文查看页（隐私政策 / 用户协议共用，内置离线渲染）
class AgreementTextScreen extends StatelessWidget {
  const AgreementTextScreen({super.key, required this.document});

  final LegalDocument document;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(document.title),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: document.sections.length,
        itemBuilder: (context, i) {
          final s = document.sections[i];
          return Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  s.heading,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                    color: TaoistTheme.jadeGreen,
                  ),
                ),
                const SizedBox(height: 8),
                for (final p in s.paragraphs)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(
                      _stripBold(p),
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.7,
                        color: TaoistTheme.inkBlack,
                        fontWeight: _isBold(p) ? FontWeight.bold : null,
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 文案用 ** 标记的段落整段加粗（Flutter Text 不解析 Markdown）
  static bool _isBold(String p) => p.startsWith('**') && p.endsWith('**');

  static String _stripBold(String p) => p.replaceAll('**', '');
}
