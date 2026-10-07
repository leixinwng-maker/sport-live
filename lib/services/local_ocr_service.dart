import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart'
    as mlkit;
import 'dart:typed_data';

/// 本地 OCR 服务（免费、离线、不依赖 AI 视觉模型）
/// Android: Google ML Kit 中文识别（本地模型）
/// 其他平台：暂不支持本地 OCR，由上层降级到视觉模型或手动录入
class LocalOcrService {
  static final LocalOcrService instance = LocalOcrService._();
  LocalOcrService._();

  /// 识别图片/文件中的文字，返回识别出的文本。
  /// [filePath] 图片文件路径（Android/iOS 通用）
  /// [bytes] 可选：直接传图片字节
  /// 仅 Android/iOS 支持本地识别，其他平台抛出 [UnsupportedError]，
  /// 由上层决定是否降级到视觉模型。
  Future<String> recognize({
    String? filePath,
    Uint8List? bytes,
  }) async {
    if (Platform.isAndroid || Platform.isIOS) {
      return await _recognizeMlKit(filePath: filePath, bytes: bytes);
    } else {
      throw UnsupportedError(
          '当前平台(${Platform.operatingSystem})不支持本地OCR，请配置视觉模型或手动录入');
    }
  }

  /// 是否支持本地 OCR（Android/iOS 支持）
  bool get isSupported =>
      Platform.isAndroid || Platform.isIOS;

  /// Google ML Kit 识别（支持中文）
  Future<String> _recognizeMlKit({
    String? filePath,
    Uint8List? bytes,
  }) async {
    final textRecognizer = mlkit.TextRecognizer(
      script: mlkit.TextRecognitionScript.chinese,
    );
    String? tempPath;
    try {
      // 有字节但无路径时，写临时文件（fromBytes 只支持 YUV/BGRA 原始格式，不适合 JPEG）
      if (bytes != null &&
          bytes.isNotEmpty &&
          (filePath == null || filePath.isEmpty)) {
        tempPath = await _writeTempFile(bytes);
        filePath = tempPath;
      }
      if (filePath == null || filePath.isEmpty) {
        throw Exception('缺少图片数据');
      }

      final inputImage = mlkit.InputImage.fromFilePath(filePath);
      final result = await textRecognizer.processImage(inputImage);
      return result.text;
    } finally {
      textRecognizer.close();
      if (tempPath != null) {
        try {
          final f = File(tempPath);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
    }
  }

  Future<String> _writeTempFile(Uint8List bytes) async {
    final dir = Directory.systemTemp;
    final file = File(
        '${dir.path}/ocr_${DateTime.now().millisecondsSinceEpoch}.jpg');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 将图片文件读取为字节
  static Future<Uint8List> readBytes(String filePath) async {
    return await File(filePath).readAsBytes();
  }
}
