import 'package:material_ui/material_ui.dart';
// ignore: deprecated_member_use
import 'package:flutter/material.dart' as legacy show Theme;
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';

import 'safe_link.dart';

/// メモのMarkdown対応（2026-11-17）
/// - 詳細画面：Markdownを整えた見た目で表示。チェックボックスはタップで ✓ を付け外し
/// - 一覧のカード：記号を外した文字（markdownToPlain）
/// - 変更画面：文字のまま編集し、記号ボタン（MarkdownToolbar）で行の先頭に記号を入れる

/// チェックボックスの行（「- [ ] 」「1. [x] 」「> - [ ] 」など）
final _taskLine = RegExp(r'^((?:\s*>)*\s*(?:[-*+]|\d+[.)])\s+\[)([ xX])(\])');
final _fence = RegExp(r'^\s*(```|~~~)');

/// 本文の [index] 番目（0から）のチェックボックスの ✓ を付け外しした本文を返す。
/// コードブロックの中は数えない（表示のチェックボックスと同じ順番になるように）
String toggleCheckbox(String body, int index) {
  final lines = body.split('\n');
  var inFence = false;
  var n = 0;
  for (var i = 0; i < lines.length; i++) {
    final l = lines[i];
    if (_fence.hasMatch(l)) {
      inFence = !inFence;
      continue;
    }
    if (inFence) continue;
    final m = _taskLine.firstMatch(l);
    if (m == null) continue;
    if (n == index) {
      lines[i] = '${m.group(1)}${m.group(2) == ' ' ? 'x' : ' '}${m.group(3)}${l.substring(m.end)}';
      return lines.join('\n');
    }
    n++;
  }
  return body;
}

/// 本文にあるチェックボックスの数
int countCheckboxes(String body) {
  var inFence = false;
  var n = 0;
  for (final l in body.split('\n')) {
    if (_fence.hasMatch(l)) {
      inFence = !inFence;
    } else if (!inFence && _taskLine.hasMatch(l)) {
      n++;
    }
  }
  return n;
}

/// 一覧のカード用に、Markdownの記号を外した文字にする（チェックは ☐／☑、箇条書きは ・）
String markdownToPlain(String body) {
  final out = <String>[];
  for (var l in body.split('\n')) {
    l = l
        .replaceFirst(RegExp(r'^(\s*>)+\s?'), '')
        .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
        .replaceFirstMapped(RegExp(r'^(\s*)[-*+]\s+\[[xX]\]\s+'), (m) => '${m[1]}☑ ')
        .replaceFirstMapped(RegExp(r'^(\s*)[-*+]\s+\[ \]\s+'), (m) => '${m[1]}☐ ')
        .replaceFirstMapped(RegExp(r'^(\s*)[-*+]\s+'), (m) => '${m[1]}・')
        .replaceFirst(RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$'), '')
        .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]+\)'), (m) => m[1]!)
        .replaceAll(RegExp(r'\*\*|__|~~|`'), '');
    if (l.trim().isNotEmpty) out.add(l);
  }
  return out.join('\n');
}

/// LINEなどに貼る・メールの本文にする文字（2026-11-17）。
/// 見出し・強調・引用の記号を外し、チェックボックスと箇条書きは「- 項目」にそろえる。
/// リンクは「文字（URL）」にしてURLを残す。空行は残す（3行以上続く空行は1つに）
String markdownToShareText(String body) {
  final out = <String>[];
  var inFence = false;
  for (var l in body.replaceAll('\r\n', '\n').split('\n')) {
    if (_fence.hasMatch(l)) {
      inFence = !inFence;
      continue; // コードの区切り（```）は外す。中身は残す
    }
    if (!inFence) {
      l = l
          .replaceFirst(RegExp(r'^(\s*>)+\s?'), '')
          .replaceFirst(RegExp(r'^\s*#{1,6}\s+'), '')
          .replaceFirstMapped(RegExp(r'^(\s*)(?:[-*+]|\d+[.)])\s+\[[ xX]\]\s+'), (m) => '${m[1]}- ')
          .replaceFirstMapped(RegExp(r'^(\s*)[*+]\s+'), (m) => '${m[1]}- ')
          .replaceFirst(RegExp(r'^\s*(-{3,}|\*{3,}|_{3,})\s*$'), '')
          .replaceAllMapped(RegExp(r'\[([^\]]+)\]\(([^)]+)\)'), (m) => '${m[1]}（${m[2]}）')
          .replaceAll(RegExp(r'\*\*|__|~~|`'), '');
    }
    out.add(l);
  }
  return out.join('\n').replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
}

/// メモの本文をMarkdownとして表示する。[onToggle] を渡すと、チェックボックスをタップできる
class MemoMarkdown extends StatelessWidget {
  const MemoMarkdown({super.key, required this.body, this.onToggle});

  final String body;

