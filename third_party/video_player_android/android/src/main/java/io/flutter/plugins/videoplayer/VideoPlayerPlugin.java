// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import android.content.Context;
import android.util.LongSparseArray;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import io.flutter.FlutterInjector;
import io.flutter.Log;
import io.flutter.embedding.engine.plugins.FlutterPlugin;
import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.EventChannel;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;
import io.flutter.plugins.videoplayer.Messages.AndroidVideoPlayerApi;
import io.flutter.plugins.videoplayer.Messages.CreationOptions;
import io.flutter.plugins.videoplayer.Messages.PlatformVideoFormat;
import io.flutter.plugins.videoplayer.Messages.TexturePlayerIds;
import io.flutter.plugins.videoplayer.Messages.VideoPlayerInstanceApi;
import io.flutter.plugins.videoplayer.platformview.PlatformVideoViewFactory;
import io.flutter.plugins.videoplayer.platformview.PlatformViewVideoPlayer;
import io.flutter.plugins.videoplayer.texture.TextureVideoPlayer;
import io.flutter.view.TextureRegistry;
import java.util.HashMap;
import java.util.Map;

/** Android platform implementation of the VideoPlayerPlugin. */
public class VideoPlayerPlugin implements FlutterPlugin, AndroidVideoPlayerApi {
  private static final String TAG = "VideoPlayerPlugin";
  private final LongSparseArray<VideoPlayer> videoPlayers = new LongSparseArray<>();
  private FlutterState flutterState;
  private final VideoPlayerOptions sharedOptions = new VideoPlayerOptions();
  private long nextPlayerIdentifier = 1;

  /**
   * 侧信道：把 ExoPlayer 自己的网络统计（实时下载速度估算 / 当前视频轨码率）暴露给 Dart。
   *
   * <p>没有走 Pigeon 生成的 {@code AndroidVideoPlayerApi}：那是代码生成产物，
   * 手改会和 {@code pigeons/messages.dart} 里的定义脱节。单开一条 MethodChannel
   * 完全独立，不碰任何既有接口。
   */
  private static final String NETWORK_STATS_CHANNEL = "com.zy.player/video_network_stats";

  private MethodChannel networkStatsChannel;

  /** Register this with the v2 embedding for the plugin to respond to lifecycle callbacks. */
  public VideoPlayerPlugin() {}

  @Override
  public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
    final FlutterInjector injector = FlutterInjector.instance();
    this.flutterState =
        new FlutterState(
            binding.getApplicationContext(),
            binding.getBinaryMessenger(),
            injector.flutterLoader()::getLookupKeyForAsset,
            injector.flutterLoader()::getLookupKeyForAsset,
            binding.getTextureRegistry());
    flutterState.startListening(this, binding.getBinaryMessenger());

    networkStatsChannel =
        new MethodChannel(binding.getBinaryMessenger(), NETWORK_STATS_CHANNEL);
    networkStatsChannel.setMethodCallHandler(this::onNetworkStatsCall);

