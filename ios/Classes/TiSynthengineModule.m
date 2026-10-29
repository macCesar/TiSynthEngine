#import "TiSynthengineModule.h"
#import "TiSynthengineContract.h"
#import "TiBase.h"
#import "TiHost.h"
#import "TiUtils.h"
#import <AVFoundation/AVFoundation.h>
#import <limits.h>
#import <math.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <stdint.h>
#include "../../shared/synth_core.h"
#include "../../shared/synth_held.h"
#include "../../shared/synth_retrigger.h"
#include "../../shared/synth_modulation.h"
#include "../../shared/synth_spatial.h"
#include "../../shared/synth_stats.h"
#include "../../shared/synth_transport.h"

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define DEFAULT_SAMPLE_RATE   44100.0
#define ABSOLUTE_MAX_VOICES   32
#define WAVETABLE_MAX_SAMPLES 64

#define OUTPUT_CEILING        0.85
#define SPEAKER_SAFE_OUTPUT_CEILING 0.70
#define MIXING_PROFILE_RAW          0
#define MIXING_PROFILE_CONSERVATIVE 1
#define MIXING_PROFILE_BALANCED     2
#define MIXING_PROFILE_SPEAKER_SAFE 3
#define CONSERVATIVE_SINE_GAIN      0.44
#define STOP_ALL_FADE_MS      20
#define VOICE_STEAL_FADE_MS   6

#define COMMAND_QUEUE_CAPACITY 128

#define DEFAULT_FREQUENCY_HZ  440.0

#define DURATION_DEFAULT_MS   500
#define DURATION_MIN_MS       1
#define DURATION_MAX_MS       60000

#define ATTACK_DEFAULT_MS     50
#define ATTACK_MIN_MS         0
#define ATTACK_MAX_MS         2000

#define RELEASE_DEFAULT_MS    50
#define RELEASE_MIN_MS        0
#define RELEASE_MAX_MS        4000

#define VOLUME_DEFAULT        1.0
#define VOLUME_MIN            0.0
#define VOLUME_MAX            2.0

#define MIN_FREQUENCY_HZ      1.0

// ---------------------------------------------------------------------------
// Voice struct
// ---------------------------------------------------------------------------

typedef struct {
  int sequenceSlot,priority,bus,sequenceTimeUnit;double effectSend;SynthSend send;
  uint64_t voiceGeneration;uint32_t sequenceId;
  double sequenceStartClock,sequenceLength,sequenceFrequencyEnd,sequenceNoiseEnd,sequencePanEnd,sequencePulseEnd,sequenceFMEnd;BOOL sequenceFMSweep;
  SynthHeld held;
  SynthModulation modulation;
  BOOL modulating;
  uint32_t modulationFrames;
  uint64_t sequenceGeneration;
  double sequenceOffBeat;
  int sequenceStep,sequenceMidi;
  SynthLive live;
  double eventGain;
  bool   isActive;
  bool spatial;
  SynthSpatial spatialState;
  int spatialDrain;
  double phase;
  double phaseIncrement;
  double phaseIncrDelta;
  int    totalSamples;
  int    samplesPlayed;
  int    attackSamples;
  int    releaseSamples;
  double volume;
  double currentEnvelope;

  // Timbre: 0=sine 1=square 2=sawtooth 3=triangle 4=noise 5=wavetable
  int    waveType;

  // Stereo panning
  double pan;
  double panDelta;
  double leftGain;
  double rightGain;

  // LFO vibrato
  double lfoPhase;
  double lfoPhaseIncrement;
  double lfoDepth;

  // Noise LCG
  uint64_t noiseState;
  double noisePhase;
  double noisePhaseIncrement;
  double noisePhaseIncrDelta;
  double heldNoise;

  // Optional retro character controls
  double filterState;
  double filterAlpha;
  double pulseWidth;
  double pulseWidthDelta;
  int bitDepth;
  double wavetable[WAVETABLE_MAX_SAMPLES];
  int wavetableSize;

  // Decay and sustain stages of the envelope
  int    decaySamples;
  double sustain;

  // State-variable filter; the cutoff moves from svfHz to svfHzEnd when sweeping
  SynthFilter svf;
  bool   svfSweeping;
  double svfHz;
  double svfHzEnd;
  double svfQ;

  // Phase-modulated sine
  bool   fmActive;
  double fmRatio;
  double fmModPhase;
  double fmDepth;
  double fmDepthDelta;
} SynthVoice;

typedef struct {
  SynthSend send;int bus;double effectSend;
  bool isActive;
  bool spatial;
  SynthSpatial spatialState;
  int spatialDrain;
  double phase;
  double phaseIncrement;
  double volume;
  int waveType;
  double leftGain;
  double rightGain;
  uint64_t noiseState;
  double noisePhase;
  double noisePhaseIncrement;
  double heldNoise;
  double filterState;
  double filterAlpha;
  double pulseWidth;
  int bitDepth;
  double wavetable[WAVETABLE_MAX_SAMPLES];
  int wavetableSize;
  SynthFilter svf;
  bool fmActive;
  double fmRatio;
  double fmModPhase;
  double fmDepth;
  int totalSamples;
  int samplesRemaining;
} TailVoice;

// ---------------------------------------------------------------------------
// Command struct
// ---------------------------------------------------------------------------

typedef struct {
  int sequenceSlot,priority,bus,sequenceTimeUnit;double effectSend;BOOL hasSendUpdate;uint32_t sequenceId;
  SynthSpatialPrepared preparedSpatial;BOOL hasSpatialUpdate;
  uint64_t voiceGeneration;
  int32_t voiceId;
  SynthModulationConfig modulation;
  BOOL hasModulations;
  SynthEffectsConfig processing;
  uint64_t sequenceGeneration;
  double sequenceOffBeat;
  int sequenceStep,sequenceMidi;
  uint32_t liveMask;
  double liveValues[SYNTH_LIVE_COUNT];
  int    type;
  BOOL spatial;
  double spatialX, spatialY;
  double frequency;
  int    durationSamples;
  int    attackSamples;
  int    releaseSamples;
  double volume;
  int    eventVoiceCount;
  int    waveType;
  double pan;
  double panEnd;
  double frequencyEnd;
  double lfoFreq;
  double lfoDepth;
  double noiseRate;
  double noiseRateEnd;
  double lowPassHz;
  double pulseWidth;
  double pulseWidthEnd;
  int bitDepth;
  double wavetable[WAVETABLE_MAX_SAMPLES];
  int wavetableSize;
  int    decaySamples;
  double sustain;
  int    filterType;
  double filterHz;
  double filterHzEnd;
  double filterQ;
  double fmRatio;
  double fmDepth;
  double fmDepthEnd;
  bool   hasFmDepthEnd;
} SynthCommand;

enum {
  CMD_NOTE_ON  = 1,
  CMD_STOP_ALL = 2,
  CMD_SHUTDOWN = 3
};

// ---------------------------------------------------------------------------
// C utilities
// ---------------------------------------------------------------------------

static double ClampDouble(double value, double minValue, double maxValue)
{
  if (value < minValue) return minValue;
  if (value > maxValue) return maxValue;
  return value;
}

static int ClampInt(int value, int minValue, int maxValue)
{
  if (value < minValue) return minValue;
  if (value > maxValue) return maxValue;
  return value;
}

static int MsToSamples(int ms, double sampleRate)
{
  return (int)((ms / 1000.0) * sampleRate);
}

static double SmoothStep01(double x)
{
  double t = ClampDouble(x, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

static double VoiceGainForEvent(int profile, int waveType, int voiceCount)
{
  if (profile == MIXING_PROFILE_RAW) return 1.0;

  double gain;
  if (waveType == 1) {
    gain = CONSERVATIVE_SINE_GAIN / M_SQRT2;
  } else if (waveType == 0) {
    gain = CONSERVATIVE_SINE_GAIN;
  } else {
    gain = CONSERVATIVE_SINE_GAIN * sqrt(1.5);
  }
  if (profile == MIXING_PROFILE_BALANCED) {
    gain *= M_SQRT2;
  } else if (profile == MIXING_PROFILE_SPEAKER_SAFE) {
    gain /= M_SQRT2;
  }
  return gain / sqrt((double)MAX(1, voiceCount));
}

static double PolyBlep(double t, double dt)
{
  if (t < dt) {
    double x = t / dt;
    return x + x - x * x - 1.0;
  }
  if (t > 1.0 - dt) {
    double x = (t - 1.0) / dt;
    return x * x + x + x + 1.0;
  }
  return 0.0;
}

static double RenderPeriodicWave(int waveType, double phase, double phaseIncrement,
                                 double pulseWidth)
{
  double t = phase - floor(phase);
  double dt = ClampDouble(fabs(phaseIncrement), 1.0e-9, 0.5);
  switch (waveType) {
    case 1: {
      double width = ClampDouble(pulseWidth, 0.05, 0.95);
      double value = t < width ? 1.0 : -1.0;
      value += PolyBlep(t, dt);
      double shifted = t - width;
      if (shifted < 0.0) shifted += 1.0;
      value -= PolyBlep(shifted, dt);
      return value;
    }
    case 2:
      return 2.0 * t - 1.0 - PolyBlep(t, dt);
    case 3:
      return 1.0 - 4.0 * fabs(t - 0.5);
    default:
      return sin(t * 2.0 * M_PI);
  }
}

static double QuantizeWave(double value, int bitDepth)
{
  if (bitDepth < 2) return value;
  int safeDepth = ClampInt(bitDepth, 2, 16);
  double levels = (double)((1u << safeDepth) - 1u);
  double normalized = ClampDouble((value + 1.0) * 0.5, 0.0, 1.0);
  return round(normalized * levels) / levels * 2.0 - 1.0;
}

static double RenderWavetable(double phase, const double *table, int tableSize)
{
  if (tableSize < 2) return sin((phase - floor(phase)) * 2.0 * M_PI);
  double t = phase - floor(phase);
  int index = MIN(tableSize - 1, (int)(t * tableSize));
  return table[index];
}

// splitmix64-style noise: returns a value in [-1, 1]
static double LcgNoise(uint64_t *state)
{
  *state += 0x9e3779b97f4a7c15ULL;
  uint64_t z = *state;
  z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
  z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
  z ^= (z >> 31);
  return (double)(int64_t)z / (double)0x7FFFFFFFFFFFFFFFLL;
}

static BOOL ParseFiniteDoubleFromAny(id value, double *outValue)
{
  if ([value isKindOfClass:[NSNumber class]]) {
    double parsed = [(NSNumber *)value doubleValue];
    if (!isfinite(parsed)) return NO;
    *outValue = parsed;
    return YES;
  }
  if ([value isKindOfClass:[NSString class]]) {
    NSScanner *scanner = [NSScanner scannerWithString:(NSString *)value];
    double parsed = 0.0;
    if (![scanner scanDouble:&parsed]) return NO;
    if (![scanner isAtEnd] || !isfinite(parsed)) return NO;
    *outValue = parsed;
    return YES;
  }
  return NO;
}

static BOOL ParseStrictIntegerFromAny(id value, NSInteger *outValue)
{
  double parsed = 0.0;
  if (!ParseFiniteDoubleFromAny(value, &parsed)) return NO;
  double rounded = nearbyint(parsed);
  if (fabs(parsed - rounded) > 1e-9) return NO;
  if (rounded < (double)INT_MIN || rounded > (double)INT_MAX) return NO;
  *outValue = (NSInteger)rounded;
  return YES;
}

static void CopyWaveTableFromOptions(NSDictionary *options,
                                     const double *fallback, int fallbackSize,
                                     double *destination, int *outSize)
{
  int count = ClampInt(fallbackSize, 0, WAVETABLE_MAX_SAMPLES);
  if (count > 0 && fallback != NULL) {
    memcpy(destination, fallback, count * sizeof(double));
  }
  id raw = [options objectForKey:@"waveTable"];
  if ([raw isKindOfClass:[NSArray class]]) {
    NSArray *values = (NSArray *)raw;
    count = MIN((int)values.count, WAVETABLE_MAX_SAMPLES);
    for (int i = 0; i < count; i++) {
      double value = 0.0;
      if (ParseFiniteDoubleFromAny(values[i], &value)) {
        destination[i] = ClampDouble(value, -1.0, 1.0);
      } else {
        destination[i] = 0.0;
      }
    }
  }
  *outSize = count;
}

// ---------------------------------------------------------------------------
// Note name parser
// Supports: C4, F#4, Bb3, Do4, Fa#4, Sib3 → returns -1 on failure
// ---------------------------------------------------------------------------
static double ParseNoteToFrequency(NSString *noteName)
{
  if (noteName == nil || noteName.length == 0) return -1.0;
  NSString *s     = [noteName stringByTrimmingCharactersInSet:
                     [NSCharacterSet whitespaceCharacterSet]];
  NSString *upper = [s uppercaseString];
  NSUInteger pos  = 0;
  int semitone    = -1;

  if ([upper hasPrefix:@"SOL"])     { semitone = 7;  pos = 3; }
  else if ([upper hasPrefix:@"DO"]) { semitone = 0;  pos = 2; }
  else if ([upper hasPrefix:@"RE"]) { semitone = 2;  pos = 2; }
  else if ([upper hasPrefix:@"MI"]) { semitone = 4;  pos = 2; }
  else if ([upper hasPrefix:@"FA"]) { semitone = 5;  pos = 2; }
  else if ([upper hasPrefix:@"LA"]) { semitone = 9;  pos = 2; }
  else if ([upper hasPrefix:@"SI"]) { semitone = 11; pos = 2; }
  else if ([upper hasPrefix:@"TI"]) { semitone = 11; pos = 2; }
  else {
    pos = 1;
    if (s.length == 0) return -1.0;
    unichar c = [upper characterAtIndex:0];
    switch (c) {
      case 'C': semitone = 0;  break;
      case 'D': semitone = 2;  break;
      case 'E': semitone = 4;  break;
      case 'F': semitone = 5;  break;
      case 'G': semitone = 7;  break;
      case 'A': semitone = 9;  break;
      case 'B': semitone = 11; break;
      default:  return -1.0;
    }
  }

  // Accidental (use original string: lowercase 'b' = flat)
  if (pos < s.length) {
    unichar acc = [s characterAtIndex:pos];
    if (acc == '#') { semitone++; pos++; }
    else if (acc == 'b') { semitone--; pos++; }
  }

  // Octave digit, default 4
  int octave = 4;
  if (pos < s.length) {
    unichar c = [s characterAtIndex:pos];
    if (c >= '0' && c <= '9') octave = (int)(c - '0');
  }

  int midi = (octave + 1) * 12 + semitone;
  return 440.0 * pow(2.0, (midi - 69.0) / 12.0);
}

// ---------------------------------------------------------------------------
// Expressive controls: decay, sustain, filter, FM and detune. Options are
// already validated; a step reads its own keys over the values it inherits.
// ---------------------------------------------------------------------------

typedef struct {
  NSInteger decayMs;
  double sustain;
  int    filterType;
  double filterHz;
  double filterHzEnd;
  double filterQ;
  double fmRatio;
  double fmDepth;
  double fmDepthEnd;
  BOOL   hasFmDepthEnd;
  double detune;
  BOOL spatial;
  double spatialX, spatialY;
} ExpressiveParams;

static ExpressiveParams ExpressiveDefaults(void)
{
  ExpressiveParams p;
  p.decayMs = 0;
  p.sustain = 1.0;
  p.filterType = SYNTH_FILTER_NONE;
  p.filterHz = 1000.0;
  p.filterHzEnd = 0.0;
  p.filterQ = 0.7071;
  p.fmRatio = 1.0;
  p.fmDepth = 0.0;
  p.fmDepthEnd = 0.0;
  p.hasFmDepthEnd = NO;
  p.detune = 0.0;
  p.spatial = NO; p.spatialX = p.spatialY = 0.0;
  return p;
}

static int FilterTypeFromString(NSString *raw)
{
  NSString *value = [[raw stringByTrimmingCharactersInSet:
                      [NSCharacterSet whitespaceAndNewlineCharacterSet]] lowercaseString];
  if ([value isEqualToString:@"lowpass"]) return SYNTH_FILTER_LOWPASS;
  if ([value isEqualToString:@"highpass"]) return SYNTH_FILTER_HIGHPASS;
  if ([value isEqualToString:@"bandpass"]) return SYNTH_FILTER_BANDPASS;
  return SYNTH_FILTER_NONE;
}

static ExpressiveParams ReadExpressiveParams(NSDictionary *options, ExpressiveParams inherited)
{
  ExpressiveParams p = inherited;
  double v = 0.0;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"spatialX"], &v)) { p.spatialX = v; p.spatial = YES; }
  if (ParseFiniteDoubleFromAny([options objectForKey:@"spatialY"], &v)) { p.spatialY = v; p.spatial = YES; }
  if (ParseFiniteDoubleFromAny([options objectForKey:@"decay"], &v)) p.decayMs = (NSInteger)llround(v);
  if (ParseFiniteDoubleFromAny([options objectForKey:@"sustain"], &v)) p.sustain = v;
  id filterType = [options objectForKey:@"filterType"];
  if ([filterType isKindOfClass:[NSString class]]) p.filterType = FilterTypeFromString(filterType);
  if (ParseFiniteDoubleFromAny([options objectForKey:@"filterHz"], &v)) p.filterHz = v;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"filterHzEnd"], &v)) p.filterHzEnd = v;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"filterQ"], &v)) p.filterQ = v;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"fmRatio"], &v)) p.fmRatio = v;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"fmDepth"], &v)) p.fmDepth = v;
  if (ParseFiniteDoubleFromAny([options objectForKey:@"fmDepthEnd"], &v)) {
    p.fmDepthEnd = v;
    p.hasFmDepthEnd = YES;
  }
  if (ParseFiniteDoubleFromAny([options objectForKey:@"detune"], &v)) p.detune = v;
  return p;
}

