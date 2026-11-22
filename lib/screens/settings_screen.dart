import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/app_settings.dart';
import '../data/calendar_store.dart';
import '../data/memo_store.dart';
import '../data/sender_merges.dart';
import '../services/notion_sync.dart';
import '../services/errors.dart';

/// 設定画面の見出し
Widget _header(BuildContext context, String text) {
  final theme = Theme.of(context);
  return Padding(
    padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
    child: Text(text, style: theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.primary)),
  );
}

/// どのタブの≡からも開ける「全体の設定」をメニューに出すための項目を作るときに使う
void openGeneralSettings(BuildContext context) {
  Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GeneralSettingsScreen()));
}

// ---------------- 全体の設定（お知らせ・外観） ----------------

class GeneralSettingsScreen extends StatelessWidget {
  const GeneralSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('全体の設定')),
      body: ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => ListView(
          children: [
            _header(context, 'お知らせ'),
            SwitchListTile(
              title: const Text('保存後のお知らせを表示'),
              subtitle: const Text('予定・タスク・メモを追加したときの「開く」付きのお知らせ'),
              value: appSettings.showSavedNotice,
              onChanged: appSettings.setShowSavedNotice,
            ),
            ListTile(
              title: const Text('お知らせの表示時間'),
              subtitle: const Text('削除や下書きの「元に戻す」付きのお知らせにも適用'),
              trailing: DropdownButton<int>(
                value: appSettings.noticeSeconds,
                items: const [2, 4, 6, 8, 10]
                    .map((s) => DropdownMenuItem(value: s, child: Text('$s秒')))
                    .toList(),
                onChanged: (v) {
                  if (v != null) appSettings.setNoticeSeconds(v);
                },
              ),
            ),
            _header(context, '外観'),
            RadioGroup<ThemeMode>(
              groupValue: appSettings.themeMode,
              onChanged: (v) {
                if (v != null) appSettings.setThemeMode(v);
              },
              child: const Column(
                children: [
                  RadioListTile(value: ThemeMode.system, title: Text('端末の設定に合わせる')),
                  RadioListTile(value: ThemeMode.light, title: Text('ライトモード')),
                  RadioListTile(value: ThemeMode.dark, title: Text('ダークモード')),
                ],
              ),
            ),
            _header(context, 'AI（✨）'),
            SwitchListTile(
              title: const Text('✨にほかのタブの内容も見せる'),
              subtitle: const Text('オンにすると、どの画面の✨でも、これからの予定・未完了のタスク・メモ・'
                  '受信メール（最新100通の差出人・件名・本文の冒頭）もAIに送ります。'
                  '「明日の予定は？」「○○さんから何か頼まれてた？」などに答えられるようになります'),
              value: appSettings.aiCrossTab,
              onChanged: appSettings.setAiCrossTab,
            ),
            _header(context, '端末内のデータ'),
            ListTile(
              leading: Icon(Icons.delete_forever_outlined, color: Theme.of(context).colorScheme.error),
              title: const Text('端末内のデータを消す'),
              subtitle: const Text('メモ・送信元のまとめ・Notion連携の状態・設定を、この端末から消します。'
                  'Googleのメール・予定・タスクと、Notionのページは消えません'),
              onTap: () => _clearLocalData(context),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ---------------- メールの設定（読み込み・画像） ----------------

class MailSettingsScreen extends StatelessWidget {
  const MailSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('メールの設定')),
      body: ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => ListView(
          children: [
            _header(context, '読み込み'),
            SwitchListTile(
              title: const Text('起動時に自動で読み込む'),
              subtitle: const Text('オフのときは、一覧を下に引っ張るか、≡の「再読み込み」で読み込みます'),
              value: appSettings.autoReloadOnStart,
              onChanged: appSettings.setAutoReloadOnStart,
            ),
            SwitchListTile(
              title: const Text('トップ画面に戻ったときに自動で読み込む'),
              subtitle: const Text('メール一覧や本文から、送信元の一覧に戻ったとき'
                  '（前回の読み込みから1分以内なら読み込みません）'),
              isThreeLine: true,
              value: appSettings.autoReloadOnTop,
              onChanged: appSettings.setAutoReloadOnTop,
            ),
            _header(context, '表示'),
            SwitchListTile(
              title: const Text('メール内の画像を自動で表示'),
              subtitle: const Text('オンにすると、送信元に開封したことが伝わる場合があります。'
                  'オフのときは、メールごとに「画像を表示」で表示できます'),
              isThreeLine: true,
              value: appSettings.loadImages,
              onChanged: appSettings.setLoadImages,
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ---------------- カレンダーの設定 ----------------

class CalendarSettingsScreen extends StatelessWidget {
  const CalendarSettingsScreen({super.key});

  static const _dayChoices = [30, 60, 90, 180];
  static const _minuteChoices = [15, 30, 60, 90, 120];

  static String _minutesLabel(int m) {
    if (m < 60) return '$m分';
    if (m % 60 == 0) return '${m ~/ 60}時間';
    return '${m ~/ 60}時間${m % 60}分';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('カレンダーの設定')),
      body: ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => ListView(
          children: [
            _header(context, '表示'),
            ListTile(
              title: const Text('表示する期間'),
              subtitle: const Text('今日から何日先までの予定を読み込むか'),
              trailing: DropdownButton<int>(
                value: _dayChoices.contains(appSettings.calendarDays) ? appSettings.calendarDays : 60,
                items: _dayChoices
                    .map((d) => DropdownMenuItem(value: d, child: Text('$d日')))
                    .toList(),
                onChanged: (v) {
                  if (v == null || v == appSettings.calendarDays) return;
                  appSettings.setCalendarDays(v);
                  calendarStore.reload(); // 期間が変わったので読み込み直す
                },
              ),
            ),
            ListTile(
              title: const Text('週の始まり'),
              subtitle: const Text('日付を選ぶカレンダーの並び'),
              trailing: DropdownButton<bool>(
                value: appSettings.weekStartsMonday,
                items: const [
                  DropdownMenuItem(value: false, child: Text('日曜日')),
                  DropdownMenuItem(value: true, child: Text('月曜日')),
                ],
                onChanged: (v) {
                  if (v != null) appSettings.setWeekStartsMonday(v);
                },
              ),
            ),
            ListTile(
              title: const Text('予定のある日の印'),
              subtitle: const Text('月のカレンダーで、予定のある日に付ける印'),
              trailing: DropdownButton<int>(
                value: appSettings.calendarMarker.clamp(0, 2),
                items: const [
                  DropdownMenuItem(value: 0, child: Text('点')),
                  DropdownMenuItem(value: 1, child: Text('件数')),
                  DropdownMenuItem(value: 2, child: Text('色付きの丸')),
                ],
                onChanged: (v) {
                  if (v != null) appSettings.setCalendarMarker(v);
                },
              ),
            ),
            ListTile(
              title: const Text('開いたときの表示'),
              subtitle: const Text('アプリを起動してカレンダーを開いたときの表示'),
              trailing: DropdownButton<bool>(
                value: appSettings.calendarRememberView,
                items: const [
                  DropdownMenuItem(value: true, child: Text('最後に使った表示')),
                  DropdownMenuItem(value: false, child: Text('いつも一覧')),
                ],
                onChanged: (v) {
                  if (v != null) appSettings.setCalendarRememberView(v);
                },
              ),
            ),
            _header(context, '追加'),
            ListTile(
              title: const Text('予定の標準の長さ'),
              subtitle: const Text('時刻ありの予定を追加するときの、終了時刻の初期値'),
              trailing: DropdownButton<int>(
                value: _minuteChoices.contains(appSettings.eventMinutes) ? appSettings.eventMinutes : 60,
                items: _minuteChoices
                    .map((m) => DropdownMenuItem(value: m, child: Text(_minutesLabel(m))))
                    .toList(),
                onChanged: (v) {
                  if (v != null) appSettings.setEventMinutes(v);
                },
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ---------------- タスクの設定 ----------------

class TaskSettingsScreen extends StatelessWidget {
  const TaskSettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('タスクの設定')),
      body: ListenableBuilder(
        listenable: appSettings,
        builder: (context, _) => ListView(
          children: [
            _header(context, '表示'),
            SwitchListTile(
              title: const Text('完了したタスクも表示'),
              subtitle: const Text('オンにすると、完了したタスクを一覧の下に取り消し線付きで表示します'),
              value: appSettings.showCompletedTasks,
              onChanged: appSettings.setShowCompletedTasks,
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ---------------- メモの設定（Notion連携。2026-11-17） ----------------

class MemoSettingsScreen extends StatelessWidget {
  const MemoSettingsScreen({super.key});

  static String _time(DateTime d) =>
      '${d.month}/${d.day} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('メモの設定')),
      body: ListenableBuilder(
        listenable: Listenable.merge([appSettings, notionSync, memoStore]),
        builder: (context, _) {
          final configured = notionSync.configured;
          final on = appSettings.notionSync && configured;
          final String status;
          if (notionSync.syncing) {
            status = 'Notionに送っています…';
          } else if (notionSync.lastError != null) {
            status = '送れませんでした：${notionSync.lastError}';
          } else if (notionSync.pendingCount > 0) {
            status = 'まだ送っていないメモ：${notionSync.pendingCount}件';
          } else if (notionSync.lastSyncedAt != null) {
            status = 'すべて送信済み（最後に送った日時：${_time(notionSync.lastSyncedAt!)}）';
          } else {
            status = 'まだ送っていません';
          }
          return ListView(
            children: [
              _header(context, 'Notion連携'),
              SwitchListTile(
                title: const Text('メモをNotionに保存する'),
                subtitle: Text(configured
                    ? 'メモを保存・削除するたびに、Notionの保存先ページの下に反映します（アプリ→Notionの一方向）。'
                        'オンにすると、今あるメモもすべて送ります'
                    : 'secrets.json に NOTION_TOKEN と NOTION_PAGE_ID を入れて起動し直すと使えます'),
                value: on,
                onChanged: configured ? notionSync.setEnabled : null,
              ),
              if (on)
                ListTile(
                  leading: Icon(
                    notionSync.lastError != null ? Icons.error_outline : Icons.cloud_done_outlined,
                    color: notionSync.lastError != null ? theme.colorScheme.error : null,
                  ),
                  title: Text(status,
                      style: notionSync.lastError != null ? TextStyle(color: theme.colorScheme.error) : null),
                  trailing: TextButton(
                    onPressed: notionSync.syncing ? null : notionSync.flush,
                    child: const Text('今すぐ送る'),
                  ),
                ),
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Text('・Notionで直した内容はアプリには戻りません（下の「復元」を除く）。アプリで保存すると、Notionのページはアプリの内容で上書きされます\n'
                    '・アプリで削除したメモは、Notionではゴミ箱に入ります\n'
                    '・メモの色は、Notionのページのアイコン（🟥🟦など）で表します'),
              ),
              _header(context, 'Notionから復元'),
              ListTile(
                leading: const Icon(Icons.settings_backup_restore),
                title: const Text('Notionからメモを復元する'),
                subtitle: Text(!configured
                    ? 'secrets.json に NOTION_TOKEN と NOTION_PAGE_ID を入れて起動し直すと使えます'
                    : notionSync.restoring && notionSync.restoreTotal > 0
                        ? '復元しています…（${notionSync.restoreDone}／${notionSync.restoreTotal}件）'
                        : memoStore.memos.isEmpty
                            ? 'アプリを入れ直したときなどに、Notionの保存先ページの下にあるページをメモとして取り込みます'
                            : 'メモが1件もないときだけ使えます（アプリを入れ直したとき用）'),
                trailing: notionSync.restoring
                    ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                    : TextButton(
                        onPressed: notionSync.canRestore ? () => _restoreFromNotion(context) : null,
                        child: const Text('復元'),
                      ),
              ),
              const SizedBox(height: 32),
            ],
          );
        },
      ),
    );
  }
}

/// 「Notionから復元」（2026-11-18）：ページの一覧を読む → 件数を確認 → 取り込む → 連携がオフならオンにするか聞く
Future<void> _restoreFromNotion(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  final List<NotionPageRef> pages;
  try {
    pages = await notionSync.listRestorablePages();
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Notionを読み込めませんでした：${friendlyError(e)}')));
    return;
  }
  if (!context.mounted) return;
  if (pages.isEmpty) {
    messenger.showSnackBar(const SnackBar(content: Text('Notionの保存先ページの下に、復元できるページがありません')));
    return;
  }
  final ok = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('Notionからメモを復元'),
      content: Text('Notionの保存先ページの下にある${pages.length}件のページを、メモとして取り込みます。\n\n'
          '・作成・更新日時は、Notionのページの日時になります\n'
          '・色は、ページのアイコン（🟥🟦など）から戻します\n'
          '・Notionで付けた画像・表などは、文字のまま入ることがあります'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('復元する')),
      ],
    ),
  );
  if (ok != true) return;
  final int count;
  try {
    count = await notionSync.restore(pages);
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('復元できませんでした（メモは取り込んでいません）：${friendlyError(e)}')));
    return;
  }
  messenger.showSnackBar(SnackBar(content: Text('$count件のメモを復元しました')));
  if (count == 0 || appSettings.notionSync || !context.mounted) return;
  final on = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('今後もNotionに保存しますか？'),
      content: const Text('オンにすると、メモを保存・削除するたびにNotionにも反映します。'
          '復元したメモは、元のNotionのページにつながったままです。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('あとで')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('オンにする')),
      ],
    ),
  );
  if (on == true) await notionSync.setEnabled(true, sendAll: false);
}

/// 「端末内のデータを消す」（2026-11-18）：2回確認してから、端末に保存したものをすべて消す
/// （メモ・送信元のまとめ・Notion連携の状態・設定。Googleのログインはそのまま）
Future<void> _clearLocalData(BuildContext context) async {
  final messenger = ScaffoldMessenger.of(context);
  if (notionSync.syncing || notionSync.restoring) {
    messenger.showSnackBar(const SnackBar(content: Text('Notionとのやり取りが終わってから、もう一度押してください')));
    return;
  }
  final first = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('端末内のデータを消す'),
      content: Text('この端末から次のものを消します。\n\n'
          '・メモ（${memoStore.memos.length}件）\n'
          '・送信元のまとめ\n'
          '・Notion連携の状態（送れていないメモ・ページとのつながり）\n'
          '・設定（初期値に戻ります）\n\n'
          'Googleのメール・予定・タスク、Notionのページは消えません。'
          'Notionに保存していたメモは、メモの設定の「Notionから復元」で戻せます'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
        FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('次へ')),
      ],
    ),
  );
  if (first != true || !context.mounted) return;
  final second = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: const Text('本当に消しますか？'),
      content: const Text('消したデータは元に戻せません。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('キャンセル')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Theme.of(c).colorScheme.error),
          onPressed: () => Navigator.pop(c, true),
          child: const Text('消す'),
        ),
      ],
    ),
  );
  if (second != true) return;
  final p = await SharedPreferences.getInstance();
  await p.clear();
  memoStore.clearLocal();
  senderMerges.clearLocal();
  notionSync.clearLocal();
  appSettings.resetToDefaults();
  messenger.showSnackBar(const SnackBar(content: Text('端末内のデータを消しました')));
}
