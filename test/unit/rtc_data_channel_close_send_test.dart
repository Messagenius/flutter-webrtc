import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:flutter_webrtc/src/native/rtc_data_channel_impl.dart';

/// close() has to establish a terminal Dart-side state and reject any send()
/// issued afterward locally, rather than leaving `state` stale and letting
/// the send reach the platform channel after native teardown. See #2156.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peerConnectionId = 'pc-data-channel-close-send-test';
  const flutterId = 'dc-close-send';

  final methodChannel = MethodChannel('FlutterWebRTC.Method');
  final eventChannel = MethodChannel(
      'FlutterWebRTC/dataChannelEvent$peerConnectionId$flutterId');

  final calls = <String>[];

  setUp(() {
    calls.clear();
    methodChannel.setMockMethodCallHandler((MethodCall methodCall) async {
      calls.add(methodCall.method);
      return null;
    });
    eventChannel.setMockMethodCallHandler((MethodCall methodCall) async {
      return null;
    });
  });

  tearDown(() {
    methodChannel.setMockMethodCallHandler(null);
    eventChannel.setMockMethodCallHandler(null);
  });

  test('close() transitions state to closed', () async {
    final dataChannel = RTCDataChannelNative(
        peerConnectionId, 'label', 1, flutterId,
        state: RTCDataChannelState.RTCDataChannelOpen);
    await Future<void>.delayed(Duration.zero);

    expect(dataChannel.state, RTCDataChannelState.RTCDataChannelOpen);

    await dataChannel.close();

    expect(dataChannel.state, RTCDataChannelState.RTCDataChannelClosed);
  });

  test(
      'send() after close() is rejected locally and never reaches the platform channel',
      () async {
    final dataChannel = RTCDataChannelNative(
        peerConnectionId, 'label', 1, flutterId,
        state: RTCDataChannelState.RTCDataChannelOpen);
    await Future<void>.delayed(Duration.zero);

    await dataChannel.close();
    calls.clear();

    await expectLater(
        () => dataChannel.send(RTCDataChannelMessage('late message')),
        throwsA(isA<Exception>()
            .having((e) => e.toString(), 'message', contains('closed'))));

    expect(calls, isNot(contains('dataChannelSend')));
  });

  test('reentrant close shares completion and notifies closed once', () async {
    final dataChannel = RTCDataChannelNative(
        peerConnectionId, 'label', 1, flutterId,
        state: RTCDataChannelState.RTCDataChannelOpen);
    final streamStates = <RTCDataChannelState>[];
    dataChannel.stateChangeStream.listen(streamStates.add);
    var notifications = 0;
    Future<void>? reentrantClose;
    dataChannel.onDataChannelState = (_) {
      notifications++;
      reentrantClose = dataChannel.close();
    };

    final closing = dataChannel.close();
    expect(dataChannel.state, RTCDataChannelState.RTCDataChannelClosed);
    await expectLater(dataChannel.send(RTCDataChannelMessage('late')),
        throwsA(isA<Exception>()));
    await closing;

    expect(identical(closing, reentrantClose), isTrue);
    expect(notifications, 1);
    expect(streamStates, [RTCDataChannelState.RTCDataChannelClosed]);
    expect(calls.where((call) => call == 'dataChannelClose'), hasLength(1));
    expect(calls, isNot(contains('dataChannelSend')));
  });

  test('closing inside a synchronous stream listener still tears down',
      () async {
    final dataChannel = RTCDataChannelNative(
        peerConnectionId, 'label', 1, flutterId,
        state: RTCDataChannelState.RTCDataChannelConnecting);
    final streamStates = <RTCDataChannelState>[];
    Future<void>? closing;
    dataChannel.stateChangeStream.listen((state) {
      streamStates.add(state);
      closing ??= dataChannel.close();
    });

    dataChannel.eventListener(<String, dynamic>{
      'event': 'dataChannelStateChanged',
      'id': 1,
      'state': 'open',
    });
    await closing;

    expect(streamStates, [
      RTCDataChannelState.RTCDataChannelOpen,
      RTCDataChannelState.RTCDataChannelClosed,
    ]);
    expect(calls.where((call) => call == 'dataChannelClose'), hasLength(1));
  });

  test(
      'close() notifies stateChangeStream listeners and onDataChannelState of the closed state',
      () async {
    final dataChannel = RTCDataChannelNative(
        peerConnectionId, 'label', 1, flutterId,
        state: RTCDataChannelState.RTCDataChannelOpen);
    await Future<void>.delayed(Duration.zero);

    final streamStates = <RTCDataChannelState>[];
    dataChannel.stateChangeStream.listen(streamStates.add);
    RTCDataChannelState? callbackState;
    dataChannel.onDataChannelState = (state) => callbackState = state;

    await dataChannel.close();

    expect(streamStates, contains(RTCDataChannelState.RTCDataChannelClosed));
    expect(callbackState, RTCDataChannelState.RTCDataChannelClosed);
  });
}