static void ApplyExpressiveParams(SynthCommand *cmd, const ExpressiveParams *p, double sampleRate)
{
  cmd->decaySamples  = MAX(0, MsToSamples((int)p->decayMs, sampleRate));
  cmd->sustain       = p->sustain;
  cmd->filterType    = p->filterType;
  cmd->filterHz      = p->filterHz;
  cmd->filterHzEnd   = p->filterHzEnd;
  cmd->filterQ       = p->filterQ;
  cmd->fmRatio       = p->fmRatio;
  cmd->fmDepth       = p->fmDepth;
  cmd->fmDepthEnd    = p->fmDepthEnd;
  cmd->hasFmDepthEnd = p->hasFmDepthEnd;
  cmd->spatial = p->spatial;
  cmd->spatialX = p->spatialX; cmd->spatialY = p->spatialY;
}

static double DetunedFrequency(double frequency, double cents, double maxFrequency)
{
  if (cents == 0.0) return frequency;
  return ClampDouble(frequency * synth_cents_ratio(cents), MIN_FREQUENCY_HZ, maxFrequency);
}

// ---------------------------------------------------------------------------
// Module interface
// ---------------------------------------------------------------------------

static unsigned StudioModCapabilities(int wave,int filter) {
 return (filter?SYNTH_MOD_CAP_FILTER:0)|(wave==1?SYNTH_MOD_CAP_PWM:0)|(wave==0?SYNTH_MOD_CAP_FM:0);
}
static unsigned StudioModCapabilitiesFromMask(uint32_t mask) {
 return ((mask&(1u<<LIVE_FILTER_HZ))?SYNTH_MOD_CAP_FILTER:0)|((mask&(1u<<LIVE_PULSE_WIDTH))?SYNTH_MOD_CAP_PWM:0)|((mask&(1u<<LIVE_FM_DEPTH))?SYNTH_MOD_CAP_FM:0);
}
static SynthModulationConfig StudioModulationFromValues(const double *v) {
 SynthModulationConfig m=synth_modulation_default_config();
 for(int i=0;i<2;i++){const double *p=v+i*6;m.lfo[i].enabled=(int)p[0];m.lfo[i].waveform=(int)p[1];m.lfo[i].target=(int)p[2];m.lfo[i].rateHz=p[3];m.lfo[i].depth=p[4];m.lfo[i].syncBeats=p[5];}return m;
}
static SynthCommand StudioSequenceCommand(const SynthSequenceVoice *v,double rate) {
 SynthCommand c;memset(&c,0,sizeof(c));c.type=SYNTH_CMD_HELD_ON;c.volume=v->volume;c.pan=c.panEnd=v->pan;
 c.attackSamples=MsToSamples(v->attack,rate);c.decaySamples=MsToSamples(v->decay,rate);c.releaseSamples=MsToSamples(v->release,rate);c.sustain=v->sustain;
 c.waveType=v->waveType;c.lfoFreq=v->lfoFreq;c.lfoDepth=v->lfoDepth;c.noiseRate=v->noiseRate;c.lowPassHz=v->lowPassHz;c.pulseWidth=v->pulseWidth;c.bitDepth=v->bitDepth;
 c.filterType=v->filterType;c.filterHz=v->filterHz;c.filterQ=v->filterQ;c.fmRatio=v->fmRatio;c.fmDepth=v->fmDepth;
 c.frequencyEnd=v->frequencyEnd;c.noiseRateEnd=v->noiseRateEnd;c.panEnd=v->panEnd;c.pulseWidthEnd=v->pulseWidthEnd;c.filterHzEnd=v->filterHzEnd;c.fmDepthEnd=v->fmDepthEnd;c.hasFmDepthEnd=v->fmDepthSweep;
 c.bus=v->bus;c.effectSend=v->effectSend;c.priority=v->priority;c.spatial=v->spatial;c.spatialX=v->spatialX;c.spatialY=v->spatialY;c.wavetableSize=v->wavetableSize;memcpy(c.wavetable,v->wavetable,sizeof(c.wavetable));
 c.modulation=StudioModulationFromValues(v->mods);c.hasModulations=v->mods[0]||v->mods[6];return c;
}

@interface TiSynthengineModule () {
  SynthTransport *sequence;
  NSMutableDictionary *sequenceOptions;
  SynthEffects effects;
  SynthEffectsConfig processingOptions;
  int32_t sequenceVoiceId;
  SynthStats stats;
  uint64_t statsRejected[3], priorityDrops,rejectedPublications;
  BOOL statsEnabled;
  mach_timebase_info_data_t statsTimebase;
  AVAudioEngine      *audioEngine;
  AVAudioSourceNode  *sourceNode;

  int    engineMaxVoices;
  double engineSampleRate;

  SynthVoice    voices[ABSOLUTE_MAX_VOICES];
  SynthLiveIdentity identities[ABSOLUTE_MAX_VOICES];
  _Atomic(uint32_t) identityPriority[ABSOLUTE_MAX_VOICES];
  uint64_t voiceOrder,batchOrder;int batchRemaining;
  NSMutableDictionary *voiceGenerations,*voicePositions,*voiceSpatialModes;
  uint64_t nextVoiceGeneration;
  TailVoice     tails[ABSOLUTE_MAX_VOICES];
  SynthCommand  commandQueue[COMMAND_QUEUE_CAPACITY];

  _Atomic(uint32_t) commandWriteIndex;
  _Atomic(uint32_t) commandReadIndex;
  os_unfair_lock commandProducerLock;

  int    stopFadeSamples;
  int    stealFadeSamples;
  _Atomic(bool) emergencyStopRequested;
  _Atomic(bool) emergencyShutdownRequested;

  // Atomic master volume: written by main thread, read by audio thread
  _Atomic(double) masterVolume;

  dispatch_source_t sequenceEventTimer;
  uint64_t sequenceEventGeneration;
  uint32_t nextSequenceId;

  NSMutableSet *warningKeys;

  // Peak limiter state (render-thread only)
  double smoothedMasterGain;
  double masterGainTarget;
  double masterGainStep;
  int masterGainFramesRemaining;
  double smoothedGain;
  int mixingProfile;
  double gainReleaseCoeff;
  double limiterAttackTarget;
  double limiterAttackStep;

  // Lookahead buffer: delays audio so gain settles before the signal is output
  double *lookaheadL;
  double *lookaheadR;
  double *lookaheadPeaks;
  int64_t *lookaheadPeakIndices;
  int    lookaheadSize;
  int    lookaheadIdx;
  int    lookaheadPeakHead;
  int    lookaheadPeakCount;
  int64_t limiterSampleIndex;

  BOOL observingAudioNotifications;
  AVAudioSessionCategory audioSessionCategory;
}
@end

@implementation TiSynthengineModule

- (id)moduleGUID
{
  return @"ee6624e0-d373-4cf9-8849-a1f034594518";
}

- (NSString *)moduleId
{
  return @"ti.synthengine";
}

- (void)startup
{
  [super startup];
  synth_stats_init(&stats);
  mach_timebase_info(&statsTimebase);
  warningKeys = [[NSMutableSet alloc] init];voiceGenerations=[NSMutableDictionary dictionary];voicePositions=[NSMutableDictionary dictionary];voiceSpatialModes=[NSMutableDictionary dictionary];
  engineSampleRate = DEFAULT_SAMPLE_RATE;
  engineMaxVoices  = 8;
  atomic_store_explicit(&commandWriteIndex, 0, memory_order_relaxed);
  atomic_store_explicit(&commandReadIndex,  0, memory_order_relaxed);
  commandProducerLock = OS_UNFAIR_LOCK_INIT;
  atomic_store_explicit(&masterVolume,      1.0, memory_order_relaxed);
  atomic_store_explicit(&emergencyStopRequested, false, memory_order_relaxed);
  atomic_store_explicit(&emergencyShutdownRequested, false, memory_order_relaxed);
  if (!observingAudioNotifications) {
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self selector:@selector(audioRouteDidChange:)
                   name:AVAudioSessionRouteChangeNotification object:nil];
    [center addObserver:self selector:@selector(audioEngineConfigurationDidChange:)
                   name:AVAudioEngineConfigurationChangeNotification object:nil];
    observingAudioNotifications = YES;
  }
  DebugLog(@"[DEBUG] %@ loaded", self);
}

- (void)resumeAudioEngineAfterRouteChange:(NSString *)reason
{
  dispatch_async(dispatch_get_main_queue(), ^{
    @synchronized(self) {
    if (self->audioEngine == nil || [self->audioEngine isRunning]) return;

    NSError *sessionError = nil;
    AVAudioSession *session = [AVAudioSession sharedInstance];
    if (self->audioSessionCategory != nil
        && ![session.category isEqualToString:self->audioSessionCategory]) {
      NSError *categoryError = nil;
      [session setCategory:self->audioSessionCategory error:&categoryError];
      if (categoryError != nil) {
        DebugLog(@"[ERROR] Unable to reapply audio category after %@: %@",
                 reason, categoryError.localizedDescription);
      }
    }
    [session setActive:YES error:&sessionError];
    if (sessionError != nil) {
      DebugLog(@"[ERROR] Unable to reactivate audio after %@: %@",
               reason, sessionError.localizedDescription);
      return;
    }

    NSError *engineError = nil;
    BOOL started = [self->audioEngine startAndReturnError:&engineError];
    if (!started || engineError != nil) {
      DebugLog(@"[ERROR] Unable to resume audio after %@: %@",
               reason, engineError.localizedDescription);
    }
    }
  });
}

- (void)audioRouteDidChange:(NSNotification *)notification
{
#pragma unused(notification)
  [self resumeAudioEngineAfterRouteChange:@"route change"];
}

- (void)audioEngineConfigurationDidChange:(NSNotification *)notification
{
#pragma unused(notification)
  [self resumeAudioEngineAfterRouteChange:@"engine configuration change"];
}

// ---------------------------------------------------------------------------
#pragma mark - Warning helpers
// ---------------------------------------------------------------------------

- (void)warnOnceMethod:(NSString *)method key:(NSString *)key reason:(NSString *)reason
                 value:(id)value action:(NSString *)action
{
  if (warningKeys == nil) warningKeys = [[NSMutableSet alloc] init];
  NSString *onceKey = [NSString stringWithFormat:@"%@:%@:%@", method, key, reason];
  @synchronized(warningKeys) {
    if ([warningKeys containsObject:onceKey]) return;
    [warningKeys addObject:onceKey];
  }
  DebugLog(@"[WARN] event=validation_warning method=%@ key=%@ reason=%@ action=%@ value=%@",
           method, key, reason, action, value);
}

- (BOOL)acceptValidation:(NSDictionary *)failure method:(NSString *)method
{
  if (failure == nil) return YES;
  __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED);
  [self warnOnceMethod:method
                   key:[failure objectForKey:@"key"]
                reason:[failure objectForKey:@"reason"]
                 value:[failure objectForKey:@"value"]
                action:@"rejected"];
  return NO;
}

- (BOOL)containsRawKey:(NSDictionary *)dict key:(NSString *)key
{
  return (dict != nil) && ([dict objectForKey:key] != nil);
}

- (double)maxFrequencyHz
{
  double sr = isfinite(engineSampleRate) && engineSampleRate > 0.0
            ? engineSampleRate : DEFAULT_SAMPLE_RATE;
  return sr * 0.45;
}

// ---------------------------------------------------------------------------
#pragma mark - Option readers
// ---------------------------------------------------------------------------

- (BOOL)readRequiredDoubleFrom:(NSDictionary *)options method:(NSString *)method
                           key:(NSString *)key out:(double *)outValue
{
  if (![self containsRawKey:options key:key]) {
    [self warnOnceMethod:method key:key reason:@"missing_required" value:@"null" action:@"ignored"];
    return NO;
  }
  id raw = [options objectForKey:key];
  double parsed = 0.0;
  if (!ParseFiniteDoubleFromAny(raw, &parsed)) {
    [self warnOnceMethod:method key:key reason:@"non_numeric_or_non_finite" value:raw action:@"ignored"];
    return NO;
  }
  *outValue = parsed;
  return YES;
}

- (BOOL)readRequiredIntegerFrom:(NSDictionary *)options method:(NSString *)method
                            key:(NSString *)key out:(NSInteger *)outValue
{
  if (![self containsRawKey:options key:key]) {
    [self warnOnceMethod:method key:key reason:@"missing_required" value:@"null" action:@"ignored"];
    return NO;
  }
  id raw = [options objectForKey:key];
  NSInteger parsed = 0;
  if (!ParseStrictIntegerFromAny(raw, &parsed)) {
    [self warnOnceMethod:method key:key reason:@"non_integer_or_non_finite" value:raw action:@"ignored"];
    return NO;
  }
  *outValue = parsed;
  return YES;
}

- (BOOL)readOptionalIntegerFrom:(NSDictionary *)options method:(NSString *)method
                            key:(NSString *)key defaultValue:(NSInteger)defaultValue
                            min:(NSInteger)minValue max:(NSInteger)maxValue
                            out:(NSInteger *)outValue
{
  if (![self containsRawKey:options key:key]) { *outValue = defaultValue; return YES; }
  id raw = [options objectForKey:key];
  NSInteger parsed = 0;
  if (!ParseStrictIntegerFromAny(raw, &parsed)) {
    [self warnOnceMethod:method key:key reason:@"non_integer_or_non_finite" value:raw action:@"fallback_default"];
    *outValue = defaultValue;
    return YES;
  }
  NSInteger clamped = MAX(minValue, MIN(maxValue, parsed));
  if (clamped != parsed) {
    [self warnOnceMethod:method key:key reason:@"out_of_range" value:raw action:@"clamped"];
  }
  *outValue = clamped;
  return YES;
}

