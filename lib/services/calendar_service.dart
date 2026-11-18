import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;

import '../data/calendar_store.dart';

/// Googleカレンダー（メインのカレンダー）とのやり取り
class CalendarService {
  CalendarService(http.Client client) : _api = gcal.CalendarApi(client);

  final gcal.CalendarApi _api;
  static const _cal = 'primary';

  /// 今日から指定日数先までの予定を取得する
  Future<List<CalendarEvent>> fetchUpcoming({int days = 60}) {
    final now = DateTime.now();
    final from = DateTime(now.year, now.month, now.day);
    return fetchRange(from, from.add(Duration(days: days)));
  }

  /// [from] から [to] までの予定を取得する（月表示で、その月の予定を読むのに使う）
  Future<List<CalendarEvent>> fetchRange(DateTime from, DateTime to) async {
    final result = <CalendarEvent>[];
    String? pageToken;
    do {
      final res = await _api.events.list(
        _cal,
        timeMin: from.toUtc(),
        timeMax: to.toUtc(),
        singleEvents: true,
        orderBy: 'startTime',
        maxResults: 250,
        pageToken: pageToken,
      );
      for (final e in res.items ?? <gcal.Event>[]) {
        final ev = _fromGoogle(e);
        if (ev != null) result.add(ev);
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null && result.length < 2000);
    return result;
  }

  static CalendarEvent? _fromGoogle(gcal.Event e) {
    final dt = e.start?.dateTime;
    final date = e.start?.date;
    if (dt == null && date == null) return null;
    final allDay = dt == null;
    final start = dt?.toLocal() ?? DateTime(date!.year, date.month, date.day);
    final endDt = e.end?.dateTime;
    final endDate = e.end?.date;
    DateTime? end;
    if (allDay && endDate != null) {
      end = DateTime(endDate.year, endDate.month, endDate.day);
    } else if (!allDay && endDt != null) {
      end = endDt.toLocal();
    }
    return CalendarEvent(
      id: e.id,
      title: (e.summary ?? '').isEmpty ? '（タイトルなし）' : e.summary!,
      start: start,
      end: end,
      allDay: allDay,
      note: e.description,
      location: e.location,
      recurring: e.recurringEventId != null,
    );
  }

  /// Googleに送る形にする（終日は終了日を「翌日」で表す）
  static gcal.Event _toGoogle(CalendarEvent e) {
    final event = gcal.Event(
      summary: e.title,
      description: e.note ?? '',
      location: e.location ?? '',
    );
    if (e.allDay) {
      DateTime d(DateTime x) => DateTime(x.year, x.month, x.day);
      event.start = gcal.EventDateTime(date: d(e.start));
      event.end = gcal.EventDateTime(date: d(e.end));
    } else {
      final tz = DateTime.now().timeZoneName;
      event.start = gcal.EventDateTime(dateTime: e.start, timeZone: _ianaOrNull(tz));
      event.end = gcal.EventDateTime(dateTime: e.end, timeZone: _ianaOrNull(tz));
    }
    return event;
  }

  /// 端末のタイムゾーン名がIANA形式（Asia/Tokyo など）のときだけ使う。JST などは送らない
  static String? _ianaOrNull(String name) => name.contains('/') ? name : null;

  /// 予定を追加し、Google側のIDが付いた予定を返す
  Future<CalendarEvent> insert(CalendarEvent e) async {
    final created = await _api.events.insert(_toGoogle(e), _cal);
    return _fromGoogle(created) ?? e;
  }

  /// 予定を変更する（繰り返しの予定は、この回だけが変わる）
  /// 今の予定を取り直して、タイトル・日時・場所・メモだけを差し替える（参加者などはそのまま）
  Future<CalendarEvent> update(CalendarEvent e) async {
    final current = await _api.events.get(_cal, e.id!);
    final changed = _toGoogle(e);
    current
      ..summary = changed.summary
      ..description = changed.description
      ..location = changed.location
      ..start = changed.start
      ..end = changed.end;
    final updated = await _api.events.update(current, _cal, e.id!);
    return _fromGoogle(updated) ?? e;
  }

  /// 予定を削除する（繰り返しの予定は、この回だけが消える）
  Future<void> delete(String id) => _api.events.delete(_cal, id);
}
