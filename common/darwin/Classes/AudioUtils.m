#if TARGET_OS_IPHONE
#import "AudioUtils.h"
#import <AVFoundation/AVFoundation.h>

@implementation AudioUtils

+ (void)ensureAudioSessionWithRecording:(BOOL)recording {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  // we also need to set default WebRTC audio configuration, since it may be activated after
  // this method is called
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  // require audio session to be either PlayAndRecord or MultiRoute
  if (recording && session.category != AVAudioSessionCategoryPlayAndRecord &&
      session.category != AVAudioSessionCategoryMultiRoute) {
    config.category = AVAudioSessionCategoryPlayAndRecord;
    // Preserve a previously requested speaker preference (set via
    // setSpeakerphoneOn:) — WebRTC re-applies this configuration when its audio
    // unit starts, so dropping the bit here would revert the route to earpiece.
    config.categoryOptions =
        AVAudioSessionCategoryOptionAllowBluetooth |
        AVAudioSessionCategoryOptionAllowBluetoothA2DP |
        AVAudioSessionCategoryOptionAllowAirPlay |
        (config.categoryOptions & AVAudioSessionCategoryOptionDefaultToSpeaker);

    [session lockForConfiguration];
    NSError* error = nil;
    bool success = [session setCategory:config.category withOptions:config.categoryOptions error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[true]: setCategory failed due to: %@", error);
    success = [session setMode:config.mode error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[true]: setMode failed due to: %@", error);
    [session unlockForConfiguration];
  } else if (!recording && (session.category == AVAudioSessionCategoryAmbient ||
                            session.category == AVAudioSessionCategorySoloAmbient)) {
    config.mode = AVAudioSessionModeDefault;
    [session lockForConfiguration];
    NSError* error = nil;
    bool success = [session setMode:config.mode error:&error];
    if (!success)
      NSLog(@"ensureAudioSessionWithRecording[false]: setMode failed due to: %@", error);
    [session unlockForConfiguration];
  }
}

+ (BOOL)selectAudioInput:(AVAudioSessionPort)type {
  RTCAudioSession* rtcSession = [RTCAudioSession sharedInstance];
  AVAudioSessionPortDescription* inputPort = nil;
  for (AVAudioSessionPortDescription* port in rtcSession.session.availableInputs) {
    if ([port.portType isEqualToString:type]) {
      inputPort = port;
      break;
    }
  }
  if (inputPort != nil) {
    NSError* errOut = nil;
    [rtcSession lockForConfiguration];
    [rtcSession setPreferredInput:inputPort error:&errOut];
    [rtcSession unlockForConfiguration];
    if (errOut != nil) {
      return NO;
    }
    return YES;
  }
  return NO;
}

+ (BOOL)selectAudioInputWithUID:(NSString*)uid {
  RTCAudioSession* rtcSession = [RTCAudioSession sharedInstance];
  AVAudioSessionPortDescription* inputPort = nil;
  for (AVAudioSessionPortDescription* port in rtcSession.session.availableInputs) {
    if ([port.UID isEqualToString:uid]) {
      inputPort = port;
      break;
    }
  }
  if (inputPort == nil) {
    return NO;
  }
  NSError* errOut = nil;
  [rtcSession lockForConfiguration];
  [rtcSession setPreferredInput:inputPort error:&errOut];
  [rtcSession unlockForConfiguration];
  if (errOut != nil) {
    NSLog(@"selectAudioInputWithUID: setPreferredInput failed due to: %@", errOut);
    return NO;
  }
  return YES;
}

+ (void)setSpeakerphoneOn:(BOOL)enable {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  if(enable && config.category != AVAudioSessionCategoryPlayAndRecord) {
    NSLog(@"setSpeakerphoneOn: Category option 'defaultToSpeaker' is only applicable with category 'playAndRecord', switching category.");
    config.category = AVAudioSessionCategoryPlayAndRecord;
  }

  // Persist the speaker preference into the shared WebRTC configuration so
  // later reconfiguration (e.g. ensureAudioSessionWithRecording:) doesn't
  // drop it. category/options alone are not enough to steer routing once
  // Voice Processing I/O is enabled — mode matters too: videoChat defaults to
  // the speaker, voiceChat defaults to the earpiece.
  config.categoryOptions = AVAudioSessionCategoryOptionAllowAirPlay |
                            AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                            AVAudioSessionCategoryOptionAllowBluetooth |
                            (enable ? AVAudioSessionCategoryOptionDefaultToSpeaker : 0);
  config.mode = enable ? AVAudioSessionModeVideoChat : AVAudioSessionModeVoiceChat;

  [session lockForConfiguration];
  NSError* error = nil;
  BOOL success = [session setCategory:config.category
                                  mode:config.mode
                               options:config.categoryOptions
                                 error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOn: setCategory:mode:options: failed due to: %@", error);

  success = [session overrideOutputAudioPort:enable ? AVAudioSessionPortOverrideSpeaker
                                                     : AVAudioSessionPortOverrideNone
                                        error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOn: Port override failed due to: %@", error);
  [session unlockForConfiguration];
}

+ (void)setSpeakerphoneOnButPreferBluetooth {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];
  config.categoryOptions = AVAudioSessionCategoryOptionAllowAirPlay |
                            AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                            AVAudioSessionCategoryOptionAllowBluetooth |
                            AVAudioSessionCategoryOptionDefaultToSpeaker;
  config.mode = AVAudioSessionModeVideoChat;

  [session lockForConfiguration];
  NSError* error = nil;
  BOOL success = [session setCategory:config.category
                                  mode:config.mode
                               options:config.categoryOptions
                                 error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: setCategory:mode:options: failed due to: %@", error);

  // No port override: with AllowBluetooth set, iOS routes to a connected
  // bluetooth device automatically; DefaultToSpeaker only takes effect when
  // none is connected.
  success = [session overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: Port override failed due to: %@", error);

  success = [session setActive:YES error:&error];
  if (!success)
    NSLog(@"setSpeakerphoneOnButPreferBluetooth: Audio session override failed: %@", error);
  [session unlockForConfiguration];
}

+ (void)configureAudioSessionForEngineWithRecording:(BOOL)recording
                                speakerPreferenceSet:(BOOL)speakerPreferenceSet
                                            speakerOn:(BOOL)speakerOn
                                     preferBluetooth:(BOOL)preferBluetooth {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  AVAudioSessionCategory category = recording ? AVAudioSessionCategoryPlayAndRecord : config.category;
  // Start from the shared config so options the app set via
  // setAppleAudioConfiguration (mixWithOthers, defaultToSpeaker, ...) survive;
  // with no speaker preference the app-configured mode decides routing
  // (voiceChat → earpiece, videoChat → speaker).
  AVAudioSessionCategoryOptions options = config.categoryOptions |
                                           AVAudioSessionCategoryOptionAllowBluetooth |
                                           AVAudioSessionCategoryOptionAllowBluetoothA2DP |
                                           AVAudioSessionCategoryOptionAllowAirPlay;
  AVAudioSessionMode mode = config.mode;

  if (speakerPreferenceSet) {
    if (speakerOn) {
      options |= AVAudioSessionCategoryOptionDefaultToSpeaker;
      mode = AVAudioSessionModeVideoChat;
    } else if (!preferBluetooth) {
      options &= ~AVAudioSessionCategoryOptionDefaultToSpeaker;
      mode = AVAudioSessionModeVoiceChat;
    }
  }

  config.category = category;
  config.categoryOptions = options;
  config.mode = mode;

  [session lockForConfiguration];
  NSError* error = nil;
  BOOL success = [session setCategory:category mode:mode options:options error:&error];
  if (!success)
    NSLog(@"configureAudioSessionForEngine: setCategory:mode:options: failed due to: %@", error);
  [session unlockForConfiguration];
}

+ (void)deactiveRtcAudioSession {
  NSError* error = nil;
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  [session lockForConfiguration];
  if ([session isActive]) {
    BOOL success = [session setActive:NO error:&error];
    if (!success)
      NSLog(@"RTC Audio session deactive failed: %@", error);
    else
      NSLog(@"RTC AudioSession deactive is successful ");
  }
  [session unlockForConfiguration];
}


+ (AVAudioSessionMode)audioSessionModeFromString:(NSString*)mode {
  if([@"default_" isEqualToString:mode]) {
    return AVAudioSessionModeDefault;
  } else if([@"voicePrompt" isEqualToString:mode]) {
    return AVAudioSessionModeVoicePrompt;
  } else if([@"videoRecording" isEqualToString:mode]) {
    return AVAudioSessionModeVideoRecording;
  } else if([@"videoChat" isEqualToString:mode]) {
    return AVAudioSessionModeVideoChat;
  } else if([@"voiceChat" isEqualToString:mode]) {
    return AVAudioSessionModeVoiceChat;
  } else if([@"gameChat" isEqualToString:mode]) {
    return AVAudioSessionModeGameChat;
  } else if([@"measurement" isEqualToString:mode]) {
    return AVAudioSessionModeMeasurement;
  } else if([@"moviePlayback" isEqualToString:mode]) {
    return AVAudioSessionModeMoviePlayback;
  } else if([@"spokenAudio" isEqualToString:mode]) {
    return AVAudioSessionModeSpokenAudio;
  } 
  return AVAudioSessionModeDefault;
}

+ (AVAudioSessionCategory)audioSessionCategoryFromString:(NSString *)category {
  if([@"ambient" isEqualToString:category]) {
    return AVAudioSessionCategoryAmbient;
  } else if([@"soloAmbient" isEqualToString:category]) {
    return AVAudioSessionCategorySoloAmbient;
  } else if([@"playback" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayback;
  } else if([@"record" isEqualToString:category]) {
    return AVAudioSessionCategoryRecord;
  } else if([@"playAndRecord" isEqualToString:category]) {
    return AVAudioSessionCategoryPlayAndRecord;
  } else if([@"multiRoute" isEqualToString:category]) {
    return AVAudioSessionCategoryMultiRoute;
  }
  return AVAudioSessionCategoryAmbient;
}

+ (void) setAppleAudioConfiguration:(NSDictionary*)configuration {
  RTCAudioSession* session = [RTCAudioSession sharedInstance];
  RTCAudioSessionConfiguration* config = [RTCAudioSessionConfiguration webRTCConfiguration];

  NSString* appleAudioCategory = configuration[@"appleAudioCategory"];
  NSArray* appleAudioCategoryOptions = configuration[@"appleAudioCategoryOptions"];
  NSString* appleAudioMode = configuration[@"appleAudioMode"];
  
  [session lockForConfiguration];

  if(appleAudioCategoryOptions != nil) {
    config.categoryOptions = 0;
    for(NSString* option in appleAudioCategoryOptions) {
      if([@"mixWithOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionMixWithOthers;
      } else if([@"duckOthers" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDuckOthers;
      } else if([@"allowBluetooth" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetooth;
      } else if([@"allowBluetoothA2DP" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowBluetoothA2DP;
      } else if([@"allowAirPlay" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionAllowAirPlay;
      } else if([@"defaultToSpeaker" isEqualToString:option]) {
        config.categoryOptions |= AVAudioSessionCategoryOptionDefaultToSpeaker;
      }
    }
  }

  if(appleAudioCategory != nil) {
    config.category = [AudioUtils audioSessionCategoryFromString:appleAudioCategory];
    [session setCategory:config.category withOptions:config.categoryOptions error:nil];
  }

  if(appleAudioMode != nil) {
    config.mode = [AudioUtils audioSessionModeFromString:appleAudioMode];
    [session setMode:config.mode error:nil];
  }

  [session unlockForConfiguration];

}

@end
#endif