- (BOOL)readOptionalDoubleFrom:(NSDictionary *)options method:(NSString *)method
                           key:(NSString *)key defaultValue:(double)defaultValue
                           min:(double)minValue max:(double)maxValue
                           out:(double *)outValue
{
  if (![self containsRawKey:options key:key]) { *outValue = defaultValue; return YES; }
  id raw = [options objectForKey:key];
  double parsed = 0.0;
  if (!ParseFiniteDoubleFromAny(raw, &parsed)) {
    [self warnOnceMethod:method key:key reason:@"non_numeric_or_non_finite" value:raw action:@"fallback_default"];
    *outValue = defaultValue;
    return YES;
  }
  double clamped = ClampDouble(parsed, minValue, maxValue);
  if (clamped != parsed) {
    [self warnOnceMethod:method key:key reason:@"out_of_range" value:raw action:@"clamped"];
  }
  *outValue = clamped;
  return YES;
}

// ---------------------------------------------------------------------------
#pragma mark - Voice management
// ---------------------------------------------------------------------------

- (void)clearVoices
{
  for (int i = 0; i < ABSOLUTE_MAX_VOICES; i++) {
    voices[i].isActive      = false;
    memset(&voices[i].held,0,sizeof(SynthHeld));
    synth_identity_set(&identities[i],0,0);
    voices[i].phase         = 0.0;
    voices[i].phaseIncrement= 0.0;
    voices[i].totalSamples  = 0;
    voices[i].samplesPlayed = 0;
    voices[i].attackSamples = 0;
    voices[i].releaseSamples= 0;
    voices[i].volume        = VOLUME_DEFAULT;
    voices[i].currentEnvelope = 0.0;
    voices[i].waveType      = 0;
    voices[i].pan           = 0.0;
    voices[i].panDelta      = 0.0;
    voices[i].leftGain      = M_SQRT1_2;
    voices[i].rightGain     = M_SQRT1_2;
    voices[i].lfoDepth      = 0.0;
    voices[i].noisePhase    = 0.0;
    voices[i].noisePhaseIncrement = 1.0;
    voices[i].noisePhaseIncrDelta = 0.0;
    voices[i].heldNoise     = 0.0;
    voices[i].filterState   = 0.0;
    voices[i].filterAlpha   = 0.0;
    voices[i].pulseWidth    = 0.5;
    voices[i].pulseWidthDelta = 0.0;
    voices[i].bitDepth      = 0;
    voices[i].wavetableSize = 0;
    voices[i].decaySamples  = 0;
    voices[i].sustain       = 1.0;
    voices[i].svfSweeping   = false;
    voices[i].fmActive      = false;
    tails[i].isActive       = false;
  }
  synth_stats_stopped(&stats);
  // Clear lookahead buffer to prevent stale audio leaking after stop
  if (lookaheadL && lookaheadR) {
    memset(lookaheadL, 0, lookaheadSize * sizeof(double));
    memset(lookaheadR, 0, lookaheadSize * sizeof(double));
  }
  smoothedGain = 1.0;
  smoothedMasterGain = 1.0;
  masterGainTarget = 1.0;
  masterGainStep = 0.0;
  masterGainFramesRemaining = 0;
  limiterAttackTarget = 1.0;
  limiterAttackStep = 0.0;
  lookaheadPeakHead = 0;
  lookaheadPeakCount = 0;
  limiterSampleIndex = 0;
}

- (void)updatePanGainsForVoice:(SynthVoice *)voice
{
  double angle = (voice->pan + 1.0) * M_PI * 0.25;
  voice->leftGain = cos(angle);
  voice->rightGain = sin(angle);
}

- (TailVoice *)findTailSlot
{
  TailVoice *fallback = &tails[0];
  for (int i = 0; i < engineMaxVoices; i++) {
    TailVoice *tail = &tails[i];
    if (!tail->isActive) return tail;
    if (tail->samplesRemaining < fallback->samplesRemaining) fallback = tail;
  }
  return fallback;
}

- (void)snapshotTailFromVoice:(SynthVoice *)voice fadeSamples:(int)fadeSamples
{
  TailVoice *tail = [self findTailSlot];
  synth_stats_tail_start(&stats, tail->isActive);
  tail->send=voice->send;tail->bus=voice->bus;tail->effectSend=voice->effectSend;
  tail->isActive = true;
  tail->spatial = voice->spatial;
  if (tail->spatial) {
    tail->spatialState = voice->spatialState;
    tail->spatialDrain = tail->spatialState.taps - 1;
  }
  tail->phase = voice->phase;
  tail->phaseIncrement = ClampDouble(voice->phaseIncrement, -0.45, 0.45);
  tail->volume = voice->volume * ClampDouble(voice->currentEnvelope, 0.0, 1.0);
  tail->waveType = voice->waveType;
  tail->leftGain = voice->leftGain;
  tail->rightGain = voice->rightGain;
  tail->noiseState = voice->noiseState;
  tail->noisePhase = voice->noisePhase;
  tail->noisePhaseIncrement = voice->noisePhaseIncrement;
  tail->heldNoise = voice->heldNoise;
  tail->filterState = voice->filterState;
  tail->filterAlpha = voice->filterAlpha;
  tail->pulseWidth = voice->pulseWidth;
  tail->bitDepth = voice->bitDepth;
  tail->wavetableSize = voice->wavetableSize;
  if (tail->wavetableSize > 0) {
    memcpy(tail->wavetable, voice->wavetable,
           tail->wavetableSize * sizeof(double));
  }
  tail->svf = voice->svf;
  tail->fmActive = voice->fmActive;
  tail->fmRatio = voice->fmRatio;
  tail->fmModPhase = voice->fmModPhase;
  tail->fmDepth = voice->fmDepth;
  tail->totalSamples = MAX(1, fadeSamples);
  tail->samplesRemaining = tail->totalSamples;
}

- (void)fadeOutAllVoices
{
  for (int i = 0; i < engineMaxVoices; i++) {
    SynthVoice *voice = &voices[i];
    if (!voice->isActive) continue;
    [self snapshotTailFromVoice:voice fadeSamples:stopFadeSamples];
    synth_stats_voice_end(&stats, voice->spatial);
    voice->isActive = false;
    synth_identity_set(&identities[i],0,0);
  }
  // Panic fades stay dry so they cannot refill the invalidated FX histories.
  for(int i=0;i<engineMaxVoices;i++)if(tails[i].isActive) {
    tails[i].effectSend=0;
    synth_send_init(&tails[i].send,tails[i].bus,0,effects.config.applyToMask);
  }
}

- (BOOL)canAdmitCount:(int)count priority:(int)priority
{
 int available=0;for(int i=0;i<engineMaxVoices;i++)if(!voices[i].isActive||voices[i].priority<=priority)available++;return available>=count;
}
- (int)findVoiceSlotForCommand:(const SynthCommand *)cmd
{
  BOOL heldPool=cmd->voiceId!=0;
  for(int i=0;i<engineMaxVoices;i++) {
    if(voices[i].isActive && cmd->voiceId && voices[i].held.voiceId==cmd->voiceId)return voices[i].priority<=cmd->priority?i:-1;
    if(voices[i].isActive && voices[i].held.voiceId)heldPool=YES;
  }
  int slot=-1, leastRemaining=INT_MAX; BOOL chosenRelease=NO;
  for(int i=0;i<engineMaxVoices;i++) {
    SynthVoice *v=&voices[i]; if(!v->isActive)return i;
    if(v->priority>cmd->priority||(batchRemaining>0&&v->held.order>batchOrder))continue;
    int remaining=v->totalSamples-v->samplesPlayed;
    BOOL releasing=v->held.voiceId ? v->held.releasing!=0 : remaining<=v->releaseSamples;
    if(slot<0 || v->priority<voices[slot].priority || (v->priority==voices[slot].priority && (heldPool ? (releasing!=chosenRelease ? releasing : v->held.order<voices[slot].held.order) : remaining<leastRemaining))) {
      slot=i; leastRemaining=remaining; chosenRelease=releasing;
    }
  }
  return slot;
}

- (void)startVoiceFromCommand:(const SynthCommand *)cmd
{
  // Capture before slot reuse; only public, stable held-key release tails donate.
  BOOL inherit=NO; uint64_t donorOrder=0;
  double inheritedPhase=0,inheritedFM=0,inheritedLFO=0,inheritedFilterState=0;
  SynthFilter inheritedFilter={0};
  if(cmd->voiceId>0 && !cmd->sequenceGeneration &&
     (!cmd->hasModulations || (!cmd->modulation.lfo[0].enabled && !cmd->modulation.lfo[1].enabled)) &&
     cmd->frequencyEnd<MIN_FREQUENCY_HZ && cmd->pulseWidthEnd<.05 &&
     cmd->filterHzEnd<SYNTH_FILTER_MIN_HZ && !cmd->hasFmDepthEnd) {
    double values[SYNTH_LIVE_COUNT]={cmd->frequency,cmd->volume,cmd->filterHz,cmd->filterQ,cmd->lfoFreq,cmd->lfoDepth,cmd->pulseWidth,cmd->fmRatio,cmd->fmDepth,cmd->noiseRate>0?cmd->noiseRate/engineSampleRate:1,cmd->lowPassHz>0?1-exp(-2*M_PI*cmd->lowPassHz/engineSampleRate):1,cmd->pan};
    double cutoff=ClampDouble(cmd->lowPassHz,0,engineSampleRate*.45);
    SynthRetriggerKey next={cmd->waveType,cmd->filterType,cmd->bitDepth,cmd->wavetableSize,cutoff>0?1-exp(-2*M_PI*cutoff/engineSampleRate):0,values,cmd->wavetable};
    for(int i=0;i<engineMaxVoices;i++) {
      const SynthVoice *d=&voices[i];
      if(!d->isActive || d->held.voiceId<=0 || !d->held.releasing || d->held.releasePlayed>=d->releaseSamples ||
         d->samplesPlayed>=d->totalSamples || d->sequenceGeneration || d->phaseIncrDelta || d->pulseWidthDelta ||
         d->fmDepthDelta || d->svfSweeping || synth_modulation_is_active(&d->modulation))continue;
      SynthRetriggerKey old={d->waveType,d->svf.type,d->bitDepth,d->wavetableSize,d->filterAlpha,d->live.value,d->wavetable};
      if(d->held.order>donorOrder && synth_retrigger_compatible(&d->live,&old,&next)) {
        inherit=YES;donorOrder=d->held.order;inheritedPhase=d->phase;inheritedFM=d->fmModPhase;
        inheritedLFO=d->lfoPhase;inheritedFilterState=d->filterState;inheritedFilter=d->svf;
      }
    }
  }
  int slot    = [self findVoiceSlotForCommand:cmd];
  if(slot<0){__atomic_fetch_add(&priorityDrops,1,__ATOMIC_RELAXED);return;}
  SynthVoice *v = &voices[slot];
  BOOL replacing=v->isActive;
  synth_stats_voice_start(&stats, v->isActive, v->spatial, cmd->spatial);
  if (v->isActive) [self snapshotTailFromVoice:v fadeSamples:stealFadeSamples];

  v->priority=cmd->priority;v->bus=cmd->bus;v->effectSend=cmd->effectSend;synth_send_init(&v->send,v->bus,v->effectSend,effects.config.applyToMask);
  v->sequenceSlot=cmd->sequenceSlot;v->sequenceId=cmd->sequenceId;v->sequenceTimeUnit=cmd->sequenceTimeUnit;v->voiceGeneration=cmd->voiceGeneration;
  v->sequenceStartClock=sequence?(cmd->sequenceTimeUnit==SYNTH_SEQUENCE_MS?sequence->milliseconds:sequence->beat):0;
  v->sequenceLength=cmd->sequenceOffBeat-v->sequenceStartClock;v->sequenceFrequencyEnd=cmd->frequencyEnd;v->sequenceNoiseEnd=cmd->noiseRateEnd;v->sequencePanEnd=cmd->panEnd;v->sequencePulseEnd=cmd->pulseWidthEnd;v->sequenceFMEnd=cmd->fmDepthEnd;v->sequenceFMSweep=cmd->hasFmDepthEnd;
  v->isActive       = true;
  v->sequenceGeneration=cmd->sequenceGeneration;v->sequenceOffBeat=cmd->sequenceOffBeat;
  v->sequenceStep=cmd->sequenceStep;v->sequenceMidi=cmd->sequenceMidi;
  synth_modulation_init(&v->modulation,engineSampleRate);
  v->modulationFrames=0;v->modulating=cmd->hasModulations;
  if(cmd->hasModulations)synth_modulation_set_config(&v->modulation,&cmd->modulation,StudioModCapabilities(cmd->waveType,cmd->filterType));
  memset(&v->held,0,sizeof(v->held)); v->held.voiceId=cmd->voiceId; v->held.order=++voiceOrder;
  atomic_store_explicit(&identityPriority[slot],cmd->priority,memory_order_release);
  synth_identity_set(&identities[slot],cmd->voiceId,synth_live_allowed(cmd->waveType,cmd->filterType));
  v->spatial = cmd->spatial;
  if (v->spatial) {
    synth_spatial_init(&v->spatialState, cmd->spatialX, cmd->spatialY, engineSampleRate);
    v->spatialDrain = v->spatialState.taps - 1;
  }
  v->phase          = 0.0;
  v->totalSamples   = cmd->voiceId ? INT_MAX : MAX(1, cmd->durationSamples);
  v->samplesPlayed  = 0;
  v->attackSamples  = MAX(0, cmd->attackSamples);
  if(cmd->voiceId && replacing)v->attackSamples=MAX(v->attackSamples,stealFadeSamples);
  v->releaseSamples = MAX(0, cmd->releaseSamples);
    if(cmd->voiceId) {
      int edge=synth_held_edge_samples(engineSampleRate);
      v->attackSamples=MAX(v->attackSamples,edge);
      v->releaseSamples=MAX(v->releaseSamples,edge);
    }
  v->currentEnvelope= 0.0;
  v->waveType       = ClampInt(cmd->waveType, 0, 5);
  v->volume         = ClampDouble(cmd->volume, VOLUME_MIN, VOLUME_MAX)
                    * VoiceGainForEvent(mixingProfile, v->waveType,
                                        cmd->eventVoiceCount);
  v->pan            = ClampDouble(cmd->pan, -1.0, 1.0);
  [self updatePanGainsForVoice:v];

  v->phaseIncrement = cmd->frequency / engineSampleRate;

  // Pitch sweep
  double freqEnd = cmd->frequencyEnd;
  if (freqEnd >= MIN_FREQUENCY_HZ && v->totalSamples > 1) {
    double phaseIncrEnd = freqEnd / engineSampleRate;
    v->phaseIncrDelta = (phaseIncrEnd - v->phaseIncrement) / (v->totalSamples - 1);
  } else {
    v->phaseIncrDelta = 0.0;
  }

  // Pan sweep
  double panEnd = ClampDouble(cmd->panEnd, -1.0, 1.0);
  if (panEnd != v->pan && v->totalSamples > 1) {
    v->panDelta = (panEnd - v->pan) / (v->totalSamples - 1);
  } else {
    v->panDelta = 0.0;
  }

  // LFO
  v->lfoDepth          = ClampDouble(cmd->lfoDepth, 0.0, 20000.0);
  v->lfoPhase          = 0.0;
  double lfoFreq       = cmd->lfoFreq;
  v->lfoPhaseIncrement = lfoFreq > 0.0 ? lfoFreq / engineSampleRate : 0.0;

  // Variable-rate sample-and-hold noise. A zero rate preserves 1.0 behavior:
  // a fresh white-noise value for every output sample.
  double noiseRate = cmd->noiseRate > 0.0
                   ? ClampDouble(cmd->noiseRate, 1.0, engineSampleRate * 0.45)
                   : engineSampleRate;
  v->noisePhase = 0.0;
  v->noisePhaseIncrement = noiseRate / engineSampleRate;
  if (cmd->noiseRateEnd >= 1.0 && v->totalSamples > 1) {
    double noiseEnd = ClampDouble(cmd->noiseRateEnd, 1.0, engineSampleRate * 0.45)
                    / engineSampleRate;
    v->noisePhaseIncrDelta = (noiseEnd - v->noisePhaseIncrement)
                           / (v->totalSamples - 1);
  } else {
    v->noisePhaseIncrDelta = 0.0;
  }

  double cutoff = ClampDouble(cmd->lowPassHz, 0.0, engineSampleRate * 0.45);
  v->filterState = 0.0;
  v->filterAlpha = cutoff > 0.0
                 ? 1.0 - exp(-2.0 * M_PI * cutoff / engineSampleRate)
                 : 0.0;
  v->pulseWidth = ClampDouble(cmd->pulseWidth, 0.05, 0.95);
  if (cmd->pulseWidthEnd >= 0.05 && v->totalSamples > 1) {
    v->pulseWidthDelta = (ClampDouble(cmd->pulseWidthEnd, 0.05, 0.95)
                         - v->pulseWidth) / (v->totalSamples - 1);
  } else {
    v->pulseWidthDelta = 0.0;
  }
  v->bitDepth = cmd->bitDepth == 0 ? 0 : ClampInt(cmd->bitDepth, 2, 16);
  v->wavetableSize = ClampInt(cmd->wavetableSize, 0, WAVETABLE_MAX_SAMPLES);
  if (v->wavetableSize > 0) {
    memcpy(v->wavetable, cmd->wavetable, v->wavetableSize * sizeof(double));
  }

  // Decay and sustain
  v->decaySamples = MAX(0, cmd->decaySamples);
  v->sustain      = ClampDouble(cmd->sustain, 0.0, 1.0);

  // State-variable filter
  int filterType = ClampInt(cmd->filterType, SYNTH_FILTER_NONE, SYNTH_FILTER_BANDPASS);
  synth_filter_init(&v->svf, filterType);
  v->svfHz       = cmd->filterHz;
  v->svfHzEnd    = cmd->filterHzEnd;
  v->svfQ        = cmd->filterQ;
  v->svfSweeping = filterType != SYNTH_FILTER_NONE
                 && cmd->filterHzEnd >= SYNTH_FILTER_MIN_HZ && v->totalSamples > 1;

  // Phase modulation, sine carrier only
  v->fmActive   = (cmd->fmDepth > 0.0 || cmd->hasFmDepthEnd) && v->waveType == 0;
  v->fmRatio    = cmd->fmRatio;
  v->fmModPhase = 0.0;
  v->fmDepth    = ClampDouble(cmd->fmDepth, 0.0, 10.0);
  if (cmd->hasFmDepthEnd && v->totalSamples > 1) {
    v->fmDepthDelta = (ClampDouble(cmd->fmDepthEnd, 0.0, 10.0) - v->fmDepth)
                    / (v->totalSamples - 1);
  } else {
    v->fmDepthDelta = 0.0;
  }

  if(cmd->voiceId) {
    v->eventGain=VoiceGainForEvent(mixingProfile,v->waveType,cmd->eventVoiceCount);
    double values[SYNTH_LIVE_COUNT]={cmd->frequency,cmd->volume,cmd->filterHz,cmd->filterQ,cmd->lfoFreq,cmd->lfoDepth,cmd->pulseWidth,cmd->fmRatio,cmd->fmDepth,cmd->noiseRate>0?cmd->noiseRate/engineSampleRate:1,cmd->lowPassHz>0?1-exp(-2*M_PI*cmd->lowPassHz/engineSampleRate):1,cmd->pan};
    synth_live_init(&v->live,values); v->fmActive=v->waveType==0;
  }

  // Noise seed
  v->noiseState = (uint64_t)(mach_absolute_time()) ^ ((uint64_t)(slot + 1) * 0x9e3779b97f4a7c15ULL);
  v->heldNoise = LcgNoise(&v->noiseState);
  if(inherit) {v->phase=inheritedPhase;v->fmModPhase=inheritedFM;v->lfoPhase=inheritedLFO;v->filterState=inheritedFilterState;v->svf=inheritedFilter;}
}

