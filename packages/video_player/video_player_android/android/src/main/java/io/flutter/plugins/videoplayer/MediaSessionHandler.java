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
import android.support.v4.media.MediaMetadataCompat;
import android.support.v4.media.session.MediaSessionCompat;
import android.support.v4.media.session.PlaybackStateCompat;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.core.app.NotificationCompat;
import androidx.media.app.NotificationMediaStyle;
import androidx.media3.common.Player;
import androidx.media3.exoplayer.ExoPlayer;
import java.io.IOException;
import java.net.URL;
import java.util.concurrent.Executors;

/**
 * Handles MediaSession integration for video playback.
 * Provides media controls in notification and lock screen.
 */
public class MediaSessionHandler {
  private static final String CHANNEL_ID = "video_player_media_controls";
  private static final String CHANNEL_NAME = "Media Controls";
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
      channel.setDescription("Media playback controls");
      channel.setShowBadge(false);
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
        // This will be handled by the video player
      }
      
      @Override
      public void onPause() {
        // This will be handled by the video player
      }
      
      @Override
      public void onSeekTo(long pos) {
        // This will be handled by the video player
      }
    });
    
    mediaSession.setActive(true);
  }
  
  public void setPlayer(@Nullable ExoPlayer player) {
    if (player != null) {
      // Set up player listener for state changes
      player.addListener(new Player.Listener() {
        @Override
        public void onPlaybackStateChanged(int playbackState) {
          updatePlaybackState(player);
        }
        
        @Override
        public void onIsPlayingChanged(boolean isPlaying) {
          updatePlaybackState(player);
          if (isPlaying) {
            showNotification(player);
          } else if (playbackState == Player.STATE_READY) {
            showNotification(player);
          }
        }
      });
      
      updatePlaybackState(player);
    }
  }
  
  private void updatePlaybackState(@NonNull ExoPlayer player) {
    long position = player.getCurrentPosition();
    float playbackSpeed = player.getPlaybackParameters().speed;
    
    int state = player.isPlaying() 
        ? PlaybackStateCompat.STATE_PLAYING 
        : PlaybackStateCompat.STATE_PAUSED;
    
    PlaybackStateCompat.Builder stateBuilder = new PlaybackStateCompat.Builder()
        .setActions(
            PlaybackStateCompat.ACTION_PLAY |
            PlaybackStateCompat.ACTION_PAUSE |
            PlaybackStateCompat.ACTION_PLAY_PAUSE |
            PlaybackStateCompat.ACTION_SEEK_TO
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
    
    // Load artwork asynchronously
    if (artworkUrl != null && !artworkUrl.isEmpty()) {
      loadArtwork(artworkUrl, metadataBuilder);
    } else {
      mediaSession.setMetadata(metadataBuilder.build());
    }
  }
  
  private void loadArtwork(String url, MediaMetadataCompat.Builder metadataBuilder) {
    Executors.newSingleThreadExecutor().execute(() -> {
      try {
        URL artworkUrl = new URL(url);
        currentArtwork = BitmapFactory.decodeStream(artworkUrl.openStream());
        metadataBuilder.putBitmap(MediaMetadataCompat.METADATA_KEY_ART, currentArtwork);
        mediaSession.setMetadata(metadataBuilder.build());
      } catch (IOException e) {
        // Failed to load artwork, use metadata without it
        mediaSession.setMetadata(metadataBuilder.build());
      }
    });
  }
  
  private void showNotification(@NonNull ExoPlayer player) {
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
        .setContentIntent(contentIntent)
        .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
        .setPriority(NotificationCompat.PRIORITY_LOW)
        .setOnlyAlertOnce(true)
        .setStyle(new NotificationMediaStyle()
            .setMediaSession(mediaSession.getSessionToken())
            .setShowActionsInCompactView(0, 1, 2));
    
    if (currentArtwork != null) {
      builder.setLargeIcon(currentArtwork);
    }
    
    // Add playback actions
    if (player.isPlaying()) {
      builder.addAction(
          android.R.drawable.ic_media_pause,
          "Pause",
          MediaButtonReceiver.buildMediaButtonPendingIntent(
              context,
              PlaybackStateCompat.ACTION_PAUSE
          )
      );
    } else {
      builder.addAction(
          android.R.drawable.ic_media_play,
          "Play",
          MediaButtonReceiver.buildMediaButtonPendingIntent(
              context,
              PlaybackStateCompat.ACTION_PLAY
          )
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