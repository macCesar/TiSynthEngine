#define SYNTH_BENCH_MAX_SEQUENCES 4
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
int main() {
 Rig r(32);auto c=note(r,440,120,5,20,.1,0);
 assert(r.e().publishTone(1,c,10,true));r.render(1);
 assert(r.e().tones_.slots[0].remaining==479);
 uint64_t firstOrder=r.e().voiceOrder_;assert(firstOrder==1);
 r.render(479);assert(r.e().voiceOrder_==firstOrder);
 auto updated=c;updated.volume=.2;
 assert(r.e().publishTone(1,updated,20,false));
 r.render(1);assert(r.e().voiceOrder_==firstOrder+1);
 assert(r.e().tones_.slots[0].remaining==959);
 assert(r.e().stopTone(1));assert(!r.e().stopTone(1));
 assert(!r.e().publishTone(1,c,10,false));r.render(2000);
 assert(r.e().voiceOrder_==firstOrder+1);
 // A full ordinary queue cannot lose stop-before-start.
 Rig q(32);assert(q.e().publishTone(2,c,1,true));
 for(int i=0;i<127;i++)assert(!q.e().enqueue(c));
 assert(q.e().enqueue(c));assert(q.e().stopTone(2));q.render(1);
 assert(q.e().voiceOrder_==127);
 // Finite tone initialization is exactly shared, including envelopes/sweeps.
 for(int wave=0;wave<6;wave++)for(int profile=0;profile<4;profile++) {
  Rig a(8,profile),b(8,profile);auto x=note(a,440,100,5,20,.1,wave);
  x.wavetableSize=4;x.wavetable={-1,-.3,.8,1};x.frequencyEnd=220;
  assert(!a.e().enqueue(x));assert(b.e().publishTone(3,x,1000,true));
  a.render(1);b.render(1);assert(b.e().stopTone(3));a.settle();b.settle();assert(a.render(6000)==b.render(6000));
 }
 // Spatial tiling never starts a future attack ahead of its exact frame.
 {Rig spatial(32);auto x=note(spatial,440,100,5,20,.1,0);x.spatial=true;x.spatialX=.5;
  assert(spatial.e().publishTone(20,x,1,true));spatial.render(1);uint64_t order=spatial.e().voiceOrder_;
  spatial.render(47);assert(spatial.e().voiceOrder_==order);
  spatial.render(1);assert(spatial.e().voiceOrder_==order+1);
  spatial.render(1000);assert(spatial.e().voiceOrder_==22);
 }
 // Standalone calls remain independent finite attacks at ordinary JS cadence.
 {Rig standalone(32);for(int n=0;n<3;n++){assert(!standalone.e().enqueue(c));standalone.render(9600);}
  assert(standalone.e().voiceOrder_==3&&standalone.e().tones_.activeMask==0);
 }
 // Tone capacity is independent of the four simultaneous sequence slots.
 {Rig capacity(32);for(int id=1;id<=32;id++)assert(capacity.e().publishTone(id,c,100,true));
  assert(!capacity.e().publishTone(33,c,100,true));
  for(int id=1;id<=4;id++) {auto *score=synth_transport_begin_write(&capacity.e().transport_,id,1);assert(score);
   score->stepCount=1;score->steps[0].rest=1;score->loop=1;assert(synth_transport_commit(&capacity.e().transport_,score,1));}
  capacity.render(1);assert(capacity.e().voiceOrder_==32);
 }
 // Tempo edits cannot affect the millisecond cadence, including 44.1kHz fractions.
 {Rig clock(32);clock.e().renderSampleRate_=44100;clock.e().reportedSampleRate_.store(44100);clock.e().tones_.sampleRate=44100;clock.e().initializeLimiter();
  auto x=note(clock,440,2,0,0,.01,0);assert(clock.e().publishTone(1,x,1,true));
  clock.e().setTempo(20);clock.render(22050);assert(clock.e().voiceOrder_==500);
  clock.e().setTempo(300);clock.render(22051);assert(clock.e().voiceOrder_==1001);
 }
 // Revisions preserve stream position; explicit seed changes restart it.
 {Rig stream(32);auto x=c;x.variation.amount=1;x.variation.mask=1;x.variation.seeded=1;x.variation.seed=11;
  x.variation.low[0]=.05;x.variation.high[0]=.2;assert(stream.e().publishTone(1,x,2,true));stream.render(1);
  assert(stream.e().voices_[0].volume==synth_variation_value(&x.variation,0,x.volume,11,0,0)*eventGain(1,0,1));
  x.volume=.15;assert(stream.e().publishTone(1,x,2,false));stream.render(95);assert(stream.e().voiceOrder_==1);
  stream.render(1);assert(stream.e().tones_.slots[0].variationAttack==2);
  assert(stream.e().voices_[1].volume==synth_variation_value(&x.variation,0,x.volume,11,1,0)*eventGain(1,0,1));
  x.variation.seed=12;assert(stream.e().publishTone(1,x,2,false));stream.render(96);
  assert(stream.e().tones_.slots[0].variationAttack==1);
  assert(stream.e().voices_[2].volume==synth_variation_value(&x.variation,0,x.volume,12,0,0)*eventGain(1,0,1));
 }
 // Seeded streams advance independently; rejected priority admissions consume none.
 Rig v(1);auto protectedNote=c;protectedNote.priority=3;assert(!v.e().enqueue(protectedNote));v.render(1);
 c.variation.amount=1;c.variation.mask=1;c.variation.seeded=1;c.variation.seed=8;c.variation.low[0]=.05;c.variation.high[0]=.2;
 assert(v.e().publishTone(4,c,1,true));v.render(1);assert(v.e().tones_.slots[0].variationAttack==0);
 v.render(6000);assert(v.e().tones_.slots[0].variationAttack>0);
 v.e().stopAll();assert(!v.e().publishTone(4,c,1,false));v.render(1000);assert(v.e().tones_.activeMask==0);
 // Global stop retires only ownership accepted before it; a later start survives.
 for(int full:{0,1}) {Rig global(32);assert(global.e().publishTone(1,c,10,true));
  if(full)for(int i=0;i<127;i++)assert(!global.e().enqueue(c));
  assert(global.e().stopAll()==(full!=0));
  assert(!global.e().publishTone(1,c,10,false));assert(global.e().publishTone(2,c,10,true));global.render(1);
  assert(global.e().voiceOrder_==(uint64_t)(1+127*full)&&synth_tone_find(&global.e().tones_,2)>=0);
 }
 printf("tone renderer passed; recipe bytes=%zu transport bytes=%zu\n",sizeof(Command),sizeof(SynthToneTransport));
}
