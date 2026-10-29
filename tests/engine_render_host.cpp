// Host-side render check for the Android engine (android/jni/SynthOboeEngine.cpp).
//
// The engine is compiled unchanged on the host, with its audio stream never
// opened, and driven through the same Command/onAudioReady path the Oboe
// callback uses. It needs the Oboe headers (any Gradle cache that built the
// module has them) and the JDK's jni.h, so it is a local tool, not part of CI.
//
//   OBOE=$(find ~/.gradle -path '*oboe-1.11.0/prefab/modules/oboe/include' | head -1)
//   JH=$(/usr/libexec/java_home)
//   clang++ -std=c++17 -O1 -Wall -I"$OBOE" -I"$JH/include" -I"$JH/include/darwin" \
//     -DHAS_EXPRESSIVE -DENGINE_CPP='"../android/jni/SynthOboeEngine.cpp"' \
//     -Wl,-undefined,dynamic_lookup tests/engine_render_host.cpp -o /tmp/engine_render && /tmp/engine_render
//
// Without -DHAS_EXPRESSIVE the scenarios only use the original Command fields,
// so the same source can be built against an older copy of the engine
// (-DENGINE_CPP='"/path/to/old/SynthOboeEngine.cpp"'). Equal "hash" columns
// prove the default sound did not change.
#ifdef __APPLE__
// Oboe's AudioClock.h calls clock_nanosleep, which macOS lacks. It is never called here.
#include <time.h>
#define TIMER_ABSTIME 1
extern "C" int clock_nanosleep(clockid_t, int, const struct timespec *, struct timespec *);
#endif
#include <oboe/Oboe.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>

#define private public
#include ENGINE_CPP
#undef private

namespace {
constexpr double kRate = 48000.0;
int failures = 0;

#define CHECK(condition, message)                                                   \
  do {                                                                              \
    if (!(condition)) {                                                             \
      std::fprintf(stderr, "FAIL: %s (line %d)\n", message, __LINE__);              \
      ++failures;                                                                   \
    }                                                                               \
  } while (0)

struct Rig {
  EngineHandle engine;
  explicit Rig(int voices = 8, int profile = 1) {
#ifdef SYNTH_BENCH_MAX_SEQUENCES
    engine = std::make_shared<Engine>(voices, profile, SYNTH_BENCH_MAX_SEQUENCES);
#else
    engine = std::make_shared<Engine>(voices, profile);
#endif
    engine->renderSampleRate_ = static_cast<int>(kRate);
    engine->reportedSampleRate_.store(static_cast<int>(kRate));
    engine->initializeLimiter();
  }
  Engine &e() { return *engine; }

  // Start queued commands, then make the noise seeds independent of heap addresses.
  void settle() {
    engine->processCommands();
    uint64_t seed = 1;
    for (Voice &voice : engine->voices_) {
      if (!voice.active) continue;
      voice.noise = seed = seed * 6364136223846793005ULL + 1442695040888963407ULL;
      voice.heldNoise = static_cast<int32_t>(voice.noise >> 32) / 2147483648.0;
    }
  }