// ---------------------------------------------------------------------------
#pragma mark - Command queue
// ---------------------------------------------------------------------------

- (BOOL)enqueueCommand:(SynthCommand)cmd
{
  // Serialize public producers
  // without ever taking a lock on the real-time audio consumer.
  os_unfair_lock_lock(&commandProducerLock);
  uint32_t write = atomic_load_explicit(&commandWriteIndex, memory_order_relaxed);
  uint32_t read  = atomic_load_explicit(&commandReadIndex,  memory_order_acquire);
  uint32_t next  = (write + 1) % COMMAND_QUEUE_CAPACITY;

  if (next == read) {
    // SPSC invariant: the audio thread alone advances commandReadIndex.
    if (cmd.type == CMD_STOP_ALL) {
      atomic_store_explicit(&emergencyStopRequested, true, memory_order_release);
    } else if (cmd.type == CMD_SHUTDOWN) {
      atomic_store_explicit(&emergencyShutdownRequested, true, memory_order_release);
    }
    os_unfair_lock_unlock(&commandProducerLock);
    return YES;
  }

  commandQueue[write] = cmd;
  atomic_store_explicit(&commandWriteIndex, next, memory_order_release);
  os_unfair_lock_unlock(&commandProducerLock);
  return NO;
}

- (BOOL)heldPriorityAllows:(int32_t)identifier priority:(int)priority
{
 os_unfair_lock_lock(&commandProducerLock);int current=-1,pending=-1;
 uint32_t rd=atomic_load_explicit(&commandReadIndex,memory_order_acquire),wr=atomic_load_explicit(&commandWriteIndex,memory_order_acquire);
 while(rd!=wr){SynthCommand *c=&commandQueue[rd];if(c->type==SYNTH_CMD_HELD_ON&&c->voiceId==identifier)pending=c->priority;rd=(rd+1)%COMMAND_QUEUE_CAPACITY;}
 for(int i=0;i<engineMaxVoices;i++)if(synth_identity_mask(&identities[i],identifier)>=0)current=(int)atomic_load_explicit(&identityPriority[i],memory_order_acquire);
 os_unfair_lock_unlock(&commandProducerLock);return (pending>=0?pending:current)<=priority;
}

- (int)voiceMaskForId:(int32_t)voiceId
{
  os_unfair_lock_lock(&commandProducerLock);
  int result=-1;
  for(int i=0;i<engineMaxVoices;i++){int found=synth_identity_mask(&identities[i],voiceId);if(found>=0)result=found;}
  uint32_t rd=atomic_load_explicit(&commandReadIndex,memory_order_acquire),wr=atomic_load_explicit(&commandWriteIndex,memory_order_acquire);
  while(rd!=wr) {
    SynthCommand *c=&commandQueue[rd];
    if(c->type==SYNTH_CMD_HELD_ON && c->voiceId==voiceId)result=(int)synth_live_allowed(c->waveType,c->filterType);
    rd=(rd+1)%COMMAND_QUEUE_CAPACITY;
  }
  os_unfair_lock_unlock(&commandProducerLock);
  return result;
}

- (void)applyHeldCommand:(const SynthCommand *)cmd
{
  for(int i=0;i<engineMaxVoices;i++) {
    SynthVoice *v=&voices[i];
    if(!v->isActive || v->held.voiceId!=cmd->voiceId || v->voiceGeneration!=cmd->voiceGeneration)continue;
    if(cmd->type==SYNTH_CMD_HELD_OFF)synth_held_release(&v->held,v->currentEnvelope);
    else if(!(cmd->liveMask & ~synth_live_allowed(v->waveType,v->svf.type))) {
      if(cmd->hasSendUpdate){v->effectSend=cmd->effectSend;synth_send_update(&v->send,v->bus,v->effectSend,effects.config.applyToMask,MAX(1,MsToSamples(10,engineSampleRate)));}
      if(cmd->hasSpatialUpdate&&v->spatial)synth_spatial_set_target(&v->spatialState,&cmd->preparedSpatial,MAX(1,MsToSamples(10,engineSampleRate)));
      synth_live_update(&v->live,cmd->liveMask,cmd->liveValues,MAX(1,MsToSamples(10,engineSampleRate)));
      if(cmd->hasModulations && synth_modulation_set_config(&v->modulation,&cmd->modulation,StudioModCapabilities(v->waveType,v->svf.type)))v->modulating=YES;
    }
    break;
  }
}

// Convenience for CMD_STOP_ALL / CMD_SHUTDOWN
- (BOOL)enqueueSimpleCommand:(int)type
{
  SynthCommand cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.type = type;
  return [self enqueueCommand:cmd];
}

// ---------------------------------------------------------------------------
#pragma mark - Public APIs
// ---------------------------------------------------------------------------

- (NSDictionary *)getStats:(id)args
{
  @synchronized(self) {
#pragma unused(args)
  double v[SYNTH_STATS_COUNT]; synth_stats_read(&stats,v);
  NSMutableDictionary *r=[NSMutableDictionary dictionary];
  NSArray *keys=@[@"activeVoices",@"peakActiveVoices",@"tailVoices",@"spatialVoices",@"voiceStealCount",@"callbackFrames",@"renderLoad",@"peakRenderLoad"];
  for(int i=0;i<8;i++) r[keys[i]]=isnan(v[i]) ? (id)[NSNull null] : @(v[i]);
  r[@"outputPeakDbFS"]=isnan(v[ST_PEAK_L]) ? (id)[NSNull null] : @{@"left":@(v[ST_PEAK_L]),@"right":@(v[ST_PEAK_R])};
  r[@"outputRmsDbFS"]=isnan(v[ST_RMS_L]) ? (id)[NSNull null] : @{@"left":@(v[ST_RMS_L]),@"right":@(v[ST_RMS_R])};
  r[@"limiterReductionDb"]=isnan(v[ST_REDUCTION]) ? (id)[NSNull null] : @(v[ST_REDUCTION]);
  r[@"preLimiterPeakDb"]=isnan(v[ST_PRE_LIMITER_PEAK]) ? (id)[NSNull null] : @(v[ST_PRE_LIMITER_PEAK]);
  r[@"maxLimiterReductionDb"]=isnan(v[ST_MAX_REDUCTION]) ? (id)[NSNull null] : @(v[ST_MAX_REDUCTION]);
  os_unfair_lock_lock(&commandProducerLock);
  uint32_t rd=atomic_load_explicit(&commandReadIndex,memory_order_acquire);
  uint32_t wr=atomic_load_explicit(&commandWriteIndex,memory_order_acquire);
  r[@"pendingCommands"]=@((wr+COMMAND_QUEUE_CAPACITY-rd)%COMMAND_QUEUE_CAPACITY);
  os_unfair_lock_unlock(&commandProducerLock);
  r[@"maxVoices"]=@(engineMaxVoices); r[@"sampleRate"]=@(engineSampleRate);
  r[@"underrunCount"]=[NSNull null]; r[@"bufferFrames"]=[NSNull null]; r[@"estimatedOutputLatencyMs"]=[NSNull null];
  uint64_t validation=synth_stats_load(&statsRejected[0]), stopped=synth_stats_load(&statsRejected[1]), full=synth_stats_load(&statsRejected[2]);
  r[@"rejectedRequestsByReason"]=@{@"validation":@(validation),@"engineStopped":@(stopped),@"queueFull":@(full)};
  r[@"rejectedRequestCount"]=@(validation+stopped+full);
  r[@"rejectedPublicationCount"]=@(synth_stats_load(&rejectedPublications));
  r[@"priorityDropCount"]=@(synth_stats_load(&priorityDrops));
  return r;
  }
}
- (NSNumber *)setStatsEnabled:(id)args
{
  @synchronized(self) {
  id enabled=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
  if(![enabled isKindOfClass:[NSNumber class]] || CFGetTypeID((__bridge CFTypeRef)enabled)!=CFBooleanGetTypeID()) {
    __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED); return @NO;
  }
  statsEnabled=[enabled boolValue]; synth_stats_enable(&stats,statsEnabled); return @YES;
  }
}
- (void)resetStats:(id)args
{
  @synchronized(self) {
#pragma unused(args)
  for(int i=0;i<3;i++) synth_stats_store(&statsRejected[i],0);
  synth_stats_store(&priorityDrops,0);synth_stats_store(&rejectedPublications,0);synth_stats_reset(&stats);
  }
}

- (NSDictionary *)getDefaults:(id)args
{
  @synchronized(self) {
#pragma unused(args)
  return [TiSynthengineContract defaultsWithMaxFrequency:[self maxFrequencyHz]];
  }
}

