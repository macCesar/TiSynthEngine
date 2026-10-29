// Synthetic callback load. Host timing is evidence, never device acceptance.
#define main original_render_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
#ifdef __APPLE__
#include <pthread/qos.h>
#endif
int main(int argc,char **argv) {
#ifdef __APPLE__
 pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
#endif
 const int seconds=argc>1?atoi(argv[1]):30;
 auto e=std::make_shared<Engine>(32,1,4);e->renderSampleRate_=48000;e->reportedSampleRate_.store(48000);assert(e->initializeLimiter());
 auto fx=synth_effects_default_config();fx.chorus.enabled=fx.delay.enabled=fx.reverb.enabled=fx.saturation.enabled=1;
 fx.saturation.drive=2;Command processing;processing.type=8;processing.effects=fx;assert(!e->enqueue(processing));
 for(uint32_t id=1;id<=4;id++) {
  auto *c=synth_transport_begin_write(&e->transport_,id,1);assert(c);c->loop=1;c->stepCount=1;c->stepDuration=1;
  auto &s=c->steps[0];s.noteCount=8;s.gate=1;s.voice.volume=.01;s.voice.attack=2;s.voice.release=30;
  s.voice.waveType=1;s.voice.filterType=1;s.voice.filterHz=1200;s.voice.spatial=1;s.voice.spatialX=.6;s.voice.spatialY=-.4;
  s.voice.mods[0]=1;s.voice.mods[2]=0;s.voice.mods[3]=2;s.voice.mods[4]=.3;
  s.voice.mods[6]=1;s.voice.mods[8]=1;s.voice.mods[9]=3;s.voice.mods[10]=.3;
  for(int n=0;n<8;n++)s.notes[n]=(uint8_t)(36+id*8+n);
  assert(synth_transport_commit(&e->transport_,c,1));
 }
 float output[512];std::vector<double> work;work.reserve(seconds*48000/256+1);
 int64_t misses=0;int peakVoices=0;
 for(int64_t frame=0;frame<(int64_t)seconds*48000;frame+=256) {
  auto start=std::chrono::steady_clock::now();e->onAudioReady(nullptr,output,256);
  double load=std::chrono::duration<double>(std::chrono::steady_clock::now()-start).count()*48000/256;
  work.push_back(load);if(load>=1)misses++;peakVoices=std::max(peakVoices,(int)e->stats_.active);
  for(float v:output)assert(std::isfinite(v)&&fabs(v)<=.850001);
 }
 std::sort(work.begin(),work.end());assert(peakVoices==32);
 // Include native engine/queue/banks, renderer vectors and live+replacement FX
 // buffers. Recovery destroys previous FX before allocation of the new buffers.
 auto high=std::make_shared<Engine>(32,1,4);high->renderSampleRate_=192000;assert(high->initializeLimiter());
 size_t bytes=sizeof(Engine)+high->voices_.capacity()*sizeof(Voice)+high->tails_.capacity()*sizeof(Tail)+synth_effects_memory_bytes(&high->effects_)-sizeof(SynthEffects);
 assert(bytes<32u*1024u*1024u);
 printf("{\"kind\":\"syntheticAndroidCallback\",\"sampleRate\":48000,\"blockFrames\":256,\"simulatedSeconds\":%d,\"blocks\":%zu,\"voices\":32,\"sequences\":4,\"binaural\":true,\"lfosPerVoice\":2,\"effects\":true,\"loadMedian\":%.9g,\"loadP95\":%.9g,\"loadMax\":%.9g,\"deadlineMisses\":%lld,\"nativeBytes192k\":%zu,\"physicalAcceptance\":false}\n",seconds,work.size(),work[work.size()/2],work[work.size()*95/100],work.back(),(long long)misses,bytes);
}
