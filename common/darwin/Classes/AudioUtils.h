#if TARGET_OS_IPHONE

#import <WebRTC/WebRTC.h>

@interface AudioUtils : NSObject
+ (void)ensureAudioSessionWithRecording:(BOOL)recording;
// needed for wired headphones to use headphone mic
+ (BOOL)selectAudioInput:(AVAudioSessionPort)type;
// selects by port UID, distinguishing devices that share a portType (e.g. two
// bluetooth headsets); returns NO and does nothing if the UID isn't currently
// available (caller should retry once it reappears).
+ (BOOL)selectAudioInputWithUID:(NSString*)uid;
+ (void)clearPreferredInput;
+ (void)setSpeakerphoneOn:(BOOL)enable;
+ (void)setSpeakerphoneOnButPreferBluetooth;
+ (void)deactiveRtcAudioSession;
+ (void) setAppleAudioConfiguration:(NSDictionary*)configuration;
// Resets the shared WebRTC configuration's mode/options to what the app set
// via setAppleAudioConfiguration (WebRTC's voiceChat default otherwise),
// undoing what a call's speaker preference wrote there.
+ (void)restoreAppleAudioConfiguration;
// Configures category/mode/options for the AVAudioEngine-based audio device
// module right before it enables voice processing (RTCAudioDeviceModuleDelegate
// audioDeviceModule:willEnableEngine:...). This is the only reliable place to
// steer initial routing (earpiece vs. speaker) on that ADM: unlike the legacy
// ADM, it never re-applies RTCAudioSessionConfiguration.webRTCConfiguration and
// never calls audioSessionDidStartPlayOrRecord:, so category/options set at any
// other time are wiped out when Voice Processing I/O is enabled.
+ (void)configureAudioSessionForEngineWithRecording:(BOOL)recording
                                  speakerPreferenceSet:(BOOL)speakerPreferenceSet
                                              speakerOn:(BOOL)speakerOn
                                       preferBluetooth:(BOOL)preferBluetooth;
@end

#endif
