import 'dart:ui';

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
