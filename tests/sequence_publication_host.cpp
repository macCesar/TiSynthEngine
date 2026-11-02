// Real Android JNI publication and C++ producer on a host. Only the JVM array
// accessors are supplied here; Java validation/VM allocation time is excluded.
#define main original_render_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#include <ctime>
#include <sys/resource.h>
static std::vector<double> packet;
static jsize JNICALL arrayLength(JNIEnv *,jarray) {return (jsize)packet.size();}
static void JNICALL readArray(JNIEnv *,jdoubleArray,jsize start,jsize count,jdouble *dest) {
 assert(start>=0&&count>=0&&(size_t)(start+count)<=packet.size());std::copy(packet.begin()+start,packet.begin()+start+count,dest);
}
static double seconds(clockid_t clock){timespec t{};assert(!clock_gettime(clock,&t));return t.tv_sec+t.tv_nsec*1e-9;}
static uint64_t hashBytes(uint64_t h,const void *data,size_t size){auto p=(const unsigned char *)data;while(size--){h^=*p++;h*=1099511628211ULL;}return h;}
int main(int argc,char **argv) {
 int steps=argc>1?atoi(argv[1]):1,loops=argc>2?atoi(argv[2]):100;assert(steps>=1&&steps<=512&&loops>0);
 packet.assign(11+204*steps,0);packet[0]=steps;packet[1]=120;packet[3]=1;packet[4]=1;packet[5]=440;packet[8]=.25;
 for(int i=0;i<steps;i++) {
  auto p=packet.data()+11+i*204;p[0]=32;p[2]=.8;
  for(int n=0;n<32;n++)p[3+n]=36+(i+n)%60;
  p[35]=.03;p[42]=.5;p[43]=1000;p[44]=.7071;p[45]=1;p[49]=1;p[50]=1;p[51]=1;p[53]=10;p[168]=1;p[169]=-1;
 }
 JNINativeInterface_ table{};table.GetArrayLength=arrayLength;table.GetDoubleArrayRegion=readArray;JNIEnv env{&table};
 auto engine=std::make_shared<Engine>(32,1,4);auto handle=reinterpret_cast<jlong>(&engine);auto input=reinterpret_cast<jdoubleArray>(packet.data());
 assert(Java_ti_synthengine_SynthThread_nativePublishSequence(&env,nullptr,handle,1,input,true));synth_transport_begin_block(&engine->transport_);
 std::vector<double> cpu,wall;double ct=0,wt=0;cpu.reserve(loops);wall.reserve(loops);
 for(int n=0;n<loops+10;n++) {
  double c=seconds(CLOCK_THREAD_CPUTIME_ID),w=seconds(CLOCK_MONOTONIC);
  assert(Java_ti_synthengine_SynthThread_nativePublishSequence(&env,nullptr,handle,1,input,false));
  double elapsed=seconds(CLOCK_MONOTONIC)-w,work=seconds(CLOCK_THREAD_CPUTIME_ID)-c;
  if(n>=10){cpu.push_back(work);wall.push_back(elapsed);ct+=work;wt+=elapsed;}
  synth_transport_begin_block(&engine->transport_);auto &slot=engine->transport_.slots[0];slot.beat=slot.nextBeat;
  SynthSequenceEvent event;synth_transport_tick(&engine->transport_,0,&event);
 }
 auto &slot=engine->transport_.slots[0];auto &active=slot.banks[slot.active];uint64_t h=hashBytes(1469598103934665603ULL,active.steps,steps*sizeof(SynthSequenceStep));
 h=hashBytes(h,&active.stepCount,sizeof(active)-offsetof(SynthSequenceConfig,stepCount));
 std::sort(cpu.begin(),cpu.end());std::sort(wall.begin(),wall.end());rusage usage{};getrusage(RUSAGE_SELF,&usage);
 printf("{\"steps\":%d,\"loops\":%d,\"cpuSeconds\":%.9g,\"wallSeconds\":%.9g,\"cpuP95\":%.9g,\"wallP95\":%.9g,\"cpuMax\":%.9g,\"wallMax\":%.9g,\"peakRssBytes\":%ld,\"state\":\"%016llx\"}\n",steps,loops,ct,wt,cpu[(loops*95-1)/100],wall[(loops*95-1)/100],cpu.back(),wall.back(),usage.ru_maxrss,(unsigned long long)h);
}
