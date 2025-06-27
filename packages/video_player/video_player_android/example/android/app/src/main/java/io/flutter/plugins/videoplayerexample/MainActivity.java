package io.flutter.plugins.videoplayerexample;

import android.os.Build;
import android.os.Bundle;
import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

public class MainActivity extends FlutterActivity {
  private static final String CHANNEL = "video_player_example/pip";
  private MethodChannel methodChannel;

  @Override
  public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
    super.configureFlutterEngine(flutterEngine);
    
    // Set up method channel for PiP callbacks
    methodChannel = new MethodChannel(flutterEngine.getDartExecutor().getBinaryMessenger(), CHANNEL);
  }

  @Override
  public void onUserLeaveHint() {
    super.onUserLeaveHint();
    
    // Notify Flutter side that user is leaving
    if (methodChannel != null) {
      methodChannel.invokeMethod("onUserLeaveHint", null);
    }
  }

  @Override
  public void onPictureInPictureModeChanged(boolean isInPictureInPictureMode) {
    super.onPictureInPictureModeChanged(isInPictureInPictureMode);
    
    // Notify Flutter side of PiP mode change
    if (methodChannel != null) {
      methodChannel.invokeMethod("onPictureInPictureModeChanged", isInPictureInPictureMode);
    }
  }
}