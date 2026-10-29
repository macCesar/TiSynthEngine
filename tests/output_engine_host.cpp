#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
int main() {
 for(int rate:{16000,44100,48000,96000,192000})for(int profile=0;profile<4;profile++) {
  Rig r(32,profile);r.e().renderSampleRate_=rate;assert(r.e().initializeLimiter());
  r.e().limit(.1,-.2,false);
  CHECK(fabs(r.e().outputL_-.1)<1e-12,"final stage must retain zero samples");
  CHECK(fabs(r.e().outputR_+.2)<1e-12,"both channels must be immediate");
  double ceiling=profile==3?.7:.85;
  r.e().limit(10,-5,false);
  CHECK(fabs(r.e().outputL_-ceiling)<1e-12,"impulse must be protected immediately");
  r.e().setVolume(0);int frames=(int)round(rate*.01);
  for(int i=0;i<frames;i++)r.e().limit(.1,.1,false);
  CHECK(r.e().outputL_==0,"master ramp must reach zero exactly in 10ms");
  const double expected[]={1,.44,.44*std::sqrt(2.),.44/std::sqrt(2.)};
  auto command=note(r,440,100,0,0,.1,0);command.type=SYNTH_CMD_HELD_ON;command.voiceId=1;
  assert(!r.e().enqueue(command));r.e().processCommands();
  CHECK(fabs(r.e().voices_[0].eventGain-expected[profile])<1e-12,"selected profile must affect actual voice gain");
  r.e().setVolume(2);
  Command fx;fx.type=8;fx.effects=synth_effects_default_config();fx.effects.inputGain=4;assert(!r.e().enqueue(fx));
  for(int i=1;i<32;i++){command.voiceId=i+1;command.volume=2;assert(!r.e().enqueue(command));}
  int sizes[]={0,1,3,17,256,511,1024};
  r.e().enableStats(true);
  for(int block=0;block<60;block++){auto pcm=r.render(sizes[block%7]);for(float x:pcm)CHECK(std::isfinite(x)&&fabs(x)<=ceiling+1e-6,"routed hot mix stays finite and bounded");}
  CHECK(r.e().stats_.values[ST_MAX_REDUCTION]>0,"hot mix exercises protection");
  assert(r.e().initializeLimiter());CHECK(r.e().output_.gain==1 && r.e().output_.masterGain==1,"stream reset clears reduction and ramp");
 }
 if(failures)return 1;
 puts("Android production output: zero retention, four profiles/ceilings and exact master ramp at five rates PASS");
}