  /// [index] 番目のチェックボックスがタップされた
  final void Function(int index)? onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = theme.textTheme.bodyLarge?.copyWith(height: 1.6);
    // チェックボックスは表示の順に作られるので、その順番で何番目かを決める
    // （表示し直したときもずれないよう、数で割った余りを使う）
    final total = countCheckboxes(body);
    var built = 0;
    return MarkdownBody(
      data: body,
      selectable: true,
      // 1回の改行もそのまま改行として表示する（今までのメモの見た目を保つ）
      softLineBreak: true,
      // flutter_markdown_plus はまだ旧 material の ThemeData を受け取るので、旧 material のテーマを渡す
      // （MaterialUiCompatibilityBridge が中身を用意している。2026-11-22 の18）
      styleSheet: MarkdownStyleSheet.fromTheme(legacy.Theme.of(context)).copyWith(
        p: text,
        listBullet: text,
        h1: theme.textTheme.headlineSmall,
        h2: theme.textTheme.titleLarge,
        h3: theme.textTheme.titleMedium,
        blockquoteDecoration: BoxDecoration(
          border: Border(left: BorderSide(color: theme.colorScheme.outline, width: 3)),
        ),
        blockquotePadding: const EdgeInsets.only(left: 12),
        code: theme.textTheme.bodyMedium?.copyWith(fontFamily: 'monospace'),
      ),
      // リンクは安全なものだけ開く（https はそのまま、http は確認、mailto は新規メール。2026-11-18）
      onTapLink: (text, href, title) => openSafeLink(context, href),
      // 画像は読み込まない（外部に情報が出ないように。2026-11-18 セキュリティ対策 A05）。代わりに文字で出す
      // ignore: deprecated_member_use
      imageBuilder: (uri, title, alt) => _ImagePlaceholder(alt: alt, host: uri.host),
      checkboxBuilder: (checked) {
        final index = total == 0 ? 0 : built++ % total;
        final icon = Icon(
          checked ? Icons.check_box : Icons.check_box_outline_blank,
          size: 22,
          color: checked ? theme.colorScheme.primary : theme.colorScheme.outline,
        );
        if (onToggle == null) return Padding(padding: const EdgeInsets.only(right: 6), child: icon);
        return InkResponse(
          onTap: () => onToggle!(index),
          radius: 20,
          child: Padding(padding: const EdgeInsets.only(right: 6), child: icon),
        );
      },
    );
  }
}

/// 行の先頭の記号（見出し・チェック・箇条書き・番号）
final _linePrefix = RegExp(r'^(#{1,6} |[-*+] \[[ xX]\] |[-*+] |\d+\. )');

/// カーソルのある行（選んでいるときは、その範囲の行すべて）の先頭に [prefix] を付ける。
/// ほかの記号が付いていれば置き換え、すべての行に同じ記号が付いていれば外す
TextEditingValue toggleLinePrefix(TextEditingValue value, String prefix) {
  final text = value.text;
  var start = value.selection.start;
  var end = value.selection.end;
  if (start < 0 || end < 0) start = end = text.length;
  final a = start == 0 ? 0 : text.lastIndexOf('\n', start - 1) + 1;
  var b = text.indexOf('\n', end);
  if (b < 0) b = text.length;
  final lines = text.substring(a, b).split('\n');
  final all = lines.every((l) => _linePrefix.firstMatch(l)?.group(0) == prefix);
  final changed = lines.map((l) {
    final m = _linePrefix.firstMatch(l);
    final rest = m == null ? l : l.substring(m.end);
    return all ? rest : '$prefix$rest';
  }).join('\n');
  final newText = text.substring(0, a) + changed + text.substring(b);
  return TextEditingValue(
    text: newText,
    selection: TextSelection.collapsed(offset: a + changed.length),
  );
}

/// 本文の入力欄の下に並べる記号ボタン（見出し・箇条書き・チェック）
class MarkdownToolbar extends StatelessWidget {
  const MarkdownToolbar({super.key, required this.controller, this.focusNode});

  final TextEditingController controller;
  final FocusNode? focusNode;

  void _apply(String prefix) {
    controller.value = toggleLinePrefix(controller.value, prefix);
    focusNode?.requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    Widget button(IconData icon, String label, String prefix) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(
            avatar: Icon(icon, size: 18),
            label: Text(label),
            visualDensity: VisualDensity.compact,
            onPressed: () => _apply(prefix),
          ),
        );
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          button(Icons.title, '見出し', '## '),
          button(Icons.format_list_bulleted, '箇条書き', '- '),
          button(Icons.check_box_outlined, 'チェック', '- [ ] '),
        ],
      ),
    );
  }
}

/// メモの画像の代わりに出す文字（画像は読み込まない）
class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.alt, required this.host});

  final String? alt;
  final String host;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = (alt ?? '').trim();
    return Text(
      '🖼 画像（表示しません）${name.isEmpty ? '' : '：$name'}${host.isEmpty ? '' : '（$host）'}',
      style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline),
    );
  }
}
