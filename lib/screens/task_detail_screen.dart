import 'package:material_ui/material_ui.dart';

import '../data/task_store.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/header_actions.dart';
import '../widgets/item_color.dart';
import '../widgets/links/links.dart';
import '../widgets/task_ai.dart';

/// タスクの詳細（タスクの一覧でタップすると開く）
class TaskDetailScreen extends StatefulWidget {
  const TaskDetailScreen({super.key, required this.task});

  final TaskItem task;

  @override
  State<TaskDetailScreen> createState() => _TaskDetailScreenState();
}

class _TaskDetailScreenState extends State<TaskDetailScreen> {
  late TaskItem _task = widget.task;
  bool _aiBusy = false;
  bool _deleting = false;

  /// 一覧側で変わった最新の状態（変更・完了の切り替え）
  TaskItem get _current => taskStore.find(_task) ?? _task;

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: taskDetailAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: taskDetailAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runTaskAi(
      context,
      instruction,
      selected: _current,
      setBusy: (b) {
        if (mounted) setState(() => _aiBusy = b);
      },
      onDeleted: () {
        if (mounted) Navigator.of(context).pop(); // 削除したので一覧に戻る
      },
    );
  }

  Future<void> _edit() async {
    final saved = await showEditTaskSheet(context, _current);
    if (saved != null && mounted) setState(() => _task = saved);
  }

  /// つないだメモを保存する（Googleのメモ欄の最後の行。失敗したら例外）
  Future<void> _saveLinks(List<MemoLinkRef> links) async {
    final t = _current;
    final saved = await taskStore.update(t, t.copyWith(memoLinks: links));
    if (mounted) setState(() => _task = saved);
  }

  /// つないだメールを保存する（2026-11-19）
  Future<void> _saveMailLinks(List<MailLinkRef> links) async {
    final t = _current;
    final saved = await taskStore.update(t, t.copyWith(mailLinks: links));
    if (mounted) setState(() => _task = saved);
  }

  /// つないだ予定を保存する（2026-11-24 の25）
  Future<void> _saveEventLinks(List<EventLinkRef> links) async {
    final t = _current;
    final saved = await taskStore.update(t, t.copyWith(eventLinks: links));
    if (mounted) setState(() => _task = saved);
  }

  Future<void> _delete() async {
    if (_deleting) return;
    setState(() => _deleting = true);
    final deleted = await confirmDeleteTask(context, _current);
    if (!mounted) return;
    if (deleted) {
      Navigator.of(context).pop();
    } else {
      setState(() => _deleting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: taskStore,
      builder: (context, _) {
        final t = _current;
        final note = (t.note ?? '').trim();
        final today = DateUtils.dateOnly(DateTime.now());
        final overdue = !t.done && t.due != null && t.due!.isBefore(today);
        return Scaffold(
          appBar: AppBar(
            title: const Text('タスク'),
            actions: [
              AiButton(onTap: _aiByVoice, onLongPress: _aiByText, busy: _aiBusy),
              IconButton(icon: const Icon(Icons.edit_outlined), tooltip: '変更', onPressed: _edit),
              IconButton(
                icon: const Icon(Icons.delete_outline),
                tooltip: '削除',
                onPressed: _deleting ? null : _delete,
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // 色の付いたタスクは、名前と期限の部分だけをその色の帯に（メモの詳細画面と同じ。2026-11-24 の24）
              ItemColorBand(
                color: t.color,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SelectableText(
                      t.title,
                      style: theme.textTheme.headlineSmall?.copyWith(
                        decoration: t.done ? TextDecoration.lineThrough : null,
                        color: t.done ? theme.colorScheme.outline : null,
                      ),
                    ),
                    const SizedBox(height: 12),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.flag_outlined, color: overdue ? theme.colorScheme.error : null),
                      title: Text(
                        t.due == null ? '期限なし' : '期限：${formatDue(t.due!, withYear: true)}',
                        style: overdue ? TextStyle(color: theme.colorScheme.error) : null,
                      ),
                      subtitle: overdue ? const Text('期限が過ぎています') : null,
                    ),
                  ],
                ),
              ),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(t.done ? '完了' : '未完了'),
                value: t.done,
                onChanged: (_) => taskStore.toggle(t),
              ),
              if (note.isNotEmpty) ...[
                const Divider(height: 24),
                SelectableText(note, style: theme.textTheme.bodyLarge?.copyWith(height: 1.6)),
              ],
              MemoLinkSection(links: t.memoLinks, onChanged: _saveLinks),
              MailLinkSection(links: t.mailLinks, onChanged: _saveMailLinks),
              EventLinkSection(links: t.eventLinks, onChanged: _saveEventLinks),
              const SizedBox(height: 16),
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
              Text('右上の ✨ で、このタスクについてAIに頼めます（タップ＝音声、長押し＝文字）',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
            ],
          ),
        );
      },
    );
  }
}
