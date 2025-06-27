package io.flutter.plugins.videoplayerexample;

import android.content.res.Configuration;
import android.os.Build;
import androidx.annotation.NonNull;
import androidx.annotation.RequiresApi;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
    private static final String PIP_CHANNEL = "video_player_pip_channel";
    private MethodChannel pipChannel;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        
        // Set up method channel for PiP events
        pipChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), PIP_CHANNEL);
    }

    @Override
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode, Configuration newConfig) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig);
        
        // Notify Flutter side about PiP mode change
        if (pipChannel != null) {
            pipChannel.invokeMethod("onPictureInPictureModeChanged", isInPictureInPictureMode);
        }
    }

    @Override
    @RequiresApi(api = Build.VERSION_CODES.O)
    public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode);
        
        // For older API compatibility
        if (pipChannel != null) {
            pipChannel.invokeMethod("onPictureInPictureModeChanged", isInPictureInPictureMode);
        }
    }
}