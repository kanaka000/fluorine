import 'package:flutter/foundation.dart';

import '../services/google_auth.dart';
import '../services/tasks_service.dart';
import 'models/task_item.dart';
import '../services/errors.dart';

export 'models/task_item.dart';

/// タスクの保管場所（ログイン後はGoogle ToDoリスト。ログアウト中は空）
final taskStore = TaskStore([]);

class TaskStore extends ChangeNotifier {
  TaskStore(this._tasks);

  final List<TaskItem> _tasks;
  TasksService? _service;

  bool loading = false;
  String? error;

  bool get usingGoogle => _service != null;

  /// 未完了を上に、その中は期限が近い順
  List<TaskItem> get tasks {
    final list = [..._tasks];
    list.sort((a, b) {
      if (a.done != b.done) return a.done ? 1 : -1;
      if (a.due == null && b.due == null) return 0;
      if (a.due == null) return 1;
      if (b.due == null) return -1;
      return a.due!.compareTo(b.due!);
    });
    return list;
  }

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
        error = 'Google ToDoリストへのアクセスがまだ許可されていません';
      } else {
        final service = TasksService(client);
        final list = await service.fetchAll();
        googleAuth.checkSession(gen);
        _service = service;
        _tasks
          ..clear()
          ..addAll(list);
      }
    } on StaleSession {
      // ログアウト・アカウントの切り替えの前に始めた読み込み → 結果は捨てる
    } catch (e) {
      if (gen == googleAuth.session) error = 'タスクの読み込みに失敗しました：${friendlyError(e)}';
    } finally {
      if (gen == googleAuth.session) {
        loading = false;
        notifyListeners();
      }
    }
  }

  /// タスクを追加する（連携中はGoogle側にも保存。失敗すると例外）
  Future<TaskItem> add(TaskItem t) async {
    final saved = await _service?.insert(t) ?? t;
    _tasks.add(saved);
    notifyListeners();
    return saved;
  }

  /// タスクを変更する（[old] を [changed] に置き換える。失敗すると例外）
  Future<TaskItem> update(TaskItem old, TaskItem changed) async {
    final saved = await _service?.update(changed) ?? changed;
    final i = _tasks.indexWhere((x) => x.sameAs(old));
    if (i >= 0) {
      _tasks[i] = saved;
    } else {
      _tasks.add(saved);
    }
    notifyListeners();
    return saved;
  }

  /// タスクを削除する。先に一覧から消し、Google側で失敗したら一覧に戻して例外を投げる
  Future<void> remove(TaskItem t) async {
    final i = _tasks.indexWhere((x) => x.sameAs(t));
    if (i < 0) return;
    final removed = _tasks.removeAt(i);
    notifyListeners();
    try {
      await _service?.delete(t);
    } catch (_) {
      _tasks.add(removed);
      notifyListeners();
      rethrow;
    }
  }

  /// 削除したタスクを元に戻す（Googleには新しいタスクとして作り直す。完了済みなら完了にする）
  Future<void> restore(TaskItem t) async {
    final saved = await add(TaskItem(title: t.title, due: t.due, note: t.note, memoLinks: t.memoLinks, mailLinks: t.mailLinks));
    if (t.done) await toggle(saved);
  }

  /// 一覧のタスクのうち、[t] と同じもの（変更後の最新の状態）。なければ null
  TaskItem? find(TaskItem t) {
    for (final x in _tasks) {
      if (x.sameAs(t)) return x;
    }
    return null;
  }

  Future<void> toggle(TaskItem t) async {
    t.done = !t.done;
    notifyListeners();
    try {
      await _service?.setDone(t, t.done);
    } catch (e) {
      t.done = !t.done; // 失敗したら元に戻す
      error = '更新に失敗しました：${friendlyError(e)}';
      notifyListeners();
    }
  }

  /// 自動読み込みがオフのとき：ダミーを消して、手動で読み込むまで空にする
  void clearForManual() {
    if (_service != null) return;
    _tasks.clear();
    notifyListeners();
  }

  /// ログアウト時：空にする
  void resetForSignOut() {
    loading = false; // 読み込み中でも、ログインし直したらすぐ読み込めるように
    _service = null;
    error = null;
    _tasks.clear();
    notifyListeners();
  }
}
