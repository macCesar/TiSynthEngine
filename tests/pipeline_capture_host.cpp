// Matched-source PCM and timing probe. Never opens a hardware stream.
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#include <sys/resource.h>
int main(int argc,char **argv) {
 assert(argc==2);
 for(int rate:{16000,44100,48000,96000,192000})for(int kind=0;kind<8;kind++) {
  Rig r(32,1);r.e().renderSampleRate_=rate;assert(r.e().initializeLimiter());r.e().enableStats(true);
  if(kind&1){Command fx;fx.type=8;fx.effects=synth_effects_default_config();fx.effects.chorus.enabled=fx.effects.delay.enabled=fx.effects.reverb.enabled=1;assert(!r.e().enqueue(fx));}
  for(int i=0;i<8;i++) {
   Command c=note(r,220+i*31,1000,2,30,kind>=4?2:.005,0);
   c.type=SYNTH_CMD_HELD_ON;c.voiceId=i+1;c.spatial=kind&2;c.spatialX=.6;c.spatialY=-.4;
   c.attack=rate/500;c.release=rate*3/100;assert(!r.e().enqueue(c));
  }
  r.settle();std::vector<float> pcm;
  int sizes[]={1,3,17,256,511};int total=rate/2,off=rate/8,frame=0,block=0;
  while(frame<total) {
   if(frame==off)for(int id=1;id<=8;id++){Command c;c.type=SYNTH_CMD_HELD_OFF;c.voiceId=id;assert(!r.e().enqueue(c));}
   int n=std::min(sizes[block++%5],(frame<off?off:total)-frame);
   auto out=r.render(n);for(float x:out)assert(std::isfinite(x)&&fabs(x)<=.850001);
   pcm.insert(pcm.end(),out.begin(),out.end());frame+=n;
  }
  char path[4096];snprintf(path,sizeof(path),"%s/%d-%d.f32",argv[1],rate,kind);
  FILE *f=fopen(path,"wb");assert(f);assert(fwrite(pcm.data(),sizeof(float),pcm.size(),f)==pcm.size());fclose(f);
  printf("{\"rate\":%d,\"kind\":%d,\"prePeakDb\":%.9g,\"reductionDb\":%.9g}\n",rate,kind,r.e().stats_.values[ST_PRE_LIMITER_PEAK],r.e().stats_.values[ST_MAX_REDUCTION]);
 }
}
