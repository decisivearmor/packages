// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer_Internal.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer_Test.h"

#import <GLKit/GLKit.h>
#import <AVKit/AVKit.h>
#import <MediaPlayer/MediaPlayer.h>

#import "./include/video_player_avfoundation/AVAssetTrackUtils.h"

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *presentationSizeContext = &presentationSizeContext;
static void *durationContext = &durationContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

@interface FVPVideoPlayer () <AVAssetResourceLoaderDelegate>
@end

@implementation FVPVideoPlayer {
  BOOL _isInPictureInPicture;
  BOOL _isRemoteCommandCenterConfigured;
  BOOL _userExplicitlyPaused;  // ユーザーが明示的に停止したかどうか
  BOOL _backgroundTransitionExecuted; // バックグラウンド移行処理が実行済みかどうか
  BOOL _deviceIsLocked; // デバイスがロックされているかどうか
  BOOL _pausedFromPiP; // PiPコントロールから一時停止されたかどうか
  NSTimer *_playbackMonitoringTimer; // 再生監視タイマー
  NSTimer *_bufferMonitoringTimer; // バッファ監視タイマー
  NSTimer *_backgroundTaskRefreshTimer; // バックグラウンドタスクリフレッシュタイマー
}

@synthesize isInPictureInPicture = _isInPictureInPicture;
@synthesize isLiveStream = _isLiveStream;

- (instancetype)init {
  self = [super init];
  if (self) {
#if TARGET_OS_IOS
    _backgroundTask = UIBackgroundTaskInvalid;
#endif
    _isRemoteCommandCenterConfigured = NO;
    _userExplicitlyPaused = NO;
    _isLiveStream = NO;
    _backgroundTransitionExecuted = NO;
    _deviceIsLocked = ![UIApplication sharedApplication].protectedDataAvailable;
    _pausedFromPiP = NO;
    _playbackMonitoringTimer = nil;
    _bufferMonitoringTimer = nil;
    _backgroundTaskRefreshTimer = nil;
    NSLog(@"🚀 ========================================");
    NSLog(@"🚀 [VideoPlayer] INITIALIZATION COMPLETED");
    NSLog(@"🚀 Build Version: TIMER-MEMORY-FIX (Latest)");
    NSLog(@"🚀 Features: Auto-PiP, HLS Headers, User Pause Respect, Device Lock Detection, Timer Cleanup");
    NSLog(@"🚀 ========================================");
  }
  return self;
}
- (instancetype)initWithAsset:(NSString *)asset
                    avFactory:(id<FVPAVFactory>)avFactory
                 viewProvider:(NSObject<FVPViewProvider> *)viewProvider {
  return [self initWithURL:[NSURL fileURLWithPath:[FVPVideoPlayer absolutePathForAssetName:asset]]
               httpHeaders:@{}
                 avFactory:avFactory
              viewProvider:viewProvider];
}

- (instancetype)initWithURL:(NSURL *)url
                httpHeaders:(nonnull NSDictionary<NSString *, NSString *> *)headers
                  avFactory:(id<FVPAVFactory>)avFactory
               viewProvider:(NSObject<FVPViewProvider> *)viewProvider {
  NSDictionary<NSString *, id> *options = nil;
  if ([headers count] != 0) {
    options = @{@"AVURLAssetHTTPHeaderFieldsKey" : headers};
  }
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  
  // Store headers for potential reuse
  _httpHeaders = [headers copy];
  
  // Set up resource loader delegate for HLS segment requests only if we have custom headers
  // and the URL suggests it's an HLS stream
  if ([headers count] > 0 && ([url.pathExtension isEqualToString:@"m3u8"] || [url.absoluteString containsString:@"m3u8"])) {
    [urlAsset.resourceLoader setDelegate:self queue:dispatch_get_main_queue()];
    NSLog(@"🔗 [VideoPlayer] Resource loader delegate set for HLS header injection");
  }
  
  // Log URL and headers for debugging
  NSLog(@"🔄 [HLS-HEADER-INJECTION] HLSヘッダー注入機能付きVideoPlayer初期化");
  NSLog(@"📡 [VideoPlayer] Creating AVURLAsset at %@", [NSDate date]);
  NSLog(@"  URL: %@", url);
  NSLog(@"  HTTP Headers: %@", headers);
  NSLog(@"  Headers count: %lu", (unsigned long)[headers count]);
  NSLog(@"  URL contains m3u8: %@", [url.absoluteString containsString:@"m3u8"] ? @"YES" : @"NO");
  
  if ([headers count] > 0) {
    NSLog(@"✅ [HLS-HEADER-INJECTION] カスタムヘッダーがすべてのHLSリクエスト（TSセグメント含む）に適用されます");
  } else {
    NSLog(@"⚠️ [HLS-HEADER-INJECTION] HTTPヘッダーが設定されていません - HLSセグメント注入は無効");
  }
  
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  return [self initWithPlayerItem:item avFactory:avFactory viewProvider:viewProvider];
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                         avFactory:(id<FVPAVFactory>)avFactory
                      viewProvider:(NSObject<FVPViewProvider> *)viewProvider {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");
  
  NSLog(@"🎬 [VideoPlayer] Initializing player at %@", [NSDate date]);

  _viewProvider = viewProvider;

  AVAsset *asset = [item asset];
  void (^assetCompletionHandler)(void) = ^{
    if ([asset statusOfValueForKey:@"tracks" error:nil] == AVKeyValueStatusLoaded) {
      NSArray *tracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if ([tracks count] > 0) {
        AVAssetTrack *videoTrack = tracks[0];
        void (^trackCompletionHandler)(void) = ^{
          if (self->_disposed) return;
          if ([videoTrack statusOfValueForKey:@"preferredTransform"
                                        error:nil] == AVKeyValueStatusLoaded) {
            // Rotate the video by using a videoComposition and the preferredTransform
            self->_preferredTransform = FVPGetStandardizedTransformForTrack(videoTrack);
            // Do not use video composition when it is not needed.
            if (CGAffineTransformIsIdentity(self->_preferredTransform)) {
              return;
            }
            // Note:
            // https://developer.apple.com/documentation/avfoundation/avplayeritem/1388818-videocomposition
            // Video composition can only be used with file-based media and is not supported for
            // use with media served using HTTP Live Streaming.
            AVMutableVideoComposition *videoComposition =
                [self getVideoCompositionWithTransform:self->_preferredTransform
                                             withAsset:asset
                                        withVideoTrack:videoTrack];
            item.videoComposition = videoComposition;
          }
        };
        [videoTrack loadValuesAsynchronouslyForKeys:@[ @"preferredTransform" ]
                                  completionHandler:trackCompletionHandler];
      }
    }
  };

  _player = [avFactory playerWithPlayerItem:item];
  _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
  
  // Configure for aggressive HLS background playback
  if (@available(iOS 10.0, *)) {
    // HLS背景再生のための強化設定
    item.preferredForwardBufferDuration = 15.0; // より長いバッファで安定性確保
    item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    
    // プレイヤーの自動待機を無効化（背景再生で重要）
    // 注記：automaticallyWaitsToMinimizeStalling プロパティは一部のiOSバージョンで利用できないため削除
    // 代わりにバッファ時間の調整で連続再生を実現
    NSLog(@"🚀 [VideoPlayer] Enhanced buffering configured for continuous background playback");
    
    // 音声専用ファイルの場合はさらに最適化
    AVAsset *asset = item.asset;
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    if (videoTracks.count == 0) {
      // 音声のみの場合はより長いバッファで安定性を向上
      item.preferredForwardBufferDuration = 20.0;
      NSLog(@"🎵 [VideoPlayer] Audio-only file detected - extended buffering configured");
    } else {
      NSLog(@"🎬 [VideoPlayer] Video file detected - standard enhanced buffering configured");
    }
    
    NSLog(@"📡 [VideoPlayer] HLS background playback optimization completed - Buffer: %.1fs", item.preferredForwardBufferDuration);
  }

  // Configure output.
  NSDictionary *pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [avFactory videoOutputWithPixelBufferAttributes:pixBuffAttributes];

  [self addObserversForItem:item player:_player];
  
  // Setup Audio Session for background playback
  [self setupAudioSessionForBackgroundPlayback];
  
  // Defer Remote Command Center setup to avoid blocking initialization
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"🎮 [VideoPlayer] Setting up Remote Command Center (deferred) at %@", [NSDate date]);
    [self setupRemoteCommandCenterIfNeeded];
  });
  
#if TARGET_OS_IOS
  // Defer background task to avoid blocking initialization
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"🔄 [VideoPlayer] Starting persistent background task (deferred) at %@", [NSDate date]);
    [self startPersistentBackgroundTask];
  });
  
  // Register for app lifecycle notifications with detailed logging
  NSLog(@"🔔 [VideoPlayer] REGISTERING APPLICATION LIFECYCLE NOTIFICATIONS");
  NSLog(@"  PlayerInstance: %p", self);
  NSLog(@"  TARGET_OS_IOS: %d", TARGET_OS_IOS);
  NSLog(@"  Registration timestamp: %@", [NSDate date]);
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillResignActive:)
                                              name:UIApplicationWillResignActiveNotification
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered applicationWillResignActive");
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationDidBecomeActive:)
                                              name:UIApplicationDidBecomeActiveNotification
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered applicationDidBecomeActive");
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationDidEnterBackground:)
                                              name:UIApplicationDidEnterBackgroundNotification
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered applicationDidEnterBackground");
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillEnterForeground:)
                                              name:UIApplicationWillEnterForegroundNotification
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered applicationWillEnterForeground");
  
  // デバイスロック/アンロック通知を登録
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(protectedDataWillBecomeUnavailable:)
                                              name:UIApplicationProtectedDataWillBecomeUnavailable
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered protectedDataWillBecomeUnavailable");
  
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(protectedDataDidBecomeAvailable:)
                                              name:UIApplicationProtectedDataDidBecomeAvailable
                                            object:nil];
  NSLog(@"✅ [VideoPlayer] Registered protectedDataDidBecomeAvailable");
  
  NSLog(@"🔔 [VideoPlayer] ALL LIFECYCLE NOTIFICATIONS REGISTERED SUCCESSFULLY");
#endif

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)dealloc {
  if (!_disposed) {
    [self removeKeyValueObservers];
  }
}

+ (NSString *)absolutePathForAssetName:(NSString *)assetName {
  NSString *path = [[NSBundle mainBundle] pathForResource:assetName ofType:nil];
#if TARGET_OS_OSX
  // See https://github.com/flutter/flutter/issues/135302
  // TODO(stuartmorgan): Remove this if the asset APIs are adjusted to work better for macOS.
  if (!path) {
    path = [NSURL URLWithString:assetName relativeToURL:NSBundle.mainBundle.bundleURL].path;
  }
#endif

  return path;
}

- (void)addObserversForItem:(AVPlayerItem *)item player:(AVPlayer *)player {
  [item addObserver:self
         forKeyPath:@"loadedTimeRanges"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:timeRangeContext];
  [item addObserver:self
         forKeyPath:@"status"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:statusContext];
  [item addObserver:self
         forKeyPath:@"presentationSize"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:presentationSizeContext];
  [item addObserver:self
         forKeyPath:@"duration"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:durationContext];
  [item addObserver:self
         forKeyPath:@"playbackLikelyToKeepUp"
            options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
            context:playbackLikelyToKeepUpContext];

  // Add observer to AVPlayer instead of AVPlayerItem since the AVPlayerItem does not have a "rate"
  // property
  [player addObserver:self
           forKeyPath:@"rate"
              options:NSKeyValueObservingOptionInitial | NSKeyValueObservingOptionNew
              context:rateContext];

  // Add an observer that will respond to itemDidPlayToEndTime
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(itemDidPlayToEndTime:)
                                               name:AVPlayerItemDidPlayToEndTimeNotification
                                             object:item];
  
  // Add observers for error tracking
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemFailedToPlay:)
                                               name:AVPlayerItemFailedToPlayToEndTimeNotification
                                             object:item];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(playerItemNewErrorLogEntry:)
                                               name:AVPlayerItemNewErrorLogEntryNotification
                                             object:item];
}

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
  if (_isLooping) {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    if (_eventSink) {
      _eventSink(@{@"event" : @"completed"});
    }
  }
}

