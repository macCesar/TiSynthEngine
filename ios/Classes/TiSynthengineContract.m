#import "TiSynthengineContract.h"
#import <math.h>

static const NSInteger ContractDefaultMaxVoices = 8;
static NSString *const ContractDefaultMixingProfile = @"conservative";
static NSString *const ContractDefaultAudioSession = @"playback";
static const double ContractDefaultFrequency = 440.0;
static const NSInteger ContractDefaultDuration = 500;
static const NSInteger ContractDefaultAttack = 50;
static const NSInteger ContractDefaultRelease = 50;
static const double ContractDefaultVolume = 1.0;
static const double ContractDefaultNoiseRate = 0.0;
static const double ContractDefaultLowPass = 0.0;
static const double ContractDefaultPulseWidth = 0.5;
static const NSInteger ContractDefaultBitDepth = 0;
static const NSInteger ContractMaxVoices = 32;
static const NSInteger ContractMaxSequenceSteps = 512;
static const NSInteger ContractMinWavetableSamples = 2;
static const NSInteger ContractMaxWavetableSamples = 64;
static const NSInteger ContractDefaultDecay = 0;
static const NSInteger ContractMaxDecay = 4000;
static const double ContractDefaultSustain = 1.0;
static NSString *const ContractDefaultFilterType = @"none";
static const double ContractDefaultFilterHz = 1000.0;
static const double ContractMinFilterHz = 20.0;
static const double ContractDefaultFilterQ = 0.7071;
static const double ContractMinFilterQ = 0.5;
static const double ContractMaxFilterQ = 10.0;
static const double ContractDefaultFmRatio = 1.0;
static const double ContractMinFmRatio = 0.1;
static const double ContractMaxFmRatio = 16.0;
static const double ContractMaxFmDepth = 10.0;
static const double ContractMaxDetuneCents = 1200.0;

static NSString *StudioFilterName(id value) {
 return [value isKindOfClass:[NSString class]] ? [[value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString] : @"none";
}

static BOOL HasKey(NSDictionary *options, NSString *key)
{
  return options != nil && [options objectForKey:key] != nil;
}

static NSDictionary *Failure(NSString *key, NSString *reason, id value)
{
  return @{
    @"key": key ?: @"options",
    @"reason": reason ?: @"invalid",
    @"value": value ?: [NSNull null]
  };
}

static BOOL FiniteNumber(id raw, double *outValue)
{
  if (![raw isKindOfClass:[NSNumber class]]) return NO;
  if (CFGetTypeID((__bridge CFTypeRef)raw) == CFBooleanGetTypeID()) return NO;
  double value = [(NSNumber *)raw doubleValue];
  if (!isfinite(value)) return NO;
  if (outValue) *outValue = value;
  return YES;
}

static NSDictionary *OptionalDouble(NSDictionary *options, NSString *key,
                                    double minValue, double maxValue)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  double value = 0.0;
  if (!FiniteNumber(raw, &value)) return Failure(key, @"non_numeric_or_non_finite", raw);
  if (value < minValue || value > maxValue) return Failure(key, @"out_of_range", raw);
  return nil;
}

static NSDictionary *OptionalInteger(NSDictionary *options, NSString *key,
                                     NSInteger minValue, NSInteger maxValue)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  double value = 0.0;
  if (!FiniteNumber(raw, &value)) return Failure(key, @"non_numeric_or_non_finite", raw);
  double rounded = rint(value);
  if (fabs(value - rounded) > 1e-9) return Failure(key, @"not_integer", raw);
  if (rounded < minValue || rounded > maxValue) return Failure(key, @"out_of_range", raw);
  return nil;
}

static NSDictionary *OptionalWaveTable(NSDictionary *options, NSString *key)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  if (![raw isKindOfClass:[NSArray class]]) return Failure(key, @"not_array", raw);
  NSArray *values = (NSArray *)raw;
  if (values.count < ContractMinWavetableSamples || values.count > ContractMaxWavetableSamples) {
    return Failure(key, @"invalid_sample_count", @(values.count));
  }
  for (id value in values) {
    NSDictionary *failure = OptionalDouble(@{ key: value ?: [NSNull null] }, key, -1.0, 1.0);
    if (failure) return failure;
  }
  return nil;
}

static NSDictionary *OptionalBitDepth(NSDictionary *options, NSString *key)
{
  if (!HasKey(options, key)) return nil;
  NSDictionary *failure = OptionalInteger(options, key, 0, 16);
  if (failure) return failure;
  NSInteger value = [[options objectForKey:key] integerValue];
  return value == 0 || value >= 2 ? nil : Failure(key, @"out_of_range", @(value));
}

static NSDictionary *OptionalPulseWidthEnd(NSDictionary *options, NSString *key)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  double value = 0.0;
  if (!FiniteNumber(raw, &value)) return Failure(key, @"non_numeric_or_non_finite", raw);
  return value == 0.0 || (value >= 0.05 && value <= 0.95)
       ? nil : Failure(key, @"out_of_range", raw);
}

static double StrictNoteFrequency(id raw)
{
  if (![raw isKindOfClass:[NSString class]]) return -1.0;
  NSString *value = [(NSString *)raw stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceAndNewlineCharacterSet]];
  if (value.length == 0) return -1.0;
  NSString *upper = [value uppercaseString];
  NSUInteger position = 0;
  NSInteger semitone = 0;

  if ([upper hasPrefix:@"SOL"]) { semitone = 7; position = 3; }
  else if ([upper hasPrefix:@"DO"]) { semitone = 0; position = 2; }
  else if ([upper hasPrefix:@"RE"]) { semitone = 2; position = 2; }
  else if ([upper hasPrefix:@"MI"]) { semitone = 4; position = 2; }
  else if ([upper hasPrefix:@"FA"]) { semitone = 5; position = 2; }
  else if ([upper hasPrefix:@"LA"]) { semitone = 9; position = 2; }
  else if ([upper hasPrefix:@"SI"] || [upper hasPrefix:@"TI"]) { semitone = 11; position = 2; }
  else {
    position = 1;
    switch ([upper characterAtIndex:0]) {
      case 'C': semitone = 0; break;
      case 'D': semitone = 2; break;
      case 'E': semitone = 4; break;
      case 'F': semitone = 5; break;
      case 'G': semitone = 7; break;
      case 'A': semitone = 9; break;
      case 'B': semitone = 11; break;
      default: return -1.0;
    }
  }

  if (position < value.length) {
    unichar accidental = [value characterAtIndex:position];
    if (accidental == '#') { semitone += 1; position += 1; }
    else if (accidental == 'b') { semitone -= 1; position += 1; }
  }

  NSInteger octave = 4;
  if (position < value.length) {
    unichar digit = [value characterAtIndex:position];
    if (digit < '0' || digit > '9' || position + 1 != value.length) return -1.0;
    octave = digit - '0';
  }
  NSInteger midi = (octave + 1) * 12 + semitone;
  return 440.0 * pow(2.0, (midi - 69.0) / 12.0);
}

static NSDictionary *ValidNote(id raw, NSString *key)
{
  if (![raw isKindOfClass:[NSString class]]) return Failure(key, @"not_string", raw);
  return StrictNoteFrequency(raw) >= 1.0 ? nil : Failure(key, @"invalid_note", raw);
}

