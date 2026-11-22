import 'package:material_ui/material_ui.dart';

import 'confirm_dialog.dart';

import '../data/calendar_store.dart';
import '../data/mail_store.dart';
import '../data/link_lines.dart';
import '../data/memo_store.dart';
import '../data/models.dart';
import '../data/task_store.dart';
import '../services/claude_service.dart';
import '../services/errors.dart';
import 'calendar_ai.dart';
import 'format.dart';
import 'task_ai.dart';
import 'timed_snack.dart';

/// ✨の「リンクを付ける・外す」（2026-11-19）。
/// AIは相手の手がかり（keyword・sender・date）を返すだけで、探すのはここ（端末の中）。
/// 1件なら確認ダイアログ、いくつもあれば選ぶ画面、なければお知らせ。押すのは自分。
///
/// 開いている項目は [event]・[task]・[memo]・[mail] のどれか1つ。
/// 予定を書き換えたときは、その新しい予定を返す（予定の詳細画面の表示を直すため）
Future<CalendarEvent?> runLinkAi(
  BuildContext context,
  AiLink r, {
  CalendarEvent? event,
  TaskItem? task,
  Memo? memo,
  Mail? mail,
}) async {
  try {
    if (event != null || task != null) {
      return await _fromHolder(context, r, event: event, task: task);
    }
    if (memo != null || mail != null) {
      await _fromSource(context, r, memo: memo, mail: mail);
    }
  } catch (e) {
    if (context.mounted) showTimedSnack(context, '保存できませんでした：${friendlyError(e)}');
  }
  return null;
}

String _norm(String s) => s.toLowerCase().replaceAll(RegExp(r'\s+'), '');

/// 手がかりの言葉が [texts] のどれかに含まれるか（空なら何でも当てはまる）
bool _hit(String? keyword, List<String> texts) {
  final k = _norm(keyword ?? '');
  if (k.isEmpty) return true;
  return texts.any((t) => _norm(t).contains(k));
}

bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

/// 予定がその日にかかっているか
bool _eventOn(CalendarEvent e, DateTime day) {
  final s = DateTime(day.year, day.month, day.day);
  final t = DateTime(s.year, s.month, s.day + 1);
  return e.start.isBefore(t) && (e.end.isAfter(s) || _sameDay(e.start, s));
}

