#import "TiModule.h"

@interface TiSynthengineModule : TiModule

// Return the shared JS export before Titanium's automatic create* factory.
- (id)createSound;

// Internal entry-layer hooks; public Sound methods are shared CommonJS assets.
- (NSDictionary *)_soundRuntime:(id)args;
- (NSDictionary *)_validateSoundOptions:(id)args;
- (NSNumber *)_soundNoteToMidi:(id)args;
- (NSNumber *)_allocateSoundNote:(id)args;
- (NSNumber *)_soundHeld:(id)args;
- (NSNumber *)_updateSoundOptions:(id)args;

- (NSDictionary *)getStats:(id)args;
- (NSNumber *)enableStats:(id)args;
- (NSNumber *)disableStats:(id)args;
// Deprecated: use enableStats()/disableStats().
- (NSNumber *)setStatsEnabled:(id)args;
- (void)resetStats:(id)args;
- (NSDictionary *)getDefaults:(id)args;
- (NSNumber *)start:(id)args;
- (NSNumber *)setVolume:(id)args;
- (NSNumber *)playTone:(id)args;
- (NSNumber *)repeatTone:(id)args;
- (NSNumber *)updateTone:(id)args;
- (NSNumber *)stopTone:(id)args;
- (NSNumber *)noteOn:(id)args;
- (NSNumber *)noteOff:(id)args;
- (NSNumber *)updateNote:(id)args;
// Deprecated: use updateNote().
- (NSNumber *)updateVoice:(id)args;
- (NSNumber *)playChord:(id)args;
- (void)stopAll:(id)args;
- (void)shutdown:(id)args;

- (NSNumber *)setTempo:(id)args;
- (NSNumber *)playSequence:(id)args;
- (NSNumber *)updateSequence:(id)args;
- (NSNumber *)stopSequence:(id)args;
- (NSDictionary *)getSequenceState:(id)args;
- (NSNumber *)setMasterProcessing:(id)args;
@end