- (NSNumber *)start:(id)args
{
  @synchronized(self) {
  id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
  if(raw==nil) raw=@{};
  if(![raw isKindOfClass:[NSDictionary class]]) { __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED); return @NO; }
  NSDictionary *options=raw;
  if (![self acceptValidation:[TiSynthengineContract validateStart:options]
                       method:@"start"]) return @NO;
  if (audioEngine != nil) return @YES;
  SynthStats previousStats=stats;
  int previousMaxVoices=engineMaxVoices;
  double previousSampleRate=engineSampleRate;

  NSInteger maxVoices = 0;
  [self readOptionalIntegerFrom:options method:@"start" key:@"maxVoices"
                   defaultValue:8 min:1 max:ABSOLUTE_MAX_VOICES out:&maxVoices];
  engineMaxVoices = (int)maxVoices;

  mixingProfile = MIXING_PROFILE_CONSERVATIVE;
  id mixingProfileValue = [options objectForKey:@"mixingProfile"];
  if (mixingProfileValue != nil) {
    if (![mixingProfileValue isKindOfClass:[NSString class]]) {
      [self warnOnceMethod:@"start" key:@"mixingProfile" reason:@"not_string"
                     value:mixingProfileValue action:@"engine_not_started"];
      return @NO;
    }
    NSString *profile = [[(NSString *)mixingProfileValue
        stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        lowercaseString];
    if ([profile isEqualToString:@"conservative"]) {
      mixingProfile = MIXING_PROFILE_CONSERVATIVE;
    } else if ([profile isEqualToString:@"balanced"]) {
      mixingProfile = MIXING_PROFILE_BALANCED;
    } else if ([profile isEqualToString:@"speakersafe"]) {
      mixingProfile = MIXING_PROFILE_SPEAKER_SAFE;
    } else if (![profile isEqualToString:@"raw"]) {
      [self warnOnceMethod:@"start" key:@"mixingProfile"
                     reason:@"unsupported_value" value:mixingProfileValue
                     action:@"engine_not_started"];
      return @NO;
    }
  }

  audioSessionCategory = AVAudioSessionCategoryPlayback;
  id audioSessionValue = [options objectForKey:@"audioSession"];
  if ([audioSessionValue isKindOfClass:[NSString class]]
      && [[(NSString *)audioSessionValue stringByTrimmingCharactersInSet:
           [NSCharacterSet whitespaceAndNewlineCharacterSet]]
          caseInsensitiveCompare:@"ambient"] == NSOrderedSame) {
    audioSessionCategory = AVAudioSessionCategoryAmbient;
  }

  NSError *sessionError = nil;
  AVAudioSession *session = [AVAudioSession sharedInstance];
  [session setCategory:audioSessionCategory error:&sessionError];
  [session setActive:YES error:&sessionError];

  if(sessionError != nil) {
    engineMaxVoices=previousMaxVoices;
    __atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED); return @NO;
  }
  double sessionSampleRate = [session sampleRate];
  engineSampleRate = (isfinite(sessionSampleRate) && sessionSampleRate > 0.0)
                   ? sessionSampleRate : DEFAULT_SAMPLE_RATE;

  stopFadeSamples  = MAX(1, MsToSamples(STOP_ALL_FADE_MS, engineSampleRate));
  stealFadeSamples = MAX(1, MsToSamples(VOICE_STEAL_FADE_MS, engineSampleRate));
  atomic_store_explicit(&masterVolume, 1.0, memory_order_relaxed);
  atomic_store_explicit(&emergencyStopRequested, false, memory_order_relaxed);
  atomic_store_explicit(&emergencyShutdownRequested, false, memory_order_relaxed);
  smoothedGain        = 1.0;
  smoothedMasterGain  = 1.0;
  masterGainTarget    = 1.0;
  masterGainStep      = 0.0;
  masterGainFramesRemaining = 0;
  limiterAttackTarget = 1.0;
  limiterAttackStep   = 0.0;
  gainReleaseCoeff = 1.0 - exp(-1.0 / (0.100 * engineSampleRate));
  lookaheadSize       = MAX(1, (int)round(0.010 * engineSampleRate));
  lookaheadIdx        = 0;
  lookaheadL          = (double *)calloc(lookaheadSize, sizeof(double));
  lookaheadR          = (double *)calloc(lookaheadSize, sizeof(double));
  lookaheadPeaks      = (double *)calloc(lookaheadSize + 1, sizeof(double));
  lookaheadPeakIndices= (int64_t *)calloc(lookaheadSize + 1, sizeof(int64_t));

  [self clearVoices];
  atomic_store_explicit(&commandWriteIndex, 0, memory_order_relaxed);
  atomic_store_explicit(&commandReadIndex,  0, memory_order_relaxed);

  sequence=calloc(1,sizeof(*sequence));
  if(!sequence || !synth_effects_init(&effects,engineSampleRate)) {
    if(sequence){free(sequence);sequence=NULL;}
    if(lookaheadL){free(lookaheadL);lookaheadL=NULL;}if(lookaheadR){free(lookaheadR);lookaheadR=NULL;}
    if(lookaheadPeaks){free(lookaheadPeaks);lookaheadPeaks=NULL;}if(lookaheadPeakIndices){free(lookaheadPeakIndices);lookaheadPeakIndices=NULL;}
    return @NO;
  }
  synth_transport_init(sequence,engineSampleRate,options[@"maxSequences"]?[options[@"maxSequences"] intValue]:1);sequenceOptions=[NSMutableDictionary dictionary];sequenceVoiceId=0;
  processingOptions=synth_effects_default_config();
  synth_stats_init(&stats);
  synth_stats_enable(&stats,statsEnabled);
  audioEngine = [[AVAudioEngine alloc] init];
  AVAudioFormat *format = [[AVAudioFormat alloc]
      initStandardFormatWithSampleRate:engineSampleRate channels:2];

  if (@available(iOS 13.0, *)) {
    __unsafe_unretained TiSynthengineModule *module = self;

    AVAudioSourceNodeRenderBlock renderBlock =
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                  AVAudioFrameCount frameCount, AudioBufferList *outputData)
    {
#pragma unused(isSilence, timestamp)
      BOOL measure = synth_stats_begin(&module->stats);
      uint64_t statsBegin = measure ? mach_absolute_time() : 0;
      // Process all pending commands
      BOOL shutdownAfterCommands=atomic_exchange_explicit(&module->emergencyShutdownRequested,false,memory_order_acq_rel);
      BOOL stopAfterCommands=atomic_exchange_explicit(&module->emergencyStopRequested,false,memory_order_acq_rel);
      uint32_t rd = atomic_load_explicit(&module->commandReadIndex, memory_order_acquire);
      uint32_t wr = atomic_load_explicit(&module->commandWriteIndex, memory_order_acquire);

      while (rd != wr) {
        SynthCommand cmd = module->commandQueue[rd];
        if (cmd.type == CMD_NOTE_ON || cmd.type == SYNTH_CMD_HELD_ON) {
          if(cmd.eventVoiceCount>1 && cmd.sequenceStep==1 && ![module canAdmitCount:cmd.eventVoiceCount priority:cmd.priority]) {
            __atomic_fetch_add(&module->priorityDrops,1,__ATOMIC_RELAXED);rd=(rd+cmd.eventVoiceCount)%COMMAND_QUEUE_CAPACITY;continue;
          }
          if(cmd.eventVoiceCount>1&&cmd.sequenceStep==1){module->batchOrder=module->voiceOrder;module->batchRemaining=cmd.eventVoiceCount;}
          [module startVoiceFromCommand:&cmd];if(module->batchRemaining>0)module->batchRemaining--;
        } else if(cmd.type == SYNTH_CMD_HELD_OFF || cmd.type == SYNTH_CMD_HELD_UPDATE) {
          [module applyHeldCommand:&cmd];
        } else if(cmd.type==7) {
          synth_effects_set_config(&module->effects,&cmd.processing);
          for(int i=0;i<module->engineMaxVoices;i++){SynthVoice *v=&module->voices[i];synth_send_update(&v->send,v->bus,v->effectSend,cmd.processing.applyToMask,MAX(1,MsToSamples(10,module->engineSampleRate)));TailVoice *tail=&module->tails[i];synth_send_update(&tail->send,tail->bus,tail->effectSend,cmd.processing.applyToMask,MAX(1,MsToSamples(10,module->engineSampleRate)));}
        } else if (cmd.type == CMD_STOP_ALL) {
          synth_transport_stop_all(module->sequence);
          synth_effects_panic(&module->effects);
          [module fadeOutAllVoices];
        } else if (cmd.type == CMD_SHUTDOWN) {
          [module clearVoices];
        }
        rd = (rd + 1) % COMMAND_QUEUE_CAPACITY;
      }
      atomic_store_explicit(&module->commandReadIndex, rd, memory_order_release);
      if(stopAfterCommands){synth_transport_stop_all(module->sequence);synth_effects_panic(&module->effects);[module fadeOutAllVoices];}
      if(shutdownAfterCommands)[module clearVoices];
      synth_transport_begin_block(module->sequence);
      for(int slot=0;slot<module->sequence->capacity;slot++) {
        uint32_t stopped=__atomic_load_n(&module->sequence->latestStoppedId[slot],__ATOMIC_ACQUIRE);
        if(stopped)for(int i=0;i<module->engineMaxVoices;i++){SynthVoice *v=&module->voices[i];if(v->isActive&&v->sequenceId==stopped)synth_held_release(&v->held,v->currentEnvelope);}
      }

      if (outputData->mNumberBuffers == 0) return noErr;

      float *outL = (float *)outputData->mBuffers[0].mData;
      float *outR = outputData->mNumberBuffers > 1
                  ? (float *)outputData->mBuffers[1].mData : NULL;
      BOOL isInterleaved = (outR == NULL && outputData->mBuffers[0].mNumberChannels >= 2);

      double mv = atomic_load_explicit(&module->masterVolume, memory_order_relaxed);

      for (AVAudioFrameCount frame = 0; frame < frameCount; frame++) {
        if (mv != module->masterGainTarget) {
          module->masterGainTarget = mv;
          module->masterGainFramesRemaining = module->lookaheadSize;
          module->masterGainStep = (module->masterGainTarget
                                    - module->smoothedMasterGain)
                                 / module->masterGainFramesRemaining;
        }
        if (module->masterGainFramesRemaining > 0) {
          module->smoothedMasterGain += module->masterGainStep;
          module->masterGainFramesRemaining--;
          if (module->masterGainFramesRemaining == 0) {
            module->smoothedMasterGain = module->masterGainTarget;
            module->masterGainStep = 0.0;
          }
        }

        if(module->sequence->activeMask)[module renderSequenceFrame];
        double mixL = 0.0;
        double mixR = 0.0, selectedL=0,selectedR=0;

        if (module->stats.active > 0) for (int i = 0; i < module->engineMaxVoices; i++) {
          SynthVoice *v = &module->voices[i];
          if (!v->isActive) continue;
          double send=synth_send_tick(&v->send);
          if(v->sequenceGeneration && !v->held.releasing && [module sequenceGateEnded:v])synth_held_release(&v->held,v->currentEnvelope);
          if (v->spatial && v->samplesPlayed >= v->totalSamples) {
            float l, r;
            synth_spatial_process(&v->spatialState, 0, &l, &r);
            mixL += l*(1-send); mixR += r*(1-send);selectedL+=l*send;selectedR+=r*send;
            if (--v->spatialDrain <= 0) { v->isActive = false; synth_stats_voice_end(&module->stats,true); }
            continue;
          }

          if(v->held.voiceId) {
            synth_live_tick(&v->live); const double *live=v->live.value;
            v->phaseIncrement=live[LIVE_FREQUENCY]/module->engineSampleRate;
            v->volume=live[LIVE_VOLUME]*v->eventGain;
            v->lfoPhaseIncrement=live[LIVE_LFO_FREQ]/module->engineSampleRate; v->lfoDepth=live[LIVE_LFO_DEPTH];
            v->noisePhaseIncrement=live[LIVE_NOISE_RATE];v->filterAlpha=live[LIVE_LOWPASS_HZ]>=1?0:live[LIVE_LOWPASS_HZ];
            if(v->pan!=live[LIVE_PAN]){v->pan=live[LIVE_PAN];[module updatePanGainsForVoice:v];}
            v->pulseWidth=live[LIVE_PULSE_WIDTH]; v->fmRatio=live[LIVE_FM_RATIO]; v->fmDepth=live[LIVE_FM_DEPTH];
            if(v->svf.type && (v->live.remaining[LIVE_FILTER_HZ]>0 || v->live.remaining[LIVE_FILTER_Q]>0 || v->svfHz!=live[LIVE_FILTER_HZ] || v->svfQ!=live[LIVE_FILTER_Q])) {
              v->svfHz=live[LIVE_FILTER_HZ]; v->svfQ=live[LIVE_FILTER_Q];
              if(!v->modulating)synth_filter_set(&v->svf,v->svfHz,v->svfQ,module->engineSampleRate);
            }
          }

          if(v->sequenceGeneration) {
            double clock=v->sequenceTimeUnit==SYNTH_SEQUENCE_MS?module->sequence->milliseconds:module->sequence->beat;
            double progress=ClampDouble((clock-v->sequenceStartClock)/fmax(v->sequenceLength,1e-10),0,1);
            const double *base=v->live.value;
            if(v->sequenceFrequencyEnd>=1)v->phaseIncrement=(base[LIVE_FREQUENCY]+(v->sequenceFrequencyEnd-base[LIVE_FREQUENCY])*progress)/module->engineSampleRate;
            if(v->sequenceNoiseEnd>=1)v->noisePhaseIncrement=base[LIVE_NOISE_RATE]+(v->sequenceNoiseEnd/module->engineSampleRate-base[LIVE_NOISE_RATE])*progress;
            if(v->sequencePulseEnd>=.05)v->pulseWidth=base[LIVE_PULSE_WIDTH]+(v->sequencePulseEnd-base[LIVE_PULSE_WIDTH])*progress;
            if(v->sequenceFMSweep)v->fmDepth=base[LIVE_FM_DEPTH]+(v->sequenceFMEnd-base[LIVE_FM_DEPTH])*progress;
            double pan=base[LIVE_PAN]+(v->sequencePanEnd-base[LIVE_PAN])*progress;if(pan!=v->pan){v->pan=pan;[module updatePanGainsForVoice:v];}
          }

          // --- LFO vibrato ---
          double effectivePhaseIncr = v->phaseIncrement;
          if (v->lfoDepth > 0.0) {
            double lfoSample = sin(v->lfoPhase * 2.0 * M_PI);
            effectivePhaseIncr += lfoSample * v->lfoDepth / module->engineSampleRate;
            v->lfoPhase += v->lfoPhaseIncrement;
            if (v->lfoPhase >= 1.0) v->lfoPhase -= 1.0;
          }

          BOOL processingModulation=v->modulating;
          SynthModulationOutput mod={0,0,0};
          if(v->modulating){mod=synth_modulation_tick(&v->modulation,module->sequence->bpm);v->modulating=synth_modulation_is_active(&v->modulation);}
          double modPulse=v->modulating?synth_modulation_pwm(v->pulseWidth,mod.pwmOffset):v->pulseWidth;
          double modFM=v->modulating?synth_modulation_fm(v->fmDepth,mod.fmOffset):v->fmDepth;
          // --- Waveform generation ---
          effectivePhaseIncr = ClampDouble(effectivePhaseIncr, -0.45, 0.45);
          double wf = 0.0;
          if (v->waveType == 4) {
            v->noisePhase += ClampDouble(v->noisePhaseIncrement, 1.0e-9, 1.0);
            if (v->noisePhase >= 1.0) {
              v->noisePhase -= floor(v->noisePhase);
              v->heldNoise = LcgNoise(&v->noiseState);
            }
            wf = v->heldNoise;
          } else if (v->waveType == 5) {
            wf = RenderWavetable(v->phase, v->wavetable, v->wavetableSize);
          } else if (v->fmActive) {
            wf = synth_fm_sine(v->phase - floor(v->phase), v->fmModPhase, modFM);
          } else {
            wf = RenderPeriodicWave(v->waveType, v->phase, effectivePhaseIncr,
                                    modPulse);
          }
          wf = QuantizeWave(wf, v->bitDepth);
          if (v->filterAlpha > 0.0) {
            v->filterState += v->filterAlpha * (wf - v->filterState);
            wf = v->filterState;
          }
          if (v->svf.type != SYNTH_FILTER_NONE) {
            if(v->sequenceGeneration&&v->svfSweeping) {
              if((v->modulationFrames++&7)==0) {
                double clock=v->sequenceTimeUnit==SYNTH_SEQUENCE_MS?module->sequence->milliseconds:module->sequence->beat;
                double progress=ClampDouble((clock-v->sequenceStartClock)/fmax(v->sequenceLength,1e-10),0,1);
                double cutoff=progress>=1?v->svfHzEnd:synth_geometric_at(v->live.value[LIVE_FILTER_HZ],v->svfHzEnd,progress);
                if(processingModulation)cutoff=synth_modulation_cutoff(cutoff,mod.cutoffOctaves,module->engineSampleRate);
                synth_filter_set(&v->svf,cutoff,v->svfQ,module->engineSampleRate);
              }
            } else {
            if(processingModulation && ((v->modulationFrames++&15)==0||!v->modulating))synth_filter_set(&v->svf,synth_modulation_cutoff(v->svfHz,mod.cutoffOctaves,module->engineSampleRate),v->svfQ,module->engineSampleRate);
            if (!v->modulating && synth_filter_update_due(v->svfSweeping, v->sequenceGeneration?(int)v->modulationFrames++:v->samplesPlayed)) {
              double cutoffHz = v->svfSweeping
                  ? synth_geometric_at(v->svfHz, v->svfHzEnd,
                                       (v->sequenceGeneration?ClampDouble(((v->sequenceTimeUnit==SYNTH_SEQUENCE_MS?module->sequence->milliseconds:module->sequence->beat)-v->sequenceStartClock)/fmax(v->sequenceLength,1e-10),0,1):synth_sweep_progress(v->samplesPlayed, v->totalSamples)))
                  : v->svfHz;
              synth_filter_set(&v->svf, cutoffHz, v->svfQ, module->engineSampleRate);
            }
            }
            wf = synth_filter_process(&v->svf, wf);
          }

          // --- Envelope (smoothstep attack, decay to sustain, release) ---
          double envelope = v->held.voiceId ? synth_held_envelope(&v->held,v->samplesPlayed,v->attackSamples,v->decaySamples,v->sustain,v->releaseSamples) : synth_envelope(v->samplesPlayed, v->totalSamples,
                                           v->attackSamples, v->decaySamples,
                                           v->sustain, v->releaseSamples);
          v->currentEnvelope = envelope;

          // --- Voice mix (optional bus protection is applied below) ---
          double sample = wf * envelope * v->volume;
          if (v->spatial) {
            float spatialL, spatialR;
            synth_spatial_process(&v->spatialState, (float)sample, &spatialL, &spatialR);
            mixL += spatialL*(1-send); mixR += spatialR*(1-send);selectedL+=spatialL*send;selectedR+=spatialR*send;
          } else {
            mixL += sample * v->leftGain*(1-send);
            mixR += sample * v->rightGain*(1-send);selectedL+=sample*v->leftGain*send;selectedR+=sample*v->rightGain*send;
          }

          // --- Advance phase ---
          v->phase += effectivePhaseIncr;
          v->phase -= floor(v->phase);
          if (v->fmActive) {
            v->fmModPhase += effectivePhaseIncr * v->fmRatio;
            v->fmModPhase -= floor(v->fmModPhase);
            if(!v->sequenceGeneration)v->fmDepth = ClampDouble(v->fmDepth + v->fmDepthDelta, 0.0, 10.0);
          }

          // --- Pitch sweep ---
          if (!v->sequenceGeneration && v->phaseIncrDelta != 0.0) {
            v->phaseIncrement += v->phaseIncrDelta;
          }
          if(!v->sequenceGeneration){v->noisePhaseIncrement += v->noisePhaseIncrDelta;
          v->pulseWidth = ClampDouble(v->pulseWidth + v->pulseWidthDelta, 0.05, 0.95);}

          // --- Pan sweep ---
          if (!v->sequenceGeneration && v->panDelta != 0.0) {
            v->pan = ClampDouble(v->pan + v->panDelta, -1.0, 1.0);
            [module updatePanGainsForVoice:v];
          }

          // --- Advance sample counter ---
          BOOL finished;
          if(v->held.voiceId) {
            if(v->samplesPlayed < v->attackSamples+v->decaySamples)v->samplesPlayed++;
            finished=v->held.releasing && ++v->held.releasePlayed>=MAX(1,v->releaseSamples);
            if(finished){v->samplesPlayed=v->totalSamples;synth_identity_set(&module->identities[i],0,0);}
          } else finished=++v->samplesPlayed>=v->totalSamples;
          if (finished) {
            if (v->spatial) v->currentEnvelope = 0;
            else { v->isActive = false; synth_stats_voice_end(&module->stats,false); }
          }
        }

        if (module->stats.tails > 0) for (int i = 0; i < module->engineMaxVoices; i++) {
          TailVoice *tail = &module->tails[i];
          if (!tail->isActive) continue;
          double send=synth_send_tick(&tail->send);
          if (tail->spatial && tail->samplesRemaining <= 0) {
            float l, r;
            synth_spatial_process(&tail->spatialState, 0, &l, &r);
            mixL += l*(1-send); mixR += r*(1-send);selectedL+=l*send;selectedR+=r*send;
            if (--tail->spatialDrain <= 0) { tail->isActive = false; synth_stats_tail_end(&module->stats); }
            continue;
          }
          double wf = 0.0;
          if (tail->waveType == 4) {
            tail->noisePhase += tail->noisePhaseIncrement;
            if (tail->noisePhase >= 1.0) {
              tail->noisePhase -= floor(tail->noisePhase);
              tail->heldNoise = LcgNoise(&tail->noiseState);
            }
            wf = tail->heldNoise;
          } else if (tail->waveType == 5) {
            wf = RenderWavetable(tail->phase, tail->wavetable, tail->wavetableSize);
          } else if (tail->fmActive) {
            wf = synth_fm_sine(tail->phase - floor(tail->phase), tail->fmModPhase, tail->fmDepth);
          } else {
            wf = RenderPeriodicWave(tail->waveType, tail->phase,
                                    tail->phaseIncrement, tail->pulseWidth);
          }
          wf = QuantizeWave(wf, tail->bitDepth);
          if (tail->filterAlpha > 0.0) {
            tail->filterState += tail->filterAlpha * (wf - tail->filterState);
            wf = tail->filterState;
          }
          wf = synth_filter_process(&tail->svf, wf);
          int denominator = MAX(1, tail->totalSamples - 1);
          double x = ClampDouble((double)(tail->samplesRemaining - 1)
                                 / (double)denominator, 0.0, 1.0);
          double tailEnvelope = SmoothStep01(x);
          double sample = wf * tail->volume * tailEnvelope;
          if (tail->spatial) {
            float spatialL, spatialR;
            synth_spatial_process(&tail->spatialState, (float)sample, &spatialL, &spatialR);
            mixL += spatialL*(1-send); mixR += spatialR*(1-send);selectedL+=spatialL*send;selectedR+=spatialR*send;
          } else {
            mixL += sample * tail->leftGain*(1-send);
            mixR += sample * tail->rightGain*(1-send);selectedL+=sample*tail->leftGain*send;selectedR+=sample*tail->rightGain*send;
          }
          tail->phase += tail->phaseIncrement;
          tail->phase -= floor(tail->phase);
          if (tail->fmActive) {
            tail->fmModPhase += tail->phaseIncrement * tail->fmRatio;
            tail->fmModPhase -= floor(tail->fmModPhase);
          }
          tail->samplesRemaining--;
          if (tail->samplesRemaining <= 0 && !tail->spatial) { tail->isActive = false; synth_stats_tail_end(&module->stats); }
        }

        // --- Stereo-linked lookahead peak limiter ---
        int laIdx = module->lookaheadIdx;
        double delayedL = module->lookaheadL[laIdx];
        double delayedR = module->lookaheadR[laIdx];
        double scaledL,scaledR;
        synth_effects_process_routed(&module->effects,module->sequence->bpm,mixL,mixR,selectedL,selectedR,module->smoothedMasterGain,&scaledL,&scaledR);
        synth_transport_advance_sample(module->sequence);
        module->lookaheadL[laIdx] = scaledL;
        module->lookaheadR[laIdx] = scaledR;
        module->lookaheadIdx = (laIdx + 1) % module->lookaheadSize;

        // Maintain the maximum of the complete future window in amortized O(1).
        int peakCapacity = module->lookaheadSize + 1;
        int64_t oldestIndex = module->limiterSampleIndex - module->lookaheadSize;
        while (module->lookaheadPeakCount > 0
               && module->lookaheadPeakIndices[module->lookaheadPeakHead]
                    < oldestIndex) {
          module->lookaheadPeakHead = (module->lookaheadPeakHead + 1) % peakCapacity;
          module->lookaheadPeakCount--;
        }

        if(measure) synth_stats_pre_limiter(&module->stats,scaledL,scaledR);
        double currentPeak = fmax(fabs(scaledL), fabs(scaledR));
        while (module->lookaheadPeakCount > 0) {
          int last = (module->lookaheadPeakHead
                      + module->lookaheadPeakCount - 1) % peakCapacity;
          if (module->lookaheadPeaks[last] > currentPeak) break;
          module->lookaheadPeakCount--;
        }
        int insert = (module->lookaheadPeakHead
                      + module->lookaheadPeakCount) % peakCapacity;
        module->lookaheadPeaks[insert] = currentPeak;
        module->lookaheadPeakIndices[insert] = module->limiterSampleIndex;
        module->lookaheadPeakCount++;
        module->limiterSampleIndex++;

        // A shared window gain preserves waveform shape instead of flattening
        // individual peaks with a sample-by-sample safety gain.
        double windowPeak = module->lookaheadPeaks[module->lookaheadPeakHead];

        double outputCeiling = module->mixingProfile == MIXING_PROFILE_SPEAKER_SAFE
                             ? SPEAKER_SAFE_OUTPUT_CEILING : OUTPUT_CEILING;
        double targetGain = windowPeak > outputCeiling
                          ? outputCeiling / windowPeak : 1.0;

        // A new maximum enters at the far end of the lookahead buffer. Ramp
        // toward its required gain over that deadline instead of introducing
        // an instantaneous gain discontinuity. Do not slow an attack already
        // in flight because an earlier peak can have a nearer deadline.
        if (targetGain < module->smoothedGain) {
          module->limiterAttackTarget = fmin(
              module->limiterAttackTarget, targetGain);
          double requiredStep = (module->limiterAttackTarget
                                 - module->smoothedGain)
                              / module->lookaheadSize;
          module->limiterAttackStep = fmin(
              module->limiterAttackStep, requiredStep);
        }

        if (module->limiterAttackStep < 0.0
            && module->smoothedGain > module->limiterAttackTarget) {
          module->smoothedGain = fmax(
              module->limiterAttackTarget,
              module->smoothedGain + module->limiterAttackStep);
        } else {
          module->limiterAttackTarget = 1.0;
          module->limiterAttackStep = 0.0;
          module->smoothedGain = fmin(
              targetGain,
              module->smoothedGain
                  + (1.0 - module->smoothedGain) * module->gainReleaseCoeff);
        }

        // A fully drained lookahead window has no remaining waveform to protect.
        // Reset only dynamic bus gain so the next unrelated sound starts at its
        // intended level without truncating a release tail or creating a click.
        BOOL drainedWindow = currentPeak <= 1.0e-12
            && windowPeak <= 1.0e-12
            && fabs(delayedL) <= 1.0e-12
            && fabs(delayedR) <= 1.0e-12;
        if (drainedWindow) {
          module->smoothedGain = 1.0;
          module->limiterAttackTarget = 1.0;
          module->limiterAttackStep = 0.0;
          module->lookaheadPeakHead = 0;
          module->lookaheadPeakCount = 0;
        }
        double finalL = delayedL * module->smoothedGain;
        double finalR = delayedR * module->smoothedGain;

        float fL = (float)ClampDouble(finalL, -1.0, 1.0);
        float fR = (float)ClampDouble(finalR, -1.0, 1.0);
        if(measure) synth_stats_sample(&module->stats,fL,fR,module->smoothedGain,(int)module->engineSampleRate);

        if (outR != NULL) {
          outL[frame] = fL;
          outR[frame] = fR;
        } else if (isInterleaved) {
          outL[frame * 2]     = fL;
          outL[frame * 2 + 1] = fR;
        } else {
          outL[frame] = fL;
        }
      }

      for(int slot=0;slot<module->sequence->capacity;slot++)if(__atomic_load_n(&module->sequence->status[slot],__ATOMIC_ACQUIRE)==2)synth_sequence_publish_state(&module->sequence->slots[slot]);
      double seconds = measure ? (mach_absolute_time()-statsBegin) * (double)module->statsTimebase.numer / module->statsTimebase.denom * 1e-9 : 0;
      synth_stats_end(&module->stats,(int)frameCount,(int)module->engineSampleRate,seconds);
      return noErr;
    };

    sourceNode = [[AVAudioSourceNode alloc] initWithRenderBlock:renderBlock];
    [audioEngine attachNode:sourceNode];
    [audioEngine connect:sourceNode to:audioEngine.mainMixerNode format:format];
  } else {
    DebugLog(@"[ERROR] AVAudioSourceNode requires iOS 13.0+");
    audioEngine = nil;
    sourceNode  = nil;
    return @NO;
  }

  NSError *engineError = nil;
  BOOL started=[audioEngine startAndReturnError:&engineError];
  if (!started || engineError != nil) {
    DebugLog(@"[ERROR] Unable to start audio engine: %@", engineError.localizedDescription);
    [self shutdown:nil];
    stats=previousStats; engineMaxVoices=previousMaxVoices; engineSampleRate=previousSampleRate;
    __atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED);
    return @NO;
  }
  for(int i=0;i<3;i++) synth_stats_store(&statsRejected[i],0);
  return @YES;
  }
}

