import 'package:flutter/material.dart';

import '../data/models.dart';
import '../screens/mail_search_screen.dart';
import '../screens/reply_screen.dart';
import '../services/mail_search.dart';
import '../services/claude_service.dart';
import '../services/contacts_service.dart';
import 'add_sheets.dart';
import 'ai_common.dart';
import 'ai_prompt.dart';

/// AIボタンのステップ2：どの画面の✨からでも使う共通の処理

const generalAiHint = '例：明日の予定は？／期限が近いタスクは？／田中さんに打ち合わせのお礼メールを作って／金曜15時に歯医者を入れて／見積書が添付されたメールを探して';

/// AIが作った新しい予定の下書きで、追加画面を開く（保存は自分で押す）。[mail] があればメールから作る
Future<void> openNewEventFromAi(BuildContext context, AiEvent r, {Mail? mail}) async {
  await showAddEventSheet(
    context,
    mail,
    title: r.title,
    date: r.date,
    time: r.time,
    endDate: r.endDate,
    endTime: r.endTime,
    allDay: (r.allDay ?? false) || r.time == null,
    location: r.location,
    note: r.note,
  );
}

/// AIが作った新しいメールの下書きで、作成画面を開く（送信は自分で押す）。
/// 宛先が名前だけのときは、Googleの連絡先などから探して入れる（候補が複数なら選ぶ）
Future<void> openNewMailFromAi(BuildContext context, AiNewMail r) async {
  final messenger = ScaffoldMessenger.of(context);
  final navigator = Navigator.of(context);
  var to = r.toAddress ?? '';
  final name = r.toName;
  if (to.isEmpty && name != null && name.trim().isNotEmpty) {
    messenger.showSnackBar(SnackBar(
      content: Text('「${ContactsService.cleanName(name)}」さんのアドレスを探しています…'),
      duration: const Duration(seconds: 20),
    ));
    final result = await ContactsService.search(name);
    messenger.hideCurrentSnackBar();
    if (!context.mounted) return;
    if (result.problem != null) messenger.showSnackBar(SnackBar(content: Text(result.problem!)));
    if (result.list.length == 1) {
      to = result.list.first.address;
    } else if (result.list.length > 1) {
      final picked = await _pickRecipient(context, ContactsService.cleanName(name), result.list);
      if (!context.mounted) return;
      to = picked ?? '';
    } else {
      messenger.showSnackBar(SnackBar(
        content: Text('「${ContactsService.cleanName(name)}」さんのアドレスが見つかりませんでした。宛先を入れてください'),
      ));
    }
  }
  navigator.push(MaterialPageRoute(
    builder: (_) => ReplyScreen(
      mode: ComposeMode.newMail,
      initialTo: to,
      initialSubject: r.subject,
      initialDraft: r.body,
    ),
  ));
}

/// 宛先の候補が複数あるときに選んでもらう。選ばなければ null（宛先は空のまま開く）
Future<String?> _pickRecipient(BuildContext context, String name, List<ContactCandidate> list) {
  return showModalBottomSheet<String>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (ctx) {
      final theme = Theme.of(ctx);
      return ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(ctx).height * 0.7),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Text('「$name」さんの宛先を選んでください', style: theme.textTheme.titleMedium),
            ),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  for (final c in list)
                    ListTile(
                      leading: const Icon(Icons.person_outline),
                      title: Text(c.name),
                      subtitle: Text('${c.address}（${c.source}）'),
                      onTap: () => Navigator.of(ctx).pop(c.address),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
              child: OutlinedButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('選ばずに開く（宛先は自分で入れる）'),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// メールのトップ画面の✨：予定・タスク・メモ・メールの質問と新規作成
Future<void> runGeneralAi(
  BuildContext context,
  String instruction, {
  required void Function(bool busy) setBusy,
}) async {
  final result = await askAiWithStatus(context, instruction, setBusy: setBusy, ask: () => ClaudeService.askAnything(instruction: instruction));
  if (result == null || !context.mounted) return;

  switch (result) {
    case AiMailSearch r:
      // メールを探す（2026-11-19）。手がかりがなければ案内だけ
      if (buildMailQuery(r).isEmpty) {
        showAiAnswer(context, instruction, '何を探すか分かりませんでした。言葉・差出人・添付の種類・期間などを入れて頼んでください。');
        return;
      }
      await Navigator.of(context).push(MaterialPageRoute(builder: (_) => MailSearchScreen(search: r)));
    default:
      await handleCommonAiResult(context, instruction, result);
  }
}
