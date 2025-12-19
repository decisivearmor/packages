// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.OptIn;
import androidx.core.app.NotificationCompat;
import androidx.media3.common.ForwardingPlayer;
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.session.CommandButton;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import androidx.media3.session.MediaStyleNotificationHelper;
import androidx.media3.session.SessionCommand;
import androidx.media3.session.SessionResult;

import com.google.common.collect.ImmutableList;
import com.google.common.util.concurrent.Futures;
import com.google.common.util.concurrent.ListenableFuture;

import java.io.InputStream;
import java.net.URL;
import java.util.List;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Media service for handling background playback and media notifications.
 */
@OptIn(markerClass = UnstableApi.class)
public class VideoPlayerMediaService extends MediaSessionService {
    private static final String TAG = "VideoPlayerMediaService";
    private static final String CHANNEL_ID = "video_player_media_channel";
    private static final int NOTIFICATION_ID = 1001;

    // Action constants for notification buttons
    private static final String ACTION_PREVIOUS = "io.flutter.plugins.videoplayer.ACTION_PREVIOUS";
    private static final String ACTION_PLAY_PAUSE = "io.flutter.plugins.videoplayer.ACTION_PLAY_PAUSE";
    private static final String ACTION_NEXT = "io.flutter.plugins.videoplayer.ACTION_NEXT";

    @Nullable
    private MediaSession mediaSession;

    @Nullable
    private static Player currentPlayer;

    @Nullable
    private static VideoPlayerEventCallbacks eventCallbacks;

    @Nullable
    private static VideoPlayerMediaService instance;

    private static boolean isLiveStream = false;

    private final ExecutorService artworkExecutor = Executors.newSingleThreadExecutor();
    private boolean isForegroundStarted = false;

    // BroadcastReceiver to handle notification button clicks
    private final BroadcastReceiver actionReceiver = new BroadcastReceiver() {
        @Override
        public void onReceive(Context context, Intent intent) {
            String action = intent.getAction();
            if (action == null) return;

            Log.d(TAG, "Received action: " + action);

            switch (action) {
                case ACTION_PREVIOUS:
                    if (eventCallbacks != null) {
                        eventCallbacks.onPreviousTrackRequested();
                    }
                    break;
                case ACTION_PLAY_PAUSE:
                    if (currentPlayer != null) {
                        if (currentPlayer.isPlaying()) {
                            currentPlayer.pause();
                        } else {
                            currentPlayer.play();
                        }
                        // Update notification to reflect play/pause state
                        updateMediaStyleNotification();
                    }
                    break;
                case ACTION_NEXT:
                    if (eventCallbacks != null) {
                        eventCallbacks.onNextTrackRequested();
                    }
                    break;
            }
        }
    };

    public static void setPlayer(@Nullable Player player) {
        setPlayer(player, false);
    }

    public static void setPlayer(@Nullable Player player, boolean liveStream) {
        Log.d(TAG, "setPlayer called, player=" + (player != null ? "not null" : "null") + ", instance=" + (instance != null ? "not null" : "null") + ", isLiveStream=" + liveStream);
        currentPlayer = player;
        isLiveStream = liveStream;
        if (instance != null && player != null) {
            instance.updateSession(player);
            // Also explicitly update notification when player changes
            instance.updateMediaStyleNotification();
        }
    }

    public static void setEventCallbacks(@Nullable VideoPlayerEventCallbacks callbacks) {
        eventCallbacks = callbacks;
    }

    public static void clearPlayer() {
        clearPlayer(true);
    }

    public static void clearPlayer(boolean stopService) {
        Log.d(TAG, "clearPlayer called, stopService=" + stopService);
        currentPlayer = null;
        if (instance != null && stopService) {
            instance.stopSelf();
        }
        // If stopService is false, the service continues running
        // This allows for seamless player switching (e.g., radio track changes)
    }

    @Override
    public void onCreate() {
        super.onCreate();
        instance = this;
        createNotificationChannel();

        // Register broadcast receiver for notification actions
        IntentFilter filter = new IntentFilter();
        filter.addAction(ACTION_PREVIOUS);
        filter.addAction(ACTION_PLAY_PAUSE);
        filter.addAction(ACTION_NEXT);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(actionReceiver, filter, Context.RECEIVER_NOT_EXPORTED);
        } else {
            registerReceiver(actionReceiver, filter);
        }

