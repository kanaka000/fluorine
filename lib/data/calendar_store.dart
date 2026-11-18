import 'package:flutter/material.dart';

import '../services/calendar_service.dart';
import 'app_settings.dart';
import '../services/google_auth.dart';
import '../services/errors.dart';

class CalendarEvent {
  CalendarEvent({
    this.id,
    required this.title,
    required this.start,
    DateTime? end,
    this.allDay = false,
    this.note,
    this.location,
    this.recurring = false,
  }) : end = end ??
            (allDay
                ? DateTime(start.year, start.month, start.day + 1)
                : start.add(const Duration(hours: 1)));

  /// Googleカレンダーの予定ID（ダミーや未保存なら null）
  final String? id;
  final String title;
  final DateTime start;

  /// 終了日時。終日の予定は「最後の日の翌日」（Googleカレンダーと同じ表し方）
  final DateTime end;
  final bool allDay;
  final String? note;
  final String? location;

  /// 繰り返しの予定の1回分か
  final bool recurring;

  /// 終日の予定の最後の日
  DateTime get lastDay => DateTime(end.year, end.month, end.day - 1);

  CalendarEvent copyWith({
    String? title,
    DateTime? start,
    DateTime? end,
    bool? allDay,
    String? note,
    String? location,
  }) =>
      CalendarEvent(
        id: id,
        title: title ?? this.title,
        start: start ?? this.start,
        end: end ?? this.end,
        allDay: allDay ?? this.allDay,
        note: note ?? this.note,
        location: location ?? this.location,
        recurring: recurring,
      );
}

/// 予定の保管場所（ログイン後はGoogleカレンダー。ログアウト中は空）
final calendarStore = CalendarStore([]);

class CalendarStore extends ChangeNotifier {
  CalendarStore(this._events);

  final List<CalendarEvent> _events;
  CalendarService? _service;

  bool loading = false;
  String? error;

  bool get usingGoogle => _service != null;

  // ---- 月表示用：月ごとに読み込んだ予定（キーは月の1日） ----
  final Map<DateTime, List<CalendarEvent>> _months = {};
  final Set<DateTime> _monthsLoading = {};

  /// 最後に月表示で開いた月（再読み込みのあと、この月も読み直す）
  DateTime? _lastMonth;

  bool get monthLoading => _monthsLoading.isNotEmpty;

  static DateTime _monthKey(DateTime d) => DateTime(d.year, d.month);

  /// 月表示：[anyDay] を含む月の予定を読み込む（読み込み済みなら何もしない）
  Future<void> loadMonth(DateTime anyDay, {bool force = false}) async {
    final key = _monthKey(anyDay);
    _lastMonth = key;
    final service = _service;
    if (service == null || _monthsLoading.contains(key)) return;
    if (!force && _months.containsKey(key)) return;
    _monthsLoading.add(key);
    notifyListeners();
    final gen = googleAuth.session; // 途中でログアウトしたら結果を捨てる（2026-11-18）
    try {
      // 画面には前後の月の日も出るので、1週間ずつ広めに読む
      final from = key.subtract(const Duration(days: 7));
      final to = DateTime(key.year, key.month + 1, 8);
      final list = await service.fetchRange(from, to);
      if (gen != googleAuth.session) return;
      _months[key] = list;
    } catch (e) {
      if (gen == googleAuth.session) error = '予定の読み込みに失敗しました：${friendlyError(e)}';
    } finally {
      if (gen == googleAuth.session) {
        _monthsLoading.remove(key);
        notifyListeners();
      }
    }
  }

  /// 月表示：その日にかかっている予定（終日を先に、あとは開始の早い順）
  List<CalendarEvent> eventsOn(DateTime day) {
    final start = DateTime(day.year, day.month, day.day);
    final end = DateTime(start.year, start.month, start.day + 1);
    final seen = <String>{};
    final result = <CalendarEvent>[];
    // 一覧の予定（変更・追加が反映済み）を先に見て、月ごとに読んだ分と重なるものは除く
    for (final e in [..._events, for (final list in _months.values) ...list]) {
      final overlaps = e.start.isBefore(end) &&
          (e.end.isAfter(start) || (e.start == e.end && !e.start.isBefore(start)));
      if (!overlaps) continue;
      if (e.id != null && !seen.add(e.id!)) continue;
      result.add(e);
    }
    result.sort((a, b) {
      if (a.allDay != b.allDay) return a.allDay ? -1 : 1;
      return a.start.compareTo(b.start);
    });
    return result;
  }

