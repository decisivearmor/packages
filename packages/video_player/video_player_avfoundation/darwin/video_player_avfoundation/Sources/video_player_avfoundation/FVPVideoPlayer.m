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
}

@synthesize isInPictureInPicture = _isInPictureInPicture;

- (instancetype)init {
  self = [super init];
  if (self) {
#if TARGET_OS_IOS
    _backgroundTask = UIBackgroundTaskInvalid;
#endif
    NSLog(@"🚀 [HLS-HEADER-INJECTION] FVPVideoPlayer初期化完了 - カスタムビルド版使用中");
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
    if (@available(iOS 10.0, *)) {
      _player.automaticallyWaitsToMinimizeStalling = NO;
      NSLog(@"🚀 [VideoPlayer] Disabled automatic stalling for continuous background playback");
    }
    
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
  
  // Setup Remote Command Center immediately
  NSLog(@"🎮 [VideoPlayer] Setting up Remote Command Center at %@", [NSDate date]);
  [self setupRemoteCommandCenter];
  
#if TARGET_OS_IOS
  // Start background task immediately to ensure continuous playback capability
  NSLog(@"🔄 [VideoPlayer] Starting persistent background task at %@", [NSDate date]);
  [self startPersistentBackgroundTask];
  
  // Register for app lifecycle notifications
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillResignActive:)
                                              name:UIApplicationWillResignActiveNotification
                                            object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationDidBecomeActive:)
                                              name:UIApplicationDidBecomeActiveNotification
                                            object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationDidEnterBackground:)
                                              name:UIApplicationDidEnterBackgroundNotification
                                            object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillEnterForeground:)
                                              name:UIApplicationWillEnterForegroundNotification
                                            object:nil];
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
          NSLog(@"PiP is now possible, starting PiP");
          [_pipController removeObserver:self forKeyPath:@"isPictureInPicturePossible"];
          [_pipController startPictureInPicture];
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
  }
}

- (void)play {
  _isPlaying = YES;
  [self updatePlayingState];
  [self updateNowPlayingInfo];
}

