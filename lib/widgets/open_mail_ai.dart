import 'package:material_ui/material_ui.dart';

import '../data/mail_store.dart';
import '../data/models.dart';
import '../screens/mail_detail_screen.dart';
import '../services/claude_service.dart';
import '../services/errors.dart';
import '../services/google_auth.dart';
import '../services/mail_search.dart';
import 'ai_prompt.dart';
import 'format.dart';

// ✨で「元のメールを表示して」（2026-11-22）。
// メモの本文の「メール：件名」「差出人・日時」の行か、AIが聞き取った手がかりでメールを探す。
// 1通ならすぐ詳細を開き、何通もあれば選ぶ画面、なければお知らせ。見るだけなので確認はしない

/// メモの本文にある元のメールの情報（メールから作ったメモの最後の2行。widgets/sheets/sheet_common.dart の mailSourceNote）
class SourceMailInfo {
  const SourceMailInfo(this.subject, this.sender, this.receivedAt);
  final String subject;
  final String sender;
  final DateTime receivedAt;
}

final _sourceLine = RegExp(
  r'^メール[：:][ \t]*(.*)\r?\n(.*)・(\d{4})/(\d{1,2})/(\d{1,2}) (\d{1,2}):(\d{2})[ \t]*$',
  multiLine: true,
);

/// 本文の「メール：件名」と次の行「差出人・2026/11/20 9:05」を読む（いくつかあれば最後のもの）。なければ null
SourceMailInfo? sourceMailOf(String body) {
  RegExpMatch? last;
  for (final m in _sourceLine.allMatches(body)) {
    last = m;
  }
  final m = last;
  if (m == null) return null;
  final subject = m.group(1)!.trim();
  if (subject.isEmpty) return null;
  int n(int i) => int.parse(m.group(i)!);
  return SourceMailInfo(subject, m.group(2)!.trim(), DateTime(n(3), n(4), n(5), n(6), n(7)));
}

