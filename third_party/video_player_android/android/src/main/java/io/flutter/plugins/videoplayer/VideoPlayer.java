// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import static androidx.media3.common.Player.REPEAT_MODE_ALL;
import static androidx.media3.common.Player.REPEAT_MODE_OFF;

import android.os.SystemClock;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.media3.common.AudioAttributes;
import androidx.media3.common.C;
import androidx.media3.common.Format;
import androidx.media3.common.MediaItem;
import androidx.media3.common.PlaybackParameters;
import androidx.media3.exoplayer.ExoPlayer;
import androidx.media3.exoplayer.analytics.AnalyticsListener;
import androidx.media3.exoplayer.source.LoadEventInfo;
import androidx.media3.exoplayer.source.MediaLoadData;
import io.flutter.view.TextureRegistry.SurfaceProducer;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;

/**
 * A class responsible for managing video playback using {@link ExoPlayer}.
 *
 * <p>It provides methods to control playback, adjust volume, and handle seeking.
 */
public abstract class VideoPlayer implements Messages.VideoPlayerInstanceApi {
  @NonNull protected final VideoPlayerCallbacks videoPlayerEvents;
  @Nullable protected final SurfaceProducer surfaceProducer;
  @Nullable private DisposeHandler disposeHandler;
  @NonNull protected ExoPlayer exoPlayer;

  // ---- 网络统计（供「显示实时下载速度」使用，由 MethodChannel 侧信道查询）----

  /** ExoPlayer 带宽计估算的下载速度，单位 bit/s。 */
  private volatile long bandwidthEstimateBps;
  /** 当前视频轨道的码率，单位 bit/s；部分源不提供则为 0。 */
  private volatile long videoBitrateBps;
  /** 上一次拿到带宽采样的时刻（SystemClock.elapsedRealtime），0 表示还没采过样。 */
  private volatile long lastSampleRealtimeMs;
  /** 正在进行的网络请求数，>0 表示此刻确实在下载。 */
  private final AtomicInteger activeLoads = new AtomicInteger();

  /** A closure-compatible signature since {@link java.util.function.Supplier} is API level 24. */
  public interface ExoPlayerProvider {
    /**
     * Returns a new {@link ExoPlayer}.
     *
     * @return new instance.
     */
    @NonNull
    ExoPlayer get();
  }

  /** A handler to run when dispose is called. */
  public interface DisposeHandler {
    void onDispose();
  }

