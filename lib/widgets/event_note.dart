import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_widget_from_html_core/flutter_widget_from_html_core.dart';

import '../util/html_text.dart';
import 'safe_link.dart';

// 予定の詳細画面のメモ欄（2026-11-22 の11）。
// 書式付き（HTML）なら、メールと同じ部品で書式を再現する（ダークモードでは色を外す。画像は読み込まない）。
// 書式なしなら文字のまま出し、https://… などを下線付きのリンクにする。どちらのリンクも openSafeLink で開く

class EventNoteView extends StatelessWidget {
  const EventNoteView({super.key, required this.note});

  final String note;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final style = theme.textTheme.bodyLarge?.copyWith(height: 1.6, color: theme.colorScheme.onSurface);
    if (!looksLikeHtml(note)) return _LinkifiedText(text: note, style: style);
    return HtmlWidget(
      dark ? stripHtmlColors(note) : note,
      textStyle: style,
      onTapUrl: (url) => openSafeLink(context, url),
      // 暗い背景でもリンクが読める色にする
      customStylesBuilder: dark ? (element) => element.localName == 'a' ? {'color': '#8AB4F8'} : null : null,
      // 画像は読み込まない（外部に情報が出ないように。メモと同じ考え方）
      customWidgetBuilder: (element) => element.localName == 'img' ? const SizedBox.shrink() : null,
    );
  }
}

/// 文字の中の https://・http:// を見つける（後ろの句読点・かっこは外す）
final _url = RegExp(r'''https?://[^\s<>"'（）「」『』【】、。]+''');
final _urlTail = RegExp(r'[.,!?)\]]+$');

class _LinkifiedText extends StatefulWidget {
  const _LinkifiedText({required this.text, required this.style});

  final String text;
  final TextStyle? style;

  @override
  State<_LinkifiedText> createState() => _LinkifiedTextState();
}

class _LinkifiedTextState extends State<_LinkifiedText> {
  final _recognizers = <TapGestureRecognizer>[];

  @override
  void dispose() {
    _disposeRecognizers();
    super.dispose();
  }

  void _disposeRecognizers() {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
  }

  @override
  Widget build(BuildContext context) {
    _disposeRecognizers();
    final theme = Theme.of(context);
    final linkStyle = TextStyle(
      color: theme.brightness == Brightness.dark ? const Color(0xFF8AB4F8) : theme.colorScheme.primary,
      decoration: TextDecoration.underline,
    );
    final text = widget.text;
    final spans = <InlineSpan>[];
    var pos = 0;
    for (final m in _url.allMatches(text)) {
      final url = m[0]!.replaceFirst(_urlTail, '');
      if (url.length <= 'https://'.length) continue;
      if (m.start > pos) spans.add(TextSpan(text: text.substring(pos, m.start)));
      final r = TapGestureRecognizer()..onTap = () => openSafeLink(context, url);
      _recognizers.add(r);
      spans.add(TextSpan(text: url, style: linkStyle, recognizer: r));
      pos = m.start + url.length;
    }
    if (pos < text.length) spans.add(TextSpan(text: text.substring(pos)));
    return SelectableText.rich(TextSpan(style: widget.style, children: spans));
  }
}