- (NSNumber *)setVolume:(id)args
{
  @synchronized(self) {
  if (audioEngine == nil) { __atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED); return @NO; }

  id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
  if(![raw isKindOfClass:[NSDictionary class]]) { __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED); return @NO; }
  NSDictionary *options=raw;
  if (![self acceptValidation:[TiSynthengineContract validateSetVolume:options]
                       method:@"setVolume"]) return @NO;
  double volume = 1.0;
  [self readOptionalDoubleFrom:options method:@"setVolume" key:@"volume"
                  defaultValue:1.0 min:VOLUME_MIN max:VOLUME_MAX out:&volume];
  atomic_store_explicit(&masterVolume, volume, memory_order_relaxed);
  return @YES;
  }
}

- (void)pruneVoiceMetadata
{
  if(voiceGenerations.count==0)return;
  NSMutableSet *retained=[NSMutableSet set];
  os_unfair_lock_lock(&commandProducerLock);
  uint32_t rd=atomic_load_explicit(&commandReadIndex,memory_order_acquire),wr=atomic_load_explicit(&commandWriteIndex,memory_order_acquire);
  while(rd!=wr){SynthCommand *c=&commandQueue[rd];if(c->type==SYNTH_CMD_HELD_ON&&c->voiceId>0)[retained addObject:@(c->voiceId)];rd=(rd+1)%COMMAND_QUEUE_CAPACITY;}
  for(int i=0;i<engineMaxVoices;i++){int32_t identifier=(int32_t)__atomic_load_n(&identities[i].voiceId,__ATOMIC_SEQ_CST);if(identifier>0&&synth_identity_mask(&identities[i],identifier)>=0)[retained addObject:@(identifier)];}
  os_unfair_lock_unlock(&commandProducerLock);
  for(NSNumber *identifier in [voiceGenerations allKeys])if(![retained containsObject:identifier]){[voiceGenerations removeObjectForKey:identifier];[voicePositions removeObjectForKey:identifier];[voiceSpatialModes removeObjectForKey:identifier];}
}

- (void)cancelSequencePoll
{
  ++sequenceEventGeneration;
  if(sequenceEventTimer){dispatch_source_cancel(sequenceEventTimer);sequenceEventTimer=nil;}
}

- (void)scheduleSequencePoll
{
  // Held voices also need metadata retirement. Stop waking the main queue
  // once both the sequence-event and held-metadata work have drained.
  if(sequenceEventTimer||!sequence||(!sequenceOptions.count&&!voiceGenerations.count))return;
  uint64_t generation=++sequenceEventGeneration;
  sequenceEventTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
  dispatch_source_set_timer(sequenceEventTimer,dispatch_time(DISPATCH_TIME_NOW,10*NSEC_PER_MSEC),10*NSEC_PER_MSEC,NSEC_PER_MSEC);
  __weak __typeof__(self) eventOwner=self;
  dispatch_source_set_event_handler(sequenceEventTimer,^{
    __typeof__(self) owner=eventOwner;
    @synchronized(owner) {
      if(owner&&owner->sequenceEventGeneration==generation)[owner drainSequenceEvents];
    }
  });
  dispatch_resume(sequenceEventTimer);
}

