// RTCVideoView rotates the texture by the renderer's rotation on iOS/macOS only.
// No failure cases: the rotation comes from a native event and the widget has no error path.
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:webrtc_interface/webrtc_interface.dart';

import 'package:flutter_webrtc/src/native/rtc_video_renderer_impl.dart';
import 'package:flutter_webrtc/src/native/rtc_video_view_impl.dart';

class _FakeMediaStream extends Fake implements MediaStream {
  @override
  String get id => 'stream';

  @override
  String get ownerTag => 'local';
}

const int _textureId = 7;

final TargetPlatformVariant _darwin = TargetPlatformVariant(
    <TargetPlatform>{TargetPlatform.iOS, TargetPlatform.macOS});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final TestDefaultBinaryMessenger messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), (MethodCall call) async {
      if (call.method == 'createVideoRenderer') {
        return <String, dynamic>{'textureId': _textureId};
      }
      return null;
    });
    for (final String name in <String>[
      'FlutterWebRTC/Texture$_textureId',
      'FlutterWebRTC.Event'
    ]) {
      messenger.setMockStreamHandler(
          EventChannel(name),
          MockStreamHandler.inline(
              onListen:
                  (Object? arguments, MockStreamHandlerEventSink events) {}));
    }
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(
        const MethodChannel('FlutterWebRTC.Method'), null);
    for (final String name in <String>[
      'FlutterWebRTC/Texture$_textureId',
      'FlutterWebRTC.Event'
    ]) {
      messenger.setMockStreamHandler(EventChannel(name), null);
    }
  });

  Future<RTCVideoRenderer> pumpView(WidgetTester tester,
      {required int rotation, bool mirror = false}) async {
    final RTCVideoRenderer renderer = RTCVideoRenderer();
    await renderer.initialize();
    await renderer.setSrcObject(stream: _FakeMediaStream());
    renderer.eventListener(<String, dynamic>{
      'event': 'didTextureChangeVideoSize',
      'width': 640,
      'height': 480
    });
    renderer.eventListener(<String, dynamic>{
      'event': 'didTextureChangeRotation',
      'rotation': rotation
    });
    await tester.pumpWidget(RTCVideoView(renderer, mirror: mirror));
    addTearDown(renderer.dispose);
    return renderer;
  }

  int quarterTurns(WidgetTester tester) =>
      tester.widget<RotatedBox>(find.byType(RotatedBox)).quarterTurns;

  group('RTCVideoView rotation - normal cases', () {
    for (final int rotation in <int>[0, 90, 180, 270]) {
      testWidgets(
          'rotation $rotation turns the texture ${rotation ~/ 90} quarter turns on iOS and macOS',
          (WidgetTester tester) async {
        // Arrange
        await pumpView(tester, rotation: rotation);

        // Act
        final int turns = quarterTurns(tester);

        // Assert
        expect(turns, rotation ~/ 90);
        expect(
            find.descendant(
                of: find.byType(RotatedBox), matching: find.byType(Texture)),
            findsOneWidget);
      }, variant: _darwin);

      testWidgets('rotation $rotation leaves the texture unrotated on Android',
          (WidgetTester tester) async {
        // Arrange
        await pumpView(tester, rotation: rotation);

        // Act
        final int turns = quarterTurns(tester);

        // Assert
        expect(turns, 0);
      }, variant: TargetPlatformVariant.only(TargetPlatform.android));
    }

    testWidgets('mirror on flips the rotated texture',
        (WidgetTester tester) async {
      // Arrange
      await pumpView(tester, rotation: 90, mirror: true);

      // Act
      final Transform transform =
          tester.widget<Transform>(find.byType(Transform));

      // Assert
      expect(transform.transform, Matrix4.identity()..rotateY(-pi));
      expect(
          find.descendant(
              of: find.byType(Transform), matching: find.byType(RotatedBox)),
          findsOneWidget);
      expect(quarterTurns(tester), 1);
    }, variant: _darwin);

    testWidgets('mirror off keeps the identity transform',
        (WidgetTester tester) async {
      // Arrange
      await pumpView(tester, rotation: 90);

      // Act
      final Transform transform =
          tester.widget<Transform>(find.byType(Transform));

      // Assert
      expect(transform.transform, Matrix4.identity());
      expect(
          find.descendant(
              of: find.byType(Transform), matching: find.byType(RotatedBox)),
          findsOneWidget);
      expect(quarterTurns(tester), 1);
    }, variant: _darwin);
  });

  group('RTCVideoView rotation - edge cases', () {
    testWidgets('a rotation change updates the quarter turns',
        (WidgetTester tester) async {
      // Arrange
      final RTCVideoRenderer renderer = await pumpView(tester, rotation: 270);

      // Act
      renderer.eventListener(<String, dynamic>{
        'event': 'didTextureChangeRotation',
        'rotation': 0
      });
      await tester.pump();

      // Assert
      expect(quarterTurns(tester), 0);
    }, variant: _darwin);

    testWidgets('portrait rotation swaps the view aspect ratio',
        (WidgetTester tester) async {
      // Arrange
      await pumpView(tester, rotation: 90);

      // Act
      final Size size = tester.getSize(find.byType(RotatedBox));

      // Assert
      expect(size.width / size.height, closeTo(480 / 640, 0.001));
    }, variant: _darwin);

    testWidgets('Windows and Linux leave the texture unrotated',
        (WidgetTester tester) async {
      // Arrange
      await pumpView(tester, rotation: 90);

      // Act
      final int turns = quarterTurns(tester);

      // Assert
      expect(turns, 0);
    },
        variant: TargetPlatformVariant(
            <TargetPlatform>{TargetPlatform.windows, TargetPlatform.linux}));

    testWidgets('the placeholder is not rotated', (WidgetTester tester) async {
      // Arrange
      final RTCVideoRenderer renderer = RTCVideoRenderer();
      await renderer.initialize();
      addTearDown(renderer.dispose);
      renderer.eventListener(<String, dynamic>{
        'event': 'didTextureChangeRotation',
        'rotation': 90
      });

      // Act
      await tester.pumpWidget(RTCVideoView(renderer,
          placeholderBuilder: (_) => const SizedBox.shrink()));

      // Assert
      expect(find.byType(RotatedBox), findsNothing);
      expect(find.byType(Texture), findsNothing);
    }, variant: _darwin);
  });
}
