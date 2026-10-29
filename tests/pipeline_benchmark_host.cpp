// Matched-source callback timing, CPU and native memory. No hardware stream.
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#include <sys/resource.h>
static double cpuNow(){struct timespec t;clock_gettime(CLOCK_THREAD_CPUTIME_ID,&t);return t.tv_sec+t.tv_nsec*1e-9;}
int main(int argc,char **argv) {
 int kind=argc>1?atoi(argv[1]):0;Rig r(32,1);
 if(kind&1){Command fx;fx.type=8;fx.effects=synth_effects_default_config();fx.effects.chorus.enabled=fx.effects.delay.enabled=fx.effects.reverb.enabled=fx.effects.saturation.enabled=1;assert(!r.e().enqueue(fx));}
 for(int i=0;i<32;i++){auto c=note(r,220+i*17,5000,2,30,.005,0);c.type=SYNTH_CMD_HELD_ON;c.voiceId=i+1;c.spatial=kind&2;c.spatialX=.6;c.spatialY=-.4;assert(!r.e().enqueue(c));}
 r.settle();float output[512];for(int i=0;i<500;i++)r.e().onAudioReady(nullptr,output,256);
 std::vector<double> cpu,wall;double cpuTotal=0,wallTotal=0;
 for(int i=0;i<3000;i++){double c=cpuNow();auto w=std::chrono::steady_clock::now();r.e().onAudioReady(nullptr,output,256);double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-w).count(),work=cpuNow()-c;cpu.push_back(work);wall.push_back(elapsed);cpuTotal+=work;wallTotal+=elapsed;}
 std::sort(cpu.begin(),cpu.end());std::sort(wall.begin(),wall.end());
 Rig high(32,1);high.e().renderSampleRate_=192000;assert(high.e().initializeLimiter());
 size_t bytes=sizeof(Engine)+high.e().voices_.capacity()*sizeof(Voice)+high.e().tails_.capacity()*sizeof(Tail)+synth_effects_memory_bytes(&high.e().effects_)-sizeof(SynthEffects);
#ifndef SYNTH_OUTPUT_H
 bytes+=high.e().delayL_.capacity()*sizeof(double)+high.e().delayR_.capacity()*sizeof(double)+high.e().peakValues_.capacity()*sizeof(double)+high.e().peakIndices_.capacity()*sizeof(int64_t);
#endif
 struct rusage usage;getrusage(RUSAGE_SELF,&usage);
 printf("{\"kind\":%d,\"blocks\":3000,\"framesPerBlock\":256,\"cpuSeconds\":%.9g,\"wallSeconds\":%.9g,\"cpuP95\":%.9g,\"wallP95\":%.9g,\"nativeBytes192k\":%zu,\"peakRssBytes\":%ld}\n",kind,cpuTotal,wallTotal,cpu[2849],wall[2849],bytes,usage.ru_maxrss);
}
