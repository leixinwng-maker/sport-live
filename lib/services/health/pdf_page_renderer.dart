import 'dart:typed_data';

import 'package:pdfx/pdfx.dart';

import '../vision/vision_exceptions.dart';

/// PDF 逐页渲染器：把 PDF 每页渲染为 JPEG 字节，供视觉模型识别。
/// 支持 Android / iOS / Windows / macOS / Web。
class PdfPageRenderer {
  static final PdfPageRenderer instance = PdfPageRenderer._();
  PdfPageRenderer._();

  /// 渲染 PDF 全部页面为 JPEG 列表。
  ///
  /// [dpi] 渲染分辨率（默认 150，兼顾清晰度与上传体积）；
  /// 超过 [maxPages] 页抛 [PdfTooLargeException]；
  /// 损坏 / 加密 PDF 抛带中文提示的 [Exception]。
  Future<List<Uint8List>> render(
    String pdfPath, {
    int dpi = 150,
    int maxPages = 20,
    int jpegQuality = 80,
  }) async {
    PdfDocument? doc;
    try {
      doc = await PdfDocument.openFile(pdfPath);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('password') || msg.contains('encrypt')) {
        throw Exception('PDF 已加密，请先解除密码保护后重试');
      }
      throw Exception('无法打开 PDF 文件，文件可能已损坏：$e');
    }

    try {
      if (doc.pagesCount > maxPages) {
        throw const PdfTooLargeException();
      }
      final scale = dpi / 72.0;
      final pages = <Uint8List>[];
      for (var i = 1; i <= doc.pagesCount; i++) {
        final page = await doc.getPage(i);
        try {
          final rendered = await page.render(
            width: page.width * scale,
            height: page.height * scale,
            format: PdfPageImageFormat.jpeg,
            quality: jpegQuality,
          );
          final bytes = rendered?.bytes;
          if (bytes == null || bytes.isEmpty) {
            throw Exception('第 $i 页渲染失败，请尝试改用图片格式报告');
          }
          pages.add(bytes);
        } finally {
          await page.close();
        }
      }
      return pages;
    } finally {
      await doc.close();
    }
  }
}
