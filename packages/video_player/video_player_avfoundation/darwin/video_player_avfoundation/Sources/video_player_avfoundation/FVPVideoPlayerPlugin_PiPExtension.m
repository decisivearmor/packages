// FVPVideoPlayerPlugin_PiPExtension.m
// PiP切り替え機能の拡張実装

#import "include/video_player_avfoundation/FVPVideoPlayerPlugin.h"
#import "include/video_player_avfoundation/FVPVideoPlayer.h"
#import "include/video_player_avfoundation/messages.g.h"
#import <AVKit/AVKit.h>

@interface FVPVideoPlayerPlugin (PiPExtension)
- (nullable NSNumber *)createWithPipTransition:(nonnull FVPCreationOptions *)options
                                          error:(FlutterError **)error;
@end

@implementation FVPVideoPlayerPlugin (PiPExtension)

- (nullable NSNumber *)createWithPipTransition:(nonnull FVPCreationOptions *)options
                                          error:(FlutterError **)error {
#if TARGET_OS_IOS
  if (@available(iOS 9.0, *)) {
    // 既存のPiPプレイヤーを確認
    if (self->_activePipPlayerIdentifier && options.uri) {
      FVPVideoPlayer *existingPlayer = self->_playersByIdentifier[self->_activePipPlayerIdentifier];
      
      if (existingPlayer && [existingPlayer respondsToSelector:@selector(pipController)]) {
        AVPictureInPictureController *pipController = [existingPlayer valueForKey:@"pipController"];
        
        if (pipController && pipController.isPictureInPictureActive) {
          NSLog(@"📺 [PiPExtension] 既存のPiPプレイヤーを検出しました");
          
          // 新しいプレイヤーを作成
          FVPVideoPlayer *newPlayer = nil;
          if (options.viewType == FVPPlatformVideoViewTypeTextureView) {
            newPlayer = [self texturePlayerWithOptions:options];
          } else {
            newPlayer = [self platformViewPlayerWithOptions:options];
          }
          
          if (!newPlayer) {
            *error = [FlutterError errorWithCode:@"video_player" 
                                        message:@"新しいプレイヤーの作成に失敗しました" 
                                        details:nil];
            return nil;
          }
          
          // 新しいプレイヤーをセットアップ
          int64_t newPlayerId = [self onPlayerSetup:newPlayer];
          
          // PiPコントローラーを新しいプレイヤーに移管
          [self transferPipControllerFromPlayer:existingPlayer 
                                      toPlayer:newPlayer 
                               withNewPlayerId:@(newPlayerId)];
          
          return @(newPlayerId);
        }
      }
    }
  }
#endif
  
  // PiPがアクティブでない場合は通常の作成処理
  return [self createWithOptions:options error:error];
}

#if TARGET_OS_IOS
- (void)transferPipControllerFromPlayer:(FVPVideoPlayer *)oldPlayer 
                              toPlayer:(FVPVideoPlayer *)newPlayer 
                       withNewPlayerId:(NSNumber *)newPlayerId {
  if (@available(iOS 9.0, *)) {
    // 1. 既存のPiPコントローラーを取得
    AVPictureInPictureController *pipController = [oldPlayer valueForKey:@"pipController"];
    if (!pipController || !pipController.isPictureInPictureActive) {
      return;
    }
    
    // 2. 新しいプレイヤーのレイヤーを取得
    AVPlayerLayer *newPlayerLayer = nil;
    if ([newPlayer respondsToSelector:@selector(playerLayer)]) {
      newPlayerLayer = [newPlayer valueForKey:@"playerLayer"];
    }
    
    if (!newPlayerLayer) {
      NSLog(@"⚠️ [PiPExtension] 新しいプレイヤーレイヤーが見つかりません");
      return;
    }
    
    // 3. PiPコントローラーのプレイヤーレイヤーを更新
    @try {
      // プライベートAPIを使用してプレイヤーレイヤーを更新
      // 注意: これは公式にサポートされていない方法です
      if ([pipController respondsToSelector:@selector(setPlayerLayer:)]) {
        [pipController setValue:newPlayerLayer forKey:@"playerLayer"];
        NSLog(@"✅ [PiPExtension] PiPコントローラーのプレイヤーレイヤーを更新しました");
      } else {
        // 代替方法: PiPを一度停止して新しいプレイヤーで再開
        [self restartPipWithNewPlayer:newPlayer oldController:pipController];
      }
      
      // 4. コントローラーの参照を更新
      [oldPlayer setValue:nil forKey:@"pipController"];
      [newPlayer setValue:pipController forKey:@"pipController"];
      
      // 5. activePipPlayerIdentifierを更新
      self->_activePipPlayerIdentifier = newPlayerId;
      
      NSLog(@"✅ [PiPExtension] PiP切り替え完了: 旧ID=%@ → 新ID=%@", 
            self->_activePipPlayerIdentifier, newPlayerId);
      
    } @catch (NSException *exception) {
      NSLog(@"❌ [PiPExtension] PiP切り替えエラー: %@", exception.reason);
      // エラー時はPiPを再起動
      [self restartPipWithNewPlayer:newPlayer oldController:pipController];
    }
  }
}

- (void)restartPipWithNewPlayer:(FVPVideoPlayer *)newPlayer 
                 oldController:(AVPictureInPictureController *)oldController {
  if (@available(iOS 9.0, *)) {
    // PiPを一度停止
    [oldController stopPictureInPicture];
    
    // 新しいプレイヤーレイヤーを取得
    AVPlayerLayer *newPlayerLayer = nil;
    if ([newPlayer respondsToSelector:@selector(playerLayer)]) {
      newPlayerLayer = [newPlayer valueForKey:@"playerLayer"];
    }
    
    if (newPlayerLayer && [AVPictureInPictureController isPictureInPictureSupported]) {
      // 新しいPiPコントローラーを作成
      AVPictureInPictureController *newPipController = 
          [[AVPictureInPictureController alloc] initWithPlayerLayer:newPlayerLayer];
      
      if (newPipController) {
        [newPlayer setValue:newPipController forKey:@"pipController"];
        
        // 0.3秒後にPiPを再開
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), 
                       dispatch_get_main_queue(), ^{
          [newPipController startPictureInPicture];
          NSLog(@"✅ [PiPExtension] 新しいPiPコントローラーで再開しました");
        });
      }
    }
  }
}
#endif

@end