import 'dart:async';

import 'package:flutter/services.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'event_channel.dart';
import 'media_stream_impl.dart';
import 'preferred_devices.dart';
import 'utils.dart';

class MediaDeviceNative extends MediaDevices {
  MediaDeviceNative._internal() {
    FlutterWebRTCEventChannel.instance.handleEvents.stream.listen((data) {
      var event = data.keys.first;
      Map<dynamic, dynamic> map = data.values.first;
      handleEvent(event, map);
    });
  }

  static final MediaDeviceNative instance = MediaDeviceNative._internal();

  void handleEvent(String event, final Map<dynamic, dynamic> map) async {
    switch (map['event']) {
      case 'onDeviceChange':
        ondevicechange?.call(null);
        break;
    }
  }

  @override
  Future<MediaStream> getUserMedia(
      Map<String, dynamic> mediaConstraints) async {
    try {
      final constraints = _withPreferredDevices(mediaConstraints);
      final response = await WebRTC.invokeMethod(
        'getUserMedia',
        <String, dynamic>{'constraints': constraints},
      );
      if (response == null) {
        throw Exception('getUserMedia return null, something wrong');
      }

      String streamId = response['streamId'];
      var stream = MediaStreamNative(streamId, 'local');
      stream.setMediaTracks(
          response['audioTracks'] ?? [], response['videoTracks'] ?? []);
      return stream;
    } on PlatformException catch (e) {
      throw 'Unable to getUserMedia: ${e.message}';
    }
  }

  @override
  Future<MediaStream> getDisplayMedia(
      Map<String, dynamic> mediaConstraints) async {
    try {
      final response = await WebRTC.invokeMethod(
        'getDisplayMedia',
        <String, dynamic>{'constraints': mediaConstraints},
      );
      if (response == null) {
        throw Exception('getDisplayMedia return null, something wrong');
      }
      String streamId = response['streamId'];
      var stream = MediaStreamNative(streamId, 'local');
      stream.setMediaTracks(response['audioTracks'], response['videoTracks']);
      return stream;
    } on PlatformException catch (e) {
      throw 'Unable to getDisplayMedia: ${e.message}';
    }
  }

  @override
  Future<List<dynamic>> getSources() async {
    try {
      final response = await WebRTC.invokeMethod(
        'getSources',
        <String, dynamic>{},
      );

      List<dynamic> sources = response['sources'];

      return sources;
    } on PlatformException catch (e) {
      throw 'Unable to getSources: ${e.message}';
    }
  }

  @override
  Future<List<MediaDeviceInfo>> enumerateDevices() async {
    var source = await getSources();
    return source
        .map(
          (e) => MediaDeviceInfo(
              deviceId: e['deviceId'],
              groupId: e['groupId'],
              kind: e['kind'],
              label: e['label']),
        )
        .toList();
  }

  @override
  Future<MediaDeviceInfo> selectAudioOutput(
      [AudioOutputOptions? options]) async {
    await WebRTC.invokeMethod('selectAudioOutput', {
      'deviceId': options?.deviceId,
    });
    // TODO(cloudwebrtc): return the selected device
    return MediaDeviceInfo(label: 'label', deviceId: options!.deviceId);
  }

  /// Injects [PreferredDevices.audioInputId]/[PreferredDevices.videoInputId]
  /// as `optional: [{'sourceId': id}]` constraints, but only for tracks the
  /// caller didn't already pin to a specific device — an explicit constraint
  /// always wins over the sticky preference.
  Map<String, dynamic> _withPreferredDevices(
      Map<String, dynamic> mediaConstraints) {
    final audioPreference = PreferredDevices.audioInputId;
    final videoPreference = PreferredDevices.videoInputId;
    if (audioPreference == null && videoPreference == null) {
      return mediaConstraints;
    }

    final constraints = Map<String, dynamic>.from(mediaConstraints);
    if (audioPreference != null && constraints.containsKey('audio')) {
      final audio =
          _injectPreferredSourceId(constraints['audio'], audioPreference);
      if (audio != null) constraints['audio'] = audio;
    }
    if (videoPreference != null && constraints.containsKey('video')) {
      final video =
          _injectPreferredSourceId(constraints['video'], videoPreference);
      if (video != null) constraints['video'] = video;
    }
    return constraints;
  }

  /// Returns a new constraint value with `sourceId` injected, or `null` if
  /// the track is disabled (`false`) or already pinned to a device
  /// (`deviceId`, `facingMode`, or an existing `sourceId`).
  dynamic _injectPreferredSourceId(dynamic trackConstraints, String deviceId) {
    if (trackConstraints == false) return null;

    if (trackConstraints == null || trackConstraints == true) {
      return {
        'optional': [
          {'sourceId': deviceId}
        ]
      };
    }

    if (trackConstraints is Map) {
      final map = Map<String, dynamic>.from(trackConstraints);
      if (map.containsKey('deviceId') || map.containsKey('facingMode')) {
        return null;
      }
      final mandatory = map['mandatory'];
      if (mandatory is Map && mandatory.containsKey('sourceId')) {
        return null;
      }
      final optional = map['optional'];
      if (optional is List &&
          optional.any((o) => o is Map && o.containsKey('sourceId'))) {
        return null;
      }
      map['optional'] = [
        if (optional is List) ...optional,
        {'sourceId': deviceId},
      ];
      return map;
    }

    return null;
  }
}