static NSDictionary *RejectUnknownOptions(NSDictionary *options, NSArray *supportedKeys)
{
  for (id rawKey in options) {
    if (![supportedKeys containsObject:rawKey]) {
      NSString *key = [rawKey isKindOfClass:[NSString class]] ? rawKey : [rawKey description];
      return Failure(key, @"unsupported_option", [options objectForKey:rawKey]);
    }
  }
  return nil;
}

static NSDictionary *ValidateVoiceId(NSDictionary *options)
{
  if(!HasKey(options,@"voiceId")) return Failure(@"voiceId",@"missing_required",nil);
  NSDictionary *failure=OptionalInteger(options,@"voiceId",1,INT32_MAX); if(failure)return failure;
  double value=[options[@"voiceId"] doubleValue];
  return value==rint(value) ? nil : Failure(@"voiceId",@"not_integer",options[@"voiceId"]);
}

static NSArray *FilterTypes(void)
{
  return @[@"none", @"lowpass", @"highpass", @"bandpass"];
}

// Index into FilterTypes() (0 means none), or -1 when the name is not allowed.
static NSInteger FilterTypeIndex(NSString *raw)
{
  NSString *value = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  NSArray *types = FilterTypes();
  for (NSUInteger i = 0; i < types.count; i++) {
    if ([[types objectAtIndex:i] caseInsensitiveCompare:value] == NSOrderedSame) return (NSInteger)i;
  }
  return -1;
}

static NSDictionary *OptionalFilterType(NSDictionary *options, NSString *key)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  if (![raw isKindOfClass:[NSString class]]) return Failure(key, @"not_string", raw);
  return FilterTypeIndex(raw) >= 0 ? nil : Failure(key, @"unsupported_value", raw);
}

static NSDictionary *OptionalFilterHzEnd(NSDictionary *options, NSString *key, double maxFrequency)
{
  if (!HasKey(options, key)) return nil;
  id raw = [options objectForKey:key];
  double value = 0.0;
  if (!FiniteNumber(raw, &value)) return Failure(key, @"non_numeric_or_non_finite", raw);
  return value == 0.0 || (value >= ContractMinFilterHz && value <= maxFrequency)
       ? nil : Failure(key, @"out_of_range", raw);
}

static NSDictionary *ValidateSpatial(NSDictionary *options)
{
  NSDictionary *failure = OptionalDouble(options, @"spatialX", -1.0, 1.0);
  if (failure) return failure;
  failure = OptionalDouble(options, @"spatialY", -1.0, 1.0);
  if (failure) return failure;
  if ([options objectForKey:@"spatialX"] || [options objectForKey:@"spatialY"]) {
    for (NSString *key in @[@"pan", @"panEnd", @"pans", @"panSpread"]) {
      if ([options objectForKey:key]) return Failure(key, @"conflicting_spatial_fields", [options objectForKey:key]);
    }
  }
  return nil;
}

static NSDictionary *ValidateVoiceOptions(NSDictionary *options, double maxFrequency,
                                          BOOL allowSweep)
{
  if (options[@"bus"] && ![@[@"music",@"effects",@"ui",@"ambience"] containsObject:options[@"bus"]]) return Failure(@"bus",@"unsupported_value",options[@"bus"]);
  NSDictionary *routingFailure=OptionalDouble(options,@"effectSend",0,1);if(routingFailure)return routingFailure;
  routingFailure=OptionalInteger(options,@"priority",0,3);if(routingFailure)return routingFailure;

  NSDictionary *failure = ValidateSpatial(options);
  if (failure) return failure;
  failure = OptionalInteger(options, @"duration", 1, 60000);
  if (failure) return failure;
  failure = OptionalInteger(options, @"attack", 0, 2000);
  if (failure) return failure;
  failure = OptionalInteger(options, @"release", 0, 4000);
  if (failure) return failure;
  failure = OptionalDouble(options, @"volume", 0.0, 2.0);
  if (failure) return failure;
  failure = OptionalInteger(options, @"waveType", 0, 5);
  if (failure) return failure;
  failure = OptionalDouble(options, @"pan", -1.0, 1.0);
  if (failure) return failure;
  failure = OptionalDouble(options, @"noiseRate", 0.0, maxFrequency);
  if (failure) return failure;
  failure = OptionalDouble(options, @"lowPassHz", 0.0, maxFrequency);
  if (failure) return failure;
  failure = OptionalDouble(options, @"pulseWidth", 0.05, 0.95);
  if (failure) return failure;
  failure = OptionalWaveTable(options, @"waveTable");
  if (failure) return failure;
  failure = OptionalBitDepth(options, @"bitDepth");
  if (failure) return failure;
  failure = OptionalInteger(options, @"decay", 0, ContractMaxDecay);
  if (failure) return failure;
  failure = OptionalDouble(options, @"sustain", 0.0, 1.0);
  if (failure) return failure;
  failure = OptionalFilterType(options, @"filterType");
  if (failure) return failure;
  failure = OptionalDouble(options, @"filterHz", ContractMinFilterHz, maxFrequency);
  if (failure) return failure;
  failure = OptionalDouble(options, @"filterQ", ContractMinFilterQ, ContractMaxFilterQ);
  if (failure) return failure;
  failure = OptionalDouble(options, @"fmRatio", ContractMinFmRatio, ContractMaxFmRatio);
  if (failure) return failure;
  failure = OptionalDouble(options, @"fmDepth", 0.0, ContractMaxFmDepth);
  if (failure) return failure;
  if (allowSweep) {
    failure = OptionalDouble(options, @"panEnd", -1.0, 1.0);
    if (failure) return failure;
    failure = OptionalDouble(options, @"frequencyEnd", 0.0, maxFrequency);
    if (failure) return failure;
    failure = OptionalDouble(options, @"lfoFreq", 0.0, 20000.0);
    if (failure) return failure;
    failure = OptionalDouble(options, @"lfoDepth", 0.0, 20000.0);
    if (failure) return failure;
    failure = OptionalDouble(options, @"noiseRateEnd", 0.0, maxFrequency);
    if (failure) return failure;
    failure = OptionalPulseWidthEnd(options, @"pulseWidthEnd");
    if (failure) return failure;
    failure = OptionalFilterHzEnd(options, @"filterHzEnd", maxFrequency);
    if (failure) return failure;
    failure = OptionalDouble(options, @"fmDepthEnd", 0.0, ContractMaxFmDepth);
    if (failure) return failure;
    failure = OptionalDouble(options, @"detune", -ContractMaxDetuneCents, ContractMaxDetuneCents);
    if (failure) return failure;
  }
  return nil;
}

static NSInteger IntegerValue(NSDictionary *options, NSString *key, NSInteger fallback)
{
  if (!HasKey(options, key)) return fallback;
  return (NSInteger)llround([[options objectForKey:key] doubleValue]);
}

static NSDictionary *ValidateExplicitEnvelope(NSDictionary *options)
{
  NSInteger duration = IntegerValue(options, @"duration", ContractDefaultDuration);
  NSInteger attack = IntegerValue(options, @"attack", ContractDefaultAttack);
  if (HasKey(options, @"attack") && attack >= duration) {
    return Failure(@"attack", @"attack_greater_or_equal_duration", @(attack));
  }
  NSInteger release = IntegerValue(options, @"release", ContractDefaultRelease);
  if (HasKey(options, @"release") && release > MAX(0, duration - attack)) {
    return Failure(@"release", @"release_exceeds_remaining_duration", @(release));
  }
  return nil;
}

