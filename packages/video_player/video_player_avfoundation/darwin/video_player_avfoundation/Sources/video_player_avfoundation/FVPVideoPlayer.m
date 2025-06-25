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

@implementation FVPVideoPlayer
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
    options = @{AVURLAssetHTTPHeaderFieldsKey : headers};
  }
  AVURLAsset *urlAsset = [AVURLAsset URLAssetWithURL:url options:options];
  
  // Store headers for potential reuse
  _httpHeaders = [headers copy];
  
  AVPlayerItem *item = [AVPlayerItem playerItemWithAsset:urlAsset];
  return [self initWithPlayerItem:item avFactory:avFactory viewProvider:viewProvider];
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
  
  // Configure for HLS background playback
  if (@available(iOS 10.0, *)) {
    item.preferredForwardBufferDuration = 5.0; // 5 seconds buffer
    if (@available(iOS 9.0, *)) {
      item.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
    }
  }

  // Configure output.
  NSDictionary *pixBuffAttributes = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
  };
  _videoOutput = [avFactory videoOutputWithPixelBufferAttributes:pixBuffAttributes];

  [self addObserversForItem:item player:_player];
  
  // Setup Remote Command Center
  [self setupRemoteCommandCenter];
  
#if TARGET_OS_IOS
  // Register for app lifecycle notifications
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationWillResignActive:)
                                              name:UIApplicationWillResignActiveNotification
                                            object:nil];
  [[NSNotificationCenter defaultCenter] addObserver:self
                                          selector:@selector(applicationDidBecomeActive:)
                                              name:UIApplicationDidBecomeActiveNotification
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
    if (_pipController && [_pipController isPictureInPictureActive]) {
      [_pipController stopPictureInPicture];
    }
    _pipController = nil;
  }
#endif

  [self cleanupRemoteCommandCenter];
  
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
        [_pipController startPictureInPicture];
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
}

- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP開始完了時の処理
  NSLog(@"PiP did start");
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了時の処理
  NSLog(@"PiP will stop");
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
  // PiP終了完了時の処理
  NSLog(@"PiP did stop");
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
  NSLog(@"Application will resign active");
  // Ensure audio session remains active for background playback
  [[AVAudioSession sharedInstance] setActive:YES error:nil];
  
  // Update Now Playing info to ensure it's current
  [self updateNowPlayingInfo];
  
  // For HLS streams, ensure player continues buffering in background
  if (_player.currentItem) {
    _player.currentItem.preferredForwardBufferDuration = 5.0; // 5 seconds buffer
    _player.currentItem.canUseNetworkResourcesForLiveStreamingWhilePaused = YES;
  }
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
  NSLog(@"Application did become active");
  // Re-setup remote command center to ensure it's properly registered
  [self setupRemoteCommandCenter];
  
  // Update Now Playing info
  [self updateNowPlayingInfo];
  
  // Re-activate audio session
  [[AVAudioSession sharedInstance] setActive:YES error:nil];
}
#endif

#pragma mark - Remote Command Center

- (void)setupRemoteCommandCenter {
#if TARGET_OS_IOS
  MPRemoteCommandCenter *commandCenter = [MPRemoteCommandCenter sharedCommandCenter];
  
  // Play command
  [commandCenter.playCommand setEnabled:YES];
  [commandCenter.playCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    [self play];
    return MPRemoteCommandHandlerStatusSuccess;
  }];
  
  // Pause command
  [commandCenter.pauseCommand setEnabled:YES];
  [commandCenter.pauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    [self pause];
    return MPRemoteCommandHandlerStatusSuccess;
  }];
  
  // Toggle play/pause command
  [commandCenter.togglePlayPauseCommand setEnabled:YES];
  [commandCenter.togglePlayPauseCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    if ([self isPlaying]) {
      [self pause];
    } else {
      [self play];
    }
    return MPRemoteCommandHandlerStatusSuccess;
  }];
  
  // Change playback position command (seek)
  [commandCenter.changePlaybackPositionCommand setEnabled:YES];
  [commandCenter.changePlaybackPositionCommand addTargetWithHandler:^MPRemoteCommandHandlerStatus(MPRemoteCommandEvent * _Nonnull event) {
    MPChangePlaybackPositionCommandEvent *positionEvent = (MPChangePlaybackPositionCommandEvent *)event;
    [self seekTo:(int64_t)(positionEvent.positionTime * 1000) completionHandler:nil];
    return MPRemoteCommandHandlerStatusSuccess;
  }];
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
    // Default title if no metadata set
    nowPlayingInfo[MPMediaItemPropertyTitle] = @"Video";
  }
  
  [[MPNowPlayingInfoCenter defaultCenter] setNowPlayingInfo:nowPlayingInfo];
#endif
}

@end
