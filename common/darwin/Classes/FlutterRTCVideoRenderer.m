#import "FlutterRTCVideoRenderer.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CGImage.h>
#import <WebRTC/RTCYUVHelper.h>
#import <WebRTC/RTCYUVPlanarBuffer.h>
#import <WebRTC/WebRTC.h>

#import <objc/runtime.h>

#import "FlutterWebRTCPlugin.h"
#import <os/lock.h>

@implementation FlutterRTCVideoRenderer {
  CGSize _renderSize;
  CVPixelBufferRef _pixelBufferRef;
  CVPixelBufferPoolRef _pixelBufferPool;
  CGSize _poolSize;
  RTCVideoRotation _rotation;
  FlutterEventChannel* _eventChannel;
  bool _isFirstFrameRendered;
  bool _frameAvailable;
  os_unfair_lock _lock;
}

@synthesize textureId = _textureId;
@synthesize registry = _registry;
@synthesize eventSink = _eventSink;
@synthesize videoTrack = _videoTrack;

- (instancetype)initWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                              messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  self = [super init];
  if (self) {
    _lock = OS_UNFAIR_LOCK_INIT;
    _isFirstFrameRendered = false;
    _frameAvailable = false;
    _renderSize = CGSizeZero;
    _rotation = -1;
    _registry = registry;
    _pixelBufferRef = nil;
    _pixelBufferPool = NULL;
    _poolSize = CGSizeZero;
    _eventSink = nil;
    _rotation = -1;
    _textureId = [registry registerTexture:self];
    /*Create Event Channel.*/
    _eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/Texture%lld", _textureId]
             binaryMessenger:messenger];
    [_eventChannel setStreamHandler:self];
  }
  return self;
}

- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = nil;
  os_unfair_lock_lock(&_lock);
  if (_pixelBufferRef != nil && _frameAvailable) {
    buffer = CVBufferRetain(_pixelBufferRef);
    _frameAvailable = false;
  }
  os_unfair_lock_unlock(&_lock);
  return buffer;
}

- (void)dispose {
  [_eventChannel setStreamHandler:nil];
  _eventChannel = nil;
  os_unfair_lock_lock(&_lock);
  [_registry unregisterTexture:_textureId];
  _textureId = -1;
  if (_pixelBufferRef) {
    CVBufferRelease(_pixelBufferRef);
    _pixelBufferRef = nil;
  }
  CVPixelBufferPoolRelease(_pixelBufferPool);
  _pixelBufferPool = NULL;
  _frameAvailable = false;
  os_unfair_lock_unlock(&_lock);
}

- (RTCVideoTrack*)videoTrack {
  os_unfair_lock_lock(&_lock);
  RTCVideoTrack* videoTrack = _videoTrack;
  os_unfair_lock_unlock(&_lock);
  return videoTrack;
}

- (void)setVideoTrack:(RTCVideoTrack*)videoTrack {
  os_unfair_lock_lock(&_lock);
  RTCVideoTrack* oldValue = _videoTrack;
  _videoTrack = videoTrack;
  os_unfair_lock_unlock(&_lock);
  if (oldValue != videoTrack) {
    _isFirstFrameRendered = false;
    if (oldValue) {
      [oldValue removeRenderer:self];
    }
    _renderSize = CGSizeZero;
    _rotation = -1;
    if (videoTrack) {
      [videoTrack addRenderer:self];
    }
  }
}

- (void)copyI420ToCVPixelBuffer:(CVPixelBufferRef)outputPixelBuffer
                      withFrame:(RTCVideoFrame*)frame {
  id<RTCI420Buffer> i420Buffer = [frame.buffer toI420];
  CVPixelBufferLockBaseAddress(outputPixelBuffer, 0);

  const OSType pixelFormat = CVPixelBufferGetPixelFormatType(outputPixelBuffer);
  if (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
      pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
    // NV12
    uint8_t* dstY = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 0);
    const size_t dstYStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 0);
    uint8_t* dstUV = CVPixelBufferGetBaseAddressOfPlane(outputPixelBuffer, 1);
    const size_t dstUVStride = CVPixelBufferGetBytesPerRowOfPlane(outputPixelBuffer, 1);

    [RTCYUVHelper I420ToNV12:i420Buffer.dataY
                  srcStrideY:i420Buffer.strideY
                        srcU:i420Buffer.dataU
                  srcStrideU:i420Buffer.strideU
                        srcV:i420Buffer.dataV
                  srcStrideV:i420Buffer.strideV
                        dstY:dstY
                  dstStrideY:(int)dstYStride
                       dstUV:dstUV
                 dstStrideUV:(int)dstUVStride
                       width:i420Buffer.width
                      height:i420Buffer.height];

  } else {
    uint8_t* dst = CVPixelBufferGetBaseAddress(outputPixelBuffer);
    const size_t bytesPerRow = CVPixelBufferGetBytesPerRow(outputPixelBuffer);

    if (pixelFormat == kCVPixelFormatType_32BGRA) {
      // Corresponds to libyuv::FOURCC_ARGB

      [RTCYUVHelper I420ToARGB:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstARGB:dst
                 dstStrideARGB:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];

    } else if (pixelFormat == kCVPixelFormatType_32ARGB) {
      // Corresponds to libyuv::FOURCC_BGRA
      [RTCYUVHelper I420ToBGRA:i420Buffer.dataY
                    srcStrideY:i420Buffer.strideY
                          srcU:i420Buffer.dataU
                    srcStrideU:i420Buffer.strideU
                          srcV:i420Buffer.dataV
                    srcStrideV:i420Buffer.strideV
                       dstBGRA:dst
                 dstStrideBGRA:(int)bytesPerRow
                         width:i420Buffer.width
                        height:i420Buffer.height];
    }
  }

  CVPixelBufferUnlockBaseAddress(outputPixelBuffer, 0);
}

