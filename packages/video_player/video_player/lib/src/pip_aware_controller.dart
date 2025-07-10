// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

/// PiP対応のVideoPlayerController拡張クラス
/// dlab_flutter専用のカスタマイズ
/// 
/// このクラスは、PiPモード中の動画切り替えを適切に処理するための
/// 特別な実装を提供します。バックグラウンドでFlutterコードを実行し、
/// ネイティブ側の既存PiPプレイヤーを再利用します。
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
    // 既存のPiPコントローラーを破棄
    if (_currentPipController != null) {
      // disposeは呼ばない - ネイティブ側でプレイヤーを再利用するため
      _currentPipController!.removeListener(() {});
    }

    // 新しいコントローラーを作成
    final controller = PipAwareVideoPlayerController.network(
      dataSource,
      httpHeaders: httpHeaders,
      videoPlayerOptions: videoPlayerOptions ?? VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );

    // 現在のPiPコントローラーとして保存
    _currentPipController = controller;

    try {
      // 初期化を実行
      // ネイティブ側（FVPVideoPlayerPlugin.m:213-238）で
      // 自動的に既存のPiPプレイヤーを検出し再利用する
      await controller.initialize();
      
      // PiPモード中は自動的に再生を開始
      // （ネイティブ側でコンテンツ置き換え後に再生されるが、念のため）
      await controller.play();
      
      debugPrint('📺 PiP transition completed successfully');
    } catch (e) {
      debugPrint('⚠️ PiP transition error: $e');
      
      // エラーが発生しても、ネイティブ側でコンテンツ置き換えは
      // 成功している可能性があるため、再生を試みる
      try {
        await controller.play();
      } catch (_) {
        // 再生エラーは無視
      }
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