- (void)playerItemFailedToPlay:(NSNotification *)notification {
  NSError *error = notification.userInfo[AVPlayerItemFailedToPlayToEndTimeErrorKey];
  NSLog(@"Player item failed to play to end time: %@", error);
  NSLog(@"Error domain: %@, code: %ld", error.domain, (long)error.code);
  NSLog(@"Error description: %@", error.localizedDescription);
}

- (void)playerItemNewErrorLogEntry:(NSNotification *)notification {
  AVPlayerItem *playerItem = notification.object;
  AVPlayerItemErrorLog *errorLog = [playerItem errorLog];
  AVPlayerItemErrorLogEvent *lastEvent = errorLog.events.lastObject;
  
  if (lastEvent) {
    NSLog(@"HLS Error Log Entry:");
    NSLog(@"  Error Domain: %@", lastEvent.errorDomain);
    NSLog(@"  Error Code: %ld", (long)lastEvent.errorStatusCode);
    NSLog(@"  Error Comment: %@", lastEvent.errorComment);
    NSLog(@"  URI: %@", lastEvent.URI);
    NSLog(@"  Server Address: %@", lastEvent.serverAddress);
  }
}

const int64_t TIME_UNSET = -9223372036854775807;

NS_INLINE int64_t FVPCMTimeToMillis(CMTime time) {
  // When CMTIME_IS_INDEFINITE return a value that matches TIME_UNSET from ExoPlayer2 on Android.
  // Fixes https://github.com/flutter/flutter/issues/48670
  if (CMTIME_IS_INDEFINITE(time)) return TIME_UNSET;
  if (time.timescale == 0) return 0;
  return time.value * 1000 / time.timescale;
}

NS_INLINE CGFloat radiansToDegrees(CGFloat radians) {
  // Input range [-pi, pi] or [-180, 180]
  CGFloat degrees = GLKMathRadiansToDegrees((float)radians);
  if (degrees < 0) {
    // Convert -90 to 270 and -180 to 180
    return degrees + 360;
  }
  // Output degrees in between [0, 360]
  return degrees;
};

- (AVMutableVideoComposition *)getVideoCompositionWithTransform:(CGAffineTransform)transform
                                                      withAsset:(AVAsset *)asset
                                                 withVideoTrack:(AVAssetTrack *)videoTrack {
  AVMutableVideoCompositionInstruction *instruction =
      [AVMutableVideoCompositionInstruction videoCompositionInstruction];
  instruction.timeRange = CMTimeRangeMake(kCMTimeZero, [asset duration]);
  AVMutableVideoCompositionLayerInstruction *layerInstruction =
      [AVMutableVideoCompositionLayerInstruction
          videoCompositionLayerInstructionWithAssetTrack:videoTrack];
  [layerInstruction setTransform:_preferredTransform atTime:kCMTimeZero];

  AVMutableVideoComposition *videoComposition = [AVMutableVideoComposition videoComposition];
  instruction.layerInstructions = @[ layerInstruction ];
  videoComposition.instructions = @[ instruction ];

  // If in portrait mode, switch the width and height of the video
  CGFloat width = videoTrack.naturalSize.width;
  CGFloat height = videoTrack.naturalSize.height;
  NSInteger rotationDegrees =
      (NSInteger)round(radiansToDegrees(atan2(_preferredTransform.b, _preferredTransform.a)));
  if (rotationDegrees == 90 || rotationDegrees == 270) {
    width = videoTrack.naturalSize.height;
    height = videoTrack.naturalSize.width;
  }
  videoComposition.renderSize = CGSizeMake(width, height);

  videoComposition.sourceTrackIDForFrameTiming = videoTrack.trackID;
  if (CMTIME_IS_VALID(videoTrack.minFrameDuration)) {
    videoComposition.frameDuration = videoTrack.minFrameDuration;
  } else {
    NSLog(@"Warning: videoTrack.minFrameDuration for input video is invalid, please report this to "
          @"https://github.com/flutter/flutter/issues with input video attached.");
    videoComposition.frameDuration = CMTimeMake(1, 30);
  }

  return videoComposition;
}

- (void)observeValueForKeyPath:(NSString *)path
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context {
  if (context == timeRangeContext) {
    if (_eventSink != nil) {
      NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
      for (NSValue *rangeValue in [object loadedTimeRanges]) {
        CMTimeRange range = [rangeValue CMTimeRangeValue];
        int64_t start = FVPCMTimeToMillis(range.start);
        [values addObject:@[ @(start), @(start + FVPCMTimeToMillis(range.duration)) ]];
      }
      _eventSink(@{@"event" : @"bufferingUpdate", @"values" : values});
    }
  } else if (context == statusContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    switch (item.status) {
      case AVPlayerItemStatusFailed:
        [self sendFailedToLoadVideoEvent];
        break;
      case AVPlayerItemStatusUnknown:
        break;
      case AVPlayerItemStatusReadyToPlay:
        [item addOutput:_videoOutput];
        [self setupEventSinkIfReadyToPlay];
        break;
    }
  } else if (context == presentationSizeContext || context == durationContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    if (item.status == AVPlayerItemStatusReadyToPlay) {
      // Due to an apparent bug, when the player item is ready, it still may not have determined
      // its presentation size or duration. When these properties are finally set, re-check if
      // all required properties and instantiate the event sink if it is not already set up.
      [self setupEventSinkIfReadyToPlay];
    }
  } else if (context == playbackLikelyToKeepUpContext) {
    [self updatePlayingState];
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingEnd"});
      }
    } else {
      if (_eventSink != nil) {
        _eventSink(@{@"event" : @"bufferingStart"});
      }
    }
  } else if (context == rateContext) {
    // Important: Make sure to cast the object to AVPlayer when observing the rate property,
    // as it is not available in AVPlayerItem.
    AVPlayer *player = (AVPlayer *)object;
    
    // PiPモード中のrate変更はユーザーの明示的な操作として扱う
    if (_isInPictureInPicture) {
      if (player.rate == 0) {
        // PiPコントロールから一時停止された
        NSLog(@"⏸️ [VideoPlayer] User paused from PiP controls");
        // _isPlayingフラグを直接更新（pauseメソッドを呼ばない）
        _isPlaying = NO;
        _userExplicitlyPaused = YES;
        _pausedFromPiP = YES;
      } else {
        // デバイスロック時は自動再生によるフラグリセットを防ぐ
        if (!_deviceIsLocked) {
          // PiPコントロールから再生された（デバイスロック時以外）
          // ただし、_pausedFromPiPがセットされている場合のみユーザー操作として扱う
          if (_pausedFromPiP) {
            // PiPで一時停止後の再生なので、ユーザーが明示的に再生したと判断
            NSLog(@"▶️ [VideoPlayer] User resumed from PiP controls");
            // _isPlayingフラグを直接更新（playメソッドを呼ばない）
            _isPlaying = YES;
            _userExplicitlyPaused = NO;
            _pausedFromPiP = NO;
          } else {
            // PiPモード中だが、一度も一時停止されていない場合
            // これはシステムによる自動的なrate変化の可能性が高い
            NSLog(@"⚠️ [VideoPlayer] Rate changed in PiP mode but not after pause - likely system-initiated");
          }
        } else {
          NSLog(@"🔒 [VideoPlayer] Rate changed while device locked - NOT resetting user pause flag");
        }
      }
    }
    
    if (_eventSink != nil) {
      _eventSink(
          @{@"event" : @"isPlayingStateUpdate", @"isPlaying" : player.rate > 0 ? @YES : @NO});
    }
  } else {
#if TARGET_OS_IOS
    // Check if this is the PiP controller's isPictureInPicturePossible property
    if (@available(iOS 9.0, *)) {
      if (object == _pipController && [path isEqualToString:@"isPictureInPicturePossible"]) {
        if (_pipController.isPictureInPicturePossible) {
          NSLog(@"🎯 [VideoPlayer] PiP observer triggered - now possible, starting PiP");
          [_pipController removeObserver:self forKeyPath:@"isPictureInPicturePossible"];
          [_pipController startPictureInPicture];
        } else {
          NSLog(@"⏳ [VideoPlayer] PiP observer triggered but still not possible");
        }
      }
    }
#endif
  }
}

- (void)updatePlayingState {
  if (!_isInitialized) {
    return;
  }
  if (_isPlaying) {
    // デバイスロック状態を確認
    if (_deviceIsLocked) {
      NSLog(@"🔒 [VideoPlayer] updatePlayingState: Device is locked - skipping play");
      return;
    }
    
    // PiPから一時停止された状態を確認
    if (_pausedFromPiP) {
      NSLog(@"⏸️ [VideoPlayer] updatePlayingState: Paused from PiP - skipping play");
      return;
    }
    
    // ユーザーが明示的に一時停止した場合もスキップ
    if (_userExplicitlyPaused) {
      NSLog(@"⚠️ [VideoPlayer] updatePlayingState: User explicitly paused - skipping play");
      return;
    }
    
    // デバイスロック状態をリアルタイムで再確認
    if (![UIApplication sharedApplication].protectedDataAvailable) {
      _deviceIsLocked = YES;
      NSLog(@"⚠️ [VideoPlayer] updatePlayingState: Device lock detected via protectedData - aborting play");
      return;
    }
    
    NSLog(@"🎬 [VideoPlayer] updatePlayingState: Calling play (from: %@)", [NSThread callStackSymbols][3]);
    
    // Calling play is the same as setting the rate to 1.0 (or to defaultRate depending on iOS
    // version) so last set playback speed must be set here if any instead.
    // https://github.com/flutter/flutter/issues/71264
    // https://github.com/flutter/flutter/issues/73643
    if (_targetPlaybackSpeed) {
      [self updateRate];
    } else {
      [_player play];
    }
  } else {
    [_player pause];
  }
}

/// Synchronizes the player's playback rate with targetPlaybackSpeed, constrained by the playback
/// rate capabilities of the player's current item.
- (void)updateRate {
  // See https://developer.apple.com/library/archive/qa/qa1772/_index.html for an explanation of
  // these checks.
  // If status is not AVPlayerItemStatusReadyToPlay then both canPlayFastForward
  // and canPlaySlowForward are always false and it is unknown whether video can
  // be played at these speeds, updatePlayingState will be called again when
  // status changes to AVPlayerItemStatusReadyToPlay.
  float speed = _targetPlaybackSpeed.floatValue;
  BOOL readyToPlay = _player.currentItem.status == AVPlayerItemStatusReadyToPlay;
  if (speed > 2.0 && !_player.currentItem.canPlayFastForward) {
    if (!readyToPlay) {
      return;
    }
    speed = 2.0;
  }
  if (speed < 1.0 && !_player.currentItem.canPlaySlowForward) {
    if (!readyToPlay) {
      return;
    }
    speed = 1.0;
  }
  _player.rate = speed;
}

- (void)sendFailedToLoadVideoEvent {
  if (_eventSink == nil) {
    return;
  }
  // Prefer more detailed error information from tracks loading.
  NSError *error;
  if ([self.player.currentItem.asset statusOfValueForKey:@"tracks"
                                                   error:&error] != AVKeyValueStatusFailed) {
    error = self.player.currentItem.error;
  }
  __block NSMutableOrderedSet<NSString *> *details =
      [NSMutableOrderedSet orderedSetWithObject:@"Failed to load video"];
  void (^add)(NSString *) = ^(NSString *detail) {
    if (detail != nil) {
      [details addObject:detail];
    }
  };
  NSError *underlyingError = error.userInfo[NSUnderlyingErrorKey];
  add(error.localizedDescription);
  add(error.localizedFailureReason);
  add(underlyingError.localizedDescription);
  add(underlyingError.localizedFailureReason);
  NSString *message = [details.array componentsJoinedByString:@": "];
  _eventSink([FlutterError errorWithCode:@"VideoError" message:message details:nil]);
}

