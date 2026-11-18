import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/app_nav.dart';
import '../data/calendar_store.dart';
import '../data/mail_store.dart';
import '../data/task_store.dart';
import '../widgets/tab_marks.dart';
import 'calendar_screen.dart';
import 'memo_screen.dart';
import 'sender_list_screen.dart';
import 'task_screen.dart';

/// 画面下のタブ（メール／カレンダー／タスク／メモ）
/// タブごとに画面の履歴を持つので、作業途中の画面に戻ってこられる
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> with WidgetsBindingObserver {
  int get _index => tabIndex.value;

  /// タブの印（今日・明日）を、時間がたったり日付が変わったりしたら付け直すためのタイマー
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    tabIndex.addListener(_onTabChanged);
    WidgetsBinding.instance.addObserver(this);
    _ticker = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    tabIndex.removeListener(_onTabChanged);
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    super.dispose();
  }

  /// アプリに戻ってきたら、タブの印を付け直す
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) setState(() {});
  }

  void _onTabChanged() => setState(() {});
  final _navKeys = List.generate(4, (_) => GlobalKey<NavigatorState>());

  static const _roots = <Widget>[
    SenderListScreen(),
    CalendarScreen(),
    TaskScreen(),
    MemoScreen(),
  ];

  void _onSelect(int i) {
    if (i == _index) {
      // 選択中のタブをもう一度押すと、そのタブの最初の画面に戻る
      _navKeys[i].currentState?.popUntil((r) => r.isFirst);
    } else {
      tabIndex.value = i;
    }
  }

  void _onBack() {
    final nav = _navKeys[_index].currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
    } else if (_index != 0) {
      tabIndex.value = 0;
    } else {
      SystemNavigator.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardOpen = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onBack();
      },
      child: Scaffold(
        // キーボード表示中の高さ調整は各タブの画面側で行う
        resizeToAvoidBottomInset: false,
        body: IndexedStack(
          index: _index,
          children: [
            for (var i = 0; i < _roots.length; i++)
              Navigator(
                key: _navKeys[i],
                observers: i == Tabs.mail ? [mailRouteObserver] : const [],
                onGenerateRoute: (_) => MaterialPageRoute(builder: (_) => _roots[i]),
              ),
          ],
        ),
        // キーボード表示中はタブを隠す
        bottomNavigationBar: keyboardOpen
            ? null
            : ListenableBuilder(
                listenable: Listenable.merge([mailStore, calendarStore, taskStore]),
                builder: (context, _) {
                  final calMarks = calendarMarks();
                  final taskMarks_ = taskMarks();
                  final unread = mailStore.groups.fold<int>(0, (s, g) => s + g.unreadCount);
                  return NavigationBar(
                    selectedIndex: _index,
                    onDestinationSelected: _onSelect,
                    destinations: [
                      NavigationDestination(
                        icon: Badge(
                          isLabelVisible: unread > 0,
                          label: Text('$unread'),
                          child: const Icon(Icons.mail_outline),
                        ),
                        selectedIcon: Badge(
                          isLabelVisible: unread > 0,
                          label: Text('$unread'),
                          child: const Icon(Icons.mail),
                        ),
                        label: 'メール',
                      ),
                      // 今日に予定があれば右上に赤、明日にあれば右下に青の点
                      NavigationDestination(
                        icon: MarkedIcon(icon: Icons.calendar_today_outlined, marks: calMarks),
                        selectedIcon: MarkedIcon(icon: Icons.calendar_today, marks: calMarks),
                        label: 'カレンダー',
                      ),
                      NavigationDestination(
                        icon: MarkedIcon(icon: Icons.check_box_outlined, marks: taskMarks_),
                        selectedIcon: MarkedIcon(icon: Icons.check_box, marks: taskMarks_),
                        label: 'タスク',
                      ),
                      const NavigationDestination(
                        icon: Icon(Icons.sticky_note_2_outlined),
                        selectedIcon: Icon(Icons.sticky_note_2),
                        label: 'メモ',
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }
}
