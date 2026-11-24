import 'package:material_ui/material_ui.dart';

import '../data/models.dart';

// メモ・予定・タスクの色の共通部品（2026-11-24 の24）。色はメモと同じ9色＋指定なし（MemoColor）。
// 予定・タスクの色はメモ欄の隠し行 `🎨 色：黄〔color:yellow〕` に保存する（data/link_lines.dart）

/// 色を選ぶ丸いボタンの列（左端は「指定なし」）。メモ・予定・タスクで共通（2026-11-24 の24で memo_sheet から移した）
class ItemColorPicker extends StatelessWidget {
  const ItemColorPicker({super.key, required this.selected, required this.onChanged});

  final String? selected;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    Widget dot({required String? key, required Color? color, required String label}) {
      final isSel = selected == key;
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Tooltip(
          message: label,
          child: InkResponse(
            onTap: () => onChanged(key),
            radius: 22,
            child: Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: color ?? theme.colorScheme.surface,
                shape: BoxShape.circle,
                border: Border.all(
                  color: isSel ? theme.colorScheme.primary : theme.colorScheme.outlineVariant,
                  width: isSel ? 3 : 1,
                ),
              ),
              child: color == null
                  ? Icon(Icons.format_color_reset_outlined, size: 18, color: theme.colorScheme.outline)
                  : (isSel ? const Icon(Icons.check, size: 18, color: Colors.black54) : null),
            ),
          ),
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          dot(key: null, color: null, label: '指定なし'),
          for (final c in MemoColor.all)
            dot(key: c.key, color: c.cardColor(theme.brightness, theme.colorScheme.surface), label: c.label),
        ],
      ),
    );
  }
}

/// 色付きのカード（予定・タスクの一覧の行）。色がなければ中身をそのまま返す
class ItemColorCard extends StatelessWidget {
  const ItemColorCard({super.key, required this.color, required this.child});

  final MemoColor? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = color;
    if (c == null) return child;
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      color: c.cardColor(theme.brightness, theme.colorScheme.surface),
      elevation: 0,
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

/// 詳細画面のタイトル部分の色の帯（メモの詳細画面と同じ形）。色がなければ中身をそのまま返す
class ItemColorBand extends StatelessWidget {
  const ItemColorBand({super.key, required this.color, required this.child});

  final MemoColor? color;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final c = color;
    if (c == null) return child;
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: c.cardColor(theme.brightness, theme.colorScheme.surface),
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }
}
