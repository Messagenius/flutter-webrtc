import 'dart:async';

import 'package:flutter/services.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:flutter_webrtc/src/native/rtc_data_channel_impl.dart';
import 'package:flutter_webrtc/src/native/rtc_peerconnection_impl.dart';

/// A peer connection hands out data channel objects that each hold an event
/// channel subscription and two stream controllers. Nothing else closes them,
/// so dispose() has to, and it has to do that before the peer connection goes
/// away because the native dataChannelClose looks the channel up through the
/// connection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const peerConnectionId = 'pc-data-channel-test';
  const createdChannelId = 'dc-created';
  const receivedChannelId = 'dc-received';

  final methodChannel = MethodChannel('FlutterWebRTC.Method');
  final peerConnectionEventChannel =
      MethodChannel('FlutterWebRTC/peerConnectionEvent$peerConnectionId');
  final dataChannelEventChannels = <String, MethodChannel>{
    for (final flutterId in [createdChannelId, receivedChannelId])
      flutterId: MethodChannel(
          'FlutterWebRTC/dataChannelEvent$peerConnectionId$flutterId'),
  };

  final calls = <String>[];

  /// Thrown out of the next dataChannelClose the platform is asked for, so a
  /// test can pick the failure the teardown has to survive.
  Object? dataChannelCloseError;

  /// Runs once, on the next dataChannelClose the platform is asked for, so a
  /// test can make something happen while dispose() is awaiting that call.
  void Function()? duringDataChannelClose;
  Future<void>? dataChannelCloseWait;

  setUp(() {
    calls.clear();
    dataChannelCloseError = null;
    duringDataChannelClose = null;
    dataChannelCloseWait = null;

    methodChannel.setMockMethodCallHandler((MethodCall methodCall) async {
      switch (methodCall.method) {
        case 'createDataChannel':
          calls.add('createDataChannel');
          return <String, dynamic>{'id': 1, 'flutterId': createdChannelId};
        case 'dataChannelClose':
          final arguments = methodCall.arguments as Map<dynamic, dynamic>;
          calls.add('dataChannelClose:${arguments['dataChannelId']}');
          final hook = duringDataChannelClose;
          duringDataChannelClose = null;
          hook?.call();
          final wait = dataChannelCloseWait;
          dataChannelCloseWait = null;
          await wait;
          final error = dataChannelCloseError;
          dataChannelCloseError = null;
          if (error != null) {
            throw error;
          }
          return null;
        default:
          calls.add(methodCall.method);
          return null;
      }
    });

    peerConnectionEventChannel
        .setMockMethodCallHandler((MethodCall methodCall) async {
      calls.add('pcEvent:${methodCall.method}');
      return null;
    });

    dataChannelEventChannels.forEach((flutterId, channel) {
      channel.setMockMethodCallHandler((MethodCall methodCall) async {
        calls.add('dcEvent:$flutterId:${methodCall.method}');
        return null;
      });
    });
  });

  tearDown(() {
    methodChannel.setMockMethodCallHandler(null);
    peerConnectionEventChannel.setMockMethodCallHandler(null);
    dataChannelEventChannels.forEach((_, channel) {
      channel.setMockMethodCallHandler(null);
    });
  });

  test('dispose closes a created data channel before the peer connection',
      () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});

    // Let the constructor's subscription reach the platform side.
    await Future<void>.delayed(Duration.zero);

    await pc.createDataChannel('data', RTCDataChannelInit());
    await Future<void>.delayed(Duration.zero);

    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(
        calls,
        containsAllInOrder(<String>[
          'dcEvent:$createdChannelId:listen',
          'dcEvent:$createdChannelId:cancel',
          'dataChannelClose:$createdChannelId',
          'pcEvent:cancel',
          'peerConnectionDispose',
        ]));
  });

  test('dispose closes a data channel received from the platform', () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    pc.eventListener(<dynamic, dynamic>{
      'event': 'didOpenDataChannel',
      'id': 2,
      'label': 'remote',
      'flutterId': receivedChannelId,
    });
    await Future<void>.delayed(Duration.zero);

    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(
        calls,
        containsAllInOrder(<String>[
          'dcEvent:$receivedChannelId:listen',
          'dcEvent:$receivedChannelId:cancel',
          'dataChannelClose:$receivedChannelId',
          'pcEvent:cancel',
          'peerConnectionDispose',
        ]));
  });

  test('dispose does not close a data channel the app already closed',
      () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    final dataChannel =
        await pc.createDataChannel('data', RTCDataChannelInit());
    await Future<void>.delayed(Duration.zero);

    await dataChannel.close();
    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(calls.where((call) => call == 'dataChannelClose:$createdChannelId'),
        hasLength(1));
    expect(calls.where((call) => call == 'dcEvent:$createdChannelId:cancel'),
        hasLength(1));
    expect(calls, contains('peerConnectionDispose'));
  });

  test('dispose closes a data channel that arrives during teardown', () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    await pc.createDataChannel('data', RTCDataChannelInit());
    await Future<void>.delayed(Duration.zero);

    // The platform can still deliver a channel while dispose() is awaiting
    // the close of the previous one. That channel has to be closed too, and
    // appending to the list must not break the teardown loop.
    duringDataChannelClose = () {
      pc.eventListener(<dynamic, dynamic>{
        'event': 'didOpenDataChannel',
        'id': 2,
        'label': 'remote',
        'flutterId': receivedChannelId,
      });
    };

    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(calls, contains('dataChannelClose:$createdChannelId'));
    expect(calls, contains('dataChannelClose:$receivedChannelId'));
    expect(calls, contains('peerConnectionDispose'));
  });

  test('a closed callback disposes the peer once, after closing its channel',
      () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    final dataChannel = await pc.createDataChannel('data', RTCDataChannelInit())
        as RTCDataChannelNative;
    await Future<void>.delayed(Duration.zero);

    Future<void>? disposed;
    var closedNotifications = 0;
    final streamStates = <RTCDataChannelState>[];
    dataChannel.stateChangeStream.listen(streamStates.add);
    dataChannel.onDataChannelState = (state) {
      closedNotifications++;
      disposed ??= pc.dispose();
    };

    dataChannel.eventListener(<dynamic, dynamic>{
      'event': 'dataChannelStateChanged',
      'id': 1,
      'state': 'closed',
    });

    await disposed;
    await Future<void>.delayed(Duration.zero);

    expect(closedNotifications, 1);
    expect(streamStates, [RTCDataChannelState.RTCDataChannelClosed]);
    expect(
        calls.where((call) => call == 'peerConnectionDispose'), hasLength(1));
    expect(calls.where((call) => call == 'dataChannelClose:$createdChannelId'),
        hasLength(1));
    expect(calls.indexOf('dataChannelClose:$createdChannelId'),
        lessThan(calls.indexOf('peerConnectionDispose')));
  });

  for (final stream in ['state', 'message']) {
    test('dispose completes while the $stream stream is paused', () async {
      final pc = RTCPeerConnectionNative(peerConnectionId, {});
      final dataChannel =
          await pc.createDataChannel('data', RTCDataChannelInit());
      final events = <dynamic>[];
      var streamDone = false;
      final publicStream = stream == 'state'
          ? dataChannel.stateChangeStream
          : dataChannel.messageStream;
      final subscription =
          publicStream.listen(events.add, onDone: () => streamDone = true);
      subscription.pause();

      var completed = false;
      final disposal = pc.dispose().then((_) => completed = true);
      await Future<void>.delayed(Duration.zero);
      final completedWhilePaused = completed;
      final nativeDisposedWhilePaused = calls.contains('peerConnectionDispose');
      subscription.resume();
      await disposal;
      await Future<void>.delayed(Duration.zero);
      await subscription.cancel();

      expect(completedWhilePaused, isTrue);
      expect(nativeDisposedWhilePaused, isTrue);
      expect(streamDone, isTrue);
      expect(
          events,
          stream == 'state'
              ? [RTCDataChannelState.RTCDataChannelClosed]
              : isEmpty);
    });
  }

  test('concurrent dispose calls share one teardown', () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await pc.createDataChannel('data', RTCDataChannelInit());

    final first = pc.dispose();
    final second = pc.dispose();
    await Future.wait([first, second]);

    expect(identical(first, second), isTrue);
    expect(
        calls.where((call) => call == 'peerConnectionDispose'), hasLength(1));
    expect(calls.where((call) => call == 'dataChannelClose:$createdChannelId'),
        hasLength(1));
  });

  test('dispose waits for an already closing channel when another arrives',
      () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    final dataChannel =
        await pc.createDataChannel('data', RTCDataChannelInit());
    final nativeClose = Completer<void>();
    dataChannelCloseWait = nativeClose.future;
    final closing = dataChannel.close();
    await Future<void>.delayed(Duration.zero);

    pc.eventListener(<dynamic, dynamic>{
      'event': 'didOpenDataChannel',
      'id': 2,
      'label': 'remote',
      'flutterId': receivedChannelId,
    });
    final disposal = pc.dispose();
    await Future<void>.delayed(Duration.zero);
    final disposedBeforeClose = calls.contains('peerConnectionDispose');
    nativeClose.complete();
    await Future.wait([closing, disposal]);

    expect(disposedBeforeClose, isFalse);
    expect(
        calls.where((call) => call == 'peerConnectionDispose'), hasLength(1));
    expect(calls.where((call) => call == 'dataChannelClose:$createdChannelId'),
        hasLength(1));
  });

  test('dispose completes when closing a data channel fails', () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    await pc.createDataChannel('data', RTCDataChannelInit());
    await Future<void>.delayed(Duration.zero);

    dataChannelCloseError =
        PlatformException(code: 'error', message: 'peerConnection is null');

    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(calls, contains('dataChannelClose:$createdChannelId'));
    expect(
        calls,
        containsAllInOrder(<String>[
          'pcEvent:cancel',
          'peerConnectionDispose',
        ]));
  });

  test('dispose completes when the close plugin call is missing', () async {
    final pc = RTCPeerConnectionNative(peerConnectionId, {});
    await Future<void>.delayed(Duration.zero);

    await pc.createDataChannel('data', RTCDataChannelInit());
    await Future<void>.delayed(Duration.zero);

    // MissingPluginException is not a PlatformException, so a catch narrowed
    // to the latter would let it abort the teardown.
    dataChannelCloseError = MissingPluginException('dataChannelClose');

    await pc.dispose();
    await Future<void>.delayed(Duration.zero);

    expect(calls, contains('dataChannelClose:$createdChannelId'));
    expect(
        calls,
        containsAllInOrder(<String>[
          'pcEvent:cancel',
          'peerConnectionDispose',
        ]));
  });
}