  public VideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @Nullable SurfaceProducer surfaceProducer,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    this.videoPlayerEvents = events;
    this.surfaceProducer = surfaceProducer;
    exoPlayer = exoPlayerProvider.get();
    exoPlayer.setMediaItem(mediaItem);
    exoPlayer.prepare();
    exoPlayer.addListener(createExoPlayerEventListener(exoPlayer, surfaceProducer));
    setUpNetworkStatsListener(exoPlayer);
    setAudioAttributes(exoPlayer, options.mixWithOthers);
  }

  /**
   * 挂一个 {@link AnalyticsListener} 记录网速与码率。
   *
   * <p>用 ExoPlayer 自己的带宽计（{@code DefaultBandwidthMeter}）：
   * {@code onBandwidthEstimate} 的最后一个参数就是它对近期几次 HTTP 传输做的加权估算，
   * 和 ExoPlayer 系播放器显示的「网络速度」是同一个数，比我们自己按字节数平均更贴近体感。
   *
   * <p>回调都在 App 的 looper 上派发，与 MethodChannel 调用同线程，
   * 加上字段是 volatile，所以不需要额外加锁。
   */
  private void setUpNetworkStatsListener(@NonNull ExoPlayer player) {
    player.addAnalyticsListener(
        new AnalyticsListener() {
          @Override
          public void onBandwidthEstimate(
              EventTime eventTime,
              int totalLoadTimeMs,
              long totalBytesLoaded,
              long bitrateEstimate) {
            bandwidthEstimateBps = bitrateEstimate;
            lastSampleRealtimeMs = SystemClock.elapsedRealtime();
          }

          @Override
          public void onDownstreamFormatChanged(EventTime eventTime, MediaLoadData mediaLoadData) {
            final Format format = mediaLoadData.trackFormat;
            if (mediaLoadData.trackType == C.TRACK_TYPE_VIDEO
                && format != null
                && format.bitrate > 0) {
              videoBitrateBps = format.bitrate;
            }
          }

          @Override
          public void onLoadStarted(
              EventTime eventTime, LoadEventInfo loadEventInfo, MediaLoadData mediaLoadData) {
            activeLoads.incrementAndGet();
          }

          @Override
          public void onLoadCompleted(
              EventTime eventTime, LoadEventInfo loadEventInfo, MediaLoadData mediaLoadData) {
            decrementActiveLoads();
          }

          @Override
          public void onLoadCanceled(
              EventTime eventTime, LoadEventInfo loadEventInfo, MediaLoadData mediaLoadData) {
            decrementActiveLoads();
          }

          @Override
          public void onLoadError(
              EventTime eventTime,
              LoadEventInfo loadEventInfo,
              MediaLoadData mediaLoadData,
              IOException error,
              boolean wasCanceled) {
            decrementActiveLoads();
          }
        });
  }

  private void decrementActiveLoads() {
    // 只在 >0 时减，避免回调顺序异常时计数变负
    if (activeLoads.get() > 0) {
      activeLoads.decrementAndGet();
    }
  }

  /** 最近一次带宽估算，bit/s。 */
  public long getBandwidthEstimateBps() {
    return bandwidthEstimateBps;
  }

  /** 当前视频轨码率，bit/s；没拿到则为 0。 */
  public long getVideoBitrateBps() {
    return videoBitrateBps;
  }

  /** 距上一次带宽采样过了多少毫秒；从没采过样返回 {@link Long#MAX_VALUE}。 */
  public long getMillisecondsSinceLastSample() {
    final long last = lastSampleRealtimeMs;
    return last == 0 ? Long.MAX_VALUE : SystemClock.elapsedRealtime() - last;
  }

  /** 此刻是否真的有网络请求在跑（缓冲已满时会变成 false）。 */
  public boolean isNetworkActive() {
    return activeLoads.get() > 0;
  }

  public void setDisposeHandler(@Nullable DisposeHandler handler) {
    disposeHandler = handler;
  }

  @NonNull
  protected abstract ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer);

  private static void setAudioAttributes(ExoPlayer exoPlayer, boolean isMixMode) {
    exoPlayer.setAudioAttributes(
        new AudioAttributes.Builder().setContentType(C.AUDIO_CONTENT_TYPE_MOVIE).build(),
        !isMixMode);
  }

  @Override
  public void play() {
    exoPlayer.play();
  }

  @Override
  public void pause() {
    exoPlayer.pause();
  }

  @Override
  public void setLooping(@NonNull Boolean looping) {
    exoPlayer.setRepeatMode(looping ? REPEAT_MODE_ALL : REPEAT_MODE_OFF);
  }

  @Override
  public void setVolume(@NonNull Double volume) {
    float bracketedValue = (float) Math.max(0.0, Math.min(1.0, volume));
    exoPlayer.setVolume(bracketedValue);
  }

  @Override
  public void setPlaybackSpeed(@NonNull Double speed) {
    // We do not need to consider pitch and skipSilence for now as we do not handle them and
    // therefore never diverge from the default values.
    final PlaybackParameters playbackParameters = new PlaybackParameters(speed.floatValue());

    exoPlayer.setPlaybackParameters(playbackParameters);
  }

  @Override
  public @NonNull Messages.PlaybackState getPlaybackState() {
    return new Messages.PlaybackState.Builder()
        .setPlayPosition(exoPlayer.getCurrentPosition())
        .setBufferPosition(exoPlayer.getBufferedPosition())
        .build();
  }

  @Override
  public void seekTo(@NonNull Long position) {
    exoPlayer.seekTo(position);
  }

  @NonNull
  public ExoPlayer getExoPlayer() {
    return exoPlayer;
  }

  public void dispose() {
    if (disposeHandler != null) {
      disposeHandler.onDispose();
    }
    exoPlayer.release();
  }
}
