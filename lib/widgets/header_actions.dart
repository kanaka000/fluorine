import 'package:material_ui/material_ui.dart';

import '../services/ai/api_key_store.dart';
import '../services/claude_service.dart';
import 'ai_prompt.dart';

/// ≡メニューの1項目
class HeaderMenuItem {
  const HeaderMenuItem({
    required this.label,
    this.icon,
    this.onTap,
    this.enabled = true,
    this.dividerBefore = false,
  });

  final String label;
  final IconData? icon;
  final VoidCallback? onTap;

  /// false なら押せない見出し（例：ログイン中のアドレス）
  final bool enabled;

  /// true ならこの項目の上に区切り線を入れる
  final bool dividerBefore;
}

/// AIボタン（✨）。タップ＝音声で頼む、長押し＝文字で頼む
class AiButton extends StatelessWidget {
  const AiButton({super.key, required this.onTap, this.onLongPress, this.busy = false});

  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// true のあいだは考え中の表示にして押せなくする
  final bool busy;

  @override
  Widget build(BuildContext context) {
    if (busy) {
      return const Padding(
        padding: EdgeInsets.all(14),
        child: SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    // APIキーがないときは薄く表示し、押したら使い方の案内だけ出す（2026-11-18）。
    // キーは設定画面で入れ替えられるので、変わったら描き直す（2026-11-23）
    return ListenableBuilder(listenable: apiKeyStore, builder: (context, _) => _button(context));
  }

  Widget _button(BuildContext context) {
    final available = ClaudeService.available;
    final theme = Theme.of(context);
    return Semantics(
      button: true,
      label: available ? 'AIに頼む' : 'AIは使えません（APIキーが未設定）',
      child: InkResponse(
        onTap: available ? onTap : () => showAiUnavailable(context),
        onLongPress: available ? onLongPress : () => showAiUnavailable(context),
        radius: 24,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Icon(
            Icons.auto_awesome,
            color: available ? theme.colorScheme.primary : theme.colorScheme.outline.withValues(alpha: 0.5),
          ),
        ),
      ),
    );
  }
}

/// 4タブ共通の右上ボタン：［AI］［≡］
///
/// - [onAi] を渡したときだけ AI ボタンを表示する（[onAiLongPress] は長押し）
/// - ≡ を押すと [menuItems] のメニューが出る
List<Widget> headerActions({
  required List<HeaderMenuItem> menuItems,
  VoidCallback? onAi,
  VoidCallback? onAiLongPress,
  bool aiBusy = false,
}) {
  return [
    if (onAi != null) AiButton(onTap: onAi, onLongPress: onAiLongPress, busy: aiBusy),
    _HeaderMenuButton(items: menuItems),
  ];
}

class _HeaderMenuButton extends StatelessWidget {
  const _HeaderMenuButton({required this.items});

  final List<HeaderMenuItem> items;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<int>(
      icon: const Icon(Icons.menu),
      tooltip: 'メニュー',
      onSelected: (i) => items[i].onTap?.call(),
      itemBuilder: (_) {
        final entries = <PopupMenuEntry<int>>[];
        for (var i = 0; i < items.length; i++) {
          final item = items[i];
          if (item.dividerBefore && entries.isNotEmpty) {
            entries.add(const PopupMenuDivider());
          }
          entries.add(PopupMenuItem<int>(
            value: i,
            enabled: item.enabled,
            child: item.icon == null
                ? Text(item.label)
                : Row(
                    children: [
                      Icon(item.icon, size: 20),
                      const SizedBox(width: 12),
                      Flexible(child: Text(item.label, overflow: TextOverflow.ellipsis)),
                    ],
                  ),
          ));
        }
        return entries;
      },
    );
  }
}
