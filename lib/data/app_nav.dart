import 'package:material_ui/material_ui.dart';

/// 下部タブの番号（0:メール 1:カレンダー 2:タスク 3:メモ）
/// どの画面からでも tabIndex.value = 1 のようにしてタブを切り替えられる
final tabIndex = ValueNotifier<int>(0);

class Tabs {
  static const mail = 0;
  static const calendar = 1;
  static const task = 2;
  static const memo = 3;
}

/// メールタブの画面の移り変わりを見張る（最初の画面に戻ったことを知るため）
final mailRouteObserver = RouteObserver<ModalRoute<void>>();
