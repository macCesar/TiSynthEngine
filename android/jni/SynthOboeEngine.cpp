#include <jni.h>
#include <oboe/Oboe.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cmath>
#include <cstdint>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#include "../../shared/synth_core.h"
#include "../../shared/synth_held.h"
#include "../../shared/synth_retrigger.h"
#include "../../shared/synth_spatial.h"
#include "../../shared/synth_stats.h"
#include "../../shared/synth_transport.h"
#include "../../shared/synth_effects.h"
#include "../../shared/synth_modulation.h"

namespace {
constexpr int kMaxVoices = 32;
constexpr int kMaxWavetableSamples = 64;
constexpr int kQueueCapacity = 128;
// Mirrors SynthThread.EXTRA_*: decay ms, sustain, filter type, cutoff, cutoff
// end, Q, FM ratio, FM depth, FM depth end (NaN = no sweep), spatial enabled, x, y.
constexpr int kExtraCount = 28;
constexpr double kPi = 3.14159265358979323846;

template <typename T> T clampValue(T value, T low, T high) {
  return std::max(low, std::min(high, value));
}

double smoothStep(double x) {
  const double t = clampValue(x, 0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

double polyBlep(double t, double dt) {
  if (t < dt) {
    const double x = t / dt;
    return x + x - x * x - 1.0;
  }
  if (t > 1.0 - dt) {
    const double x = (t - 1.0) / dt;
    return x * x + x + x + 1.0;
  }
  return 0.0;
}

double periodicWave(int type, double phase, double increment, double pulseWidth) {
  const double t = phase - std::floor(phase);
  const double dt = clampValue(std::abs(increment), 1.0e-9, 0.5);
  if (type == 1) {
    const double width = clampValue(pulseWidth, 0.05, 0.95);
    double value = t < width ? 1.0 : -1.0;
    value += polyBlep(t, dt);
    double shifted = t - width;
    if (shifted < 0.0)
      shifted += 1.0;
    return value - polyBlep(shifted, dt);
  }
  if (type == 2)
    return 2.0 * t - 1.0 - polyBlep(t, dt);
  if (type == 3)
    return 1.0 - 4.0 * std::abs(t - 0.5);
  return std::sin(t * 2.0 * kPi);
}

double quantizeWave(double value, int bitDepth) {
  if (bitDepth < 2)
    return value;
  const int safeDepth = clampValue(bitDepth, 2, 16);
  const double levels = static_cast<double>((1u << safeDepth) - 1u);
  const double normalized = clampValue((value + 1.0) * 0.5, 0.0, 1.0);
  return std::round(normalized * levels) / levels * 2.0 - 1.0;
}

double wavetableWave(double phase, const std::array<double, kMaxWavetableSamples> &table,
                     int tableSize) {
  if (tableSize < 2)
    return std::sin((phase - std::floor(phase)) * 2.0 * kPi);
  const double t = phase - std::floor(phase);
  const int index = std::min(tableSize - 1, static_cast<int>(t * tableSize));
  return table[index];
}

double eventGain(int profile, int waveType, int voiceCount) {
  if (profile == 0)
    return 1.0;
  constexpr double sineGain = 0.44;
  double gain = waveType == 1   ? sineGain / std::sqrt(2.0)
                : waveType == 0 ? sineGain
                                : sineGain * std::sqrt(1.5);
  if (profile == 2)
    gain *= std::sqrt(2.0);
  else if (profile == 3)
    gain /= std::sqrt(2.0);
  return gain / std::sqrt(static_cast<double>(std::max(1, voiceCount)));
}

struct Command {
  int bus=SYNTH_BUS_EFFECTS, priority=0, groupCount=0;
  double effectSend=NAN;
  bool hasSpatialUpdate=false;
  SynthSpatialPrepared spatialPrepared{};
  uint64_t generation=0;
  SynthModulationConfig modulations=synth_modulation_default_config();
  bool hasModulations=false;
  SynthEffectsConfig effects=synth_effects_default_config();
  int32_t voiceId = 0;
  uint32_t liveMask = 0;
  double liveValues[SYNTH_LIVE_COUNT]{};
  bool spatial = false;
  double spatialX = 0.0, spatialY = 0.0;
  int type = 0;
  double frequency = 440.0;
  int duration = 1, attack = 0, release = 0;
  double volume = 1.0;
  int eventVoiceCount = 1, waveType = 0;
  double pan = 0.0, panEnd = 0.0, frequencyEnd = 0.0;
  double lfoFreq = 0.0, lfoDepth = 0.0;
  double noiseRate = 0.0, noiseRateEnd = 0.0, lowPassHz = 0.0;
  double pulseWidth = 0.5, pulseWidthEnd = 0.0;
  int bitDepth = 0, wavetableSize = 0;
  std::array<double, kMaxWavetableSamples> wavetable{};
  int decay = 0;
  double sustain = 1.0;
  int filterType = SYNTH_FILTER_NONE;
  double filterHz = 1000.0, filterHzEnd = 0.0, filterQ = 0.7071;
  double fmRatio = 1.0, fmDepth = 0.0, fmDepthEnd = 0.0;
  bool fmDepthSweep = false;
};

struct Voice {
  int bus=SYNTH_BUS_EFFECTS,priority=0,sequenceSlot=-1,sequenceUnit=0;
  uint32_t sequenceId=0;
  uint64_t generation=0;
  double effectSend=-1,spatialX=0,spatialY=0;
  SynthSend send{};
  uint64_t sendFrame=0;
  bool sequenceTimed=false,sequenceSweeps=false;
  SynthModulation modulation{};
  bool modulating=false;
  uint32_t modulationFrames=0;
  bool sequenceOwned=false;
  int sequenceStep=0,sequenceMidi=0;
  double sequenceOffBeat=0,sequenceStarted=0,sequenceLength=0,sequenceStartFrequency=0,sequenceEndFrequency=0;
  uint64_t sequenceGeneration=0;
  SynthHeld held{};
  SynthLive live{};
  bool liveRamping=false;
  double eventGain = 1;
  bool spatial = false;
  int spatialDrain = 0;
  bool active = false,controlSweeps=false;
  double phase = 0.0, increment = 0.0, incrementDelta = 0.0;
  int duration = 1, played = 0, attack = 0, release = 0;
  double volume = 0.0, envelope = 0.0;
  int waveType = 0;
  double pan = 0.0, panDelta = 0.0, left = 0.70710678, right = 0.70710678;
  double lfoPhase = 0.0, lfoIncrement = 0.0, lfoDepth = 0.0;
  double noisePhase = 0.0, noiseIncrement = 1.0, noiseIncrementDelta = 0.0;
  double heldNoise = 0.0, filterState = 0.0, filterAlpha = 0.0;
  double pulseWidth = 0.5, pulseWidthDelta = 0.0;
  int bitDepth = 0, wavetableSize = 0;
  std::array<double, kMaxWavetableSamples> wavetable{};
  uint64_t noise = 1;
  int decay = 0;
  double sustain = 1.0;
  SynthFilter filter{};
  double filterHz = 0.0, filterHzEnd = 0.0, filterQ = 0.7071;
  bool fmActive = false;
  double fmRatio = 1.0, fmDepth = 0.0, fmDepthDelta = 0.0, modPhase = 0.0;
  SynthSpatial spatialState{};
  SynthSequenceVoice sequenceShape{};
  uint32_t sequenceFilterFrames=0;
};

struct Tail {
  int bus=SYNTH_BUS_EFFECTS; double effectSend=-1; SynthSend send{}; uint64_t sendFrame=0;
  bool spatial = false;
  int spatialDrain = 0;
  bool active = false;
  double phase = 0.0, increment = 0.0, volume = 0.0;
  int waveType = 0;
  double left = 0.0, right = 0.0;
  uint64_t noise = 1;
  double noisePhase = 0.0, noiseIncrement = 1.0, heldNoise = 0.0;
  double filterState = 0.0, filterAlpha = 0.0, pulseWidth = 0.5;
  int bitDepth = 0, wavetableSize = 0;
  std::array<double, kMaxWavetableSamples> wavetable{};
  int total = 1, remaining = 0;
  SynthFilter filter{};
  bool fmActive = false;
  double fmRatio = 1.0, fmDepth = 0.0, modPhase = 0.0;
  SynthSpatial spatialState{};
};

class Engine final : public oboe::AudioStreamDataCallback,
                     public oboe::AudioStreamErrorCallback,
                     public std::enable_shared_from_this<Engine> {
public:
  Engine(int maxVoices, int profile,int maxSequences=1)
      : maxVoices_(clampValue(maxVoices, 1, kMaxVoices)),
        profile_(clampValue(profile, 0, 3)), voices_(maxVoices_),
        tails_(maxVoices_) { synth_stats_init(&stats_); synth_transport_init(&transport_,48000,maxSequences); }

  ~Engine() {synth_effects_destroy(&effects_);}

  uint64_t priorityDropCount() const {return priorityDrops_.load(std::memory_order_relaxed);}
  int maxVoices() const { return maxVoices_; }
  void readStats(double *out) {
    synth_stats_read(&stats_, out);
  }
  int pendingCommands() {
    std::lock_guard<std::mutex> guard(producerMutex_);
    auto read = read_.load(std::memory_order_acquire);
    return (write_.load(std::memory_order_acquire) + kQueueCapacity - read) % kQueueCapacity;
  }
  void collectXruns() {
    if(!stream_) return;
    auto count=stream_->getXRunCount();
    if(count) {
      xrunAvailable_=true;
      int64_t current=count.value();
      xrunTotal_ += current >= xrunLast_ ? current-xrunLast_ : current;
      xrunLast_=current;
    } else {
      xrunAvailable_=false; xrunCoverageLost_=true;
    }
  }
  void backendStats(double &buffer, double &xruns, double &latency) {
    std::lock_guard<std::mutex> guard(streamMutex_);
    collectXruns();
    latency=NAN;
    if(stream_) {
      auto estimate=stream_->calculateLatencyMillis();
      if(estimate && std::isfinite(estimate.value()) && estimate.value()>=0)
        latency=estimate.value()+lookahead_*1000.0/renderSampleRate_;
    }
    const int bufferFrames=stream_ ? stream_->getBufferSizeInFrames() : 0;
    buffer=bufferFrames>0 ? (double)bufferFrames : NAN;
    xruns = xrunAvailable_ && !xrunCoverageLost_ ? (double)xrunTotal_ : NAN;
  }
  void enableStats(bool enabled) { synth_stats_enable(&stats_, enabled); }
  void resetStats() {
    std::lock_guard<std::mutex> guard(streamMutex_);
    priorityDrops_.store(0,std::memory_order_relaxed);
    collectXruns(); xrunTotal_=0; xrunCoverageLost_=false;
    synth_stats_reset(&stats_);
  }
  bool open() {
    std::lock_guard<std::mutex> guard(streamMutex_);
    return openLocked();
  }

  bool start() {
    std::lock_guard<std::mutex> guard(streamMutex_);
    if (closing_.load(std::memory_order_acquire))
      return false;
    runningRequested_.store(true, std::memory_order_release);
    if (startLocked())
      return true;
    closeStreamLocked();
    return reopenAndStartLocked();
  }

  int sampleRate() const {
    return reportedSampleRate_.load(std::memory_order_relaxed);
  }
  void setVolume(double value) { master_.store(clampValue(value, 0.0, 2.0)); }

  bool enqueue(Command command) {
    std::lock_guard<std::mutex> guard(producerMutex_);
    // Snapshot pending publications before active identities: an ON may move
    // from queue to callback ownership while the producer examines metadata.
    if(command.type==SYNTH_CMD_HELD_ON) {
      int priority=-1,pendingPriority=-1;
      uint32_t cursor=read_.load(std::memory_order_acquire),end=write_.load(std::memory_order_acquire);
      while(cursor!=end){const auto &pending=queue_[cursor];if(pending.type==SYNTH_CMD_HELD_ON&&pending.voiceId==command.voiceId)pendingPriority=pending.priority;cursor=(cursor+1)%kQueueCapacity;}
      for(int i=0;i<maxVoices_;i++)if(synth_identity_mask(&identities_[i],command.voiceId)>=0)priority=identityPriorities_[i].load(std::memory_order_acquire);
      if(pendingPriority>=0)priority=pendingPriority;
      if(priority>command.priority){priorityDrops_.fetch_add(1,std::memory_order_relaxed);return false;}
      command.generation=++controlGeneration_;
    }
    if(command.type==SYNTH_CMD_HELD_OFF||command.type==SYNTH_CMD_HELD_UPDATE) {
      double x=0,y=0,pendingX=0,pendingY=0;
      uint64_t generation=0,pendingGeneration=0,spatialGeneration=0;
      double spatialX=0,spatialY=0;
      uint32_t cursor=read_.load(std::memory_order_acquire),end=write_.load(std::memory_order_acquire);
      while(cursor!=end){const auto &pending=queue_[cursor];
        if(pending.voiceId==command.voiceId) {
          if(pending.type==SYNTH_CMD_HELD_ON){pendingGeneration=pending.generation;pendingX=pending.spatialX;pendingY=pending.spatialY;}
          else if(pending.type==SYNTH_CMD_HELD_UPDATE&&pending.hasSpatialUpdate){spatialGeneration=pending.generation;spatialX=pending.spatialX;spatialY=pending.spatialY;}
        }cursor=(cursor+1)%kQueueCapacity;
      }
      for(int i=0;i<maxVoices_;i++)if(synth_identity_mask(&identities_[i],command.voiceId)>=0) {
        generation=identityGenerations_[i].load(std::memory_order_acquire);
        x=identityX_[i].load(std::memory_order_relaxed);y=identityY_[i].load(std::memory_order_relaxed);
      }
      if(pendingGeneration){generation=pendingGeneration;x=pendingX;y=pendingY;}
      if(generation&&spatialGeneration==generation){x=spatialX;y=spatialY;}
      command.generation=generation;
      if(command.hasSpatialUpdate){if(std::isnan(command.spatialX))command.spatialX=x;if(std::isnan(command.spatialY))command.spatialY=y;
        synth_spatial_prepare(&command.spatialPrepared,command.spatialX,command.spatialY,sampleRate());}
    }
    const uint32_t write = write_.load(std::memory_order_relaxed);
    const uint32_t next = (write + 1) % kQueueCapacity;
    if (next == read_.load(std::memory_order_acquire))
      return true;
    queue_[write] = command;
    write_.store(next, std::memory_order_release);
    return false;
  }

  int voiceMaskForId(int32_t id) {
    std::lock_guard<std::mutex> guard(producerMutex_);
    int result=-1,pending=-1;
    uint32_t read=read_.load(std::memory_order_acquire), write=write_.load(std::memory_order_acquire);
    while(read!=write) {
      const Command &c=queue_[read];
      if(c.type==SYNTH_CMD_HELD_ON && c.voiceId==id){pending=(int)synth_live_allowed(c.waveType,c.filterType);if(c.spatial)pending=(pending&~(1<<LIVE_PAN))|(1<<16);}
      read=(read+1)%kQueueCapacity;
    }
    for(const auto &identity:identities_) {int found=synth_identity_mask(&identity,id);if(found>=0)result=found;}
    if(pending>=0)result=pending;
    return result;
  }

  bool enqueueChord(std::vector<Command> commands) {
    std::lock_guard<std::mutex> guard(producerMutex_);
    uint32_t write = write_.load(std::memory_order_relaxed);
    const uint32_t read = read_.load(std::memory_order_acquire);
    const uint32_t used = (write + kQueueCapacity - read) % kQueueCapacity;
    if (commands.size() > kQueueCapacity - 1 - used)
      return true;
    if(!commands.empty())commands[0].groupCount=(int)commands.size();
    for (const Command &command : commands) {
      queue_[write] = command;
      write = (write + 1) % kQueueCapacity;
    }
    write_.store(write, std::memory_order_release);
    return false;
  }

  bool publishSequence(uint32_t id,const double *packet,int size,bool restart) {
    if(size<9)return false;
    int count=(int)packet[0];if(count<1||count>512||size!=9+count*184)return false;
    std::lock_guard<std::mutex> guard(producerMutex_);
    auto *c=synth_transport_begin_write_full(&transport_,id,restart);if(!c)return false;
    // The bridge supplies a complete score. Initialize only its live steps and
    // header; the unused tail of a bank cannot affect preparation or playback.
    memset(c->steps,0,(size_t)count*sizeof(c->steps[0]));
    memset((char *)c+offsetof(SynthSequenceConfig,stepCount),0,sizeof(*c)-offsetof(SynthSequenceConfig,stepCount));
    c->stepCount=count;c->bpm=packet[1];c->swing=packet[2];c->loop=(int)packet[3];
    c->mode=(int)packet[4];c->tuning=packet[5];c->detune=packet[6];c->timeUnit=(int)packet[7];c->stepDuration=packet[8];
    for(int i=0;i<count;i++) {
      const double *p=packet+9+i*184;auto &step=c->steps[i];auto &v=step.voice;
      step.noteCount=(int)p[0];step.rest=(int)p[1];step.gate=p[2];
      for(int n=0;n<32;n++)step.notes[n]=(uint8_t)p[3+n];
      v.volume=p[35];v.pan=p[36];v.frequencyEnd=p[37];v.lfoFreq=p[38];v.lfoDepth=p[39];
      v.noiseRate=p[40];v.lowPassHz=p[41];v.pulseWidth=p[42];v.filterHz=p[43];v.filterQ=p[44];
      v.fmRatio=p[45];v.fmDepth=p[46];v.spatialX=p[47];v.spatialY=p[48];v.sustain=p[49];
      v.waveType=(int)p[50];v.attack=(int)p[51];v.decay=(int)p[52];v.release=(int)p[53];
      v.filterType=(int)p[54];v.bitDepth=(int)p[55];v.spatial=(int)p[56];v.wavetableSize=(int)p[57];
      for(int j=0;j<64;j++)v.wavetable[j]=p[58+j];
      for(int j=0;j<12;j++)v.mods[j]=p[122+j];
      step.duration=p[134];step.length=p[135];
      for(int n=0;n<32;n++)step.frequencies[n]=p[136+n];
      v.bus=(int)p[168];v.effectSend=p[169];v.priority=(int)p[170];
      v.noiseRateEnd=p[171];v.panEnd=p[172];v.pulseWidthEnd=p[173];v.filterHzEnd=p[174];v.fmDepthEnd=p[175];v.fmDepthSweep=(int)p[176];
    }
    return synth_transport_commit(&transport_,c,restart)!=0;
  }
  bool stopSequence(uint32_t id) {return synth_transport_request_stop(&transport_,id)!=0;}
  bool sequenceState(uint32_t id,SynthSequenceState *out) {return synth_transport_state(&transport_,id,out)!=0;}
  bool setTempo(double bpm) {return synth_transport_set_tempo(&transport_,bpm)!=0;}
  bool popSequenceEnd(SynthSequenceEnd *out) {return synth_transport_pop_end(&transport_,out)!=0;}

  bool stopAll() {
    Command command;
    command.type = 2;
    bool full=enqueue(command);
    if(full)emergencyStopRequested_.store(true,std::memory_order_release);
    return full;
  }

  void close() {
    runningRequested_.store(false, std::memory_order_release);
    closing_.store(true, std::memory_order_release);
    std::lock_guard<std::mutex> guard(streamMutex_);
    closeStreamLocked();
    clearRenderState();
    read_.store(write_.load(std::memory_order_acquire),std::memory_order_release);
  }

  oboe::DataCallbackResult onAudioReady(oboe::AudioStream *, void *audioData,
                                        int32_t frames) override {
    const bool measure = synth_stats_begin(&stats_);
    const auto begin = measure ? std::chrono::steady_clock::now() : std::chrono::steady_clock::time_point{};
    processCommands();
    synth_transport_begin_block(&transport_);
    updateSequenceOwnership();
    const bool processEffects=effectsActive_;
    auto *output = static_cast<float *>(audioData);
    bool spatialBlocks=false;
#if defined(__aarch64__)
    spatialBlocks=stats_.spatial>0;
    if(!spatialBlocks&&stats_.tails>0)for(const Tail &tail:tails_)if(tail.active&&tail.spatial){spatialBlocks=true;break;}
#endif
    if(!spatialBlocks) {
    for (int32_t frame = 0; frame < frames; ++frame) {
      if(transport_.activeMask)for(int slot=0;slot<transport_.capacity;slot++)if(transport_.activeMask&(1u<<slot))processSequence(slot);
      double left=0,right=0,selectedL=0,selectedR=0;
      if(!processEffects) {
        if(stats_.active>0)for(Voice &voice:voices_)renderVoice(voice,left,right);
        if(stats_.tails>0)for(Tail &tail:tails_)renderTail(tail,left,right);
      }else {
        if(stats_.active>0)for(Voice &voice:voices_)if(voice.active) {
          double l=0,r=0;renderVoice(voice,l,r);double send=synth_send_tick(&voice.send);
          if(send==1){selectedL+=l;selectedR+=r;}else if(send==0){left+=l;right+=r;}
          else{left+=l*(1-send);right+=r*(1-send);selectedL+=l*send;selectedR+=r*send;}
        }
        if(stats_.tails>0)for(Tail &tail:tails_)if(tail.active) {
          double l=0,r=0;renderTail(tail,l,r);double send=synth_send_tick(&tail.send);
          if(send==1){selectedL+=l;selectedR+=r;}else if(send==0){left+=l;right+=r;}
          else{left+=l*(1-send);right+=r*(1-send);selectedL+=l*send;selectedR+=r*send;}
        }
      }
      if(processEffects) {
        smoothedMaster_+=(master_.load(std::memory_order_relaxed)-smoothedMaster_)/lookahead_;
        synth_effects_process_routed(&effects_,transport_.bpm,left,right,selectedL,selectedR,smoothedMaster_,&left,&right);
      } else {left+=selectedL;right+=selectedR;}
      limit(left, right, measure,processEffects);
      synth_transport_advance_sample(&transport_);
      output[frame * 2] = static_cast<float>(clampValue(outputL_, -1.0, 1.0));
      output[frame * 2 + 1] =
          static_cast<float>(clampValue(outputR_, -1.0, 1.0));
      if (measure) synth_stats_sample(&stats_, output[frame*2], output[frame*2+1], limiterGain_, renderSampleRate_);
    }
    }else {
    constexpr int tileCapacity=16;
    for (int32_t frame=0;frame<frames;) {
      // Sequence boundaries are processed only at their actual sample, before
      // planning clocks. Future attacks must never steal voices ahead of time.
      if(transport_.activeMask)for(int slot=0;slot<transport_.capacity;slot++)if(transport_.activeMask&(1u<<slot))processSequence(slot);
      double beats[tileCapacity],milliseconds[tileCapacity];
      double dryL[tileCapacity]={},dryR[tileCapacity]={},selectedL[tileCapacity]={},selectedR[tileCapacity]={};
      int count=0;
      do {
        beats[count]=transport_.beat;milliseconds[count]=transport_.milliseconds;
        synth_transport_advance_sample(&transport_);++count;
        bool due=false;
        if(transport_.activeMask)for(int slot=0;slot<transport_.capacity;slot++)if(transport_.activeMask&(1u<<slot)) {
          const auto &sequence=transport_.slots[slot];
          if(sequence.beat+1e-10>=sequence.nextBeat){due=true;break;}
        }
        if(due)break;
      }while(count<tileCapacity&&frame+count<frames);
      // Voice order remains identical for every individual frame. A small
      // tile keeps one voice's FIR data resident across consecutive samples.
      auto mix=[&](int n,double l,double r,double send) {
        if(!processEffects){dryL[n]+=l;dryR[n]+=r;}
        else if(send==1){selectedL[n]+=l;selectedR[n]+=r;}
        else if(send==0){dryL[n]+=l;dryR[n]+=r;}
        else{dryL[n]+=l*(1-send);dryR[n]+=r*(1-send);selectedL[n]+=l*send;selectedR[n]+=r*send;}
      };
      if(stats_.active>0)for(Voice &voice:voices_)if(voice.active) {
        if(voice.spatial) {
          float mono[tileCapacity],l[tileCapacity],r[tileCapacity];double sends[tileCapacity];int n=0;
          for(;n<count&&voice.active;n++) {
            double ignoredL=0,ignoredR=0;
            renderVoice<true>(voice,ignoredL,ignoredR,beats[n],milliseconds[n],mono+n);
            sends[n]=processEffects?synth_send_tick(&voice.send):0;
          }
          synth_spatial_process_block(&voice.spatialState,mono,l,r,n);
          for(int i=0;i<n;i++)mix(i,l[i],r[i],sends[i]);
        }else for(int n=0;n<count&&voice.active;n++) {
          if(!processEffects)renderVoice(voice,dryL[n],dryR[n],beats[n],milliseconds[n]);
          else {double l=0,r=0;renderVoice(voice,l,r,beats[n],milliseconds[n]);mix(n,l,r,synth_send_tick(&voice.send));}
        }
      }
      if(stats_.tails>0)for(Tail &tail:tails_)if(tail.active) {
        if(tail.spatial) {
          float mono[tileCapacity],l[tileCapacity],r[tileCapacity];double sends[tileCapacity];int n=0;
          for(;n<count&&tail.active;n++) {
            double ignoredL=0,ignoredR=0;renderTail<true>(tail,ignoredL,ignoredR,mono+n);
            sends[n]=processEffects?synth_send_tick(&tail.send):0;
          }
          synth_spatial_process_block(&tail.spatialState,mono,l,r,n);
          for(int i=0;i<n;i++)mix(i,l[i],r[i],sends[i]);
        }else for(int n=0;n<count&&tail.active;n++) {
          if(!processEffects)renderTail(tail,dryL[n],dryR[n]);
          else {double l=0,r=0;renderTail(tail,l,r);mix(n,l,r,synth_send_tick(&tail.send));}
        }
      }
      for(int n=0;n<count;n++,frame++) {
        double left=dryL[n],right=dryR[n];
        if(processEffects) {
          smoothedMaster_+=(master_.load(std::memory_order_relaxed)-smoothedMaster_)/lookahead_;
          synth_effects_process_routed(&effects_,transport_.bpm,left,right,selectedL[n],selectedR[n],smoothedMaster_,&left,&right);
        }else{left+=selectedL[n];right+=selectedR[n];}
        limit(left,right,measure,processEffects);
        output[frame*2]=static_cast<float>(clampValue(outputL_,-1.0,1.0));
        output[frame*2+1]=static_cast<float>(clampValue(outputR_,-1.0,1.0));
        if(measure)synth_stats_sample(&stats_,output[frame*2],output[frame*2+1],limiterGain_,renderSampleRate_);
      }
    }
    }
    // Unconfigured processing cannot expose intermediate send values. Advance
    // its ramps at the block boundary before a later FX publication can apply.
    if(!processEffects) {
      for(Voice &voice:voices_)if(voice.active&&voice.send.remaining){int count=(int)std::min<uint64_t>(sampleIndex_-voice.sendFrame,voice.send.remaining);while(count--)synth_send_tick(&voice.send);voice.sendFrame=sampleIndex_;}
      for(Tail &tail:tails_)if(tail.active&&tail.send.remaining){int count=(int)std::min<uint64_t>(sampleIndex_-tail.sendFrame,tail.send.remaining);while(count--)synth_send_tick(&tail.send);tail.sendFrame=sampleIndex_;}
    }
    for(int slot=0;slot<transport_.capacity;slot++)if(__atomic_load_n(&transport_.status[slot],__ATOMIC_ACQUIRE)==2)synth_sequence_publish_state(&transport_.slots[slot]);
    synth_stats_end(&stats_, frames, renderSampleRate_, measure ? std::chrono::duration<double>(std::chrono::steady_clock::now()-begin).count() : 0);
    return oboe::DataCallbackResult::Continue;
  }

  void onErrorAfterClose(oboe::AudioStream *failedStream,
                         oboe::Result error) override {
    // Every error reaching this callback has already closed the stream: a route
    // disconnect, a timeout or an invalid state. Recover from all of them, or
    // the engine stays silent while the app still believes it is running.
    (void)error;
    if (closing_.load(std::memory_order_acquire) ||
        !runningRequested_.load(std::memory_order_acquire))
      return;

    std::lock_guard<std::mutex> guard(streamMutex_);
    if (closing_.load(std::memory_order_acquire) ||
        !runningRequested_.load(std::memory_order_acquire))
      return;
    if (stream_ && stream_.get() != failedStream)
      return;

    // Oboe has already stopped and closed the failed stream before this
    // callback. Drop in-flight voices because their sample counts and phase
    // increments belong to the previous route's sample rate. Commands queued
    // while the route settles remain available to the new stream.
    collectXruns();
    xrunLast_=0;
    stream_.reset();
    clearRenderState();
    reopenAndStartLocked();
  }

private:
  bool openLocked() {
    oboe::AudioStreamBuilder builder;
    const std::shared_ptr<Engine> engine = shared_from_this();
    builder.setDirection(oboe::Direction::Output)
        ->setFormat(oboe::AudioFormat::Float)
        ->setChannelCount(2)
        ->setPerformanceMode(oboe::PerformanceMode::LowLatency)
        ->setSharingMode(oboe::SharingMode::Exclusive)
        ->setUsage(oboe::Usage::Game)
        ->setDataCallback(
            std::static_pointer_cast<oboe::AudioStreamDataCallback>(engine))
        ->setErrorCallback(
            std::static_pointer_cast<oboe::AudioStreamErrorCallback>(engine));
    std::shared_ptr<oboe::AudioStream> newStream;
    oboe::Result result = builder.openStream(newStream);
    if (result != oboe::Result::OK) {
      builder.setSharingMode(oboe::SharingMode::Shared);
      result = builder.openStream(newStream);
    }
    if (result != oboe::Result::OK || !newStream)
      return false;
    renderSampleRate_ = newStream->getSampleRate();
    if (renderSampleRate_ <= 0)
      renderSampleRate_ = 48000;
    reportedSampleRate_.store(renderSampleRate_, std::memory_order_relaxed);
    const int burst = newStream->getFramesPerBurst();
    if (burst > 0)
      newStream->setBufferSizeInFrames(burst * 2);
    transport_.sampleRate=renderSampleRate_;
    for(int i=0;i<transport_.capacity;i++)transport_.slots[i].sampleRate=renderSampleRate_;
    if(!initializeLimiter())return false;
    xrunLast_=0;
    stream_ = std::move(newStream);
    return true;
  }

  bool startLocked() {
    return stream_ && stream_->requestStart() == oboe::Result::OK;
  }

  void closeStreamLocked() {
    if (stream_) {
      stream_->stop();
      collectXruns();
      stream_->close();
      stream_.reset();
    }
  }

  bool reopenAndStartLocked() {
    constexpr int kRestartAttempts = 4;
    for (int attempt = 0; attempt < kRestartAttempts; ++attempt) {
      if (closing_.load(std::memory_order_acquire) ||
          !runningRequested_.load(std::memory_order_acquire))
        return false;
      if (attempt > 0)
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
      if (openLocked() &&
          !closing_.load(std::memory_order_acquire) && startLocked())
        return true;
      closeStreamLocked();
    }
    return false;
  }

  void clearRenderState() {
    for (Voice &voice : voices_) {
      synth_identity_set(&identities_[&voice-voices_.data()],0,0);
      voice = Voice{};
    }
    for (Tail &tail : tails_)
      tail = Tail{};
    synth_stats_stopped(&stats_);
  }

  int toSamples(int ms) const {
    return std::max(1, static_cast<int>(ms * renderSampleRate_ / 1000.0));
  }

  bool initializeLimiter() {
    lookahead_ = std::max(1, static_cast<int>(renderSampleRate_ * 0.010));
    delayL_.assign(lookahead_, 0.0);
    delayR_.assign(lookahead_, 0.0);
    peakValues_.assign(lookahead_ + 1, 0.0);
    peakIndices_.assign(lookahead_ + 1, 0);
    delayIndex_ = peakHead_ = peakCount_ = 0;
    sampleIndex_ = 0;
    limiterGain_ = smoothedMaster_ = 1.0;
    limiterAttackTarget_ = 1.0;
    limiterAttackStep_ = 0.0;
    outputL_ = outputR_ = 0.0;
    auto retainedEffects=effects_.memoryBytes?effects_.config:synth_effects_default_config();
    synth_effects_destroy(&effects_);
    if(!synth_effects_init(&effects_,renderSampleRate_))return false;
    synth_effects_set_config(&effects_,&retainedEffects);
    releaseCoeff_ = 1.0 - std::exp(-1.0 / (0.100 * renderSampleRate_));
    return true;
  }

  void processCommands() {
    uint32_t read = read_.load(std::memory_order_relaxed);
    const uint32_t write = write_.load(std::memory_order_acquire);
    while (read != write) {
      const Command &command = queue_[read];
      if(command.groupCount>0) {
        int slots[kMaxVoices];
        if(selectSlots(command.groupCount,command.priority,slots)) {
          for(int n=0;n<command.groupCount;n++)startVoice(queue_[(read+n)%kQueueCapacity],slots[n]);
        } else priorityDrops_.fetch_add(1,std::memory_order_relaxed);
        read=(read+command.groupCount)%kQueueCapacity;continue;
      }
      if (command.type == 1 || command.type == SYNTH_CMD_HELD_ON)
        {if(!startVoice(command))priorityDrops_.fetch_add(1,std::memory_order_relaxed);}
      else if(command.type == SYNTH_CMD_HELD_OFF || command.type == SYNTH_CMD_HELD_UPDATE) {
        for(Voice &v: voices_) if(v.active && v.held.voiceId==command.voiceId && command.generation!=0 && v.generation==command.generation) {
          if(command.type == SYNTH_CMD_HELD_OFF) synth_held_release(&v.held,v.envelope);
          else if(!(command.liveMask & ~synth_live_allowed(v.waveType,v.filter.type)))
            {synth_live_update(&v.live,command.liveMask,command.liveValues,toSamples(10));if(command.liveMask)v.liveRamping=true;
             if(command.hasSpatialUpdate&&v.spatial){synth_spatial_set_target(&v.spatialState,&command.spatialPrepared,toSamples(10));v.spatialX=command.spatialX;v.spatialY=command.spatialY;
               identityX_[&v-voices_.data()].store(v.spatialX,std::memory_order_relaxed);identityY_[&v-voices_.data()].store(v.spatialY,std::memory_order_relaxed);}
             if(std::isfinite(command.effectSend)){v.effectSend=command.effectSend;v.sendFrame=sampleIndex_;synth_send_update(&v.send,v.bus,v.effectSend,effects_.config.applyToMask,toSamples(10));}
             if(command.hasModulations&&synth_modulation_set_config(&v.modulation,&command.modulations,modulationCapabilities(v)))v.modulating=true;}
          break;
        }
      }
      else if(command.type==8) {synth_effects_set_config(&effects_,&command.effects);effectsActive_=true;
        for(auto &v:voices_)if(v.active)synth_send_update(&v.send,v.bus,v.effectSend,command.effects.applyToMask,toSamples(10));
        for(auto &v:tails_)if(v.active)synth_send_update(&v.send,v.bus,v.effectSend,command.effects.applyToMask,toSamples(10));
      }
      else if(command.type==7) {
        for(auto &v:voices_)if(v.active&&v.held.voiceId==command.voiceId)
          if(synth_modulation_set_config(&v.modulation,&command.modulations,modulationCapabilities(v)))v.modulating=true;
      }
      else if (command.type == 2) panicStop();
      read = (read + 1) % kQueueCapacity;
    }
    read_.store(read, std::memory_order_release);
    // A full queue must not lose panic. Apply after the queued attacks so none
    // of those attacks can survive the fallback control request.
    if(emergencyStopRequested_.exchange(false,std::memory_order_acq_rel))panicStop();
  }

  void panicStop() {
    synth_effects_panic(&effects_);synth_transport_stop_all(&transport_);
    for(Voice &voice:voices_) {
      if(voice.active){snapshotTail(voice,20);synth_stats_voice_end(&stats_,voice.spatial);}
      voice.active=false;synth_identity_set(&identities_[&voice-voices_.data()],0,0);
    }
    // Release fades stay dry: they must not repopulate invalidated FX history.
    for(Tail &tail:tails_)if(tail.active){tail.effectSend=0;synth_send_init(&tail.send,tail.bus,0,effects_.config.applyToMask);}
  }

  bool selectSlots(int count,int priority,int *slots,bool heldIntent=false) {
    if(count<1||count>maxVoices_)return false;
    bool used[kMaxVoices]={};
    bool heldPool=heldIntent;for(const auto &v:voices_)if(v.active&&v.held.voiceId)heldPool=true;
    for(int n=0;n<count;n++) {
      int best=-1;
      for(int i=0;i<maxVoices_;i++) {
        const auto &v=voices_[i];if(used[i]||(v.active&&v.priority>priority))continue;
        if(best<0){best=i;if(!v.active)break;continue;}const auto &old=voices_[best];
        if(!v.active){best=i;break;}if(!old.active)continue;
        bool release=v.held.voiceId?v.held.releasing!=0:v.duration-v.played<=v.release;
        bool oldRelease=old.held.voiceId?old.held.releasing!=0:old.duration-old.played<=old.release;
        if(v.priority<old.priority||(v.priority==old.priority&&(heldPool?(release!=oldRelease?release:v.held.order<old.held.order):v.duration-v.played<old.duration-old.played)))best=i;
      }
      if(best<0)return false;used[best]=true;slots[n]=best;
    }return true;
  }
  Voice *startVoice(const Command &command,int forcedSlot=-1) {
    // Capture before slot selection/clearing: the donor can be the victim.
    bool inherit=false; uint64_t donorOrder=0;
    double inheritedPhase=0,inheritedFM=0,inheritedLFO=0,inheritedFilterState=0;
    SynthFilter inheritedFilter{};
    if(command.type==SYNTH_CMD_HELD_ON && command.voiceId>0 &&
       !command.modulations.lfo[0].enabled && !command.modulations.lfo[1].enabled &&
       command.frequencyEnd<1 && command.pulseWidthEnd<.05 &&
       command.filterHzEnd<SYNTH_FILTER_MIN_HZ && !command.fmDepthSweep) {
      double values[SYNTH_LIVE_COUNT]={command.frequency,command.volume,command.filterHz,command.filterQ,command.lfoFreq,command.lfoDepth,command.pulseWidth,command.fmRatio,command.fmDepth,command.noiseRate>0?command.noiseRate/renderSampleRate_:1,command.lowPassHz>0?1-std::exp(-2*kPi*command.lowPassHz/renderSampleRate_):1,command.pan};
      double cutoff=clampValue(command.lowPassHz,0.0,renderSampleRate_*.45);
      SynthRetriggerKey next={command.waveType,command.filterType,command.bitDepth,command.wavetableSize,cutoff>0?1-std::exp(-2*kPi*cutoff/renderSampleRate_):0,values,command.wavetable.data()};
      for(const Voice &v:voices_) {
        if(!v.active || v.held.voiceId<=0 || !v.held.releasing || v.held.releasePlayed>=v.release ||
           v.played>=v.duration || v.sequenceOwned || v.incrementDelta || v.pulseWidthDelta ||
           v.fmDepthDelta || v.filterHzEnd>0 || synth_modulation_is_active(&v.modulation))continue;
        SynthRetriggerKey old={v.waveType,v.filter.type,v.bitDepth,v.wavetableSize,v.filterAlpha,v.live.value,v.wavetable.data()};
        if(v.held.order>donorOrder && synth_retrigger_compatible(&v.live,&old,&next)) {
          inherit=true;donorOrder=v.held.order;inheritedPhase=v.phase;inheritedFM=v.modPhase;
          inheritedLFO=v.lfoPhase;inheritedFilterState=v.filterState;inheritedFilter=v.filter;
        }
      }
    }
    Voice *voice=forcedSlot>=0?&voices_[forcedSlot]:nullptr;
    if(!voice&&command.voiceId)for(auto &v:voices_)if(v.active&&v.held.voiceId==command.voiceId){if(v.priority>command.priority)return nullptr;voice=&v;break;}
    if(!voice){int slot;if(selectSlots(1,command.priority,&slot,command.type==SYNTH_CMD_HELD_ON))voice=&voices_[slot];}
    if (!voice)
      return nullptr;
    const bool replacing=voice->active;
    synth_stats_voice_start(&stats_, voice->active, voice->spatial, command.spatial);
    if (voice->active)
      snapshotTail(*voice, 6);
    *voice = Voice{};
    voice->active = true;
    voice->sendFrame=sampleIndex_;voice->bus=command.bus;voice->priority=command.priority;voice->effectSend=command.effectSend;
    voice->spatialX=command.spatialX;voice->spatialY=command.spatialY;
    synth_send_init(&voice->send,command.bus,command.effectSend,effects_.config.applyToMask);
    synth_modulation_init(&voice->modulation,renderSampleRate_);
    voice->generation=command.generation;
    identityGenerations_[voice-voices_.data()].store(command.generation,std::memory_order_release);
    identityPriorities_[voice-voices_.data()].store(command.priority,std::memory_order_release);
    identityX_[voice-voices_.data()].store(command.spatialX,std::memory_order_relaxed);
    identityY_[voice-voices_.data()].store(command.spatialY,std::memory_order_relaxed);
    voice->held.voiceId=command.voiceId;
    voice->held.order=++voiceOrder_;
    synth_identity_set(&identities_[voice-voices_.data()],command.voiceId,command.spatial?(synth_live_allowed(command.waveType,command.filterType)&~(1u<<LIVE_PAN))|(1u<<16):synth_live_allowed(command.waveType,command.filterType));
    voice->spatial = command.spatial;
    if (voice->spatial) {
      synth_spatial_init(&voice->spatialState, command.spatialX, command.spatialY, renderSampleRate_);
      voice->spatialDrain = voice->spatialState.taps - 1;
    }
    voice->duration = command.voiceId ? INT32_MAX : std::max(1, command.duration);
    voice->attack = clampValue(command.attack, 0, voice->duration - 1);
    if(command.voiceId && replacing)voice->attack=std::max(voice->attack,toSamples(6));
    voice->release =
        clampValue(command.release, 0, voice->duration - voice->attack);
      if(command.voiceId) {
        int edge=synth_held_edge_samples(renderSampleRate_);
        voice->attack=std::max(voice->attack,edge);
        voice->release=std::max(voice->release,edge);
      }
    voice->waveType = clampValue(command.waveType, 0, 5);
    voice->volume =
        clampValue(command.volume, 0.0, 2.0) *
        eventGain(profile_, voice->waveType, command.eventVoiceCount);
    voice->pan = clampValue(command.pan, -1.0, 1.0);
    updatePan(*voice);
    voice->increment =
        clampValue(command.frequency, 1.0, renderSampleRate_ * 0.45) /
        renderSampleRate_;
    if (command.frequencyEnd >= 1.0 && voice->duration > 1) {
      voice->incrementDelta =
          (command.frequencyEnd / renderSampleRate_ - voice->increment) /
          (voice->duration - 1);
    }
    const double panEnd = clampValue(command.panEnd, -1.0, 1.0);
    if (voice->duration > 1)
      voice->panDelta = (panEnd - voice->pan) / (voice->duration - 1);
    voice->lfoDepth = clampValue(command.lfoDepth, 0.0, 20000.0);
    voice->lfoIncrement =
        clampValue(command.lfoFreq, 0.0, 20000.0) / renderSampleRate_;
    const double noiseRate = command.noiseRate > 0.0
                                 ? clampValue(command.noiseRate, 1.0,
                                              renderSampleRate_ * 0.45)
                                 : renderSampleRate_;
    voice->noiseIncrement = noiseRate / renderSampleRate_;
    if (command.noiseRateEnd >= 1.0 && voice->duration > 1) {
      voice->noiseIncrementDelta =
          (clampValue(command.noiseRateEnd, 1.0, renderSampleRate_ * 0.45) /
               renderSampleRate_ -
           voice->noiseIncrement) /
          (voice->duration - 1);
    }
    const double cutoff = clampValue(command.lowPassHz, 0.0,
                                     renderSampleRate_ * 0.45);
    voice->filterAlpha = cutoff > 0.0
                             ? 1.0 - std::exp(-2.0 * kPi * cutoff / renderSampleRate_)
                             : 0.0;
    voice->pulseWidth = clampValue(command.pulseWidth, 0.05, 0.95);
    if (command.pulseWidthEnd >= 0.05 && voice->duration > 1) {
      voice->pulseWidthDelta =
          (clampValue(command.pulseWidthEnd, 0.05, 0.95) - voice->pulseWidth) /
          (voice->duration - 1);
    }
    voice->decay =
        clampValue(command.decay, 0, std::max(0, voice->duration - voice->attack));
    voice->sustain = clampValue(command.sustain, 0.0, 1.0);
    synth_filter_init(&voice->filter, clampValue(command.filterType, 0, 3));
    if (voice->filter.type != SYNTH_FILTER_NONE) {
      const double maxHz = renderSampleRate_ * 0.45;
      voice->filterHz = clampValue(command.filterHz, SYNTH_FILTER_MIN_HZ, maxHz);
      voice->filterHzEnd = command.filterHzEnd >= SYNTH_FILTER_MIN_HZ
                               ? clampValue(command.filterHzEnd, SYNTH_FILTER_MIN_HZ, maxHz)
                               : 0.0;
      voice->filterQ = command.filterQ;
      synth_filter_set(&voice->filter, voice->filterHz, voice->filterQ,
                       renderSampleRate_);
    }
    voice->fmActive =
        voice->waveType == 0 && (command.fmDepth > 0.0 || command.fmDepthSweep);
    if (voice->fmActive) {
      voice->fmRatio = clampValue(command.fmRatio, 0.1, 16.0);
      voice->fmDepth = clampValue(command.fmDepth, 0.0, 10.0);
      if (command.fmDepthSweep && voice->duration > 1) {
        voice->fmDepthDelta =
            (clampValue(command.fmDepthEnd, 0.0, 10.0) - voice->fmDepth) /
            (voice->duration - 1);
      }
    }
    voice->bitDepth = command.bitDepth == 0 ? 0 : clampValue(command.bitDepth, 2, 16);
    voice->wavetableSize = clampValue(command.wavetableSize, 0, kMaxWavetableSamples);
    voice->wavetable = command.wavetable;
    if(command.voiceId) {
      voice->eventGain=eventGain(profile_,voice->waveType,command.eventVoiceCount);
      double values[SYNTH_LIVE_COUNT]={command.frequency,command.volume,command.filterHz,command.filterQ,command.lfoFreq,command.lfoDepth,command.pulseWidth,command.fmRatio,command.fmDepth,command.noiseRate>0?command.noiseRate/renderSampleRate_:1,command.lowPassHz>0?1-std::exp(-2*kPi*command.lowPassHz/renderSampleRate_):1,command.pan};
      synth_live_init(&voice->live,values);voice->liveRamping=true;
      voice->fmActive=voice->waveType==0;
    }
    voice->controlSweeps=voice->incrementDelta!=0||voice->noiseIncrementDelta!=0||voice->pulseWidthDelta!=0;
    voice->noise = reinterpret_cast<uintptr_t>(voice) ^ sampleIndex_;
    voice->noise = voice->noise * 6364136223846793005ULL + 1442695040888963407ULL;
    voice->heldNoise = static_cast<int32_t>(voice->noise >> 32) / 2147483648.0;
    synth_modulation_set_config(&voice->modulation,&command.modulations,modulationCapabilities(*voice));
    voice->modulating=synth_modulation_is_active(&voice->modulation)!=0;
    if(inherit) {voice->phase=inheritedPhase;voice->modPhase=inheritedFM;voice->lfoPhase=inheritedLFO;voice->filterState=inheritedFilterState;voice->filter=inheritedFilter;}
    return voice;
  }

  static unsigned modulationCapabilities(const Voice &v) {
    return (v.filter.type?SYNTH_MOD_CAP_FILTER:0u)|(v.waveType==1?SYNTH_MOD_CAP_PWM:0u)|(v.waveType==0?SYNTH_MOD_CAP_FM:0u);
  }
  static SynthModulationConfig unpackModulations(const double *p) {
    auto config=synth_modulation_default_config();
    for(int i=0;i<2;i++,p+=6){auto &l=config.lfo[i];l.enabled=(int)p[0];l.waveform=(int)p[1];l.target=(int)p[2];l.rateHz=p[3];l.depth=p[4];l.syncBeats=p[5];}
    return config;
  }
  void updateSequenceOwnership() {
    if(!transport_.clockRunning)return;
    for(auto &v:voices_)if(v.active&&v.sequenceTimed&&!v.held.releasing) {
      if((v.sequenceUnit==SYNTH_SEQUENCE_MS?transport_.milliseconds:transport_.beat)+1e-10>=v.sequenceOffBeat)synth_held_release(&v.held,v.envelope);
      for(int i=0;i<transport_.capacity;i++)if(__atomic_load_n(&transport_.latestStoppedId[i],__ATOMIC_ACQUIRE)==v.sequenceId)
        synth_held_release(&v.held,v.envelope);
    }
  }
  void processSequence(int slotIndex) {
    SynthSequenceEvent event;
    bool fired=synth_transport_tick(&transport_,slotIndex,&event)!=0;
    if(!fired||event.noteCount==0)return;
    // Expired native gates release before an atomic attack selects its victims.
    for(auto &v:voices_)if(v.active&&v.sequenceTimed&&!v.held.releasing&&
       (v.sequenceUnit==SYNTH_SEQUENCE_MS?transport_.milliseconds:transport_.beat)+1e-10>=v.sequenceOffBeat)synth_held_release(&v.held,v.envelope);
    auto &slot=transport_.slots[slotIndex];
    const auto &config=slot.banks[event.bank];const auto &shape=config.steps[event.stepIndex].voice;
    int slots[kMaxVoices];if(!selectSlots(event.noteCount,shape.priority,slots,true)){priorityDrops_.fetch_add(1,std::memory_order_relaxed);return;}
    for(int n=0;n<event.noteCount;n++) {
      Command c;c.type=SYNTH_CMD_HELD_ON;c.voiceId=nextSequenceVoiceId_;
      nextSequenceVoiceId_=nextSequenceVoiceId_==INT32_MIN?-1:nextSequenceVoiceId_-1;
      c.frequency=event.frequencies[n];c.eventVoiceCount=event.noteCount;
      c.attack=toSamples(shape.attack);c.decay=shape.decay?toSamples(shape.decay):0;c.release=toSamples(shape.release);
      c.volume=shape.volume;c.pan=c.panEnd=shape.pan;c.waveType=shape.waveType;c.sustain=shape.sustain;
      c.lfoFreq=shape.lfoFreq;c.lfoDepth=shape.lfoDepth;c.noiseRate=shape.noiseRate;c.lowPassHz=shape.lowPassHz;
      c.pulseWidth=shape.pulseWidth;c.filterType=shape.filterType;c.filterHz=shape.filterHz;c.filterQ=shape.filterQ;
      c.fmRatio=shape.fmRatio;c.fmDepth=shape.fmDepth;c.bitDepth=shape.bitDepth;
      c.spatial=shape.spatial;c.spatialX=shape.spatialX;c.spatialY=shape.spatialY;
      c.bus=shape.bus;c.effectSend=shape.effectSend;c.priority=shape.priority;
      c.modulations=unpackModulations(shape.mods);
      c.wavetableSize=shape.wavetableSize;std::copy(shape.wavetable,shape.wavetable+64,c.wavetable.begin());
      Voice *v=startVoice(c,slots[n]);if(v){
        v->sequenceShape=shape;
        v->sequenceSweeps=shape.frequencyEnd>0||shape.noiseRateEnd>0||shape.pan!=shape.panEnd||shape.pulseWidthEnd>=.05||shape.fmDepthSweep||shape.filterHzEnd>=SYNTH_FILTER_MIN_HZ;
        v->sequenceOwned=true;v->sequenceTimed=true;v->sequenceSlot=slotIndex;v->sequenceId=event.sequenceId;
        v->sequenceUnit=config.timeUnit;v->sequenceStep=event.stepIndex;v->sequenceMidi=event.notes[n];
        v->sequenceOffBeat=(config.timeUnit==SYNTH_SEQUENCE_MS?transport_.milliseconds:transport_.beat)+event.length;
        v->sequenceGeneration=event.generation;
        if(shape.frequencyEnd>0){v->sequenceStartFrequency=c.frequency;v->sequenceEndFrequency=shape.frequencyEnd;}
        v->sequenceLength=event.length;v->sequenceStarted=v->sequenceOffBeat-event.length;
      }
    }
  }

  void updatePan(Voice &voice) {
    const double angle = (voice.pan + 1.0) * kPi * 0.25;
    voice.left = std::cos(angle);
    voice.right = std::sin(angle);
  }

  void snapshotTail(const Voice &voice, int milliseconds) {
    Tail *tail = nullptr;
    for (Tail &candidate : tails_) {
      if (!candidate.active) {
        tail = &candidate;
        break;
      }
      if (!tail || candidate.remaining < tail->remaining)
        tail = &candidate;
    }
    if (!tail)
      return;
    synth_stats_tail_start(&stats_, tail->active);
    tail->active = true;tail->bus=voice.bus;tail->effectSend=voice.effectSend;tail->send=voice.send;
    if(!effectsActive_){int count=(int)std::min<uint64_t>(sampleIndex_-voice.sendFrame,tail->send.remaining);while(count--)synth_send_tick(&tail->send);}
    tail->sendFrame=sampleIndex_;
    tail->spatial = voice.spatial;
    if (tail->spatial) {
      tail->spatialState = voice.spatialState;
      tail->spatialDrain = tail->spatialState.taps - 1;
    }
    tail->phase = voice.phase;
    tail->increment = clampValue(voice.increment, -0.45, 0.45);
    tail->volume = voice.volume * clampValue(voice.envelope, 0.0, 1.0);
    tail->waveType = voice.waveType;
    tail->left = voice.left;
    tail->right = voice.right;
    tail->noise = voice.noise;
    tail->noisePhase = voice.noisePhase;
    tail->noiseIncrement = voice.noiseIncrement;
    tail->heldNoise = voice.heldNoise;
    tail->filterState = voice.filterState;
    tail->filterAlpha = voice.filterAlpha;
    tail->pulseWidth = voice.pulseWidth;
    tail->bitDepth = voice.bitDepth;
    tail->wavetableSize = voice.wavetableSize;
    tail->wavetable = voice.wavetable;
    tail->filter = voice.filter;
    tail->fmActive = voice.fmActive;
    tail->fmRatio = voice.fmRatio;
    tail->fmDepth = voice.fmDepth;
    tail->modPhase = voice.modPhase;
    tail->total = toSamples(milliseconds);
    tail->remaining = tail->total;
  }

  template<bool Deferred=false>
  void renderTail(Tail &tail, double &left, double &right,float *mono=nullptr) {
    if (!tail.active)
      return;
    if (tail.spatial && tail.remaining <= 0) {
      if(Deferred) *mono=0;
      else {float l,r;synth_spatial_process(&tail.spatialState,0,&l,&r);left+=l;right+=r;}
      if (--tail.spatialDrain <= 0) { tail.active = false; synth_stats_tail_end(&stats_); }
      return;
    }
    double wave;
    if (tail.waveType == 4) {
      tail.noisePhase += tail.noiseIncrement;
      if (tail.noisePhase >= 1.0) {
        tail.noisePhase -= std::floor(tail.noisePhase);
        tail.noise = tail.noise * 6364136223846793005ULL + 1442695040888963407ULL;
        tail.heldNoise = static_cast<int32_t>(tail.noise >> 32) / 2147483648.0;
      }
      wave = tail.heldNoise;
    } else if (tail.waveType == 5) {
      wave = wavetableWave(tail.phase, tail.wavetable, tail.wavetableSize);
    } else if (tail.fmActive) {
      wave = synth_fm_sine(tail.phase, tail.modPhase, tail.fmDepth);
    } else {
      wave = periodicWave(tail.waveType, tail.phase, tail.increment, tail.pulseWidth);
    }
    wave = quantizeWave(wave, tail.bitDepth);
    if (tail.filterAlpha > 0.0) {
      tail.filterState += tail.filterAlpha * (wave - tail.filterState);
      wave = tail.filterState;
    }
    wave = synth_filter_process(&tail.filter, wave);
    const double fade = smoothStep(static_cast<double>(tail.remaining - 1) /
                                   std::max(1, tail.total - 1));
    const double sample = wave * tail.volume * fade;
    if (tail.spatial) {
      if(Deferred) *mono=static_cast<float>(sample);
      else {float spatialL,spatialR;synth_spatial_process(&tail.spatialState,static_cast<float>(sample),&spatialL,&spatialR);left+=spatialL;right+=spatialR;}
    } else {
      left += sample * tail.left;
      right += sample * tail.right;
    }
    tail.phase += tail.increment;
    tail.phase -= std::floor(tail.phase);
    if (tail.fmActive) {
      tail.modPhase += tail.increment * tail.fmRatio;
      tail.modPhase -= std::floor(tail.modPhase);
    }
    if (--tail.remaining <= 0 && !tail.spatial)
      { tail.active = false; synth_stats_tail_end(&stats_); }
  }

  __attribute__((always_inline)) void renderVoice(Voice &voice,double &left,double &right) {renderVoice<false,false>(voice,left,right,0,0);}

  template<bool Deferred=false,bool Clocked=true>
  __attribute__((always_inline)) void renderVoice(Voice &voice, double &left, double &right,double nowBeat,double nowMs,float *mono=nullptr) {
    if (!voice.active)
      return;
    if(voice.sequenceTimed&&!voice.held.releasing&&
       (voice.sequenceUnit==SYNTH_SEQUENCE_MS?(Clocked?nowMs:transport_.milliseconds):(Clocked?nowBeat:transport_.beat))+1e-10>=voice.sequenceOffBeat)
      synth_held_release(&voice.held,voice.envelope);
    if (voice.spatial && voice.played >= voice.duration) {
      if(Deferred) *mono=0;
      else {float l,r;synth_spatial_process(&voice.spatialState,0,&l,&r);left+=l;right+=r;}
      if (--voice.spatialDrain <= 0) { voice.active = false; synth_stats_voice_end(&stats_, true); }
      return;
    }
    if(voice.held.voiceId) {
      if(voice.liveRamping) {
      synth_live_tick(&voice.live);
      const double *v=voice.live.value;
      voice.increment=v[LIVE_FREQUENCY]/renderSampleRate_;
      voice.volume=v[LIVE_VOLUME]*voice.eventGain;
      voice.lfoIncrement=v[LIVE_LFO_FREQ]/renderSampleRate_; voice.lfoDepth=v[LIVE_LFO_DEPTH];
      voice.noiseIncrement=v[LIVE_NOISE_RATE];
      voice.filterAlpha=v[LIVE_LOWPASS_HZ]>=1?0:v[LIVE_LOWPASS_HZ];
      if(!voice.spatial&&!(voice.sequenceTimed&&voice.sequenceShape.pan!=voice.sequenceShape.panEnd)&&voice.pan!=v[LIVE_PAN]){voice.pan=v[LIVE_PAN];updatePan(voice);}
      voice.pulseWidth=v[LIVE_PULSE_WIDTH]; voice.fmRatio=v[LIVE_FM_RATIO]; voice.fmDepth=v[LIVE_FM_DEPTH];
      if(voice.filter.type && !(voice.sequenceTimed&&voice.sequenceShape.filterHzEnd>=SYNTH_FILTER_MIN_HZ) && (voice.live.remaining[LIVE_FILTER_HZ]>0 || voice.live.remaining[LIVE_FILTER_Q]>0 || voice.filterHz!=v[LIVE_FILTER_HZ] || voice.filterQ!=v[LIVE_FILTER_Q])) {
        voice.filterHz=v[LIVE_FILTER_HZ]; voice.filterQ=v[LIVE_FILTER_Q];
        synth_filter_set(&voice.filter,voice.filterHz,voice.filterQ,renderSampleRate_);
      }
      voice.liveRamping=false;for(int i=0;i<SYNTH_LIVE_COUNT;i++)if(voice.live.remaining[i]){voice.liveRamping=true;break;}
      }
      if(voice.sequenceSweeps) {
        const auto &shape=voice.sequenceShape;
        double now=voice.sequenceUnit==SYNTH_SEQUENCE_MS?(Clocked?nowMs:transport_.milliseconds):(Clocked?nowBeat:transport_.beat);
        double f=clampValue((now-voice.sequenceStarted)/voice.sequenceLength,0.0,1.0);
        if(shape.frequencyEnd>0)voice.increment=(voice.sequenceStartFrequency+(shape.frequencyEnd-voice.sequenceStartFrequency)*f)/renderSampleRate_;
        if(shape.noiseRateEnd>0)voice.noiseIncrement=(shape.noiseRate>0?shape.noiseRate+(shape.noiseRateEnd-shape.noiseRate)*f:renderSampleRate_+(shape.noiseRateEnd-renderSampleRate_)*f)/renderSampleRate_;
        if(shape.pan!=shape.panEnd&&!voice.spatial){double pan=shape.pan+(shape.panEnd-shape.pan)*f;if(voice.pan!=pan){voice.pan=pan;updatePan(voice);}}
        if(shape.pulseWidthEnd>=.05)voice.pulseWidth=shape.pulseWidth+(shape.pulseWidthEnd-shape.pulseWidth)*f;
        if(shape.fmDepthSweep)voice.fmDepth=shape.fmDepth+(shape.fmDepthEnd-shape.fmDepth)*f;
      }
    if(voice.sequenceSweeps&&voice.filter.type&&voice.sequenceShape.filterHzEnd>=SYNTH_FILTER_MIN_HZ&&
       ((voice.sequenceFilterFrames++&15u)==0||((voice.sequenceUnit==SYNTH_SEQUENCE_MS?(Clocked?nowMs:transport_.milliseconds):(Clocked?nowBeat:transport_.beat))>=voice.sequenceOffBeat&&voice.filterHz!=voice.sequenceShape.filterHzEnd))) {
      double now=voice.sequenceUnit==SYNTH_SEQUENCE_MS?(Clocked?nowMs:transport_.milliseconds):(Clocked?nowBeat:transport_.beat);
      double f=clampValue((now-voice.sequenceStarted)/voice.sequenceLength,0.0,1.0);
      double hz=synth_geometric_at(voice.sequenceShape.filterHz,voice.sequenceShape.filterHzEnd,f);
      if(voice.filterHz!=hz){voice.filterHz=hz;synth_filter_set(&voice.filter,hz,voice.filterQ,renderSampleRate_);}
    }
    }
    double effectivePWM=voice.pulseWidth,effectiveFM=voice.fmDepth;
    SynthModulationOutput mod={0,0,0};
    bool modulating=voice.modulating;
    if(modulating) {mod=synth_modulation_tick(&voice.modulation,transport_.bpm);voice.modulating=synth_modulation_is_active(&voice.modulation)!=0;}
    if(modulating) {
      effectivePWM=synth_modulation_pwm(effectivePWM,mod.pwmOffset);
      effectiveFM=synth_modulation_fm(effectiveFM,mod.fmOffset);
    }
    if(voice.filter.type && modulating && ((voice.modulationFrames++&15u)==0||!voice.modulating))
      synth_filter_set(&voice.filter,synth_modulation_cutoff(voice.filterHz,mod.cutoffOctaves,renderSampleRate_),voice.filterQ,renderSampleRate_);
    double increment = voice.increment;
    if (voice.lfoDepth > 0.0) {
      increment +=
          std::sin(voice.lfoPhase * 2.0 * kPi) * voice.lfoDepth /
          renderSampleRate_;
      voice.lfoPhase += voice.lfoIncrement;
      if (voice.lfoPhase >= 1.0)
        voice.lfoPhase -= 1.0;
    }
    increment = clampValue(increment, -0.45, 0.45);
    double wave;
    if (voice.waveType == 4) {
      voice.noisePhase += clampValue(voice.noiseIncrement, 1.0e-9, 1.0);
      if (voice.noisePhase >= 1.0) {
        voice.noisePhase -= std::floor(voice.noisePhase);
        voice.noise =
            voice.noise * 6364136223846793005ULL + 1442695040888963407ULL;
        voice.heldNoise = static_cast<int32_t>(voice.noise >> 32) / 2147483648.0;
      }
      wave = voice.heldNoise;
    } else if (voice.waveType == 5) {
      wave = wavetableWave(voice.phase, voice.wavetable, voice.wavetableSize);
    } else if (voice.fmActive) {
      wave = synth_fm_sine(voice.phase, voice.modPhase, effectiveFM);
    } else {
      wave = periodicWave(voice.waveType, voice.phase, increment, effectivePWM);
    }
    wave = quantizeWave(wave, voice.bitDepth);
    if (voice.filterAlpha > 0.0) {
      voice.filterState += voice.filterAlpha * (wave - voice.filterState);
      wave = voice.filterState;
    }
    if (voice.filter.type != SYNTH_FILTER_NONE) {
      if (voice.filterHzEnd > 0.0 && synth_filter_update_due(1, voice.played)) {
        synth_filter_set(&voice.filter,
                         synth_geometric_at(voice.filterHz, voice.filterHzEnd,
                                            synth_sweep_progress(voice.played, voice.duration)),
                         voice.filterQ, renderSampleRate_);
      }
      wave = synth_filter_process(&voice.filter, wave);
    }
    const double envelope =
        voice.held.voiceId ? synth_held_envelope(&voice.held,voice.played,voice.attack,voice.decay,voice.sustain,voice.release) :
        synth_envelope(voice.played, voice.duration, voice.attack, voice.decay,
                       voice.sustain, voice.release);
    voice.envelope = envelope;
    const double sample = wave * envelope * voice.volume;
    if (voice.spatial) {
      if(Deferred) *mono=static_cast<float>(sample);
      else {float spatialL,spatialR;synth_spatial_process(&voice.spatialState,static_cast<float>(sample),&spatialL,&spatialR);left+=spatialL;right+=spatialR;}
    } else {
      left += sample * voice.left;
      right += sample * voice.right;
    }
    voice.phase += increment;
    voice.phase -= std::floor(voice.phase);
    if (voice.fmActive) {
      voice.modPhase += increment * voice.fmRatio;
      voice.modPhase -= std::floor(voice.modPhase);
      voice.fmDepth = clampValue(voice.fmDepth + voice.fmDepthDelta, 0.0, 10.0);
    }
    if(voice.controlSweeps) {
      voice.increment += voice.incrementDelta;
      voice.noiseIncrement += voice.noiseIncrementDelta;
      voice.pulseWidth = clampValue(voice.pulseWidth + voice.pulseWidthDelta, 0.05, 0.95);
    }
    if (voice.panDelta != 0.0) {
      voice.pan = clampValue(voice.pan + voice.panDelta, -1.0, 1.0);
      updatePan(voice);
    }
    bool finished;
    if(voice.held.voiceId) {
      if(voice.played < voice.attack+voice.decay) ++voice.played;
      finished=voice.held.releasing && ++voice.held.releasePlayed>=std::max(1,voice.release);
      if(finished) {voice.played=voice.duration; synth_identity_set(&identities_[&voice-voices_.data()],0,0);}
    } else finished=++voice.played>=voice.duration;
    if (finished) {
      if (voice.spatial) voice.envelope = 0;
      else { voice.active = false; synth_stats_voice_end(&stats_, false); }
    }
  }

  void limit(double left, double right, bool measure,bool effectsProcessed=false) {
    const double targetMaster = master_.load(std::memory_order_relaxed);
    if(!effectsProcessed){smoothedMaster_ += (targetMaster - smoothedMaster_) / lookahead_;left*=smoothedMaster_;right*=smoothedMaster_;}
    if(measure)synth_stats_pre_limiter(&stats_,left,right);
    const int index = delayIndex_;
    const double delayedL = delayL_[index], delayedR = delayR_[index];
    delayL_[index] = left;
    delayR_[index] = right;
    delayIndex_ = (index + 1) % lookahead_;

    const int capacity = lookahead_ + 1;
    const int64_t oldest = static_cast<int64_t>(sampleIndex_) - lookahead_;
    while (peakCount_ > 0 && peakIndices_[peakHead_] < oldest) {
      peakHead_ = (peakHead_ + 1) % capacity;
      --peakCount_;
    }
    const double peak = std::max(std::abs(left), std::abs(right));
    while (peakCount_ > 0) {
      const int last = (peakHead_ + peakCount_ - 1) % capacity;
      if (peakValues_[last] > peak)
        break;
      --peakCount_;
    }
    const int insert = (peakHead_ + peakCount_) % capacity;
    peakValues_[insert] = peak;
    peakIndices_[insert] = sampleIndex_++;
    ++peakCount_;
    const double windowPeak = peakValues_[peakHead_];
    const double ceiling = profile_ == 3 ? 0.70 : 0.85;
    const double targetGain = windowPeak > ceiling ? ceiling / windowPeak : 1.0;
    // Reach the required gain before the peak leaves the lookahead window.
    // An exponential attack still misses the ceiling at that deadline.
    if (targetGain < limiterGain_) {
      limiterAttackTarget_ = std::min(limiterAttackTarget_, targetGain);
      const double requiredStep = (limiterAttackTarget_ - limiterGain_) / lookahead_;
      limiterAttackStep_ = std::min(limiterAttackStep_, requiredStep);
    }
    if (limiterAttackStep_ < 0.0 && limiterGain_ > limiterAttackTarget_) {
      limiterGain_ = std::max(limiterAttackTarget_, limiterGain_ + limiterAttackStep_);
    } else {
      limiterAttackTarget_ = 1.0;
      limiterAttackStep_ = 0.0;
      limiterGain_ = std::min(targetGain, limiterGain_ + (1.0 - limiterGain_) *
                                                             releaseCoeff_);
    }
    if (peak <= 1.0e-12 && windowPeak <= 1.0e-12
        && std::abs(delayedL) <= 1.0e-12 && std::abs(delayedR) <= 1.0e-12) {
      limiterGain_ = 1.0;
      limiterAttackTarget_ = 1.0;
      limiterAttackStep_ = 0.0;
      peakHead_ = peakCount_ = 0;
    }
    outputL_ = delayedL * limiterGain_;
    outputR_ = delayedR * limiterGain_;
  }

  int64_t xrunTotal_=0, xrunLast_=0;
  bool xrunAvailable_=false, xrunCoverageLost_=false;
  bool effectsActive_=false;
  SynthEffects effects_{};
  SynthTransport transport_{};
  int32_t nextSequenceVoiceId_=-1;
  std::atomic<uint64_t> priorityDrops_{0};
  SynthStats stats_{};
  int maxVoices_, profile_, renderSampleRate_ = 48000;
  std::atomic<int> reportedSampleRate_{48000};
  std::vector<Voice> voices_;
  std::vector<Tail> tails_;
  std::shared_ptr<oboe::AudioStream> stream_;
  std::mutex streamMutex_;
  std::atomic<bool> runningRequested_{false};
  std::atomic<bool> emergencyStopRequested_{false};
  std::atomic<bool> closing_{false};
  std::array<Command, kQueueCapacity> queue_{};
  std::atomic<uint32_t> read_{0}, write_{0};
  std::mutex producerMutex_;
  std::atomic<double> master_{1.0};
  std::vector<double> delayL_, delayR_, peakValues_;
  std::vector<int64_t> peakIndices_;
  int lookahead_ = 1, delayIndex_ = 0, peakHead_ = 0, peakCount_ = 0;
  uint64_t sampleIndex_ = 0, voiceOrder_ = 0;
  std::array<SynthLiveIdentity,kMaxVoices> identities_{};
  std::array<std::atomic<uint64_t>,kMaxVoices> identityGenerations_{};
  std::array<std::atomic<int>,kMaxVoices> identityPriorities_{};
  std::array<std::atomic<double>,kMaxVoices> identityX_{},identityY_{};
  uint64_t controlGeneration_=0;
  double releaseCoeff_ = 0.0, limiterGain_ = 1.0, smoothedMaster_ = 1.0;
  double limiterAttackTarget_ = 1.0, limiterAttackStep_ = 0.0;
  double outputL_ = 0.0, outputR_ = 0.0;
};

using EngineHandle = std::shared_ptr<Engine>;

EngineHandle fromHandle(jlong handle) {
  return *reinterpret_cast<EngineHandle *>(handle);
}

Command makeCommand(Engine *engine, double frequency, int durationMs,
                    int attackMs, int releaseMs, double volume, int waveType,
                    double pan, double panEnd, double frequencyEnd,
                    double lfoFreq, double lfoDepth, double noiseRate,
                    double noiseRateEnd, double lowPassHz, double pulseWidth,
                    double pulseWidthEnd, int bitDepth) {
  Command command;command.effectSend=-1;
  command.type = 1;
  command.frequency = frequency;
  command.duration =
      std::max(1, static_cast<int>(durationMs * engine->sampleRate() / 1000.0));
  command.attack =
      std::max(0, static_cast<int>(attackMs * engine->sampleRate() / 1000.0));
  command.release =
      std::max(0, static_cast<int>(releaseMs * engine->sampleRate() / 1000.0));
  command.volume = volume;
  command.waveType = waveType;
  command.pan = pan;
  command.panEnd = panEnd;
  command.frequencyEnd = frequencyEnd;
  command.lfoFreq = lfoFreq;
  command.lfoDepth = lfoDepth;
  command.noiseRate = noiseRate;
  command.noiseRateEnd = noiseRateEnd;
  command.lowPassHz = lowPassHz;
  command.pulseWidth = pulseWidth;
  command.pulseWidthEnd = pulseWidthEnd;
  command.bitDepth = bitDepth;
  return command;
}

void applyExtras(JNIEnv *env, Command &command, jdoubleArray extras,
                 int sampleRate) {
  double v[kExtraCount] = {0.0, 1.0, 0.0, 1000.0, 0.0, 0.7071, 1.0, 0.0, NAN};
  if (extras) {
    const int count = std::min<int>(env->GetArrayLength(extras), kExtraCount);
    env->GetDoubleArrayRegion(extras, 0, count, v);
  }
  command.decay = std::max(0, static_cast<int>(v[0] * sampleRate / 1000.0));
  command.sustain = v[1];
  command.filterType = static_cast<int>(v[2]);
  command.filterHz = v[3];
  command.filterHzEnd = v[4];
  command.filterQ = v[5];
  command.fmRatio = v[6];
  command.fmDepth = v[7];
  command.fmDepthSweep = !std::isnan(v[8]);
  command.fmDepthEnd = command.fmDepthSweep ? v[8] : 0.0;
  command.spatial = v[9] != 0.0;
  command.spatialX = v[10];
  command.spatialY = v[11];
  command.bus=(int)v[25];command.effectSend=extras&&env->GetArrayLength(extras)>26?v[26]:-1;command.priority=(int)v[27];
  command.voiceId = static_cast<int32_t>(v[12]);
  if(command.voiceId) command.type=SYNTH_CMD_HELD_ON;
  for(int i=0;i<2;i++) {double *p=v+13+i*6;auto &l=command.modulations.lfo[i];l.enabled=(int)p[0];l.waveform=(int)p[1];l.target=(int)p[2];l.rateHz=p[3];l.depth=p[4];l.syncBeats=p[5];}
}
} // namespace

extern "C" JNIEXPORT jlong JNICALL Java_ti_synthengine_SynthThread_nativeCreate(
    JNIEnv *, jclass, jint voices, jint profile,jint maxSequences) {
  auto engine = std::make_shared<Engine>(voices, profile,maxSequences);
  if (!engine->open())
    return 0;
  return reinterpret_cast<jlong>(new EngineHandle(std::move(engine)));
}
extern "C" JNIEXPORT jint JNICALL
Java_ti_synthengine_SynthThread_nativeGetSampleRate(JNIEnv *, jclass,
                                                    jlong handle) {
  return fromHandle(handle)->sampleRate();
}
extern "C" JNIEXPORT jboolean JNICALL
Java_ti_synthengine_SynthThread_nativeStart(JNIEnv *, jclass, jlong handle) {
  return fromHandle(handle)->start();
}
extern "C" JNIEXPORT void JNICALL
Java_ti_synthengine_SynthThread_nativeSetMasterVolume(JNIEnv *, jclass,
                                                      jlong handle,
                                                      jdouble value) {
  fromHandle(handle)->setVolume(value);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_ti_synthengine_SynthThread_nativeEnqueueNote(
    JNIEnv *env, jclass, jlong handle, jdouble frequency, jint duration,
    jint attack, jint release, jdouble volume, jint waveType, jdouble pan,
    jdouble panEnd, jdouble frequencyEnd, jdouble lfoFreq, jdouble lfoDepth,
    jdouble noiseRate, jdouble noiseRateEnd, jdouble lowPassHz,
    jdouble pulseWidth, jdouble pulseWidthEnd, jint bitDepth,
    jdoubleArray wavetable,
    jdoubleArray extras) {
  EngineHandle engine = fromHandle(handle);
  Command command =
      makeCommand(engine.get(), frequency, duration, attack, release, volume,
                  waveType, pan, panEnd, frequencyEnd, lfoFreq, lfoDepth,
                  noiseRate, noiseRateEnd, lowPassHz, pulseWidth, pulseWidthEnd,
                  bitDepth);
  if (wavetable) {
    const int count = std::min<int>(env->GetArrayLength(wavetable),
                                    kMaxWavetableSamples);
    env->GetDoubleArrayRegion(wavetable, 0, count, command.wavetable.data());
    command.wavetableSize = count;
  }
  applyExtras(env, command, extras, engine->sampleRate());
  return engine->enqueue(command);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_ti_synthengine_SynthThread_nativeEnqueueChord(
    JNIEnv *env, jclass, jlong handle, jdoubleArray frequencies, jint duration,
    jint attack, jint release, jdouble volume, jint waveType,
    jdoubleArray pans, jdouble noiseRate, jdouble lowPassHz,
    jdouble pulseWidth, jint bitDepth, jdoubleArray wavetable,
    jdoubleArray extras) {
  if (!frequencies)
    return true;
  EngineHandle engine = fromHandle(handle);
  const int count = std::min<int>(env->GetArrayLength(frequencies), kMaxVoices);
  if (count <= 0)
    return true;
  std::vector<double> freq(count), pan(count, 0.0);
  env->GetDoubleArrayRegion(frequencies, 0, count, freq.data());
  if (pans)
    env->GetDoubleArrayRegion(
        pans, 0, std::min<int>(count, env->GetArrayLength(pans)), pan.data());
  std::vector<Command> commands;
  commands.reserve(count);
  for (int i = 0; i < count; ++i) {
    Command command =
        makeCommand(engine.get(), freq[i], duration, attack, release, volume,
                    waveType, pan[i], pan[i], 0.0, 0.0, 0.0, noiseRate, 0.0,
                    lowPassHz, pulseWidth, 0.0, bitDepth);
    if (wavetable) {
      const int tableCount = std::min<int>(env->GetArrayLength(wavetable),
                                           kMaxWavetableSamples);
      env->GetDoubleArrayRegion(wavetable, 0, tableCount, command.wavetable.data());
      command.wavetableSize = tableCount;
    }
    applyExtras(env, command, extras, engine->sampleRate());
    command.eventVoiceCount = count;
    commands.push_back(command);
  }
  return engine->enqueueChord(std::move(commands));
}
extern "C" JNIEXPORT jboolean JNICALL
Java_ti_synthengine_SynthThread_nativeStopAll(JNIEnv *, jclass, jlong handle) {
  return fromHandle(handle)->stopAll();
}
extern "C" JNIEXPORT void JNICALL
Java_ti_synthengine_SynthThread_nativeDestroy(JNIEnv *, jclass, jlong handle) {
  std::unique_ptr<EngineHandle> engineHandle(
      reinterpret_cast<EngineHandle *>(handle));
  (*engineHandle)->close();
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_ti_synthengine_SynthThread_nativeGetStats(JNIEnv *env, jclass, jlong handle) {
  auto e=fromHandle(handle);
  double values[SYNTH_STATS_COUNT+7]; e->readStats(values);
  values[SYNTH_STATS_COUNT+6]=(double)e->priorityDropCount();
  values[SYNTH_STATS_COUNT]=e->pendingCommands();
  e->backendStats(values[SYNTH_STATS_COUNT+1],values[SYNTH_STATS_COUNT+2],values[SYNTH_STATS_COUNT+5]);
  values[SYNTH_STATS_COUNT+3]=e->sampleRate();
  values[SYNTH_STATS_COUNT+4]=e->maxVoices();
  jdoubleArray result=env->NewDoubleArray(SYNTH_STATS_COUNT+7);
  if(result) env->SetDoubleArrayRegion(result,0,SYNTH_STATS_COUNT+7,values);
  return result;
}
extern "C" JNIEXPORT void JNICALL
Java_ti_synthengine_SynthThread_nativeStatsControl(JNIEnv *, jclass, jlong handle, jint operation) {
  auto e=fromHandle(handle);
  if(operation==3) e->close();
  else if(operation==2) e->resetStats(); else e->enableStats(operation==1);
}

extern "C" JNIEXPORT jint JNICALL Java_ti_synthengine_SynthThread_nativeVoiceMask(JNIEnv *,jclass,jlong handle,jint id) {
  return fromHandle(handle)->voiceMaskForId(id);
}
extern "C" JNIEXPORT jboolean JNICALL Java_ti_synthengine_SynthThread_nativeVoiceCommand(JNIEnv *env,jclass,jlong handle,jint type,jint id,jint mask,jdoubleArray values) {
  Command c; c.type=type; c.voiceId=id; c.liveMask=static_cast<uint32_t>(mask);
  if(values && env->GetArrayLength(values)>=SYNTH_LIVE_COUNT)env->GetDoubleArrayRegion(values,0,SYNTH_LIVE_COUNT,c.liveValues);
  if(type==6 && values && env->GetArrayLength(values)==28) {
    double controls[4];env->GetDoubleArrayRegion(values,24,4,controls);
    c.hasModulations=((int)controls[0]&2)!=0;c.hasSpatialUpdate=((int)controls[0]&1)!=0;
    c.spatialX=controls[1];c.spatialY=controls[2];c.effectSend=controls[3];
    if(mask&(1u<<LIVE_NOISE_RATE))c.liveValues[LIVE_NOISE_RATE]=c.liveValues[LIVE_NOISE_RATE]>0?c.liveValues[LIVE_NOISE_RATE]/fromHandle(handle)->sampleRate():1;
    if(mask&(1u<<LIVE_LOWPASS_HZ))c.liveValues[LIVE_LOWPASS_HZ]=c.liveValues[LIVE_LOWPASS_HZ]>0?1-std::exp(-2*kPi*c.liveValues[LIVE_LOWPASS_HZ]/fromHandle(handle)->sampleRate()):1;
    double v[12];env->GetDoubleArrayRegion(values,12,12,v);
    for(int i=0;i<2;i++){double *p=v+i*6;auto &l=c.modulations.lfo[i];l.enabled=(int)p[0];l.waveform=(int)p[1];l.target=(int)p[2];l.rateHz=p[3];l.depth=p[4];l.syncBeats=p[5];}
  }
  if(type==7 && values && env->GetArrayLength(values)==12) {
    double v[12];env->GetDoubleArrayRegion(values,0,12,v);
    for(int i=0;i<2;i++){double *p=v+i*6;auto &l=c.modulations.lfo[i];l.enabled=(int)p[0];l.waveform=(int)p[1];l.target=(int)p[2];l.rateHz=p[3];l.depth=p[4];l.syncBeats=p[5];}
  }
  return fromHandle(handle)->enqueue(c);
}

extern "C" JNIEXPORT jboolean JNICALL Java_ti_synthengine_SynthThread_nativePublishSequence(JNIEnv *env,jclass,jlong handle,jint id,jdoubleArray packet,jboolean restart) {
  if(!packet)return false;
  std::vector<double> data(env->GetArrayLength(packet));env->GetDoubleArrayRegion(packet,0,(jsize)data.size(),data.data());
  return fromHandle(handle)->publishSequence((uint32_t)id,data.data(),(int)data.size(),restart);
}
extern "C" JNIEXPORT jboolean JNICALL Java_ti_synthengine_SynthThread_nativeStopSequence(JNIEnv *,jclass,jlong handle,jint id) {return fromHandle(handle)->stopSequence((uint32_t)id);}
extern "C" JNIEXPORT jdoubleArray JNICALL Java_ti_synthengine_SynthThread_nativeSequenceState(JNIEnv *env,jclass,jlong handle,jint id) {
  SynthSequenceState s;if(!fromHandle(handle)->sequenceState((uint32_t)id,&s))return nullptr;
  double values[5]={(double)s.playing,(double)s.stepIndex,s.beat,s.bpm,(double)s.revision};
  auto result=env->NewDoubleArray(5);if(result)env->SetDoubleArrayRegion(result,0,5,values);return result;
}
extern "C" JNIEXPORT jboolean JNICALL Java_ti_synthengine_SynthThread_nativeSetTempo(JNIEnv *,jclass,jlong handle,jdouble bpm) {return fromHandle(handle)->setTempo(bpm);}
extern "C" JNIEXPORT jdoubleArray JNICALL Java_ti_synthengine_SynthThread_nativeSequenceEnds(JNIEnv *env,jclass,jlong handle) {
  double values[8];int count=0;SynthSequenceEnd end;
  while(count<8&&fromHandle(handle)->popSequenceEnd(&end)){values[count++]=end.sequenceId;values[count++]=end.reason;}
  if(!count)return nullptr;
  auto result=env->NewDoubleArray(count);if(result&&count)env->SetDoubleArrayRegion(result,0,count,values);return result;
}

extern "C" JNIEXPORT jboolean JNICALL Java_ti_synthengine_SynthThread_nativeMasterProcessing(JNIEnv *env,jclass,jlong handle,jdoubleArray values) {
  if(!values||env->GetArrayLength(values)!=18)return false;
  double p[18];env->GetDoubleArrayRegion(values,0,18,p);Command c;c.type=8;
  auto &v=c.effects;v.inputGain=p[0];v.chorus={(int)p[1],p[2],p[3],p[4]};
  v.delay={(int)p[5],p[6],p[7],p[8],p[9]};v.reverb={(int)p[10],p[11],p[12],p[13]};v.saturation={(int)p[14],p[15],p[16]};
  v.applyToMask=(uint32_t)p[17];
  if(!synth_effects_validate(&v))return false;return !fromHandle(handle)->enqueue(c);
}
