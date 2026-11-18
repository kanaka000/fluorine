import 'package:flutter/material.dart';

import '../screens/reply_screen.dart';
import '../services/claude_service.dart';
import '../services/contacts_service.dart';
import 'add_sheets.dart';
import 'ai_prompt.dart';
import '../services/errors.dart';

/// AIボタンのステップ2：どの画面の✨からでも使う共通の処理

const generalAiHint = '例：明日の予定は？／期限が近いタスクは？／田中さんに打ち合わせのお礼メールを作って／金曜15時に歯医者を入れて';

/// AIが作った新しい予定の下書きで、追加画面を開く（保存は自分で押す）
Future<void> openNewEventFromAi(BuildContext context, AiEvent r) async {
  await showAddEventSheet(
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
  setBusy(true);
  final messenger = ScaffoldMessenger.of(context);
  messenger.showSnackBar(SnackBar(
    content: Text('AIが考えています…（$instruction）'),
    duration: const Duration(seconds: 30),
  ));
  AiResult result;
  try {
    result = await ClaudeService.askAnything(instruction: instruction);
  } catch (e) {
    messenger.hideCurrentSnackBar();
    setBusy(false);
    messenger.showSnackBar(SnackBar(content: Text('AIに頼めませんでした：${friendlyError(e)}')));
    return;
  }
  messenger.hideCurrentSnackBar();
  setBusy(false);
  if (!context.mounted) return;

  switch (result) {
    case AiEvent r:
      await openNewEventFromAi(context, r);
    case AiTask r:
      showAddTaskSheet(context, null, title: r.title, due: r.due, note: r.note);
    case AiMemo r:
      showAddMemoSheet(context, null, title: r.title, body: r.body);
    case AiNewMail r:
      await openNewMailFromAi(context, r);
    case AiReply r:
      showAiAnswer(context, instruction, r.body);
    case AiAnswer r:
      showAiAnswer(context, instruction, r.text);
    case AiDeleteEvent _ || AiTaskUpdate _ || AiTaskComplete _ || AiTaskDelete _ || AiMemoUpdate _ || AiMemoDelete _:
      showAiAnswer(context, instruction, '予定・タスク・メモの変更や削除は、それぞれのタブの✨から頼んでください。');
  }
}