- (void)setupEventSinkIfReadyToPlay {
  if (_eventSink && !_isInitialized) {
    AVPlayerItem *currentItem = self.player.currentItem;
    CGSize size = currentItem.presentationSize;
    CGFloat width = size.width;
    CGFloat height = size.height;

    // Wait until tracks are loaded to check duration or if there are any videos.
    AVAsset *asset = currentItem.asset;
    if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
      void (^trackCompletionHandler)(void) = ^{
        if ([asset statusOfValueForKey:@"tracks" error:nil] != AVKeyValueStatusLoaded) {
          // Cancelled, or something failed.
          return;
        }
        // This completion block will run on an AVFoundation background queue.
        // Hop back to the main thread to set up event sink.
        [self performSelector:_cmd onThread:NSThread.mainThread withObject:self waitUntilDone:NO];
      };
      [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ]
                           completionHandler:trackCompletionHandler];
      return;
    }

    // HLS判定
    BOOL isHLS = NO;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)asset;
      NSURL *url = urlAsset.URL;
      isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
             [url.absoluteString.lowercaseString containsString:@"m3u8"];
    }
    
    BOOL hasVideoTracks = [asset tracksWithMediaType:AVMediaTypeVideo].count != 0;
    // Audio-only HLS files have no size, so `currentItem.tracks.count` must be used to check for
    // track presence, as AVAsset does not always provide track information in HLS streams.
    BOOL hasNoTracks = currentItem.tracks.count == 0 && asset.tracks.count == 0;

    // The player has not yet initialized when it has no size, unless it is an audio-only track.
    // HLS m3u8 video files never load any tracks, and are also not yet initialized until they have
    // a size.
    if ((hasVideoTracks || hasNoTracks) && height == CGSizeZero.height &&
        width == CGSizeZero.width) {
      return;
    }
    // The player may be initialized but still needs to determine the duration.
    int64_t duration = [self duration];
    if (duration == 0) {
      return;
    }

    _isInitialized = YES;
    [self updatePlayingState];

    _eventSink(@{
      @"event" : @"initialized",
      @"duration" : @(duration),
      @"width" : @(width),
      @"height" : @(height)
    });
    
#if TARGET_OS_IOS
    // Mark that video supports PiP but don't create controller yet
    if (@available(iOS 9.0, *)) {
      if (!_pipController && (hasVideoTracks || isHLS)) {
        NSLog(@"📌 [VideoPlayer] Video supports PiP - will create controller when needed");
        _isPiPPrepared = NO; // Don't mark as prepared until controller is created
      }
    }
#endif
  }
}

- (void)play {
  // デバイスロック状態を再確認
  NSLog(@"🎬 ========================================");
  NSLog(@"🎬 [VideoPlayer] PLAY COMMAND EXECUTED");
  NSLog(@"🎬 Device Locked: %@", _deviceIsLocked ? @"YES" : @"NO");
  NSLog(@"🎬 Call Stack: %@", [NSThread callStackSymbols]);
  
  _isPlaying = YES;
  _userExplicitlyPaused = NO;  // ユーザーが再生を開始した
  
  // playメソッドが呼ばれた場合、PiP一時停止フラグもリセット
  // ただし、リモートコマンドからの再生と区別するため、コールスタックを確認
  NSArray *callStack = [NSThread callStackSymbols];
  BOOL isFromRemoteCommand = NO;
  for (NSString *symbol in callStack) {
    if ([symbol containsString:@"MPRemoteCommand"] || [symbol containsString:@"togglePlayPauseCommand"]) {
      isFromRemoteCommand = YES;
      break;
    }
  }
  
  if (!isFromRemoteCommand && _pausedFromPiP) {
    NSLog(@"🎬 Resetting PiP pause flag - play called directly (not from remote command)");
    _pausedFromPiP = NO;
  }
  
  // 分かりやすい再生開始ログ
  NSLog(@"🎬 User Explicitly Paused: NO (Reset)");
  NSLog(@"🎬 Is Playing: YES");
  NSLog(@"🎬 In PiP Mode: %@", _isInPictureInPicture ? @"YES" : @"NO");
  NSLog(@"🎬 Paused from PiP: %@", _pausedFromPiP ? @"YES" : @"NO");
  NSLog(@"🎬 Remote Command Center Configured: %@", _isRemoteCommandCenterConfigured ? @"YES" : @"NO");
  NSLog(@"🎬 ========================================");
  
#if TARGET_OS_IOS
  // 動画再生開始時にPiPを準備（まだ作成していない場合）
  if (@available(iOS 9.0, *)) {
    if (!_pipController && _isInitialized) {
      AVAsset *asset = _player.currentItem.asset;
      BOOL isHLS = NO;
      if ([asset isKindOfClass:[AVURLAsset class]]) {
        AVURLAsset *urlAsset = (AVURLAsset *)asset;
        NSURL *url = urlAsset.URL;
        isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
               [url.absoluteString.lowercaseString containsString:@"m3u8"];
      }
      
      NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if (videoTracks.count > 0 || isHLS) {
        NSLog(@"🎯 [VideoPlayer] Preparing PiP controller on play start");
        [self preparePictureInPictureController];
      }
    }
  }
#endif
  
  [self updatePlayingState];
  [self updateNowPlayingInfo];
}

- (void)pause {
  _isPlaying = NO;
  _userExplicitlyPaused = YES;  // ユーザーが明示的に停止した
  
  // PiPモード中の一時停止は特別に記録
  if (_isInPictureInPicture) {
    _pausedFromPiP = YES;
  }
  
  // 分かりやすい一時停止ログ
  NSLog(@"⏸️ ========================================");
  NSLog(@"⏸️ [VideoPlayer] PAUSE COMMAND EXECUTED");
  NSLog(@"⏸️ User Explicitly Paused: YES (User Action)");
  NSLog(@"⏸️ Is Playing: NO");
  NSLog(@"⏸️ In PiP Mode: %@", _isInPictureInPicture ? @"YES" : @"NO");
  NSLog(@"⏸️ Paused from PiP: %@", _pausedFromPiP ? @"YES" : @"NO");
  NSLog(@"⏸️ Auto-restart should be BLOCKED");
  NSLog(@"⏸️ ========================================");
  
#if TARGET_OS_IOS
  // バックグラウンド監視タイマーを停止
  if (_playbackMonitoringTimer) {
    [_playbackMonitoringTimer invalidate];
    _playbackMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Playback monitoring timer stopped on pause");
  }
  
  if (_bufferMonitoringTimer) {
    [_bufferMonitoringTimer invalidate];
    _bufferMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Buffer monitoring timer stopped on pause");
  }
#endif
  
  [self updatePlayingState];
  [self updateNowPlayingInfo];
}

- (int64_t)position {
  return FVPCMTimeToMillis([_player currentTime]);
}

- (int64_t)duration {
  // Note: https://openradar.appspot.com/radar?id=4968600712511488
  // `[AVPlayerItem duration]` can be `kCMTimeIndefinite`,
  // use `[[AVPlayerItem asset] duration]` instead.
  return FVPCMTimeToMillis([[[_player currentItem] asset] duration]);
}

- (void)seekTo:(int64_t)location completionHandler:(void (^)(BOOL))completionHandler {
  CMTime targetCMTime = CMTimeMake(location, 1000);
  CMTimeValue duration = _player.currentItem.asset.duration.value;
  // Without adding tolerance when seeking to duration,
  // seekToTime will never complete, and this call will hang.
  // see issue https://github.com/flutter/flutter/issues/124475.
  CMTime tolerance = location == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
  [_player seekToTime:targetCMTime
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:^(BOOL completed) {
        [self updateNowPlayingInfo];
        if (completionHandler) {
          completionHandler(completed);
        }
      }];
}

- (void)setIsLooping:(BOOL)isLooping {
  _isLooping = isLooping;
}

- (void)setVolume:(double)volume {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed {
  _targetPlaybackSpeed = @(speed);
  [self updatePlayingState];
}

- (void)setIsLiveStream:(BOOL)isLiveStream {
  _isLiveStream = isLiveStream;
  NSLog(@"📺 [VideoPlayer] Live stream status set to: %@", isLiveStream ? @"YES" : @"NO");
  
  // Update Remote Command Center configuration for live streams
  if (_isRemoteCommandCenterConfigured) {
    [self setupRemoteCommandCenter];
  }
  
  // Update Now Playing info to reflect live stream status
  [self updateNowPlayingInfo];
}

- (FlutterError *_Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError *_Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)events {
  _eventSink = events;
  // TODO(@recastrodiaz): remove the line below when the race condition is resolved:
  // https://github.com/flutter/flutter/issues/21483
  // This line ensures the 'initialized' event is sent when the event
  // 'AVPlayerItemStatusReadyToPlay' fires before _eventSink is set (this function
  // onListenWithArguments is called)
  // and also send error in similar case with 'AVPlayerItemStatusFailed'
  // https://github.com/flutter/flutter/issues/151475
  // https://github.com/flutter/flutter/issues/147707
  if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
    [self sendFailedToLoadVideoEvent];
    return nil;
  }
  [self setupEventSinkIfReadyToPlay];
  return nil;
}

/// This method allows you to dispose without touching the event channel. This
/// is useful for the case where the Engine is in the process of deconstruction
/// so the channel is going to die or is already dead.
- (void)disposeSansEventChannel {
  _disposed = YES;
  [self removeKeyValueObservers];

#if TARGET_OS_IOS
  // Clean up timers
  if (_playbackMonitoringTimer) {
    [_playbackMonitoringTimer invalidate];
    _playbackMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Playback monitoring timer invalidated");
  }
  
  if (_bufferMonitoringTimer) {
    [_bufferMonitoringTimer invalidate];
    _bufferMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Buffer monitoring timer invalidated");
  }
  
  if (_backgroundTaskRefreshTimer) {
    [_backgroundTaskRefreshTimer invalidate];
    _backgroundTaskRefreshTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Background task refresh timer invalidated");
  }
  
  // Remove all notification observers
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  
  if (@available(iOS 9.0, *)) {
    if (_pipController) {
      // Remove observer if it exists
      @try {
        [_pipController removeObserver:self forKeyPath:@"isPictureInPicturePossible"];
      } @catch (NSException *exception) {
        // Observer might not be registered, ignore
      }
      
      if ([_pipController isPictureInPictureActive]) {
        [_pipController stopPictureInPicture];
      }
    }
    _pipController = nil;
  }
#endif

  [self cleanupRemoteCommandCenter];
  
#if TARGET_OS_IOS
  // End background task if still running
  [self endBackgroundTask];
#endif
  
  [self.player replaceCurrentItemWithPlayerItem:nil];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)dispose {
  [self disposeSansEventChannel];
  [_eventChannel setStreamHandler:nil];
}

/// Removes all key-value observers set up for the player.
///
/// This is called from dealloc, so must not use any methods on self.
- (void)removeKeyValueObservers {
  AVPlayerItem *currentItem = _player.currentItem;
  [currentItem removeObserver:self forKeyPath:@"status"];
  [currentItem removeObserver:self forKeyPath:@"loadedTimeRanges"];
  [currentItem removeObserver:self forKeyPath:@"presentationSize"];
  [currentItem removeObserver:self forKeyPath:@"duration"];
  [currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp"];
  [_player removeObserver:self forKeyPath:@"rate"];
}

- (void)preparePictureInPictureController {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    if (_pipController || !_player) {
      return;
    }
    
    NSLog(@"🎬 [VideoPlayer] Preparing PiP controller for quick activation");
    
    // Get player layer from subclass or create new one
    AVPlayerLayer *layerForPiP = [self playerLayerForPiP];
    if (!layerForPiP) {
      NSLog(@"Creating new AVPlayerLayer for PiP preparation");
      layerForPiP = [AVPlayerLayer playerLayerWithPlayer:_player];
      _playerLayer = layerForPiP;
    }
    
    // Log current opacity to ensure it's correct
    NSLog(@"📏 [VideoPlayer] Layer opacity before PiP setup: %.3f", layerForPiP.opacity);
    
    // Ensure the layer has valid bounds
    if (CGRectIsEmpty(layerForPiP.bounds)) {
      NSLog(@"Setting default size for PiP layer");
      layerForPiP.frame = CGRectMake(0, 0, 320, 180);
    }
    
    // Create PiP controller
    if ([AVPictureInPictureController isPictureInPictureSupported]) {
      _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layerForPiP];
      _pipController.delegate = self;
      
      // Enable automatic PiP when app goes to background (iOS 14.2+)
      if (@available(iOS 14.2, *)) {
        _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
        NSLog(@"🚀 [VideoPlayer] Automatic PiP enabled for background transition (iOS 14.2+)");
      } else {
        NSLog(@"⚠️ [VideoPlayer] Automatic PiP not available (requires iOS 14.2+)");
      }
      
      _isPiPPrepared = YES;
      NSLog(@"✅ [VideoPlayer] PiP controller prepared successfully");
      NSLog(@"PiP controller isPictureInPicturePossible: %@", _pipController.isPictureInPicturePossible ? @"YES" : @"NO");
      NSLog(@"📏 [VideoPlayer] Layer opacity after PiP setup: %.3f", layerForPiP.opacity);
    } else {
      NSLog(@"⚠️ [VideoPlayer] PiP is not supported on this device");
    }
  }
