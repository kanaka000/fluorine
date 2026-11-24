import 'package:material_ui/material_ui.dart';

import '../../data/app_nav.dart';
import '../../data/app_settings.dart';
import '../../data/models.dart';
import '../../data/task_store.dart';
import '../../services/claude_service.dart';
import '../ai_prompt.dart';
import '../header_actions.dart';
import '../timed_snack.dart';
import '../../services/errors.dart';
import 'sheet_common.dart';
import '../item_color.dart';

// タスクの追加・変更シート

/// タスクの追加。[mail] があればメールから作る。[source] は元の予定などの情報（メモ欄に付ける）。
/// 保存したタスクを返す
Future<TaskItem?> showAddTaskSheet(
  BuildContext context,
  Mail? mail, {
  String? title,
  DateTime? due,
  String? note,
  String? source,
  String? color,
  CalendarEvent? event,
}) async {
  final initialTitle = (title?.trim().isNotEmpty ?? false)
      ? title!.trim()
      : (mail == null ? '' : cleanMailSubject(mail.subject));
  final initialNote = mail == null ? joinSourceNote(note, source) : noteWithMail(note, mail);
  final saved = await showFormSheet<TaskItem>(
    context,
    _TaskForm(
      draft: TaskItem(
        title: initialTitle,
        due: due,
        note: initialNote,
        // メールから作ったタスクには、元のメールをリンクする（2026-11-19）
        mailLinks: mail == null ? const [] : [MailLinkRef(mail.id, mail.subject)],
        colorKey: MemoColor.of(color)?.key, // ✨で色を言われたとき（2026-11-24 の24）
        // 予定の詳細画面の✨から作ったタスクには、元の予定をリンクする（2026-11-24 の25）
        eventLinks: event?.id == null ? const [] : [EventLinkRef(event!.id!, event.title)],
      ),
      aiSource: mail == null ? source : mailForAi(mail),
    ),
  );
  if (saved != null && context.mounted) {
    showSavedSnack(context, 'タスクに追加しました', Tabs.task);
  }
  return saved;
}

/// タスクの変更。渡した項目だけを差し替えた状態で開く（AIボタンから使う）。変更後のタスクを返す。
/// [color] は色の名前（MemoColor.key）、'none' なら色を外す、null なら今のまま
Future<TaskItem?> showEditTaskSheet(
  BuildContext context,
  TaskItem task, {
  String? title,
  DateTime? due,
  bool clearDue = false,
  String? note,
  String? color,
}) async {
  final draft = task.copyWith(
    title: (title?.trim().isNotEmpty ?? false) ? title!.trim() : null,
    due: due,
    clearDue: clearDue,
    note: note,
    colorKey: MemoColor.of(color)?.key,
    clearColor: color == 'none',
  );
  final saved = await showFormSheet<TaskItem>(context, _TaskForm(draft: draft, editing: task));
  if (saved != null && context.mounted && appSettings.showSavedNotice) {
    showTimedSnack(context, 'タスクを変更しました');
  }
  return saved;
}

class _TaskForm extends StatefulWidget {
  const _TaskForm({required this.draft, this.editing, this.aiSource});

  /// 入力欄の初期値
  final TaskItem draft;

  /// 変更するときの元のタスク（追加なら null）
  final TaskItem? editing;

  /// フォームのAIボタンに渡す元の情報（メール本文など）
  final String? aiSource;

  @override
  State<_TaskForm> createState() => _TaskFormState();
}

class _TaskFormState extends State<_TaskForm> {
  late final _title = TextEditingController(text: widget.draft.title);
  late final _note = TextEditingController(text: widget.draft.note ?? '');
  late DateTime? _due = widget.draft.due;
  late String? _color = widget.draft.colorKey; // カードの色（2026-11-24 の24。✨で色の名前を言えば変わる）

  bool _saving = false;
  bool _aiBusy = false;
  String? _error;

  /// AIが入れる前の入力欄（「元に戻す」用）
  ({String title, DateTime? due, String note, String? color})? _beforeAi;

  @override
  void dispose() {
    _title.dispose();
    _note.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final d = await showDatePicker(
      context: context,
      initialDate: _due ?? DateUtils.dateOnly(DateTime.now()),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (d != null) setState(() => _due = d);
  }

  // ---------------- AIボタン（入力欄を埋める） ----------------

  static const _aiHint = '例：期限は来週の金曜／見積書を送る、メモに金額を入れて／黄色にして／名前を短くして';

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
      final r = await ClaudeService.fillTask(
        instruction: instruction,
        title: _title.text,
        due: _due,
        note: _note.text,
        source: widget.aiSource,
      );
      if (!mounted) return;
      setState(() {
        _beforeAi = (title: _title.text, due: _due, note: _note.text, color: _color);
        if (r.title.isNotEmpty) _title.text = r.title;
        _due = r.due;
        _note.text = r.note;
        if (r.color != null) _color = r.color == 'none' ? null : r.color;
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
      _due = b.due;
      _note.text = b.note;
      _color = b.color;
      _beforeAi = null;
    });
  }

  Future<void> _save() async {
    final title = _title.text.trim();
    if (_saving) return;
    if (title.isEmpty) {
      setState(() => _error = 'やることを入れてください');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final base = widget.editing ?? widget.draft;
    final task = base.copyWith(
      title: title,
      due: _due,
      clearDue: _due == null,
      note: _note.text.trim(),
      colorKey: _color,
      clearColor: _color == null,
    );
    try {
      final editing = widget.editing;
      final saved =
          editing == null ? await taskStore.add(task) : await taskStore.update(editing, task);
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
              child: Text(editing ? '✅ タスクを変更' : '✅ タスクに追加', style: theme.textTheme.titleLarge),
            ),
            AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
          ],
        ),
        Text('✨ タップで話して入力、長押しで文字で頼めます',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
        const SizedBox(height: 12),
        TextField(controller: _title, decoration: const InputDecoration(labelText: 'やること')),
        const SizedBox(height: 12),
        ItemColorPicker(selected: _color, onChanged: (c) => setState(() => _color = c)),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.flag_outlined),
          title: Text(_due == null ? '期限なし' : '期限：${sheetDateLabel(_due!)}'),
          trailing: _due == null
              ? null
              : IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => _due = null)),
          onTap: _pickDue,
        ),
        TextField(
          controller: _note,
          minLines: 2,
          maxLines: 5,
          decoration: const InputDecoration(labelText: 'メモ'),
        ),
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