  /// 月ごとに読んだ分から、その予定を取り除く
  void _removeFromMonths(CalendarEvent e) {
    for (final list in _months.values) {
      list.removeWhere((x) => identical(x, e) || (e.id != null && x.id == e.id));
    }
  }

  List<CalendarEvent> get events =>
      [..._events]..sort((a, b) => a.start.compareTo(b.start));

  Future<void> reload({bool prompt = false}) async {
    if (!googleAuth.signedIn || loading) return;
    final gen = googleAuth.session; // 途中でログアウトしたら結果を捨てる（2026-11-18）
    loading = true;
    error = null;
    notifyListeners();
    try {
      final client = await googleAuth.authorizedClient(prompt: prompt);
      googleAuth.checkSession(gen);
      if (client == null) {
        error = 'Googleカレンダーへのアクセスがまだ許可されていません';
      } else {
        final service = CalendarService(client);
        final list = await service.fetchUpcoming(days: appSettings.calendarDays);
        googleAuth.checkSession(gen);
        _service = service;
        _events
          ..clear()
          ..addAll(list);
        _months.clear();
      }
    } on StaleSession {
      // ログアウト・アカウントの切り替えの前に始めた読み込み → 結果は捨てる
    } catch (e) {
      if (gen == googleAuth.session) error = '予定の読み込みに失敗しました：${friendlyError(e)}';
    } finally {
      if (gen == googleAuth.session) {
        loading = false;
        notifyListeners();
      }
    }
    // 月表示で見ていた月も読み直す
    final month = _lastMonth;
    if (month != null && _service != null) loadMonth(month, force: true);
  }

  /// 予定を追加する（Google連携中ならGoogleカレンダーにも保存。失敗すると例外）
  Future<CalendarEvent> add(CalendarEvent e) async {
    final saved = await _service?.insert(e) ?? e;
    _events.add(saved);
    notifyListeners();
    return saved;
  }

  /// 予定を変更する（[old] を [changed] に置き換える。失敗すると例外）
  Future<CalendarEvent> update(CalendarEvent old, CalendarEvent changed) async {
    final service = _service;
    final saved = (service != null && changed.id != null) ? await service.update(changed) : changed;
    final i = _events.indexWhere((e) => identical(e, old) || (old.id != null && e.id == old.id));
    if (i >= 0) {
      _events[i] = saved;
    } else {
      _events.add(saved);
    }
    notifyListeners();
    return saved;
  }

  /// 予定を削除する。先に一覧から消し、Google側で失敗したら一覧に戻して例外を投げる
  Future<void> remove(CalendarEvent e) async {
    final i = _events.indexWhere((x) => identical(x, e) || (e.id != null && x.id == e.id));
    final inMonths = _months.values
        .any((list) => list.any((x) => identical(x, e) || (e.id != null && x.id == e.id)));
    if (i < 0 && !inMonths) return;
    final removed = i >= 0 ? _events.removeAt(i) : e;
    _removeFromMonths(e);
    notifyListeners();
    final service = _service;
    if (service == null || e.id == null) return;
    try {
      await service.delete(e.id!);
    } catch (_) {
      _events.add(removed); // 失敗したら戻す（月表示にも出る）
      notifyListeners();
      rethrow;
    }
  }

  /// 削除した予定を元に戻す（Googleには新しい予定として作り直す）
  Future<CalendarEvent> restore(CalendarEvent e) => add(CalendarEvent(
        title: e.title,
        start: e.start,
        end: e.end,
        allDay: e.allDay,
        note: e.note,
        location: e.location,
      ));

  /// 自動読み込みがオフのとき：ダミーを消して、手動で読み込むまで空にする
  void clearForManual() {
    if (_service != null) return;
    _events.clear();
    notifyListeners();
  }

  /// ログアウト時：空にする
  void resetForSignOut() {
    loading = false; // 読み込み中でも、ログインし直したらすぐ読み込めるように
    _monthsLoading.clear();
    _service = null;
    error = null;
    _events.clear();
    _months.clear();
    _lastMonth = null;
    notifyListeners();
  }
}

