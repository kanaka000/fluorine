import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../services/errors.dart';

/// メモの色（null は「指定なし」）
class MemoColor {
  const MemoColor(this.key, this.label, this.color);

  /// 保存に使う名前
  final String key;
  final String label;

  /// ライトモードでのカードの色
  final Color color;

  static const all = [
    MemoColor('red', '赤', Color(0xFFF8C9C4)),
    MemoColor('orange', 'オレンジ', Color(0xFFFBD9B0)),
    MemoColor('yellow', '黄', Color(0xFFFBF0A8)),
    MemoColor('green', '緑', Color(0xFFCDEBC0)),
    MemoColor('teal', '青緑', Color(0xFFB9E6DF)),
    MemoColor('blue', '青', Color(0xFFC3DBF7)),
    MemoColor('purple', '紫', Color(0xFFDCCDF2)),
    MemoColor('pink', 'ピンク', Color(0xFFF6CDE3)),
    MemoColor('gray', '灰', Color(0xFFDCDCDC)),
  ];

  static MemoColor? of(String? key) {
    for (final c in all) {
      if (c.key == key) return c;
    }
    return null;
  }

  /// 画面の明るさに合わせたカードの色（ダークモードでは暗めにする）
  Color cardColor(Brightness brightness, Color surface) =>
      brightness == Brightness.dark ? Color.alphaBlend(color.withValues(alpha: 0.30), surface) : color;
}

class Memo {
  Memo({
    String? id,
    required this.title,
    required this.body,
    required this.createdAt,
    DateTime? updatedAt,
    this.colorKey,
  })  : id = id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        updatedAt = updatedAt ?? createdAt;

  final String id;
  final String title;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 色の名前（MemoColor.key）。null なら指定なし
  final String? colorKey;

  MemoColor? get color => MemoColor.of(colorKey);

  /// 内容を変えた写し（更新日時は今にする）。色を外すときは clearColor: true
  Memo copyWith({String? title, String? body, String? colorKey, bool clearColor = false}) => Memo(
        id: id,
        title: title ?? this.title,
        body: body ?? this.body,
        createdAt: createdAt,
        updatedAt: DateTime.now(),
        colorKey: clearColor ? null : (colorKey ?? this.colorKey),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'body': body,
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
        'color': colorKey,
      };

  static Memo? fromJson(Object? j) {
    if (j is! Map) return null;
    final created = DateTime.tryParse(j['createdAt'] as String? ?? '');
    if (created == null) return null;
    return Memo(
      id: j['id'] as String?,
      title: j['title'] as String? ?? '',
      body: j['body'] as String? ?? '',
      createdAt: created,
      updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
      colorKey: j['color'] as String?,
    );
  }
}

/// メモの保管場所（端末内に保存。アプリを閉じても消えない）
final memoStore = MemoStore();

class MemoStore extends ChangeNotifier {
  static const _key = 'memos';

  /// 追加・変更・削除したときに呼ぶ（Notion連携が使う。main.dart で設定）
  static void Function(Memo m)? onSaved;
  static void Function(Memo m)? onRemoved;

  final List<Memo> _memos = [];
  SharedPreferences? _prefs;

  /// 更新日時の新しい順（新規メモは作成日時＝更新日時）
  List<Memo> get memos => [..._memos]..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));

  /// 端末に保存したメモを読み込む（起動時に1回）
  Future<void> load() async {
    final p = await SharedPreferences.getInstance();
    _prefs = p;
    final text = p.getString(_key);
    _memos.clear();
    if (text != null) {
      try {
        for (final j in jsonDecode(text) as List) {
          final m = Memo.fromJson(j);
          if (m != null) _memos.add(m);
        }
      } catch (e) {
        devLog('メモの読み込みに失敗: $e');
      }
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final p = _prefs ?? await SharedPreferences.getInstance();
    _prefs = p;
    await p.setString(_key, jsonEncode(_memos.map((m) => m.toJson()).toList()));
  }

  Memo? find(String id) {
    for (final m in _memos) {
      if (m.id == id) return m;
    }
    return null;
  }

  Future<Memo> add(Memo m) async {
    _memos.add(m);
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  /// Notionから復元したメモをまとめて入れる（2026-11-18）。
  /// Notionへは送り返さないので onSaved は呼ばない
  Future<void> addRestored(List<Memo> list) async {
    _memos.addAll(list);
    notifyListeners();
    await _save();
  }

  /// 「端末内のデータを消す」のあと（保存した分は消してあるので、画面の分だけ空にする。
  /// Notionのページはゴミ箱に入れないので onRemoved は呼ばない）
  void clearLocal() {
    _memos.clear();
    notifyListeners();
  }

  Future<Memo> update(Memo m) async {
    final i = _memos.indexWhere((x) => x.id == m.id);
    if (i >= 0) {
      _memos[i] = m;
    } else {
      _memos.add(m);
    }
    notifyListeners();
    await _save();
    onSaved?.call(m);
    return m;
  }

  Future<void> remove(Memo m) async {
    _memos.removeWhere((x) => x.id == m.id);
    notifyListeners();
    await _save();
    onRemoved?.call(m);
  }
}