#endif
}

- (void)setPictureInPictureEnabled:(BOOL)enabled {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    NSLog(@"🎭 ========================================");
    NSLog(@"🎭 [VideoPlayer] setPictureInPictureEnabled called");
    NSLog(@"🎭 Enabled: %@", enabled ? @"YES" : @"NO");
    NSLog(@"🎭 Current PiP Controller: %@", _pipController ? @"EXISTS" : @"NIL");
    NSLog(@"🎭 ========================================");
    
    if (enabled && !_pipController) {
      // Get player layer from subclass or create new one
      AVPlayerLayer *layerForPiP = [self playerLayerForPiP];
      if (!layerForPiP) {
        NSLog(@"Creating new AVPlayerLayer for PiP");
        layerForPiP = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer = layerForPiP;
        
        // Log opacity to ensure it's not 1.0
        NSLog(@"📏 [VideoPlayer] New layer opacity in setPictureInPictureEnabled: %.3f", layerForPiP.opacity);
      }
      
      NSLog(@"Using playerLayer for PiP: %@", layerForPiP);
      NSLog(@"Player layer superlayer: %@", layerForPiP.superlayer);
      NSLog(@"Player layer bounds: %@", NSStringFromCGRect(layerForPiP.bounds));
      NSLog(@"Player layer frame: %@", NSStringFromCGRect(layerForPiP.frame));
      NSLog(@"Player: %@", layerForPiP.player);
      NSLog(@"isPictureInPictureSupported: %@", [AVPictureInPictureController isPictureInPictureSupported] ? @"YES" : @"NO");
      
      // Ensure the layer has valid bounds
      if (CGRectIsEmpty(layerForPiP.bounds)) {
        NSLog(@"WARNING: Player layer has empty bounds, setting default size");
        layerForPiP.frame = CGRectMake(0, 0, 320, 180);
      }
      
      // Create PiP controller
      if ([AVPictureInPictureController isPictureInPictureSupported]) {
        NSLog(@"Creating AVPictureInPictureController with playerLayer: %@", layerForPiP);
        _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layerForPiP];
        _pipController.delegate = self;
        
        // Enable automatic PiP when app goes to background (iOS 14.2+)
        if (@available(iOS 14.2, *)) {
          _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
          NSLog(@"🚀 [VideoPlayer] Automatic PiP enabled in setPictureInPictureEnabled (iOS 14.2+)");
        }
        
        NSLog(@"PiP controller created: %@", _pipController);
        NSLog(@"PiP controller isPictureInPicturePossible: %@", _pipController.isPictureInPicturePossible ? @"YES" : @"NO");
      } else {
        NSLog(@"PiP is not supported on this device");
      }
    }
    
    if (_pipController) {
      if (enabled && ![_pipController isPictureInPictureActive]) {
        NSLog(@"Starting PiP");
        NSLog(@"PiP controller isPictureInPicturePossible before start: %@", _pipController.isPictureInPicturePossible ? @"YES" : @"NO");
        
        // Wait for player to be ready for PiP
        if (!_pipController.isPictureInPicturePossible) {
          NSLog(@"⏳ [VideoPlayer] PiP not ready yet, setting up observer and retrying...");
          
          // Remove any existing observer first
          @try {
            [_pipController removeObserver:self forKeyPath:@"isPictureInPicturePossible"];
          } @catch (NSException *exception) {
            // Observer might not exist, ignore
          }
          
          // Add observer for when PiP becomes possible
          [_pipController addObserver:self 
                           forKeyPath:@"isPictureInPicturePossible" 
                              options:NSKeyValueObservingOptionNew 
                              context:nil];
          
          // Also try again after a short delay
          dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 0.5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            if (self->_pipController && self->_pipController.isPictureInPicturePossible && !self->_pipController.isPictureInPictureActive) {
              NSLog(@"🔄 [VideoPlayer] Retry: PiP now possible, starting...");
              [self->_pipController startPictureInPicture];
            }
          });
        } else {
          NSLog(@"✅ [VideoPlayer] PiP ready immediately, starting...");
          [_pipController startPictureInPicture];
        }
      } else if (!enabled && [_pipController isPictureInPictureActive]) {
        NSLog(@"Stopping PiP");
        [_pipController stopPictureInPicture];
      }
    } else {
      NSLog(@"PiP controller is nil, cannot start/stop PiP");
    }
  } else {
    NSLog(@"iOS version < 9.0, PiP not available");
  }
#endif
}

- (void)setNowPlayingMetadataWithTitle:(nullable NSString *)title
                                 artist:(nullable NSString *)artist
                                  album:(nullable NSString *)album
                             artworkUrl:(nullable NSString *)artworkUrl {
#if TARGET_OS_IOS
  NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
  
  if (title) {
    metadata[MPMediaItemPropertyTitle] = title;
  }
  if (artist) {
    metadata[MPMediaItemPropertyArtist] = artist;
  }
  if (album) {
    metadata[MPMediaItemPropertyAlbumTitle] = album;
  }
  
  // Artwork URLからMPMediaItemArtworkを作成
  if (artworkUrl) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSURL *url = [NSURL URLWithString:artworkUrl];
      NSData *data = [NSData dataWithContentsOfURL:url];
      if (data) {
        UIImage *image = [UIImage imageWithData:data];
        if (image) {
          MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithImage:image];
          dispatch_async(dispatch_get_main_queue(), ^{
            NSMutableDictionary *updatedMetadata = [self->_currentMetadata mutableCopy] ?: [NSMutableDictionary dictionary];
            updatedMetadata[MPMediaItemPropertyArtwork] = artwork;
            self->_currentMetadata = [updatedMetadata copy];
            [self updateNowPlayingInfo];
          });
        }
      }
    });
  }
  
  _currentMetadata = [metadata copy];
  [self updateNowPlayingInfo];
#endif
}

#pragma mark - AVPictureInPictureControllerDelegate

- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP開始時の処理
  NSLog(@"PiP will start");
  _isInPictureInPicture = YES;
  
  // PiP開始時にフラグを初期化
  // 再生中にPiPに移行した場合、_pausedFromPiPはfalseのままにする
  // 一時停止中にPiPに移行した場合、それはPiPからの一時停止ではない
  if (_player.rate == 0 && _userExplicitlyPaused) {
    // 既に一時停止中の場合、PiPからの一時停止ではない
    _pausedFromPiP = NO;
    NSLog(@"PiP starting while already paused - not a PiP pause");
  } else {
    // 再生中のPiP移行
    _pausedFromPiP = NO;
    NSLog(@"PiP starting while playing - pausedFromPiP = NO");
  }
  
  // Update playing state to stop display link during PiP
  [self updatePlayingState];
  if (_eventSink != nil) {
    _eventSink(@{@"event" : @"pipStatusUpdate", @"isInPictureInPicture" : @YES});
  }
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP開始完了時の処理
  NSLog(@"PiP did start");
  
  // Debug player state
  NSLog(@"Player status: %ld", (long)_player.status);
  NSLog(@"Player rate: %f", _player.rate);
  NSLog(@"Current time: %f", CMTimeGetSeconds(_player.currentTime));
  NSLog(@"Player item status: %ld", (long)_player.currentItem.status);
  NSLog(@"Player layer bounds: %@", NSStringFromCGRect(_playerLayer.bounds));
  NSLog(@"Player layer video rect: %@", NSStringFromCGRect([_playerLayer videoRect]));
  
  // Ensure remote command center is active (非同期で実行してメインスレッドをブロックしない)
  dispatch_async(dispatch_get_main_queue(), ^{
    [self setupRemoteCommandCenterIfNeeded];
    [self updateNowPlayingInfo];
  });
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了時の処理
  NSLog(@"📺 [VideoPlayer] PiP will stop");
  NSLog(@"  - App state: %@", [UIApplication sharedApplication].applicationState == UIApplicationStateActive ? @"Active" : @"Background/Inactive");
  NSLog(@"  - Stop triggered by: %@", [UIApplication sharedApplication].applicationState == UIApplicationStateActive ? @"Foreground return (auto-stop)" : @"User action or system");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了完了時の処理
  NSLog(@"📺 [VideoPlayer] PiP did stop - transitioning back to app player");
  NSLog(@"  - App state: %@", [UIApplication sharedApplication].applicationState == UIApplicationStateActive ? @"Active" : @"Background/Inactive");
  _isInPictureInPicture = NO;
  
  // 一時的なPiPレイヤーをクリーンアップ
  AVPlayerLayer *pipLayer = pictureInPictureController.playerLayer;
  if (pipLayer && [pipLayer.name isEqualToString:@"pip_temp_layer"]) {
    NSLog(@"🧹 [VideoPlayer] Removing temporary PiP layer");
    [pipLayer removeFromSuperlayer];
  }
  
  // Resume display link after PiP
  [self updatePlayingState];
  if (_eventSink != nil) {
    _eventSink(@{@"event" : @"pipStatusUpdate", @"isInPictureInPicture" : @NO});
  }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
  // PiP開始失敗時の処理
  NSLog(@"❌ [VideoPlayer] PiP failed to start: %@", error);
  NSLog(@"Error domain: %@", error.domain);
  NSLog(@"Error code: %ld", (long)error.code);
  NSLog(@"Error userInfo: %@", error.userInfo);
  
  // 自動PiP失敗時のフォールバック処理
  NSLog(@"🔄 [VideoPlayer] PiP failed, falling back to background audio playback");
  [self fallbackToBackgroundAudioPlayback];
  
  // Flutter側に失敗を通知
  if (_eventSink != nil) {
    _eventSink(@{
      @"event" : @"pipFailure", 
      @"error" : error.localizedDescription ?: @"Unknown PiP error"
    });
  }
}

- (nullable AVPlayerLayer *)playerLayerForPiP {
  // Default implementation returns the instance variable
  // Subclasses should override this to provide their own layer
  NSLog(@"🔍 [VideoPlayer] playerLayerForPiP called");
  NSLog(@"  - _playerLayer exists: %@", _playerLayer ? @"YES" : @"NO");
  if (_playerLayer) {
    NSLog(@"  - Layer bounds: %@", NSStringFromCGRect(_playerLayer.bounds));
    NSLog(@"  - Layer superlayer: %@", _playerLayer.superlayer ? @"EXISTS" : @"NIL");
    NSLog(@"  - Layer player: %@", _playerLayer.player ? @"SET" : @"NIL");
  }
  return _playerLayer;
}

