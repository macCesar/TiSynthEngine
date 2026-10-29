// Native callback diagnostic for Studio startup processing and source levels.
// macOS host build: set TASK_OBOE_INCLUDE to the cached Oboe include directory
// and TASK_JDK to a JDK root (the same dependencies as engine_render_host.cpp).
// clang++ -std=c++17 -O2 -Wall -I"$TASK_OBOE_INCLUDE" \
//   -I"$TASK_JDK/include" -I"$TASK_JDK/include/darwin" -DHAS_EXPRESSIVE \
//   -DENGINE_CPP='"../android/jni/SynthOboeEngine.cpp"' \
//   -Wl,-undefined,dynamic_lookup tests/startup_processing_host.cpp \
//   -o /tmp/startup_processing_host
// /tmp/startup_processing_host > /tmp/startup_processing_report.jsonl
// Levels/spectra use the steady held interval from one to two seconds. The
// fundamental-fit residual includes aliases and nonharmonic content; it is not
// strictly THD. Diagnostic dB fields use synth_stats_db's -120dB floor: retain
// residualRatio when investigating content below that floor. Wavetable spectral
// values are observations, never assertions that preserve staircase artifacts.
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>

static SynthEffectsConfig studioDisabledProcessing() {
  auto c=synth_effects_default_config();c.inputGain=1;
  c.chorus.depth=.3;c.delay.timeMs=300;c.delay.mix=.2;
  c.reverb.decay=1.8;c.saturation.mix=0;return c;
}
static void publishDisabled(Rig &r) {
  Command c;c.type=8;c.effects=studioDisabledProcessing();assert(!r.e().enqueue(c));
}
static void setRate(Rig &r,int rate,double master) {
  r.e().renderSampleRate_=rate;r.e().reportedSampleRate_.store(rate);
  assert(r.e().initializeLimiter());r.e().setVolume(master);
}
static Command studioNote(Rig &r,int wave,double frequency,double volume) {
  auto c=note(r,frequency,100,8,300,volume,wave);
  c.type=SYNTH_CMD_HELD_ON;c.voiceId=1;c.decay=(int)(r.e().renderSampleRate_*.180);c.sustain=.7;
  // Exact saved-state timing; note() otherwise scales milliseconds at 48kHz.
  c.attack=(int)(r.e().renderSampleRate_*.008);c.release=(int)(r.e().renderSampleRate_*.300);
  c.lfoFreq=.5625;c.lfoDepth=0;c.bitDepth=0;c.wavetableSize=32;
  for(int i=0;i<32;i++)c.wavetable[i]=std::sin(2*kPi*i/32.);
  return c;
}
static void startupBypass(int rate,int wave) {
  Rig plain(32,1),published(32,1);setRate(plain,rate,1.2);setRate(published,rate,1.2);
  publishDisabled(published);
  auto compare=[&](int frames,bool silent) {
    auto a=plain.render(frames),b=published.render(frames);assert(a==b);
    for(float sample:a){assert(std::isfinite(sample));if(silent)assert(sample==0);}
  };
  compare(rate/10,true);assert(!plain.e().effectsActive_&&published.e().effectsActive_);
  auto c=studioNote(plain,wave,261.6255653005986,.287334982191);
  assert(!plain.e().enqueue(c));assert(!published.e().enqueue(c));compare(rate/2,false);
  // Re-publishing disabled processing during a held note must remain exact.
  publishDisabled(published);compare(rate/2,false);
  Command off;off.type=SYNTH_CMD_HELD_OFF;off.voiceId=1;
  assert(!plain.e().enqueue(off));assert(!published.e().enqueue(off));compare(rate/2,false);
  compare(rate/10,true);assert(plain.e().output_.gain==1&&published.e().output_.gain==1);
}
struct Spectrum {double rms,peak,dc,fundamentalRms,residualRatio,maxStep,image31Ratio,image33Ratio;};
static double folded(double hz) {hz=std::fmod(hz,kRate);return hz>kRate*.5?kRate-hz:hz;}
static Spectrum spectrum(const std::vector<float> &s,double hz) {
  size_t a=48000,b=96000;double ss=0,cc=0,sc=0,ys=0,yc=0,mean=0,sm=0,cm=0;
  Spectrum out{};
  for(size_t i=a;i<b;i++) {
    double y=s[i*2],phase=2*kPi*hz*i/kRate,si=sin(phase),co=cos(phase);
    mean+=y;sm+=si;cm+=co;ss+=si*si;cc+=co*co;sc+=si*co;ys+=y*si;yc+=y*co;
    out.rms+=y*y;out.peak=std::max(out.peak,fabs(y));if(i>a)out.maxStep=std::max(out.maxStep,fabs(y-s[(i-1)*2]));
  }
  double n=b-a;mean/=n;sm/=n;cm/=n;
  ss-=n*sm*sm;cc-=n*cm*cm;sc-=n*sm*cm;ys-=n*mean*sm;yc-=n*mean*cm;
  double determinant=ss*cc-sc*sc,sine=(ys*cc-yc*sc)/determinant,cosine=(yc*ss-ys*sc)/determinant;
  out.dc=mean;out.rms=sqrt(out.rms/n);double residual=0,fundamental=0;
  for(size_t i=a;i<b;i++) {
    double phase=2*kPi*hz*i/kRate,fit=sine*(sin(phase)-sm)+cosine*(cos(phase)-cm),error=s[i*2]-mean-fit;
    residual+=error*error;fundamental+=fit*fit;
  }
  out.fundamentalRms=sqrt(fundamental/n);out.residualRatio=sqrt(residual/fundamental);
  double base=amplitudeAt(s,a,b,hz);
  out.image31Ratio=amplitudeAt(s,a,b,folded(hz*31))/base;
  out.image33Ratio=amplitudeAt(s,a,b,folded(hz*33))/base;return out;
}
static Spectrum sourceLevel(int wave,int midi,double master,double volume) {
  Rig r(32,1);setRate(r,48000,master);publishDisabled(r);r.render(4800);
  double hz=440*std::exp2((midi-69)/12.);auto c=studioNote(r,wave,hz,volume);assert(!r.e().enqueue(c));
  auto samples=r.render(105600);auto v=spectrum(samples,hz);
  assert(std::isfinite(v.rms)&&std::isfinite(v.residualRatio)&&r.e().output_.gain==1);
  if(wave==0)assert(v.residualRatio<1e-6);
  printf("{\"wave\":%d,\"midi\":%d,\"master\":%.6g,\"voiceVolume\":%.12g,\"peakDb\":%.9g,\"rmsDb\":%.9g,\"dc\":%.9g,\"fundamentalRms\":%.9g,\"residualRatio\":%.9g,\"residualDb\":%.9g,\"maxStep\":%.9g,\"image31Db\":%.9g,\"image33Db\":%.9g}\n",wave,midi,master,volume,synth_stats_db(v.peak),synth_stats_db(v.rms),v.dc,v.fundamentalRms,v.residualRatio,synth_stats_db(v.residualRatio),v.maxStep,synth_stats_db(v.image31Ratio),synth_stats_db(v.image33Ratio));
  return v;
}
int main() {
  for(int rate:{16000,44100,48000,96000,192000})for(int wave:{0,1,2,3,5})startupBypass(rate,wave);
  puts("startup published-disabled processing: exact callback output through held note/release, finite output and exact idle silence at five rates PASS");
  // Saved iPad state: volume1, presetGain below, master.6. New UI mapping is1.2.
  for(int midi:{48,60,72,84}) {
    auto sine=sourceLevel(0,midi,1.2,.287334982191);
    for(int wave:{1,2,3,5}) {
      auto other=sourceLevel(wave,midi,1.2,.287334982191);
      // Anti-aliasing slightly lowers square/saw power in higher registers.
      // Wavetable spectral measurements are diagnostic, not golden assertions.
      if(wave<4)assert(fabs(20*log10(other.rms/sine.rms))<.35);
    }
  }
  auto integerCycles=sourceLevel(0,69,1.2,.287334982191);
  assert(fabs(integerCycles.dc)<1e-8); // 440 complete cycles: no window-end bias.
  sourceLevel(5,69,1.2,.287334982191);
  // Clean factory preset vs legacy factory volume, before/after master correction.
  sourceLevel(0,60,.6,.35*.287334982191);sourceLevel(0,60,1.2,.35*.287334982191);
  sourceLevel(0,60,2,.35*.287334982191);sourceLevel(0,60,.6,.35);
}
