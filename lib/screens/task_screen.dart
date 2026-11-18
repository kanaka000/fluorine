import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/task_store.dart';
import '../services/google_auth.dart';
import '../widgets/add_sheets.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/header_actions.dart';
import '../widgets/sign_in_prompt.dart';
import '../widgets/swipe_delete.dart';
import '../widgets/sync_status.dart';
import '../widgets/task_ai.dart';
import 'settings_screen.dart';
import 'task_detail_screen.dart';

/// タスク（ログイン後はGoogle ToDoリストのデフォルトのリスト）
class TaskScreen extends StatefulWidget {
  const TaskScreen({super.key});

  @override
  State<TaskScreen> createState() => _TaskScreenState();
}

class _TaskScreenState extends State<TaskScreen> {
  bool _aiBusy = false;

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: taskAiHint);
    if (text != null && mounted) _runAi(text);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: taskAiHint);
    if (text != null && mounted) _runAi(text);
  }

  void _runAi(String instruction) {
    if (_aiBusy) return;
    runTaskAi(context, instruction, setBusy: (b) {
      if (mounted) setState(() => _aiBusy = b);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListenableBuilder(
      listenable: Listenable.merge([taskStore, appSettings, googleAuth]),
      builder: (context, _) {
        final tasks = visibleTasks();
        final hiddenDone = appSettings.showCompletedTasks ? 0 : taskStore.tasks.where((t) => t.done).length;
        final today = DateUtils.dateOnly(DateTime.now());
        return Scaffold(
          appBar: AppBar(
            title: const Text('タスク'),
            actions: headerActions(
              // ログアウト中は✨を出さない
              onAi: googleAuth.signedIn ? _aiByVoice : null,
              onAiLongPress: _aiByText,
              aiBusy: _aiBusy,
              menuItems: [
                if (googleAuth.signedIn)
                  HeaderMenuItem(
                    icon: Icons.refresh,
                    label: '再読み込み',
                    onTap: () => taskStore.reload(prompt: true),
                  ),
                HeaderMenuItem(
                  icon: Icons.settings_outlined,
                  label: 'タスクの設定',
                  dividerBefore: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const TaskSettingsScreen()),
                  ),
                ),
                HeaderMenuItem(
                  icon: Icons.tune,
                  label: '全体の設定',
                  onTap: () => openGeneralSettings(context),
                ),
              ],
            ),
          ),
          // ログアウト中は＋を出さず、一覧の代わりにログインの案内
          floatingActionButton: !googleAuth.signedIn
              ? null
              : FloatingActionButton(
                  tooltip: 'タスクを追加',
                  onPressed: () => showAddTaskSheet(context, null),
                  child: const Icon(Icons.add),
                ),
          body: !googleAuth.signedIn
              ? const SignInPrompt(
                  icon: Icons.task_alt,
                  message: 'Googleでログインすると、\nGoogle ToDoリストのタスクが表示されます',
                )
              : Column(
            children: [
              SyncStatus(
                loading: taskStore.loading,
                error: taskStore.error,
              ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => taskStore.reload(),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 88),
                    children: [
                      if (tasks.isEmpty)
                        const Padding(
                          padding: EdgeInsets.all(32),
                          child: Center(
                              child: Text('タスクはありません\n（下に引っ張ると読み込みます）', textAlign: TextAlign.center)),
                        ),
                      // 左右どちらかにスワイプすると削除（「元に戻す」で作り直す）
                      for (final t in tasks)
                        SwipeToDelete(
                          itemKey: ObjectKey(t),
                          message: 'タスクを削除しました',
                          onDelete: () => taskStore.remove(t),
                          onUndo: () => taskStore.restore(t),
                          child: _taskTile(t, theme, today),
                        ),
                      if (hiddenDone > 0)
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('完了したタスク $hiddenDone 件を非表示にしています（≡ → タスクの設定）',
                              textAlign: TextAlign.center,
                              style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.outline)),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _taskTile(TaskItem t, ThemeData theme, DateTime today) {
    final note = (t.note ?? '').trim();
    final lines = [
      if (t.due != null) '期限：${formatDue(t.due!)}',
      if (note.isNotEmpty) note.split('\n').first,
    ];
    final overdue = !t.done && t.due != null && t.due!.isBefore(today);
    return ListTile(
      leading: Checkbox(value: t.done, onChanged: (_) => taskStore.toggle(t)),
      title: Text(t.title,
          style: t.done ? TextStyle(decoration: TextDecoration.lineThrough, color: theme.colorScheme.outline) : null),
      subtitle: lines.isEmpty
          ? null
          : Text(lines.join('\n'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: overdue ? TextStyle(color: theme.colorScheme.error) : null),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => TaskDetailScreen(task: t)),
      ),
    );
  }
}
