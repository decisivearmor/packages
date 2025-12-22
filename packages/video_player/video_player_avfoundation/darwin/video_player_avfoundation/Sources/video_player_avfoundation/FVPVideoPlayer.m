// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "./include/video_player_avfoundation/FVPVideoPlayer.h"
#import "./include/video_player_avfoundation/FVPVideoPlayer_Internal.h"

#import <GLKit/GLKit.h>

#if TARGET_OS_IOS
#import <MediaPlayer/MediaPlayer.h>
#import <AVFoundation/AVAudioSession.h>
#endif

#import "./include/video_player_avfoundation/AVAssetTrackUtils.h"

static void *timeRangeContext = &timeRangeContext;
static void *statusContext = &statusContext;
static void *playbackLikelyToKeepUpContext = &playbackLikelyToKeepUpContext;
static void *rateContext = &rateContext;

/// Registers KVO observers on 'object' for each entry in 'observations', which must be a
/// dictionary mapping KVO keys to NSValue-wrapped context pointers.
///
/// This does not call any methods on 'observer', so is safe to call from 'observer's init.
static void FVPRegisterKeyValueObservers(NSObject *observer,
                                         NSDictionary<NSString *, NSValue *> *observations,
                                         NSObject *target) {
  // It is important not to use NSKeyValueObservingOptionInitial here, because that will cause
  // synchronous calls to 'observer', violating the requirement that this method does not call its
  // methods. If there are use cases for specific pieces of initial state, those should be handled
  // explicitly by the caller, rather than by adding initial-state KVO notifications here.
  for (NSString *key in observations) {
    [target addObserver:observer
             forKeyPath:key
                options:NSKeyValueObservingOptionNew
                context:observations[key].pointerValue];
  }
}

/// Registers KVO observers on 'object' for each entry in 'observations', which must be a
/// dictionary mapping KVO keys to NSValue-wrapped context pointers.
///
/// This should only be called to balance calls to FVPRegisterKeyValueObservers, as it is an
/// error to try to remove observers that are not currently set.
///
/// This does not call any methods on 'observer', so is safe to call from 'observer's dealloc.
static void FVPRemoveKeyValueObservers(NSObject *observer,
                                       NSDictionary<NSString *, NSValue *> *observations,
                                       NSObject *target) {
  for (NSString *key in observations) {
    [target removeObserver:observer forKeyPath:key];
  }
}

/// Returns a mapping of KVO keys to NSValue-wrapped observer context pointers for observations that
/// should be set for AVPlayer instances.
static NSDictionary<NSString *, NSValue *> *FVPGetPlayerObservations(void) {
  return @{
    @"rate" : [NSValue valueWithPointer:rateContext],
  };
}

/// Returns a mapping of KVO keys to NSValue-wrapped observer context pointers for observations that
/// should be set for AVPlayerItem instances.
static NSDictionary<NSString *, NSValue *> *FVPGetPlayerItemObservations(void) {
  return @{
    @"loadedTimeRanges" : [NSValue valueWithPointer:timeRangeContext],
    @"status" : [NSValue valueWithPointer:statusContext],
    @"playbackLikelyToKeepUp" : [NSValue valueWithPointer:playbackLikelyToKeepUpContext],
  };
}

@implementation FVPVideoPlayer {
  // Whether or not player and player item listeners have ever been registered.
  BOOL _listenersRegistered;
  // Token for periodic time observer (for background position updates).
  id _timeObserverToken;
#if TARGET_OS_IOS
  // Whether RemoteCommandCenter has been configured.
  BOOL _isRemoteCommandCenterConfigured;
  // Current metadata for Now Playing Info.
  NSDictionary *_currentMetadata;
  // Whether this is a live stream.
  BOOL _isLiveStream;
  // Whether app lifecycle notifications have been registered.
  BOOL _lifecycleNotificationsRegistered;
  // Whether video was playing before going to background.
  BOOL _wasPlayingBeforeBackground;
#endif
}