- (void)drainSequenceEvents
{
 @synchronized(self) {if(!sequence)return;
  uint64_t generation=sequenceEventGeneration;
  [self pruneVoiceMetadata];
  SynthSequenceEnd end;while(sequence&&generation==sequenceEventGeneration&&synth_transport_pop_end(sequence,&end)) {
  [sequenceOptions removeObjectForKey:@(end.sequenceId)];
  [self fireEvent:@"sequenceend" withObject:@{@"sequenceId":@(end.sequenceId),@"reason":end.reason==SYNTH_SEQUENCE_COMPLETED?@"completed":@"stopped"}];
  }
  if(generation==sequenceEventGeneration&&!sequenceOptions.count&&!voiceGenerations.count)[self cancelSequencePoll];
 }
}
- (NSNumber *)setTempo:(id)args
{
 @synchronized(self) {id raw=[args isKindOfClass:[NSArray class]]&&[args count]==1?args[0]:args;
  if(!sequence||!audioEngine||![raw isKindOfClass:[NSDictionary class]]||[raw count]!=1)return @NO;
  double bpm;id value=raw[@"bpm"];if(![value isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||!ParseFiniteDoubleFromAny(value,&bpm)||bpm<20||bpm>300)return @NO;
  return @(synth_transport_set_tempo(sequence,bpm));}
}
- (NSNumber *)playSequence:(id)args {return [self publishSequence:args restart:YES];}
- (NSNumber *)updateSequence:(id)args {return [self publishSequence:args restart:NO];}
- (NSNumber *)publishSequence:(id)args restart:(BOOL)restart
{
 @synchronized(self) {
  if(!audioEngine||!sequence)return restart?@0:@NO;
  id raw=[args isKindOfClass:[NSArray class]]&&[args count]==1?args[0]:args;
  if(![raw isKindOfClass:[NSDictionary class]])return restart?@0:@NO;
  uint32_t identifier=0;
  if(restart){if(nextSequenceId>=INT32_MAX)return @0;identifier=nextSequenceId+1;}
  else {id value=raw[@"sequenceId"];double numeric;
   if(![value isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()||!ParseFiniteDoubleFromAny(value,&numeric)||numeric<1||numeric>INT32_MAX||numeric!=floor(numeric))return @NO;
   identifier=(uint32_t)numeric;if(!sequenceOptions[@(identifier)])return @NO;
  }
  NSMutableDictionary *changes=[raw mutableCopy];if(!restart)[changes removeObjectForKey:@"sequenceId"];
  NSDictionary *previous=sequenceOptions[@(identifier)];
  if(!restart&&changes[@"timeUnit"]&&![changes[@"timeUnit"] isEqual:previous[@"timeUnit"]?:@"beats"])return @NO;
  NSMutableDictionary *merged=restart?[NSMutableDictionary dictionary]:[previous mutableCopy];[merged addEntriesFromDictionary:changes];
  if(!restart&&[changes[@"voice"] isKindOfClass:[NSDictionary class]])merged[@"voice"]=[TiSynthengineContract mergeSequenceVoice:previous[@"voice"]?:@{} changes:changes[@"voice"]];
  SynthSequenceConfig *bank=synth_transport_begin_write_full(sequence,identifier,restart);
  if(!bank){__atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);__atomic_fetch_add(&rejectedPublications,1,__ATOMIC_RELAXED);return restart?@0:@NO;}
  NSDictionary *failure=[TiSynthengineContract prepareSequence:merged config:bank maxFrequency:[self maxFrequencyHz]];
  if(failure){synth_transport_cancel_write(sequence,bank);[self acceptValidation:failure method:restart?@"playSequence":@"updateSequence"];return restart?@0:@NO;}
  if(!synth_transport_commit_prepared(sequence,bank,restart)){__atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);__atomic_fetch_add(&rejectedPublications,1,__ATOMIC_RELAXED);return restart?@0:@NO;}
  sequenceOptions[@(identifier)]=merged;if(restart)nextSequenceId=identifier;
  [self scheduleSequencePoll];
  return restart?@(identifier):@YES;
 }
}
- (NSNumber *)stopSequence:(id)args
{
 @synchronized(self) {id raw=[args isKindOfClass:[NSArray class]]&&[args count]==1?args[0]:args;
  if(!sequence||!audioEngine||![raw isKindOfClass:[NSDictionary class]]||[raw count]!=1)return @NO;
  double value;id identifier=raw[@"sequenceId"];if(![identifier isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)identifier)==CFBooleanGetTypeID()||!ParseFiniteDoubleFromAny(identifier,&value)||value<1||value>INT32_MAX||value!=floor(value))return @NO;
  return @(synth_transport_request_stop(sequence,(uint32_t)value));}
}
- (NSDictionary *)getSequenceState:(id)args
{
 @synchronized(self) {id raw=[args isKindOfClass:[NSArray class]]&&[args count]==1?args[0]:args;
  if(!sequence||![raw isKindOfClass:[NSDictionary class]]||[raw count]!=1)return nil;
  double value;id identifier=raw[@"sequenceId"];if(![identifier isKindOfClass:[NSNumber class]]||CFGetTypeID((__bridge CFTypeRef)identifier)==CFBooleanGetTypeID()||!ParseFiniteDoubleFromAny(identifier,&value)||value<1||value>INT32_MAX||value!=floor(value))return nil;
  SynthSequenceState state;if(!synth_transport_state(sequence,(uint32_t)value,&state))return nil;
  NSMutableDictionary *result=[[TiSynthengineContract sequenceStateObject:&state] mutableCopy];result[@"sequenceId"]=@((uint32_t)value);return result;}
}
- (NSNumber *)setMasterProcessing:(id)args
{
 @synchronized(self) {
  if(!audioEngine)return @NO;
  id raw=[args isKindOfClass:[NSArray class]]&&[args count]==1?args[0]:args;
  SynthEffectsConfig next=processingOptions;
  NSDictionary *failure=[TiSynthengineContract prepareMasterProcessing:raw config:&next];
  if(failure){[self acceptValidation:failure method:@"setMasterProcessing"];return @NO;}
  SynthCommand cmd;memset(&cmd,0,sizeof(cmd));cmd.type=7;cmd.processing=next;
  if([self enqueueCommand:cmd]){__atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);return @NO;}
  processingOptions=next;return @YES;
 }
}
- (BOOL)sequenceGateEnded:(SynthVoice *)voice
{
 return (voice->sequenceTimeUnit==SYNTH_SEQUENCE_MS?sequence->milliseconds:sequence->beat)+1e-10>=voice->sequenceOffBeat;
}
- (void)renderSequenceFrame
{
 for(int slot=0;slot<sequence->capacity;slot++) {
  if(!(sequence->activeMask&(1u<<slot)))continue;
  SynthSequenceEvent event;SynthSequenceTransport *t=&sequence->slots[slot];
  BOOL emitted=synth_transport_tick(sequence,slot,&event);
  if(!emitted||!event.noteCount)continue;
  for(int i=0;i<engineMaxVoices;i++){SynthVoice *v=&voices[i];if(v->isActive&&v->sequenceGeneration&&!v->held.releasing&&[self sequenceGateEnded:v])synth_held_release(&v->held,v->currentEnvelope);}
  const SynthSequenceConfig *config=&t->banks[event.bank];const SynthSequenceVoice *settings=&config->steps[event.stepIndex].voice;
  if(![self canAdmitCount:event.noteCount priority:settings->priority]){__atomic_fetch_add(&priorityDrops,1,__ATOMIC_RELAXED);continue;}
  batchOrder=voiceOrder;batchRemaining=event.noteCount;
  for(int n=0;n<event.noteCount;n++) {
   SynthCommand cmd=StudioSequenceCommand(settings,engineSampleRate);
   if(sequenceVoiceId==INT32_MIN)sequenceVoiceId=0;cmd.voiceId=--sequenceVoiceId;
   cmd.frequency=event.frequencies[n]>0?event.frequencies[n]:synth_sequence_frequency(config,event.notes[n]);cmd.eventVoiceCount=event.noteCount;
   cmd.sequenceId=event.sequenceId;cmd.sequenceTimeUnit=config->timeUnit;cmd.sequenceSlot=slot;cmd.sequenceGeneration=event.generation;cmd.sequenceOffBeat=(config->timeUnit==SYNTH_SEQUENCE_MS?sequence->milliseconds:sequence->beat)+event.length;cmd.sequenceStep=event.stepIndex;cmd.sequenceMidi=event.notes[n];
   [self startVoiceFromCommand:&cmd];batchRemaining--;
  }
 }
}

- (NSNumber *)playTone:(id)args { return [self publishTone:args voiceId:0]; }

- (NSNumber *)noteOn:(id)args
{
  @synchronized(self) {
    if(audioEngine==nil){__atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED);return @NO;}
    id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
    if(![raw isKindOfClass:[NSDictionary class]]){__atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED);return @NO;}
    if(![self acceptValidation:[TiSynthengineContract validateNoteOn:raw maxFrequency:[self maxFrequencyHz]] method:@"noteOn"])return @NO;
    return [self publishTone:raw voiceId:[raw[@"voiceId"] intValue]];
  }
}

- (NSNumber *)noteOff:(id)args
{
  @synchronized(self) {
    if(audioEngine==nil){__atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED);return @NO;}
    id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
    if(![raw isKindOfClass:[NSDictionary class]]){__atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED);return @NO;}
    if(![self acceptValidation:[TiSynthengineContract validateNoteOff:raw] method:@"noteOff"])return @NO;
    SynthCommand cmd; memset(&cmd,0,sizeof(cmd));cmd.type=SYNTH_CMD_HELD_OFF;cmd.voiceId=[raw[@"voiceId"] intValue];cmd.voiceGeneration=[voiceGenerations[@(cmd.voiceId)] unsignedLongLongValue];
    BOOL full=[self enqueueCommand:cmd];if(full)__atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);
    return full ? @NO : @YES;
  }
}

- (NSNumber *)updateVoice:(id)args
{
  @synchronized(self) {
    if(audioEngine==nil){__atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED);return @NO;}
    id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
    if(![raw isKindOfClass:[NSDictionary class]]){__atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED);return @NO;}
    if(![self acceptValidation:[TiSynthengineContract validateUpdateVoice:raw maxFrequency:[self maxFrequencyHz]] method:@"updateVoice"])return @NO;
    NSNumber *spatialMode=voiceSpatialModes[raw[@"voiceId"]];
    if(spatialMode&&(([spatialMode boolValue]&&raw[@"pan"])||(![spatialMode boolValue]&&(raw[@"spatialX"]||raw[@"spatialY"]))))return @NO;
    NSArray *keys=@[@"frequency",@"volume",@"filterHz",@"filterQ",@"lfoFreq",@"lfoDepth",@"pulseWidth",@"fmRatio",@"fmDepth",@"noiseRate",@"lowPassHz",@"pan"];
    SynthCommand cmd;memset(&cmd,0,sizeof(cmd));cmd.type=SYNTH_CMD_HELD_UPDATE;cmd.voiceId=[raw[@"voiceId"] intValue];cmd.voiceGeneration=[voiceGenerations[@(cmd.voiceId)] unsignedLongLongValue];
    for(int i=0;i<SYNTH_LIVE_COUNT;i++)if(raw[keys[i]]){cmd.liveMask|=1u<<i;cmd.liveValues[i]=[raw[keys[i]] doubleValue];}
    if(raw[@"noiseRate"])cmd.liveValues[LIVE_NOISE_RATE]=[raw[@"noiseRate"] doubleValue]>0?[raw[@"noiseRate"] doubleValue]/engineSampleRate:1;
    if(raw[@"lowPassHz"])cmd.liveValues[LIVE_LOWPASS_HZ]=[raw[@"lowPassHz"] doubleValue]>0?1-exp(-2*M_PI*[raw[@"lowPassHz"] doubleValue]/engineSampleRate):1;
    if(raw[@"effectSend"]){cmd.hasSendUpdate=YES;cmd.effectSend=[raw[@"effectSend"] doubleValue];}
    if(raw[@"spatialX"]||raw[@"spatialY"]){NSArray *previous=voicePositions[@(cmd.voiceId)]?:@[@0,@0];double x=raw[@"spatialX"]?[raw[@"spatialX"] doubleValue]:[previous[0] doubleValue],y=raw[@"spatialY"]?[raw[@"spatialY"] doubleValue]:[previous[1] doubleValue];cmd.hasSpatialUpdate=YES;synth_spatial_prepare(&cmd.preparedSpatial,x,y,engineSampleRate);cmd.spatialX=x;cmd.spatialY=y;}
    if(raw[@"note"]){cmd.liveMask|=1u<<LIVE_FREQUENCY;cmd.liveValues[LIVE_FREQUENCY]=ParseNoteToFrequency(raw[@"note"]);}
    if(raw[@"modulations"]) {
      double mods[12];[TiSynthengineContract prepareModulations:raw[@"modulations"] values:mods waveType:-1 filterType:-1];
      cmd.modulation=StudioModulationFromValues(mods);cmd.hasModulations=YES;
    }
    int allowed=[self voiceMaskForId:cmd.voiceId];
    if(allowed>=0 && cmd.hasModulations && !synth_modulation_validate(&cmd.modulation,StudioModCapabilitiesFromMask(allowed)))return @NO;
    if(allowed>=0 && (cmd.liveMask & ~(uint32_t)allowed)){[self acceptValidation:@{@"key":@"changes",@"reason":@"incompatible_voice_source",@"value":raw} method:@"updateVoice"];return @NO;}
    BOOL full=[self enqueueCommand:cmd];if(full)__atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);
    else if(cmd.hasSpatialUpdate && cmd.voiceGeneration!=0)voicePositions[@(cmd.voiceId)]=@[@(cmd.spatialX),@(cmd.spatialY)];
    return full ? @NO : @YES;
  }
}

- (NSNumber *)publishTone:(id)args voiceId:(int32_t)voiceId
{
  @synchronized(self) {
  if (audioEngine == nil || engineMaxVoices < 1) { __atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED); return @NO; }

  id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
  if(raw==nil) raw=@{};
  if(![raw isKindOfClass:[NSDictionary class]]) { __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED); return @NO; }
  NSDictionary *options=raw;
  double maxFreq = [self maxFrequencyHz];
  if (voiceId==0 && ![self acceptValidation:[TiSynthengineContract validateTone:options maxFrequency:maxFreq]
                       method:@"playTone"]) return @NO;

  double frequency = 0.0;

  SynthCommand cmd;
  memset(&cmd, 0, sizeof(cmd));
  cmd.type = voiceId ? SYNTH_CMD_HELD_ON : CMD_NOTE_ON;
  cmd.voiceId=voiceId;
  cmd.bus=(int)[@[@"music",@"effects",@"ui",@"ambience"] indexOfObject:options[@"bus"]?:@"effects"];cmd.effectSend=options[@"effectSend"]?[options[@"effectSend"] doubleValue]:-1;cmd.priority=[options[@"priority"] intValue];
  if(options[@"modulations"]) {
    double mods[12];[TiSynthengineContract prepareModulations:options[@"modulations"] values:mods waveType:-1 filterType:-1];
    cmd.modulation=StudioModulationFromValues(mods);cmd.hasModulations=YES;
  }

  if ([self containsRawKey:options key:@"note"]) {
    id noteObj = [options objectForKey:@"note"];
    frequency = ParseNoteToFrequency([noteObj isKindOfClass:[NSString class]]
                                     ? (NSString *)noteObj : [noteObj description]);
    if (frequency < MIN_FREQUENCY_HZ) {
      [self warnOnceMethod:@"playTone" key:@"note" reason:@"invalid_note"
                     value:noteObj action:@"ignored"];
      return @NO;
    }
    frequency = ClampDouble(frequency, MIN_FREQUENCY_HZ, maxFreq);
  } else {
    [self readOptionalDoubleFrom:options method:@"playTone" key:@"frequency"
                   defaultValue:DEFAULT_FREQUENCY_HZ
                            min:MIN_FREQUENCY_HZ max:maxFreq out:&frequency];
  }
  cmd.frequency = frequency;

  NSInteger durationMs = 0;
  [self readOptionalIntegerFrom:options method:@"playTone" key:@"duration"
                   defaultValue:(voiceId ? DURATION_MAX_MS : DURATION_DEFAULT_MS)
                            min:DURATION_MIN_MS max:DURATION_MAX_MS out:&durationMs];

  NSInteger attackMs = 0, releaseMs = 0;
  double volume = 0.0, pan = 0.0, panEnd = 0.0, lfoFreq = 0.0, lfoDepth = 0.0;
  double noiseRate = 0.0, noiseRateEnd = 0.0, lowPassHz = 0.0;
  double pulseWidth = 0.5, pulseWidthEnd = 0.0;
  NSInteger waveType = 0, bitDepth = 0;

  [self readOptionalIntegerFrom:options method:@"playTone" key:@"attack"
                   defaultValue:ATTACK_DEFAULT_MS min:ATTACK_MIN_MS max:ATTACK_MAX_MS out:&attackMs];
  [self readOptionalIntegerFrom:options method:@"playTone" key:@"release"
                   defaultValue:RELEASE_DEFAULT_MS min:RELEASE_MIN_MS max:RELEASE_MAX_MS out:&releaseMs];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"volume"
                  defaultValue:VOLUME_DEFAULT min:VOLUME_MIN max:VOLUME_MAX out:&volume];
  [self readOptionalIntegerFrom:options method:@"playTone" key:@"waveType"
                   defaultValue:0 min:0 max:5 out:&waveType];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"pan"
                  defaultValue:0.0 min:-1.0 max:1.0 out:&pan];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"panEnd"
                  defaultValue:pan min:-1.0 max:1.0 out:&panEnd];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"lfoFreq"
                  defaultValue:0.0 min:0.0 max:20000.0 out:&lfoFreq];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"lfoDepth"
                  defaultValue:0.0 min:0.0 max:20000.0 out:&lfoDepth];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"noiseRate"
                  defaultValue:0.0 min:0.0 max:maxFreq out:&noiseRate];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"noiseRateEnd"
                  defaultValue:0.0 min:0.0 max:maxFreq out:&noiseRateEnd];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"lowPassHz"
                  defaultValue:0.0 min:0.0 max:maxFreq out:&lowPassHz];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"pulseWidth"
                  defaultValue:0.5 min:0.05 max:0.95 out:&pulseWidth];
  [self readOptionalDoubleFrom:options method:@"playTone" key:@"pulseWidthEnd"
                  defaultValue:0.0 min:0.0 max:0.95 out:&pulseWidthEnd];
  [self readOptionalIntegerFrom:options method:@"playTone" key:@"bitDepth"
                   defaultValue:0 min:0 max:16 out:&bitDepth];

  double frequencyEnd = 0.0;
  if ([self containsRawKey:options key:@"frequencyEnd"]) {
    double fe = 0.0;
    if (ParseFiniteDoubleFromAny([options objectForKey:@"frequencyEnd"], &fe)
        && fe >= MIN_FREQUENCY_HZ) {
      frequencyEnd = ClampDouble(fe, MIN_FREQUENCY_HZ, maxFreq);
    }
  }

  if (attackMs >= durationMs) {
    [self warnOnceMethod:@"playTone" key:@"attack" reason:@"attack_greater_or_equal_duration"
                   value:@(attackMs) action:@"trimmed"];
    attackMs = MAX(0, durationMs - 1);
  }
  NSInteger maxRelease = MAX(0, durationMs - attackMs);
  if (releaseMs > maxRelease) {
    [self warnOnceMethod:@"playTone" key:@"release" reason:@"release_exceeds_remaining_duration"
                   value:@(releaseMs) action:@"trimmed"];
    releaseMs = maxRelease;
  }

  cmd.durationSamples = MAX(1, MsToSamples((int)durationMs, engineSampleRate));
  cmd.attackSamples   = MAX(voiceId ? 0 : 1, MsToSamples((int)attackMs,   engineSampleRate));
  cmd.releaseSamples  = MAX(voiceId ? 0 : 1, MsToSamples((int)releaseMs,  engineSampleRate));
  cmd.volume          = volume;
  cmd.waveType        = (int)waveType;
  cmd.pan             = pan;
  cmd.panEnd          = panEnd;
  cmd.frequencyEnd    = frequencyEnd;
  cmd.lfoFreq         = lfoFreq;
  cmd.lfoDepth        = lfoDepth;
  cmd.noiseRate       = noiseRate;
  cmd.noiseRateEnd    = noiseRateEnd;
  cmd.lowPassHz       = lowPassHz;
  cmd.pulseWidth      = pulseWidth;
  cmd.pulseWidthEnd   = pulseWidthEnd;
  cmd.bitDepth        = (int)bitDepth;
  CopyWaveTableFromOptions(options, NULL, 0, cmd.wavetable, &cmd.wavetableSize);

  ExpressiveParams expressive = ReadExpressiveParams(options, ExpressiveDefaults());
  ApplyExpressiveParams(&cmd, &expressive, engineSampleRate);
  cmd.frequency = DetunedFrequency(cmd.frequency, expressive.detune, maxFreq);
  if (cmd.frequencyEnd > 0.0) {
    cmd.frequencyEnd = DetunedFrequency(cmd.frequencyEnd, expressive.detune, maxFreq);
  }

  int maxAttackSamples = MAX(0, cmd.durationSamples - 1);
  if (cmd.attackSamples > maxAttackSamples) cmd.attackSamples = maxAttackSamples;
  int maxReleaseSamples = MAX(0, cmd.durationSamples - cmd.attackSamples);
  if (cmd.releaseSamples > maxReleaseSamples) cmd.releaseSamples = maxReleaseSamples;

  if(voiceId){if(![self heldPriorityAllows:voiceId priority:cmd.priority]){__atomic_fetch_add(&priorityDrops,1,__ATOMIC_RELAXED);return @YES;}cmd.voiceGeneration=++nextVoiceGeneration;}
  BOOL dropped = [self enqueueCommand:cmd];
  if(!dropped&&voiceId){voiceGenerations[@(voiceId)]=@(cmd.voiceGeneration);voiceSpatialModes[@(voiceId)]=@(cmd.spatial);voicePositions[@(voiceId)]=@[@(cmd.spatialX),@(cmd.spatialY)];if(voiceGenerations.count>256)[self pruneVoiceMetadata];[self scheduleSequencePoll];}
  if (dropped) {
    [self warnOnceMethod:@"playTone" key:@"queue" reason:@"overflow"
                   value:@"command_queue_full" action:@"drop_newest"];
  }
  if(dropped) __atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);
  return voiceId ? (dropped ? @NO : @YES) : @(!dropped);
  }
}

