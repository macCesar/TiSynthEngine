#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#include <ctime>
static double cpuSeconds(){timespec t{};assert(!clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t));return t.tv_sec+t.tv_nsec*1e-9;}
int main(){
 printf("tone-layout recipe=%zu transport=%zu engine=%zu\n",sizeof(Command),sizeof(SynthToneTransport),sizeof(Engine));
 for(int count:{0,1,8,32})for(int spatial:{0,1}) {
  Rig r(32);auto command=note(r,440,20,1,4,.005,0);command.spatial=spatial;command.spatialX=.5;
  for(int id=1;id<=count;id++)assert(r.e().publishTone(id,command,10,true));
  float out[512];for(int i=0;i<100;i++)r.e().onAudioReady(nullptr,out,256);double cpu=cpuSeconds();
  for(int i=0;i<500;i++)r.e().onAudioReady(nullptr,out,256);
  cpu=cpuSeconds()-cpu;
  printf("repetitions=%d spatial=%d callbackCpuSeconds=%.6f load=%.6f\n",count,spatial,cpu,cpu/(500*256/48000.0));
 }
}