- (void)enableAutomaticPictureInPictureForBackground {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    // PiPコントローラーが事前に準備されているかチェック
    if (_isPiPPrepared && _pipController) {
      NSLog(@"✅ [VideoPlayer] Using pre-initialized PiP controller for quick activation");
    } else if (!_pipController) {
      // PiPコントローラーが存在しない場合は作成
      NSLog(@"⚠️ [VideoPlayer] PiP controller not pre-initialized, creating now");
      // プレイヤーレイヤーを取得または作成
      AVPlayerLayer *layerForPiP = [self playerLayerForPiP];
      if (!layerForPiP && _player) {
        NSLog(@"📺 [VideoPlayer] Creating player layer for automatic PiP");
        layerForPiP = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer = layerForPiP;
        
        // Log opacity to detect any issues
        NSLog(@"📏 [VideoPlayer] New layer opacity: %.3f", layerForPiP.opacity);
        
        // レイヤーのサイズを設定
        if (CGRectIsEmpty(layerForPiP.bounds)) {
          layerForPiP.frame = CGRectMake(0, 0, 320, 180);
        }
      }
      
      if (layerForPiP && [AVPictureInPictureController isPictureInPictureSupported]) {
        NSLog(@"📺 [VideoPlayer] Creating PiP controller for automatic background PiP");
        _pipController = [[AVPictureInPictureController alloc] initWithPlayerLayer:layerForPiP];
        _pipController.delegate = self;
        
        // Enable automatic PiP when app goes to background (iOS 14.2+)
        if (@available(iOS 14.2, *)) {
          _pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
          NSLog(@"🚀 [VideoPlayer] Automatic PiP enabled in enableAutomaticPictureInPictureForBackground (iOS 14.2+)");
        }
      }
    }
    
    // PiPが利用可能で、現在アクティブでない場合に開始
    if (_pipController && !_pipController.isPictureInPictureActive) {
      NSLog(@"📱 [VideoPlayer] PiP controller state check:");
      NSLog(@"  - isPictureInPicturePossible: %@", _pipController.isPictureInPicturePossible ? @"YES" : @"NO");
      NSLog(@"  - isPictureInPictureActive: %@", _pipController.isPictureInPictureActive ? @"YES" : @"NO");
      NSLog(@"  - isPictureInPictureSuspended: %@", _pipController.isPictureInPictureSuspended ? @"YES" : @"NO");
      
      // Check automatic PiP status for iOS 14.2+
      if (@available(iOS 14.2, *)) {
        NSLog(@"  - canStartPictureInPictureAutomaticallyFromInline: %@", 
              _pipController.canStartPictureInPictureAutomaticallyFromInline ? @"YES" : @"NO");
      }
      
      if (_pipController.isPictureInPicturePossible) {
        NSLog(@"🚀 [VideoPlayer] Starting automatic PiP for background playback");
        [_pipController startPictureInPicture];
      } else {
        NSLog(@"⏳ [VideoPlayer] PiP not ready yet, setting up observer for readiness");
        
        // 既存のオブザーバーを削除してから追加
        @try {
          [_pipController removeObserver:self forKeyPath:@"isPictureInPicturePossible"];
        } @catch (NSException *exception) {
          // オブザーバーが存在しない場合は無視
        }
        
        // PiPが可能になるまで待機
        [_pipController addObserver:self 
                         forKeyPath:@"isPictureInPicturePossible" 
                            options:NSKeyValueObservingOptionNew 
                            context:nil];
                            
        // 即座に再チェック（UISceneがまだフォアグラウンドの間に）
        dispatch_async(dispatch_get_main_queue(), ^{
          if (self->_pipController && self->_pipController.isPictureInPicturePossible && !self->_pipController.isPictureInPictureActive) {
            NSLog(@"🔄 [VideoPlayer] Immediate retry: PiP now possible, starting...");
            [self->_pipController startPictureInPicture];
          }
        });
      }
    } else if (_pipController && _pipController.isPictureInPictureActive) {
      NSLog(@"✅ [VideoPlayer] PiP already active");
    } else {
      NSLog(@"❌ [VideoPlayer] Failed to create PiP controller for automatic background PiP");
      
      // フォールバック：通常のバックグラウンド再生を確保
      [self fallbackToBackgroundAudioPlayback];
    }
  }
#endif
}

- (BOOL)shouldEnableAutomaticPiPForBackground {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    // 基本的な PiP サポートチェック
    if (![AVPictureInPictureController isPictureInPictureSupported]) {
      NSLog(@"❌ [VideoPlayer] PiP not supported on device");
      return NO;
    }
    
    // プレイヤーとプレイヤーアイテムの存在確認
    if (!_player || !_player.currentItem) {
      NSLog(@"❌ [VideoPlayer] No player or player item for PiP");
      return NO;
    }
    
    // 再生状態の確認（一時停止中でもPiPを許可）
    // ユーザーはPiPから再生を再開できるため、一時停止中でもPiPを許可
    if (!_isPlaying) {
      NSLog(@"⚠️ [VideoPlayer] Player is paused, but allowing PiP for user convenience");
      // 一時停止中でもPiPを許可
    }
    
    // プレイヤーアイテムの状態確認
    if (_player.currentItem.status != AVPlayerItemStatusReadyToPlay) {
      NSLog(@"❌ [VideoPlayer] Player item not ready for PiP");
      return NO;
    }
    
    // HLSストリームかどうか判定
    AVAsset *asset = _player.currentItem.asset;
    BOOL isHLS = NO;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)asset;
      NSURL *url = urlAsset.URL;
      isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
             [url.absoluteString.lowercaseString containsString:@"m3u8"];
    }
    
    // HLSは全て動画として扱う
    if (isHLS) {
      NSLog(@"✅ [VideoPlayer] HLS stream detected - treating as video for PiP");
    } else {
      // HLS以外は通常の動画トラック検出
      NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if (videoTracks.count == 0) {
        NSLog(@"❌ [VideoPlayer] No video tracks, PiP not applicable");
        return NO;
      }
    }
    
    NSLog(@"✅ [VideoPlayer] All conditions met for automatic PiP");
    return YES;
  }
#endif
  
  return NO;
}

- (void)fallbackToBackgroundAudioPlayback {
#if TARGET_OS_IOS
  NSLog(@"🎵 [VideoPlayer] Falling back to background audio playback (PiP unavailable)");
  
  // PiPが利用できない場合の音声のみバックグラウンド再生
  [self setupAudioSessionForBackgroundPlayback];
  [self setupRemoteCommandCenterIfNeeded];
  [self updateNowPlayingInfo];
  
  // 継続的なバックグラウンドタスクを確保
  if (_backgroundTask == UIBackgroundTaskInvalid) {
    [self startPersistentBackgroundTask];
  }
  
  NSLog(@"✅ [VideoPlayer] Background audio playback configured as PiP fallback");
#endif
}

#pragma mark - Application Lifecycle

#if TARGET_OS_IOS
- (void)applicationWillResignActive:(NSNotification *)notification {
  NSLog(@"⚠️⚠️⚠️ ========================================");
  NSLog(@"⚠️⚠️⚠️ APPLICATION WILL RESIGN ACTIVE CALLED!");
  NSLog(@"⚠️⚠️⚠️ PlayerInstance: %p", self);
  NSLog(@"⚠️⚠️⚠️ Timestamp: %@", [NSDate date]);
  NSLog(@"⚠️⚠️⚠️ ========================================");
  NSLog(@"📱 [VideoPlayer] Application will resign active - HLS強化背景再生開始");
  
  // 最優先：オーディオセッションを強制設定
  [self setupAudioSessionForBackgroundPlayback];
  
  // Ensure background task is active
  [self startPersistentBackgroundTask];
  
  // Update Now Playing info
  [self updateNowPlayingInfo];
  
  // For HLS streams, apply comprehensive background optimization
  if (_player.currentItem) {
    AVPlayerItem *item = _player.currentItem;
    AVAsset *asset = item.asset;
    
    // HLS特有の判定
    BOOL isHLS = NO;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)asset;
      NSURL *url = urlAsset.URL;
      isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
             [url.absoluteString.lowercaseString containsString:@"m3u8"];
    }
    
    if (isHLS) {
      NSLog(@"🎯 [VideoPlayer] HLS stream detected - applying video HLS background optimization");
      
      // HLSは全て動画として扱う
      NSLog(@"🎬 [VideoPlayer] HLS stream type: Video HLS (treating all HLS as video)");
      
      // 動画HLS専用の最適化
      NSLog(@"🎬 [VideoPlayer] Applying video HLS background optimization");
        
      // 動画HLS用のバッファリング設定（大幅強化）
      item.preferredForwardBufferDuration = 25.0;  // 動画は25秒バッファ
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
      
      // バックグラウンド動画再生専用設定
      // 注記：automaticallyWaitsToMinimizeStalling プロパティは一部のiOSバージョンで利用できないため、
      // 代わりにpreferredForwardBufferDurationの調整で積極的バッファリングを実現
      
      // 動画品質の最適化（バックグラウンド用）
      if ([item respondsToSelector:@selector(setPreferredPeakBitRate:)]) {
        // バックグラウンドでは中程度の品質に制限してバッファを安定化
        item.preferredPeakBitRate = 2000000;  // 2Mbps程度に制限
      }
      
      // 動画HLSの場合はPiPが利用可能かチェック
      if ([AVPictureInPictureController isPictureInPictureSupported]) {
        NSLog(@"📺 [VideoPlayer] PiP is supported for video HLS - consider automatic PiP activation");
        // PiP自動開始は別途設定で制御可能にする
      }
      
      // 共通のHLS設定
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
      
      // HTTP headers maintenance for HLS segments
      [self ensureHTTPHeadersForBackgroundPlayback];
      
      NSLog(@"✅ [VideoPlayer] HLS background optimization applied - Buffer: %.1fs", item.preferredForwardBufferDuration);
    } else {
      // 通常のストリーム
      item.preferredForwardBufferDuration = 15.0;
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    }
  }
  
  // デバイスロック状態をリアルタイムで再確認
  BOOL currentlyLocked = ![UIApplication sharedApplication].protectedDataAvailable;
  if (currentlyLocked && !_deviceIsLocked) {
    _deviceIsLocked = YES;
    NSLog(@"🔒 [VideoPlayer] Device lock detected via protectedDataAvailable check");
  }
  
  // Keep player playing if it was playing (but not if device is locked or paused from PiP)
  if (_isPlaying && _player.rate == 0 && !_userExplicitlyPaused && !_deviceIsLocked && !_pausedFromPiP) {
    // 再度デバイスロック状態を確認（タイミング問題対策）
    if (![UIApplication sharedApplication].protectedDataAvailable) {
      NSLog(@"⚠️ [VideoPlayer] Device lock detected just before play - aborting restart");
      _deviceIsLocked = YES;
    } else {
      NSLog(@"🔄 [VideoPlayer] Restarting playback for background");
      [_player play];
    }
  } else if (_deviceIsLocked) {
    NSLog(@"🔒 [VideoPlayer] Device is locked - skipping background playback restart");
  } else if (_pausedFromPiP) {
    NSLog(@"⏸️ [VideoPlayer] Paused from PiP - skipping background playback restart");
  }
  
  // Start continuous buffer monitoring for HLS
  [self startBackgroundBufferMonitoring];
  
  // Start high-frequency playback monitoring (1s interval)
  [self startBackgroundPlaybackMonitoring];
  
  // iOS 14.2+では自動PiPが有効なので、手動でのPiP開始は不要
  if (@available(iOS 14.2, *)) {
    if (_pipController && _pipController.canStartPictureInPictureAutomaticallyFromInline) {
      NSLog(@"🤖 [VideoPlayer] Automatic PiP is enabled - system will handle PiP transition");
      // システムが自動的にPiPを開始するので、手動での開始は不要
    } else if (_isPiPPrepared && _pipController && !_pipController.isPictureInPictureActive) {
      // iOS 14.2未満の場合は従来の手動開始を試みる
      if (_pipController.isPictureInPicturePossible) {
        NSLog(@"🚀 [VideoPlayer] Starting PiP manually for iOS < 14.2");
        [_pipController startPictureInPicture];
        // PiP開始を即座に処理、遅延なし
        return; // PiP開始後は後続の処理をスキップ
      }
    }
  } else {
    // iOS 14.2未満の場合
    if (_isPiPPrepared && _pipController && !_pipController.isPictureInPictureActive) {
      if (_pipController.isPictureInPicturePossible) {
        NSLog(@"🚀 [VideoPlayer] Starting PiP immediately before background transition");
        [_pipController startPictureInPicture];
        // PiP開始を即座に処理、遅延なし
        return; // PiP開始後は後続の処理をスキップ
      }
    }
  }
  
  // iOS 14.2+で自動PiPが有効な場合は、以下の手動処理をスキップ
  BOOL shouldSkipManualPiP = NO;
  if (@available(iOS 14.2, *)) {
    if (_pipController && _pipController.canStartPictureInPictureAutomaticallyFromInline) {
      shouldSkipManualPiP = YES;
      NSLog(@"🤖 [VideoPlayer] Skipping manual PiP logic - automatic PiP is enabled");
    }
  }
  
  if (!shouldSkipManualPiP) {
    // iOS 13以降でapplicationDidEnterBackgroundが発火しない問題の回避策
    // 即座にPiP処理を実行（遅延なし）
    NSLog(@"🔄 [VideoPlayer] Immediately executing PiP for background transition");
    
    // 動画再生中の場合、即座にPiPを試みる（HLSに限定しない）
    if (_player.currentItem && !_pipController.isPictureInPictureActive) {
    AVAsset *asset = _player.currentItem.asset;
    
    NSLog(@"🔍 [VideoPlayer] Checking PiP eligibility on background transition");
    
    // HLSストリームかどうか判定
    BOOL isHLS = NO;
    if ([asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)asset;
      NSURL *url = urlAsset.URL;
      isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
             [url.absoluteString.lowercaseString containsString:@"m3u8"];
    }
    
    // HLSは全て動画として扱う
    BOOL hasVideoTracks = NO;
    if (isHLS) {
      hasVideoTracks = YES;
      NSLog(@"  - HLS stream detected - treating as video content");
    } else {
      // HLS以外は通常の動画トラック検出
      NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      hasVideoTracks = (videoTracks.count > 0);
    }
    
    NSLog(@"  - Has video tracks: %@", hasVideoTracks ? @"YES" : @"NO");
    NSLog(@"  - Is HLS: %@", isHLS ? @"YES" : @"NO");
    NSLog(@"  - Is playing: %@", _isPlaying ? @"YES" : @"NO");
    NSLog(@"  - PiP controller exists: %@", _pipController ? @"YES" : @"NO");
    NSLog(@"  - PiP is prepared: %@", _isPiPPrepared ? @"YES" : @"NO");
    
    if (hasVideoTracks) {
      NSLog(@"🎬 [VideoPlayer] Video content detected - attempting PiP immediately");
      #if TARGET_OS_IOS
      if (@available(iOS 9.0, *)) {
        BOOL shouldEnablePiP = [self shouldEnableAutomaticPiPForBackground];
        NSLog(@"📺 [VideoPlayer] Should enable PiP: %@", shouldEnablePiP ? @"YES" : @"NO");
        
        if (shouldEnablePiP) {
          NSLog(@"📺 [VideoPlayer] Starting PiP immediately without delay");
          [self enableAutomaticPictureInPictureForBackground];
        } else {
          NSLog(@"⚠️ [VideoPlayer] PiP conditions not met");
        }
      } else {
        NSLog(@"⚠️ [VideoPlayer] iOS version < 9.0, PiP not available");
      }
      #endif
    } else {
      NSLog(@"⚠️ [VideoPlayer] No video tracks detected - PiP not applicable");
    }
  }
  } // End of !shouldSkipManualPiP block
  
  // フォールバック処理を即座に実行
  dispatch_async(dispatch_get_main_queue(), ^{
    NSLog(@"🎯 [VideoPlayer] FALLBACK: Executing remaining background transition logic");
    [self executeBackgroundTransitionLogic];
  });
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  NSLog(@"🟢🟢🟢 ========================================");
  NSLog(@"🟢🟢🟢 APPLICATION DID BECOME ACTIVE CALLED!");
  NSLog(@"🟢🟢🟢 PlayerInstance: %p", self);
  NSLog(@"🟢🟢🟢 Timestamp: %@", [NSDate date]);
  NSLog(@"🟢🟢🟢 ========================================");
  NSLog(@"📱 [VideoPlayer] Application did become active - バックグラウンド維持により通知センター継続中");
  
  // バックグラウンド移行フラグをリセット
  _backgroundTransitionExecuted = NO;
  NSLog(@"🔄 [VideoPlayer] Reset background transition flag for next cycle");
  
