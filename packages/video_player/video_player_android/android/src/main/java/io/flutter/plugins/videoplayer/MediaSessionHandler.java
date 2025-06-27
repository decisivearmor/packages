// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.Context;
import android.content.Intent;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.media.session.MediaButtonReceiver;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.ExoPlayer;
import java.io.IOException;
import java.net.URL;
import java.util.concurrent.Executors;

/**
 * Handles MediaSession integration for video playback.
 * Provides media controls in notification and lock screen.
 */
@UnstableApi
public class MediaSessionHandler {
  private static final String CHANNEL_ID = "video_player_media_controls";
  private static final String CHANNEL_NAME = "Media Playback";
  private static final int NOTIFICATION_ID = 1001;
  
  private final Context context;
  private final NotificationManager notificationManager;
  private MediaSessionCompat mediaSession;
  private final String packageName;
  
  // Current metadata
  private String currentTitle;
  private String currentArtist;
  private String currentAlbum;
  private String currentArtworkUrl;
  private Bitmap currentArtwork;
  
  // Player reference
  private ExoPlayer currentPlayer;
  
  // Handler for main thread operations
  private final Handler mainHandler = new Handler(Looper.getMainLooper());
  
  public MediaSessionHandler(@NonNull Context context) {
    this.context = context;
    this.packageName = context.getPackageName();
    this.notificationManager = 
        (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
    
    createNotificationChannel();
    initializeMediaSession();
  }
  
  private void createNotificationChannel() {
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
      NotificationChannel channel = new NotificationChannel(
          CHANNEL_ID,
          CHANNEL_NAME,
          NotificationManager.IMPORTANCE_LOW
      );
      channel.setDescription("Media playback controls for video player");
      channel.setShowBadge(false);
      channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);
      notificationManager.createNotificationChannel(channel);
    }
  }
  
  private void initializeMediaSession() {
    mediaSession = new MediaSessionCompat(context, "VideoPlayerMediaSession");
    mediaSession.setFlags(
        MediaSessionCompat.FLAG_HANDLES_MEDIA_BUTTONS |
        MediaSessionCompat.FLAG_HANDLES_TRANSPORT_CONTROLS
    );
    
    // Set media session callbacks
    mediaSession.setCallback(new MediaSessionCompat.Callback() {
      @Override
      public void onPlay() {
        if (currentPlayer != null) {
          currentPlayer.play();
        }
      }
      
      @Override
      public void onPause() {
        if (currentPlayer != null) {
          currentPlayer.pause();
        }
      }
      
      @Override
      public void onSeekTo(long pos) {
        if (currentPlayer != null) {
          currentPlayer.seekTo(pos);
        }
      }
      
      @Override
      public void onSkipToPrevious() {
        if (currentPlayer != null) {
          long newPosition = Math.max(0, currentPlayer.getCurrentPosition() - 10000);
          currentPlayer.seekTo(newPosition);
        }
      }
      
      @Override
      public void onSkipToNext() {
        if (currentPlayer != null) {
          long newPosition = Math.min(currentPlayer.getDuration(), 
                                    currentPlayer.getCurrentPosition() + 10000);
          currentPlayer.seekTo(newPosition);
        }
      }
    });
    
    mediaSession.setActive(true);
  }
  
  public void setPlayer(@Nullable ExoPlayer player) {
    this.currentPlayer = player;
    
    if (player != null) {
      // Set up player listener for state changes
      player.addListener(new Player.Listener() {
        @Override
        public void onPlaybackStateChanged(int playbackState) {
          // Ensure updates happen on main thread
          mainHandler.post(() -> {
            updatePlaybackState();
            showNotification();
          });
        }
        
        @Override
        public void onIsPlayingChanged(boolean isPlaying) {
          // Ensure updates happen on main thread
          mainHandler.post(() -> {
            updatePlaybackState();
            showNotification();
          });
        }
        
        @Override
        public void onPositionDiscontinuity(
            Player.PositionInfo oldPosition,
            Player.PositionInfo newPosition,
            int reason) {
          // Ensure updates happen on main thread
          mainHandler.post(() -> updatePlaybackState());
        }
      });
      
      updatePlaybackState();
      showNotification();
    }
  }
  
  private void updatePlaybackState() {
    if (currentPlayer == null) return;
    
    long position = currentPlayer.getCurrentPosition();
    float playbackSpeed = currentPlayer.getPlaybackParameters().speed;
    
    int state = currentPlayer.isPlaying() 
        ? PlaybackStateCompat.STATE_PLAYING 
        : PlaybackStateCompat.STATE_PAUSED;
    
    PlaybackStateCompat.Builder stateBuilder = new PlaybackStateCompat.Builder()
        .setActions(
            PlaybackStateCompat.ACTION_PLAY |
            PlaybackStateCompat.ACTION_PAUSE |
            PlaybackStateCompat.ACTION_PLAY_PAUSE |
            PlaybackStateCompat.ACTION_SEEK_TO |
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS |
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        )
        .setState(state, position, playbackSpeed);
    
    mediaSession.setPlaybackState(stateBuilder.build());
  }
  
  public void setMetadata(String title, String artist, String album, String artworkUrl) {
    this.currentTitle = title;
    this.currentArtist = artist;
    this.currentAlbum = album;
    this.currentArtworkUrl = artworkUrl;
    
    MediaMetadataCompat.Builder metadataBuilder = new MediaMetadataCompat.Builder()
        .putString(MediaMetadataCompat.METADATA_KEY_TITLE, title != null ? title : "")
        .putString(MediaMetadataCompat.METADATA_KEY_ARTIST, artist != null ? artist : "")
        .putString(MediaMetadataCompat.METADATA_KEY_ALBUM, album != null ? album : "");
    
    if (currentPlayer != null) {
      metadataBuilder.putLong(MediaMetadataCompat.METADATA_KEY_DURATION, currentPlayer.getDuration());
    }
    
    mediaSession.setMetadata(metadataBuilder.build());
    
    // Load artwork asynchronously
    if (artworkUrl != null && !artworkUrl.isEmpty()) {
      loadArtwork(artworkUrl);
    }
    
    showNotification();
  }
  
  private void loadArtwork(String url) {
    Executors.newSingleThreadExecutor().execute(() -> {
      try {
        URL artworkUrl = new URL(url);
        currentArtwork = BitmapFactory.decodeStream(artworkUrl.openStream());
        
        // Post to main thread to update UI and access player
        mainHandler.post(() -> {
          // Update metadata with artwork
          MediaMetadataCompat currentMetadata = mediaSession.getController().getMetadata();
          if (currentMetadata != null) {
            MediaMetadataCompat.Builder builder = new MediaMetadataCompat.Builder(currentMetadata);
            builder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, currentArtwork);
            mediaSession.setMetadata(builder.build());
          }
          
          showNotification();
        });
      } catch (IOException e) {
        // Failed to load artwork - still update notification on main thread
        mainHandler.post(() -> showNotification());
      }
    });
  }
  
  private void showNotification() {
    if (currentPlayer == null) return;
    
    // Create intent for launching the app
    Intent intent = context.getPackageManager().getLaunchIntentForPackage(packageName);
    PendingIntent contentIntent = PendingIntent.getActivity(
        context, 
        0, 
        intent, 
        PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE
    );
    
    // Build the notification
    NotificationCompat.Builder builder = new NotificationCompat.Builder(context, CHANNEL_ID)
        .setSmallIcon(android.R.drawable.ic_media_play)
        .setContentTitle(currentTitle != null ? currentTitle : "Video Player")
        .setContentText(currentArtist != null ? currentArtist : "")
        .setSubText(currentAlbum)
        .setContentIntent(contentIntent)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOnlyAlertOnce(true)
        .setOngoing(currentPlayer.isPlaying())
        .setShowWhen(false);
    
    if (currentArtwork != null) {
      builder.setLargeIcon(currentArtwork);
    }
    
    // Create MediaStyle
    androidx.media.app.NotificationCompat.MediaStyle mediaStyle = 
        new androidx.media.app.NotificationCompat.MediaStyle()
            .setMediaSession(mediaSession.getSessionToken())
            .setShowCancelButton(false);
    
    // Add skip backward action
    builder.addAction(new NotificationCompat.Action(
        android.R.drawable.ic_media_rew,
        "Previous",
        MediaButtonReceiver.buildMediaButtonPendingIntent(
            context,
            PlaybackStateCompat.ACTION_SKIP_TO_PREVIOUS
        )
    ));
    
    // Add play/pause action
    if (currentPlayer.isPlaying()) {
      builder.addAction(new NotificationCompat.Action(
          android.R.drawable.ic_media_pause,
          "Pause",
          MediaButtonReceiver.buildMediaButtonPendingIntent(
              context,
              PlaybackStateCompat.ACTION_PAUSE
          )
      ));
    } else {
      builder.addAction(new NotificationCompat.Action(
          android.R.drawable.ic_media_play,
          "Play",
          MediaButtonReceiver.buildMediaButtonPendingIntent(
              context,
              PlaybackStateCompat.ACTION_PLAY
          )
      ));
    }
    
    // Add skip forward action
    builder.addAction(new NotificationCompat.Action(
        android.R.drawable.ic_media_ff,
        "Next",
        MediaButtonReceiver.buildMediaButtonPendingIntent(
            context,
            PlaybackStateCompat.ACTION_SKIP_TO_NEXT
        )
    ));
    
    // Show actions in compact view (skip backward, play/pause, skip forward)
    mediaStyle.setShowActionsInCompactView(0, 1, 2);
    builder.setStyle(mediaStyle);
    
    // Add progress bar
    if (currentPlayer.getDuration() > 0) {
      builder.setProgress(
          (int) currentPlayer.getDuration(),
          (int) currentPlayer.getCurrentPosition(),
          false
      );
    }
    
    Notification notification = builder.build();
    notificationManager.notify(NOTIFICATION_ID, notification);
  }
  
  public void hideNotification() {
    notificationManager.cancel(NOTIFICATION_ID);
  }
  
  public void release() {
    hideNotification();
    if (mediaSession != null) {
      mediaSession.setActive(false);
      mediaSession.release();
    }
  }
  
  public MediaSessionCompat getMediaSession() {
    return mediaSession;
  }
}