- (instancetype)initWithPlayerItem:(AVPlayerItem *)item
                         avFactory:(id<FVPAVFactory>)avFactory
                      viewProvider:(NSObject<FVPViewProvider> *)viewProvider {
  self = [super init];
  NSAssert(self, @"super init cannot be nil");

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

#if TARGET_OS_IOS
  // Allow background playback - prevent display sleep from stopping audio
  if (@available(iOS 12.0, *)) {
    _player.preventsDisplaySleepDuringVideoPlayback = NO;
  }

  // Disable automatic stalling to allow background playback to continue
  if (@available(iOS 10.0, *)) {
    _player.automaticallyWaitsToMinimizeStalling = NO;
  }

  // NOTE: Audio session is NOT configured here to avoid showing RemoteCommandCenter at app startup.
  // Audio session will be configured in setupAudioSessionForPlayback when playback actually starts.
  // This prevents the audio session from being activated before the user initiates playback.
#endif

  // Configure output.
  NSDictionary *pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [avFactory videoOutputWithPixelBufferAttributes:pixBuffAttributes];

  [asset loadValuesAsynchronouslyForKeys:@[ @"tracks" ] completionHandler:assetCompletionHandler];

  return self;
}

- (void)dealloc {
  if (_listenersRegistered && !_disposed) {
    // If dispose was never called for some reason, remove observers to prevent crashes.
    FVPRemoveKeyValueObservers(self, FVPGetPlayerItemObservations(), _player.currentItem);
    FVPRemoveKeyValueObservers(self, FVPGetPlayerObservations(), _player);
  }
}

- (void)disposeWithError:(FlutterError *_Nullable *_Nonnull)error {
  // In some hot restart scenarios, dispose can be called twice, so no-op after the first time.
  if (_disposed) {
    return;
  }
  _disposed = YES;

#if TARGET_OS_IOS
  // NOTE: Do NOT clean up remote command center here.
  // This allows the RemoteCommandCenter to persist between track changes.
  // The new player will take over the command handlers.
  // RemoteCommandCenter should only be cleaned up when explicitly requested
  // via clearNowPlayingMetadata.

  // Remove lifecycle notification observers
  if (_lifecycleNotificationsRegistered) {
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillResignActiveNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidEnterBackgroundNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationWillEnterForegroundNotification
                                                  object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self
                                                    name:UIApplicationDidBecomeActiveNotification
                                                  object:nil];
    _lifecycleNotificationsRegistered = NO;
  }
#endif

  if (_listenersRegistered) {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    FVPRemoveKeyValueObservers(self, FVPGetPlayerItemObservations(), self.player.currentItem);
    FVPRemoveKeyValueObservers(self, FVPGetPlayerObservations(), self.player);

    // Remove periodic time observer
    if (_timeObserverToken) {
      [self.player removeTimeObserver:_timeObserverToken];
      _timeObserverToken = nil;
    }
  }

  [self.player replaceCurrentItemWithPlayerItem:nil];

  if (_onDisposed) {
    _onDisposed();
  }
  [self.eventListener videoPlayerWasDisposed];
}

- (void)setEventListener:(NSObject<FVPVideoEventListener> *)eventListener {
  _eventListener = eventListener;
  // The first time an event listener is set, set up video event listeners to relay status changes
  // changes to the event listener.
  if (eventListener && !_listenersRegistered) {
    AVPlayerItem *item = self.player.currentItem;
    // If the item is already ready to play, ensure that the intialized event is sent first.
    [self reportStatusForPlayerItem:item];
    // Set up all necessary observers to report video events.
    FVPRegisterKeyValueObservers(self, FVPGetPlayerItemObservations(), item);
    FVPRegisterKeyValueObservers(self, FVPGetPlayerObservations(), _player);
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(itemDidPlayToEndTime:)
                                                 name:AVPlayerItemDidPlayToEndTimeNotification
                                               object:item];

    // Add periodic time observer for background position updates.
    // This allows Dart side to receive position updates even when app is in background.
    __weak typeof(self) weakSelf = self;
    CMTime interval = CMTimeMake(1, 2); // 500ms interval
    _timeObserverToken = [_player addPeriodicTimeObserverForInterval:interval
                                                               queue:dispatch_get_main_queue()
                                                          usingBlock:^(CMTime time) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      if (!strongSelf || strongSelf->_disposed) return;

      // Only send position updates if the listener supports it (optional method)
      if ([strongSelf.eventListener respondsToSelector:@selector(videoPlayerDidUpdatePosition:duration:isPlaying:)]) {
        int64_t position = FVPCMTimeToMillis(time);
        int64_t duration = strongSelf.duration;
        BOOL isPlaying = strongSelf->_isPlaying;
        [strongSelf.eventListener videoPlayerDidUpdatePosition:position duration:duration isPlaying:isPlaying];
      }
    }];

    _listenersRegistered = YES;
  }
}

