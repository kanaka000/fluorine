import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/task_store.dart';
import '../services/claude_service.dart';
import 'add_sheets.dart';
import 'ai_prompt.dart';
import 'general_ai.dart';
import 'timed_snack.dart';
import '../services/errors.dart';

const _week = ['月', '火', '水', '木', '金', '土', '日'];

/// 期限を「11/20（金）」のような文字にする
String formatDue(DateTime d, {bool withYear = false}) =>
    '${withYear ? '${d.year}/' : ''}${d.month}/${d.day}（${_week[d.weekday - 1]}）';

/// 一覧に表示するタスク（設定で完了したタスクを隠す）。AIに渡す番号もこの順
List<TaskItem> visibleTasks() {
  final all = taskStore.tasks;
  return appSettings.showCompletedTasks ? all : all.where((t) => !t.done).toList();
}

const taskAiHint = '例：明日までに見積書を送るを追加／期限が近いタスクは？／見積書のタスクを完了にして／明日の予定は？';
const taskDetailAiHint = '例：期限を金曜に変えて／完了にして／やることを細かく分けてメモにして／このタスクを削除して';

/// 確認ダイアログを出してからタスクを削除する。削除したら true
Future<bool> confirmDeleteTask(BuildContext context, TaskItem task) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('タスクを削除しますか？'),
      content: Text('「${task.title}」'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('やめる')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('削除')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await taskStore.remove(task);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('削除できませんでした：${friendlyError(e)}')));
    return false;
  }
  if (context.mounted && appSettings.showSavedNotice) showTimedSnack(context, 'タスクを削除しました');
  return true;
}

/// 確認ダイアログを出してからタスクを完了にする
Future<void> confirmCompleteTask(BuildContext context, TaskItem task) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('タスクを完了にしますか？'),
      content: Text('「${task.title}」'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('やめる')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('完了にする')),
      ],
    ),
  );
  if (ok != true) return;
  await taskStore.toggle(task);
  if (context.mounted && appSettings.showSavedNotice && task.done) {
    showTimedSnack(context, 'タスクを完了にしました');
  }
}

/// タスクのAIボタンの処理。[selected] があればそのタスクを対象にする（詳細画面）。
/// 選んでいるタスクを削除したら [onDeleted] を呼ぶ
Future<void> runTaskAi(
  BuildContext context,
  String instruction, {
  TaskItem? selected,
  required void Function(bool busy) setBusy,
  VoidCallback? onDeleted,
}) async {
  setBusy(true);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text('AIが考えています…（$instruction）'),
    duration: const Duration(seconds: 30),
  ));
  final list = visibleTasks(); // AIに渡す一覧（番号はこの順）
  AiResult result;
  try {
    result = await ClaudeService.askAboutTasks(instruction: instruction, tasks: list, selected: selected);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    setBusy(false);
    messenger.showSnackBar(SnackBar(content: Text('AIに頼めませんでした：${friendlyError(e)}')));
    return;
  }
  messenger.hideCurrentSnackBar();
  setBusy(false);
  if (!context.mounted) return;

  /// 番号からタスクを決める（番号がなければ選んでいるタスク）
  // 番号がないときは選んでいるタスク。範囲外の番号は使わない（2026-11-18 B04：選んでいるタスクに勝手に置き換えない）
  TaskItem? target(int? n) => n == null ? selected : ((n >= 1 && n <= list.length) ? list[n - 1] : null);
  const notFound = 'どのタスクか分かりませんでした。タスクを開いてから頼むか、名前を入れて頼んでください。';

  // 選んでいるタスクから作るタスク・メモには、元のタスクの情報を付ける
  final source = selected == null ? null : 'タスク：${selected.title}';

  switch (result) {
    case AiTask r:
      showAddTaskSheet(context, null, title: r.title, due: r.due, note: r.note, source: source);
    case AiTaskUpdate r:
      final tu = target(r.number);
      if (tu == null) {
        showAiAnswer(context, instruction, notFound);
        return;
      }
      await showEditTaskSheet(context, tu, title: r.title, due: r.due, clearDue: r.clearDue, note: r.note);
    case AiTaskComplete r:
      final tc = target(r.number);
      if (tc == null) {
        showAiAnswer(context, instruction, notFound);
      } else if (tc.done) {
        showAiAnswer(context, instruction, '「${tc.title}」はもう完了しています。');
      } else {
        await confirmCompleteTask(context, tc);
      }
    case AiTaskDelete r:
      final td = target(r.number);
      if (td == null) {
        showAiAnswer(context, instruction, notFound);
        return;
      }
      final deleted = await confirmDeleteTask(context, td);
      if (deleted && selected != null && td.sameAs(selected)) onDeleted?.call();
    case AiMemo r:
      showAddMemoSheet(context, null, title: r.title, body: r.body, source: source);
    case AiReply r:
      showAiAnswer(context, instruction, r.body);
    case AiEvent r:
      await openNewEventFromAi(context, r);
    case AiNewMail r:
      await openNewMailFromAi(context, r);
    case AiAnswer r:
      showAiAnswer(context, instruction, r.text);
    case AiDeleteEvent _ || AiMemoUpdate _ || AiMemoDelete _:
      showAiAnswer(context, instruction, '予定やメモの変更は、それぞれの画面から頼んでください。');
  }
}
