#include <atomic>
#include <cassert>
#include <cstdio>
#include <thread>
#include <cstdint>
#include <cstring>
struct Recipe {uint64_t revision,proof[64];};
#define SYNTH_TONE_RECIPE_TYPE Recipe
#include "../shared/synth_tone.h"
static SynthToneTransport t;
int main() {
 synth_tone_init(&t,44100);std::atomic<bool> done{false};std::atomic<uint64_t> attacks{0};
 std::thread audio([&]{
  while(!done.load(std::memory_order_acquire)) {
   synth_tone_begin_block(&t);
   for(int f=0;f<64;f++) {
    for(int i=0;i<32;i++)if(const auto *c=synth_tone_tick(&t,i)) {
     for(uint64_t proof:c->recipe.proof)assert(proof==c->recipe.revision);
     assert(c->intervalMs==1||c->intervalMs==2);attacks.fetch_add(1,std::memory_order_relaxed);
    }
    synth_tone_advance_sample(&t);
   }
  }
 });
 uint64_t revision=0;
 for(uint32_t id=1;id<=2000;id++) {
  SynthToneConfig *c;
  while(!(c=synth_tone_begin_write(&t,id,1)))std::this_thread::yield();
  c->intervalMs=1;c->seed=id;c->recipe.revision=++revision;
  for(uint64_t &proof:c->recipe.proof)proof=revision;
  assert(synth_tone_commit(&t,c,1));
  for(int edit=0;edit<20;edit++) {
   while(!(c=synth_tone_begin_write(&t,id,0)))std::this_thread::yield();
   c->intervalMs=1+(edit&1);c->recipe.revision=++revision;
   for(uint64_t &proof:c->recipe.proof)proof=revision;
   assert(synth_tone_commit(&t,c,0));
  }
  assert(synth_tone_request_stop(&t,id));assert(!synth_tone_begin_write(&t,id,0));
 }
 done.store(true,std::memory_order_release);audio.join();
 printf("tone concurrency: 2000 starts/stops, 40000 revisions passed; admitted attacks=%llu\n",(unsigned long long)attacks.load());
}
