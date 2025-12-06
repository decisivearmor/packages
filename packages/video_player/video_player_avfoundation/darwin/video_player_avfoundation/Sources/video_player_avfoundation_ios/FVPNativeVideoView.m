// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#import "../video_player_avfoundation/include/video_player_avfoundation/FVPNativeVideoView.h"

#import <AVFoundation/AVFoundation.h>

@interface FVPPlayerView : UIView
@end

@implementation FVPPlayerView
+ (Class)layerClass {
  return [AVPlayerLayer class];
}

- (void)setPlayer:(AVPlayer *)player {
  [(AVPlayerLayer *)[self layer] setPlayer:player];
}
@end

@interface FVPNativeVideoView ()
@property(nonatomic) FVPPlayerView *playerView;
@property(nonatomic, weak) AVPlayer *player;
@property(nonatomic, strong) AVPlayer *retainedPlayerForBackground; // Temporarily retain during background
@property(nonatomic, strong) NSNumber *playerIdentifier;
@property(nonatomic, copy) FVPPlayerProvider playerProvider;
@end

@implementation FVPNativeVideoView

- (instancetype)initWithPlayerIdentifier:(NSNumber *)playerIdentifier
                          playerProvider:(FVPPlayerProvider)playerProvider {
  if (self = [super init]) {
    _playerIdentifier = playerIdentifier;
    _playerProvider = [playerProvider copy];
    _playerView = [[FVPPlayerView alloc] init];

    // Get the initial player from the provider
    AVPlayer *player = playerProvider(playerIdentifier);
    _player = player;
    [_playerView setPlayer:player];

    // Register for app lifecycle notifications
    // Use didEnterBackground instead of willResignActive to avoid detaching
    // when notification center or control center is opened
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    NSLog(@"[VideoPlayer] FVPNativeVideoView initialized with playerIdentifier: %@ and provider", playerIdentifier);
  }
  return self;
}

- (instancetype)initWithPlayer:(AVPlayer *)player {
  if (self = [super init]) {
    _playerView = [[FVPPlayerView alloc] init];
    _player = player;
    [_playerView setPlayer:player];

    // Register for app lifecycle notifications
    // Use didEnterBackground instead of willResignActive to avoid detaching
    // when notification center or control center is opened
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidEnterBackground:)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive:)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    NSLog(@"[VideoPlayer] FVPNativeVideoView initialized with lifecycle observers (legacy)");
  }
  return self;
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)appDidEnterBackground:(NSNotification *)notification {
  // Detach player from layer when entering background
  // This prevents iOS from pausing the AVPlayer
  // Note: Using didEnterBackground instead of willResignActive so that
  // notification center / control center doesn't trigger this
  AVPlayer *currentPlayer = _player;

  // If we have a provider, get the latest player
  if (_playerProvider && _playerIdentifier) {
    AVPlayer *latestPlayer = _playerProvider(_playerIdentifier);
    if (latestPlayer) {
      currentPlayer = latestPlayer;
    }
  }

  if (currentPlayer && currentPlayer.rate > 0) {
    // Retain the player during background to prevent deallocation
    _retainedPlayerForBackground = currentPlayer;
    [(AVPlayerLayer *)[_playerView layer] setPlayer:nil];
    NSLog(@"[VideoPlayer] FVPNativeVideoView: Detached player from layer (didEnterBackground)");
  }
}

- (void)appDidBecomeActive:(NSNotification *)notification {
  // If we have a provider, always get the latest player from it
  // This handles the case where player was changed in background
  AVPlayer *playerToReattach = nil;

  if (_playerProvider && _playerIdentifier) {
    playerToReattach = _playerProvider(_playerIdentifier);
    NSLog(@"[VideoPlayer] FVPNativeVideoView: Got player from provider for id %@: %@",
          _playerIdentifier,
          playerToReattach ? @"exists" : @"nil");
  }

  // Fallback to retained/stored player if provider didn't return one
  if (!playerToReattach) {
    playerToReattach = _retainedPlayerForBackground ?: _player;
  }

  NSLog(@"[VideoPlayer] FVPNativeVideoView: didBecomeActive - playerToReattach: %@, rate: %f",
        playerToReattach ? @"exists" : @"nil",
        playerToReattach ? playerToReattach.rate : 0.0);

  if (playerToReattach) {
    // Update our reference to the latest player
    _player = playerToReattach;

    AVPlayerLayer *playerLayer = (AVPlayerLayer *)[_playerView layer];

    // Reattach player to layer
    [playerLayer setPlayer:playerToReattach];
    NSLog(@"[VideoPlayer] FVPNativeVideoView: Reattached player to layer (didBecomeActive)");

    // Force layer to redraw
    [playerLayer setNeedsDisplay];
    [_playerView setNeedsLayout];
    [_playerView layoutIfNeeded];
  } else {
    NSLog(@"[VideoPlayer] FVPNativeVideoView: WARNING - no player to reattach");
  }

  // Release the retained player
  _retainedPlayerForBackground = nil;
}

- (FVPPlayerView *)view {
  return self.playerView;
}

- (void)detachPlayerFromLayer {
  // Detach player from layer to allow background audio playback
  // iOS automatically pauses AVPlayer when video is being displayed in background
  [(AVPlayerLayer *)[_playerView layer] setPlayer:nil];
  NSLog(@"[VideoPlayer] Detached player from layer for background playback");
}

- (void)reattachPlayerToLayer:(AVPlayer *)player {
  // Reattach player to layer when returning to foreground
  _player = player;
  [(AVPlayerLayer *)[_playerView layer] setPlayer:player];
  NSLog(@"[VideoPlayer] Reattached player to layer");
}
@end