#if TARGET_OS_IOS
  // バックグラウンドタイマーをクリーンアップ（アプリがアクティブな間は不要）
  if (_playbackMonitoringTimer) {
    [_playbackMonitoringTimer invalidate];
    _playbackMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Playback monitoring timer stopped - app is active");
  }
  
  if (_bufferMonitoringTimer) {
    [_bufferMonitoringTimer invalidate];
    _bufferMonitoringTimer = nil;
    NSLog(@"🗑️ [VideoPlayer] Buffer monitoring timer stopped - app is active");
  }
  
  // PiPがアクティブな場合は自動的に終了してアプリ内プレイヤーに戻す
  if (@available(iOS 9.0, *)) {
    if (_pipController && _pipController.isPictureInPictureActive) {
      NSLog(@"📺 [VideoPlayer] PiP is active, automatically stopping to return to app player");
      NSLog(@"  - PiP controller: %@", _pipController ? @"EXISTS" : @"NIL");
      NSLog(@"  - isPictureInPictureActive: %@", _pipController.isPictureInPictureActive ? @"YES" : @"NO");
      NSLog(@"  - isPictureInPicturePossible: %@", _pipController.isPictureInPicturePossible ? @"YES" : @"NO");
      
      // PiPを自動的に終了
      [_pipController stopPictureInPicture];
      NSLog(@"✅ [VideoPlayer] PiP stop requested - should transition back to app player");
    } else {
      NSLog(@"🔍 [VideoPlayer] PiP is not active, no action needed");
      if (_pipController) {
        NSLog(@"  - PiP controller exists but not active");
      } else {
        NSLog(@"  - No PiP controller");
      }
    }
  }
#endif
  
  // バックグラウンドタスクが継続的にオーディオセッションを維持しているため、
  // 複雑な再設定は不要。簡単な確認のみ行う。
  [self maintainAudioSessionAndNotificationCenter];
  
  NSLog(@"✅ [VideoPlayer] Foreground restoration completed - notification center should remain visible");
}

- (void)endBackgroundTask {
  if (_backgroundTask != UIBackgroundTaskInvalid) {
    NSLog(@"Ending background task: %lu", (unsigned long)_backgroundTask);
    [[UIApplication sharedApplication] endBackgroundTask:_backgroundTask];
    _backgroundTask = UIBackgroundTaskInvalid;
  }
  
  // Stop background task refresh timer
  [self stopBackgroundTaskRefreshTimer];
}

- (void)startPersistentBackgroundTask {
  // End any existing task first
  [self endBackgroundTask];
  
  __weak typeof(self) weakSelf = self;
  _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"VideoPlayerBackground" 
                                                                 expirationHandler:^{
    // If task is about to expire, try to extend it
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      NSLog(@"⚠️ [VideoPlayer] Background task expiring, attempting to extend...");
      dispatch_async(dispatch_get_main_queue(), ^{
        // Maintain audio session and notification center
        [strongSelf maintainAudioSessionAndNotificationCenter];
        // End current task
        [strongSelf endBackgroundTask];
        // 一時停止中でもバックグラウンドタスクを再開
        if (strongSelf.player && (strongSelf->_isPlaying || strongSelf->_userExplicitlyPaused)) {
          NSLog(@"🔄 [VideoPlayer] Restarting background task (playing: %@, paused: %@)",
                strongSelf->_isPlaying ? @"YES" : @"NO",
                strongSelf->_userExplicitlyPaused ? @"YES" : @"NO");
          [strongSelf startPersistentBackgroundTask];
        }
      });
    }
  }];
  
  // Immediately ensure audio session is active for the background task (非同期で実行)
  dispatch_async(dispatch_get_main_queue(), ^{
    [self maintainAudioSessionAndNotificationCenter];
  });
  
  // Start background task refresh timer (20秒ごとにタスクをリフレッシュ)
  [self startBackgroundTaskRefreshTimer];
  
  NSLog(@"🔄 Started persistent background task with audio session maintenance: %lu", (unsigned long)_backgroundTask);
}

- (void)executeBackgroundTransitionLogic {
  // 重複実行を避ける
  if (_backgroundTransitionExecuted) {
    NSLog(@"⚠️ [VideoPlayer] Background transition logic already executed, skipping");
    return;
  }
  
  NSLog(@"🎯 [VideoPlayer] EXECUTING BACKGROUND TRANSITION LOGIC");
  _backgroundTransitionExecuted = YES;
  
  // Ensure background task is active
  if (_backgroundTask == UIBackgroundTaskInvalid) {
    [self startPersistentBackgroundTask];
  }
  
  // 動画HLSの場合の特別処理
  if (_player.currentItem) {
    AVAsset *asset = _player.currentItem.asset;
    BOOL isHLS = NO;
    
    if ([asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)asset;
      NSURL *url = urlAsset.URL;
      isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
             [url.absoluteString.lowercaseString containsString:@"m3u8"];
    }
    
    if (isHLS) {
      NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      if (videoTracks.count > 0) {
        NSLog(@"🎬 [VideoPlayer] Video HLS detected in background - applying special handling");
        
        // 動画HLSの場合、自動でPiPを開始
        #if TARGET_OS_IOS
        if (@available(iOS 9.0, *)) {
          if ([self shouldEnableAutomaticPiPForBackground]) {
            NSLog(@"📺 [VideoPlayer] Attempting automatic PiP for video HLS background playback");
            [self enableAutomaticPictureInPictureForBackground];
          } else {
            NSLog(@"⚠️ [VideoPlayer] Automatic PiP conditions not met, using background audio");
            [self fallbackToBackgroundAudioPlayback];
          }
        }
        #endif
        
        // 動画HLS用バックグラウンド最適化
        AVPlayerItem *item = _player.currentItem;
        item.preferredForwardBufferDuration = 30.0;  // バックグラウンドでは更に長く
        
        // デバイスロック状態をリアルタイムで確認
        BOOL currentlyLockedHLS = ![UIApplication sharedApplication].protectedDataAvailable;
        if (currentlyLockedHLS && !_deviceIsLocked) {
          _deviceIsLocked = YES;
          NSLog(@"🔒 [VideoPlayer] Device lock detected during HLS processing");
        }
        
        // 動画再生の継続確保（デバイスロック時やPiP一時停止時は除く）
        if (_isPlaying && _player.rate == 0 && !_userExplicitlyPaused && !_deviceIsLocked && !_pausedFromPiP) {
          // 再生前にもう一度確認
          if (![UIApplication sharedApplication].protectedDataAvailable) {
            NSLog(@"⚠️ [VideoPlayer] Device lock detected just before HLS play - aborting");
            _deviceIsLocked = YES;
          } else {
            NSLog(@"🎬 [VideoPlayer] Ensuring video HLS continues in background");
            [_player play];
          }
        } else if (_deviceIsLocked) {
          NSLog(@"🔒 [VideoPlayer] Device is locked - skipping HLS background restart");
        } else if (_pausedFromPiP) {
          NSLog(@"⏸️ [VideoPlayer] Paused from PiP - skipping HLS background restart");
        }
      }
    }
  }
  
  // 重要：バックグラウンドでオーディオセッションと通知センターを継続維持
  [self maintainAudioSessionAndNotificationCenter];
  
  // デバイスロック状態の最終確認
  BOOL finalLockCheck = ![UIApplication sharedApplication].protectedDataAvailable;
  if (finalLockCheck && !_deviceIsLocked) {
    _deviceIsLocked = YES;
    NSLog(@"🔒 [VideoPlayer] Device lock detected at final check");
  }
  
  // バックグラウンド移行完了時に即座に再生状態をチェック
  // デバイスロック時やPiP一時停止時は自動再生をスキップ
  if (_isPlaying && _player.rate == 0 && !_userExplicitlyPaused && !_deviceIsLocked && !_pausedFromPiP) {
    // 最後の再生前チェック
    if (![UIApplication sharedApplication].protectedDataAvailable) {
      NSLog(@"⚠️ [VideoPlayer] Device lock detected at final play attempt - aborting");
      _deviceIsLocked = YES;
    } else {
      NSLog(@"🔄 [VideoPlayer] Background transition detected playback stopped, restarting immediately");
      [_player play];
    }
  } else if (_pausedFromPiP) {
    NSLog(@"⏸️ [VideoPlayer] Paused from PiP - skipping background transition restart");
  }
  
  NSLog(@"✅ [VideoPlayer] Background transition logic completed");
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
  NSLog(@"📱📱📱 ========================================");
  NSLog(@"📱📱📱 APPLICATION DID ENTER BACKGROUND CALLED!");
  NSLog(@"📱📱📱 PlayerInstance: %p", self);
  NSLog(@"📱📱📱 Notification: %@", notification);
  NSLog(@"📱📱📱 Timestamp: %@", [NSDate date]);
  NSLog(@"📱📱📱 ========================================");
  NSLog(@"📱 Application did enter background - 動画HLS専用バックグラウンド処理開始");
  
  // デバイスがバックグラウンドに入る際のロック検知を削除
  // PiP時はデバイスがロックされていないため、実際のロック通知のみに依存する
  // この部分が問題の原因であるため、コメントアウト
  // if (!_deviceIsLocked) {
  //   _deviceIsLocked = YES;
  //   NSLog(@"🔒 [VideoPlayer] Setting device locked flag on background entry");
  // }
  NSLog(@"📌 [VideoPlayer] Not setting device locked flag - waiting for actual lock notification");
  
  // 既に実装された処理を呼び出し（重複を避ける）
  NSLog(@"🔄 [VideoPlayer] Delegating to background transition logic");
  [self executeBackgroundTransitionLogic];
  
  NSLog(@"✅ [VideoPlayer] Background transition completed with video HLS optimization");
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
  NSLog(@"🔆🔆🔆 ========================================");
  NSLog(@"🔆🔆🔆 APPLICATION WILL ENTER FOREGROUND CALLED!");
  NSLog(@"🔆🔆🔆 PlayerInstance: %p", self);
  NSLog(@"🔆🔆🔆 Timestamp: %@", [NSDate date]);
  NSLog(@"🔆🔆🔆 ========================================");
  NSLog(@"📱 [VideoPlayer] Application will enter foreground - avoiding RCC duplicate setup");
  
  // RemoteCommandCenterの重複設定を避ける
  // 初回のみ設定し、既に設定済みの場合はスキップ
  [self setupRemoteCommandCenterIfNeeded];
  
  // メタデータのみ更新（接続は維持）
  [self updateNowPlayingInfo];
}