  std::vector<float> render(int frames) {
    std::vector<float> out(static_cast<size_t>(frames) * 2);
    int done = 0;
    while (done < frames) {
      const int chunk = std::min(256, frames - done);
      engine->onAudioReady(nullptr, out.data() + static_cast<size_t>(done) * 2, chunk);
      done += chunk;
    }
    return out;
  }
};

Command note(Rig &rig, double freq, int ms, int attackMs, int releaseMs, double vol, int wave,
             double pan = 0.0, double panEnd = 0.0, double freqEnd = 0.0, double lfoFreq = 0.0,
             double lfoDepth = 0.0, double noiseRate = 0.0, double noiseRateEnd = 0.0,
             double lowPassHz = 0.0, double pulseWidth = 0.5, double pulseWidthEnd = 0.0,
             int bitDepth = 0) {
  return makeCommand(&rig.e(), freq, ms, attackMs, releaseMs, vol, wave, pan, panEnd, freqEnd,
                     lfoFreq, lfoDepth, noiseRate, noiseRateEnd, lowPassHz, pulseWidth,
                     pulseWidthEnd, bitDepth);
}

uint64_t fnv(const std::vector<float> &samples) {
  uint64_t hash = 1469598103934665603ULL;
  for (float sample : samples) {
    uint32_t bits;
    std::memcpy(&bits, &sample, sizeof bits);
    for (int shift = 0; shift < 32; shift += 8) {
      hash ^= (bits >> shift) & 0xFFu;
      hash *= 1099511628211ULL;
    }
  }
  return hash;
}

double peak(const std::vector<float> &samples) {
  double p = 0.0;
  for (float s : samples) p = std::max(p, static_cast<double>(std::fabs(s)));
  return p;
}

double rms(const std::vector<float> &s, size_t fromFrame, size_t toFrame) {
  double sum = 0.0;
  for (size_t i = fromFrame; i < toFrame; ++i) sum += static_cast<double>(s[i * 2]) * s[i * 2];
  return std::sqrt(sum / std::max<size_t>(1, toFrame - fromFrame));
}

// Hann-windowed single-bin amplitude, so leakage from a strong neighbour stays negligible.
double amplitudeAt(const std::vector<float> &s, size_t fromFrame, size_t toFrame, double hz) {
  double re = 0.0, im = 0.0, weights = 0.0;
  const double n = static_cast<double>(toFrame - fromFrame);
  for (size_t i = fromFrame; i < toFrame; ++i) {
    const double w = 0.5 - 0.5 * std::cos(2.0 * kPi * (i - fromFrame) / (n - 1.0));
    const double angle = 2.0 * kPi * hz * (i - fromFrame) / kRate;
    re += w * s[i * 2] * std::cos(angle);
    im += w * s[i * 2] * std::sin(angle);
    weights += w;
  }
  return 2.0 * std::sqrt(re * re + im * im) / weights;
}

void report(const char *name, const std::vector<float> &out) {
  std::printf("scenario %-28s hash=%016llx peak=%.6f\n", name,
              static_cast<unsigned long long>(fnv(out)), peak(out));
}

// ---- Scenarios that exist in the original engine: their output must not change. ----
void legacyScenarios() {
  { Rig r; r.e().enqueue(note(r, 440, 500, 50, 50, 1.0, 0)); r.settle(); report("sine default", r.render(30000)); }
  { Rig r; r.e().enqueue(note(r, 220, 600, 5, 120, 0.8, 1, -0.5, 0.5, 880, 5, 20, 0, 0, 0, 0.2, 0.7)); r.settle(); report("square sweep pw pan lfo", r.render(34000)); }
  { Rig r; r.e().enqueue(note(r, 330, 700, 20, 200, 0.9, 2, 0, 0, 0, 6, 15)); r.settle(); report("saw vibrato", r.render(36000)); }
  { Rig r; r.e().enqueue(note(r, 100, 500, 2, 80, 1.0, 4, 0.3, 0.3, 0, 0, 0, 800, 6000, 3000)); r.settle(); report("noise rate sweep lowpass", r.render(30000)); }
  { Rig r; Command c = note(r, 261.63, 500, 10, 60, 1.0, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0.5, 0, 6);
    c.wavetableSize = 4; c.wavetable[0] = -1; c.wavetable[1] = -0.2; c.wavetable[2] = 0.7; c.wavetable[3] = 1;
    r.e().enqueue(c); r.settle(); report("wavetable bitcrush", r.render(30000)); }
  { Rig r; r.e().enqueue(note(r, 90, 400, 10, 40, 1.0, 3, 0, 0, 40)); r.settle(); report("triangle pitch fall", r.render(24000)); }
  { Rig r(16, 2);
    std::vector<Command> chord;
    const double f[4] = {261.63, 329.63, 392.0, 523.25};
    for (int i = 0; i < 4; ++i) {
      Command c = note(r, f[i], 800, 30, 200, 1.0, 1, -0.6 + 0.4 * i, -0.6 + 0.4 * i);
      c.eventVoiceCount = 4;
      chord.push_back(c);
    }
    r.e().enqueueChord(chord); r.settle(); report("square chord", r.render(48000)); }
  { Rig r(2, 1);   // more notes than voices: exercises voice stealing and tails
    for (int i = 0; i < 4; ++i) r.e().enqueue(note(r, 300.0 + 100 * i, 500, 5, 100, 1.0, 2));
    r.settle(); report("voice steal tails", r.render(30000)); }
  { Rig r; r.e().enqueue(note(r, 500, 2000, 5, 100, 1.0, 0)); r.settle(); (void)r.render(6000);
    Command stop; stop.type = 2; r.e().enqueue(stop); report("stopAll fade", r.render(6000)); }
}

#ifdef HAS_EXPRESSIVE
Command expressive(Rig &r, double freq, int ms, int attackMs, int releaseMs, int wave = 0) {
  Command c = note(r, freq, ms, attackMs, releaseMs, 1.0, wave);
  return c;
}

int samples(int ms) { return static_cast<int>(ms * kRate / 1000.0); }
// The engine's lookahead limiter delays its output by 10 ms.
const int kDelay = 480;

void expressiveScenarios() {
  // Decay and sustain: the held level settles at the sustain fraction of the peak.
  { Rig r(8, 0);
    Command c = note(r, 440, 1200, 5, 50, 0.5, 0);   // volume 0.5 keeps the limiter out of the measurement
    c.decay = samples(200); c.sustain = 0.25;
    r.e().enqueue(c); r.settle();
    auto out = r.render(samples(1300));
    // Four whole 440 Hz cycles (436 samples) starting where the attack ends.
    const double peakRms = rms(out, kDelay + samples(5), kDelay + samples(5) + 436);
    const double held = rms(out, kDelay + samples(500), kDelay + samples(900));
    // Left channel of a centered, constant-power pan: 0.5 amplitude * 0.7071 (pan) * 0.7071 (sine RMS).
    CHECK(std::fabs(peakRms - 0.25) < 0.005, "a 0.5 sine peaks at a left-channel RMS of 0.25 once the attack ends");
    CHECK(std::fabs(held / peakRms - 0.25) < 0.03, "held level settles at the sustain fraction");
    const double tail = rms(out, kDelay + samples(1195), kDelay + samples(1200));
    CHECK(tail < held * 0.1, "release still fades a decayed note to silence"); }

  // With no decay the new engine must behave as before: sustain value alone changes nothing.
  { Rig r(8, 0);
    Command a = expressive(r, 440, 500, 5, 50), b = a;
    b.sustain = 0.3;   // ignored by the engine when decay is 0, as the contract also rejects it
    Rig r2(8, 0);
    r.e().enqueue(a); r.settle(); auto oa = r.render(samples(520));
    Command b2 = expressive(r2, 440, 500, 5, 50); b2.sustain = 1.0; r2.e().enqueue(b2); r2.settle();
    auto ob = r2.render(samples(520));
    CHECK(fnv(oa) == fnv(ob), "explicit neutral decay/sustain is bit-identical to the defaults"); }

  // Filters.
  { Rig r(8, 0);
    Command raw = expressive(r, 4000, 600, 2, 20, 1);   // square: strong odd harmonics
    r.e().enqueue(raw); r.settle(); auto plain = r.render(samples(650));
    Rig r2(8, 0);
    Command lp = expressive(r2, 4000, 600, 2, 20, 1);
    lp.filterType = SYNTH_FILTER_LOWPASS; lp.filterHz = 500; lp.filterQ = 0.7071;
    r2.e().enqueue(lp); r2.settle(); auto filtered = r2.render(samples(650));
    const double a = rms(plain, samples(100), samples(500)), b = rms(filtered, samples(100), samples(500));
    CHECK(b < a * 0.05, "lowpass at 500 Hz removes a 4 kHz square almost entirely");
    Rig r3(8, 0);
    Command hp = expressive(r3, 4000, 600, 2, 20, 1);
    hp.filterType = SYNTH_FILTER_HIGHPASS; hp.filterHz = 500;
    r3.e().enqueue(hp); r3.settle(); auto hi = r3.render(samples(650));
    CHECK(rms(hi, samples(100), samples(500)) > a * 0.9, "highpass at 500 Hz keeps a 4 kHz square"); }

  // Cutoff sweep: noise brightens as the lowpass opens.
  { Rig r(8, 0);
    Command n = expressive(r, 440, 2000, 2, 20, 4);
    n.filterType = SYNTH_FILTER_LOWPASS; n.filterHz = 200; n.filterHzEnd = 12000; n.filterQ = 1.0;
    r.e().enqueue(n); r.settle(); auto out = r.render(samples(2050));
    const double start = rms(out, samples(50), samples(250)), end = rms(out, samples(1700), samples(1900));
    CHECK(end > start * 3.0, "an opening lowpass sweep gets louder on noise"); }

  // FM: sidebands appear around the carrier; zero depth leaves a single line.
  { const double carrier = 2400.0;
    Rig r(8, 0);
    Command fm = expressive(r, carrier, 1000, 2, 20);
    fm.fmDepth = 1.0; fm.fmRatio = 0.1;
    r.e().enqueue(fm); r.settle(); auto out = r.render(samples(1010));
    const size_t a = kDelay + samples(100), b = a + 24000;
    const double c0 = amplitudeAt(out, a, b, carrier), up = amplitudeAt(out, a, b, carrier + 240.0);
    CHECK(up > 0.3 * c0, "FM puts energy in the first sideband");
    Rig r2(8, 0);
    Command plain = expressive(r2, carrier, 1000, 2, 20);
    r2.e().enqueue(plain); r2.settle(); auto flat = r2.render(samples(1010));
    CHECK(amplitudeAt(flat, a, b, carrier + 240.0) < 0.01, "no sideband without FM");
    CHECK(amplitudeAt(out, a, b, carrier) < amplitudeAt(flat, a, b, carrier), "FM moves energy out of the carrier"); }

  // FM index sweep that decays to nothing ends as a plain sine.
  { Rig r(8, 0);
    Command fm = expressive(r, 2400, 1000, 2, 5);
    fm.fmDepth = 2.0; fm.fmDepthSweep = true; fm.fmDepthEnd = 0.0; fm.fmRatio = 0.1;
    r.e().enqueue(fm); r.settle(); auto out = r.render(samples(1010));
    const size_t early = kDelay + samples(10), late = kDelay + samples(940);
    const double startRatio = amplitudeAt(out, early, early + 2400, 2400.0 + 240.0) / amplitudeAt(out, early, early + 2400, 2400.0);
    const double endRatio = amplitudeAt(out, late, late + 2400, 2400.0 + 240.0) / amplitudeAt(out, late, late + 2400, 2400.0);
    CHECK(startRatio > 1.0, "an index of 2 starts with a first sideband stronger than the carrier");
    CHECK(endRatio < 0.15, "a decaying FM index leaves almost no sideband at the end"); }

  // Voice stealing and stopAll with every expressive feature active must stay finite and bounded.
  { Rig r(2, 1);
    for (int i = 0; i < 6; ++i) {
      Command c = expressive(r, 300.0 + 90 * i, 600, 5, 100);
      c.decay = samples(150); c.sustain = 0.4;
      c.filterType = SYNTH_FILTER_BANDPASS; c.filterHz = 800; c.filterHzEnd = 3000; c.filterQ = 6;
      c.fmDepth = 2.0; c.fmRatio = 2.0;
      r.e().enqueue(c);
    }
    r.settle(); auto out = r.render(samples(300));
    Command stop; stop.type = 2; r.e().enqueue(stop); auto more = r.render(samples(400));
    bool finite = true;
    for (float s : out) finite = finite && std::isfinite(s);
    for (float s : more) finite = finite && std::isfinite(s);
    CHECK(finite, "stolen and stopped expressive voices stay finite");
    CHECK(peak(out) <= 1.0 && peak(more) <= 1.0, "output stays inside full scale"); }
}
#endif
}  // namespace

int main() {
  legacyScenarios();
#ifdef HAS_EXPRESSIVE
  expressiveScenarios();
#endif
  if (failures) {
    std::fprintf(stderr, "engine_render_host: %d failure(s)\n", failures);
    return 1;
  }
  std::printf("engine_render_host: all checks passed\n");
  return 0;
}