- (void)itemDidPlayToEndTime:(NSNotification *)notification {
  if (_isLooping) {
    AVPlayerItem *p = [notification object];
    [p seekToTime:kCMTimeZero completionHandler:nil];
  } else {
    [self.eventListener videoPlayerDidComplete];
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
    NSMutableArray<NSArray<NSNumber *> *> *values = [[NSMutableArray alloc] init];
    for (NSValue *rangeValue in [object loadedTimeRanges]) {
      CMTimeRange range = [rangeValue CMTimeRangeValue];
      [values addObject:@[
        @(FVPCMTimeToMillis(range.start)),
        @(FVPCMTimeToMillis(range.duration)),
      ]];
    }
    [self.eventListener videoPlayerDidUpdateBufferRegions:values];
  } else if (context == statusContext) {
    AVPlayerItem *item = (AVPlayerItem *)object;
    [self reportStatusForPlayerItem:item];
  } else if (context == playbackLikelyToKeepUpContext) {
    [self updatePlayingState];
    if ([[_player currentItem] isPlaybackLikelyToKeepUp]) {
      [self.eventListener videoPlayerDidEndBuffering];
    } else {
      [self.eventListener videoPlayerDidStartBuffering];
    }
  } else if (context == rateContext) {
    // Important: Make sure to cast the object to AVPlayer when observing the rate property,
    // as it is not available in AVPlayerItem.
    AVPlayer *player = (AVPlayer *)object;
    NSLog(@"[VideoPlayer] Rate changed to: %f, isPlaying: %@", player.rate, _isPlaying ? @"YES" : @"NO");

    // If rate becomes 0 while we think we're playing, check the reason
    if (player.rate == 0 && _isPlaying) {
      NSLog(@"[VideoPlayer] WARNING: Playback stopped while isPlaying=YES");

#if TARGET_OS_IOS
      // Check if we're in background - if so, don't notify Dart to prevent UI state changes
      // But DON'T force restart - respect user actions like removing headphones
      UIApplicationState appState = [UIApplication sharedApplication].applicationState;
      if (appState == UIApplicationStateBackground) {
        NSLog(@"[VideoPlayer] Rate changed to 0 in background - not notifying Dart");
        // Don't notify Dart - but also don't force restart
        // This keeps the UI in "playing" state but respects the actual stop
        return;
      }
#endif
    }

    [self.eventListener videoPlayerDidSetPlaying:(player.rate > 0)];
  }
}

