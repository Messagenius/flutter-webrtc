/// Sticky device preferences requested before a call is connected.
///
/// `getUserMedia` reads these to pick a camera/microphone when the caller
/// did not specify a device explicitly in the constraints, so a selection
/// made via [Helper.setPreferredCamera]/[Helper.selectAudioInput] before the
/// call starts still takes effect once it does.
class PreferredDevices {
  static String? audioInputId;
  static String? videoInputId;
}