/// 候補が1つなら確認、いくつもあれば選ぶ。決めた候補（やめたら null）を返す
Future<T?> _choose<T>(
  BuildContext context, {
  required List<T> items,
  required String Function(T) label,
  required String? Function(T) sub,
  required String notFound,
  required String Function(T) confirmText,
  required bool unlink,
  required String pickTitle,
}) async {
  if (items.isEmpty) {
    showTimedSnack(context, notFound);
    return null;
  }
  if (items.length == 1) {
    final x = items.first;
    final ok = await askConfirm(context, title: unlink ? 'リンクを外しますか？' : 'リンクしますか？', message: confirmText(x), okLabel: unlink ? '外す' : 'リンクする');
    return ok ? x : null;
  }
  // いくつもあるときは選ぶ（選ぶこと自体が決定）
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (c) {
      final theme = Theme.of(c);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.of(c).size.height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(pickTitle, style: theme.textTheme.titleMedium),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final x in items)
                      ListTile(
                        leading: Icon(unlink ? Icons.link_off : Icons.link),
                        title: Text(label(x), maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: sub(x) == null ? null : Text(sub(x)!, maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.pop(c, x),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

// ---------------- 予定・タスクを開いているとき：相手はメモかメール ----------------

Future<CalendarEvent?> _fromHolder(BuildContext context, AiLink r, {CalendarEvent? event, TaskItem? task}) async {
  final holderName = event?.title ?? task!.title;
  final memoLinks = event?.memoLinks ?? task!.memoLinks;
  final mailLinks = event?.mailLinks ?? task!.mailLinks;
  final kind = event != null ? '予定' : 'タスク';

  Future<CalendarEvent?> save({List<MemoLinkRef>? memos, List<MailLinkRef>? mails}) async {
    if (event != null) {
      final saved = await calendarStore.update(event, event.copyWith(memoLinks: memos, mailLinks: mails));
      return saved;
    }
    final t = taskStore.find(task!) ?? task;
    await taskStore.update(t, t.copyWith(memoLinks: memos, mailLinks: mails));
    return null;
  }

  if (r.target == LinkTarget.memo) {
    if (r.unlink) {
      final items = memoLinks.where((l) {
        final m = resolveMemoLink(l);
        return _hit(r.keyword, [l.title, if (m != null) memoTitleOf(m)]);
      }).toList();
      final x = await _choose<MemoLinkRef>(context,
          items: items,
          label: (l) => resolveMemoLink(l) == null ? l.title : memoTitleOf(resolveMemoLink(l)!),
          sub: (_) => null,
          notFound: 'この$kindに、外せるメモのリンクが見つかりませんでした',
          confirmText: (l) => '「$holderName」から「${l.title}」のメモのリンクを外します。メモそのものは消えません。',
          unlink: true,
          pickTitle: '外すメモを選ぶ');
      if (x == null || !context.mounted) return null;
      final saved = await save(memos: memoLinks.where((l) => !identical(l, x)).toList());
      if (context.mounted) showTimedSnack(context, 'リンクを外しました');
      return saved;
    }
    final linked = {for (final l in memoLinks) resolveMemoLink(l)?.id ?? l.id};
    final items = memoStore.memos
        .where((m) => !linked.contains(m.id))
        .where((m) => _hit(r.keyword, [m.title, memoTitleOf(m)]))
        .toList();
    final x = await _choose<Memo>(context,
        items: items,
        label: memoTitleOf,
        sub: (_) => null,
        notFound: r.keyword == null ? 'リンクできるメモがありません' : '「${r.keyword}」に当てはまるメモが見つかりませんでした',
        confirmText: (m) => '「$holderName」に「${memoTitleOf(m)}」のメモをリンクします。',
        unlink: false,
        pickTitle: 'リンクするメモを選ぶ');
    if (x == null || !context.mounted) return null;
    final saved = await save(memos: [...memoLinks, MemoLinkRef(x.id, memoTitleOf(x))]);
    if (context.mounted) showTimedSnack(context, 'メモをリンクしました');
    return saved;
  }

  if (r.target == LinkTarget.mail) {
    if (r.unlink) {
      final items = mailLinks.where((l) {
        final m = mailStore.loadedMail(l.id);
        return _hit(r.keyword, [l.subject, if (m != null) m.subject]) &&
            _hit(r.sender, [if (m != null) m.senderName, if (m != null) m.senderAddress, if (m == null) l.subject]);
      }).toList();
      final x = await _choose<MailLinkRef>(context,
          items: items,
          label: (l) => l.subject,
          sub: (l) => mailStore.loadedMail(l.id)?.senderName,
          notFound: 'この$kindに、外せるメールのリンクが見つかりませんでした',
          confirmText: (l) => '「$holderName」から「${l.subject}」のメールのリンクを外します。メールそのものは消えません。',
          unlink: true,
          pickTitle: '外すメールを選ぶ');
      if (x == null || !context.mounted) return null;
      final saved = await save(mails: mailLinks.where((l) => !identical(l, x)).toList());
      if (context.mounted) showTimedSnack(context, 'リンクを外しました');
      return saved;
    }
    final linked = {for (final l in mailLinks) l.id};
    final items = mailStore
        .recentMails(300)
        .where((m) => !linked.contains(m.id))
        .where((m) => _hit(r.keyword, [m.subject]))
        .where((m) => _hit(r.sender, [m.senderName, m.senderAddress]))
        .take(50)
        .toList();
    final hint = [if (r.sender != null) '${r.sender}さん', if (r.keyword != null) '「${r.keyword}」'].join('・');
    final x = await _choose<Mail>(context,
        items: items,
        label: (m) => m.subject,
        sub: (m) => '${m.senderName}・${formatReceived(m.receivedAt)}',
        notFound: hint.isEmpty ? 'リンクできるメールがありません' : '$hintに当てはまるメールが見つかりませんでした（受信トレイの最近のメールから探しています）',
        confirmText: (m) => '「$holderName」に、${m.senderName}さんの「${m.subject}」のメールをリンクします。',
        unlink: false,
        pickTitle: 'リンクするメールを選ぶ');
    if (x == null || !context.mounted) return null;
    final saved = await save(mails: [...mailLinks, MailLinkRef(x.id, x.subject)]);
    if (context.mounted) showTimedSnack(context, 'メールをリンクしました');
    return saved;
  }

  showTimedSnack(context, '$kindにリンクできるのは、メモとメールです');
  return null;
}

// ---------------- メモ・メールを開いているとき：相手は予定かタスク ----------------

Future<void> _fromSource(BuildContext context, AiLink r, {Memo? memo, Mail? mail}) async {
  final sourceName = memo != null ? '「${memoTitleOf(memo)}」のメモ' : '「${mail!.subject}」のメール';

  bool eventLinked(CalendarEvent e) => memo != null
      ? e.memoLinks.any((l) => (resolveMemoLink(l)?.id ?? l.id) == memo.id)
      : e.mailLinks.any((l) => l.id == mail!.id);
  bool taskLinked(TaskItem t) => memo != null
      ? t.memoLinks.any((l) => (resolveMemoLink(l)?.id ?? l.id) == memo.id)
      : t.mailLinks.any((l) => l.id == mail!.id);
  CalendarEvent addTo(CalendarEvent e) => memo != null
      ? e.copyWith(memoLinks: [...e.memoLinks, MemoLinkRef(memo.id, memoTitleOf(memo))])
      : e.copyWith(mailLinks: [...e.mailLinks, MailLinkRef(mail!.id, mail.subject)]);
  CalendarEvent removeFrom(CalendarEvent e) => memo != null
      ? e.copyWith(memoLinks: e.memoLinks.where((l) => (resolveMemoLink(l)?.id ?? l.id) != memo.id).toList())
      : e.copyWith(mailLinks: e.mailLinks.where((l) => l.id != mail!.id).toList());
  TaskItem addToTask(TaskItem t) => memo != null
      ? t.copyWith(memoLinks: [...t.memoLinks, MemoLinkRef(memo.id, memoTitleOf(memo))])
      : t.copyWith(mailLinks: [...t.mailLinks, MailLinkRef(mail!.id, mail.subject)]);
  TaskItem removeFromTask(TaskItem t) => memo != null
      ? t.copyWith(memoLinks: t.memoLinks.where((l) => (resolveMemoLink(l)?.id ?? l.id) != memo.id).toList())
      : t.copyWith(mailLinks: t.mailLinks.where((l) => l.id != mail!.id).toList());

  final date = r.date;
  final hint = [if (date != null) '${date.month}/${date.day}', if (r.keyword != null) '「${r.keyword}」'].join('・');

  if (r.target == LinkTarget.event) {
    final base = r.unlink ? calendarStore.allLoaded.where(eventLinked) : calendarStore.allLoaded.where((e) => !eventLinked(e));
    // つなぐときは、日付の指定がなければ今日からの予定だけ
    final today = DateTime.now();
    final items = base
        .where((e) => date != null ? _eventOn(e, date) : (r.unlink || !e.end.isBefore(DateTime(today.year, today.month, today.day))))
        .where((e) => _hit(r.keyword, [e.title]))
        .take(50)
        .toList();
    final x = await _choose<CalendarEvent>(context,
        items: items,
        label: (e) => e.title,
        sub: (e) => formatEventWhen(e),
        notFound: r.unlink
            ? '$sourceNameにリンクしている予定が見つかりませんでした'
            : (hint.isEmpty ? 'リンクできる予定がありません' : '$hintに当てはまる予定が見つかりませんでした（読み込み済みの予定から探しています）'),
        confirmText: (e) => r.unlink
            ? '「${e.title}」（${formatEventWhen(e)}）から$sourceNameのリンクを外します。'
            : '「${e.title}」（${formatEventWhen(e)}）に$sourceNameをリンクします。',
        unlink: r.unlink,
        pickTitle: r.unlink ? 'リンクを外す予定を選ぶ' : 'リンクする予定を選ぶ');
    if (x == null || !context.mounted) return;
    await calendarStore.update(x, r.unlink ? removeFrom(x) : addTo(x));
    if (context.mounted) showTimedSnack(context, r.unlink ? 'リンクを外しました' : '予定にリンクしました');
    return;
  }

  if (r.target == LinkTarget.task) {
    final base = r.unlink
        ? taskStore.tasks.where(taskLinked)
        : taskStore.tasks.where((t) => !t.done && !taskLinked(t));
    final items = base
        .where((t) => date == null || (t.due != null && _sameDay(t.due!, date)))
        .where((t) => _hit(r.keyword, [t.title]))
        .take(50)
        .toList();
    final x = await _choose<TaskItem>(context,
        items: items,
        label: (t) => t.title,
        sub: (t) => t.due == null ? null : '期限：${formatDue(t.due!)}',
        notFound: r.unlink
            ? '$sourceNameにリンクしているタスクが見つかりませんでした'
            : (hint.isEmpty ? 'リンクできるタスクがありません' : '$hintに当てはまる未完了のタスクが見つかりませんでした'),
        confirmText: (t) => r.unlink ? '「${t.title}」から$sourceNameのリンクを外します。' : '「${t.title}」に$sourceNameをリンクします。',
        unlink: r.unlink,
        pickTitle: r.unlink ? 'リンクを外すタスクを選ぶ' : 'リンクするタスクを選ぶ');
    if (x == null || !context.mounted) return;
    await taskStore.update(x, r.unlink ? removeFromTask(x) : addToTask(x));
    if (context.mounted) showTimedSnack(context, r.unlink ? 'リンクを外しました' : 'タスクにリンクしました');
    return;
  }

  showTimedSnack(context, '${memo != null ? 'メモ' : 'メール'}にリンクできるのは、予定とタスクです');
}
