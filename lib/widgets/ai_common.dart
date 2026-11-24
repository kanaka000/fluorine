import 'package:material_ui/material_ui.dart';

import '../data/models.dart';
import '../data/task_store.dart';
import '../screens/settings_screen.dart';
import '../services/ai/api_key_store.dart';
import '../services/claude_service.dart';
import '../services/errors.dart';
import 'add_sheets.dart';
import 'ai_prompt.dart';
import 'general_ai.dart';
import 'timed_snack.dart';

// ✨の共通の流れ（2026-11-19 の整理で、5つの画面にあった同じ処理をまとめた）

/// ✨の頼みごとを送る。「AIが考えています…」を出し、終わったら消す。
/// 失敗したらお知らせを出して null。画面が閉じていても null
Future<AiResult?> askAiWithStatus(
  BuildContext context,
  String instruction, {
  required void Function(bool busy) setBusy,
  required Future<AiResult> Function() ask,
}) async {
  setBusy(true);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text('AIが考えています…（$instruction）'),
    duration: const Duration(seconds: 30),
  ));
  AiResult result;
  try {
    result = await ask();
  } catch (e) {
    messenger.hideCurrentSnackBar();
    setBusy(false);
    messenger.showSnackBar(SnackBar(
      content: Text('AIに頼めませんでした：${friendlyError(e)}'),
      // キーが使えなかったときは、入れ直す画面への近道を付ける（2026-11-23）
      action: apiKeyStore.invalid && context.mounted
          ? SnackBarAction(
              label: '設定を見る',
              onPressed: () {
                if (context.mounted) openApiKeySettings(context);
              },
            )
          : null,
    ));
    return null;
  }
  messenger.hideCurrentSnackBar();
  setBusy(false);
  return context.mounted ? result : null;
}

/// どの画面の✨でも同じに扱う結果。画面ごとに特別な扱いがある結果は、各画面の switch で先に処理して、
/// 残りをここに渡す（新しい結果の種類を足したら、まずここに足す）。
/// [mail]：メールの詳細画面から（作る予定・タスク・メモに元のメールの情報を付ける）。
/// [source]：元の予定・タスク・メモの情報（作るタスク・メモに付ける）。
/// [openHint]：リンクを頼まれたときの案内「○○を開いてから」。
/// [fromEvent]：予定の詳細画面から（作るタスクに、その予定を自動でリンクする。2026-11-24 の25）。
/// [fromTask]：タスクの詳細画面から（作った予定を、そのタスクに自動でリンクする。2026-11-24 の25）
Future<void> handleCommonAiResult(
  BuildContext context,
  String instruction,
  AiResult result, {
  Mail? mail,
  String? source,
  String openHint = 'メール・予定・タスク・メモ',
  CalendarEvent? fromEvent,
  TaskItem? fromTask,
}) async {
  switch (result) {
    case AiEvent r:
      final saved = await openNewEventFromAi(context, r, mail: mail);
      if (saved != null && saved.id != null && fromTask != null && context.mounted) {
        await _linkNewEventToTask(context, fromTask, saved);
      }
    case AiTask r:
      showAddTaskSheet(context, mail,
          title: r.title, due: r.due, note: r.note, source: source, color: r.color, event: fromEvent);
    case AiMemo r:
      showAddMemoSheet(context, mail, title: r.title, body: r.body, source: source);
    case AiNewMail r:
      await openNewMailFromAi(context, r);
    case AiReply r:
      showAiAnswer(context, instruction, r.body);
    case AiAnswer r:
      showAiAnswer(context, instruction, r.text);
    case AiDeleteEvent _ || AiTaskUpdate _ || AiTaskComplete _ || AiTaskDelete _ || AiMemoUpdate _ || AiMemoDelete _:
      showAiAnswer(context, instruction, '予定・タスク・メモの変更や削除は、それぞれの画面の✨から頼んでください。');
    case AiLink _:
      showAiAnswer(context, instruction, 'リンクは、$openHintを開いてから✨で頼んでください。');
    case AiMailSearch _:
      showAiAnswer(context, instruction, 'メールを探すのは、メールのトップ画面の✨から頼んでください。');
    case AiOpenMail _:
      showAiAnswer(context, instruction, 'メールを開くのは、メモを開いてから✨で頼んでください。');
  }
}

/// タスクの詳細画面の✨で作った予定を、そのタスクにリンクする（2026-11-24 の25）
Future<void> _linkNewEventToTask(BuildContext context, TaskItem task, CalendarEvent event) async {
  final t = taskStore.find(task) ?? task;
  if (t.eventLinks.any((l) => l.id == event.id)) return;
  try {
    await taskStore.update(t, t.copyWith(eventLinks: [...t.eventLinks, EventLinkRef(event.id!, event.title)]));
  } catch (e) {
    if (context.mounted) showTimedSnack(context, 'タスクへのリンクを保存できませんでした：${friendlyError(e)}');
  }
}
