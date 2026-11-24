import 'memo_store.dart';
import 'models/link_refs.dart';

export 'models/link_refs.dart';

/// メモ欄の中のリンクの行（前の改行・<br> も一緒に取る。PCで「:」に直されても読む）
final _linkLine = RegExp(r'(?:\s|<br\s*/?>)*📝 メモ[：:]([^\n〔]*?)〔memo:(\d+)〕');
final _mailLine = RegExp(r'(?:\s|<br\s*/?>)*✉\uFE0F? ?メール[：:]([^\n〔]*?)〔mail:([0-9A-Za-z_-]+)〕');
/// カードの色の行（2026-11-24 の24）：`🎨 色：黄〔color:yellow〕`。名前（黄）は人が読むためだけで、印（yellow）で読む
final _colorLine = RegExp(r'(?:\s|<br\s*/?>)*🎨\uFE0F? ?色[：:][^\n〔]*?〔color:([a-z]+)〕');
/// 予定のリンクの行（タスクのメモ欄だけ。2026-11-24 の25）：`📅 予定：タイトル〔event:<予定のID>〕`
final _eventLine = RegExp(r'(?:\s|<br\s*/?>)*📅 ?予定[：:]([^\n〔]*?)〔event:([0-9A-Za-z_-]+)〕');
final _trailing = RegExp(r'(?:\s|<br\s*/?>)+$');
final _looksHtml = RegExp(r'<(br|p|div|b|i|u|a|ul|ol|li|span|strong|em)\b[^>]*>', caseSensitive: false);

String _decode(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

/// メモ欄を「本文」と「リンク（メモ・メール・予定）」と「カードの色」に分ける
/// （色は 2026-11-24 の24、予定のリンクは 2026-11-24 の25。予定のリンクはタスクにだけある）
({
  String body,
  List<MemoLinkRef> links,
  List<MailLinkRef> mails,
  String? color,
  List<EventLinkRef> events,
}) splitMemoLinks(String? note) {
  if (note == null || note.isEmpty) {
    return (
      body: note ?? '',
      links: const <MemoLinkRef>[],
      mails: const <MailLinkRef>[],
      color: null,
      events: const <EventLinkRef>[],
    );
  }
  final links = <MemoLinkRef>[];
  final mails = <MailLinkRef>[];
  final events = <EventLinkRef>[];
  String? color;
  var found = false;
  var body = note.replaceAllMapped(_colorLine, (m) {
    found = true;
    color ??= MemoColor.of(m.group(1))?.key; // 知らない色の名前は「指定なし」
    return '';
  });
  body = body.replaceAllMapped(_linkLine, (m) {
    final id = m.group(2)!;
    if (!links.any((l) => l.id == id)) links.add(MemoLinkRef(id, _decode(m.group(1)!).trim()));
    return '';
  });
  body = body.replaceAllMapped(_mailLine, (m) {
    final id = m.group(2)!;
    if (!mails.any((l) => l.id == id)) mails.add(MailLinkRef(id, _decode(m.group(1)!).trim()));
    return '';
  });
  body = body.replaceAllMapped(_eventLine, (m) {
    final id = m.group(2)!;
    if (!events.any((l) => l.id == id)) events.add(EventLinkRef(id, _decode(m.group(1)!).trim()));
    return '';
  });
  if (links.isEmpty && mails.isEmpty && events.isEmpty && !found) {
    return (
      body: note,
      links: const <MemoLinkRef>[],
      mails: const <MailLinkRef>[],
      color: null,
      events: const <EventLinkRef>[],
    );
  }
  body = body.replaceAll(_trailing, '');
  return (body: body, links: links, mails: mails, color: color, events: events);
}

String _cleanTitle(String t) {
  final s = t.replaceAll(RegExp(r'[〔〕<>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? '（タイトルなし）' : s;
}

/// 本文の最後に色の行とリンクの行を付けて、Googleに送るメモ欄にする（色の行が先）。
/// 送る前に、リンク先のメモの今のID・タイトルに直す（Notionから復元してIDが変わった場合など）
String joinMemoLinks(String? body, List<MemoLinkRef> links,
    {List<MailLinkRef> mails = const [], String? color, List<EventLinkRef> events = const []}) {
  final b = (body ?? '').replaceAll(RegExp(r'\s+$'), '');
  final fixed = normalizeMemoLinks(links);
  final seen = <String>{};
  final mailList = [for (final m in mails) if (seen.add(m.id)) m];
  final c = MemoColor.of(color);
  final seenEvents = <String>{};
  final eventList = [for (final e in events) if (seenEvents.add(e.id)) e];
  if (fixed.isEmpty && mailList.isEmpty && eventList.isEmpty && c == null) return b;
  final sep = _looksHtml.hasMatch(b) ? '<br>' : '\n';
  final lines = [
    if (c != null) '🎨 色：${c.label}〔color:${c.key}〕',
    for (final l in fixed) '📝 メモ：${_cleanTitle(l.title)}〔memo:${l.id}〕',
    for (final m in mailList) '✉️ メール：${_cleanTitle(m.subject)}〔mail:${m.id}〕',
    for (final e in eventList) '📅 予定：${_cleanTitle(e.title)}〔event:${e.id}〕',
  ].join(sep);
  return b.isEmpty ? lines : '$b$sep$sep$lines';
}

/// リンク先のメモを探す。IDで見つからなければ、タイトルが同じメモが1件だけならそれを使う
Memo? resolveMemoLink(MemoLinkRef ref) {
  final byId = memoStore.find(ref.id);
  if (byId != null) return byId;
  if (ref.title.isEmpty) return null;
  final same = memoStore.memos.where((m) => _cleanTitle(memoTitleOf(m)) == _cleanTitle(ref.title)).toList();
  return same.length == 1 ? same.first : null;
}

/// 見つかるリンクは今のID・タイトルに直し、同じメモへの重複を除く
List<MemoLinkRef> normalizeMemoLinks(List<MemoLinkRef> links) {
  final out = <MemoLinkRef>[];
  for (final l in links) {
    final m = resolveMemoLink(l);
    final ref = m == null ? l : MemoLinkRef(m.id, memoTitleOf(m));
    if (!out.any((x) => x.id == ref.id)) out.add(ref);
  }
  return out;
}

/// メモの表示用のタイトル（空なら本文の1行目）
String memoTitleOf(Memo m) {
  final t = m.title.trim();
  if (t.isNotEmpty) return t;
  final first = m.body
      .trim()
      .split('\n')
      .first
      .replaceFirst(RegExp(r'^\s*(#+\s*|[-*+]\s+(\[[ xX]\]\s+)?|>\s*)'), '')
      .trim();
  return first.isEmpty ? '（タイトルなし）' : first;
}

/// 一覧の行のタイトル（リンクがあれば 📝・✉️ を付ける。予定⇔タスクのリンクは、予定の行に ✅、タスクの行に 📅。2026-11-24 の25）
String titleWithLinkMarks(String title, List<MemoLinkRef> memos, List<MailLinkRef> mails,
    {bool task = false, bool event = false}) {
  final marks = [
    if (memos.isNotEmpty) '📝',
    if (mails.isNotEmpty) '✉️',
    if (task) '✅',
    if (event) '📅',
  ];
  return marks.isEmpty ? title : '$title  ${marks.join()}';
}
