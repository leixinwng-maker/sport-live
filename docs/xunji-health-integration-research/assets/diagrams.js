/* Mermaid bootstrap for the 训记健康平台接入调研 report.
   Loaded after _shared/js/mermaid.min.js. Rendered diagram colors are hardcoded
   because Mermaid output cannot inherit CSS custom properties. */
(function () {
  if (typeof mermaid === 'undefined') return;

  mermaid.initialize({
    startOnLoad: true,
    securityLevel: 'loose',
    theme: 'base',
    fontFamily: "'PingFang SC', 'Microsoft YaHei', 'Noto Sans CJK SC', 'Segoe UI', sans-serif",
    themeVariables: {
      fontSize: '14px',
      primaryColor: '#E6F7F1',
      primaryTextColor: '#0B5C44',
      primaryBorderColor: '#12B886',
      secondaryColor: '#F6F9F8',
      tertiaryColor: '#FFFFFF',
      lineColor: '#6B7A76',
      textColor: '#1A2421',
      clusterBkg: '#FBFDFC',
      clusterBorder: '#D6E0DD'
    },
    flowchart: {
      useMaxWidth: true,
      htmlLabels: true,
      curve: 'basis',
      nodeSpacing: 36,
      rankSpacing: 46,
      padding: 12
    }
  });
})();
