import 'package:flutter/services.dart';

/// アプリの見た目のうち、起動画面の色とアイコン
class Brand {
  /// 起動画面に出すアイコン
  static const splashIcon = 'assets/icon/fluorine_icon.png';

  /// 起動画面の背景（アイコンの背景と同じクリーム色。android の ic_launcher_background と同じ色）
  static const splashBackground = Color(0xFFFCF7EF);

  /// プログレスバーの色（アイコンの青）
  static const splashAccent = Color(0xFF2673C6);

  /// アプリ名の文字の色
  static const splashText = Color(0xFF2B2B2B);

  /// バージョンの文字の色
  static const splashSubText = Color(0x992B2B2B);

  /// プログレスバーの下地の色
  static const splashTrack = Color(0x1F2B2B2B);

  /// 上の時計などの文字の色（明るい背景なので黒い文字）
  static const splashStatusBar = SystemUiOverlayStyle.dark;
}
