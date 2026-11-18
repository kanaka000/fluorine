import 'package:flutter/material.dart';

import 'timed_snack.dart';
import '../services/errors.dart';

/// スワイプ中に見える赤い背景（ゴミ箱アイコン付き）
Widget swipeDeleteBackground(BuildContext context, Alignment alignment, {EdgeInsets margin = EdgeInsets.zero, double radius = 0}) {
  final theme = Theme.of(context);
  return Container(
    margin: margin,
    padding: const EdgeInsets.symmetric(horizontal: 24),
    alignment: alignment,
    decoration: BoxDecoration(
      color: theme.colorScheme.error,
      borderRadius: BorderRadius.circular(radius),
    ),
    child: Icon(Icons.delete_outline, color: theme.colorScheme.onError),
  );
}

/// 左右どちらかにスワイプすると削除する行。
/// [onDelete] で削除し、失敗したらお知らせを出す。成功したら「元に戻す」付きのお知らせ（[onUndo]）
class SwipeToDelete extends StatelessWidget {
  const SwipeToDelete({
    super.key,
    required this.itemKey,
    required this.message,
    required this.onDelete,
    required this.onUndo,
    required this.child,
  });

  final Key itemKey;
  final String message;
  final Future<void> Function() onDelete;
  final Future<void> Function() onUndo;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Dismissible(
      key: itemKey,
      background: swipeDeleteBackground(context, Alignment.centerLeft),
      secondaryBackground: swipeDeleteBackground(context, Alignment.centerRight),
      onDismissed: (_) async {
        final messenger = ScaffoldMessenger.of(context);
        try {
          await onDelete();
        } catch (e) {
          messenger.showSnackBar(SnackBar(content: Text('削除できませんでした：${friendlyError(e)}')));
          return;
        }
        // この行はもう画面から消えているので、先に取っておいた messenger でお知らせを出す
        showTimedSnackOn(messenger, message, actionLabel: '元に戻す', onAction: () async {
          try {
            await onUndo();
          } catch (e) {
            messenger.showSnackBar(SnackBar(content: Text('元に戻せませんでした：${friendlyError(e)}')));
          }
        });
      },
      child: child,
    );
  }
}