- (void)pause {
  _isPlaying = NO;
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

- (void)setPictureInPictureEnabled:(BOOL)enabled {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    NSLog(@"setPictureInPictureEnabled called with enabled: %@", enabled ? @"YES" : @"NO");
    
    if (enabled && !_pipController) {
      // Get player layer from subclass or create new one
      AVPlayerLayer *layerForPiP = [self playerLayerForPiP];
      if (!layerForPiP) {
        NSLog(@"Creating new AVPlayerLayer for PiP");
        layerForPiP = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer = layerForPiP;
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
          NSLog(@"PiP not possible yet, waiting for player to be ready...");
          // Observe the isPictureInPicturePossible property
          [_pipController addObserver:self 
                           forKeyPath:@"isPictureInPicturePossible" 
                              options:NSKeyValueObservingOptionNew 
                              context:nil];
        } else {
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
  
  // Ensure remote command center is active
  [self setupRemoteCommandCenter];
  [self updateNowPlayingInfo];
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了時の処理
  NSLog(@"PiP will stop");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了完了時の処理
  NSLog(@"PiP did stop");
  _isInPictureInPicture = NO;
  // Resume display link after PiP
  [self updatePlayingState];
  if (_eventSink != nil) {
    _eventSink(@{@"event" : @"pipStatusUpdate", @"isInPictureInPicture" : @NO});
  }
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
  // PiP開始失敗時の処理
  NSLog(@"PiP failed to start: %@", error);
  NSLog(@"Error domain: %@", error.domain);
  NSLog(@"Error code: %ld", (long)error.code);
  NSLog(@"Error userInfo: %@", error.userInfo);
}

- (nullable AVPlayerLayer *)playerLayerForPiP {
  // Default implementation returns the instance variable
  // Subclasses should override this to provide their own layer
  return _playerLayer;
}

#pragma mark - Application Lifecycle

#if TARGET_OS_IOS
- (void)applicationWillResignActive:(NSNotification *)notification {
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
      
      // 動画HLS判定
      NSArray *videoTracks = [asset tracksWithMediaType:AVMediaTypeVideo];
      BOOL hasVideoTracks = (videoTracks.count > 0);
      
      NSLog(@"🎬 [VideoPlayer] HLS stream type: %@", hasVideoTracks ? @"Video HLS" : @"Audio-only HLS");
      
      if (hasVideoTracks) {
        // 動画HLS専用の最適化
        NSLog(@"🎬 [VideoPlayer] Applying video HLS background optimization");
        
        // 動画HLS用のバッファリング設定（大幅強化）
        item.preferredForwardBufferDuration = 25.0;  // 動画は25秒バッファ
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
        
        // バックグラウンド動画再生専用設定
        if ([item respondsToSelector:@selector(setAutomaticallyWaitsToMinimizeStalling:)]) {
          item.automaticallyWaitsToMinimizeStalling = NO;  // 積極的バッファリング
        }
        
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
        
        // 動画解像度のバックグラウンド最適化
        AVAssetTrack *videoTrack = videoTracks.firstObject;
        if (videoTrack) {
          CGSize videoSize = videoTrack.naturalSize;
          NSLog(@"🎬 [VideoPlayer] Video track info: %.0fx%.0f, %.1ffps", 
                videoSize.width, videoSize.height, videoTrack.nominalFrameRate);
        }
        
      } else {
        // audio-only HLS処理
        NSLog(@"🎵 [VideoPlayer] Applying audio-only HLS background optimization");
        item.preferredForwardBufferDuration = 30.0;  // audio-onlyは30秒
        
        if ([item respondsToSelector:@selector(setPreferredPeakBitRate:)]) {
          item.preferredPeakBitRate = 0;  // 品質制限なし
        }
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
  
  // Keep player playing if it was playing
  if (_isPlaying && _player.rate == 0) {
    NSLog(@"🔄 [VideoPlayer] Restarting playback for background");
    [_player play];
  }
  
  // Start continuous buffer monitoring for HLS
  [self startBackgroundBufferMonitoring];
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  NSLog(@"📱 [VideoPlayer] Application did become active - バックグラウンド維持により通知センター継続中");
  
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
}

- (void)startPersistentBackgroundTask {
  // End any existing task first
  [self endBackgroundTask];
  
  __weak typeof(self) weakSelf = self;
  _backgroundTask = [[UIApplication sharedApplication] beginBackgroundTaskWithName:@"VideoPlayerBackground" 
                                                                 expirationHandler:^{
    // If task is about to expire, restart it
    dispatch_async(dispatch_get_main_queue(), ^{
      // Before ending, ensure audio session and notification center are maintained
      [weakSelf maintainAudioSessionAndNotificationCenter];
      [weakSelf endBackgroundTask];
      // Only restart if player is still active
      if (weakSelf && weakSelf.player) {
        [weakSelf startPersistentBackgroundTask];
      }
    });
  }];
  
  // Immediately ensure audio session is active for the background task
  [self maintainAudioSessionAndNotificationCenter];
  
  NSLog(@"🔄 Started persistent background task with audio session maintenance: %lu", (unsigned long)_backgroundTask);
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
  NSLog(@"📱 Application did enter background - 動画HLS専用バックグラウンド処理開始");
  
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
        
        // 動画HLSの場合、PiPが利用可能ならPiPを推奨（自動開始は設定次第）
        #if TARGET_OS_IOS
        if (@available(iOS 9.0, *)) {
          if (_pipController && [AVPictureInPictureController isPictureInPictureSupported]) {
            if (!_pipController.isPictureInPictureActive) {
              NSLog(@"📺 [VideoPlayer] PiP available for video HLS background playback");
              // 自動PiP開始は設定で制御可能 - ここではログのみ
            }
          }
        }
        #endif
        
        // 動画HLS用バックグラウンド最適化
        AVPlayerItem *item = _player.currentItem;
        item.preferredForwardBufferDuration = 30.0;  // バックグラウンドでは更に長く
        
        // 動画再生の継続確保
        if (_isPlaying && _player.rate == 0) {
          NSLog(@"🎬 [VideoPlayer] Ensuring video HLS continues in background");
          [_player play];
        }
      }
    }
  }
  
  // 重要：バックグラウンドでオーディオセッションと通知センターを継続維持
  [self maintainAudioSessionAndNotificationCenter];
  
  NSLog(@"✅ [VideoPlayer] Background transition completed with video HLS optimization");
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
  NSLog(@"Application will enter foreground");
  
  // Refresh Remote Command Center
  [self setupRemoteCommandCenter];
  [self updateNowPlayingInfo];
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

- (void)setupAudioSessionForBackgroundPlayback {
#if TARGET_OS_IOS
  NSError *error = nil;
  AVAudioSession *audioSession = [AVAudioSession sharedInstance];
  
  NSLog(@"🔧 [VideoPlayer] Forcing audio session setup for reliable HLS background playback");
  
  // HLS背景再生用の最適化されたオーディオセッション設定
  // 1. カテゴリの強制設定（HLS再生継続に重要）
  BOOL categorySuccess = [audioSession setCategory:AVAudioSessionCategoryPlayback 
                                        withOptions:AVAudioSessionCategoryOptionAllowBluetooth | 
                                                   AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                                   AVAudioSessionCategoryOptionAllowAirPlay |
                                                   AVAudioSessionCategoryOptionMixWithOthers  // 他のアプリとの共存
                                              error:&error];
  
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
  
  // 2. モードの設定（オプション）
  if ([audioSession respondsToSelector:@selector(setMode:error:)]) {
    [audioSession setMode:AVAudioSessionModeDefault error:&error];
    if (error) {
      NSLog(@"⚠️ [VideoPlayer] Failed to set audio session mode: %@", error);
      error = nil;  // エラーをリセット
    }
  }
  
  // 3. 強制的にオーディオセッションをアクティベート
  BOOL activateSuccess = [audioSession setActive:YES 
                                      withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation 
                                            error:&error];
  if (!activateSuccess || error) {
    NSLog(@"⚠️ [VideoPlayer] Failed to force activate audio session: %@", error);
    
    // 代替手段：通常のアクティベーションを試行
    activateSuccess = [audioSession setActive:YES error:&error];
    if (activateSuccess && !error) {
      NSLog(@"✅ [VideoPlayer] Alternative audio session activation successful");
    }
  } else {
    NSLog(@"✅ [VideoPlayer] Audio session forcefully activated for HLS background playback");
  }
  
  // 4. 品質設定の最適化
  if ([audioSession respondsToSelector:@selector(setPreferredSampleRate:error:)]) {
    [audioSession setPreferredSampleRate:44100.0 error:&error];
    if (error) {
      NSLog(@"⚠️ [VideoPlayer] Failed to set preferred sample rate: %@", error);
      error = nil;
    }
  }
  
  // 最終確認とログ出力
  NSLog(@"📊 [VideoPlayer] HLS background audio session state:");
  NSLog(@"  Category: %@", audioSession.category);
  NSLog(@"  Mode: %@", audioSession.mode);
  NSLog(@"  Active: %@", audioSession.isOtherAudioPlaying ? @"YES" : @"NO");
  NSLog(@"  Sample Rate: %.1f Hz", audioSession.sampleRate);
#endif
}

#pragma mark - Remote Command Center

- (void)setupRemoteCommandCenter {
#if TARGET_OS_IOS
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  
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
      [strongSelf pause];
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
        [strongSelf pause];
      } else {
        [strongSelf play];
      }
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
  // Change playback position command (seek)
  [commandCenter.changePlaybackPositionCommand setEnabled:YES];
  [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (strongSelf) {
      MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
      [strongSelf seekTo:(int64_t)(positionEvent.positionTime * 1000) completionHandler:nil];
      return MPRemoteCommandHandlerStatusSuccess;
    }
    return MPRemoteCommandHandlerStatusCommandFailed;
  }];
  
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
  
  // Media type specific optimizations
  nowPlayingInfo[MPNowPlayingInfoPropertyMediaType] = @(MPNowPlayingInfoMediaTypeAudio);
  
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
  
  NSLog(@"🎵 [VideoPlayer] Now Playing Info updated - Duration: %.1fs, Position: %.1fs", duration, currentTime);
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
  
  NSLog(@"📊 [VideoPlayer] Starting HLS background buffer monitoring");
  
  // 10秒ごとにバッファ状態をチェック
  dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
    NSTimer *bufferTimer = [NSTimer scheduledTimerWithTimeInterval:10.0
                                                           repeats:YES
                                                             block:^(NSTimer * _Nonnull timer) {
      dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.player.currentItem || self->_disposed) {
          [timer invalidate];
          return;
        }
        
        AVPlayerItem *currentItem = self.player.currentItem;
        
        // バッファ状態のログ出力
        NSArray *loadedTimeRanges = currentItem.loadedTimeRanges;
        CMTime currentTime = self.player.currentTime;
        
        if (loadedTimeRanges.count > 0) {
          NSValue *timeRangeValue = loadedTimeRanges.firstObject;
          CMTimeRange timeRange = timeRangeValue.CMTimeRangeValue;
          CMTime bufferEnd = CMTimeAdd(timeRange.start, timeRange.duration);
          Float64 bufferDuration = CMTimeGetSeconds(CMTimeSubtract(bufferEnd, currentTime));
          
          NSLog(@"📊 [VideoPlayer] HLS Buffer status: %.1fs ahead, isLikelyToKeepUp: %@", 
                bufferDuration, currentItem.isPlaybackLikelyToKeepUp ? @"YES" : @"NO");
          
          // バッファが不足している場合の対策
          if (bufferDuration < 5.0 && !currentItem.isPlaybackLikelyToKeepUp) {
            NSLog(@"⚠️ [VideoPlayer] Low buffer detected, increasing buffer duration");
            currentItem.preferredForwardBufferDuration = MAX(currentItem.preferredForwardBufferDuration, 30.0);
          }
        }
        
        // プレイヤーが予期せず停止している場合の復旧
        if (self->_isPlaying && self.player.rate == 0 && currentItem.isPlaybackLikelyToKeepUp) {
          NSLog(@"🔄 [VideoPlayer] Detected unexpected pause, restarting HLS playback");
          [self.player play];
        }
        
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
      });
    }];
    
    // タイマーをランループに追加
    [[NSRunLoop currentRunLoop] addTimer:bufferTimer forMode:NSDefaultRunLoopMode];
    [[NSRunLoop currentRunLoop] run];
  });
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

@end
