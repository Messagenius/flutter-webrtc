package com.cloudwebrtc.webrtc;

import android.graphics.SurfaceTexture;
import android.view.Surface;

import org.webrtc.EglBase;
import org.webrtc.EglRenderer;
import org.webrtc.GlRectDrawer;
import org.webrtc.RendererCommon;
import org.webrtc.ThreadUtils;
import org.webrtc.VideoFrame;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;

import io.flutter.view.TextureRegistry;

/**
 * Display the video stream on a Surface.
 * renderFrame() is asynchronous to avoid blocking the calling thread.
 * This class is thread safe and handles access from potentially three different threads:
 * Interaction from the plugin executor in init and release.
 * Interaction from C++ rtc::VideoSinkInterface in renderFrame.
 * Interaction from SurfaceHolder lifecycle in surfaceCreated, surfaceChanged, and surfaceDestroyed.
 */
public class SurfaceTextureRenderer extends EglRenderer {
  // Callback for reporting renderer events. Read-only after initilization so no lock required.
  private RendererCommon.RendererEvents rendererEvents;
  private final Object layoutLock = new Object();
  private boolean isRenderingPaused;
  private boolean isFirstFrameRendered;
  private int rotatedFrameWidth;
  private int rotatedFrameHeight;
  private int frameRotation;

  /**
   * In order to render something, you must first call init().
   */
  public SurfaceTextureRenderer(String name, Executor executor) {
    super(name);
    this.executor = executor;
  }

  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents) {
    init(sharedContext, rendererEvents, EglBase.CONFIG_PLAIN, new GlRectDrawer());
  }

  /**
   * Initialize this class, sharing resources with |sharedContext|. The custom |drawer| will be used
   * for drawing frames on the EGLSurface. This class is responsible for calling release() on
   * |drawer|. It is allowed to call init() to reinitialize the renderer after a previous
   * init()/release() cycle.
   */
  public void init(final EglBase.Context sharedContext,
                   RendererCommon.RendererEvents rendererEvents, final int[] configAttributes,
                   RendererCommon.GlDrawer drawer) {
    this.rendererEvents = rendererEvents;
    synchronized (layoutLock) {
      isFirstFrameRendered = false;
      rotatedFrameWidth = 0;
      rotatedFrameHeight = 0;
      frameRotation = -1;
    }
    super.init(sharedContext, configAttributes, drawer);
  }
  @Override
  public void init(final EglBase.Context sharedContext, final int[] configAttributes,
                   RendererCommon.GlDrawer drawer) {
    init(sharedContext, null /* rendererEvents */, configAttributes, drawer);
  }
  /**
   * Limit render framerate.
   *
   * @param fps Limit render framerate to this value, or use Float.POSITIVE_INFINITY to disable fps
   *            reduction.
   */
  @Override
  public void setFpsReduction(float fps) {
    synchronized (layoutLock) {
      isRenderingPaused = fps == 0f;
    }
    super.setFpsReduction(fps);
  }
  @Override
  public void disableFpsReduction() {
    synchronized (layoutLock) {
      isRenderingPaused = false;
    }
    super.disableFpsReduction();
  }
  @Override
  public void pauseVideo() {
    synchronized (layoutLock) {
      isRenderingPaused = true;
    }
    super.pauseVideo();
  }
  // VideoSink interface.
  @Override
  public void onFrame(VideoFrame frame) {
    synchronized (surfaceLock) {
      if (released || !surfaceAvailable) {
        return;
      }
      if(surface == null) {
        producer.setSize(frame.getRotatedWidth(),frame.getRotatedHeight());
        surface = producer.getSurface();
        createEglSurface(surface);
      } else if (frameSizeChanged(frame)) {
        // The producer's backing buffers are fixed-size: setSize() only takes
        // effect for a Surface obtained afterwards. Without recreating the EGL
        // surface here, a simulcast layer upgrade keeps rendering into the old
        // low-resolution buffer and the video stays blurry.
        releaseEglSurface(() -> {});
        // Clear the field before re-obtaining: if getSurface() throws, the
        // next frame takes the surface == null path and recreates cleanly
        // rather than rendering into the already-released surface.
        surface = null;
        producer.setSize(frame.getRotatedWidth(), frame.getRotatedHeight());
        surface = producer.getSurface();
        createEglSurface(surface);
      }
    }
    updateFrameDimensionsAndReportEvents(frame);
    super.onFrame(frame);
  }

  private boolean frameSizeChanged(VideoFrame frame) {
    synchronized (layoutLock) {
      return !isRenderingPaused
          && (rotatedFrameWidth != frame.getRotatedWidth()
              || rotatedFrameHeight != frame.getRotatedHeight());
    }
  }

  private final Object surfaceLock = new Object();
  private final Executor executor;
  private Surface surface = null;
  private boolean released = true;
  private boolean surfaceAvailable = true;
  private int rendererGeneration;
  private int cleanupGeneration;

  private TextureRegistry.SurfaceProducer producer;

  @Override
  public void release() {
    synchronized (surfaceLock) {
      released = true;
      rendererGeneration++;
      surface = null;
    }
    super.release();
  }

  public void surfaceCreated(final TextureRegistry.SurfaceProducer producer) {
    ThreadUtils.checkIsOnMainThread();
    synchronized (surfaceLock) {
      this.producer = producer;
      released = false;
    }
    producer.setCallback(
            new TextureRegistry.SurfaceProducer.Callback() {
              @Override
              public void onSurfaceAvailable() {
                final int generation;
                synchronized (surfaceLock) {
                  generation = cleanupGeneration;
                }
                executor.execute(() -> {
                  synchronized (surfaceLock) {
                    if (generation == cleanupGeneration) {
                      surfaceAvailable = true;
                    }
                  }
                });
              }

              @Override
              public void onSurfaceCleanup() {
                final int generation;
                synchronized (surfaceLock) {
                  surfaceAvailable = false;
                  cleanupGeneration++;
                  generation = rendererGeneration;
                }
                executor.execute(() -> surfaceDestroyed(generation));
              }
            }
    );
  }

  private void surfaceDestroyed(int generation) {
    final CountDownLatch completionLatch = new CountDownLatch(1);
    synchronized (surfaceLock) {
      if (generation != rendererGeneration) {
        return;
      }
      releaseEglSurface(completionLatch::countDown);
      surface = null;
    }
    ThreadUtils.awaitUninterruptibly(completionLatch);
  }

  // Update frame dimensions and report any changes to |rendererEvents|.
  private void updateFrameDimensionsAndReportEvents(VideoFrame frame) {
    synchronized (layoutLock) {
      if (isRenderingPaused) {
        return;
      }
      if (!isFirstFrameRendered) {
        isFirstFrameRendered = true;
        if (rendererEvents != null) {
          rendererEvents.onFirstFrameRendered();
        }
      }
      if (rotatedFrameWidth != frame.getRotatedWidth()
              || rotatedFrameHeight != frame.getRotatedHeight()
              || frameRotation != frame.getRotation()) {
        if (rendererEvents != null) {
          rendererEvents.onFrameResolutionChanged(
                  frame.getBuffer().getWidth(), frame.getBuffer().getHeight(), frame.getRotation());
        }
        rotatedFrameWidth = frame.getRotatedWidth();
        rotatedFrameHeight = frame.getRotatedHeight();
        frameRotation = frame.getRotation();
      }
    }
  }
}
