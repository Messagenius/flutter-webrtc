import 'dart:async';

import 'package:flutter/services.dart';

import 'package:webrtc_interface/webrtc_interface.dart';

import 'utils.dart';

final _typeStringToMessageType = <String, MessageType>{
  'text': MessageType.text,
  'binary': MessageType.binary
};

/// A class that represents a WebRTC datachannel.
/// Can send and receive text and binary messages.
class RTCDataChannelNative extends RTCDataChannel {
  RTCDataChannelNative(
      this._peerConnectionId, this._label, this._dataChannelId, this._flutterId,
      {RTCDataChannelState? state}) {
    stateChangeStream = _stateChangeController.stream;
    messageStream = _messageController.stream;
    if (state != null) {
      _state = state;
    }
    _eventSubscription = _eventChannelFor(_peerConnectionId, _flutterId)
        .receiveBroadcastStream()
        .listen(eventListener, onError: errorListener);
  }
  final String _peerConnectionId;
  final String _label;
  int _bufferedAmount = 0;
  @override
  // ignore: overridden_fields
  int? bufferedAmountLowThreshold;

  /// Id for the datachannel in the Flutter <-> Native layer.
  final String _flutterId;

  int? _dataChannelId;
  RTCDataChannelState? _state;
  StreamSubscription<dynamic>? _eventSubscription;
  bool _isClosed = false;
  bool _closeComplete = false;
  Future<void>? _closeFuture;

  /// Whether native close has finished, so owners no longer need to await it.
  bool get isClosed => _closeComplete;

  @override
  RTCDataChannelState? get state => _state;

  @override
  int? get id => _dataChannelId;

  /// Get label.
  @override
  String? get label => _label;

  @override
  int? get bufferedAmount => _bufferedAmount;

  final _stateChangeController =
      StreamController<RTCDataChannelState>.broadcast(sync: true);
  final _messageController =
      StreamController<RTCDataChannelMessage>.broadcast(sync: true);

  /// RTCDataChannel event listener.
  void eventListener(dynamic event) {
    // Nothing to report once the channel is closed. The controller guards
    // below cover the other case, where the app's callback closes this channel
    // or its peer connection while the event is being delivered.
    if (_isClosed) {
      return;
    }
    final Map<dynamic, dynamic> map = event;
    switch (map['event']) {
      case 'dataChannelStateChanged':
        _dataChannelId = map['id'];
        final state = rtcDataChannelStateForString(map['state']);
        _state = state;
        onDataChannelState?.call(state);

        if (!_stateChangeController.isClosed) {
          _stateChangeController.add(state);
        }
        break;
      case 'dataChannelReceiveMessage':
        _dataChannelId = map['id'];

        var type = _typeStringToMessageType[map['type']];
        dynamic data = map['data'];
        RTCDataChannelMessage message;
        if (type == MessageType.binary) {
          message = RTCDataChannelMessage.fromBinary(data);
        } else {
          message = RTCDataChannelMessage(data);
        }

        onMessage?.call(message);

        if (!_messageController.isClosed) {
          _messageController.add(message);
        }
        break;

      case 'dataChannelBufferedAmountChange':
        _bufferedAmount = map['bufferedAmount'];
        if (bufferedAmountLowThreshold != null) {
          if (_bufferedAmount < bufferedAmountLowThreshold!) {
            onBufferedAmountLow?.call(_bufferedAmount);
          }
        }
        onBufferedAmountChange?.call(_bufferedAmount, map['changedAmount']);
        break;
    }
  }

  EventChannel _eventChannelFor(String peerConnectionId, String flutterId) {
    return EventChannel(
        'FlutterWebRTC/dataChannelEvent$peerConnectionId$flutterId');
  }

  void errorListener(Object obj) {
    if (obj is Exception) {
      throw obj;
    }
  }

  @override
  Future<int> getBufferedAmount() async {
    final Map<dynamic, dynamic> response = await WebRTC.invokeMethod(
        'dataChannelGetBufferedAmount', <String, dynamic>{
      'peerConnectionId': _peerConnectionId,
      'dataChannelId': _flutterId
    });
    _bufferedAmount = response['bufferedAmount'];
    return _bufferedAmount;
  }

  @override
  Future<void> send(RTCDataChannelMessage message) async {
    if (_isClosed) {
      throw Exception('Can\'t send: The RTCDataChannel is closed');
    }
    await WebRTC.invokeMethod('dataChannelSend', <String, dynamic>{
      'peerConnectionId': _peerConnectionId,
      'dataChannelId': _flutterId,
      'type': message.isBinary ? 'binary' : 'text',
      'data': message.isBinary ? message.binary : message.text,
    });
  }

  @override
  Future<void> close() {
    final closing = _closeFuture;
    if (closing != null) {
      return closing;
    }
    final notifyClosed = _state != RTCDataChannelState.RTCDataChannelClosed;
    _isClosed = true;
    _state = RTCDataChannelState.RTCDataChannelClosed;
    return _closeFuture = Future<void>.microtask(() => _close(notifyClosed))
        .whenComplete(() => _closeComplete = true);
  }

  Future<void> _close(bool notifyClosed) async {
    try {
      if (notifyClosed) {
        onDataChannelState?.call(_state!);
        _stateChangeController.add(_state!);
      }
    } finally {
      unawaited(_stateChangeController.close());
      unawaited(_messageController.close());
      try {
        await _eventSubscription?.cancel();
      } finally {
        await WebRTC.invokeMethod('dataChannelClose', <String, dynamic>{
          'peerConnectionId': _peerConnectionId,
          'dataChannelId': _flutterId
        });
      }
    }
  }
}
