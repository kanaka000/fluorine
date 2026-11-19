import 'package:flutter/material.dart';

import '../confirm_dialog.dart';
import '../../data/link_lines.dart';
import '../../data/memo_store.dart';
import '../../data/models.dart';
import '../../screens/memo_detail_screen.dart';
import '../../services/errors.dart';
import '../memo_markdown.dart';
import '../timed_snack.dart';

// 予定・タスクの詳細画面の「リンクしたメモ」とメモの選択（2026-11-19 の整理で memo_link_section.dart から分けた）

final _checked = RegExp(r'^(?:\s*>)*\s*(?:[-*+]|\d+[.)])\s+\[[xX]\]');

/// メモのチェックの数（済み・全部）
({int done, int total}) memoCheckProgress(String body) {
  final total = countCheckboxes(body);
  if (total == 0) return (done: 0, total: 0);
  var inFence = false;
  var done = 0;
  for (final l in body.split('\n')) {
    if (RegExp(r'^\s*(```|~~~)').hasMatch(l)) {
      inFence = !inFence;
    } else if (!inFence && _checked.hasMatch(l)) {
      done++;
    }
  }
  return (done: done, total: total);
}

/// 予定・タスクの詳細画面の「リンクしたメモ」（カードと「メモをリンク」ボタン）。
/// [onChanged] でリンクの一覧を保存する（Googleに送る。失敗したら例外）
class MemoLinkSection extends StatefulWidget {
  const MemoLinkSection({super.key, required this.links, required this.onChanged});

  final List<MemoLinkRef> links;
  final Future<void> Function(List<MemoLinkRef> links) onChanged;

  @override
  State<MemoLinkSection> createState() => _MemoLinkSectionState();
}

class _MemoLinkSectionState extends State<MemoLinkSection> {
  bool _saving = false;

  Future<void> _save(List<MemoLinkRef> links, String done) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onChanged(links);
      if (mounted) showTimedSnack(context, done);
    } catch (e) {
      if (mounted) showTimedSnack(context, '保存できませんでした：${friendlyError(e)}');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _add() async {
    final linked = {for (final l in widget.links) resolveMemoLink(l)?.id ?? l.id};
    final memo = await pickMemo(context, exclude: linked);
    if (memo == null || !mounted) return;
    await _save([...widget.links, MemoLinkRef(memo.id, memoTitleOf(memo))], 'メモをリンクしました');
  }

  Future<void> _unlink(MemoLinkRef ref) async {
    final ok = await askConfirm(context, title: 'リンクを外しますか？', message: '「${ref.title}」へのリンクを外します。メモそのものは消えません。', okLabel: '外す');
    if (!ok || !mounted) return;
    await _save(widget.links.where((l) => !identical(l, ref)).toList(), 'リンクを外しました');
  }

  void _open(Memo m) {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => MemoDetailScreen(memo: m)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: memoStore,
      builder: (context, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.links.isNotEmpty) ...[
            const Divider(height: 24),
            Text('リンクしたメモ', style: theme.textTheme.titleSmall),
            const SizedBox(height: 8),
            for (final ref in widget.links) _card(ref, theme),
          ],
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: _saving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('メモをリンク'),
              onPressed: _saving ? null : _add,
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(MemoLinkRef ref, ThemeData theme) {
    final m = resolveMemoLink(ref);
    final scheme = theme.colorScheme;
    if (m == null) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8),
        color: scheme.surfaceContainerHighest,
        child: ListTile(
          leading: Icon(Icons.link_off, color: scheme.outline),
          title: Text('メモが見つかりません', style: TextStyle(color: scheme.outline)),
          subtitle: Text(ref.title, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: TextButton(onPressed: _saving ? null : () => _unlink(ref), child: const Text('外す')),
        ),
      );
    }
    final color = MemoColor.of(m.colorKey)?.cardColor(theme.brightness, scheme.surface);
    final p = memoCheckProgress(m.body);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: color ?? scheme.surfaceContainerHigh,
      child: ListTile(
        leading: const Icon(Icons.sticky_note_2_outlined),
        title: Text(memoTitleOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (p.total > 0) Text('☑ ${p.done}/${p.total}', style: theme.textTheme.bodyMedium),
            const SizedBox(width: 4),
            const Icon(Icons.chevron_right),
          ],
        ),
        onTap: () => _open(m),
        onLongPress: _saving ? null : () => _unlink(ref),
      ),
    );
  }
}

/// メモの一覧から1つ選ぶ（[exclude] のIDは出さない）。選ばなければ null
Future<Memo?> pickMemo(BuildContext context, {Set<String> exclude = const {}}) {
  return showModalBottomSheet<Memo>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      final theme = Theme.of(c);
      final memos = memoStore.memos.where((m) => !exclude.contains(m.id)).toList();
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text('リンクするメモを選ぶ', style: theme.textTheme.titleMedium),
              ),
              if (memos.isEmpty)
                Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    memoStore.memos.isEmpty ? 'メモがありません。メモのタブで作ってください' : 'リンクできるメモはもうありません',
                    style: TextStyle(color: theme.colorScheme.outline),
                  ),
                )
              else
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      for (final m in memos)
                        ListTile(
                          leading: CircleAvatar(
                            radius: 10,
                            backgroundColor: MemoColor.of(m.colorKey)
                                    ?.cardColor(theme.brightness, theme.colorScheme.surface) ??
                                theme.colorScheme.surfaceContainerHighest,
                          ),
                          title: Text(memoTitleOf(m), maxLines: 1, overflow: TextOverflow.ellipsis),
                          onTap: () => Navigator.pop(c, m),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    },
  );
}

// ============ メモ・メールの側：リンクしている予定・タスク（2026-11-19） ============
