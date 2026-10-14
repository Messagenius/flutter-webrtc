import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:flutter_webrtc/src/native/rtc_peerconnection_impl.dart';
import 'package:flutter_webrtc/src/native/utils.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('FlutterWebRTC.Method');
  const eventChannel = MethodChannel('FlutterWebRTC/peerConnectionEventtest-peer');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late RTCPeerConnectionNative peerConnection;
  late List<MethodCall> calls;
  PlatformException? candidateError;

  setUp(() {
    calls = [];
    candidateError = null;
    WebRTC.initialized = true;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (call.method == 'addCandidate' && candidateError != null) {
        throw candidateError!;
      }
      return null;
    });
    messenger.setMockMethodCallHandler(eventChannel, (_) async => null);
    peerConnection = RTCPeerConnectionNative('test-peer', {});
  });

  tearDown(() async {
    await peerConnection.dispose();
    messenger.setMockMethodCallHandler(channel, null);
    messenger.setMockMethodCallHandler(eventChannel, null);
    WebRTC.initialized = false;
  });

  for (final candidate in [
    RTCIceCandidate(null, null, null),
    RTCIceCandidate('', null, null),
    RTCIceCandidate('', 'video', 1),
  ]) {
    test('does not send end-of-candidates ${candidate.toMap()} to native WebRTC', () async {
      await peerConnection.addCandidate(candidate);

      expect(calls, isEmpty);
    });
  }

  test('preserves a valid candidate payload', () async {
    const sdp = 'candidate:1 1 udp 2122260223 192.0.2.1 54321 typ host';
    await peerConnection.addCandidate(RTCIceCandidate(sdp, 'video', 1));

    expect(calls, hasLength(1));
    expect(calls.single.method, 'addCandidate');
    expect(calls.single.arguments, {
      'peerConnectionId': 'test-peer',
      'candidate': {
        'candidate': sdp,
        'sdpMid': 'video',
        'sdpMLineIndex': 1,
      },
    });
  });

  for (final message in ['Invalid candidate', 'Peer connection is closed', 'Peer connection not found']) {
    test('preserves native error: $message', () async {
      candidateError = PlatformException(code: 'addCandidateFailed', message: message);

      await expectLater(
        peerConnection.addCandidate(RTCIceCandidate('nonempty-candidate', 'video', 1)),
        throwsA('Unable to RTCPeerConnection::addCandidate: $message'),
      );
      expect(calls.single.method, 'addCandidate');
    });
  }
}
