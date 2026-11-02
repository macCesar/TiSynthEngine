#define SYNTH_BENCH_MAX_SEQUENCES 4
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#include <ctime>
static double cpuSeconds(){timespec t{};assert(!clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t));return t.tv_sec+t.tv_nsec*1e-9;}
int main(){
 printf("layout voice=%zu step=%zu config=%zu transport=%zu fourTransports=%zu command=%zu\n",sizeof(SynthSequenceVoice),sizeof(SynthSequenceStep),sizeof(SynthSequenceConfig),sizeof(SynthSequenceTransport),4*sizeof(SynthSequenceTransport),sizeof(Command));
 for(int count:{1,8,16,32})for(int enabled:{0,1}) {
  Rig r(32);
  for(int id=1;id<=4;id++) {
   auto *c=synth_transport_begin_write(&r.e().transport_,id,1);assert(c);c->loop=1;c->stepCount=1;c->stepDuration=.01;
   auto &step=c->steps[0];step.noteCount=count/4+(id<=count%4);step.rest=step.noteCount==0;auto &v=step.voice;v.volume=.01;v.release=5;v.filterType=1;v.filterHz=1500;
   v.variation.amount=enabled;v.variation.mask=131;v.variation.low[0]=.005;v.variation.high[0]=.01;v.variation.low[1]=1000;v.variation.high[1]=2000;v.variation.low[7]=-10;v.variation.high[7]=10;
   for(int i=0;i<step.noteCount;i++)step.notes[i]=60+i;
   assert(synth_transport_commit(&r.e().transport_,c,1));
  }
  float out[512];for(int i=0;i<1000;i++)r.e().onAudioReady(nullptr,out,256);double cpu=cpuSeconds();auto start=std::chrono::steady_clock::now();
  for(int i=0;i<1000;i++)r.e().onAudioReady(nullptr,out,256);
  double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count();cpu=cpuSeconds()-cpu;
  printf("targetVoices=%d admittedPerAttack=%d variation=%d fourSequences=1 callbackCpuSeconds=%.6f wallSeconds=%.6f load=%.6f\n",count,count,enabled,cpu,elapsed,cpu/(1000*256/48000.0));
 }
}
