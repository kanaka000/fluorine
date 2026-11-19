import 'package:flutter/material.dart';

import '../../data/app_nav.dart';
import '../../data/app_settings.dart';
import '../../data/memo_store.dart';
import '../../data/models.dart';
import '../../services/claude_service.dart';
import '../ai_prompt.dart';
import '../header_actions.dart';
import '../memo_markdown.dart';
import '../timed_snack.dart';
import '../../services/errors.dart';
import 'sheet_common.dart';

// メモの追加・変更シート

/// メモの追加。[mail] があればメールから作る。[source] は元の予定・タスクなどの情報（本文の下に付ける）。
/// 保存したメモを返す
Future<Memo?> showAddMemoSheet(
  BuildContext context,
  Mail? mail, {
  String? title,
  String? body,
  String? source,
}) async {
  final initialTitle = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : (mail == null ? '' : cleanMailSubject(mail.subject));
  final b = body?.trim() ?? '';
  final from = mail != null ? mailSourceNote(mail) : (source?.trim() ?? '');
  final initialBody = from.isEmpty ? b : '$b\n\n---\n$from';
  final now = DateTime.now();
  final saved = await showFormSheet<Memo>(
    context,
    _MemoForm(
      draft: Memo(title: initialTitle, body: initialBody, createdAt: now),
      aiSource: mail == null ? source : mailForAi(mail),
    ),
  );
  if (saved != null && context.mounted) {
    showSavedSnack(context, 'メモに追加しました', Tabs.memo);
  }
  return saved;
}

/// メモの変更。渡した項目だけを差し替えた状態で開く（AIボタンから使う）。変更後のメモを返す
Future<Memo?> showEditMemoSheet(BuildContext context, Memo memo, {String? title, String? body}) async {
  final draft = Memo(
    id: memo.id,
    title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : memo.title,
    body: body ?? memo.body,
    createdAt: memo.createdAt,
    updatedAt: memo.updatedAt,
    colorKey: memo.colorKey,
  );
  final saved = await showFormSheet<Memo>(context, _MemoForm(draft: draft, editing: memo));
  if (saved != null && context.mounted && appSettings.showSavedNotice) {
    showTimedSnack(context, 'メモを変更しました');
  }
  return saved;
}

/// メモの色を選ぶ丸いボタンの列（左端は「指定なし」）
class MemoColorPicker extends StatelessWidget {
  const MemoColorPicker({super.key, required this.selected, required this.onChanged});

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

class _MemoForm extends StatefulWidget {
  const _MemoForm({required this.draft, this.editing, this.aiSource});

  /// 入力欄の初期値
  final Memo draft;

  /// 変更するときの元のメモ（追加なら null）
  final Memo? editing;

  /// フォームのAIボタンに渡す元の情報（メール本文など）
  final String? aiSource;

  @override
  State<_MemoForm> createState() => _MemoFormState();
}

class _MemoFormState extends State<_MemoForm> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _body = TextEditingController(text: widget.draft.body);
  final _bodyFocus = FocusNode();
  late String? _color = widget.draft.colorKey;

  bool _saving = false;
  bool _aiBusy = false;
  String? _error;

  /// AIが入れる前の入力欄（「元に戻す」用）
  ({String title, String body})? _beforeAi;

  @override
  void dispose() {
    _title.dispose();
    _body.dispose();
    _bodyFocus.dispose();
    super.dispose();
  }

  // ---------------- AIボタン（入力欄を埋める） ----------------

  static const _aiHint = '例：要点を見出し付きで整理して／もっと短く／買うものをチェックリストにして／タイトルを付けて';

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: _aiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _runAi(String instruction) async {
    if (_aiBusy) return;
    setState(() {
      _aiBusy = true;
      _error = null;
    });
    try {
      final r = await ClaudeService.fillMemo(
        instruction: instruction,
        title: _title.text,
        body: _body.text,
        source: widget.aiSource,
      );
      if (!mounted) return;
      setState(() {
        _beforeAi = (title: _title.text, body: _body.text);
        if (r.title.isNotEmpty) _title.text = r.title;
        if (r.body.isNotEmpty) _body.text = r.body;
        _aiBusy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _aiBusy = false;
          _error = 'AIに頼めませんでした：${friendlyError(e)}';
        });
      }
    }
  }

  void _undoAi() {
    final b = _beforeAi;
    if (b == null) return;
    setState(() {
      _title.text = b.title;
      _body.text = b.body;
      _beforeAi = null;
    });
  }

  Future<void> _save() async {
    if (_saving) return;
    var title = _title.text.trim();
    final body = _body.text.trim();
    if (title.isEmpty && body.isEmpty) {
      setState(() => _error = 'タイトルか本文を入れてください');
      return;
    }
    // タイトルが空なら本文の1行目をタイトルにする
    if (title.isEmpty) {
      final first = body.split('\n').first.trim();
      title = first.length > 30 ? '${first.substring(0, 30)}…' : first;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final editing = widget.editing;
      final Memo saved;
      if (editing == null) {
        saved = await memoStore.add(Memo(
          title: title,
          body: body,
          createdAt: DateTime.now(),
          colorKey: _color,
        ));
      } else {
        saved = await memoStore.update(
          editing.copyWith(title: title, body: body, colorKey: _color, clearColor: _color == null),
        );
      }
      if (mounted) Navigator.of(context).pop(saved);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = '保存できませんでした：${friendlyError(e)}';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final editing = widget.editing != null;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(editing ? '📝 メモを変更' : '📝 メモに追加', style: theme.textTheme.titleLarge),
            ),
            AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
          ],
        ),
        Text('✨ タップで話して入力、長押しで文字で頼めます',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 12),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'タイトル')),
        const SizedBox(height: 12),
        Text('色', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        MemoColorPicker(selected: _color, onChanged: (c) => setState(() => _color = c)),
        const SizedBox(height: 8),
        TextField(
          controller: _body,
          focusNode: _bodyFocus,
          minLines: 5,
          maxLines: 12,
          decoration: const InputDecoration(
            labelText: '本文',
            alignLabelWithHint: true,
            helperText: 'Markdownで書けます（# 見出し、- 箇条書き、- [ ] チェック）',
          ),
        ),
        const SizedBox(height: 6),
        // カーソルのある行（選んだ行）の先頭に記号を入れる。もう一度押すと外す
        MarkdownToolbar(controller: _body, focusNode: _bodyFocus),
        if (_beforeAi != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              icon: const Icon(Icons.undo),
              label: const Text('AIが入れる前に戻す'),
              onPressed: _undoAi,
            ),
          ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: (_saving || _aiBusy) ? null : _save,
          child: Text(_saving ? '保存中…' : '保存'),
        ),
      ],
    );
  }
}
