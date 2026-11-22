import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../data/memo_store.dart';
import '../services/google_auth.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/header_actions.dart';
import '../widgets/memo_ai.dart';
import '../widgets/links/links.dart';
import '../widgets/memo_markdown.dart';
import '../widgets/timed_snack.dart';
import 'reply_screen.dart';

/// メモの詳細（メモの一覧でタップすると開く）
class MemoDetailScreen extends StatefulWidget {
  const MemoDetailScreen({super.key, required this.memo});

  final Memo memo;

  @override
  State<MemoDetailScreen> createState() => _MemoDetailScreenState();
}

class _MemoDetailScreenState extends State<MemoDetailScreen> {
  bool _aiBusy = false;
  bool _deleting = false;

  /// 最新の状態（変更されていればそれを使う）
  Memo get _memo => memoStore.find(widget.memo.id) ?? widget.memo;

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: memoDetailAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: memoDetailAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runMemoAi(
      context,
      instruction,
      selected: _memo,
      setBusy: (b) {
        if (mounted) setState(() => _aiBusy = b);
      },
      onDeleted: () {
        if (mounted) Navigator.of(context).pop(); // 削除したので一覧に戻る
      },
    );
  }

  /// 詳細画面でチェックボックスをタップしたら、その場で ✓ を付け外しして保存する
  Future<void> _toggleCheck(int index) async {
    final m = _memo;
    final body = toggleCheckbox(m.body, index);
    if (body == m.body) return;
    await memoStore.update(m.copyWith(body: body));
  }

  /// 本文をクリップボードにコピーする（記号を外した文字。LINEなどに貼れる）
  Future<void> _copy() async {
    final text = markdownToShareText(_memo.body);
    if (text.isEmpty) {
      showTimedSnack(context, '本文がありません');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTimedSnack(context, '本文をコピーしました');
  }

  /// このメモから新しいメールを作る（件名＝タイトル、本文＝記号を外した本文、宛先は空欄）
  void _mail() {
    if (!googleAuth.signedIn) {
      showTimedSnack(context, 'メールを作るには、Googleにログインしてください');
      return;
    }
    final m = _memo;
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReplyScreen(
        mode: ComposeMode.newMail,
        initialSubject: m.title,
        initialDraft: markdownToShareText(m.body),
      ),
    ));
  }

  Future<void> _edit() async {
    await showEditMemoSheet(context, _memo);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final deleted = await confirmDeleteMemo(context, _memo);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
    } else {
      setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: memoStore,
      builder: (context, _) {
        final theme = Theme.of(context);
        final m = _memo;
        final bg = m.color?.cardColor(theme.brightness, theme.colorScheme.surface);
        // 色はタイトルの部分だけに付ける（画面全体だとダークモードで本文が見にくいため。2026-11-17）
        return Scaffold(
          appBar: AppBar(
            title: const Text('メモ'),
            actions: [
              AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
              // 右上のゴミ箱はなくした（削除は本文の下のボタンと一覧のスワイプで。2026-11-17）
              IconButton(icon: const Icon(Icons.copy_outlined), tooltip: '本文をコピー', onPressed: _copy),
              IconButton(icon: const Icon(Icons.mail_outline), tooltip: 'メールを作る', onPressed: _mail),
              IconButton(icon: const Icon(Icons.edit_outlined), tooltip: '変更', onPressed: _edit),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Container(
                padding: bg == null ? EdgeInsets.zero : const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: bg == null
                    ? null
                    : BoxDecoration(color: bg, borderRadius: BorderRadius.circular(12)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(m.title, style: theme.textTheme.headlineSmall),
                    const SizedBox(height: 4),
                    Text(
                      '作成 ${formatMemoTime(m.createdAt)}'
                      '${m.updatedAt.isAfter(m.createdAt.add(const Duration(seconds: 1))) ? '・更新 ${formatMemoTime(m.updatedAt)}' : ''}',
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline),
                    ),
                  ],
                ),
              ),
              const Divider(height: 24),
              if (m.body.trim().isEmpty)
                Text('（本文なし）', style: theme.textTheme.bodyLarge)
              else
                MemoMarkdown(body: m.body, onToggle: _toggleCheck),
              MemoBacklinkSection(memo: m),
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('変更'),
                      onPressed: _edit,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.delete_outline),
                      label: const Text('削除'),
                      onPressed: _deleting ? null : _delete,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text('右上の ✨ で、このメモについてAIに頼めます（タップ＝音声、長押し＝文字）',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        );
      },
    );
  }
}