    binding
        .getPlatformViewRegistry()
        .registerViewFactory(
            "plugins.flutter.dev/video_player_android",
            new PlatformVideoViewFactory(videoPlayers::get));
  }

  @Override
  public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {
    if (flutterState == null) {
      Log.wtf(TAG, "Detached from the engine before registering to it.");
    }
    flutterState.stopListening(binding.getBinaryMessenger());
    if (networkStatsChannel != null) {
      networkStatsChannel.setMethodCallHandler(null);
      networkStatsChannel = null;
    }
    flutterState = null;
    onDestroy();
  }

  private void disposeAllPlayers() {
    for (int i = 0; i < videoPlayers.size(); i++) {
      videoPlayers.valueAt(i).dispose();
    }
    videoPlayers.clear();
  }

  /**
   * 处理 {@link #NETWORK_STATS_CHANNEL} 上的调用。
   *
   * <p>目前只有 {@code getNetworkStats}：入参 {@code playerId}（Dart 侧传
   * {@code VideoPlayerController.playerId}，texture 路径下它就是这里的 playerId），
   * 返回 {speedBps, bitrateBps, idleMs, active}；
   * 找不到播放器时返回 null，Dart 侧会静默降级成不显示。
   */
  private void onNetworkStatsCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
    if (!"getNetworkStats".equals(call.method)) {
      result.notImplemented();
      return;
    }
    final Object rawId = call.argument("playerId");
    final long id = rawId instanceof Number ? ((Number) rawId).longValue() : -1L;
    final VideoPlayer player = id < 0 ? null : videoPlayers.get(id);
    if (player == null) {
      result.success(null);
      return;
    }
    final Map<String, Object> stats = new HashMap<>();
    stats.put("speedBps", player.getBandwidthEstimateBps());
    stats.put("bitrateBps", player.getVideoBitrateBps());
    stats.put("idleMs", player.getMillisecondsSinceLastSample());
    stats.put("active", player.isNetworkActive());
    result.success(stats);
  }


  public void onDestroy() {
    // The whole FlutterView is being destroyed. Here we release resources acquired for all
    // instances
    // of VideoPlayer. Once https://github.com/flutter/flutter/issues/19358 is resolved this may
    // be replaced with just asserting that videoPlayers.isEmpty().
    // https://github.com/flutter/flutter/issues/20989 tracks this.
    disposeAllPlayers();
  }

  @Override
  public void initialize() {
    disposeAllPlayers();
  }

  @Override
  public @NonNull Long createForPlatformView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    VideoPlayer videoPlayer =
        PlatformViewVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(createEventChannel(id)),
            videoAsset,
            sharedOptions);

    registerPlayerInstance(videoPlayer, id);
    return id;
  }

  @Override
  public @NonNull TexturePlayerIds createForTextureView(@NonNull CreationOptions options) {
    final VideoAsset videoAsset = videoAssetWithOptions(options);

    long id = nextPlayerIdentifier++;
    TextureRegistry.SurfaceProducer handle = flutterState.textureRegistry.createSurfaceProducer();
    VideoPlayer videoPlayer =
        TextureVideoPlayer.create(
            flutterState.applicationContext,
            VideoPlayerEventCallbacks.bindTo(createEventChannel(id)),
            handle,
            videoAsset,
            sharedOptions);

    registerPlayerInstance(videoPlayer, id);
    return new TexturePlayerIds.Builder().setPlayerId(id).setTextureId(handle.id()).build();
  }

  private @NonNull VideoAsset videoAssetWithOptions(@NonNull CreationOptions options) {
    final @NonNull String uri = options.getUri();
    if (uri.startsWith("asset:")) {
      return VideoAsset.fromAssetUrl(uri);
    } else if (uri.startsWith("rtsp:")) {
      return VideoAsset.fromRtspUrl(uri);
    } else {
      VideoAsset.StreamingFormat streamingFormat = VideoAsset.StreamingFormat.UNKNOWN;
      PlatformVideoFormat formatHint = options.getFormatHint();
      if (formatHint != null) {
        switch (formatHint) {
          case SS:
            streamingFormat = VideoAsset.StreamingFormat.SMOOTH;
            break;
          case DASH:
            streamingFormat = VideoAsset.StreamingFormat.DYNAMIC_ADAPTIVE;
            break;
          case HLS:
            streamingFormat = VideoAsset.StreamingFormat.HTTP_LIVE;
            break;
        }
      }
      return VideoAsset.fromRemoteUrl(
          uri, streamingFormat, options.getHttpHeaders(), options.getUserAgent());
    }
  }

  private void registerPlayerInstance(VideoPlayer player, long id) {
    // Set up the instance-specific API handler, and make sure it is removed when the player is
    // disposed.
    BinaryMessenger messenger = flutterState.binaryMessenger;
    final String channelSuffix = Long.toString(id);
    VideoPlayerInstanceApi.setUp(messenger, channelSuffix, player);
    player.setDisposeHandler(() -> VideoPlayerInstanceApi.setUp(messenger, channelSuffix, null));

    videoPlayers.put(id, player);
  }

  @NonNull
  private EventChannel createEventChannel(long id) {
    return new EventChannel(
        flutterState.binaryMessenger, "flutter.io/videoPlayer/videoEvents" + id);
  }

  @NonNull
  private VideoPlayer getPlayer(long playerId) {
    VideoPlayer player = videoPlayers.get(playerId);

    // Avoid a very ugly un-debuggable NPE that results in returning a null player.
    if (player == null) {
      String message = "No player found with playerId <" + playerId + ">";
      if (videoPlayers.size() == 0) {
        message += " and no active players created by the plugin.";
      }
      throw new IllegalStateException(message);
    }

    return player;
  }

  @Override
  public void dispose(@NonNull Long playerId) {
    VideoPlayer player = getPlayer(playerId);
    player.dispose();
    videoPlayers.remove(playerId);
  }

  @Override
  public void setMixWithOthers(@NonNull Boolean mixWithOthers) {
    sharedOptions.mixWithOthers = mixWithOthers;
  }

  @Override
  public @NonNull String getLookupKeyForAsset(@NonNull String asset, @Nullable String packageName) {
    return packageName == null
        ? flutterState.keyForAsset.get(asset)
        : flutterState.keyForAssetAndPackageName.get(asset, packageName);
  }

  private interface KeyForAssetFn {
    String get(String asset);
  }

  private interface KeyForAssetAndPackageName {
    String get(String asset, String packageName);
  }

  private static final class FlutterState {
    final Context applicationContext;
    final BinaryMessenger binaryMessenger;
    final KeyForAssetFn keyForAsset;
    final KeyForAssetAndPackageName keyForAssetAndPackageName;
    final TextureRegistry textureRegistry;

    FlutterState(
        Context applicationContext,
        BinaryMessenger messenger,
        KeyForAssetFn keyForAsset,
        KeyForAssetAndPackageName keyForAssetAndPackageName,
        TextureRegistry textureRegistry) {
      this.applicationContext = applicationContext;
      this.binaryMessenger = messenger;
      this.keyForAsset = keyForAsset;
      this.keyForAssetAndPackageName = keyForAssetAndPackageName;
      this.textureRegistry = textureRegistry;
    }

    void startListening(VideoPlayerPlugin methodCallHandler, BinaryMessenger messenger) {
      AndroidVideoPlayerApi.setUp(messenger, methodCallHandler);
    }

    void stopListening(BinaryMessenger messenger) {
      AndroidVideoPlayerApi.setUp(messenger, null);
    }
  }
}
