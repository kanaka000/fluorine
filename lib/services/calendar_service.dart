import 'package:googleapis/calendar/v3.dart' as gcal;
import 'package:http/http.dart' as http;

import '../data/models.dart';
import '../data/link_lines.dart';

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

  /// 日本の祝日のカレンダー（Google が公開している「日本の祝日」。法律で決まった祝日だけ。2026-11-24 の22）
  /// 記念日・銀行休業日も入る ja.japanese#holiday ではなく official のほうを使う
  static const holidayCalendarId = 'ja.japanese.official#holiday@group.v.calendar.google.com';

  /// [from] から [to] までの祝日を「日付 → 祝日名」で返す（読むだけ。今の権限 calendar.events で読める見込み）。
  /// official にも銀行休業日が混じることがあるという報告があるので、名前で外す
  Future<Map<DateTime, String>> fetchHolidays(DateTime from, DateTime to) async {
    final result = <DateTime, String>{};
    String? pageToken;
    do {
      final res = await _api.events.list(
        holidayCalendarId,
        timeMin: from.toUtc(),
        timeMax: to.toUtc(),
        singleEvents: true,
        maxResults: 250,
        pageToken: pageToken,
      );
      for (final e in res.items ?? <gcal.Event>[]) {
        final name = (e.summary ?? '').trim();
        final date = e.start?.date;
        if (name.isEmpty || date == null || name.contains('銀行休業日')) continue;
        final endDate = e.end?.date;
        var d = DateTime(date.year, date.month, date.day);
        final last = endDate == null ? d : DateTime(endDate.year, endDate.month, endDate.day);
        // 終日の予定の終わりは「翌日」で表される。1日だけのものがほとんどだが、念のため日ごとに入れる
        do {
          result[d] = result[d] == null ? name : '${result[d]}・$name';
          d = DateTime(d.year, d.month, d.day + 1);
        } while (d.isBefore(last));
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null && result.length < 1000);
    return result;
  }

  /// 予定を ID で1件読む（タスクにつないだ予定を開くため。2026-11-24 の25）。
  /// 消された予定（cancelled）・見つからない予定は null
  Future<CalendarEvent?> get(String id) async {
    try {
      final e = await _api.events.get(_cal, id);
      if (e.status == 'cancelled') return null;
      return _fromGoogle(e);
    } on gcal.DetailedApiRequestError catch (e) {
      if (e.status == 404 || e.status == 410) return null;
      rethrow;
    }
  }

  /// メモ欄の文字で予定を探す（メールのリンクの逆引き用。期間は限らない。2026-11-19）
  Future<List<CalendarEvent>> search(String text) async {
    final res = await _api.events.list(_cal, q: text, singleEvents: true, maxResults: 50);
    return (res.items ?? <gcal.Event>[]).map(_fromGoogle).whereType<CalendarEvent>().toList();
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
    final split = splitMemoLinks(e.description);
    return CalendarEvent(
      id: e.id,
      title: (e.summary ?? '').isEmpty ? '（タイトルなし）' : e.summary!,
      start: start,
      end: end,
      allDay: allDay,
      note: split.body,
      memoLinks: split.links,
      mailLinks: split.mails,
      colorKey: split.color,
      location: e.location,
      recurring: e.recurringEventId != null,
    );
  }

  /// Googleに送る形にする（終日は終了日を「翌日」で表す）
  static gcal.Event _toGoogle(CalendarEvent e) {
    final event = gcal.Event(
      summary: e.title,
      description: joinMemoLinks(e.note, e.memoLinks, mails: e.mailLinks, color: e.colorKey),
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