        // Must call startForeground immediately in onCreate when started via startForegroundService
        // Android requires this within a few seconds or the app will crash
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification notification = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle("Media Playing")
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setOngoing(true)
                .build();

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(NOTIFICATION_ID, notification,
                    android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK);
            } else {
                startForeground(NOTIFICATION_ID, notification);
            }
            isForegroundStarted = true;
            Log.d(TAG, "Started foreground in onCreate");
        }

        Log.d(TAG, "VideoPlayerMediaService created");
    }

    private void updateSession(@NonNull Player player) {
        if (mediaSession != null) {
            mediaSession.release();
        }

        // Custom commands for next/previous track
        SessionCommand nextCommand = new SessionCommand("nextTrack", Bundle.EMPTY);
        SessionCommand prevCommand = new SessionCommand("previousTrack", Bundle.EMPTY);

        // Create custom layout buttons for notification
        CommandButton prevButton = new CommandButton.Builder()
            .setDisplayName("Previous")
            .setIconResId(android.R.drawable.ic_media_previous)
            .setSessionCommand(prevCommand)
            .build();

        CommandButton nextButton = new CommandButton.Builder()
            .setDisplayName("Next")
            .setIconResId(android.R.drawable.ic_media_next)
            .setSessionCommand(nextCommand)
            .build();

        // Wrap player with ForwardingPlayer to report SEEK_TO_PREVIOUS/NEXT as available
        // This is needed for Android 13+ where notification buttons are derived from Player.availableCommands
        Player wrappedPlayer;
        if (isLiveStream) {
            // For live streams, use the original player (no prev/next)
            wrappedPlayer = player;
            Log.d(TAG, "Using original player for live stream");
        } else {
            // For regular videos, wrap to enable prev/next commands
            wrappedPlayer = new ForwardingPlayer(player) {
                @Override
                @NonNull
                public Commands getAvailableCommands() {
                    // Add SEEK_TO_PREVIOUS and SEEK_TO_NEXT to available commands
                    return super.getAvailableCommands().buildUpon()
                        .add(COMMAND_SEEK_TO_PREVIOUS)
                        .add(COMMAND_SEEK_TO_NEXT)
                        .build();
                }

                @Override
                public boolean isCommandAvailable(int command) {
                    if (command == COMMAND_SEEK_TO_PREVIOUS || command == COMMAND_SEEK_TO_NEXT) {
                        return true;
                    }
                    return super.isCommandAvailable(command);
                }

                @Override
                public void seekToNext() {
                    Log.d(TAG, "seekToNext called via ForwardingPlayer, eventCallbacks=" + (eventCallbacks != null ? "not null" : "null"));
                    if (eventCallbacks != null) {
                        Log.d(TAG, "Calling onNextTrackRequested");
                        eventCallbacks.onNextTrackRequested();
                    } else {
                        Log.w(TAG, "eventCallbacks is null, cannot call onNextTrackRequested");
                    }
                }

                @Override
                public void seekToPrevious() {
                    Log.d(TAG, "seekToPrevious called via ForwardingPlayer, eventCallbacks=" + (eventCallbacks != null ? "not null" : "null"));
                    if (eventCallbacks != null) {
                        Log.d(TAG, "Calling onPreviousTrackRequested");
                        eventCallbacks.onPreviousTrackRequested();
                    } else {
                        Log.w(TAG, "eventCallbacks is null, cannot call onPreviousTrackRequested");
                    }
                }
            };
            Log.d(TAG, "Using ForwardingPlayer with prev/next commands enabled");
        }

        // Build MediaSession with callback using the wrapped player
        MediaSession.Builder sessionBuilder = new MediaSession.Builder(this, wrappedPlayer)
            .setCallback(new MediaSession.Callback() {
                @NonNull
                @Override
                public MediaSession.ConnectionResult onConnect(
                        @NonNull MediaSession session,
                        @NonNull MediaSession.ControllerInfo controller) {
                    // Allow connections and add custom commands
                    MediaSession.ConnectionResult.AcceptedResultBuilder builder =
                        new MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                            .setAvailableSessionCommands(
                                MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                                    .add(nextCommand)
                                    .add(prevCommand)
                                    .build());

                    // For regular videos, also add player commands for prev/next
                    if (!isLiveStream) {
                        builder.setAvailablePlayerCommands(
                            MediaSession.ConnectionResult.DEFAULT_PLAYER_COMMANDS.buildUpon()
                                .add(Player.COMMAND_SEEK_TO_PREVIOUS)
                                .add(Player.COMMAND_SEEK_TO_NEXT)
                                .build());
                    }

                    return builder.build();
                }

                @NonNull
                @Override
                public ListenableFuture<SessionResult> onCustomCommand(
                        @NonNull MediaSession session,
                        @NonNull MediaSession.ControllerInfo controller,
                        @NonNull SessionCommand customCommand,
                        @NonNull Bundle args) {
                    Log.d(TAG, "onCustomCommand: " + customCommand.customAction);
                    if ("nextTrack".equals(customCommand.customAction)) {
                        if (eventCallbacks != null) {
                            eventCallbacks.onNextTrackRequested();
                        }
                        return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                    } else if ("previousTrack".equals(customCommand.customAction)) {
                        if (eventCallbacks != null) {
                            eventCallbacks.onPreviousTrackRequested();
                        }
                        return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_SUCCESS));
                    }
                    return Futures.immediateFuture(new SessionResult(SessionResult.RESULT_ERROR_NOT_SUPPORTED));
                }
            });

        // For Android 13+, use setMediaButtonPreferences to control notification buttons
        // For live streams: no prev/next buttons (only play/pause which is auto)
        // For regular videos: show prev/next buttons
        if (isLiveStream) {
            // No custom buttons for live stream - just play/pause
            sessionBuilder.setMediaButtonPreferences(ImmutableList.of());
            Log.d(TAG, "MediaSession configured for live stream (no prev/next buttons)");
        } else {
            // Add prev/next buttons for regular videos
            sessionBuilder.setMediaButtonPreferences(ImmutableList.of(prevButton, nextButton));
            Log.d(TAG, "MediaSession configured with prev/next buttons for regular video");
        }

        mediaSession = sessionBuilder.build();

        // Also set custom layout for backward compatibility with older Android versions
        if (isLiveStream) {
            mediaSession.setCustomLayout(ImmutableList.of());
        } else {
            mediaSession.setCustomLayout(ImmutableList.of(prevButton, nextButton));
        }

        // Update notification with MediaStyle after session is created
        updateMediaStyleNotification();
    }

    @Nullable
    private Bitmap cachedArtwork = null;
    @Nullable
    private String cachedArtworkUri = null;

    private void updateMediaStyleNotification() {
        Log.d(TAG, "updateMediaStyleNotification called, mediaSession=" + (mediaSession != null ? "not null" : "null") + ", currentPlayer=" + (currentPlayer != null ? "not null" : "null") + ", isLiveStream=" + isLiveStream);
        if (mediaSession == null) {
            Log.w(TAG, "mediaSession is null, skipping notification update");
            return;
        }

        // Get artwork URI from current media item
        String artworkUriString = getArtworkUri();

        // If artwork URI changed, load new artwork asynchronously
        if (artworkUriString != null && !artworkUriString.equals(cachedArtworkUri)) {
            cachedArtworkUri = artworkUriString;
            loadArtworkAsync(artworkUriString);
        }

        buildAndShowNotification();
    }

    private void loadArtworkAsync(String artworkUriString) {
        artworkExecutor.execute(() -> {
            try {
                Log.d(TAG, "Loading artwork from: " + artworkUriString);
                URL url = new URL(artworkUriString);
                InputStream inputStream = url.openStream();
                Bitmap bitmap = BitmapFactory.decodeStream(inputStream);
                inputStream.close();

                if (bitmap != null) {
                    cachedArtwork = bitmap;
                    Log.d(TAG, "Artwork loaded successfully");
                    // Update notification on main thread with the new artwork
                    new android.os.Handler(android.os.Looper.getMainLooper()).post(() -> {
                        buildAndShowNotification();
                    });
                }
            } catch (Exception e) {
                Log.w(TAG, "Failed to load artwork: " + e.getMessage());
            }
        });
    }

    private void buildAndShowNotification() {
        if (mediaSession == null) return;

        try {
            // Get the app's launch intent for the notification tap action
            Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
            PendingIntent contentIntent = null;
            if (launchIntent != null) {
                contentIntent = PendingIntent.getActivity(this, 0, launchIntent,
                    PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
            }

            // Create PendingIntents for action buttons
            Intent prevIntent = new Intent(ACTION_PREVIOUS);
            prevIntent.setPackage(getPackageName());
            PendingIntent prevPendingIntent = PendingIntent.getBroadcast(this, 0, prevIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

            Intent playPauseIntent = new Intent(ACTION_PLAY_PAUSE);
            playPauseIntent.setPackage(getPackageName());
            PendingIntent playPausePendingIntent = PendingIntent.getBroadcast(this, 1, playPauseIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

            Intent nextIntent = new Intent(ACTION_NEXT);
            nextIntent.setPackage(getPackageName());
            PendingIntent nextPendingIntent = PendingIntent.getBroadcast(this, 2, nextIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);

            // Determine play/pause icon based on current state
            boolean isPlaying = currentPlayer != null && currentPlayer.isPlaying();
            int playPauseIcon = isPlaying ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play;
            String playPauseTitle = isPlaying ? "Pause" : "Play";

            // Build MediaStyle notification with action buttons
            // For live streams: only play/pause button
            // For regular videos: Previous, Play/Pause, Next buttons
            NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
                .setContentTitle(getMediaTitle())
                .setContentText(getMediaArtist())
                .setSmallIcon(android.R.drawable.ic_media_play)
                .setContentIntent(contentIntent)
                .setPriority(NotificationCompat.PRIORITY_LOW)
                .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
                .setOngoing(true);

            // Set large icon (artwork) if available
            if (cachedArtwork != null) {
                builder.setLargeIcon(cachedArtwork);
                Log.d(TAG, "Setting artwork as large icon");
            }

            if (isLiveStream) {
                // Live stream: only play/pause button
                builder.addAction(playPauseIcon, playPauseTitle, playPausePendingIntent)
                    .setStyle(new MediaStyleNotificationHelper.MediaStyle(mediaSession)
                        .setShowActionsInCompactView(0));  // Show only play/pause in compact view
                Log.d(TAG, "Building live stream notification with play/pause only");
            } else {
                // Regular video: Previous, Play/Pause, Next buttons
                builder.addAction(android.R.drawable.ic_media_previous, "Previous", prevPendingIntent)
                    .addAction(playPauseIcon, playPauseTitle, playPausePendingIntent)
                    .addAction(android.R.drawable.ic_media_next, "Next", nextPendingIntent)
                    .setStyle(new MediaStyleNotificationHelper.MediaStyle(mediaSession)
                        .setShowActionsInCompactView(0, 1, 2));  // Show all 3 actions in compact view
                Log.d(TAG, "Building regular video notification with prev/play/next buttons");
            }

            Notification notification = builder.build();

            NotificationManager notificationManager = getSystemService(NotificationManager.class);
            if (notificationManager != null) {
                notificationManager.notify(NOTIFICATION_ID, notification);
            }
            Log.d(TAG, "Updated MediaStyle notification");
        } catch (Exception e) {
            Log.e(TAG, "Failed to update MediaStyle notification: " + e.getMessage());
        }
    }

    @Nullable
    private String getArtworkUri() {
        if (currentPlayer != null && currentPlayer.getCurrentMediaItem() != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata.artworkUri != null) {
            return currentPlayer.getCurrentMediaItem().mediaMetadata.artworkUri.toString();
        }
        return null;
    }

    private String getMediaTitle() {
        if (currentPlayer != null && currentPlayer.getCurrentMediaItem() != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata.title != null) {
            return currentPlayer.getCurrentMediaItem().mediaMetadata.title.toString();
        }
        return "Media Playing";
    }

    private String getMediaArtist() {
        if (currentPlayer != null && currentPlayer.getCurrentMediaItem() != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata != null &&
            currentPlayer.getCurrentMediaItem().mediaMetadata.artist != null) {
            return currentPlayer.getCurrentMediaItem().mediaMetadata.artist.toString();
        }
        return "";
    }

    @Override
    @Nullable
    public MediaSession onGetSession(@NonNull MediaSession.ControllerInfo controllerInfo) {
        return mediaSession;
    }

    @Override
    public int onStartCommand(@Nullable Intent intent, int flags, int startId) {
        // startForeground is already called in onCreate, so we just need to update the session
        if (currentPlayer != null && mediaSession == null) {
            updateSession(currentPlayer);
        }
        return super.onStartCommand(intent, flags, startId);
    }

    @Override
    public void onDestroy() {
        // Unregister broadcast receiver
        try {
            unregisterReceiver(actionReceiver);
        } catch (Exception e) {
            Log.w(TAG, "Failed to unregister receiver: " + e.getMessage());
        }

        if (mediaSession != null) {
            mediaSession.release();
            mediaSession = null;
        }
        artworkExecutor.shutdown();
        instance = null;
        Log.d(TAG, "VideoPlayerMediaService destroyed");
        super.onDestroy();
    }

    @Override
    public void onTaskRemoved(@Nullable Intent rootIntent) {
        Player player = mediaSession != null ? mediaSession.getPlayer() : null;
        if (player == null || !player.getPlayWhenReady() || player.getMediaItemCount() == 0) {
            stopSelf();
        }
    }

    private void createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationChannel channel = new NotificationChannel(
                CHANNEL_ID,
                "Media Playback",
                NotificationManager.IMPORTANCE_LOW
            );
            channel.setDescription("Controls for media playback");
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_PUBLIC);

            NotificationManager manager = getSystemService(NotificationManager.class);
            if (manager != null) {
                manager.createNotificationChannel(channel);
            }
        }
    }
}
