#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
int main() {
#ifdef SYNTH_VARIATION_H
 Rig r(8);auto c=note(r,440,200,5,20,.3,0);
 c.variation.amount=1;c.variation.seeded=1;c.variation.seed=0;c.variation.mask=1|128;
 c.variation.low[0]=.1;c.variation.high[0]=.2;c.variation.low[7]=-100;c.variation.high[7]=100;
 assert(!r.e().enqueue(c));r.e().processCommands();
 Voice *v=nullptr;for(auto &x:r.e().voices_)if(x.active)v=&x;assert(v);
 double frequency=440*pow(2,synth_variation_value(&c.variation,7,0,0,0,0)/1200);
 assert(v->increment==frequency/48000);
 assert(v->volume==synth_variation_value(&c.variation,0,.3,0,0,0)*eventGain(1,0,1));
 auto freq=v->increment;assert(!r.e().enqueue(c));r.e().processCommands();
 for(auto &x:r.e().voices_)if(x.active)assert(x.increment==freq);
 // The legacy render and amount-zero path agree exactly, including noise.
 for(int wave=0;wave<5;wave++)for(int profile=0;profile<4;profile++) {
  Rig a(8,profile),b(8,profile);auto x=note(a,440,200,5,20,.1,wave),y=x;
  y.variation=c.variation;y.variation.amount=0;
  assert(!a.e().enqueue(x));assert(!b.e().enqueue(y));a.settle();b.settle();
  assert(a.render(12000)==b.render(12000));
 }
 // Large seeded chords retain atomic admission and independent native ordinals.
 for(int count:{8,32}) {
  Rig chord(count);std::vector<Command> commands((size_t)count,c);
  // Match JNI preparation: compensation uses the original admitted chord size.
  for(auto &command:commands)command.eventVoiceCount=count;
  assert(!chord.e().enqueueChord(commands));chord.e().processCommands();
  for(int ordinal=0;ordinal<count;ordinal++) {
   const auto &voice=chord.e().voices_[ordinal];assert(voice.active);
   double selected=synth_variation_value(&c.variation,0,c.volume,0,0,(uint32_t)ordinal);
   assert(voice.volume==selected*eventGain(1,0,count));
  }
 }
 {Rig full(1);auto protectedNote=c;protectedNote.variation={};protectedNote.priority=3;
  assert(!full.e().enqueue(protectedNote));full.e().processCommands();
  auto automatic=c;automatic.variation.seeded=0;
  assert(!full.e().enqueueChord(std::vector<Command>(2,automatic)));full.e().processCommands();
  assert(full.e().variationAttack_==0&&full.e().priorityDropCount()==1&&full.e().voices_[0].priority==3);
 }
 // Zero amount preserves held/chord/sequence output, every waveform/profile.
 for(int wave=0;wave<6;wave++)for(int profile=0;profile<4;profile++)for(int path=0;path<3;path++) {
  Rig a(8,profile),b(8,profile);auto x=note(a,440,200,5,20,.03,wave),y=x;
  x.wavetableSize=y.wavetableSize=4;x.wavetable=y.wavetable={-1,-.2,.7,1};
  y.variation=c.variation;y.variation.amount=0;
  if(path==0){x.type=y.type=SYNTH_CMD_HELD_ON;x.voiceId=y.voiceId=1;assert(!a.e().enqueue(x));assert(!b.e().enqueue(y));}
  else if(path==1){assert(!a.e().enqueueChord(std::vector<Command>(8,x)));assert(!b.e().enqueueChord(std::vector<Command>(8,y)));}
  else {
   for(int side=0;side<2;side++) {
    Rig &r=side?b:a;auto *config=synth_transport_begin_write(&r.e().transport_,1,1);assert(config);
    config->stepCount=1;config->steps[0].noteCount=2;config->steps[0].notes[0]=60;config->steps[0].notes[1]=64;
    auto &shape=config->steps[0].voice;shape.waveType=wave;shape.volume=.03;shape.release=20;shape.wavetableSize=4;
    shape.wavetable[0]=-1;shape.wavetable[1]=-.2;shape.wavetable[2]=.7;shape.wavetable[3]=1;
    if(side)shape.variation=y.variation;
    assert(synth_transport_commit(&r.e().transport_,config,1));r.render(1);
   }
  }
  // Identical controlled noise initialization, after native attack admission.
  a.settle();b.settle();assert(a.render(512)==b.render(512));
  for(auto &v:a.e().voices_)if(v.active&&v.held.voiceId)synth_held_release(&v.held,v.envelope);
  for(auto &v:b.e().voices_)if(v.active&&v.held.voiceId)synth_held_release(&v.held,v.envelope);
  assert(a.render(1200)==b.render(1200));
 }
 // Each admitted sequence event advances once, including chords; rests do not.
 Rig seq(8);auto *bank=synth_transport_begin_write(&seq.e().transport_,1,1);assert(bank);
 bank->stepCount=2;bank->loop=1;bank->stepDuration=.01;bank->steps[0].noteCount=2;
 bank->steps[0].notes[0]=60;bank->steps[0].notes[1]=64;bank->steps[1].rest=1;
 bank->steps[0].voice.variation=c.variation;bank->steps[0].voice.frequencyEnd=880;
 assert(synth_transport_commit(&seq.e().transport_,bank,1));seq.render(1);
 auto &slot=seq.e().transport_.slots[0];assert(slot.variationAttack==1);
 double volumes[2];int n=0;for(auto &x:seq.e().voices_)if(x.active){volumes[n++]=x.live.value[LIVE_VOLUME];assert(x.sequenceShape.frequencyEnd!=880);}
 assert(n==2&&volumes[0]!=volumes[1]);seq.render(240);assert(slot.variationAttack==1);
 seq.render(240);assert(slot.variationAttack==2);
 bank=synth_transport_begin_write(&seq.e().transport_,1,0);assert(bank);bank->swing=.1;
 assert(synth_transport_commit(&seq.e().transport_,bank,0));seq.render(480);assert(slot.variationAttack==3);
 bank=synth_transport_begin_write(&seq.e().transport_,1,0);assert(bank);bank->variationRootSeeded=1;bank->variationRootSeed=42;bank->steps[0].voice.variation.seed=42;
 assert(synth_transport_commit(&seq.e().transport_,bank,0));seq.render(480);assert(slot.variationAttack==1);
 // No random event is consumed when a higher-priority pool rejects the chord.
 Rig rejected(1);auto protectedNote=note(rejected,440,1000,5,20,.1,0);protectedNote.priority=3;
 assert(!rejected.e().enqueue(protectedNote));rejected.render(1);
 bank=synth_transport_begin_write(&rejected.e().transport_,1,1);bank->stepCount=1;bank->loop=1;bank->steps[0].noteCount=1;bank->steps[0].notes[0]=60;bank->steps[0].voice.variation=c.variation;
 assert(synth_transport_commit(&rejected.e().transport_,bank,1));rejected.render(1);
 assert(rejected.e().transport_.slots[0].variationAttack==0);
 assert(rejected.e().priorityDropCount()==1);
 puts("variation renderer PASS");
#else
 fprintf(stderr,"FAIL: renderer has no attack variation\n");return 1;
#endif
}
