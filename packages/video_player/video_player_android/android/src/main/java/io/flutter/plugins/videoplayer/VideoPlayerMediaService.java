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
import androidx.media3.common.Player;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.session.CommandButton;
import androidx.media3.session.MediaSession;
import androidx.media3.session.MediaSessionService;
import androidx.media3.session.MediaNotification;
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
                        // Notification will be updated automatically by MediaSessionService
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
        }
    }

    public static void setEventCallbacks(@Nullable VideoPlayerEventCallbacks callbacks) {
        eventCallbacks = callbacks;
    }

    public static void clearPlayer() {
        currentPlayer = null;
        if (instance != null) {
            instance.stopSelf();
        }
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

        // Set custom MediaNotification.Provider to fully control notification
        setMediaNotificationProvider(new MediaNotification.Provider() {
            @NonNull
            @Override
            public MediaNotification createNotification(
                    @NonNull MediaSession session,
                    @NonNull ImmutableList<CommandButton> customLayout,
                    @NonNull MediaNotification.ActionFactory actionFactory,
                    @NonNull Callback callback) {
                Log.d(TAG, "createNotification called, isLiveStream=" + isLiveStream + ", customLayout size=" + customLayout.size());
                return buildCustomNotification(session, customLayout, actionFactory);
            }

            @Override
            public boolean handleCustomCommand(@NonNull MediaSession session,
                    @NonNull String action, @NonNull Bundle extras) {
                return false;
            }
        });

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

    private MediaNotification buildCustomNotification(
            @NonNull MediaSession session,
            @NonNull ImmutableList<CommandButton> customLayout,
            @NonNull MediaNotification.ActionFactory actionFactory) {
        // Get the app's launch intent for the notification tap action
        Intent launchIntent = getPackageManager().getLaunchIntentForPackage(getPackageName());
        PendingIntent contentIntent = null;
        if (launchIntent != null) {
            contentIntent = PendingIntent.getActivity(this, 0, launchIntent,
                PendingIntent.FLAG_UPDATE_CURRENT | PendingIntent.FLAG_IMMUTABLE);
        }

        Log.d(TAG, "buildCustomNotification: isLiveStream=" + isLiveStream + ", customLayout size=" + customLayout.size() + ", title=" + getMediaTitle());

        NotificationCompat.Builder builder = new NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(getMediaTitle())
            .setContentText(getMediaArtist())
            .setSmallIcon(android.R.drawable.ic_media_play)
            .setContentIntent(contentIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true);

        // Add custom actions from customLayout (prev/next buttons set via setCustomLayout)
        int actionIndex = 0;
        for (CommandButton button : customLayout) {
            NotificationCompat.Action action = actionFactory.createCustomActionFromCustomCommandButton(session, button);
            builder.addAction(action);
            Log.d(TAG, "Added custom action: " + button.displayName);
            actionIndex++;
        }

        // Add play/pause action using MediaSession's standard command
        boolean isPlaying = currentPlayer != null && currentPlayer.isPlaying();
        int playPauseIconRes = isPlaying ? android.R.drawable.ic_media_pause : android.R.drawable.ic_media_play;
        NotificationCompat.Action playPauseAction = actionFactory.createMediaAction(
            session,
            androidx.core.graphics.drawable.IconCompat.createWithResource(this, playPauseIconRes),
            isPlaying ? "Pause" : "Play",
            Player.COMMAND_PLAY_PAUSE
        );
        builder.addAction(playPauseAction);

        // Set MediaStyle with appropriate compact view actions
        // customLayout contains prev/next buttons, plus we added play/pause
        // Action order: [prev], [next], [play/pause] or just [play/pause] for live
        int totalActions = customLayout.size() + 1; // +1 for play/pause
        int[] compactViewActions;
        if (customLayout.isEmpty()) {
            // Live stream: only play/pause (index 0)
            compactViewActions = new int[]{0};
        } else {
            // Regular video: prev(0), next(1), play/pause(2)
            compactViewActions = new int[]{0, 1, 2};
        }

        builder.setStyle(new MediaStyleNotificationHelper.MediaStyle(session)
            .setShowActionsInCompactView(compactViewActions));

        Log.d(TAG, "Built notification with " + totalActions + " actions, compact view: " + java.util.Arrays.toString(compactViewActions));

        return new MediaNotification(NOTIFICATION_ID, builder.build());
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

        mediaSession = new MediaSession.Builder(this, player)
            .setCallback(new MediaSession.Callback() {
                @NonNull
                @Override
                public MediaSession.ConnectionResult onConnect(
                        @NonNull MediaSession session,
                        @NonNull MediaSession.ControllerInfo controller) {
                    // Allow connections and add custom commands with custom layout
                    return new MediaSession.ConnectionResult.AcceptedResultBuilder(session)
                        .setAvailableSessionCommands(
                            MediaSession.ConnectionResult.DEFAULT_SESSION_COMMANDS.buildUpon()
                                .add(nextCommand)
                                .add(prevCommand)
                                .build())
                        .build();
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
            })
            .build();

        // Set custom layout for media notification based on content type
        // For live streams: no prev/next buttons (only play/pause which is auto)
        // For regular videos: show prev/next buttons
        if (isLiveStream) {
            mediaSession.setCustomLayout(ImmutableList.of());
            Log.d(TAG, "MediaSession updated with new player (live stream - no prev/next buttons)");
        } else {
            mediaSession.setCustomLayout(ImmutableList.of(prevButton, nextButton));
            Log.d(TAG, "MediaSession updated with new player and custom layout (prev/next buttons)");
        }

        // Trigger notification update via MediaSessionService
        Log.d(TAG, "MediaSession updated, triggering notification refresh");
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