static double NumberValue(NSDictionary *options, NSString *key, double fallback)
{
  return HasKey(options, key) ? [[options objectForKey:key] doubleValue] : fallback;
}

static BOOL FrequencyInRange(double frequency, double maxFrequency)
{
  return frequency >= 1.0 && frequency <= maxFrequency;
}

// Rules that span several keys, evaluated on the effective values of one
// sounding event (a pattern step already merged over its pattern root).
static BOOL VariationEnablesFm(NSDictionary *options) {
 SynthVariation v;return ![TiSynthengineContract prepareVariation:options config:&v]&&v.amount>0&&(v.mask&8)&&v.high[3]>0;
}
static NSDictionary *ValidateExpressiveRules(NSDictionary *eff, NSInteger durationMs)
{
  NSInteger decay = IntegerValue(eff, @"decay", ContractDefaultDecay);
  if (HasKey(eff, @"sustain") && NumberValue(eff, @"sustain", ContractDefaultSustain) < 1.0 && decay == 0) {
    return Failure(@"sustain", @"sustain_without_decay", [eff objectForKey:@"sustain"]);
  }
  if (decay > 0) {
    NSInteger attack = MIN(IntegerValue(eff, @"attack", ContractDefaultAttack), MAX(0, durationMs - 1));
    if (attack + decay > durationMs) {
      return Failure(@"decay", @"decay_exceeds_remaining_duration", [eff objectForKey:@"decay"]);
    }
  }

  BOOL filtered = HasKey(eff, @"filterType") && FilterTypeIndex([eff objectForKey:@"filterType"]) > 0;
  if (!filtered) {
    for (NSString *key in @[@"filterHz", @"filterHzEnd", @"filterQ"]) {
      if (HasKey(eff, key)) return Failure(key, @"filter_type_required", [eff objectForKey:key]);
    }
  }

  double depth = NumberValue(eff, @"fmDepth", 0.0);
  BOOL fmActive = depth > 0.0 || HasKey(eff, @"fmDepthEnd") || VariationEnablesFm(eff);
  if (fmActive && IntegerValue(eff, @"waveType", 0) != 0) {
    NSString *key = depth > 0.0 ? @"fmDepth" : @"fmDepthEnd";
    return Failure(key, @"fm_requires_sine", [eff objectForKey:key]);
  }
  if (HasKey(eff, @"fmRatio") && !fmActive) {
    return Failure(@"fmRatio", @"fm_depth_required", [eff objectForKey:@"fmRatio"]);
  }
  return nil;
}

// Detune must leave the starting pitch, and any sweep target, inside the audible range.
static NSDictionary *ValidateDetuneRange(NSDictionary *eff, double frequency, double maxFrequency)
{
  if (!HasKey(eff, @"detune")) return nil;
  double cents = NumberValue(eff, @"detune", 0.0);
  if (cents == 0.0) return nil;
  double ratio = pow(2.0, cents / 1200.0);
  BOOL inRange = FrequencyInRange(frequency * ratio, maxFrequency);
  if (inRange && HasKey(eff, @"frequencyEnd")) {
    double end = NumberValue(eff, @"frequencyEnd", 0.0);
    if (end != 0.0) inRange = FrequencyInRange(end * ratio, maxFrequency);
  }
  return inRange ? nil : Failure(@"detune", @"out_of_range", [eff objectForKey:@"detune"]);
}

static NSDictionary *ValidateVariation(NSDictionary *options,double frequency,double end,double ceiling)
{
 if(!HasKey(options,@"variation"))return nil;
 SynthVariation v;
 NSDictionary *f=[TiSynthengineContract prepareVariation:options config:&v];if(f)return f;
 int wave=(int)IntegerValue(options,@"waveType",0);
 int filter=options[@"filterType"]?(int)FilterTypeIndex(options[@"filterType"]):0;
 return synth_variation_valid(&v,wave,filter,NumberValue(options,@"noiseRate",0),NumberValue(options,@"lowPassHz",0),frequency,end,ceiling)?nil:Failure(@"variation",@"invalid_variation",options[@"variation"]);
}

@implementation TiSynthengineContract

+ (NSDictionary *)prepareVariation:(NSDictionary *)options config:(SynthVariation *)out
{
 memset(out,0,sizeof(*out));if(!HasKey(options,@"variation"))return nil;
 id raw=options[@"variation"];
 if(![raw isKindOfClass:[NSDictionary class]])return Failure(@"variation",@"invalid_variation",raw);
 NSDictionary *v=raw;
 NSDictionary *f=RejectUnknownOptions(v,@[@"amount",@"seed",@"ranges"]);if(f)return f;
 f=OptionalDouble(v,@"amount",0,1);if(f)return f;
 out->amount=NumberValue(v,@"amount",1);
 if(HasKey(v,@"seed")) {
  double seed;if(!FiniteNumber(v[@"seed"],&seed)||seed!=rint(seed)||seed<0||seed>4294967295.0)return Failure(@"variation",@"invalid_variation",raw);
  out->seeded=1;out->seed=(uint32_t)seed;
 }
 if(HasKey(v,@"ranges")) {
  id ranges=v[@"ranges"];if(![ranges isKindOfClass:[NSDictionary class]])return Failure(@"variation",@"invalid_variation",raw);
  NSArray *names=@[@"volume",@"filterHz",@"filterQ",@"fmDepth",@"noiseRate",@"lowPassHz",@"pulseWidth",@"pitchCents"];
  f=RejectUnknownOptions(ranges,names);if(f)return f;
  for(unsigned i=0;i<8;i++)if(HasKey(ranges,names[i])) {
   id a=ranges[names[i]];
   if(![a isKindOfClass:[NSArray class]]||[a count]!=2||!FiniteNumber(a[0],&out->low[i])||!FiniteNumber(a[1],&out->high[i])||out->low[i]>out->high[i])return Failure(@"variation",@"invalid_variation",raw);
   out->mask|=1u<<i;
  }
 }
 return nil;
}


