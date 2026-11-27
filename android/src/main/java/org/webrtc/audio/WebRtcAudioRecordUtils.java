package org.webrtc.audio;

/**
 * It must be in this package, because WebRtcAudioRecord is package-private.
 * JavaAudioDeviceModule.setPreferredInputDevice(null) throws, as it logs device.getId().
 **/
public abstract class WebRtcAudioRecordUtils {

    public static void clearPreferredInputDevice(JavaAudioDeviceModule audioDeviceModule) {
        audioDeviceModule.audioInput.setPreferredDevice(null);
    }
}