// Returns NULL once disposed, so no pool outlives dispose.
- (CVPixelBufferPoolRef)copyPixelBufferPoolForWidth:(int)width height:(int)height {
  CVPixelBufferPoolRef pool = NULL;
  os_unfair_lock_lock(&_lock);
  if (_textureId != -1) {
    if (_pixelBufferPool == NULL || _poolSize.width != width || _poolSize.height != height) {
      CVPixelBufferPoolRelease(_pixelBufferPool);
      _pixelBufferPool = NULL;
      NSDictionary* attributes = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(width),
        (id)kCVPixelBufferHeightKey : @(height),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
      };
      CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes,
                              &_pixelBufferPool);
      _poolSize = CGSizeMake(width, height);
    }
    pool = CVPixelBufferPoolRetain(_pixelBufferPool);
  }
  os_unfair_lock_unlock(&_lock);
  return pool;
}

// Hardware-decoded and camera frames go to Flutter as they are; the rest is converted to BGRA.
// Neither is rotated: the Dart widget rotates the texture.
- (CVPixelBufferRef)copyPixelBufferFromFrame:(RTCVideoFrame*)frame {
  if ([frame.buffer isKindOfClass:[RTCCVPixelBuffer class]]) {
    RTCCVPixelBuffer* buffer = (RTCCVPixelBuffer*)frame.buffer;
    const OSType pixelFormat = CVPixelBufferGetPixelFormatType(buffer.pixelBuffer);
    if (!buffer.requiresCropping && CVPixelBufferGetIOSurface(buffer.pixelBuffer) != NULL &&
        (pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
         pixelFormat == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange ||
         pixelFormat == kCVPixelFormatType_32BGRA)) {
      return CVPixelBufferRetain(buffer.pixelBuffer);
    }
  }

  CVPixelBufferPoolRef pool = [self copyPixelBufferPoolForWidth:frame.width height:frame.height];
  CVPixelBufferRef pixelBuffer = NULL;
  if (pool != NULL) {
    CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer);
    CVPixelBufferPoolRelease(pool);
  }
  if (pixelBuffer != NULL) {
    [self copyI420ToCVPixelBuffer:pixelBuffer withFrame:frame];
  }
  return pixelBuffer;
}

#pragma mark - RTCVideoRenderer methods
- (void)renderFrame:(RTCVideoFrame*)frame {

  os_unfair_lock_lock(&_lock);
  if(_videoTrack == nil) {
    os_unfair_lock_unlock(&_lock);
    return;
  }
  os_unfair_lock_unlock(&_lock);

  CVPixelBufferRef pixelBuffer = [self copyPixelBufferFromFrame:frame];
  os_unfair_lock_lock(&_lock);
  if (pixelBuffer != NULL && _textureId != -1) {
    CVPixelBufferRef previousPixelBuffer = _pixelBufferRef;
    _pixelBufferRef = pixelBuffer;
    pixelBuffer = previousPixelBuffer;
    _frameAvailable = true;
    [_registry textureFrameAvailable:_textureId];
  }
  os_unfair_lock_unlock(&_lock);
  CVBufferRelease(pixelBuffer);

  // Frames arrive on a decoder thread and this block runs later on the main
  // queue, so the renderer may already have been disposed and freed by the
  // time it runs. The weak reference is then nil and must not be dereferenced.
  __weak FlutterRTCVideoRenderer* weakSelf = self;
  if (_renderSize.width != frame.width || _renderSize.height != frame.height) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf != nil && strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeVideoSize",
          @"id" : @(strongSelf.textureId),
          @"width" : @(frame.width),
          @"height" : @(frame.height),
        });
      }
    });
    _renderSize = CGSizeMake(frame.width, frame.height);
  }

  if (frame.rotation != _rotation) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf != nil && strongSelf.eventSink) {
        strongSelf.eventSink(@{
          @"event" : @"didTextureChangeRotation",
          @"id" : @(strongSelf.textureId),
          @"rotation" : @(frame.rotation),
        });
      }
    });

    _rotation = frame.rotation;
  }

  // Notify Flutter once the first frame has been rendered.
  if (!_isFirstFrameRendered) {
    dispatch_async(dispatch_get_main_queue(), ^{
      FlutterRTCVideoRenderer* strongSelf = weakSelf;
      if (strongSelf == nil || strongSelf->_isFirstFrameRendered) {
        return;
      }
      if (strongSelf.eventSink) {
        strongSelf.eventSink(@{@"event" : @"didFirstFrameRendered"});
        strongSelf->_isFirstFrameRendered = true;
      }
    });
  }
}

// The size is the rotated one; buffers are sized per frame in renderFrame: instead.
- (void)setSize:(CGSize)size {
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  _eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
  _eventSink = sink;
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (FlutterVideoRendererManager)

- (FlutterRTCVideoRenderer*)createWithTextureRegistry:(id<FlutterTextureRegistry>)registry
                                            messenger:(NSObject<FlutterBinaryMessenger>*)messenger {
  return [[FlutterRTCVideoRenderer alloc] initWithTextureRegistry:registry messenger:messenger];
}

- (void)rendererSetSrcObject:(FlutterRTCVideoRenderer*)renderer stream:(RTCVideoTrack*)videoTrack {
  renderer.videoTrack = videoTrack;
}
@end