- (void)reportStatusForPlayerItem:(AVPlayerItem *)item {
  NSAssert(self.eventListener,
           @"reportStatusForPlayerItem was called when the event listener was not set.");
  switch (item.status) {
    case AVPlayerItemStatusFailed:
      [self sendFailedToLoadVideoEvent];
      break;
    case AVPlayerItemStatusUnknown:
      break;
    case AVPlayerItemStatusReadyToPlay:
      if (!_isInitialized) {
        [item addOutput:_videoOutput];
        [self reportInitialized];
        [self updatePlayingState];
      }
      break;
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
  [self.eventListener videoPlayerDidErrorWithMessage:message];
}

- (void)reportInitialized {
  AVPlayerItem *currentItem = self.player.currentItem;
  NSAssert(currentItem.status == AVPlayerItemStatusReadyToPlay,
           @"reportInitializedIfReadyToPlay was called when the item wasn't ready to play.");
  NSAssert(!_isInitialized, @"reportInitializedIfReadyToPlay should only be called once.");

  _isInitialized = YES;
  [self.eventListener videoPlayerDidInitializeWithDuration:self.duration
                                                      size:currentItem.presentationSize];
}

#pragma mark - FVPVideoPlayerInstanceApi

- (void)playWithError:(FlutterError *_Nullable *_Nonnull)error {
#if TARGET_OS_IOS
  // Set up audio session and remote command center on play
  // This ensures other apps' audio is not interrupted until playback actually starts
  [self setupAudioSessionForPlayback];
  [self setupRemoteCommandCenterIfNeeded];
  [self setupLifecycleNotificationsIfNeeded];
#endif
  _isPlaying = YES;
  [self updatePlayingState];
#if TARGET_OS_IOS
  [self updateNowPlayingInfo];
#endif
}

- (void)pauseWithError:(FlutterError *_Nullable *_Nonnull)error {
  _isPlaying = NO;
  [self updatePlayingState];
#if TARGET_OS_IOS
  [self updateNowPlayingInfo];
#endif
}

- (nullable NSNumber *)position:(FlutterError *_Nullable *_Nonnull)error {
  return @(FVPCMTimeToMillis([_player currentTime]));
}

- (void)seekTo:(NSInteger)position completion:(void (^)(FlutterError *_Nullable))completion {
  CMTime targetCMTime = CMTimeMake(position, 1000);
  CMTimeValue duration = _player.currentItem.asset.duration.value;
  // Without adding tolerance when seeking to duration,
  // seekToTime will never complete, and this call will hang.
  // see issue https://github.com/flutter/flutter/issues/124475.
  CMTime tolerance = position == duration ? CMTimeMake(1, 1000) : kCMTimeZero;
  [_player seekToTime:targetCMTime
        toleranceBefore:tolerance
         toleranceAfter:tolerance
      completionHandler:^(BOOL completed) {
        if (completion) {
          dispatch_async(dispatch_get_main_queue(), ^{
            completion(nil);
          });
        }
      }];
}

- (void)setLooping:(BOOL)looping error:(FlutterError *_Nullable *_Nonnull)error {
  _isLooping = looping;
}

- (void)setVolume:(double)volume error:(FlutterError *_Nullable *_Nonnull)error {
  _player.volume = (float)((volume < 0.0) ? 0.0 : ((volume > 1.0) ? 1.0 : volume));
}

- (void)setPlaybackSpeed:(double)speed error:(FlutterError *_Nullable *_Nonnull)error {
  _targetPlaybackSpeed = @(speed);
  [self updatePlayingState];
}

#pragma mark - Private

- (int64_t)duration {
  // Note: https://openradar.appspot.com/radar?id=4968600712511488
  // `[AVPlayerItem duration]` can be `kCMTimeIndefinite`,
  // use `[[AVPlayerItem asset] duration]` instead.
  return FVPCMTimeToMillis([[[_player currentItem] asset] duration]);
}

#if TARGET_OS_IOS
#pragma mark - Media Controls (RemoteCommandCenter / NowPlayingInfo)

- (void)setupAudioSessionForPlayback {
  NSError *error = nil;
  AVAudioSession *session = [AVAudioSession sharedInstance];

  // Set category to playback for background audio
  // Use AVAudioSessionModeDefault for better background compatibility
  [session setCategory:AVAudioSessionCategoryPlayback
                  mode:AVAudioSessionModeDefault
               options:0
                 error:&error];
  if (error) {
    NSLog(@"[VideoPlayer] Failed to set audio session category: %@", error);
    return;
  }

  // Activate the audio session
  [session setActive:YES error:&error];
  if (error) {
    NSLog(@"[VideoPlayer] Failed to activate audio session: %@", error);
  }
}

- (void)setupRemoteCommandCenterIfNeeded {
  if (_isRemoteCommandCenterConfigured) {
    return;
  }

  [self setupRemoteCommandCenter];
}

- (void)setupLifecycleNotificationsIfNeeded {
  if (_lifecycleNotificationsRegistered) {
    return;
  }

  // Register for willResignActive - fires BEFORE app goes to background
  // This is the key timing to ensure audio continues
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationWillResignActive:)
                                               name:UIApplicationWillResignActiveNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationDidEnterBackground:)
                                               name:UIApplicationDidEnterBackgroundNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationWillEnterForeground:)
                                               name:UIApplicationWillEnterForegroundNotification
                                             object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(applicationDidBecomeActive:)
                                               name:UIApplicationDidBecomeActiveNotification
                                             object:nil];

  // Register for audio session interruption (e.g., when another app starts playing)
  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleAudioSessionInterruption:)
                                               name:AVAudioSessionInterruptionNotification
                                             object:[AVAudioSession sharedInstance]];

  _lifecycleNotificationsRegistered = YES;
  NSLog(@"[VideoPlayer] Lifecycle notifications registered for background playback");
}

