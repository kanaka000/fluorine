import 'package:material_ui/material_ui.dart';

import '../data/app_nav.dart';
import '../data/app_settings.dart';
import '../data/mail_store.dart';
import '../data/models.dart';
import '../services/google_auth.dart';
import '../services/sync.dart';
import '../widgets/ai_prompt.dart';
import '../widgets/format.dart';
import '../widgets/general_ai.dart';
import '../widgets/header_actions.dart';
import '../widgets/sender_avatar.dart';
import '../widgets/sign_in_prompt.dart';
import 'mail_list_screen.dart';
import 'reply_screen.dart';
import 'settings_screen.dart';

/// ① 送信元一覧（送信元ごとに束ね、最新メールが新しい順）
class SenderListScreen extends StatefulWidget {
  const SenderListScreen({super.key});

  @override
  State<SenderListScreen> createState() => _SenderListScreenState();
}

class _SenderListScreenState extends State<SenderListScreen> with RouteAware {
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != null) mailRouteObserver.subscribe(this, route);
  }

  @override
  void dispose() {
    mailRouteObserver.unsubscribe(this);
    super.dispose();
  }

  /// メール一覧や本文から、この最初の画面に戻ってきたとき
  @override
  void didPopNext() {
    if (appSettings.autoReloadOnTop && googleAuth.signedIn) mailStore.reloadIfStale();
  }

  Future<void> _signIn(BuildContext context) => signInAndSync(context);

  // ---------------- AIボタン（どのタブの内容でも頼める） ----------------
  bool _aiBusy = false;

  void _setAiBusy(bool v) {
    if (mounted) setState(() => _aiBusy = v);
  }

  Future<void> _aiByVoice() async {
    final text = await listenInstruction(context, hint: generalAiHint);
    if (text != null && mounted) runGeneralAi(context, text, setBusy: _setAiBusy);
  }

  Future<void> _aiByText() async {
    final text = await typeInstruction(context, hint: generalAiHint);
    if (text != null && mounted) runGeneralAi(context, text, setBusy: _setAiBusy);
  }

  Future<void> _signOut() async {
    // 先に一覧を空にし、すぐにログアウトの状態にする（googleAuth.signOut は待たずに番号を進める。2026-11-18）
    resetAll();
    await googleAuth.signOut();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([mailStore, googleAuth]),
      builder: (context, _) {
        final groups = mailStore.groups;
        final user = googleAuth.user;
        return Scaffold(
          // ログアウト中は「作成」を出さない
          floatingActionButton: user == null
              ? null
              : FloatingActionButton.extended(
                  icon: const Icon(Icons.edit_outlined),
                  label: const Text('作成'),
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const ReplyScreen(mode: ComposeMode.newMail),
                  )),
                ),
          appBar: AppBar(
            title: const Text('Fluorine'),
            actions: headerActions(
              onAi: user == null ? null : _aiByVoice,
              onAiLongPress: _aiByText,
              aiBusy: _aiBusy,
              menuItems: [
                if (user == null)
                  HeaderMenuItem(
                    icon: Icons.login,
                    label: 'ログイン',
                    onTap: googleAuth.initialized ? () => _signIn(context) : null,
                    enabled: googleAuth.initialized,
                  )
                else ...[
                  HeaderMenuItem(
                    icon: Icons.account_circle,
                    label: user.email,
                    enabled: false,
                  ),
                  HeaderMenuItem(
                    icon: Icons.refresh,
                    label: '再読み込み',
                    onTap: () => syncAll(prompt: true),
                  ),
                ],
                HeaderMenuItem(
                  icon: Icons.settings_outlined,
                  label: 'メールの設定',
                  dividerBefore: true,
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const MailSettingsScreen()),
                  ),
                ),
                HeaderMenuItem(
                  icon: Icons.tune,
                  label: '全体の設定',
                  onTap: () => openGeneralSettings(context),
                ),
                if (user != null)
                  HeaderMenuItem(
                    icon: Icons.logout,
                    label: 'ログアウト',
                    dividerBefore: true,
                    onTap: _signOut,
                  ),
              ],
            ),
          ),
          // ログアウト中は一覧の代わりにログインの案内
          body: user == null
              ? const SignInPrompt(
                  icon: Icons.mail_outline,
                  message: 'Googleでログインすると、\nGmailの受信トレイが表示されます',
                )
              : Column(
            children: [
              if (mailStore.loading) const LinearProgressIndicator(),
              if (mailStore.error != null)
                MaterialBanner(
                  content: Text(mailStore.error!),
                  actions: [
                    TextButton(
                      onPressed: () => syncAll(prompt: true),
                      child: const Text('再試行'),
                    ),
                  ],
                ),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: () => mailStore.reload(),
                  child: groups.isEmpty
                      ? ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          children: const [
                            Padding(
                              padding: EdgeInsets.all(48),
                              child: Center(
                                child: Text('メールはありません\n（下に引っ張ると読み込みます）',
                                    textAlign: TextAlign.center),
                              ),
                            ),
                          ],
                        )
                      : ListView.separated(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.only(bottom: 88), // 「作成」ボタンに最後の行が隠れないように
                    itemCount: groups.length,
                    separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
                    itemBuilder: (context, i) => _SenderTile(group: groups[i]),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SenderTile extends StatelessWidget {
  const _SenderTile({required this.group});

  final SenderGroup group;

  void _open(BuildContext context) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => MailListScreen(address: group.address),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final bold = group.hasUnread ? FontWeight.bold : FontWeight.normal;
    final theme = Theme.of(context);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: () => _open(context),
      // アイコン長押しで「未読○件 / 既読○件」
      leading: Tooltip(
        triggerMode: TooltipTriggerMode.longPress,
        showDuration: const Duration(seconds: 3),
        textAlign: TextAlign.center,
        message: '未読${group.unreadCount}件\n既読${group.readCount}件',
        child: SenderAvatar(name: group.name, address: group.address),
      ),
      title: Row(
        children: [
          Expanded(
            child: Text(group.name,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: bold)),
          ),
          const SizedBox(width: 8),
          Text(formatReceived(group.latest.receivedAt),
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: bold,
                color: group.hasUnread ? theme.colorScheme.primary : null,
              )),
        ],
      ),
      subtitle: Row(
        children: [
          Expanded(
            child: Text(group.latest.subject,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontWeight: bold)),
          ),
          if (group.hasUnread) ...[
            const SizedBox(width: 8),
            Badge(label: Text('${group.unreadCount}')),
          ],
        ],
      ),
    );
  }
}
