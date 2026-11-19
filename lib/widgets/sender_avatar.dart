import 'package:flutter/material.dart';

/// かっこ・記号・空白（【 「 ( ★ など）
final _skipChar = RegExp(r'^[\p{P}\p{S}\s]', unicode: true);

/// アイコンに出す1文字。先頭のかっこ・記号・空白は飛ばす（「【公式】ヤマト」→「公」。2026-11-19）。
/// 全部が記号なら最初の文字、空なら「?」
String avatarInitial(String name) {
  for (final c in name.characters) {
    if (!_skipChar.hasMatch(c)) return c;
  }
  return name.isEmpty ? '?' : name.characters.first;
}

/// 送信元のアイコン（頭文字＋アドレスから決まる色）
class SenderAvatar extends StatelessWidget {
  const SenderAvatar({super.key, required this.name, required this.address, this.radius = 22});

  final String name;
  final String address;
  final double radius;

  static const _colors = [
    Color(0xFF5C6BC0),
    Color(0xFF26A69A),
    Color(0xFFEF6C00),
    Color(0xFF8D6E63),
    Color(0xFFAB47BC),
    Color(0xFF42A5F5),
    Color(0xFFEC407A),
    Color(0xFF66BB6A),
  ];

  @override
  Widget build(BuildContext context) {
    final color = _colors[address.hashCode.abs() % _colors.length];
    final initial = avatarInitial(name);
    return CircleAvatar(
      radius: radius,
      backgroundColor: color,
      child: Text(initial,
          style: TextStyle(color: Colors.white, fontSize: radius * 0.8, fontWeight: FontWeight.bold)),
    );
  }
}