- (void)applicationWillResignActive:(NSNotification *)notification {
  // This fires BEFORE the app goes to background
  NSLog(@"[VideoPlayer] App will resign active, isPlaying: %@, rate: %f", _isPlaying ? @"YES" : @"NO", _player.rate);

  if (_isPlaying) {
    // Activate audio session before going to background
    NSError *error = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    [session setCategory:AVAudioSessionCategoryPlayback
                    mode:AVAudioSessionModeDefault
                 options:0
                   error:&error];
    [session setActive:YES error:&error];

    if (!error) {
      NSLog(@"[VideoPlayer] Audio session prepared for background (mode: Default)");
    }
    // Note: FVPNativeVideoView handles detaching player from layer for PlatformView mode
  }
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
  // Remember if we were playing to continue playback in background
  _wasPlayingBeforeBackground = _isPlaying;
  NSLog(@"[VideoPlayer] App entered background, isPlaying: %@, rate: %f", _isPlaying ? @"YES" : @"NO", _player.rate);

  if (_isPlaying) {
    // Double-check rate is maintained after entering background
    float targetRate = _targetPlaybackSpeed ? _targetPlaybackSpeed.floatValue : 1.0f;
    if (_player.rate == 0) {
      // Player was paused by system - restart it
      _player.rate = targetRate;
      NSLog(@"[VideoPlayer] Player rate was 0, restored to %f in background", targetRate);
    } else {
      NSLog(@"[VideoPlayer] Background playback continuing with rate: %f", _player.rate);
    }
  }
}

- (void)applicationWillEnterForeground:(NSNotification *)notification {
  NSLog(@"[VideoPlayer] App will enter foreground");
  // Video tracks are not disabled, so no need to re-enable
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  NSLog(@"[VideoPlayer] App became active, wasPlayingBeforeBackground: %@, isPlaying: %@, rate: %f",
        _wasPlayingBeforeBackground ? @"YES" : @"NO",
        _isPlaying ? @"YES" : @"NO",
        _player.rate);

  // Check if player was stopped by another app (e.g., audio session interruption)
  // If our flag says playing but player rate is 0, sync our state
  if (_isPlaying && _player.rate == 0) {
    NSLog(@"[VideoPlayer] Player was stopped externally, syncing state to paused");
    _isPlaying = NO;
  }

  // Only update playing state if we're actually playing
  if (_isPlaying) {
    [self updatePlayingState];
    [self updateNowPlayingInfo];
  }
}

- (void)handleAudioSessionInterruption:(NSNotification *)notification {
  NSDictionary *userInfo = notification.userInfo;
  AVAudioSessionInterruptionType interruptionType =
      [userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue];

  if (interruptionType == AVAudioSessionInterruptionTypeBegan) {
    // Another app started playing - our playback was interrupted
    NSLog(@"[VideoPlayer] Audio session interrupted (another app started playing)");
    if (_isPlaying) {
      _isPlaying = NO;
      // Don't call updatePlayingState here - the system already paused us
      // Just update our internal state and UI
      [self updateNowPlayingInfo];
    }
  } else if (interruptionType == AVAudioSessionInterruptionTypeEnded) {
    // Interruption ended - check if we should resume
    AVAudioSessionInterruptionOptions options =
        [userInfo[AVAudioSessionInterruptionOptionKey] unsignedIntegerValue];
    NSLog(@"[VideoPlayer] Audio session interruption ended, shouldResume: %@",
          (options & AVAudioSessionInterruptionOptionShouldResume) ? @"YES" : @"NO");
    // Don't auto-resume - let the user decide
    // If they want to resume, they'll tap play in our app or RemoteCommandCenter
  }
}

