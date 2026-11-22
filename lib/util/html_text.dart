// HTMLを文字にする部品（2026-11-22 の11で gmail_service・mail_detail_screen から移した。メールの動きは変えていない）

/// HTMLを読める文字にする（メール本文をAIに渡すときなど）。
/// [keepLinks] なら、リンクを「文字（https://…）」の形で残す（予定のメモ欄を変更画面・AIに出すとき）
String htmlToText(String html, {bool keepLinks = false}) {
  var s = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(RegExp(r'<head[^>]*>[\s\S]*?</head>', caseSensitive: false), '')
      .replaceAll(RegExp(r'<(style|script|title)[^>]*>[\s\S]*?</\1>', caseSensitive: false), '');
  if (keepLinks) s = _keepLinks(s);
  s = s
      .replaceAll(RegExp(r'[\r\n]+'), ' ') // HTMLの改行は表示上の改行ではない
      .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(p|div|tr|li|h\d|table|blockquote)>', caseSensitive: false), '\n')
      .replaceAll(RegExp(r'</(td|th)>', caseSensitive: false), ' ')
      .replaceAll(RegExp(r'<[^>]+>'), '');
  s = decodeHtmlEntities(s);
  s = s
      .split('\n')
      .map((line) => line.replaceAll(RegExp(r'[ \t 　]+'), ' ').trim())
      .join('\n');
  return s.replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

final _anchor = RegExp(
  r'''<a\s[^>]*?href\s*=\s*("([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)</a>''',
  caseSensitive: false,
);

/// <a href="https://…">資料</a> → 資料（https://…）。https・http・mailto 以外のリンクは文字だけ残す
String _keepLinks(String s) => s.replaceAllMapped(_anchor, (m) {
      final hrefRaw = (m[2] ?? m[3] ?? m[4] ?? '').trim();
      final href = decodeHtmlEntities(hrefRaw);
      final inner = m[5]!;
      if (!RegExp(r'^(https?|mailto):', caseSensitive: false).hasMatch(href)) return inner;
      final labelRaw = inner.replaceAll(RegExp(r'<[^>]+>'), '').trim();
      final label = decodeHtmlEntities(labelRaw).trim();
      final shownRaw = hrefRaw.replaceFirst(RegExp(r'^mailto:', caseSensitive: false), '');
      final shown = decodeHtmlEntities(shownRaw);
      if (label.isEmpty || label == href || label == shown) return shownRaw;
      return '$labelRaw（$shownRaw）';
    });

String decodeHtmlEntities(String s) => s
    .replaceAllMapped(RegExp(r'&#[xX]([0-9a-fA-F]+);'), (m) => _charOf(int.tryParse(m[1]!, radix: 16)) ?? m[0]!)
    .replaceAllMapped(RegExp(r'&#(\d+);'), (m) => _charOf(int.tryParse(m[1]!)) ?? m[0]!)
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&yen;', '¥')
    .replaceAll('&copy;', '©')
    .replaceAll('&reg;', '®')
    .replaceAll('&hellip;', '…')
    .replaceAll('&mdash;', '—')
    .replaceAll('&ndash;', '–')
    .replaceAll('&rarr;', '→')
    .replaceAll('&apos;', "'")
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&amp;', '&');

String? _charOf(int? code) {
  if (code == null || code <= 0 || code > 0x10FFFF) return null;
  return String.fromCharCode(code);
}

/// HTMLメールから文字色・背景色の指定を外す（ダークモードで暗く表示するため）
/// style属性・<style>の中の color／background／background-color と、bgcolor・color 属性を取り除く
String stripHtmlColors(String html) {
  final colorDecl = RegExp(
      r'(?<![-\w])(background-color|background|color)\s*:\s*[^;"\x27}]*(;|(?=["\x27}]))',
      caseSensitive: false);
  var s = html.replaceAllMapped(
    RegExp(r'<style[^>]*>[\s\S]*?</style>', caseSensitive: false),
    (m) => m[0]!.replaceAll(colorDecl, ''),
  );
  s = s.replaceAllMapped(
    RegExp(r'(style\s*=\s*)("[^"]*"|\x27[^\x27]*\x27)', caseSensitive: false),
    (m) => '${m[1]}${m[2]!.replaceAll(colorDecl, '')}',
  );
  s = s.replaceAllMapped(
    RegExp(r'<[a-zA-Z][^>]*>'),
    (m) => m[0]!.replaceAll(
        RegExp(r'\s(bgcolor|color)\s*=\s*("[^"]*"|\x27[^\x27]*\x27|[^\s>]+)', caseSensitive: false), ''),
  );
  return s;
}

// ---- 予定のメモ欄（Googleカレンダーの description。テキストか、パソコンで書式を付けたときは HTML）----

final _htmlTag = RegExp(
  r'<(br|p|div|span|b|i|u|s|a|strong|em|ul|ol|li|h\d|table|tr|td|font|blockquote|hr)\b[^>]*>',
  caseSensitive: false,
);

/// 予定のメモ欄が HTML（書式付き）か
bool looksLikeHtml(String s) => _htmlTag.hasMatch(s);

/// 予定のメモ欄を文字にする（一覧・AI・変更画面用）。HTML でなければそのまま。
/// 箇条書きは「・」の行にする。[keepLinks] なら、リンクを「文字（https://…）」で残す
String eventNoteText(String? note, {bool keepLinks = false}) {
  final n = (note ?? '').trim();
  if (!looksLikeHtml(n)) return n;
  final s = n
      .replaceAll(RegExp(r'<(ul|ol)\b[^>]*>', caseSensitive: false), '<br>')
      .replaceAll(RegExp(r'<li\b[^>]*>', caseSensitive: false), '・');
  return htmlToText(s, keepLinks: keepLinks);
}
