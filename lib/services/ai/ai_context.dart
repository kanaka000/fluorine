import 'package:material_ui/material_ui.dart';

import '../../data/app_settings.dart';
import '../../data/calendar_store.dart';
import '../../data/mail_store.dart';
import '../../data/memo_store.dart';
import '../../data/models.dart';
import '../../data/task_store.dart';
import '../../util/date_text.dart';

// AIに渡す今日の日付・参考情報・予定やタスクの書き方（2026-11-19 の整理で分けた）

/// AIに渡す参考情報（ほかのタブの内容）。番号は付けない（変更・削除には使わないため）
String aiReferenceInfo({
  bool events = true,
  bool tasks = true,
  bool memos = true,
  bool mails = true,
}) {
  // 設定でオンのときだけ、ほかのタブの内容を送る（2026-11-18 A06）
  if (!appSettings.aiCrossTab) return '';
  String head(String text, int max) {
    final t = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return t.length > max ? '${t.substring(0, max)}…' : t;
  }

  final buf = StringBuffer()..writeln('## 参考情報（ほかのタブの内容）');
  if (events) {
    final now = DateTime.now();
    final list = calendarStore.events.where((e) => e.end.isAfter(now)).take(80).toList();
    buf
      ..writeln('### これからの予定')
      ..writeln(list.isEmpty ? '（なし）' : list.map((e) => '- ${describeEvent(e)}').join('\n'))
      ..writeln();
  }
  if (tasks) {
    final list = taskStore.tasks.where((t) => !t.done).take(80).toList();
    buf
      ..writeln('### 未完了のタスク')
      ..writeln(list.isEmpty ? '（なし）' : list.map((t) => '- ${describeTask(t)}').join('\n'))
      ..writeln();
  }
  if (memos) {
    // 参考情報は今までどおり更新の新しいもの40件（一覧は自分で並べた順になったため、ここで並べ直す）
    final list = ([...memoStore.memos]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt))).take(40).toList();
    buf
      ..writeln('### メモ（新しい順）')
      ..writeln(list.isEmpty ? '（なし）' : list.map((m) => '- ${m.title}：${head(m.body, 80)}').join('\n'))
      ..writeln();
  }
  if (mails) {
    final list = mailStore.recentMails(100);
    String when(DateTime d) => '${d.month}/${d.day}（${weekdayJa(d)}）${pad2(d.hour)}:${pad2(d.minute)}';
    buf
      ..writeln('### 受信メール（新しい順・最新${list.length}通。冒頭は本文の最初の部分）')
      ..writeln(list.isEmpty
          ? '（なし）'
          : list
              .map((m) => '- ${when(m.receivedAt)} ${m.senderName} <${m.senderAddress}>'
                  '${m.isRead ? '' : '［未読］'} 件名：${m.subject}／冒頭：${head(m.body, 120)}')
              .join('\n'))
      ..writeln();
  }
  return buf.toString();
}

/// 日本の祝日（今日から約1年分）。個人の情報ではないので、「✨にほかのタブの内容も見せる」に関係なく渡す（2026-11-24 の22）
String aiHolidayInfo() {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final list = calendarStore.holidaysBetween(today, DateTime(today.year + 1, today.month, today.day));
  if (list.isEmpty) return '';
  String d(DateTime x) => '${x.year}-${pad2(x.month)}-${pad2(x.day)}（${weekdayJa(x)}）';
  return '\n\n【日本の祝日（法律で決まった祝日・振替休日。今日から1年分。設定に関係なくいつも渡しています）】\n'
      '${list.map((e) => '- ${d(e.key)} ${e.value}').join('\n')}\n'
      '祝日・休み・連休について聞かれたら、この一覧と土日をもとに answer で答えてください'
      '（連休は、土日と祝日が続く日をまとめて「○月○日（土）〜○日（月）の3連休」のように）。'
      '予定を作るときに「祝日」「次の連休」などと言われたら、この一覧で日付を決めてください。';
}

String aiTodayText() {
  final now = DateTime.now();
  return '${now.year}-${pad2(now.month)}-${pad2(now.day)}（${weekdayJa(now)}曜日）'
      ' ${pad2(now.hour)}:${pad2(now.minute)}';
}

/// 予定1件を、AIに渡す1行の文字にする
String describeEvent(CalendarEvent e) {
  String d(DateTime x) => '${x.year}-${pad2(x.month)}-${pad2(x.day)}（${weekdayJa(x)}）';
  String t(DateTime x) => '${pad2(x.hour)}:${pad2(x.minute)}';
  final String when;
  if (e.allDay) {
    final last = e.lastDay;
    when = DateUtils.isSameDay(e.start, last) ? '${d(e.start)} 終日' : '${d(e.start)}〜${d(last)} 終日';
  } else if (DateUtils.isSameDay(e.start, e.end)) {
    when = '${d(e.start)} ${t(e.start)}〜${t(e.end)}';
  } else {
    when = '${d(e.start)} ${t(e.start)}〜${d(e.end)} ${t(e.end)}';
  }
  final place = (e.location ?? '').trim().isEmpty ? '' : '（場所：${e.location!.trim()}）';
  final color = e.color == null ? '' : '［色：${e.color!.label}］'; // 「黄色の予定は？」に答えられるように（2026-11-24 の24）
  return '$when ${e.title}$place$color';
}

/// タスク1件を、AIに渡す1行の文字にする
String describeTask(TaskItem t) {
  final due = t.due == null
      ? ''
      : '（期限：${t.due!.year}-${pad2(t.due!.month)}-${pad2(t.due!.day)}（${weekdayJa(t.due!)}））';
  final color = t.color == null ? '' : '［色：${t.color!.label}］';
  return '${t.title}$due$color${t.done ? '［完了］' : ''}';
}

/// 一覧の最後の予定までの日数（AIに「どこまでの予定か」を伝えるため）
String aiRangeText(List<CalendarEvent> upcoming) {
  if (upcoming.isEmpty) return '';
  final last = upcoming.last.start;
  return '${last.month}月${last.day}日まで';
}