- (void)setupRemoteCommandCenter {
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];

  // Remove ALL existing handlers (from any player instance) before adding new ones.
  // This ensures clean takeover when switching between tracks.
  // Using removeTarget:nil removes handlers from all targets.
  [commandCenter.playCommand removeTarget:nil];
  [commandCenter.pauseCommand removeTarget:nil];
  [commandCenter.togglePlayPauseCommand removeTarget:nil];
  [commandCenter.changePlaybackPositionCommand removeTarget:nil];
  [commandCenter.nextTrackCommand removeTarget:nil];
  [commandCenter.previousTrackCommand removeTarget:nil];

  // Use target-action pattern instead of blocks for proper removeTarget:self support
  commandCenter.playCommand.enabled = YES;
  [commandCenter.playCommand addTarget:self action:@selector(handlePlayCommand:)];

  commandCenter.pauseCommand.enabled = YES;
  [commandCenter.pauseCommand addTarget:self action:@selector(handlePauseCommand:)];

  commandCenter.togglePlayPauseCommand.enabled = YES;
  [commandCenter.togglePlayPauseCommand addTarget:self action:@selector(handleTogglePlayPauseCommand:)];

  if (!_isLiveStream) {
    commandCenter.changePlaybackPositionCommand.enabled = YES;
    [commandCenter.changePlaybackPositionCommand addTarget:self action:@selector(handleChangePlaybackPositionCommand:)];
  } else {
    commandCenter.changePlaybackPositionCommand.enabled = NO;
  }

  commandCenter.nextTrackCommand.enabled = YES;
  [commandCenter.nextTrackCommand addTarget:self action:@selector(handleNextTrackCommand:)];

  commandCenter.previousTrackCommand.enabled = YES;
  [commandCenter.previousTrackCommand addTarget:self action:@selector(handlePreviousTrackCommand:)];

  _isRemoteCommandCenterConfigured = YES;
  NSLog(@"[VideoPlayer] Remote Command Center configured with target-action pattern");
}

#pragma mark - Remote Command Handlers

