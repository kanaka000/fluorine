import 'memo_store.dart';
import 'models/link_refs.dart';

export 'models/link_refs.dart';

/// メモ欄の中のリンクの行（前の改行・<br> も一緒に取る。PCで「:」に直されても読む）
final _linkLine = RegExp(r'(?:\s|<br\s*/?>)*📝 メモ[：:]([^\n〔]*?)〔memo:(\d+)〕');
final _mailLine = RegExp(r'(?:\s|<br\s*/?>)*✉\uFE0F? ?メール[：:]([^\n〔]*?)〔mail:([0-9A-Za-z_-]+)〕');
final _trailing = RegExp(r'(?:\s|<br\s*/?>)+$');
final _looksHtml = RegExp(r'<(br|p|div|b|i|u|a|ul|ol|li|span|strong|em)\b[^>]*>', caseSensitive: false);

String _decode(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&#39;', "'")
    .replaceAll('&nbsp;', ' ')
    .replaceAll('&amp;', '&');

/// メモ欄を「本文」と「リンク（メモ・メール）」に分ける
({String body, List<MemoLinkRef> links, List<MailLinkRef> mails}) splitMemoLinks(String? note) {
  if (note == null || note.isEmpty) {
    return (body: note ?? '', links: const <MemoLinkRef>[], mails: const <MailLinkRef>[]);
  }
  final links = <MemoLinkRef>[];
  final mails = <MailLinkRef>[];
  var body = note.replaceAllMapped(_linkLine, (m) {
    final id = m.group(2)!;
    if (!links.any((l) => l.id == id)) links.add(MemoLinkRef(id, _decode(m.group(1)!).trim()));
    return '';
  });
  body = body.replaceAllMapped(_mailLine, (m) {
    final id = m.group(2)!;
    if (!mails.any((l) => l.id == id)) mails.add(MailLinkRef(id, _decode(m.group(1)!).trim()));
    return '';
  });
  if (links.isEmpty && mails.isEmpty) {
    return (body: note, links: const <MemoLinkRef>[], mails: const <MailLinkRef>[]);
  }
  body = body.replaceAll(_trailing, '');
  return (body: body, links: links, mails: mails);
}

String _cleanTitle(String t) {
  final s = t.replaceAll(RegExp(r'[〔〕<>]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return s.isEmpty ? '（タイトルなし）' : s;
}

/// 本文の最後にリンクの行を付けて、Googleに送るメモ欄にする。
/// 送る前に、リンク先のメモの今のID・タイトルに直す（Notionから復元してIDが変わった場合など）
String joinMemoLinks(String? body, List<MemoLinkRef> links, [List<MailLinkRef> mails = const []]) {
  final b = (body ?? '').replaceAll(RegExp(r'\s+$'), '');
  final fixed = normalizeMemoLinks(links);
  final seen = <String>{};
  final mailList = [for (final m in mails) if (seen.add(m.id)) m];
  if (fixed.isEmpty && mailList.isEmpty) return b;
  final sep = _looksHtml.hasMatch(b) ? '<br>' : '\n';
  final lines = [
    for (final l in fixed) '📝 メモ：${_cleanTitle(l.title)}〔memo:${l.id}〕',
    for (final m in mailList) '✉️ メール：${_cleanTitle(m.subject)}〔mail:${m.id}〕',
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

/// 一覧の行のタイトル（リンクがあれば 📝・✉️ を付ける）
String titleWithLinkMarks(String title, List<MemoLinkRef> memos, List<MailLinkRef> mails) {
  final marks = [if (memos.isNotEmpty) '📝', if (mails.isNotEmpty) '✉️'];
  return marks.isEmpty ? title : '$title  ${marks.join()}';
}
