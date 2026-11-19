import 'package:flutter/material.dart';

import 'confirm_dialog.dart';
import '../data/app_settings.dart';
import '../data/task_store.dart';
import '../services/claude_service.dart';
import 'add_sheets.dart';
import 'ai_common.dart';
import 'ai_prompt.dart';
import 'link_ai.dart';
import 'timed_snack.dart';
import '../services/errors.dart';
import '../util/date_text.dart';

/// 期限を「11/20（金）」のような文字にする
String formatDue(DateTime d, {bool withYear = false}) =>
    '${withYear ? '${d.year}/' : ''}${d.month}/${d.day}（${weekdayJa(d)}）';

/// 一覧に表示するタスク（設定で完了したタスクを隠す）。AIに渡す番号もこの順
List<TaskItem> visibleTasks() {
  final all = taskStore.tasks;
  return appSettings.showCompletedTasks ? all : all.where((t) => !t.done).toList();
}

const taskAiHint = '例：明日までに見積書を送るを追加／期限が近いタスクは？／見積書のタスクを完了にして／明日の予定は？';
const taskDetailAiHint = '例：期限を金曜に変えて／完了にして／やることを細かく分けてメモにして／○○さんのメールをリンクして／このタスクを削除して';

/// 確認ダイアログを出してからタスクを削除する。削除したら true
Future<bool> confirmDeleteTask(BuildContext context, TaskItem task) async {
  final ok = await askConfirm(context, title: 'タスクを削除しますか？', message: '「${task.title}」', okLabel: '削除');
  if (!ok || !context.mounted) return false;
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
  final ok = await askConfirm(context, title: 'タスクを完了にしますか？', message: '「${task.title}」', okLabel: '完了にする');
  if (!ok) return;
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
  final list = visibleTasks(); // AIに渡す一覧（番号はこの順）
  final result = await askAiWithStatus(context, instruction, setBusy: setBusy, ask: () => ClaudeService.askAboutTasks(instruction: instruction, tasks: list, selected: selected));
  if (result == null || !context.mounted) return;

  /// 番号からタスクを決める（番号がなければ選んでいるタスク）
  // 番号がないときは選んでいるタスク。範囲外の番号は使わない（2026-11-18 B04：選んでいるタスクに勝手に置き換えない）
  TaskItem? target(int? n) => n == null ? selected : ((n >= 1 && n <= list.length) ? list[n - 1] : null);
  const notFound = 'どのタスクか分かりませんでした。タスクを開いてから頼むか、名前を入れて頼んでください。';

  // 選んでいるタスクから作るタスク・メモには、元のタスクの情報を付ける
  final source = selected == null ? null : 'タスク：${selected.title}';

  switch (result) {
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
    case AiLink r when selected != null:
      await runLinkAi(context, r, task: selected);
    default:
      await handleCommonAiResult(context, instruction, result, source: source, openHint: 'タスク');
  }
}
