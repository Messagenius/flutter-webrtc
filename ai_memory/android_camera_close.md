# Opening a camera while it closes (Android)

Opening the same camera twice from one process makes cameraserver take it from the first session, which hits a
Camera2 framework bug (`CameraAccessException(CAMERA_ERROR=3)`). `GetUserMediaImpl` avoids it in two ways:

- **Sharing.** `getUserVideo` (platform thread) scans `mVideoCapturers` under `synchronized (mVideoCapturers)`. If the
  camera is already active, it builds a shared track on the existing `VideoSource` instead of opening it again.
- **Closing set.** `removeVideoCapturer` (plugin executor) unregisters a primary capturer and adds its camera name to
  `closingCameras` in the same lock, before the blocking `stopCapture()` + `waitForCameraClosed()`. A closing capturer
  is never shared. The name is removed in the `finally`, after the capturer is stopped and disposed.

When the camera `getUserVideo` is about to start is in `closingCameras`, it registers the capturer and posts
`startCapture` to the executor. The executor is the thread blocked in the close, so the start runs after the close.
Otherwise `startCapture` runs at once, on the platform thread.

All `removeVideoCapturer` calls run on the executor (`trackDispose`, `streamDispose`, `disposeOnExecutor`). A removal
queued after a deferred start runs after it (FIFO).
