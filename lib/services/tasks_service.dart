import 'package:googleapis/tasks/v1.dart' as gtasks;
import 'package:http/http.dart' as http;

import '../data/link_lines.dart';
import '../data/models.dart';

/// Google ToDoリスト（デフォルトのリスト）とのやり取り
class TasksService {
  TasksService(http.Client client) : _api = gtasks.TasksApi(client);

  final gtasks.TasksApi _api;
  static const _list = '@default';

  Future<List<TaskItem>> fetchAll() async {
    final result = <TaskItem>[];
    String? pageToken;
    do {
      final res = await _api.tasks.list(
        _list,
        showCompleted: true,
        showHidden: true, // ToDoリストのアプリで完了にしたタスクも含める
        maxResults: 100,
        pageToken: pageToken,
      );
      for (final t in res.items ?? <gtasks.Task>[]) {
        final item = _fromGoogle(t);
        if (item != null) result.add(item);
      }
      pageToken = res.nextPageToken;
    } while (pageToken != null && result.length < 500);
    return result;
  }

  static TaskItem? _fromGoogle(gtasks.Task t) {
    if ((t.title ?? '').trim().isEmpty) return null;
    DateTime? due;
    if (t.due != null) {
      final u = DateTime.parse(t.due!).toUtc();
      due = DateTime(u.year, u.month, u.day); // ToDoリストの期限は日付のみ
    }
    final split = splitMemoLinks(t.notes);
    return TaskItem(
      title: t.title!,
      due: due,
      note: split.body,
      memoLinks: split.links,
      mailLinks: split.mails,
      done: t.status == 'completed',
      googleTask: t,
    );
  }

  static String? _dueText(DateTime? due) =>
      due == null ? null : DateTime.utc(due.year, due.month, due.day).toIso8601String();

  Future<TaskItem> insert(TaskItem item) async {
    final created = await _api.tasks.insert(
      gtasks.Task(
        title: item.title,
        notes: joinMemoLinks(item.note, item.memoLinks, item.mailLinks),
        due: _dueText(item.due),
      ),
      _list,
    );
    return _fromGoogle(created) ?? item;
  }

  /// タイトル・期限・メモを変更する（期限を消すときは due を null に）
  Future<TaskItem> update(TaskItem item) async {
    final t = item.googleTask;
    if (t == null || t.id == null) return item;
    t
      ..title = item.title
      ..notes = joinMemoLinks(item.note, item.memoLinks, item.mailLinks)
      ..due = _dueText(item.due);
    final updated = await _api.tasks.update(t, _list, t.id!);
    return _fromGoogle(updated) ?? item;
  }

  /// 完了／未完了を切り替える
  Future<void> setDone(TaskItem item, bool done) async {
    final t = item.googleTask;
    if (t == null || t.id == null) return;
    t.status = done ? 'completed' : 'needsAction';
    if (!done) t.completed = null;
    await _api.tasks.update(t, _list, t.id!);
  }

  Future<void> delete(TaskItem item) async {
    final id = item.googleTask?.id;
    if (id == null) return;
    await _api.tasks.delete(_list, id);
  }
}
