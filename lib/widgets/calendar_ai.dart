import 'package:material_ui/material_ui.dart';

import 'confirm_dialog.dart';
import '../data/app_settings.dart';
import '../data/calendar_store.dart';
import '../services/claude_service.dart';
import 'add_sheets.dart';
import 'ai_common.dart';
import 'ai_prompt.dart';
import 'link_ai.dart';
import 'timed_snack.dart';
import '../services/errors.dart';
import '../util/date_text.dart';

String _day(DateTime d) => '${d.month}/${d.day}（${weekdayJa(d)}）';
String _hm(DateTime d) => hhmm(d);

/// 予定の日時を「11/17（月） 10:00〜11:00」のような文字にする
String formatEventWhen(CalendarEvent e, {bool withYear = false}) {
  String day(DateTime d) => withYear ? '${d.year}/${_day(d)}' : _day(d);
  if (e.allDay) {
    final last = e.lastDay;
    return DateUtils.isSameDay(e.start, last) ? '${day(e.start)} 終日' : '${day(e.start)}〜${day(last)} 終日';
  }
  if (DateUtils.isSameDay(e.start, e.end)) return '${day(e.start)} ${_hm(e.start)}〜${_hm(e.end)}';
  return '${day(e.start)} ${_hm(e.start)}〜${day(e.end)} ${_hm(e.end)}';
}

/// 確認ダイアログを出してから予定を削除する。削除したら true
Future<bool> confirmDeleteEvent(
  BuildContext context,
  CalendarEvent event, {
  String title = '予定を削除しますか？',
}) async {
  final ok = await askConfirm(context, title: title, message: '「${event.title}」\n${formatEventWhen(event)}'
          '${event.recurring ? '\n\n繰り返しの予定です。この回だけを削除します。' : ''}', okLabel: '削除');
  if (!ok || !context.mounted) return false;
  final messenger = ScaffoldMessenger.of(context);
  try {
    await calendarStore.remove(event);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('削除できませんでした：${friendlyError(e)}')));
    return false;
  }
  if (context.mounted && appSettings.showSavedNotice) showTimedSnack(context, '予定を削除しました');
  return true;
}

/// これからの予定（AIに渡す一覧。終わっていないもの）
List<CalendarEvent> _upcoming() {
  final now = DateTime.now();
  return calendarStore.events.where((e) => e.end.isAfter(now)).toList();
}

const calendarAiHint = '例：明日の15時から歯医者を入れて／明日の歯医者を消して／今週の予定は？／期限が近いタスクは？';
const eventAiHint = '例：15時からに変更して／緑にして／場所を渋谷駅にして／準備することをタスクにして／買い物リストのメモをつないで／この予定を削除して';

/// カレンダーのAIボタンの処理。
/// [selected] があればその予定を対象にする（詳細画面）。変更の画面で保存したら [onUpdated] を呼ぶ
Future<void> runCalendarAi(
  BuildContext context,
  String instruction, {
  CalendarEvent? selected,
  required void Function(bool busy) setBusy,
  void Function(CalendarEvent updated)? onUpdated,
  VoidCallback? onDeleted,
}) async {
  final upcoming = _upcoming(); // AIに渡す一覧（削除の番号はこの順）
  final result = await askAiWithStatus(context, instruction, setBusy: setBusy, ask: () => ClaudeService.askAboutCalendar(
      instruction: instruction,
      upcoming: upcoming,
      selected: selected,
    ));
  if (result == null || !context.mounted) return;

  // 選んでいる予定から作るタスク・メモには、元の予定の情報を付ける
  final source = selected == null ? null : '予定：${selected.title}\n${formatEventWhen(selected, withYear: true)}';

  // 結果に合わせて、入力済みの画面を開く（保存は自分で押す）
  switch (result) {
    case AiEvent r when r.update && selected != null:
      final saved = await showEditEventSheet(
        context,
        selected,
        title: r.title,
        date: r.date,
        time: r.time,
        endDate: r.endDate,
        endTime: r.endTime,
        allDay: r.allDay ?? (r.time != null ? false : null),
        location: r.location,
        note: r.note,
        color: r.color,
      );
      if (saved != null) onUpdated?.call(saved);
    case AiEvent r:
      // 日時を変える場合の元の予定（0 は選んでいる予定、1〜 は一覧の番号）
      final rn = r.replaces;
      final original = rn == null
          ? null
          : (rn == 0 ? selected : ((rn >= 1 && rn <= upcoming.length) ? upcoming[rn - 1] : null));
      final saved = await showAddEventSheet(
        context,
        null,
        title: r.title,
        date: r.date,
        time: r.time,
        endDate: r.endDate,
        endTime: r.endTime,
        allDay: (r.allDay ?? false) || r.time == null,
        location: r.location,
        note: r.note,
        color: r.color,
      );
      // 新しい予定を保存したら、元の予定を消すか確認する（押すのは自分）
      if (saved == null || original == null || !context.mounted) return;
      final deleted = await confirmDeleteEvent(context, original, title: '元の予定を削除しますか？');
      if (deleted && identical(original, selected)) onDeleted?.call();
    case AiDeleteEvent r:
      // 削除はしない。どの予定かを決めて、確認ダイアログを出す（押すのは自分）
      final n = r.number;
      final target = selected ?? ((n != null && n >= 1 && n <= upcoming.length) ? upcoming[n - 1] : null);
      if (target == null) {
        showAiAnswer(context, instruction, 'どの予定を削除するか分かりませんでした。予定を開いてから頼むか、日付や名前を入れて頼んでください。');
        return;
      }
      final deleted = await confirmDeleteEvent(context, target);
      if (deleted && selected != null) onDeleted?.call();
    case AiLink r when selected != null:
      final saved = await runLinkAi(context, r, event: selected);
      if (saved != null) onUpdated?.call(saved);
    default:
      await handleCommonAiResult(context, instruction, result,
          source: source, openHint: '予定', fromEvent: selected);
  }
}