- (void)protectedDataWillBecomeUnavailable:(NSNotification *)notification {
  NSLog(@"🔒🔒🔒 ========================================");
  NSLog(@"🔒🔒🔒 DEVICE WILL BE LOCKED!");
  NSLog(@"🔒🔒🔒 PlayerInstance: %p", self);
  NSLog(@"🔒🔒🔒 Timestamp: %@", [NSDate date]);
  NSLog(@"🔒🔒🔒 ========================================");
  
  _deviceIsLocked = YES;
  
  // デバイスロック時は再生状態を保存しておく
  if (_player.rate > 0) {
    NSLog(@"🔒 [VideoPlayer] Device locking - player is currently playing");
  } else {
    NSLog(@"🔒 [VideoPlayer] Device locking - player is currently paused");
  }
}

- (void)protectedDataDidBecomeAvailable:(NSNotification *)notification {
  NSLog(@"🔓🔓🔓 ========================================");
  NSLog(@"🔓🔓🔓 DEVICE UNLOCKED!");
  NSLog(@"🔓🔓🔓 PlayerInstance: %p", self);
  NSLog(@"🔓🔓🔓 Timestamp: %@", [NSDate date]);
  NSLog(@"🔓🔓🔓 ========================================");
  
  _deviceIsLocked = NO;
  
  // デバイスアンロック時は何もしない（ユーザーの操作に委ねる）
  NSLog(@"🔓 [VideoPlayer] Device unlocked - waiting for user action");
}
#endif

#pragma mark - Audio Session Management

- (void)maintainAudioSessionAndNotificationCenter {
#if TARGET_OS_IOS
  // オーディオセッションの状態を確認して必要に応じて維持
  AVAudioSession *audioSession = [AVAudioSession sharedInstance];
  
  // 現在のオーディオセッション状態をログ出力
  NSLog(@"🔍 [VideoPlayer] Audio session status - Category: %@, Active: %@", 
        audioSession.category, 
        audioSession.isOtherAudioPlaying ? @"YES" : @"NO");
  
  // オーディオセッションが非アクティブの場合のみアクティベートを試みる
  if (!audioSession.isOtherAudioPlaying) {
    NSError *error = nil;
    BOOL success = [audioSession setActive:YES error:&error];
    if (!success || error) {
      NSLog(@"⚠️ [VideoPlayer] Failed to maintain audio session (may be controlled by other component): %@", error);
      // エラーでも続行
    } else {
      NSLog(@"✅ [VideoPlayer] Audio session maintained in background");
    }
  } else {
    NSLog(@"✅ [VideoPlayer] Audio session already active (maintained by system)");
  }
  
  // 通知センターの情報を更新して可視性を維持
  [self updateNowPlayingInfo];
  NSLog(@"🎵 [VideoPlayer] Notification center updated to maintain visibility");
#endif
}

- (void)startBackgroundPlaybackMonitoring {
#if TARGET_OS_IOS
  // 再生状態の高頻度監視を開始（1秒間隔）
  if (!_player || !_player.currentItem) {
    return;
  }
  
  // 既存のタイマーを無効化
  if (_playbackMonitoringTimer) {
    [_playbackMonitoringTimer invalidate];
    _playbackMonitoringTimer = nil;
  }
  
  NSLog(@"🎯 [VideoPlayer] Starting high-frequency playback monitoring (1s interval)");
  
  // 再生状態専用の監視タイマー（メインスレッドで実行）
  __weak typeof(self) weakSelf = self;
  _playbackMonitoringTimer = [NSTimer scheduledTimerWithTimeInterval:1.0
                                                             repeats:YES
                                                               block:^(NSTimer * _Nonnull timer) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.player || !strongSelf.player.currentItem || strongSelf->_disposed) {
      [timer invalidate];
      NSLog(@"🛑 [VideoPlayer] Stopping playback monitoring - player disposed");
      return;
    }
    
    // アプリがアクティブな場合は監視不要
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateActive) {
      return;
    }
    
    // プレイヤーが予期せず停止している場合の迅速な復旧
    // デバイスロック状態も最初の条件に含める
    if (strongSelf->_isPlaying && strongSelf.player.rate == 0 && !strongSelf->_userExplicitlyPaused && !strongSelf->_pausedFromPiP && !strongSelf->_deviceIsLocked) {
      // デバイスがロックされていない場合のみ再生を再開
      AVPlayerItem *currentItem = strongSelf.player.currentItem;
      // バッファが十分あるかチェック
      if (currentItem.isPlaybackLikelyToKeepUp || currentItem.isPlaybackBufferFull) {
        NSLog(@"🚀 [VideoPlayer] Quick restart triggered (1s check)");
        NSLog(@"  - Player should be playing but stopped");
        NSLog(@"  - User did not pause");
        NSLog(@"  - Buffer is sufficient");
        NSLog(@"  - Device is NOT locked");
        NSLog(@"  - NOT paused from PiP");
        [strongSelf.player play];
      }
    } else if (strongSelf->_pausedFromPiP) {
      NSLog(@"⏸️ [VideoPlayer] Paused from PiP - skipping auto-restart (1s check)");
    } else if (strongSelf->_deviceIsLocked) {
      NSLog(@"🔒 [VideoPlayer] Device is locked - skipping auto-restart (1s check)");
    }
  }];
#endif
}

- (void)setupAudioSessionForBackgroundPlayback {
#if TARGET_OS_IOS
  NSError *error = nil;
  AVAudioSession *audioSession = [AVAudioSession sharedInstance];
  
  NSLog(@"🔧 [VideoPlayer] Forcing audio session setup for reliable HLS background playback");
  
  // HLS背景再生用の最適化されたオーディオセッション設定
  // 1. シンプルなカテゴリ設定でエラー-50を回避
  BOOL categorySuccess = [audioSession setCategory:AVAudioSessionCategoryPlayback error:&error];
  
  if (!categorySuccess || error) {
    NSLog(@"⚠️ [VideoPlayer] Failed to force audio session category: %@", error);
    NSLog(@"🔄 [VideoPlayer] Attempting alternative category setup...");
    
    // 代替手段：より基本的な設定を試行
    categorySuccess = [audioSession setCategory:AVAudioSessionCategoryPlayback error:&error];
    if (categorySuccess && !error) {
      NSLog(@"✅ [VideoPlayer] Alternative audio session category set successfully");
    }
  } else {
    NSLog(@"✅ [VideoPlayer] Audio session category forcefully set for HLS background playback");
  }
  
  // 2. モード設定をスキップ（エラー-50回避のため）
  NSLog(@"🔧 [VideoPlayer] Skipping audio session mode setting to avoid error -50");
  
  // 3. シンプルなオーディオセッションアクティベーション
  BOOL activateSuccess = [audioSession setActive:YES error:&error];
  if (!activateSuccess || error) {
    NSLog(@"⚠️ [VideoPlayer] Failed to activate audio session: %@", error);
  } else {
    NSLog(@"✅ [VideoPlayer] Audio session activated successfully for background playback");
  }
  
  // 4. 品質設定をスキップ（エラー-50回避のため）
  NSLog(@"🔧 [VideoPlayer] Skipping sample rate setting to avoid error -50");
  
  // 最終確認とログ出力
  NSLog(@"📊 [VideoPlayer] Final audio session state:");
  NSLog(@"  Category: %@", audioSession.category);
  NSLog(@"  Mode: %@", audioSession.mode);
  NSLog(@"  Other Audio Playing: %@", audioSession.isOtherAudioPlaying ? @"YES" : @"NO");
  NSLog(@"  Sample Rate: %.1f Hz", audioSession.sampleRate);
  NSLog(@"  Remote Command Center Configured: %@", _isRemoteCommandCenterConfigured ? @"YES" : @"NO");
  NSLog(@"✅ [VideoPlayer] Audio session setup completed - ready for RemoteCommandCenter");
#endif
}

#pragma mark - Remote Command Center

- (void)setupRemoteCommandCenterIfNeeded {
#if TARGET_OS_IOS
  NSLog(@"🎮 [VideoPlayer] setupRemoteCommandCenterIfNeeded called - configured: %@", _isRemoteCommandCenterConfigured ? @"YES" : @"NO");
  
  if (_isRemoteCommandCenterConfigured) {
    NSLog(@"🎮 [VideoPlayer] Remote Command Center already configured, skipping setup");
    return;
  }
  
  NSLog(@"🎮 [VideoPlayer] Setting up Remote Command Center for the first time");
  [self setupRemoteCommandCenter];  // 修正：無限再帰を防ぐ
  _isRemoteCommandCenterConfigured = YES;
  NSLog(@"🎮 [VideoPlayer] Remote Command Center configuration completed and flag set");
#endif
}

