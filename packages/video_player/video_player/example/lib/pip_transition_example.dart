// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:video_player/src/pip_aware_controller.dart';

/// PiP動画遷移の使用例（dlab_flutter用）
/// 
/// このサンプルは、RemoteCommandCenterからの「次の動画」イベントを
/// 受信した際に、PiPモードを維持したまま動画を切り替える方法を示します。
class PipTransitionExample extends StatefulWidget {
  const PipTransitionExample({super.key});

  @override
  State<PipTransitionExample> createState() => _PipTransitionExampleState();
}

class _PipTransitionExampleState extends State<PipTransitionExample> {
  VideoPlayerController? _controller;
  final List<String> _videoUrls = [
    'https://example.com/video1.mp4',
    'https://example.com/video2.mp4',
    'https://example.com/video3.mp4',
  ];
  int _currentVideoIndex = 0;

  @override
  void initState() {
    super.initState();
    _initializeVideo();
    _setupRemoteCommandListener();
  }

  /// 初回の動画初期化
  Future<void> _initializeVideo() async {
    _controller = VideoPlayerController.network(
      _videoUrls[_currentVideoIndex],
      videoPlayerOptions: const VideoPlayerOptions(
        allowBackgroundPlayback: true,
      ),
    );
    await _controller!.initialize();
    setState(() {});
  }

  /// RemoteCommandCenterからのイベントリスナー設定
  void _setupRemoteCommandListener() {
    // VideoPlayerControllerのイベントストリームを監視
    _controller?.addListener(() {
      if (_controller!.value.eventChannel != null) {
        // nextTrackRequestedイベントを監視
        _controller!.value.eventChannel!.receiveBroadcastStream().listen((event) {
          if (event is Map && event['event'] == 'nextTrackRequested') {
            debugPrint('⏭️ Next track requested from RemoteCommandCenter');
            _handleNextTrack();
          } else if (event is Map && event['event'] == 'previousTrackRequested') {
            debugPrint('⏮️ Previous track requested from RemoteCommandCenter');
            _handlePreviousTrack();
          }
        });
      }
    });
  }

  /// 次の動画への遷移（PiP対応）
  Future<void> _handleNextTrack() async {
    _currentVideoIndex = (_currentVideoIndex + 1) % _videoUrls.length;
    await _transitionToPipVideo(_videoUrls[_currentVideoIndex]);
  }

  /// 前の動画への遷移（PiP対応）
  Future<void> _handlePreviousTrack() async {
    _currentVideoIndex = (_currentVideoIndex - 1 + _videoUrls.length) % _videoUrls.length;
    await _transitionToPipVideo(_videoUrls[_currentVideoIndex]);
  }

  /// PiPモードを維持したまま動画を切り替え
  /// これがバックグラウンドでも動作する重要なメソッド
  Future<void> _transitionToPipVideo(String videoUrl) async {
    debugPrint('🔄 Transitioning to new video in PiP mode: $videoUrl');
    
    // 古いコントローラーのリスナーを削除
    _controller?.removeListener(() {});
    
    try {
      // PiP対応のコントローラーを作成
      // このメソッドはバックグラウンドでも動作し、
      // ネイティブ側で既存のPiPプレイヤーを再利用する
      final newController = await PipAwareVideoPlayerController.createForPipTransition(
        dataSource: videoUrl,
        httpHeaders: {
          // 必要に応じてHTTPヘッダーを追加
          'User-Agent': 'dlab_flutter/1.0',
        },
        videoPlayerOptions: const VideoPlayerOptions(
          allowBackgroundPlayback: true,
        ),
      );

      // UIを更新（アプリがフォアグラウンドの場合のみ実行される）
      if (mounted) {
        setState(() {
          _controller = newController;
        });
      } else {
        // バックグラウンドの場合でも、コントローラーを更新
        _controller = newController;
      }

      // RemoteCommandCenterのリスナーを再設定
      _setupRemoteCommandListener();

      debugPrint('✅ PiP transition completed successfully');
    } catch (e) {
      debugPrint('❌ PiP transition failed: $e');
      // エラーが発生しても、PiP画面では新しい動画が表示されている可能性がある
    }
  }

  /// 通常の動画切り替え（PiPなし）
  Future<void> _switchVideoNormally(String videoUrl) async {
    final oldController = _controller;
    
    final newController = await PipAwareVideoPlayerController.createNormal(
      dataSource: videoUrl,
    );

    if (mounted) {
      setState(() {
        _controller = newController;
      });
    }

    await oldController?.dispose();
    await newController.play();
  }

  @override
  void dispose() {
    _controller?.dispose();
    PipAwareVideoPlayerController.cleanupPipMode();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_controller == null || !_controller!.value.isInitialized) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('PiP Transition Example'),
      ),
      body: Column(
        children: [
          AspectRatio(
            aspectRatio: _controller!.value.aspectRatio,
            child: VideoPlayer(_controller!),
          ),
          VideoProgressIndicator(_controller!, allowScrubbing: true),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(Icons.skip_previous),
                onPressed: _handlePreviousTrack,
              ),
              IconButton(
                icon: Icon(
                  _controller!.value.isPlaying ? Icons.pause : Icons.play_arrow,
                ),
                onPressed: () {
                  setState(() {
                    _controller!.value.isPlaying
                        ? _controller!.pause()
                        : _controller!.play();
                  });
                },
              ),
              IconButton(
                icon: const Icon(Icons.skip_next),
                onPressed: _handleNextTrack,
              ),
              IconButton(
                icon: const Icon(Icons.picture_in_picture),
                onPressed: () async {
                  await _controller!.setPictureInPictureEnabled(true);
                },
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.all(16.0),
            child: Text(
              'PiPモードで再生中に、コントロールセンターの「次のトラック」ボタンを押すと、\n'
              'PiPを維持したまま次の動画に切り替わります。',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}