String _norm(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim().toLowerCase();

String _ymd(DateTime d) => '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';

/// 件名を Gmail の検索の "…" に入れられる形にする
String _phrase(String s) {
  final t = s.replaceAll(RegExp(r'["(){}\[\]]'), ' ').replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.isEmpty ? '' : '"$t"';
}

/// 件名が同じものに絞る。まだ何通もあれば差出人、受け取った時刻（分まで）でさらに絞る
List<Mail> _narrow(List<Mail> mails, SourceMailInfo src) {
  final seen = <String>{};
  var list = [
    for (final m in mails)
      if (_norm(m.subject) == _norm(src.subject) && seen.add(m.id)) m,
  ];
  if (list.length > 1) {
    final bySender = [for (final m in list) if (_norm(m.senderName) == _norm(src.sender)) m];
    if (bySender.isNotEmpty) list = bySender;
  }
  if (list.length > 1) {
    final t = src.receivedAt;
    final sameTime = [
      for (final m in list)
        if (m.receivedAt.year == t.year &&
            m.receivedAt.month == t.month &&
            m.receivedAt.day == t.day &&
            m.receivedAt.hour == t.hour &&
            m.receivedAt.minute == t.minute)
          m,
    ];
    if (sameTime.isNotEmpty) list = sameTime;
  }
  return list;
}

/// 元のメールを探す：読み込み済みの受信メール → Gmail（件名と日付 → 件名だけ → その日の前後のメール全部）
Future<List<Mail>> _findSource(SourceMailInfo src) async {
  final local = _narrow(mailStore.recentMails(1000), src);
  if (local.isNotEmpty) return local;
  final subject = _phrase(src.subject);
  final d = src.receivedAt;
  // Gmail の日付は時差で1日ずれることがあるので、前後1日ずつ広げる
  final range = 'after:${_ymd(d.subtract(const Duration(days: 1)))} before:${_ymd(d.add(const Duration(days: 2)))}';
  final queries = [
    if (subject.isNotEmpty) 'subject:$subject $range',
    if (subject.isNotEmpty) 'subject:$subject',
    range,
  ];
  for (final q in queries) {
    final found = _narrow(await mailStore.searchMails(q), src);
    devLog('元のメールの検索: $q → ${found.length}通');
    if (found.isNotEmpty) return found;
  }
  return const [];
}

/// メモの詳細画面の✨の open_mail。見つけたメールの詳細を今のタブに開く
Future<void> openMailFromAi(BuildContext context, String instruction, AiOpenMail r, {required Memo memo}) async {
  if (!googleAuth.signedIn) {
    showAiAnswer(context, instruction, 'メールを開くには、Googleにログインしてください。');
    return;
  }
  final src = sourceMailOf(memo.body);
  final clueQuery = buildMailQuery(AiMailSearch(keyword: r.keyword, sender: r.sender, dateFrom: r.date, dateTo: r.date));
  // 元のメールと言われたとき・手がかりがないときは、本文の行を使う
  final source = (src != null && (r.fromSource || clueQuery.isEmpty)) ? src : null;
  if (source == null && clueQuery.isEmpty) {
    showAiAnswer(
        context,
        instruction,
        r.fromSource
            ? 'このメモには元のメールの情報（「メール：件名」と差出人・日時の行）がないので、探せませんでした。'
                '「田中さんの見積もりのメールを表示して」のように、手がかりを入れて頼んでください。'
            : 'どのメールか分かりませんでした。「田中さんの見積もりのメールを表示して」のように、差出人や言葉を入れて頼んでください。');
    return;
  }

  final nav = Navigator.of(context);
  final closeProgress = _showProgress(context);
  List<Mail> found;
  try {
    found = source != null ? await _findSource(source) : await mailStore.searchMails(clueQuery);
  } catch (e) {
    closeProgress();
    if (context.mounted) showAiAnswer(context, instruction, 'メールを探せませんでした：${friendlyError(e)}');
    return;
  }
  closeProgress();
  if (!context.mounted) return;

  if (found.isEmpty) {
    showAiAnswer(
        context,
        instruction,
        source != null
            ? '元のメール「${source.subject}」が見つかりませんでした。'
                '削除された（ゴミ箱に入って約30日たった）か、件名の行が書き換えられたのかもしれません。'
            : 'メールが見つかりませんでした（Gmailの検索：$clueQuery）。言葉を短くしたり、条件を減らしたりすると見つかることがあります。');
    return;
  }
  final mail = found.length == 1 ? found.first : await _pickMail(context, found);
  if (mail == null || !context.mounted) return;
  mailStore.markRead(mail);
  nav.push(MaterialPageRoute(builder: (_) => MailDetailScreen(mail: mail)));
}

/// 探している間の表示（閉じられないダイアログ）。閉じる関数を返す
VoidCallback _showProgress(BuildContext context) {
  final nav = Navigator.of(context, rootNavigator: true);
  var shown = true;
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    useRootNavigator: true,
    builder: (c) => const PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(
          children: [
            SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 3)),
            SizedBox(width: 16),
            Expanded(child: Text('メールを探しています…')),
          ],
        ),
      ),
    ),
  );
  return () {
    if (shown) {
      shown = false;
      nav.pop();
    }
  };
}

/// 何通も見つかったときに選ぶ画面
Future<Mail?> _pickMail(BuildContext context, List<Mail> mails) {
  return showModalBottomSheet<Mail>(
    context: context,
    useRootNavigator: true,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (c) {
      final theme = Theme.of(c);
      return SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.7),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: Text(
                  mails.length >= 50
                      ? '新しい順に50通まで出しています。開くメールを選んでください'
                      : '${mails.length}通見つかりました。開くメールを選んでください',
                  style: theme.textTheme.titleMedium,
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final m in mails)
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text(m.subject, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text('${m.senderName}・${formatFull(m.receivedAt)}',
                            maxLines: 1, overflow: TextOverflow.ellipsis),
                        onTap: () => Navigator.of(c).pop(m),
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