- (void)setupRemoteCommandCenter {
#if TARGET_OS_IOS
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  
  NSLog(@"🎮 [VideoPlayer] Setting up Remote Command Center (Live Stream: %@)", _isLiveStream ? @"YES" : @"NO");
  
  // Clean up ALL existing targets first
  [commandCenter.playCommand removeTarget:nil];
  [commandCenter.pauseCommand removeTarget:nil];
  [commandCenter.togglePlayPauseCommand removeTarget:nil];
  [commandCenter.changePlaybackPositionCommand removeTarget:nil];
  [commandCenter.stopCommand removeTarget:nil];
  
  // Create weak reference to avoid retain cycles
  __weak typeof(self) weakSelf = self;
  
  // Play command
  [commandCenter.playCommand setEnabled:YES];
  [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      // デバイスロック時は再生を許可しない
      if (strongSelf->_deviceIsLocked) {
        NSLog(@"⛔ [VideoPlayer] Play command blocked - device is locked");
        return MPRemoteCommandHandlerStatusCommandFailed;
      }
      NSLog(@"▶️ [VideoPlayer] User resumed from PiP controls");
      strongSelf->_pausedFromPiP = NO;  // PiPから明示的に再生された
      [strongSelf play];
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
  // Pause command
  [commandCenter.pauseCommand setEnabled:YES];
  [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      NSLog(@"🎮 [VideoPlayer] User paused via Remote Command Center");
      [strongSelf pause];  // これで_userExplicitlyPaused = YESが設定される
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
  // Toggle play/pause command
  [commandCenter.togglePlayPauseCommand setEnabled:YES];
  [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      if ([strongSelf isPlaying]) {
        NSLog(@"⏸️ [VideoPlayer] User paused from PiP controls (toggle)");
        [strongSelf pause];
      } else {
        // デバイスロック時は再生を許可しない
        if (strongSelf->_deviceIsLocked) {
          NSLog(@"⛔ [VideoPlayer] Play command blocked - device is locked (toggle)");
          return MPRemoteCommandHandlerStatusCommandFailed;
        }
        NSLog(@"▶️ [VideoPlayer] User resumed from PiP controls (toggle)");
        strongSelf->_pausedFromPiP = NO;  // PiPから明示的に再生された
        [strongSelf play];
      }
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
  // Change playback position command (seek) - disabled for live streams
  BOOL enableSeekCommand = !_isLiveStream;
  [commandCenter.changePlaybackPositionCommand setEnabled:enableSeekCommand];
  
  if (enableSeekCommand) {
    [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (strongSelf) {
        MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
        [strongSelf seekTo:(int64_t)(positionEvent.positionTime * 1000) completionHandler:nil];
        return MPRemoteCommandHandlerStatusSuccess;
      }
      return MPRemoteCommandHandlerStatusCommandFailed;
    }];
  } else {
    [commandCenter.changePlaybackPositionCommand removeTarget:nil];
    NSLog(@"🔴 [VideoPlayer] Seek command disabled for live stream");
  }
  
  // Stop command (optional but useful)
  [commandCenter.stopCommand setEnabled:YES];
  [commandCenter.stopCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      [strongSelf pause];
      [strongSelf seekTo:0 completionHandler:nil];
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
  // Ensure audio session is active
  NSError *error = nil;
  [[AVAudioSession sharedInstance] setActive:YES error:&error];
  if (error) {
    NSLog(@"Failed to activate audio session in setupRemoteCommandCenter: %@", error);
  }
  
  NSLog(@"Remote Command Center setup completed");
#endif
}

- (void)cleanupRemoteCommandCenter {
#if TARGET_OS_IOS
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  
  // Remove all command targets
  [commandCenter.playCommand removeTarget:self];
  [commandCenter.pauseCommand removeTarget:self];
  [commandCenter.togglePlayPauseCommand removeTarget:self];
  [commandCenter.changePlaybackPositionCommand removeTarget:self];
  
  // Disable commands
  commandCenter.playCommand.enabled = NO;
  commandCenter.pauseCommand.enabled = NO;
  commandCenter.togglePlayPauseCommand.enabled = NO;
  commandCenter.changePlaybackPositionCommand.enabled = NO;
  
  // Reset configuration flag
  _isRemoteCommandCenterConfigured = NO;
  NSLog(@"🎮 [VideoPlayer] Remote Command Center cleaned up and flag reset");
#endif
}

- (void)updateNowPlayingInfo {
#if TARGET_OS_IOS
  NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];
  
  // Duration
  Float64 duration = CMTimeGetSeconds([[[_player currentItem] asset] duration]);
  if (!isnan(duration) && duration > 0) {
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(duration);
  }
  
  // Current time
  Float64 currentTime = CMTimeGetSeconds([_player currentTime]);
  if (!isnan(currentTime)) {
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(currentTime);
  }
  
  // Playback rate
  nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(_player.rate);
  
  // Live stream support
  if (_isLiveStream) {
    nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = @YES;
    NSLog(@"🔴 [VideoPlayer] Setting Live stream flag in Now Playing Info");
    
    // For live streams, remove duration and position info as they're not applicable
    [nowPlayingInfo removeObjectForKey:MPMediaItemPropertyPlaybackDuration];
    [nowPlayingInfo removeObjectForKey:MPNowPlayingInfoPropertyElapsedPlaybackTime];
  }
  
  // Apply metadata if available
  if (_currentMetadata) {
    [nowPlayingInfo addEntriesFromDictionary:_currentMetadata];
  } else {
    // 音声ファイル判定（動画トラックがない場合）
    AVAsset *asset = [[[_player currentItem] asset] copy];
    NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
    BOOL isAudioOnly = (videoTracks.count == 0);
    
    // デフォルトタイトルを音声/動画に応じて設定
    if (isAudioOnly) {
      nowPlayingInfo[MPMediaItemPropertyTitle] = @"Audio";
      nowPlayingInfo[MPMediaItemPropertyMediaType] = @(MPMediaTypeAudioBook);
    } else {
      nowPlayingInfo[MPMediaItemPropertyTitle] = @"Video";
      nowPlayingInfo[MPMediaItemPropertyMediaType] = @(MPMediaTypeMovie);
    }
  }
  
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
  
  if (_isLiveStream) {
    NSLog(@"🔴 [VideoPlayer] Now Playing Info updated for LIVE STREAM - Rate: %.1f", _player.rate);
  } else {
    NSLog(@"🎵 [VideoPlayer] Now Playing Info updated - Duration: %.1fs, Position: %.1fs", duration, currentTime);
  }
#endif
}

#if TARGET_OS_IOS
- (void)startBackgroundBufferMonitoring {
  // HLSストリームの継続的なバッファ監視を開始
  if (!_player.currentItem) {
    return;
  }
  
  AVPlayerItem *item = _player.currentItem;
  AVAsset *asset = item.asset;
  
  // HLS判定
  BOOL isHLS = NO;
  if ([asset isKindOfClass:[AVURLAsset class]]) {
    AVURLAsset *urlAsset = (AVURLAsset *)asset;
    NSURL *url = urlAsset.URL;
    isHLS = [url.pathExtension.lowercaseString isEqualToString:@"m3u8"] || 
           [url.absoluteString.lowercaseString containsString:@"m3u8"];
  }
  
  if (!isHLS) {
    NSLog(@"📊 [VideoPlayer] Non-HLS stream, skipping buffer monitoring");
    return;
  }
  
  // 既存のタイマーを無効化
  if (_bufferMonitoringTimer) {
    [_bufferMonitoringTimer invalidate];
    _bufferMonitoringTimer = nil;
  }
  
  NSLog(@"📊 [VideoPlayer] Starting HLS background buffer monitoring");
  
  // 10秒ごとにバッファ状態をチェック（メインスレッドで実行）
  __weak typeof(self) weakSelf = self;
  _bufferMonitoringTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                           repeats:YES
                                                             block:^(NSTimer * _Nonnull timer) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || !strongSelf.player.currentItem || strongSelf->_disposed) {
      [timer invalidate];
      return;
    }
        
    AVPlayerItem *currentItem = strongSelf.player.currentItem;
        
        // バッファ状態のログ出力
        NSArray *loadedTimeRanges = currentItem.loadedTimeRanges;
        CMTime currentTime = self.player.currentTime;
        Float64 bufferDuration = 0.0;  // バッファ時間を事前に定義
        
        if (loadedTimeRanges.count > 0) {
          NSValue *timeRangeValue = loadedTimeRanges.firstObject;
          CMTimeRange timeRange = timeRangeValue.CMTimeRangeValue;
          CMTime bufferEnd = CMTimeAdd(timeRange.start, timeRange.duration);
          bufferDuration = CMTimeGetSeconds(CMTimeSubtract(bufferEnd, currentTime));
          
          NSLog(@"📊 [VideoPlayer] HLS Buffer status: %.1fs ahead, isLikelyToKeepUp: %@", 
                bufferDuration, currentItem.isPlaybackLikelyToKeepUp ? @"YES" : @"NO");
          
          // バッファが不足している場合の対策
          if (bufferDuration < 5.0 && !currentItem.isPlaybackLikelyToKeepUp) {
            NSLog(@"⚠️ [VideoPlayer] Low buffer detected, increasing buffer duration");
            currentItem.preferredForwardBufferDuration = MAX(currentItem.preferredForwardBufferDuration, 30.0);
          }
        }
        
        // 再生状態チェックは高頻度監視メソッド（1秒間隔）に移行したため、
        // ここではバッファ監視のみを行う
        // 参照: startBackgroundPlaybackMonitoring
        
        // 動画HLSの特別処理：低バッファ時の品質調整
        AVAsset *currentAsset = currentItem.asset;
        NSArray *videoTracks = [currentAsset tracksWithMediaType:AVMediaTypeVideo];
        if (videoTracks.count > 0 && bufferDuration < 8.0) {
          // 動画HLSでバッファが少ない場合、一時的に品質を下げる
          if ([currentItem respondsToSelector:@selector(setPreferredPeakBitRate:)]) {
            NSLog(@"📉 [VideoPlayer] Low buffer for video HLS, reducing bitrate temporarily");
            currentItem.preferredPeakBitRate = 1000000;  // 1Mbpsに一時的に制限
          }
        } else if (videoTracks.count > 0 && bufferDuration > 15.0) {
          // バッファが十分ある場合は品質を戻す
          if ([currentItem respondsToSelector:@selector(setPreferredPeakBitRate:)]) {
            currentItem.preferredPeakBitRate = 2000000;  // 2Mbpsに戻す
          }
        }
  }];
}

- (void)ensureHTTPHeadersForBackgroundPlayback {
  // For HLS streams, ensure HTTP headers (including cookies) are maintained
  // during background playback by updating the asset's resource loader
  if (_httpHeaders && [_httpHeaders count] > 0) {
    AVPlayerItem *currentItem = _player.currentItem;
    if (currentItem && [currentItem.asset isKindOfClass:[AVURLAsset class]]) {
      AVURLAsset *urlAsset = (AVURLAsset *)currentItem.asset;
      
      // Log current headers for debugging
      NSLog(@"🍪 [VideoPlayer] Maintaining HTTP headers for background playback:");
      for (NSString *key in _httpHeaders) {
        NSLog(@"  %@: %@", key, _httpHeaders[key]);
      }
      
      // Resource loader delegate will handle header injection for HLS segments
      // This ensures all TS file requests include the required headers
    }
  }
}
#endif

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
  // This method is called for each HLS request (m3u8 playlists and .ts segments)
  NSURLRequest *request = loadingRequest.request;
  NSURL *url = request.URL;
  
  // Only handle HTTP/HTTPS requests with custom headers
  if (![url.scheme.lowercaseString hasPrefix:@"http"] || !_httpHeaders || [_httpHeaders count] == 0) {
    return NO; // Let AVFoundation handle this request normally
  }
  
  NSLog(@"🎯 [HLS-HEADER-INJECTION] HLSリクエストを傍受してヘッダー注入: %@", url.lastPathComponent);
  
  // Create a mutable copy of the request to add headers
  NSMutableURLRequest *mutableRequest = [request mutableCopy];
  
  // Add stored HTTP headers to the request
  NSLog(@"🔐 [HLS-HEADER-INJECTION] HLSリクエスト(%@)にカスタムヘッダーを追加:", url.lastPathComponent);
  for (NSString *key in _httpHeaders) {
    [mutableRequest setValue:_httpHeaders[key] forHTTPHeaderField:key];
    NSLog(@"  %@: %@", key, _httpHeaders[key]);
  }
  
  // Create a data task to load the resource with custom headers
  NSURLSessionDataTask *dataTask = [[NSURLSession sharedSession] dataTaskWithRequest:mutableRequest completionHandler:^(NSData * _Nullable data, NSURLResponse * _Nullable response, NSError * _Nullable error) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (error) {
        NSLog(@"❌ [HLS-HEADER-INJECTION] HLSリクエスト失敗: %@ - %@", url.lastPathComponent, error.localizedDescription);
        [loadingRequest finishLoadingWithError:error];
      } else if (data && response) {
        NSLog(@"✅ [HLS-HEADER-INJECTION] カスタムヘッダー付きHLSリクエスト成功: %@ (%lu bytes)", url.lastPathComponent, (unsigned long)data.length);
        
        // Provide the response and data to AVFoundation
        loadingRequest.response = response;
        [loadingRequest.dataRequest respondWithData:data];
        [loadingRequest finishLoading];
      } else {
        NSLog(@"⚠️ [HLS-HEADER-INJECTION] HLSリクエストでデータが返されませんでした: %@", url.lastPathComponent);
        NSError *noDataError = [NSError errorWithDomain:@"VideoPlayerError" 
                                                   code:-1 
                                               userInfo:@{NSLocalizedDescriptionKey: @"No data received for HLS request"}];
        [loadingRequest finishLoadingWithError:noDataError];
      }
    });
  }];
  
  [dataTask resume];
  
  // Return YES to indicate we're handling this request
  return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
  NSLog(@"🚫 [HLS-HEADER-INJECTION] リソース読み込みリクエストがキャンセルされました: %@", loadingRequest.request.URL.lastPathComponent);
}

- (void)startBackgroundTaskRefreshTimer {
  // Stop any existing timer first
  [self stopBackgroundTaskRefreshTimer];
  
  __weak typeof(self) weakSelf = self;
  _backgroundTaskRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 // 20 seconds
                                                                 repeats:YES
                                                                   block:^(NSTimer * _Nonnull timer) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf && strongSelf->_backgroundTask != UIBackgroundTaskInvalid) {
      // Refresh the background task by ending and starting a new one
      NSLog(@"🔄 [VideoPlayer] Refreshing background task to prevent expiration");
      [strongSelf endBackgroundTask];
      [strongSelf startPersistentBackgroundTask];
    } else {
      // If no background task or self is deallocated, stop the timer
      [timer invalidate];
    }
  }];
  
  NSLog(@"⏰ [VideoPlayer] Background task refresh timer started (20s intervals)");
}

- (void)stopBackgroundTaskRefreshTimer {
  if (_backgroundTaskRefreshTimer) {
    [_backgroundTaskRefreshTimer invalidate];
    _backgroundTaskRefreshTimer = nil;
    NSLog(@"⏰ [VideoPlayer] Background task refresh timer stopped");
  }
}

@end
