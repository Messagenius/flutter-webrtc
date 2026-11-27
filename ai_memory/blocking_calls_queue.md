# Blocking calls run on a serial queue (iOS/macOS)

Method-channel handlers run on the platform thread, which is also Flutter's UI thread. Some handlers wait on
another thread or process:

- WebRTC proxies (`track.isEnabled`, `stream.videoTracks`, `addRenderer:`/`removeRenderer:`, `statistics...`,
  `localDescription`/`remoteDescription`) wait on the signaling or worker thread. While the audio engine starts there
  (hundreds of ms), every such call waits.
- `AVAudioSession` calls (`setCategory`, `setActive`, `availableInputs`) wait on the audio server.

These run on `FlutterWebRTCPlugin.blockingQueue` (serial, user-initiated) through `runBlocking:result:`. The handler
looks up tracks, streams and renderers on the platform thread (the dictionaries are not thread-safe), then queues only
the blocking call. `done` hands the result back on the main thread.

| Group | Handlers |
|---|---|
| Tracks | `mediaStreamTrackSetEnable`, `setMicrophoneMute` |
| Stats | `getStats` (the audio-level poll runs every 500 ms during a call) |
| Descriptions | `getLocalDescription`, `getRemoteDescription` (the app reads the remote one per incoming ICE candidate) |
| Peer connection | `createPeerConnection`, `addTrack`, `getSenders`, `addCandidate`, `peerConnectionClose`, `peerConnectionDispose` |
| Renderers | `videoRendererSetSrcObject`, `videoRendererDispose`, the `videoTrack = nil` in `streamDispose` and `trackDispose` |
| Audio session (iOS) | `getSources`, `selectAudioInput`, `selectAudioOutput`, `enableSpeakerphone`, `enableSpeakerphoneButPreferBluetooth`, `setAppleAudioConfiguration`, `ensureAudioSession`, `clearPreferredAudioInput`, `deactiveRtcAudioSession` |

Rules:

- One queue, so these calls keep their order. Speaker preference flags are still set on the platform thread before
  queueing, so the engine callbacks see the new preference at once.
- `createPeerConnection` builds the connection on the queue, then registers it (`flutterId`, event channel,
  `peerConnections`) on the main thread before replying. Dart learns the id only from that reply, so nothing looks it
  up earlier, and its delegate callbacks post nothing until Dart listens on the event channel.
- `peerConnectionClose` / `peerConnectionDispose` run only `close` on the queue, after the calls queued earlier for that
  connection. The clean-up (`closedByPlugin`, remote maps, data-channel delegates, and on dispose the event channels and
  the `peerConnections` entry) then runs on the main thread before the reply, after the close-time delegate callbacks.
- `setVideoTrack:` is only called on the queue; the renderer guards `videoTrack` with its lock.
- `streamDispose` / `trackDispose` snapshot `renders` on the platform thread and match the track id on the queue, so a
  `videoRendererSetSrcObject` queued earlier has already been applied.
- The call-end reset of the shared WebRTC configuration runs on the queue, after any pending speaker change. It restores
  the mode/options the app set through `setAppleAudioConfiguration`.
- A renderer is removed from `renders` at once, and `dispose` (texture unregister) runs on the main thread after its
  queued track change.
- The audio-engine callbacks (`willEnableEngine:`, `willStartEngine:`) stay synchronous on WebRTC's worker thread.
- macOS keeps its audio-device branches of `getSources` / `selectAudioInput` / `selectAudioOutput` on the platform
  thread.

Not moved yet: `streamDispose` / `trackDispose` still read `stream.videoTracks` / `audioTracks` on the platform thread.
