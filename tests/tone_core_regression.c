#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdint.h>
#include <string.h>
typedef struct { double volume; } Recipe;
#define SYNTH_TONE_RECIPE_TYPE Recipe
#include "../shared/synth_tone.h"
static SynthToneTransport t;
static void publish(uint32_t id,int interval,int restart,double volume,uint32_t seed) {
 SynthToneConfig *c=synth_tone_begin_write(&t,id,restart);assert(c);
 c->intervalMs=interval;c->recipe.volume=volume;c->seed=seed;
 assert(synth_tone_commit(&t,c,restart));
}
int main(void) {
 synth_tone_init(&t,44100);
 publish(1,1,1,.5,4);synth_tone_begin_block(&t);
 int count=0;uint64_t frame=0;
 for(;frame<441001;frame++) {
  const SynthToneConfig *c=synth_tone_tick(&t,0);
  if(c){assert(frame==(uint64_t)ceil(count*44.1-1e-7));count++;}
  synth_tone_advance_sample(&t);
  if(frame%137==0)synth_tone_begin_block(&t);
 }
 assert(count==10001);
 /* Edits do not advance the pending attack; interval applies after that. */
 synth_tone_init(&t,1000);publish(2,10,1,.5,7);synth_tone_begin_block(&t);
 assert(synth_tone_tick(&t,0));t.slots[0].variationAttack=5;
 for(int i=0;i<3;i++)synth_tone_advance_sample(&t);
 publish(2,20,0,.2,7);publish(2,30,0,.3,7);
 synth_tone_begin_block(&t);assert(!synth_tone_tick(&t,0));
 for(int i=0;i<7;i++)synth_tone_advance_sample(&t);
 const SynthToneConfig *c=synth_tone_tick(&t,0);assert(c&&c->recipe.volume==.3);
 assert(t.slots[0].remaining==30&&t.slots[0].variationAttack==5);
 publish(2,30,0,.3,8);
 for(int i=0;i<30;i++)synth_tone_advance_sample(&t);
 assert(synth_tone_tick(&t,0));assert(t.slots[0].variationAttack==0);
 /* Independent stop before first attack and immediate ID retirement. */
 assert(synth_tone_request_stop(&t,2));assert(!synth_tone_request_stop(&t,2));
 assert(!synth_tone_begin_write(&t,2,0));synth_tone_begin_block(&t);
 assert(!synth_tone_tick(&t,0));
 publish(3,1,1,1,1);assert(synth_tone_request_stop(&t,3));synth_tone_begin_block(&t);assert(!synth_tone_tick(&t,0));
 for(int i=0;i<32;i++)publish(10+i,1,1,1,1);
 assert(!synth_tone_begin_write(&t,100,1));
 synth_tone_stop_all(&t);assert(!synth_tone_begin_write(&t,10,0));synth_tone_begin_block(&t);assert(!t.activeMask);
 printf("tone core: fractional cadence, edits, variation seed, stop and 32 slots passed; transport bytes=%zu\n",sizeof(t));
 return 0;
}