+ (NSDictionary *)validateStart:(NSDictionary *)options
{
  NSDictionary *failure = RejectUnknownOptions(options, @[@"maxVoices", @"mixingProfile",
                                                            @"audioSession", @"maxSequences"]);
  if (failure) return failure;
  failure = OptionalInteger(options, @"maxSequences", 1, 4);
  if (failure) return failure;
  failure = OptionalInteger(options, @"maxVoices", 1, ContractMaxVoices);
  if (failure) return failure;
  if (HasKey(options, @"mixingProfile")) {
    id raw = [options objectForKey:@"mixingProfile"];
    if (![raw isKindOfClass:[NSString class]]) return Failure(@"mixingProfile", @"not_string", raw);
    NSString *profile = [[(NSString *)raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (!([profile isEqualToString:@"raw"] || [profile isEqualToString:@"conservative"]
          || [profile isEqualToString:@"balanced"] || [profile isEqualToString:@"speakersafe"])) {
      return Failure(@"mixingProfile", @"unsupported_value", raw);
    }
  }
  if (HasKey(options, @"audioSession")) {
    id raw = [options objectForKey:@"audioSession"];
    if (![raw isKindOfClass:[NSString class]]) return Failure(@"audioSession", @"not_string", raw);
    NSString *session = [[(NSString *)raw stringByTrimmingCharactersInSet:
                          [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
    if (!([session isEqualToString:@"playback"] || [session isEqualToString:@"ambient"])) {
      return Failure(@"audioSession", @"unsupported_value", raw);
    }
  }
  return nil;
}

+ (NSDictionary *)validateSetVolume:(NSDictionary *)options
{
  NSDictionary *failure = RejectUnknownOptions(options, @[@"volume"]);
  if (failure) return failure;
  return OptionalDouble(options, @"volume", 0.0, 2.0);
}

+ (NSDictionary *)validateNoteOn:(NSDictionary *)options maxFrequency:(double)maxFrequency
{
  NSDictionary *failure=RejectUnknownOptions(options,@[@"voiceId", @"frequency", @"note", @"attack", @"decay", @"sustain", @"release", @"volume",
      @"waveType", @"pan", @"lfoFreq", @"lfoDepth", @"noiseRate", @"lowPassHz", @"pulseWidth", @"waveTable", @"bitDepth",
      @"filterType", @"filterHz", @"filterQ", @"fmRatio", @"fmDepth", @"detune", @"spatialX", @"spatialY", @"modulations", @"bus", @"effectSend", @"priority", @"variation"]);
  if(failure) return failure;
  if(!HasKey(options,@"voiceId")) return Failure(@"voiceId",@"missing_required",nil);
  failure=ValidateVoiceId(options); if(failure)return failure;
  NSMutableDictionary *tone=[NSMutableDictionary dictionaryWithDictionary:options];
  if(options[@"modulations"]) {
    failure=OptionalInteger(options,@"waveType",0,5);if(failure)return failure;
    failure=OptionalDouble(options,@"fmDepth",0,10);if(failure)return failure;
    double mods[12];
    failure=[self prepareModulations:options[@"modulations"] values:mods waveType:[options[@"waveType"] intValue] filterType:![StudioFilterName(options[@"filterType"]) isEqual:@"none"] ? 1:0];
    if(failure)return failure;
    failure=OptionalDouble(tone,@"fmRatio",.1,16);if(failure)return failure;
    if([tone[@"fmDepth"] doubleValue]==0)for(int i=0;i<2;i++)if(mods[i*6]&&mods[i*6+2]==2)[tone removeObjectForKey:@"fmRatio"];
  }
  [tone removeObjectForKey:@"modulations"];
  [tone removeObjectForKey:@"voiceId"]; tone[@"duration"]=@60000;
  return [self validateTone:tone maxFrequency:maxFrequency];
}
+ (NSDictionary *)validateNoteOff:(NSDictionary *)options
{
  NSDictionary *failure=RejectUnknownOptions(options,@[@"voiceId"]); if(failure)return failure;
  if(!HasKey(options,@"voiceId")) return Failure(@"voiceId",@"missing_required",nil);
  return ValidateVoiceId(options);
}
+ (NSDictionary *)validateUpdateVoice:(NSDictionary *)options maxFrequency:(double)maxFrequency
{
  NSDictionary *failure=RejectUnknownOptions(options,@[@"voiceId", @"frequency", @"note", @"volume", @"filterHz", @"filterQ",
      @"lfoFreq", @"lfoDepth", @"pulseWidth", @"fmRatio", @"fmDepth", @"modulations", @"noiseRate", @"lowPassHz", @"pan", @"spatialX", @"spatialY", @"effectSend"]);
  if(failure)return failure;
  if(!HasKey(options,@"voiceId")) return Failure(@"voiceId",@"missing_required",nil);
  failure=ValidateVoiceId(options); if(failure)return failure;
  if(options.count==1)return Failure(@"changes",@"missing_required",nil);
  if(HasKey(options,@"frequency")&&HasKey(options,@"note"))return Failure(@"frequency",@"conflicting_pitch_fields",options[@"frequency"]);
  failure=OptionalDouble(options,@"frequency",1,maxFrequency); if(failure)return failure;
  if(HasKey(options,@"note")) {
    failure=ValidNote(options[@"note"],@"note"); if(failure)return failure;
    if(StrictNoteFrequency(options[@"note"])>maxFrequency)return Failure(@"note",@"out_of_range",options[@"note"]);
  }
  if(options[@"modulations"]) {double mods[12];failure=[self prepareModulations:options[@"modulations"] values:mods waveType:-1 filterType:-1];if(failure)return failure;}
  return ValidateVoiceOptions(options,maxFrequency,YES);
}

+ (NSDictionary *)validateRepeatTone:(NSDictionary *)options maxFrequency:(double)maxFrequency
{
 if(!HasKey(options,@"intervalMs"))return Failure(@"intervalMs",@"missing_required",nil);
 NSDictionary *failure=OptionalInteger(options,@"intervalMs",1,60000);if(failure)return failure;
 NSMutableDictionary *tone=[options mutableCopy];[tone removeObjectForKey:@"intervalMs"];
 return [self validateTone:tone maxFrequency:maxFrequency];
}

+ (NSDictionary *)validateTone:(NSDictionary *)options maxFrequency:(double)maxFrequency
{
  NSDictionary *failure = RejectUnknownOptions(options,
    @[@"frequency", @"note", @"duration", @"attack", @"release", @"volume",
      @"waveType", @"pan", @"panEnd", @"frequencyEnd", @"lfoFreq", @"lfoDepth",
      @"noiseRate", @"noiseRateEnd", @"lowPassHz", @"pulseWidth", @"pulseWidthEnd",
      @"waveTable", @"bitDepth", @"decay", @"sustain", @"filterType", @"filterHz",
      @"filterHzEnd", @"filterQ", @"fmRatio", @"fmDepth", @"fmDepthEnd", @"detune", @"spatialX", @"spatialY", @"bus", @"effectSend", @"priority", @"variation"]);
  if (failure) return failure;
  BOOL hasFrequency = HasKey(options, @"frequency");
  BOOL hasNote = HasKey(options, @"note");
  if (hasFrequency && hasNote) return Failure(@"frequency", @"conflicting_pitch_fields", [options objectForKey:@"frequency"]);
  if (hasFrequency && (failure = OptionalDouble(options, @"frequency", 1.0, maxFrequency))) return failure;
  if (hasNote && (failure = ValidNote([options objectForKey:@"note"], @"note"))) return failure;
  failure = ValidateVoiceOptions(options, maxFrequency, YES);
  if (!failure && IntegerValue(options, @"waveType", 0) == 5 && !HasKey(options, @"waveTable")) {
    failure = Failure(@"waveTable", @"missing_required", nil);
  }
  if (failure) return failure;
  failure = ValidateExplicitEnvelope(options);
  if (failure) return failure;
  failure = ValidateExpressiveRules(options, IntegerValue(options, @"duration", ContractDefaultDuration));
  if (failure) return failure;
  double toneFrequency = hasNote ? StrictNoteFrequency([options objectForKey:@"note"])
                       : NumberValue(options, @"frequency", ContractDefaultFrequency);
  failure=ValidateDetuneRange(options,toneFrequency,maxFrequency);if(failure)return failure;
  double ratio=pow(2,NumberValue(options,@"detune",0)/1200);
  return ValidateVariation(options,toneFrequency*ratio,NumberValue(options,@"frequencyEnd",0)*ratio,maxFrequency);
}

+ (NSDictionary *)validateChord:(NSDictionary *)options maxFrequency:(double)maxFrequency
{
  NSDictionary *failure = RejectUnknownOptions(options,
    @[@"frequencies", @"notes", @"duration", @"attack", @"release", @"volume",
      @"waveType", @"panSpread", @"pans", @"noiseRate", @"lowPassHz",
      @"pulseWidth", @"waveTable", @"bitDepth", @"decay", @"sustain", @"filterType",
      @"filterHz", @"filterQ", @"fmRatio", @"fmDepth", @"detunes", @"spatialX", @"spatialY", @"bus", @"effectSend", @"priority", @"variation"]);
  if (failure) return failure;
  BOOL hasFrequencies = HasKey(options, @"frequencies");
  BOOL hasNotes = HasKey(options, @"notes");
  if (hasFrequencies == hasNotes) return Failure(@"frequencies", hasFrequencies ? @"conflicting_pitch_fields" : @"missing_required", nil);
  NSString *pitchKey = hasFrequencies ? @"frequencies" : @"notes";
  id rawPitches = [options objectForKey:pitchKey];
  if (![rawPitches isKindOfClass:[NSArray class]]) return Failure(pitchKey, @"not_array", rawPitches);
  NSArray *pitches = (NSArray *)rawPitches;
  if (pitches.count < 1 || pitches.count > ContractMaxVoices) return Failure(pitchKey, @"invalid_voice_count", @(pitches.count));
  for (id pitch in pitches) {
    failure = hasFrequencies
      ? OptionalDouble(@{ @"pitch": pitch ?: [NSNull null] }, @"pitch", 1.0, maxFrequency)
      : ValidNote(pitch, @"notes");
    if (failure) return Failure(pitchKey, [failure objectForKey:@"reason"], pitch);
  }
  failure = ValidateVoiceOptions(options, maxFrequency, NO);
  if (failure) return failure;
  if (IntegerValue(options, @"waveType", 0) == 5 && !HasKey(options, @"waveTable")) {
    return Failure(@"waveTable", @"missing_required", nil);
  }
  failure = OptionalDouble(options, @"panSpread", 0.0, 1.0);
  if (failure) return failure;
  if (HasKey(options, @"pans")) {
    id rawPans = [options objectForKey:@"pans"];
    if (![rawPans isKindOfClass:[NSArray class]]) return Failure(@"pans", @"not_array", rawPans);
    NSArray *pans = (NSArray *)rawPans;
    if (pans.count > pitches.count) return Failure(@"pans", @"too_many_values", @(pans.count));
    for (id pan in pans) {
      failure = OptionalDouble(@{ @"pan": pan ?: [NSNull null] }, @"pan", -1.0, 1.0);
      if (failure) return Failure(@"pans", [failure objectForKey:@"reason"], pan);
    }
  }
  failure = ValidateExplicitEnvelope(options);
  if (failure) return failure;

  NSArray *detunes = nil;
  if (HasKey(options, @"detunes")) {
    id rawDetunes = [options objectForKey:@"detunes"];
    if (![rawDetunes isKindOfClass:[NSArray class]]) return Failure(@"detunes", @"not_array", rawDetunes);
    detunes = (NSArray *)rawDetunes;
    if (detunes.count > pitches.count) return Failure(@"detunes", @"too_many_values", @(detunes.count));
    for (id detune in detunes) {
      failure = OptionalDouble(@{ @"detune": detune ?: [NSNull null] }, @"detune",
                               -ContractMaxDetuneCents, ContractMaxDetuneCents);
      if (failure) return Failure(@"detunes", [failure objectForKey:@"reason"], detune);
    }
  }

  failure = ValidateExpressiveRules(options, IntegerValue(options, @"duration", ContractDefaultDuration));
  if (failure) return failure;
  for (NSUInteger i = 0; i < detunes.count; i++) {
    double cents = [[detunes objectAtIndex:i] doubleValue];
    if (cents == 0.0) continue;
    double base = hasFrequencies ? [[pitches objectAtIndex:i] doubleValue]
                                 : StrictNoteFrequency([pitches objectAtIndex:i]);
    if (!FrequencyInRange(base * pow(2.0, cents / 1200.0), maxFrequency)) {
      return Failure(@"detunes", @"out_of_range", [detunes objectAtIndex:i]);
    }
  }
  for(NSUInteger i=0;i<pitches.count;i++) {
    double base=hasFrequencies?[pitches[i] doubleValue]:StrictNoteFrequency(pitches[i]);
    double ratio=pow(2,(i<detunes.count?[detunes[i] doubleValue]:0)/1200);
    failure=ValidateVariation(options,base*ratio,0,maxFrequency);if(failure)return failure;
  }
  return nil;
}

+ (NSDictionary *)defaultsWithMaxFrequency:(double)maxFrequency
{
  return @{
    @"version": @"2.0.0",
    @"capabilities": @{@"variation":@YES,@"toneRepetition":@YES},
    @"variationSchemaVersion":@1,
    @"defaults": @{
      @"maxVoices": @(ContractDefaultMaxVoices), @"maxSequences": @1, @"timeUnit": @"beats", @"gate": @0.8, @"loop": @NO, @"bus": @"effects", @"priority": @0,
      @"mixingProfile": ContractDefaultMixingProfile,
      @"audioSession": ContractDefaultAudioSession,
      @"frequency": @(ContractDefaultFrequency),
      @"duration": @(ContractDefaultDuration),
      @"attack": @(ContractDefaultAttack),
      @"release": @(ContractDefaultRelease),
      @"volume": @(ContractDefaultVolume),
      @"waveType": @0,
      @"pan": @0.0,
      @"panEnd": @0.0,
      @"frequencyEnd": @0.0,
      @"lfoFreq": @0.0,
      @"lfoDepth": @0.0,
      @"noiseRate": @(ContractDefaultNoiseRate),
      @"noiseRateEnd": @0.0,
      @"lowPassHz": @(ContractDefaultLowPass),
      @"pulseWidth": @(ContractDefaultPulseWidth),
      @"pulseWidthEnd": @0.0,
      @"waveTable": @[],
      @"bitDepth": @(ContractDefaultBitDepth),
      @"panSpread": @0.0,
      @"bpm": @120.0,
      @"swing": @0.0,
      @"stepDuration": @0.25,
      @"decay": @(ContractDefaultDecay),
      @"sustain": @(ContractDefaultSustain),
      @"filterType": ContractDefaultFilterType,
      @"filterHz": @(ContractDefaultFilterHz),
      @"filterHzEnd": @0.0,
      @"filterQ": @(ContractDefaultFilterQ),
      @"fmRatio": @(ContractDefaultFmRatio),
      @"fmDepth": @0.0,
      @"detune": @0.0
    },
    @"limits": @{
      @"maxVoices": @{ @"min": @1, @"max": @(ContractMaxVoices) },
      @"maxSequences": @{ @"min": @1, @"max": @4 },
      @"maxToneRepetitions": @{ @"min": @1, @"max": @32 },
      @"intervalMs": @{ @"min": @1, @"max": @60000 },
      @"priority": @{ @"min": @0, @"max": @3 },
      @"effectSend": @{ @"min": @0, @"max": @1 },
      @"frequency": @{ @"min": @1.0, @"max": @(maxFrequency) },
      @"duration": @{ @"min": @1, @"max": @60000 },
      @"attack": @{ @"min": @0, @"max": @2000 },
      @"release": @{ @"min": @0, @"max": @4000 },
      @"volume": @{ @"min": @0.0, @"max": @2.0 },
      @"waveType": @{ @"min": @0, @"max": @5 },
      @"noiseRate": @{ @"min": @0.0, @"max": @(maxFrequency) },
      @"lowPassHz": @{ @"min": @0.0, @"max": @(maxFrequency) },
      @"pulseWidth": @{ @"min": @0.05, @"max": @0.95 },
      @"waveTableSamples": @{ @"min": @(ContractMinWavetableSamples), @"max": @(ContractMaxWavetableSamples) },
      @"bitDepth": @{ @"min": @0, @"max": @16 },
      @"sequenceSteps": @{ @"min": @1, @"max": @(ContractMaxSequenceSteps) },
      @"pan": @{ @"min": @-1.0, @"max": @1.0 },
      @"spatialX": @{ @"min": @-1.0, @"max": @1.0 },
      @"spatialY": @{ @"min": @-1.0, @"max": @1.0 },
      @"panSpread": @{ @"min": @0.0, @"max": @1.0 },
      @"lfoFreq": @{ @"min": @0.0, @"max": @20000.0 },
      @"lfoDepth": @{ @"min": @0.0, @"max": @20000.0 },
      @"bpm": @{ @"min": @20.0, @"max": @300.0 },
      @"swing": @{ @"min": @-0.75, @"max": @0.75 },
      @"stepDuration": @{ @"min": @(20/(maxFrequency/.45)), @"max": @300 },
      @"decay": @{ @"min": @0, @"max": @(ContractMaxDecay) },
      @"sustain": @{ @"min": @0.0, @"max": @1.0 },
      @"filterHz": @{ @"min": @(ContractMinFilterHz), @"max": @(maxFrequency) },
      @"filterQ": @{ @"min": @(ContractMinFilterQ), @"max": @(ContractMaxFilterQ) },
      @"fmRatio": @{ @"min": @(ContractMinFmRatio), @"max": @(ContractMaxFmRatio) },
      @"fmDepth": @{ @"min": @0.0, @"max": @(ContractMaxFmDepth) },
      @"detune": @{ @"min": @(-ContractMaxDetuneCents), @"max": @(ContractMaxDetuneCents) }
    },
    @"mixingProfiles": @[@"conservative", @"raw", @"balanced", @"speakerSafe"],
    @"audioSessions": @[@"playback", @"ambient"],
    @"buses": @[@"music",@"effects",@"ui",@"ambience"],
    @"filterTypes": FilterTypes(),
    @"waveTypes": @{ @"SINE": @0, @"SQUARE": @1, @"SAWTOOTH": @2, @"TRIANGLE": @3, @"NOISE": @4, @"WAVETABLE": @5 }
  };
}

+ (NSDictionary *)prepareModulations:(id)raw values:(double *)values waveType:(int)wave filterType:(int)filter
{
  memset(values,0,12*sizeof(double));
  if(![raw isKindOfClass:[NSArray class]] || [raw count]>2)return Failure(@"modulations",@"invalid_array",raw);
  NSArray *sync=@[@"off",@"quarter",@"eighth",@"sixteenth",@"quarterTriplet",@"eighthTriplet",@"sixteenthTriplet"];
  double beats[]={0,1,.5,.25,2.0/3,1.0/3,1.0/6};
  int i=0;
  for(id item in raw) {
    if(![item isKindOfClass:[NSDictionary class]])return Failure(@"modulations",@"not_object",item);
    NSDictionary *f=RejectUnknownOptions(item,@[@"wave",@"target",@"rate",@"depth",@"sync"]);if(f)return f;
    NSArray *waves=@[@"sine",@"triangle"], *targets=@[@"filterHz",@"pulseWidth",@"fmDepth"];
    NSUInteger w=[waves indexOfObject:item[@"wave"] ?: @"sine"], t=[targets indexOfObject:item[@"target"] ?: @""];
    NSUInteger b=[sync indexOfObject:item[@"sync"] ?: @"off"];
    if(w==NSNotFound||t==NSNotFound||b==NSNotFound)return Failure(@"modulations",@"unsupported_value",item);
    if((t==0&&filter==0)||(t==1&&wave>=0&&wave!=1)||(t==2&&wave>=0&&wave!=0))return Failure(@"modulations",@"incompatible_voice_source",item);
    f=OptionalDouble(item,@"rate",0,20);if(f)return f;
    f=OptionalDouble(item,@"depth",0,1);if(f)return f;
    values[i++]=1;values[i++]=w;values[i++]=t;values[i++]=item[@"rate"]?[item[@"rate"] doubleValue]:1;
    values[i++]=item[@"depth"]?[item[@"depth"] doubleValue]:0;values[i++]=beats[b];
  }
  return nil;
}

+ (NSDictionary *)prepareMasterProcessing:(NSDictionary *)options config:(SynthEffectsConfig *)config
{
  if(![options isKindOfClass:[NSDictionary class]])return Failure(@"options",@"not_object",options);
  NSDictionary *f=RejectUnknownOptions(options,@[@"inputGain",@"chorus",@"delay",@"reverb",@"saturation",@"applyTo"]);if(f)return f;
  SynthEffectsConfig c=*config;
  if(options[@"applyTo"]) {
    if(![options[@"applyTo"] isKindOfClass:[NSArray class]])return Failure(@"applyTo",@"not_array",options[@"applyTo"]);
    c.applyToMask=0;for(id bus in options[@"applyTo"]) {NSUInteger n=[@[@"music",@"effects",@"ui",@"ambience"] indexOfObject:bus];if(n==NSNotFound)return Failure(@"applyTo",@"unsupported_value",bus);c.applyToMask|=1u<<n;}
  }
  f=OptionalDouble(options,@"inputGain",0,4);if(f)return f;if(options[@"inputGain"])c.inputGain=[options[@"inputGain"] doubleValue];
  for(NSString *section in @[@"chorus",@"delay",@"reverb",@"saturation"]) {
    NSDictionary *part=options[section];if(!part)continue;
    if(![part isKindOfClass:[NSDictionary class]])return Failure(section,@"not_object",part);
    NSArray *keys=[section isEqual:@"chorus"]?@[@"enabled",@"rate",@"depth",@"mix"]:[section isEqual:@"delay"]?@[@"enabled",@"timeMs",@"sync",@"feedback",@"mix"]:[section isEqual:@"reverb"]?@[@"enabled",@"decay",@"damping",@"mix"]:@[@"enabled",@"drive",@"mix"];
    f=RejectUnknownOptions(part,keys);if(f)return f;
    if(part[@"enabled"]&&CFGetTypeID((__bridge CFTypeRef)part[@"enabled"])!=CFBooleanGetTypeID())return Failure(@"enabled",@"not_boolean",part[@"enabled"]);
    for(NSString *key in keys) {
      id v=part[key];if(!v||[key isEqual:@"enabled"]||[key isEqual:@"sync"])continue;
      double low=0,high=1;
      if([key isEqual:@"rate"]){low=.05;high=5;}if([key isEqual:@"timeMs"]){low=20;high=2000;}
      if([key isEqual:@"feedback"])high=.85;if([key isEqual:@"decay"]){low=.2;high=8;}if([key isEqual:@"drive"]){low=1;high=4;}
      f=OptionalDouble(part,key,low,high);if(f)return f;
    }
#define SET(field,key) if(part[@key]) c.field=[part[@key] doubleValue]
    if([section isEqual:@"chorus"]) {SET(chorus.enabled,"enabled");SET(chorus.rateHz,"rate");SET(chorus.depth,"depth");SET(chorus.mix,"mix");}
    if([section isEqual:@"delay"]) {SET(delay.enabled,"enabled");SET(delay.timeMs,"timeMs");SET(delay.feedback,"feedback");SET(delay.mix,"mix");
      if(part[@"sync"]) {NSArray *names=@[@"off",@"quarter",@"eighth",@"sixteenth",@"quarterTriplet",@"eighthTriplet",@"sixteenthTriplet"];double beats[]={0,1,.5,.25,2.0/3,1.0/3,1.0/6};NSUInteger index=[names indexOfObject:part[@"sync"]];if(index==NSNotFound)return Failure(@"sync",@"unsupported_value",part[@"sync"]);c.delay.syncBeats=beats[index];}}
    if([section isEqual:@"reverb"]) {SET(reverb.enabled,"enabled");SET(reverb.decay,"decay");SET(reverb.damping,"damping");SET(reverb.mix,"mix");}
    if([section isEqual:@"saturation"]) {SET(saturation.enabled,"enabled");SET(saturation.drive,"drive");SET(saturation.mix,"mix");}
#undef SET
  }
  if(!synth_effects_validate(&c))return Failure(@"options",@"out_of_range",options);
  *config=c;return nil;
}

+ (NSDictionary *)sequenceStateObject:(const SynthSequenceState *)state
{
 return @{@"playing":state->playing ? @YES : @NO,@"step":@(state->stepIndex),@"beat":@(state->beat),@"position":@(state->beat),@"bpm":@(state->bpm),@"revision":@(state->revision)};
}

+ (NSMutableDictionary *)mergeSequenceVoice:(NSDictionary *)previous changes:(NSDictionary *)changes
{
 NSMutableDictionary *v=[previous mutableCopy];
 if([changes[@"filterType"] isKindOfClass:[NSString class]]&&[StudioFilterName(changes[@"filterType"]) isEqual:@"none"])for(NSString *key in @[@"filterHz",@"filterQ"])if(!changes[key])[v removeObjectForKey:key];
 if([changes[@"waveType"] isKindOfClass:[NSNumber class]]&&[changes[@"waveType"] intValue]!=0)for(NSString *key in @[@"fmRatio",@"fmDepth"])if(!changes[key])[v removeObjectForKey:key];
 BOOL fmModulation=NO;id mods=changes[@"modulations"]?:previous[@"modulations"];
 if([mods isKindOfClass:[NSArray class]])for(id item in mods)if([item isKindOfClass:[NSDictionary class]]&&[item[@"target"] isEqual:@"fmDepth"])fmModulation=YES;
 if([changes[@"fmDepth"] isKindOfClass:[NSNumber class]]&&[changes[@"fmDepth"] doubleValue]==0&&!changes[@"fmRatio"]&&!fmModulation)[v removeObjectForKey:@"fmRatio"];
 if(changes[@"pan"])for(NSString *key in @[@"spatialX",@"spatialY"])if(!changes[key])[v removeObjectForKey:key];
 if((changes[@"spatialX"]||changes[@"spatialY"])&&!changes[@"pan"])[v removeObjectForKey:@"pan"];
 [v addEntriesFromDictionary:changes];return v;
}

+ (NSDictionary *)prepareSequence:(NSDictionary *)options config:(SynthSequenceConfig *)c maxFrequency:(double)maxFrequency
{
  if(![options isKindOfClass:[NSDictionary class]])return Failure(@"options",@"not_object",options);
  NSDictionary *f=RejectUnknownOptions(options,@[@"steps",@"timeUnit",@"stepDuration",@"gate",@"swing",@"loop",@"mode",@"tuning",@"detune",@"voice",@"bus",@"effectSend",@"priority"]);if(f)return f;
  synth_sequence_defaults(c);
  if(options[@"timeUnit"]&&![@[@"beats",@"ms"] containsObject:options[@"timeUnit"]])return Failure(@"timeUnit",@"unsupported_value",options[@"timeUnit"]);
  c->timeUnit=[options[@"timeUnit"] isEqual:@"ms"]?SYNTH_SEQUENCE_MS:SYNTH_SEQUENCE_BEATS;
  c->stepDuration=c->timeUnit==SYNTH_SEQUENCE_MS?100:.25;
  double minimumInterval=(c->timeUnit==SYNTH_SEQUENCE_MS?4000:20)/(maxFrequency/.45);
  f=OptionalDouble(options,@"stepDuration",minimumInterval,c->timeUnit==SYNTH_SEQUENCE_MS?60000:300);if(f)return f;if(options[@"stepDuration"])c->stepDuration=[options[@"stepDuration"] doubleValue];
  f=OptionalDouble(options,@"gate",.01,1);if(f)return f;

  f=OptionalDouble(options,@"swing",-.75,.75);if(f)return f;
  f=OptionalDouble(options,@"tuning",220,880);if(f)return f;f=OptionalDouble(options,@"detune",-1200,1200);if(f)return f;
  if(options[@"loop"]&&CFGetTypeID((__bridge CFTypeRef)options[@"loop"])!=CFBooleanGetTypeID())return Failure(@"loop",@"not_boolean",options[@"loop"]);
  if(options[@"swing"])c->swing=[options[@"swing"] doubleValue];
  if(options[@"tuning"])c->tuning=[options[@"tuning"] doubleValue];if(options[@"detune"])c->detune=[options[@"detune"] doubleValue];if(options[@"loop"])c->loop=[options[@"loop"] boolValue];
  NSArray *modes=@[@"normal",@"up",@"down",@"updown"];NSUInteger mode=[modes indexOfObject:options[@"mode"] ?: @"normal"];if(mode==NSNotFound)return Failure(@"mode",@"unsupported_value",options[@"mode"]);c->mode=(int)mode;
  NSMutableDictionary *voice=[NSMutableDictionary dictionary];
  for(NSString *key in @[@"bus",@"effectSend",@"priority"])if(options[key])voice[key]=options[key];
  if(options[@"voice"]&&![options[@"voice"] isKindOfClass:[NSDictionary class]])return Failure(@"voice",@"not_object",options[@"voice"]);
  [voice addEntriesFromDictionary:options[@"voice"]?:@{}];
  if(![voice isKindOfClass:[NSDictionary class]])return Failure(@"voice",@"not_object",voice);
  NSArray *steps=options[@"steps"];
  if(![steps isKindOfClass:[NSArray class]]||steps.count<1||steps.count>512)return Failure(@"steps",@"invalid_array",steps);
  c->stepCount=(int)steps.count;
  NSArray *voiceKeys=@[@"attack",@"decay",@"sustain",@"release",@"volume",@"waveType",@"pan",@"lfoFreq",@"lfoDepth",@"noiseRate",@"lowPassHz",@"pulseWidth",@"waveTable",@"bitDepth",@"filterType",@"filterHz",@"filterQ",@"fmRatio",@"fmDepth",@"spatialX",@"spatialY",@"modulations",@"bus",@"effectSend",@"priority",@"frequencyEnd",@"noiseRateEnd",@"panEnd",@"pulseWidthEnd",@"filterHzEnd",@"fmDepthEnd",@"variation"];
  f=RejectUnknownOptions(voice,voiceKeys);if(f)return f;
  SynthVariation rootVariation;f=[self prepareVariation:voice config:&rootVariation];if(f)return f;
  c->variationRootSeeded=rootVariation.seeded;c->variationRootSeed=rootVariation.seed;
  for(int i=0;i<c->stepCount;i++) {
    NSDictionary *step=steps[i];if(![step isKindOfClass:[NSDictionary class]])return Failure(@"steps",@"not_object",step);
    f=RejectUnknownOptions(step,@[@"notes",@"frequencies",@"rest",@"gate",@"duration",@"length",@"overrides",@"bus",@"effectSend",@"priority"]);if(f)return f;
    BOOL rest=step[@"rest"]!=nil;
    if(rest&&(![step[@"rest"] isEqual:@YES]||CFGetTypeID((__bridge CFTypeRef)step[@"rest"])!=CFBooleanGetTypeID()||step[@"notes"]||step[@"frequencies"]))return Failure(@"rest",@"invalid_rest",step);
    BOOL frequencies=step[@"frequencies"]!=nil;
    if(step[@"notes"]&&frequencies)return Failure(@"steps",@"conflicting_pitch_fields",step);
    NSArray *notes=step[frequencies?@"frequencies":@"notes"];if(!rest&&(![notes isKindOfClass:[NSArray class]]||notes.count<1||notes.count>32))return Failure(@"notes",@"invalid_array",notes);
    SynthSequenceStep *dst=&c->steps[i];dst->rest=rest;dst->noteCount=rest?0:(int)notes.count;
    if(options[@"gate"])dst->gate=[options[@"gate"] doubleValue];
    f=OptionalDouble(step,@"duration",minimumInterval,c->timeUnit==SYNTH_SEQUENCE_MS?60000:300);if(f)return f;if(step[@"duration"])dst->duration=[step[@"duration"] doubleValue];
    f=OptionalDouble(step,@"length",.000001,c->timeUnit==SYNTH_SEQUENCE_MS?60000:300);if(f)return f;if(step[@"length"])dst->length=[step[@"length"] doubleValue];
    f=OptionalDouble(step,@"gate",.01,1);if(f)return f;if(step[@"gate"])dst->gate=[step[@"gate"] doubleValue];
    for(int n=0;n<dst->noteCount;n++){if(frequencies){double hz;if(!FiniteNumber(notes[n],&hz)||hz<1||hz>maxFrequency)return Failure(@"frequencies",@"out_of_range",notes[n]);dst->frequencies[n]=hz;continue;}double midi;if(!FiniteNumber(notes[n],&midi)||midi!=rint(midi)||midi<12||midi>119)return Failure(@"notes",@"out_of_range",notes[n]);dst->notes[n]=(uint8_t)midi;double hz=synth_sequence_frequency(c,(int)midi);if(hz<1||hz>maxFrequency)return Failure(@"notes",@"out_of_range",notes[n]);}
    NSMutableDictionary *overrides=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"bus",@"effectSend",@"priority"])if(step[key])overrides[key]=step[key];
    if(step[@"overrides"]&&![step[@"overrides"] isKindOfClass:[NSDictionary class]])return Failure(@"overrides",@"not_object",step[@"overrides"]);[overrides addEntriesFromDictionary:step[@"overrides"]?:@{}];if(![overrides isKindOfClass:[NSDictionary class]])return Failure(@"overrides",@"not_object",overrides);
    f=RejectUnknownOptions(overrides,voiceKeys);if(f)return f;
    NSMutableDictionary *v=[self mergeSequenceVoice:voice changes:overrides];v[@"voiceId"]=@1;v[@"frequency"]=@440;
    NSMutableDictionary *held=[v mutableCopy];for(NSString *key in @[@"frequencyEnd",@"noiseRateEnd",@"panEnd",@"pulseWidthEnd",@"filterHzEnd",@"fmDepthEnd"])[held removeObjectForKey:key];
    if(v[@"fmDepthEnd"]&&[v[@"fmDepth"] doubleValue]==0)[held removeObjectForKey:@"fmRatio"];
    f=[self validateNoteOn:held maxFrequency:maxFrequency];if(f)return f;
    f=ValidateVoiceOptions(v,maxFrequency,YES);if(f)return f;
    NSMutableDictionary *expressive=[v mutableCopy];
    if([v[@"fmDepth"] doubleValue]==0&&!v[@"fmDepthEnd"])for(id mod in v[@"modulations"])if([mod[@"target"] isEqual:@"fmDepth"])[expressive removeObjectForKey:@"fmRatio"];
    f=ValidateExpressiveRules(expressive,60000);if(f)return f;
    for(int n=0;n<dst->noteCount;n++) {
      double hz=frequencies?dst->frequencies[n]:synth_sequence_frequency(c,dst->notes[n]);
      f=ValidateVariation(v,hz,NumberValue(v,@"frequencyEnd",0),maxFrequency);if(f)return f;
    }
    SynthSequenceVoice *out=&dst->voice;
    f=[self prepareVariation:v config:&out->variation];if(f)return f;
    if([overrides[@"variation"] isKindOfClass:[NSDictionary class]]&&HasKey(overrides[@"variation"],@"seed"))out->variation.seeded|=SYNTH_VAR_STEP_SEED;
#define FIELD(field,key,def) out->field=v[@key]?[v[@key] doubleValue]:(def)
    FIELD(volume,"volume",1);FIELD(pan,"pan",0);FIELD(lfoFreq,"lfoFreq",0);FIELD(lfoDepth,"lfoDepth",0);FIELD(noiseRate,"noiseRate",0);FIELD(lowPassHz,"lowPassHz",0);FIELD(pulseWidth,"pulseWidth",.5);
    FIELD(filterHz,"filterHz",1000);FIELD(filterQ,"filterQ",.7071);FIELD(fmRatio,"fmRatio",1);FIELD(fmDepth,"fmDepth",0);FIELD(sustain,"sustain",1);
    FIELD(waveType,"waveType",0);FIELD(attack,"attack",50);FIELD(decay,"decay",0);FIELD(release,"release",50);FIELD(bitDepth,"bitDepth",0);
    FIELD(frequencyEnd,"frequencyEnd",0);FIELD(noiseRateEnd,"noiseRateEnd",0);FIELD(panEnd,"panEnd",out->pan);FIELD(pulseWidthEnd,"pulseWidthEnd",0);FIELD(filterHzEnd,"filterHzEnd",0);FIELD(fmDepthEnd,"fmDepthEnd",0);out->fmDepthSweep=v[@"fmDepthEnd"]!=nil;
    FIELD(spatialX,"spatialX",0);FIELD(spatialY,"spatialY",0);out->spatial=v[@"spatialX"]||v[@"spatialY"];
#undef FIELD
    out->bus=(int)[@[@"music",@"effects",@"ui",@"ambience"] indexOfObject:v[@"bus"]?:@"effects"];out->effectSend=v[@"effectSend"]?[v[@"effectSend"] doubleValue]:-1;out->priority=[v[@"priority"] intValue];
    out->filterType=(int)[@[@"none",@"lowpass",@"highpass",@"bandpass"] indexOfObject:StudioFilterName(v[@"filterType"])];
    NSArray *table=v[@"waveTable"];out->wavetableSize=(int)table.count;for(int k=0;k<out->wavetableSize;k++)out->wavetable[k]=[table[k] doubleValue];
    if(v[@"modulations"]){f=[self prepareModulations:v[@"modulations"] values:out->mods waveType:out->waveType filterType:out->filterType];if(f)return f;}
  }
  return synth_sequence_prepare(c)?nil:Failure(@"options",@"invalid_sequence",options);
}

@end
