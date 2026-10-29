// Same Oboe/JNI host build flags as engine_render_host.cpp.
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
static Command held(Rig &r,int id) { auto c=note(r,440,100,20,80,.3,0); c.type=SYNTH_CMD_HELD_ON; c.voiceId=id; return c; }
static Voice *byId(Rig &r,int id) { for(auto &v:r.e().voices_)if(v.active&&v.held.voiceId==id)return &v; return nullptr; }
static void off(Rig &r,int id) { Command c; c.type=SYNTH_CMD_HELD_OFF; c.voiceId=id; assert(!r.e().enqueue(c)); r.e().processCommands(); }
int main() {
  // Final protection bounds dense sums and resets once releases drain.
  for(double level:{.35,1.})for(int count:{4,16,32}) {
    Rig dense(32,1);
    for(int i=0;i<count;i++) {auto c=held(dense,i+1);c.frequency=220+i*40;c.volume=level;dense.e().enqueue(c);}
    auto output=dense.render(48000);assert(peak(output)<=.850001);
    for(int id=1;id<=count;id++)off(dense,id);
    dense.render(48000);assert(dense.e().output_.gain==1.0);
  }
  double reference=0;
  for(int count:{1,32}) {
    Rig quiet(32,1);
    for(int i=0;i<count;i++){auto c=held(quiet,i+1);c.frequency=220+i*40;c.volume=.05;quiet.e().enqueue(c);}
    auto output=quiet.render(48000);double amplitude=amplitudeAt(output,24000,48000,220);
    if(count==1)reference=amplitude;else assert(std::abs(amplitude-reference)<1e-7);
    assert(quiet.e().output_.gain==1.0);
  }
  // Zero ADSR edges must not hard-gate a nonzero square sample.
  {
    Rig edge(1);auto c=note(edge,440,100,0,0,.35,1);c.type=SYNTH_CMD_HELD_ON;c.voiceId=1;
    edge.e().enqueue(c);auto attack=edge.render(1000);
    assert(std::abs(attack[0])<1e-6);
    for(int frame=1;frame<12;frame++)assert(std::abs(attack[frame*2]-attack[(frame-1)*2])<.002);
    off(edge,1);auto release=edge.render(1000);
    assert(std::abs(release[2]-release[0])<.002);
    assert(!byId(edge,1));
  }
  Rig r(2); assert(!r.e().enqueue(held(r,1))); r.e().processCommands();
  r.render(48000*61); assert(byId(r,1)); assert(byId(r,1)->envelope==1);
  auto *v=byId(r,1); auto phase=v->phase; auto age=v->played;
  Command update; update.type=SYNTH_CMD_HELD_UPDATE; update.voiceId=1;
  update.liveMask=(1u<<LIVE_FREQUENCY)|(1u<<LIVE_VOLUME); update.liveValues[LIVE_FREQUENCY]=880; update.liveValues[LIVE_VOLUME]=0;
  assert(!r.e().enqueue(update)); r.e().processCommands();
  assert(v->phase==phase && v->played==age); r.render(480);
  assert(v->live.value[LIVE_FREQUENCY]==880 && v->volume==0);
  off(r,1); r.render(4000); assert(!byId(r,1));
  for(int frames: {1,200,1500}) {
    auto c=held(r,2); c.decay=3000; c.sustain=.4;
    assert(!r.e().enqueue(c)); r.e().processCommands(); r.render(frames);
    double before=byId(r,2)->envelope; off(r,2);
    assert(byId(r,2)->held.releaseLevel==before);
    double l=0,rr=0; r.e().renderVoice(*byId(r,2),l,rr);
    assert(std::abs(byId(r,2)->envelope-before)<1e-12);
    r.render(4000); assert(!byId(r,2));
  }
  r.e().enqueue(held(r,10)); r.e().processCommands(); r.render(100);
  r.e().enqueue(held(r,11)); r.e().processCommands(); r.render(100); off(r,11);
  r.e().enqueue(held(r,12)); r.e().processCommands(); assert(byId(r,10)&&byId(r,12)&&!byId(r,11));
  off(r,11); assert(!byId(r,12)->held.releasing);
  r.e().enqueue(held(r,13)); r.e().processCommands(); assert(!byId(r,10)&&byId(r,12)&&byId(r,13));
  off(r,10); assert(!byId(r,13)->held.releasing);
  r.e().enqueue(held(r,13)); r.e().processCommands(); assert(byId(r,12)&&byId(r,13));
  assert(byId(r,13)->played==0 && !byId(r,13)->held.releasing);
  assert(r.e().voiceMaskForId(13)>=0);
  auto retrigger=held(r,13);retrigger.attack=0;retrigger.waveType=3;
  r.e().enqueue(retrigger);r.e().processCommands();assert(byId(r,13)->attack>=288);
  assert(!(r.e().voiceMaskForId(13)&(1u<<LIVE_FM_DEPTH)));
  for(int n=0;n<127;n++)assert(!r.e().enqueue(held(r,100+n)));
  Command release;release.type=SYNTH_CMD_HELD_OFF;release.voiceId=13;
  assert(r.e().enqueue(release)); r.e().processCommands();
  assert(!r.e().enqueue(release)); r.e().processCommands();
  Rig chord(32);
  for(int i=1;i<=32;i++) {
    auto c=held(chord,i);c.waveType=(i-1)%6;c.spatial=i%2;c.spatialY=.5;
    c.wavetableSize=4;c.wavetable={-1,0,1,0};
    chord.e().enqueue(c);
  }
  auto sound=chord.render(2000);for(float sample:sound)assert(std::isfinite(sample));
  for(int i=1;i<=32;i++)off(chord,i);
  chord.render(5000);for(int i=1;i<=32;i++)assert(!byId(chord,i));
  puts("held renderer: long sustain, release stages, ramps, stealing, IDs and full queue PASS");
}
