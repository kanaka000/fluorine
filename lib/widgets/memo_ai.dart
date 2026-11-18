import 'package:flutter/material.dart';

import '../data/app_settings.dart';
import '../data/memo_store.dart';
import '../services/claude_service.dart';
import 'add_sheets.dart';
import 'ai_prompt.dart';
import 'general_ai.dart';
import 'timed_snack.dart';
import '../services/errors.dart';

const memoAiHint = '例：買い物リストのメモを作って／会議のメモはどれ？／買い物リストに牛乳を足して';
const memoDetailAiHint = '例：要点を箇条書きにして／やることをタスクにして／このメモを要約して／このメモを削除して';

/// 日時を「11/16 9:05」のような文字にする
String formatMemoTime(DateTime d) {
  final now = DateTime.now();
  final hm = '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  if (DateUtils.isSameDay(d, now)) return '今日 $hm';
  return d.year == now.year ? '${d.month}/${d.day} $hm' : '${d.year}/${d.month}/${d.day}';
}

/// 確認ダイアログを出してからメモを削除する。削除したら true
Future<bool> confirmDeleteMemo(BuildContext context, Memo memo) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('メモを削除しますか？'),
      content: Text('「${memo.title}」'),
      actions: [
        TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('やめる')),
        FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('削除')),
      ],
    ),
  );
  if (ok != true || !context.mounted) return false;
  await memoStore.remove(memo);
  if (context.mounted && appSettings.showSavedNotice) showTimedSnack(context, 'メモを削除しました');
  return true;
}

/// メモのAIボタンの処理。[selected] があればそのメモを対象にする（詳細画面）。
/// 選んでいるメモを削除したら [onDeleted] を呼ぶ
Future<void> runMemoAi(
  BuildContext context,
  String instruction, {
  Memo? selected,
  required void Function(bool busy) setBusy,
  VoidCallback? onDeleted,
}) async {
  setBusy(true);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text('AIが考えています…（$instruction）'),
    duration: const Duration(seconds: 30),
  ));
  final list = memoStore.memos; // AIに渡す一覧（番号はこの順）
  AiResult result;
  try {
    result = await ClaudeService.askAboutMemos(instruction: instruction, memos: list, selected: selected);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    setBusy(false);
    messenger.showSnackBar(SnackBar(content: Text('AIに頼めませんでした：${friendlyError(e)}')));
    return;
  }
  messenger.hideCurrentSnackBar();
  setBusy(false);
  if (!context.mounted) return;

  /// 番号からメモを決める（番号がなければ選んでいるメモ）
  // 番号がないときは選んでいるメモ。範囲外の番号は使わない（2026-11-18 B04：選んでいるメモに勝手に置き換えない）
  Memo? target(int? n) => n == null ? selected : ((n >= 1 && n <= list.length) ? list[n - 1] : null);
  const notFound = 'どのメモか分かりませんでした。メモを開いてから頼むか、タイトルを入れて頼んでください。';

  // 選んでいるメモから作るタスク・メモには、元のメモのタイトルを付ける
  final source = selected == null ? null : 'メモ：${selected.title}';

  switch (result) {
    case AiMemo r:
      showAddMemoSheet(context, null, title: r.title, body: r.body, source: source);
    case AiMemoUpdate r:
      final mu = target(r.number);
      if (mu == null) {
        showAiAnswer(context, instruction, notFound);
        return;
      }
      await showEditMemoSheet(context, mu, title: r.title, body: r.body);
    case AiMemoDelete r:
      final md = target(r.number);
      if (md == null) {
        showAiAnswer(context, instruction, notFound);
        return;
      }
      final deleted = await confirmDeleteMemo(context, md);
      if (deleted && selected != null && md.id == selected.id) onDeleted?.call();
    case AiTask r:
      showAddTaskSheet(context, null, title: r.title, due: r.due, note: r.note, source: source);
    case AiReply r:
      showAiAnswer(context, instruction, r.body);
    case AiEvent r:
      await openNewEventFromAi(context, r);
    case AiNewMail r:
      await openNewMailFromAi(context, r);
    case AiAnswer r:
      showAiAnswer(context, instruction, r.text);
    case AiDeleteEvent _ || AiTaskUpdate _ || AiTaskComplete _ || AiTaskDelete _:
      showAiAnswer(context, instruction, '予定やタスクの変更は、それぞれの画面から頼んでください。');
  }
}
