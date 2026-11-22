import 'package:material_ui/material_ui.dart';

// ✨の結果の型と、Claudeの返事から結果を作る部分（2026-11-19 の整理で分けた）

DateTime? aiDate(Object? v) {
  final d = DateTime.tryParse((v as String?)?.trim() ?? '');
  return d == null ? null : DateUtils.dateOnly(d);
}

TimeOfDay? aiTime(Object? v) {
  final m = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch((v as String?)?.trim() ?? '');
  return m == null ? null : TimeOfDay(hour: int.parse(m.group(1)!), minute: int.parse(m.group(2)!));
}

String? aiOptStr(Map<String, dynamic> input, String k) {
  final v = (input[k] as String?)?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

AiEvent aiEventFrom(Map<String, dynamic> input, {bool update = false}) {
  return AiEvent(
    update: update,
    replaces: (input['replaces'] as num?)?.toInt(),
    title: aiOptStr(input, 'title') ?? '',
    date: aiDate(input['date']),
    time: aiTime(input['time']),
    endDate: aiDate(input['end_date']),
    endTime: aiTime(input['end_time']),
    allDay: input['all_day'] is bool ? input['all_day'] as bool : null,
    location: aiOptStr(input, 'location'),
    note: aiOptStr(input, 'note'),
  );
}

int? aiInt(Object? v) => (v as num?)?.toInt();

/// 道具の結果を AiResult にする
AiResult aiResultFrom(({String? name, Map<String, dynamic> input, String text}) use) {
  final input = use.input;
  // 長すぎる値は切る（2026-11-18 B04。AIの答えもそのまま信じない）
  String str(String k) {
    final v = input[k] is String ? (input[k] as String).trim() : '';
    return v.length > 20000 ? v.substring(0, 20000) : v;
  }
  switch (use.name) {
    case 'create_event':
      return aiEventFrom(input);
    case 'update_event':
      return aiEventFrom(input, update: true);
    case 'delete_event':
      return AiDeleteEvent((input['number'] as num?)?.toInt());
    case 'update_task':
      return AiTaskUpdate(
        number: aiInt(input['number']),
        title: aiOptStr(input, 'title'),
        due: aiDate(input['due']),
        clearDue: input['clear_due'] == true,
        note: input['note'] is String ? (input['note'] as String).trim() : null,
      );
    case 'complete_task':
      return AiTaskComplete(aiInt(input['number']));
    case 'delete_task':
      return AiTaskDelete(aiInt(input['number']));
    case 'create_task':
      return AiTask(title: str('title'), due: aiDate(input['due']), note: str('note'));
    case 'update_memo':
      return AiMemoUpdate(
        number: aiInt(input['number']),
        title: aiOptStr(input, 'title'),
        body: input['body'] is String ? (input['body'] as String).trim() : null,
      );
    case 'delete_memo':
      return AiMemoDelete(aiInt(input['number']));
    case 'create_memo':
      return AiMemo(title: str('title'), body: str('body'));
    case 'draft_reply':
      return AiReply(str('body'));
    case 'draft_new_mail':
      return AiNewMail(
        toName: aiOptStr(input, 'to_name'),
        toAddress: aiOptStr(input, 'to_address'),
        subject: str('subject'),
        body: str('body'),
      );
    case 'link_item':
      return AiLink(
        unlink: input['action'] == 'unlink',
        target: switch (input['target']) {
          'memo' => LinkTarget.memo,
          'event' => LinkTarget.event,
          'task' => LinkTarget.task,
          _ => LinkTarget.mail,
        },
        keyword: aiOptStr(input, 'keyword'),
        sender: aiOptStr(input, 'sender'),
        date: aiDate(input['date']),
      );
    case 'search_mail':
      return AiMailSearch(
        keyword: aiOptStr(input, 'keyword'),
        sender: aiOptStr(input, 'sender'),
        hasAttachment: input['has_attachment'] == true,
        fileType: aiOptStr(input, 'file_type'),
        dateFrom: aiDate(input['date_from']),
        dateTo: aiDate(input['date_to']),
      );
    case 'open_mail':
      return AiOpenMail(
        fromSource: input['from_source'] == true,
        keyword: aiOptStr(input, 'keyword'),
        sender: aiOptStr(input, 'sender'),
        date: aiDate(input['date']),
      );
    case 'answer':
      return AiAnswer(str('text'));
    default:
      return AiAnswer(use.text.isEmpty ? 'うまく答えられませんでした。頼み方を変えてもう一度試してください。' : use.text);
  }
}

/// AIボタンの結果（どの操作になったか）
sealed class AiResult {}

/// 予定の作成（[update] が true なら、選んでいる予定の変更。省略された項目は null）
class AiEvent extends AiResult {
  AiEvent({
    this.update = false,
    this.replaces,
    required this.title,
    this.date,
    this.time,
    this.endDate,
    this.endTime,
    this.allDay,
    this.location,
    this.note,
  });
  final bool update;

  /// 日時を変える元の予定（「これからの予定」の番号。0 は選んでいる予定）。新規なら null
  final int? replaces;
  final String title;
  final DateTime? date;
  final TimeOfDay? time;
  final DateTime? endDate;
  final TimeOfDay? endTime;
  final bool? allDay;
  final String? location;
  final String? note;
}

/// 予定の削除の依頼（[number] は「これからの予定」の番号。null なら選んでいる予定）。
/// 削除はせず、確認画面を出すだけ
class AiDeleteEvent extends AiResult {
  AiDeleteEvent(this.number);
  final int? number;
}

class AiTask extends AiResult {
  AiTask({required this.title, this.due, this.note = ''});
  final String title;
  final DateTime? due;
  final String note;
}

/// タスクの変更（[number] は一覧の番号。null なら選んでいるタスク。省略された項目は null）
class AiTaskUpdate extends AiResult {
  AiTaskUpdate({this.number, this.title, this.due, this.clearDue = false, this.note});
  final int? number;
  final String? title;
  final DateTime? due;
  final bool clearDue;
  final String? note;
}

/// タスクを完了にする依頼（確認画面を出すだけ）
class AiTaskComplete extends AiResult {
  AiTaskComplete(this.number);
  final int? number;
}

/// タスクの削除の依頼（確認画面を出すだけ）
class AiTaskDelete extends AiResult {
  AiTaskDelete(this.number);
  final int? number;
}

class AiMemo extends AiResult {
  AiMemo({required this.title, required this.body});
  final String title;
  final String body;
}

/// メモの変更（[number] は一覧の番号。null なら選んでいるメモ。省略された項目は null）
class AiMemoUpdate extends AiResult {
  AiMemoUpdate({this.number, this.title, this.body});
  final int? number;
  final String? title;
  final String? body;
}

/// メモの削除の依頼（確認画面を出すだけ）
class AiMemoDelete extends AiResult {
  AiMemoDelete(this.number);
  final int? number;
}

/// 新しいメールの下書き（宛先は名前かアドレス。名前のときは連絡先から探す）
class AiNewMail extends AiResult {
  AiNewMail({this.toName, this.toAddress, required this.subject, required this.body});
  final String? toName;
  final String? toAddress;
  final String subject;
  final String body;
}

class AiReply extends AiResult {
  AiReply(this.body);
  final String body;
}

class AiAnswer extends AiResult {
  AiAnswer(this.text);
  final String text;
}

/// リンクの相手の種類
enum LinkTarget { memo, event, task, mail }

/// リンクを付ける・外す（2026-11-19）。相手はアプリの中で [keyword] などから探す
class AiLink extends AiResult {
  AiLink({required this.unlink, required this.target, this.keyword, this.sender, this.date});
  final bool unlink;
  final LinkTarget target;
  final String? keyword;
  final String? sender;
  final DateTime? date;
}

/// メールを探す（2026-11-19）。アプリが Gmail の検索で探す
class AiMailSearch extends AiResult {
  AiMailSearch({this.keyword, this.sender, this.hasAttachment = false, this.fileType, this.dateFrom, this.dateTo});
  final String? keyword;
  final String? sender;
  final bool hasAttachment;

  /// pdf／image／word／excel／powerpoint
  final String? fileType;
  final DateTime? dateFrom;
  final DateTime? dateTo;
}

/// メールを開いて表示する（2026-11-22。メモの詳細画面の✨）。
/// [fromSource] が true ならメモの元になったメール。探して開くのはアプリ
class AiOpenMail extends AiResult {
  AiOpenMail({this.fromSource = false, this.keyword, this.sender, this.date});
  final bool fromSource;
  final String? keyword;
  final String? sender;
  final DateTime? date;
}
