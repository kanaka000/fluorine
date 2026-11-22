import 'package:material_ui/material_ui.dart';

import 'confirm_dialog.dart';
import '../data/app_settings.dart';
import '../data/memo_store.dart';
import '../services/claude_service.dart';
import 'add_sheets.dart';
import 'ai_common.dart';
import 'ai_prompt.dart';
import 'link_ai.dart';
import 'open_mail_ai.dart';
import 'timed_snack.dart';

const memoAiHint = '例：買い物リストのメモを作って／会議のメモはどれ？／買い物リストに牛乳を足して';
const memoDetailAiHint = '例：要点を箇条書きにして／やることをタスクにして／このメモを要約して／土曜の買い物の予定につないで／元のメールを表示して／このメモを削除して';

/// 日時を「11/16 9:05」のような文字にする
String formatMemoTime(DateTime d) {
  final now = DateTime.now();
  final hm = '${d.hour}:${d.minute.toString().padLeft(2, '0')}';
  if (DateUtils.isSameDay(d, now)) return '今日 $hm';
  return d.year == now.year ? '${d.month}/${d.day} $hm' : '${d.year}/${d.month}/${d.day}';
}

/// 確認ダイアログを出してからメモを削除する。削除したら true
Future<bool> confirmDeleteMemo(BuildContext context, Memo memo) async {
  final ok = await askConfirm(context, title: 'メモを削除しますか？', message: '「${memo.title}」', okLabel: '削除');
  if (!ok || !context.mounted) return false;
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
  final list = memoStore.memos; // AIに渡す一覧（番号はこの順）
  final result = await askAiWithStatus(context, instruction, setBusy: setBusy, ask: () => ClaudeService.askAboutMemos(instruction: instruction, memos: list, selected: selected));
  if (result == null || !context.mounted) return;

  /// 番号からメモを決める（番号がなければ選んでいるメモ）
  // 番号がないときは選んでいるメモ。範囲外の番号は使わない（2026-11-18 B04：選んでいるメモに勝手に置き換えない）
  Memo? target(int? n) => n == null ? selected : ((n >= 1 && n <= list.length) ? list[n - 1] : null);
  const notFound = 'どのメモか分かりませんでした。メモを開いてから頼むか、タイトルを入れて頼んでください。';

  // 選んでいるメモから作るタスク・メモには、元のメモのタイトルを付ける
  final source = selected == null ? null : 'メモ：${selected.title}';

  switch (result) {
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
    case AiLink r when selected != null:
      await runLinkAi(context, r, memo: selected);
    case AiOpenMail r when selected != null:
      await openMailFromAi(context, instruction, r, memo: selected);
    default:
      await handleCommonAiResult(context, instruction, result, source: source, openHint: 'メモ');
  }
}
