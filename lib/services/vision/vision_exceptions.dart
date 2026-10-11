/// 视觉识别分型异常：
/// 「已配置但调用失败」时不允许静默降级，抛分型异常给 UI，
/// 由用户选择「重试 / 改用本地识别」。
sealed class VisionException implements Exception {
  final String message;
  const VisionException(this.message);
  @override
  String toString() => message;
}

/// 未配置任何视觉通道（独立配置与旧通道均不可用）且场景无法走本地 OCR（如 PDF）
class VisionConfigRequiredException extends VisionException {
  const VisionConfigRequiredException(
      [super.message = '尚未配置图片/PDF 识别服务，请到「AI服务配置」的「图片与 PDF 识别」卡片填写']);
}

/// 鉴权失败（401/403）：Key 无效或已过期
class VisionAuthException extends VisionException {
  final int statusCode;
  const VisionAuthException(this.statusCode,
      [super.message = '识别服务鉴权失败，请检查 API Key 是否正确']);
  @override
  String toString() => message;
}

/// 网络异常（连接失败/超时/DNS）
class VisionNetworkException extends VisionException {
  const VisionNetworkException([super.message = '网络连接失败，请检查网络或识别服务地址']);
}

/// 服务端返回错误（5xx/4xx 其他状态码/响应格式异常）
class VisionServiceException extends VisionException {
  final int? statusCode;
  final String bodySummary;
  VisionServiceException(this.statusCode, this.bodySummary)
      : super(bodySummary.isEmpty
            ? '识别服务返回错误${statusCode != null ? '（$statusCode）' : ''}'
            : '识别服务返回错误${statusCode != null ? '（$statusCode）' : ''}：$bodySummary');
}

/// PDF 页数超限（>20 页）
class PdfTooLargeException extends VisionException {
  const PdfTooLargeException([super.message = 'PDF 页数超过 20 页上限，请拆分后分次导入，或改用图片']);
}
