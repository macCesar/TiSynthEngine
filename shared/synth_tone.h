/* Fixed-capacity finite-tone repetition on the sample clock. One serialized
 * control producer, one audio consumer. Define SYNTH_TONE_RECIPE_TYPE to the
 * platform's plain finite-tone command before inclusion. No callback allocation,
 * locks, JS, command-queue dependency, or tempo dependency. */
#ifndef SYNTH_TONE_H
#define SYNTH_TONE_H
#include <stdint.h>
#include <string.h>
#define SYNTH_TONE_MAX_REPETITIONS 32
#ifndef SYNTH_TONE_RECIPE_TYPE
#error Define SYNTH_TONE_RECIPE_TYPE before including synth_tone.h
#endif
typedef struct {
 SYNTH_TONE_RECIPE_TYPE recipe;
 uint32_t intervalMs,seed;
} SynthToneConfig;
typedef struct {
 SynthToneConfig banks[3];
 uint32_t bankState[3]; /* free, producer, pending, consumer */
 int32_t pending;
 uint32_t id,status; /* empty, reserved, accepted, stop requested */
 int latest,active;
 double remaining;
 uint64_t variationAttack;
 uint32_t variationSeed;
} SynthToneSlot;
typedef struct {
 SynthToneSlot slots[SYNTH_TONE_MAX_REPETITIONS];
 uint32_t activeMask;
 double sampleRate;
} SynthToneTransport;
static inline void synth_tone_init(SynthToneTransport *t,double rate) {
 memset(t,0,sizeof(*t));t->sampleRate=rate;
 for(int i=0;i<32;i++){t->slots[i].pending=-1;t->slots[i].latest=-1;t->slots[i].active=-1;}
}
static inline int synth_tone_find(SynthToneTransport *t,uint32_t id) {
 if(!id)return -1;
 for(int i=0;i<32;i++)if(__atomic_load_n(&t->slots[i].id,__ATOMIC_ACQUIRE)==id)return i;
 return -1;
}
static inline SynthToneConfig *synth_tone_begin_write(SynthToneTransport *t,uint32_t id,int restart) {
 if(!id)return 0;
 int index=synth_tone_find(t,id);
 if(restart) {
  if(index>=0)return 0;
  for(int i=0;i<32;i++) {
   uint32_t empty=0;
   if(__atomic_compare_exchange_n(&t->slots[i].status,&empty,1,0,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) {
    index=i;SynthToneSlot *s=&t->slots[i];s->latest=s->active=-1;s->pending=-1;
    s->remaining=0;s->variationAttack=0;s->variationSeed=0;
    __atomic_store_n(&s->id,id,__ATOMIC_RELEASE);break;
   }
  }
 } else if(index<0||__atomic_load_n(&t->slots[index].status,__ATOMIC_ACQUIRE)!=2)return 0;
 if(index<0)return 0;
 SynthToneSlot *s=&t->slots[index];
 for(int b=0;b<3;b++) {
  uint32_t free=0;
  if(__atomic_compare_exchange_n(&s->bankState[b],&free,1,0,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED)) {
   if(s->latest>=0)s->banks[b]=s->banks[s->latest];else memset(&s->banks[b],0,sizeof(s->banks[b]));
   return &s->banks[b];
  }
 }
 if(restart){__atomic_store_n(&s->id,0,__ATOMIC_RELEASE);__atomic_store_n(&s->status,0,__ATOMIC_RELEASE);}
 return 0;
}
static inline int synth_tone_config_slot(SynthToneTransport *t,const SynthToneConfig *c,int *bank) {
 for(int i=0;i<32;i++)for(int b=0;b<3;b++)if(c==&t->slots[i].banks[b]){*bank=b;return i;}
 return -1;
}
static inline void synth_tone_cancel_write(SynthToneTransport *t,SynthToneConfig *c) {
 int b=0,i=synth_tone_config_slot(t,c,&b);if(i<0)return;
 SynthToneSlot *s=&t->slots[i];__atomic_store_n(&s->bankState[b],0,__ATOMIC_RELEASE);
 if(__atomic_load_n(&s->status,__ATOMIC_ACQUIRE)==1){__atomic_store_n(&s->id,0,__ATOMIC_RELEASE);__atomic_store_n(&s->status,0,__ATOMIC_RELEASE);}
}
static inline int synth_tone_commit(SynthToneTransport *t,SynthToneConfig *c,int restart) {
 int b=0,i=synth_tone_config_slot(t,c,&b);if(i<0)return 0;
 SynthToneSlot *s=&t->slots[i];
 if(c->intervalMs<1||c->intervalMs>60000||__atomic_load_n(&s->status,__ATOMIC_ACQUIRE)!=(restart?1u:2u)) {synth_tone_cancel_write(t,c);return 0;}
 s->latest=b;
 __atomic_store_n(&s->bankState[b],2,__ATOMIC_RELEASE);
 int old=__atomic_exchange_n(&s->pending,b,__ATOMIC_ACQ_REL);
 if(old>=0)__atomic_store_n(&s->bankState[old],0,__ATOMIC_RELEASE);
 if(restart)__atomic_store_n(&s->status,2,__ATOMIC_RELEASE);
 return 1;
}
static inline int synth_tone_request_stop(SynthToneTransport *t,uint32_t id) {
 int i=synth_tone_find(t,id);if(i<0)return 0;
 uint32_t accepted=2;
 return __atomic_compare_exchange_n(&t->slots[i].status,&accepted,3,0,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED);
}
static inline void synth_tone_stop_all(SynthToneTransport *t) {
 for(int i=0;i<32;i++) {uint32_t accepted=2;__atomic_compare_exchange_n(&t->slots[i].status,&accepted,3,0,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED);}
}
/* Audio thread only. Stop has a separate publication channel. */
static inline void synth_tone_begin_block(SynthToneTransport *t) {
 t->activeMask=0;
 for(int i=0;i<32;i++) {
  SynthToneSlot *s=&t->slots[i];uint32_t status=__atomic_load_n(&s->status,__ATOMIC_ACQUIRE);
  if(status==3) {
   __atomic_store_n(&s->pending,-1,__ATOMIC_RELEASE);
   for(int b=0;b<3;b++)__atomic_store_n(&s->bankState[b],0,__ATOMIC_RELEASE);
   __atomic_store_n(&s->id,0,__ATOMIC_RELEASE);__atomic_store_n(&s->status,0,__ATOMIC_RELEASE);
  }else if(status==2)t->activeMask|=1u<<i;
 }
}
static inline int synth_tone_due(const SynthToneTransport *t,int i) {
 return (t->activeMask&(1u<<i))&&t->slots[i].remaining<=1e-7;
}
/* Apply a complete revision only at its next scheduled attack. The fractional
 * remainder survives each interval, so ceil-to-sample error cannot accumulate. */
static inline const SynthToneConfig *synth_tone_tick(SynthToneTransport *t,int i) {
 if(!synth_tone_due(t,i))return 0;
 SynthToneSlot *s=&t->slots[i];int next=__atomic_exchange_n(&s->pending,-1,__ATOMIC_ACQ_REL);
 if(next>=0) {
  int old=s->active;s->active=next;
  __atomic_store_n(&s->bankState[next],3,__ATOMIC_RELEASE);
  if(old>=0)__atomic_store_n(&s->bankState[old],0,__ATOMIC_RELEASE);
  if(old<0||s->variationSeed!=s->banks[next].seed){s->variationAttack=0;s->variationSeed=s->banks[next].seed;}
 }
 if(s->active<0)return 0;
 const SynthToneConfig *c=&s->banks[s->active];
 s->remaining+=t->sampleRate*((double)c->intervalMs/1000.0);
 return c;
}
static inline void synth_tone_advance_sample(SynthToneTransport *t) {
 if(t->activeMask)for(int i=0;i<32;i++)if(t->activeMask&(1u<<i))t->slots[i].remaining-=1;
}
#endif