- (MPRemoteCommandHandlerStatus)handlePlayCommand:(MPRemoteCommandEvent *)event {
  NSLog(@"[VideoPlayer] RemoteCommand: PLAY received, isPlaying=%@", _isPlaying ? @"YES" : @"NO");
  if (!_disposed) {
    _isPlaying = YES;
    [self updatePlayingState];
    [self updateNowPlayingInfo];
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePauseCommand:(MPRemoteCommandEvent *)event {
  NSLog(@"[VideoPlayer] RemoteCommand: PAUSE received, isPlaying=%@", _isPlaying ? @"YES" : @"NO");
  if (!_disposed) {
    _isPlaying = NO;
    [self updatePlayingState];
    [self updateNowPlayingInfo];
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleTogglePlayPauseCommand:(MPRemoteCommandEvent *)event {
  NSLog(@"[VideoPlayer] RemoteCommand: TOGGLE received, isPlaying=%@", _isPlaying ? @"YES" : @"NO");
  if (!_disposed) {
    _isPlaying = !_isPlaying;
    [self updatePlayingState];
    [self updateNowPlayingInfo];
    NSLog(@"[VideoPlayer] RemoteCommand: TOGGLE completed, isPlaying=%@", _isPlaying ? @"YES" : @"NO");
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleChangePlaybackPositionCommand:(MPRemoteCommandEvent *)event {
  if (!_disposed) {
    MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
    CMTime targetTime = CMTimeMakeWithSeconds(positionEvent.positionTime, NSEC_PER_SEC);
    NSLog(@"[VideoPlayer] RemoteCommand: SEEK to %.2f seconds", positionEvent.positionTime);

    // Update NowPlayingInfo with target position immediately for responsive UI
    [self updateNowPlayingInfoWithElapsedTime:positionEvent.positionTime];

    // Seek to the target time with completion handler
    __weak typeof(self) weakSelf = self;
    [_player seekToTime:targetTime
        toleranceBefore:kCMTimeZero
         toleranceAfter:kCMTimeZero
      completionHandler:^(BOOL finished) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (strongSelf && !strongSelf->_disposed && finished) {
          dispatch_async(dispatch_get_main_queue(), ^{
            // Update again with actual position after seek completes
            [strongSelf updateNowPlayingInfo];
          });
        }
      }];
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handleNextTrackCommand:(MPRemoteCommandEvent *)event {
  NSLog(@"[VideoPlayer] RemoteCommand: NEXT received");
  if (!_disposed && self.eventListener) {
    [self.eventListener videoPlayerDidRequestNextTrack];
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (MPRemoteCommandHandlerStatus)handlePreviousTrackCommand:(MPRemoteCommandEvent *)event {
  NSLog(@"[VideoPlayer] RemoteCommand: PREVIOUS received");
  if (!_disposed && self.eventListener) {
    [self.eventListener videoPlayerDidRequestPreviousTrack];
  }
  return MPRemoteCommandHandlerStatusSuccess;
}

- (void)cleanupRemoteCommandCenter {
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];

  // Remove ALL command targets (from any player instance)
  [commandCenter.playCommand removeTarget:nil];
  [commandCenter.pauseCommand removeTarget:nil];
  [commandCenter.togglePlayPauseCommand removeTarget:nil];
  [commandCenter.changePlaybackPositionCommand removeTarget:nil];
  [commandCenter.nextTrackCommand removeTarget:nil];
  [commandCenter.previousTrackCommand removeTarget:nil];

  // Disable commands
  commandCenter.playCommand.enabled = NO;
  commandCenter.pauseCommand.enabled = NO;
  commandCenter.togglePlayPauseCommand.enabled = NO;
  commandCenter.changePlaybackPositionCommand.enabled = NO;
  commandCenter.nextTrackCommand.enabled = NO;
  commandCenter.previousTrackCommand.enabled = NO;

  // Clear Now Playing Info
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nil];

  // Deactivate audio session to allow other apps to resume
  NSError *error = nil;
  [[AVAudioSession sharedInstance] setActive:NO
                                 withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                                       error:&error];
  if (error) {
    NSLog(@"[VideoPlayer] Failed to deactivate audio session: %@", error);
  }

  _isRemoteCommandCenterConfigured = NO;
  _currentMetadata = nil;
  NSLog(@"[VideoPlayer] Remote Command Center cleaned up");
}

- (void)updateNowPlayingInfo {
  Float64 currentTime = CMTimeGetSeconds([_player currentTime]);
  [self updateNowPlayingInfoWithElapsedTime:currentTime];
}

- (void)updateNowPlayingInfoWithElapsedTime:(Float64)elapsedTime {
  NSMutableDictionary *nowPlayingInfo = [NSMutableDictionary dictionary];

  // Duration
  Float64 duration = CMTimeGetSeconds([[[_player currentItem] asset] duration]);
  if (!isnan(duration) && duration > 0 && !_isLiveStream) {
    nowPlayingInfo[MPMediaItemPropertyPlaybackDuration] = @(duration);
  }

  // Current time - use provided elapsed time
  if (!isnan(elapsedTime) && !_isLiveStream) {
    nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(elapsedTime);
  }

  // Playback rate
  nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] = @(_isPlaying ? _player.rate : 0.0);

  // Live stream flag
  if (_isLiveStream) {
    nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream] = @YES;
  }

  // Apply custom metadata if set
  if (_currentMetadata) {
    [nowPlayingInfo addEntriesFromDictionary:_currentMetadata];
  } else {
    // Default title
    nowPlayingInfo[MPMediaItemPropertyTitle] = @"--";
  }

  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
}

- (void)setNowPlayingMetadataWithTitle:(nullable NSString *)title
                                artist:(nullable NSString *)artist
                                 album:(nullable NSString *)album
                            artworkUrl:(nullable NSString *)artworkUrl
                          isLiveStream:(BOOL)isLiveStream {
  _isLiveStream = isLiveStream;

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

  // Load artwork asynchronously
  if (artworkUrl && artworkUrl.length > 0) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
      NSURL *url = [NSURL URLWithString:artworkUrl];
      NSData *data = [NSData dataWithContentsOfURL:url];
      if (data) {
        UIImage *image = [UIImage imageWithData:data];
        if (image) {
          MPMediaItemArtwork *artwork = [[MPMediaItemArtwork alloc] initWithBoundsSize:image.size
                                                                        requestHandler:^UIImage * _Nonnull(CGSize size) {
            return image;
          }];
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
}

- (void)clearNowPlayingMetadata {
  [self cleanupRemoteCommandCenter];
}

#endif

#pragma mark - Pigeon API for Now Playing Metadata

- (void)setNowPlayingMetadata:(FVPNowPlayingMetadata *)metadata
                        error:(FlutterError *_Nullable *_Nonnull)error {
#if TARGET_OS_IOS
  [self setNowPlayingMetadataWithTitle:metadata.title
                                artist:metadata.artist
                                 album:metadata.album
                            artworkUrl:metadata.artworkUrl
                          isLiveStream:metadata.isLiveStream];
#else
  // macOS: Media controls not supported
  (void)metadata;
#endif
}

- (void)clearNowPlayingMetadataWithError:(FlutterError *_Nullable *_Nonnull)error {
#if TARGET_OS_IOS
  [self clearNowPlayingMetadata];
#endif
}

@end
