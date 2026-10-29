#include <cstdlib>
// Host replay through TiSynthEngine's unchanged Android engine, no audio stream.
// Compile with the same flags/includes as engine_render_host.cpp plus
// Define ENGINE_CPP as in engine_render_host.cpp. Set SYNTH_BINAURAL=1 for the spatial path.
#define main engine_regression_main
#include "engine_render_host.cpp"
#undef main

struct Event { int time; Command command; };
int main() {
  const char *mode = std::getenv("SYNTH_BINAURAL");
  const bool binaural = mode && std::strcmp(mode, "1") == 0;
  std::vector<double> budgetPercent;
  double audioCpuMs = 0;
  int nonFinite = 0;
  Rig rig(32, 1);
  std::vector<Event> events;
  double f, fe, vol, nr, nre, lp, pw, lf, ld, sus, fh, fhe, fq, fr, fd, fde, pan, panEnd;
  int time, dur, atk, rel, dec, w, ft;
  int finish = 0;
  while (scanf("%d %lf %lf %d %d %d %d %lf %d %lf %lf %lf %lf %lf %lf %lf %d %lf %lf %lf %lf %lf %lf %lf %lf",
      &time, &f, &fe, &dur, &atk, &rel, &dec, &sus, &w, &vol, &nr, &nre, &lp, &pw, &lf, &ld, &ft, &fh, &fhe, &fq, &fr, &fd, &fde, &pan, &panEnd) == 25) {
    Command c = note(rig, f, dur, atk, rel, vol, w, pan, panEnd, fe, lf, ld, nr, nre, lp, pw);
    c.spatial = binaural; c.spatialX = pan; c.spatialY = 0.8 * std::sin(time / 1000.0);
    c.decay = samples(dec); c.sustain = sus; c.filterType = ft;
    c.filterHz = fh; c.filterHzEnd = fhe; c.filterQ = fq;
    c.fmRatio = fr; c.fmDepth = fd; c.fmDepthEnd = fde; c.fmDepthSweep = fd > 0;
    events.push_back({samples(time), c});
    finish = std::max(finish, samples(time + dur + 20));
  }
  if (events.empty()) { std::fprintf(stderr, "No complete tone events supplied\n"); return 2; }
  std::stable_sort(events.begin(), events.end(), [](const Event &a, const Event &b) { return a.time < b.time; });
  size_t index = 0;
  int replacements = 0, maxActive = 0, clipped = 0;
  double maxPeak = 0, minGain = 1;

  for (int frame = 0; frame < finish; frame++) {
    while (index < events.size() && events[index].time <= frame) {
      int active = 0;
      for (const Voice &v : rig.e().voices_) if (v.active) active++;
      if (active == 32) replacements++;
      maxActive = std::max(maxActive, std::min(32, active + 1));
      // Internal enqueue returns true for overflow; public playTone reverses it.
      if (rig.e().enqueue(events[index++].command)) return 2;
      auto commandStart = std::chrono::steady_clock::now();
        rig.e().processCommands();
        audioCpuMs += std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - commandStart).count();
    }
    int count = std::min(256, finish - frame);
    if (index < events.size()) count = std::min(count, events[index].time - frame);
    if (count <= 0) return 3;
    float block[512];
    auto begin = std::chrono::steady_clock::now();
    rig.e().onAudioReady(nullptr, block, count);
    double elapsed = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - begin).count();
    audioCpuMs += elapsed;
    budgetPercent.push_back(elapsed / (count * 1000.0 / kRate) * 100);
    for (int i = 0; i < count; ++i) {
      double peak = std::max(std::fabs(block[2*i]), std::fabs(block[2*i+1]));
      if (!std::isfinite(block[2*i]) || !std::isfinite(block[2*i+1])) nonFinite++;
      maxPeak = std::max(maxPeak, peak);

      if (peak >= 0.99999) clipped++;
    }
    minGain = std::min(minGain, rig.e().output_.gain);
    frame += count - 1;
  }
  std::sort(budgetPercent.begin(), budgetPercent.end());
  printf("{\"audioCpuMs\":%.6f,\"audioSeconds\":%.6f,\"meanBudgetPercent\":%.6f,\"p95BlockBudgetPercent\":%.6f,\"maximumBlockBudgetPercent\":%.6f,\"nonFiniteFrames\":%d,\"replacements\":%d,\"maxActive\":%d,\"clippedFrames\":%d,\"peak\":%.9f,\"minimumLimiterGain\":%.9f,\"events\":%zu}\n",
    audioCpuMs, finish / kRate, audioCpuMs / (finish / kRate * 1000) * 100,
    budgetPercent[static_cast<size_t>(0.95 * (budgetPercent.size()-1))], budgetPercent.back(),
    nonFinite, replacements, maxActive, clipped, maxPeak, minGain, events.size());
  return nonFinite ? 4 : 0;
}
