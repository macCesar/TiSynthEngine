#import <Foundation/Foundation.h>
#include "../../shared/synth_sequence.h"
#include "../../shared/synth_variation.h"
#include "../../shared/synth_effects.h"

@interface TiSynthengineContract : NSObject

+ (NSDictionary *)prepareVariation:(NSDictionary *)options config:(SynthVariation *)config;
+ (NSDictionary *)validateStart:(NSDictionary *)options;
+ (NSDictionary *)validateSetVolume:(NSDictionary *)options;
+ (NSDictionary *)validateNoteOn:(NSDictionary *)options maxFrequency:(double)maxFrequency;
+ (NSDictionary *)validateNoteOff:(NSDictionary *)options;
+ (NSDictionary *)validateUpdateVoice:(NSDictionary *)options maxFrequency:(double)maxFrequency;
+ (NSDictionary *)validateTone:(NSDictionary *)options maxFrequency:(double)maxFrequency;
+ (NSDictionary *)validateChord:(NSDictionary *)options maxFrequency:(double)maxFrequency;
+ (NSDictionary *)defaultsWithMaxFrequency:(double)maxFrequency;

+ (NSDictionary *)sequenceStateObject:(const SynthSequenceState *)state;
+ (NSMutableDictionary *)mergeSequenceVoice:(NSDictionary *)previous changes:(NSDictionary *)changes;
+ (NSDictionary *)prepareSequence:(NSDictionary *)options config:(SynthSequenceConfig *)config maxFrequency:(double)maxFrequency;
+ (NSDictionary *)prepareMasterProcessing:(NSDictionary *)options config:(SynthEffectsConfig *)config;
+ (NSDictionary *)prepareModulations:(id)options values:(double *)values waveType:(int)wave filterType:(int)filter;
@end
