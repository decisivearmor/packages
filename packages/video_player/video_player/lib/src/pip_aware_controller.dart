// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// PiP対応のVideoPlayerController拡張クラス
/// 
/// このクラスは、PiPモード中の動画切り替えを適切に処理するための
/// 特別な実装を提供します。バックグラウンドでFlutterコードを実行し、
/// ネイティブ側の既存PiPプレイヤーを再利用します。
// PiPは無効化されたため、このクラスは通常のVideoPlayerControllerの薄いラッパーとして残す
class PipAwareVideoPlayerController extends VideoPlayerController {
  static VideoPlayerController? _currentPipController;
  
  PipAwareVideoPlayerController.network(
    String dataSource, {
    Map<String, String>? httpHeaders,
    VideoPlayerOptions? videoPlayerOptions,
  }) : super.network(
          dataSource,
          httpHeaders: httpHeaders ?? const <String, String>{},
          videoPlayerOptions: videoPlayerOptions ?? VideoPlayerOptions(
            allowBackgroundPlayback: true, // バックグラウンド再生を有効化
          ),
        );

  /// PiPモード中の動画切り替え専用メソッド
  /// バックグラウンドでも動作可能
  static Future<VideoPlayerController> createForPipTransition({
    required String dataSource,
    Map<String, String>? httpHeaders,
    VideoPlayerOptions? videoPlayerOptions,
  }) async {
    // PiP移行は無効化。通常のコントローラを返す
    _currentPipController = null;

    // 新しいコントローラーを作成
    final controller = VideoPlayerController.network(
      dataSource,
      httpHeaders: httpHeaders ?? const <String, String>{},
      videoPlayerOptions: videoPlayerOptions ?? VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );

    // 現在のPiPコントローラーとして保存
    _currentPipController = controller;

    try {
      await controller.initialize();
      debugPrint('⛔ PiP transition is disabled; initialized normal controller');
    } catch (e) {
      debugPrint('⚠️ PiP transition error: $e');
      
      // no-op
    }

    return controller;
  }

  /// 通常の動画切り替え（PiPなし）
  static Future<VideoPlayerController> createNormal({
    required String dataSource,
    Map<String, String>? httpHeaders,
    VideoPlayerOptions? videoPlayerOptions,
  }) async {
    final controller = VideoPlayerController.network(
      dataSource,
      httpHeaders: httpHeaders ?? const <String, String>{},
      videoPlayerOptions: videoPlayerOptions,
    );
    
    await controller.initialize();
    return controller;
  }

  /// 現在PiPモードで再生中のコントローラーを取得
  static VideoPlayerController? get currentPipController => _currentPipController;

  /// PiPモードのクリーンアップ
  static void cleanupPipMode() {
    if (_currentPipController != null) {
      _currentPipController!.dispose();
      _currentPipController = null;
    }
  }
}