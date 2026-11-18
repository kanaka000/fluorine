import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../brand.dart';
import '../services/startup.dart';

/// 起動時のスプラッシュ画面（2026-11-16 追加）
/// アイコン・アプリ名・バージョン・プログレスバーを出す。
/// 背景はアイコンの背景と同じ色にして、OSが出す起動画面からつながって見えるようにする（色とアイコンは lib/brand.dart）
class SplashScreen extends StatelessWidget {
  const SplashScreen({super.key});

  // 色とアイコンは lib/brand.dart（自分用と公開版で違う。2026-11-18）
  static const background = Brand.splashBackground;
  static const accent = Brand.splashAccent;

  /// アイコン画像の大きさ。OSの起動画面（Android 12以降）のアイコンとほぼ同じ大きさになる
  static const _iconSize = 220.0;

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: Brand.splashStatusBar, // 上の時計などの文字の色
      child: Scaffold(
        backgroundColor: background,
        body: LayoutBuilder(
          builder: (context, c) => Stack(
            children: [
              // アイコンは画面のちょうど真ん中（OSの起動画面と同じ位置）
              Center(
                child: Image.asset(
                  Brand.splashIcon,
                  width: _iconSize,
                  height: _iconSize,
                  cacheWidth: 660,
                ),
              ),
              // その下にアプリ名・バージョン・プログレスバー
              Positioned(
                left: 0,
                right: 0,
                top: c.maxHeight / 2 + _iconSize / 2 - 8,
                child: Column(
                  children: [
                    const Text(
                      'Fluorine',
                      style: TextStyle(
                        color: Brand.splashText,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 1.2,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      appVersion.isEmpty ? '' : 'バージョン $appVersion',
                      style: const TextStyle(color: Brand.splashSubText, fontSize: 13),
                    ),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: 160,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: const LinearProgressIndicator(
                          minHeight: 4,
                          color: accent,
                          backgroundColor: Brand.splashTrack,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
