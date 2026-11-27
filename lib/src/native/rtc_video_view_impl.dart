import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'rtc_video_renderer_impl.dart';

class RTCVideoView extends StatelessWidget {
  RTCVideoView(
    this._renderer, {
    super.key,
    this.objectFit = RTCVideoViewObjectFit.RTCVideoViewObjectFitContain,
    this.mirror = false,
    this.filterQuality = FilterQuality.low,
    this.placeholderBuilder,
  });

  final RTCVideoRenderer _renderer;
  final RTCVideoViewObjectFit objectFit;
  final bool mirror;
  final FilterQuality filterQuality;
  final WidgetBuilder? placeholderBuilder;

  RTCVideoRenderer get videoRenderer => _renderer;

  bool get _rotatesTexture =>
      defaultTargetPlatform == TargetPlatform.iOS ||
      defaultTargetPlatform == TargetPlatform.macOS;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) =>
            _buildVideoView(context, constraints));
  }

  Widget _buildVideoView(BuildContext context, BoxConstraints constraints) {
    return Center(
      child: Container(
        width: constraints.maxWidth,
        height: constraints.maxHeight,
        child: FittedBox(
          clipBehavior: Clip.hardEdge,
          fit: objectFit == RTCVideoViewObjectFit.RTCVideoViewObjectFitContain
              ? BoxFit.contain
              : BoxFit.cover,
          child: Center(
            child: ValueListenableBuilder<RTCVideoValue>(
              valueListenable: videoRenderer,
              builder:
                  (BuildContext context, RTCVideoValue value, Widget? child) {
                return SizedBox(
                  width: constraints.maxHeight * value.aspectRatio,
                  height: constraints.maxHeight,
                  child: Transform(
                    transform: Matrix4.identity()..rotateY(mirror ? -pi : 0.0),
                    alignment: FractionalOffset.center,
                    child: videoRenderer.renderVideo
                        ? RotatedBox(
                            // Only iOS/macOS textures arrive unrotated.
                            quarterTurns:
                                _rotatesTexture ? value.rotation ~/ 90 : 0,
                            child: Texture(
                              textureId: videoRenderer.textureId!,
                              filterQuality: filterQuality,
                            ),
                          )
                        : placeholderBuilder?.call(context) ?? Container(),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