- (NSNumber *)playChord:(id)args
{
  @synchronized(self) {
  if (audioEngine == nil || engineMaxVoices < 1) { __atomic_fetch_add(&statsRejected[1],1,__ATOMIC_RELAXED); return @NO; }

  id raw=[args isKindOfClass:[NSArray class]] && [args count]==1 ? args[0] : args;
  if(![raw isKindOfClass:[NSDictionary class]]) { __atomic_fetch_add(&statsRejected[0],1,__ATOMIC_RELAXED); return @NO; }
  NSDictionary *options=raw;
  double maxFreq = [self maxFrequencyHz];
  if (![self acceptValidation:[TiSynthengineContract validateChord:options maxFrequency:maxFreq]
                       method:@"playChord"]) return @NO;

  NSArray *freqArr = [self parseFreqArray:options method:@"playChord" maxFreq:maxFreq];
  if (!freqArr || freqArr.count == 0) return @NO;

  NSInteger durationMs = 0;
  [self readOptionalIntegerFrom:options method:@"playChord" key:@"duration"
                   defaultValue:DURATION_DEFAULT_MS
                            min:DURATION_MIN_MS max:DURATION_MAX_MS out:&durationMs];

  NSInteger attackMs = 0, releaseMs = 0, waveType = 0, bitDepth = 0;
  double volume = 0.0, panSpread = 0.0, noiseRate = 0.0;
  double lowPassHz = 0.0, pulseWidth = 0.5;
  [self readOptionalIntegerFrom:options method:@"playChord" key:@"attack"
                   defaultValue:ATTACK_DEFAULT_MS min:ATTACK_MIN_MS max:ATTACK_MAX_MS out:&attackMs];
  [self readOptionalIntegerFrom:options method:@"playChord" key:@"release"
                   defaultValue:RELEASE_DEFAULT_MS min:RELEASE_MIN_MS max:RELEASE_MAX_MS out:&releaseMs];
  [self readOptionalDoubleFrom:options method:@"playChord" key:@"volume"
                  defaultValue:VOLUME_DEFAULT min:VOLUME_MIN max:VOLUME_MAX out:&volume];
  [self readOptionalIntegerFrom:options method:@"playChord" key:@"waveType"
                   defaultValue:0 min:0 max:5 out:&waveType];
  [self readOptionalDoubleFrom:options method:@"playChord" key:@"panSpread"
                  defaultValue:0.0 min:0.0 max:1.0 out:&panSpread];
  [self readOptionalDoubleFrom:options method:@"playChord" key:@"noiseRate"
                  defaultValue:0.0 min:0.0 max:maxFreq out:&noiseRate];
  [self readOptionalDoubleFrom:options method:@"playChord" key:@"lowPassHz"
                  defaultValue:0.0 min:0.0 max:maxFreq out:&lowPassHz];
  [self readOptionalDoubleFrom:options method:@"playChord" key:@"pulseWidth"
                  defaultValue:0.5 min:0.05 max:0.95 out:&pulseWidth];
  [self readOptionalIntegerFrom:options method:@"playChord" key:@"bitDepth"
                   defaultValue:0 min:0 max:16 out:&bitDepth];
  double chordWavetable[WAVETABLE_MAX_SAMPLES] = {0};
  int chordWavetableSize = 0;
  CopyWaveTableFromOptions(options, NULL, 0, chordWavetable, &chordWavetableSize);
  ExpressiveParams expressive = ReadExpressiveParams(options, ExpressiveDefaults());

  if (attackMs >= durationMs) attackMs = MAX(0, durationMs - 1);
  NSInteger maxRelease = MAX(0, durationMs - attackMs);
  if (releaseMs > maxRelease) releaseMs = maxRelease;

  int durSamples     = MAX(1, MsToSamples((int)durationMs, engineSampleRate));
  int attackSamples  = MAX(1, MsToSamples((int)attackMs,   engineSampleRate));
  int releaseSamples = MAX(1, MsToSamples((int)releaseMs,  engineSampleRate));
  if (attackSamples  > MAX(0, durSamples - 1))             attackSamples  = MAX(0, durSamples - 1);
  if (releaseSamples > MAX(0, durSamples - attackSamples)) releaseSamples = MAX(0, durSamples - attackSamples);

  // Per-voice pans override
  NSArray *pansOverride = nil;
  if ([self containsRawKey:options key:@"pans"]) {
    id raw = [options objectForKey:@"pans"];
    if ([raw isKindOfClass:[NSArray class]]) pansOverride = (NSArray *)raw;
  }

  // Per-voice detune in cents
  NSArray *detunes = nil;
  if ([self containsRawKey:options key:@"detunes"]) {
    id raw = [options objectForKey:@"detunes"];
    if ([raw isKindOfClass:[NSArray class]]) detunes = (NSArray *)raw;
  }

  NSInteger count = (NSInteger)freqArr.count;
  SynthCommand chordCommands[ABSOLUTE_MAX_VOICES];
  for (NSInteger i = 0; i < count; i++) {
    double freq = [freqArr[i] doubleValue];
    if (detunes && i < (NSInteger)detunes.count) {
      double cents = 0.0;
      if (ParseFiniteDoubleFromAny(detunes[i], &cents)) freq = DetunedFrequency(freq, cents, maxFreq);
    }
    double pan  = 0.0;
    if (pansOverride && i < (NSInteger)pansOverride.count) {
      double pv = 0.0;
      if (ParseFiniteDoubleFromAny(pansOverride[i], &pv)) pan = ClampDouble(pv, -1.0, 1.0);
    } else if (panSpread > 0.0 && count > 1) {
      pan = panSpread * (2.0 * i / (count - 1) - 1.0);
    }

    SynthCommand cmd;
    memset(&cmd, 0, sizeof(cmd));
    cmd.type           = CMD_NOTE_ON;
    cmd.bus=(int)[@[@"music",@"effects",@"ui",@"ambience"] indexOfObject:options[@"bus"]?:@"effects"];cmd.effectSend=options[@"effectSend"]?[options[@"effectSend"] doubleValue]:-1;cmd.priority=[options[@"priority"] intValue];
    cmd.frequency      = freq;
    cmd.durationSamples= durSamples;
    cmd.attackSamples  = attackSamples;
    cmd.releaseSamples = releaseSamples;
    cmd.volume         = volume;
    cmd.eventVoiceCount = (int)count;
    cmd.waveType       = (int)waveType;
    cmd.pan            = pan;
    cmd.panEnd         = pan;
    cmd.noiseRate      = noiseRate;
    cmd.lowPassHz      = lowPassHz;
    cmd.pulseWidth     = pulseWidth;
    cmd.bitDepth       = (int)bitDepth;
    cmd.wavetableSize  = chordWavetableSize;
    if (chordWavetableSize > 0) {
      memcpy(cmd.wavetable, chordWavetable,
             chordWavetableSize * sizeof(double));
    }
    ApplyExpressiveParams(&cmd, &expressive, engineSampleRate);

    cmd.sequenceStep=(i==0)?1:0;chordCommands[i] = cmd;
  }

  // Publish the chord with one release-store so the audio callback observes
  // every note together or none of them.
  os_unfair_lock_lock(&commandProducerLock);
  uint32_t write = atomic_load_explicit(&commandWriteIndex, memory_order_relaxed);
  uint32_t read = atomic_load_explicit(&commandReadIndex, memory_order_acquire);
  uint32_t used = (write + COMMAND_QUEUE_CAPACITY - read) % COMMAND_QUEUE_CAPACITY;
  uint32_t available = COMMAND_QUEUE_CAPACITY - 1 - used;
  BOOL dropped = (uint32_t)count > available;
  if (!dropped) {
    for (NSInteger i = 0; i < count; i++) {
      commandQueue[write] = chordCommands[i];
      write = (write + 1) % COMMAND_QUEUE_CAPACITY;
    }
    atomic_store_explicit(&commandWriteIndex, write, memory_order_release);
  }
  os_unfair_lock_unlock(&commandProducerLock);

  if (dropped) {
    [self warnOnceMethod:@"playChord" key:@"queue" reason:@"overflow"
                   value:@"command_queue_full" action:@"drop_newest"];
  }
  if(dropped) __atomic_fetch_add(&statsRejected[2],1,__ATOMIC_RELAXED);
  return @(!dropped);
  }
}

- (void)stopAll:(id)args
{
  @synchronized(self) {
#pragma unused(args)
  if (audioEngine == nil) return;
  BOOL dropped = [self enqueueSimpleCommand:CMD_STOP_ALL];
  if (dropped) {
    [self warnOnceMethod:@"stopAll" key:@"queue" reason:@"overflow"
                   value:@"command_queue_full" action:@"fallback_control_flag"];
  }
  }
}

- (void)shutdown:(id)args
{
  @synchronized(self) {
#pragma unused(args)
  if (audioEngine == nil) return;

  // Cancel any pending pattern dispatches; a closing owner gets no patternend

  BOOL dropped = [self enqueueSimpleCommand:CMD_SHUTDOWN];
  if (dropped) {
    [self warnOnceMethod:@"shutdown" key:@"queue" reason:@"overflow"
                   value:@"command_queue_full" action:@"fallback_control_flag"];
  }

  [audioEngine stop];
  [self cancelSequencePoll];
  synth_effects_destroy(&effects);if(sequence){free(sequence);sequence=NULL;}sequenceOptions=nil;
  synth_stats_stopped(&stats);
  sourceNode  = nil;
  audioEngine = nil;
  [voiceGenerations removeAllObjects];[voicePositions removeAllObjects];[voiceSpatialModes removeAllObjects];

  if (lookaheadL) { free(lookaheadL); lookaheadL = NULL; }
  if (lookaheadR) { free(lookaheadR); lookaheadR = NULL; }
  if (lookaheadPeaks) { free(lookaheadPeaks); lookaheadPeaks = NULL; }
  if (lookaheadPeakIndices) {
    free(lookaheadPeakIndices);
    lookaheadPeakIndices = NULL;
  }
  atomic_store_explicit(&commandWriteIndex, 0, memory_order_relaxed);
  atomic_store_explicit(&commandReadIndex,  0, memory_order_relaxed);
  }
}

// ---------------------------------------------------------------------------
#pragma mark - Private helpers
// ---------------------------------------------------------------------------

// Parse "frequencies" or "notes" array from options dict → NSArray of NSNumber
- (NSArray *)parseFreqArray:(NSDictionary *)options method:(NSString *)method maxFreq:(double)maxFreq
{
  NSArray *raw = nil;
  if ([self containsRawKey:options key:@"frequencies"]) {
    id val = [options objectForKey:@"frequencies"];
    if ([val isKindOfClass:[NSArray class]]) raw = (NSArray *)val;
  } else if ([self containsRawKey:options key:@"notes"]) {
    id val = [options objectForKey:@"notes"];
    if ([val isKindOfClass:[NSArray class]]) raw = (NSArray *)val;
  }

  if (!raw) return nil;

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:raw.count];
  for (id item in raw) {
    double f = 0.0;
    if (ParseFiniteDoubleFromAny(item, &f)) {
      [result addObject:@(ClampDouble(f, MIN_FREQUENCY_HZ, maxFreq))];
    } else {
      NSString *noteStr = [item isKindOfClass:[NSString class]]
                        ? (NSString *)item : [item description];
      double parsed = ParseNoteToFrequency(noteStr);
      double final  = parsed >= MIN_FREQUENCY_HZ
                    ? ClampDouble(parsed, MIN_FREQUENCY_HZ, maxFreq) : MIN_FREQUENCY_HZ;
      [result addObject:@(final)];
    }
  }
  return result;
}

@end
