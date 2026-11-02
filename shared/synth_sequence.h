/* Sample-clock transport shared by the Android and iOS render callbacks.
 * Publication has one serialized producer; the audio thread never allocates,
 * waits, destroys objects, or calls the public command queue. */
#ifndef SYNTH_SEQUENCE_H
#define SYNTH_SEQUENCE_H
#include <stdint.h>
#include "synth_variation.h"
#include <string.h>
#include <math.h>
#define SYNTH_SEQUENCE_MAX_STEPS 512
#define SYNTH_SEQUENCE_MAX_NOTES 32
#define SYNTH_SEQUENCE_BANKS 3

enum { SYNTH_SEQUENCE_BEATS, SYNTH_SEQUENCE_MS };
enum { SYNTH_SEQUENCE_NORMAL, SYNTH_SEQUENCE_UP, SYNTH_SEQUENCE_DOWN, SYNTH_SEQUENCE_UPDOWN };
typedef struct {
 SynthVariation variation;
 double volume,pan,frequencyEnd,lfoFreq,lfoDepth,noiseRate,lowPassHz,pulseWidth;
 double filterHz,filterQ,fmRatio,fmDepth,spatialX,spatialY,sustain;
 double wavetable[64],mods[12];
 double noiseRateEnd,panEnd,pulseWidthEnd,filterHzEnd,fmDepthEnd,effectSend;
 int fmDepthSweep,bus,priority;
 int waveType,attack,decay,release,filterType,bitDepth,spatial,wavetableSize;
} SynthSequenceVoice;
typedef struct {
 uint8_t notes[SYNTH_SEQUENCE_MAX_NOTES];
 int noteCount,rest;
 double gate,duration,length;
 double frequencies[SYNTH_SEQUENCE_MAX_NOTES],preparedFrequencies[SYNTH_SEQUENCE_MAX_NOTES];
 SynthSequenceVoice voice;
} SynthSequenceStep;
typedef struct {
 SynthSequenceStep steps[SYNTH_SEQUENCE_MAX_STEPS];
 int stepCount,mode,loop;
 double bpm,swing,tuning,detune,stepDuration;
 int timeUnit;
 uint32_t revision;
 uint32_t variationRootSeed,variationSeeds[SYNTH_SEQUENCE_MAX_STEPS];
 int variationRootSeeded,variationSeedCount;
 /* Prepared by the producer, never sorted in the callback. */
 int order[SYNTH_SEQUENCE_MAX_STEPS],orderCount;
} SynthSequenceConfig;
typedef struct {
 int playing,stepIndex,bank;
 double beat,bpm;
 uint32_t revision;
 uint64_t generation;
} SynthSequenceState;
typedef struct {
 int stepIndex,noteCount,bank;
 uint8_t notes[SYNTH_SEQUENCE_MAX_NOTES];
 double gateEndBeat,length;
 double frequencies[SYNTH_SEQUENCE_MAX_NOTES];
 uint32_t sequenceId;
 uint64_t generation;
} SynthSequenceEvent;
typedef struct {
 SynthSequenceConfig banks[SYNTH_SEQUENCE_BANKS];
 uint32_t bankState[SYNTH_SEQUENCE_BANKS]; /* 0 free, 1 owned */
 uint32_t mailbox,stopRequested,controlSerial,lastRestartSerial;
 int latest,active,pending,pendingRestart;
 uint32_t nextRevision;
 double sampleRate,beat,nextBeat,bpm,swing,beatCompensation,pairShift;
 int playing,cursor,pairIndex,lastStep;
 uint64_t generation,variationAttack;
 /* Atomic scalar snapshot avoids C/C++ data races in state readers. */
 uint32_t snapshotSequence,snapshotPlaying,snapshotStep,snapshotRevision;
 uint64_t snapshotBeat __attribute__((aligned(8))),snapshotBpm,snapshotGeneration;
} SynthSequenceTransport;
static inline void synth_sequence_defaults(SynthSequenceConfig *c) {
 memset(c,0,sizeof(*c));c->bpm=120;c->tuning=440;c->stepDuration=.25;c->loop=0;
 for(int i=0;i<SYNTH_SEQUENCE_MAX_STEPS;i++) {
  c->steps[i].voice.effectSend=-1;c->steps[i].voice.bus=1;
  c->steps[i].gate=.8;c->steps[i].voice.volume=1;c->steps[i].voice.pulseWidth=.5;
  c->steps[i].voice.sustain=1;c->steps[i].voice.filterHz=1000;
  c->steps[i].voice.filterQ=.7071;c->steps[i].voice.fmRatio=1;
 }
}
static inline void synth_sequence_init(SynthSequenceTransport *t,double sampleRate) {
 memset(t,0,sizeof(*t));t->sampleRate=sampleRate;t->latest=t->active=t->pending=-1;
 t->lastStep=-1;t->bpm=120;t->snapshotStep=UINT32_MAX;memcpy(&t->snapshotBpm,&t->bpm,8);
}
static inline int synth_sequence_bank_index(const SynthSequenceTransport *t,const SynthSequenceConfig *c) {
 for(int i=0;i<3;i++) if(c==&t->banks[i]) return i;
 return -1;
}
/* Reserve only; a full replacement producer must initialize every used field. */
static inline SynthSequenceConfig *synth_sequence_reserve_write(SynthSequenceTransport *t) {
 for(int i=0;i<3;i++) {
  uint32_t freeState=0;
  if(__atomic_compare_exchange_n(&t->bankState[i],&freeState,1,0,__ATOMIC_ACQ_REL,__ATOMIC_RELAXED))return &t->banks[i];
 }
 return 0;
}
static inline SynthSequenceConfig *synth_sequence_begin_write(SynthSequenceTransport *t) {
 SynthSequenceConfig *c=synth_sequence_reserve_write(t);if(!c)return 0;
 if(t->latest>=0)memcpy(c,&t->banks[t->latest],sizeof(*c));
 else synth_sequence_defaults(c);
 return c;
}
static inline void synth_sequence_cancel_write(SynthSequenceTransport *t,SynthSequenceConfig *c) {
 int i=synth_sequence_bank_index(t,c);
 if(i>=0) __atomic_store_n(&t->bankState[i],0,__ATOMIC_RELEASE);
}
static inline int synth_sequence_prepare(SynthSequenceConfig *c) {
 if(c->stepCount<1||c->stepCount>512||c->mode<0||c->mode>3||
    c->timeUnit<0||c->timeUnit>1||!isfinite(c->stepDuration)||c->stepDuration<=0||
    !isfinite(c->bpm)||c->bpm<20||c->bpm>300||!isfinite(c->swing)||c->swing<-.75||c->swing>.75||
    !isfinite(c->tuning)||c->tuning<220||c->tuning>880||!isfinite(c->detune)||fabs(c->detune)>1200) return 0;
 c->orderCount=0;c->variationSeedCount=0;
 for(int i=0;i<c->stepCount;i++) {
  SynthSequenceStep *s=&c->steps[i];
  if(!isfinite(s->gate)||s->gate<.01||s->gate>1||s->noteCount<0||s->noteCount>32||(!s->rest&&!s->noteCount)) return 0;
  if(!isfinite(s->duration)||s->duration<0||!isfinite(s->length)||s->length<0) return 0;
  for(int n=0;n<s->noteCount;n++) {
   if(!isfinite(s->frequencies[n])||s->frequencies[n]<0) return 0;
   if(s->frequencies[n]==0&&(s->notes[n]<12||s->notes[n]>119)) return 0;
   s->preparedFrequencies[n]=s->frequencies[n]>0?s->frequencies[n]:c->tuning*pow(2.0,((double)s->notes[n]-69+c->detune/100)/12);
  }
  if(s->voice.variation.seeded&SYNTH_VAR_STEP_SEED) {
   // Authored seed declarations, sorted on the producer: ordinary step moves
   // and inherited rests cannot change sequence stream identity.
   uint32_t seed=s->voice.variation.seed;int at=c->variationSeedCount++;
   while(at>0&&c->variationSeeds[at-1]>seed){c->variationSeeds[at]=c->variationSeeds[at-1];at--;}
   c->variationSeeds[at]=seed;
  }
  if(c->mode==SYNTH_SEQUENCE_NORMAL||(!s->rest&&s->noteCount)) c->order[c->orderCount++]=i;
 }
 if(c->mode!=SYNTH_SEQUENCE_NORMAL) {
  for(int i=1;i<c->orderCount;i++) {
   int item=c->order[i],j=i;
   while(j>0&&c->steps[c->order[j-1]].preparedFrequencies[0]>c->steps[item].preparedFrequencies[0]) {c->order[j]=c->order[j-1];j--;}
   c->order[j]=item;
  }
  if(c->mode==SYNTH_SEQUENCE_DOWN) for(int i=0;i<c->orderCount/2;i++) {
   int v=c->order[i];c->order[i]=c->order[c->orderCount-1-i];c->order[c->orderCount-1-i]=v;
  }
 }
 return 1;
}
/* Failed commits release the writer bank; acceptance precedes callback apply. */
/* Internal producer fast path: c must have just passed synth_sequence_prepare,
 * without any subsequent structural mutation. Ownership/mailbox checks remain. */
static inline int synth_sequence_commit_prepared(SynthSequenceTransport *t,SynthSequenceConfig *c,int restart) {
 int i=synth_sequence_bank_index(t,c);if(i<0)return 0;
 if(!restart&&t->latest>=0&&c->timeUnit!=t->banks[t->latest].timeUnit) {synth_sequence_cancel_write(t,c);return 0;}
 /* Four samples at the fastest musical tempo leave at least one sample
  * after the largest swing displacement. Sub-sample scores cannot satisfy
  * the one-sample scheduling bound and are rejected atomically. */
 double minimum=(c->timeUnit==SYNTH_SEQUENCE_MS?4000:20)/t->sampleRate;
 if(c->stepDuration<minimum) {synth_sequence_cancel_write(t,c);return 0;}
 for(int n=0;n<c->stepCount;n++)if(c->steps[n].duration>0&&c->steps[n].duration<minimum) {synth_sequence_cancel_write(t,c);return 0;}
 c->revision=t->nextRevision+1;
 uint32_t serial=(__atomic_add_fetch(&t->controlSerial,1,__ATOMIC_RELAXED)&0x0fffffffu);
 if(!serial)serial=(__atomic_add_fetch(&t->controlSerial,1,__ATOMIC_RELAXED)&0x0fffffffu);
 uint32_t empty=0,publication=(serial<<4)|(uint32_t)(i+1)|(restart?8u:0u);
 if(!__atomic_compare_exchange_n(&t->mailbox,&empty,publication,0,__ATOMIC_RELEASE,__ATOMIC_RELAXED)) {
  synth_sequence_cancel_write(t,c);return 0;
 }
 t->nextRevision=c->revision;t->latest=i;return 1;
}
static inline int synth_sequence_commit(SynthSequenceTransport *t,SynthSequenceConfig *c,int restart) {
 if(synth_sequence_bank_index(t,c)<0)return 0;
 if(!synth_sequence_prepare(c)){synth_sequence_cancel_write(t,c);return 0;}
 return synth_sequence_commit_prepared(t,c,restart);
}
static inline void synth_sequence_request_stop(SynthSequenceTransport *t) {
 uint32_t serial=(__atomic_add_fetch(&t->controlSerial,1,__ATOMIC_RELAXED)&0x0fffffffu);
 if(!serial)serial=(__atomic_add_fetch(&t->controlSerial,1,__ATOMIC_RELAXED)&0x0fffffffu);
 __atomic_store_n(&t->stopRequested,serial,__ATOMIC_RELEASE);
}
static inline void synth_sequence_publish_state(SynthSequenceTransport *t) {
 uint64_t beat,bpm;memcpy(&beat,&t->beat,8);memcpy(&bpm,&t->bpm,8);
 __atomic_fetch_add(&t->snapshotSequence,1,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotPlaying,(uint32_t)t->playing,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotStep,(uint32_t)t->lastStep,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotRevision,t->active<0?0:t->banks[t->active].revision,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotBeat,beat,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotBpm,bpm,__ATOMIC_SEQ_CST);
 __atomic_store_n(&t->snapshotGeneration,t->generation,__ATOMIC_SEQ_CST);
 __atomic_fetch_add(&t->snapshotSequence,1,__ATOMIC_SEQ_CST);
}
static inline SynthSequenceState synth_sequence_state(const SynthSequenceTransport *t) {
 SynthSequenceState s;memset(&s,0,sizeof(s));s.bank=-1;
 for(;;) {
  uint32_t before=__atomic_load_n(&t->snapshotSequence,__ATOMIC_SEQ_CST);if(before&1)continue;
  s.playing=(int)__atomic_load_n(&t->snapshotPlaying,__ATOMIC_SEQ_CST);
  s.stepIndex=(int32_t)__atomic_load_n(&t->snapshotStep,__ATOMIC_SEQ_CST);
  s.revision=__atomic_load_n(&t->snapshotRevision,__ATOMIC_SEQ_CST);
  uint64_t beat=__atomic_load_n(&t->snapshotBeat,__ATOMIC_SEQ_CST),bpm=__atomic_load_n(&t->snapshotBpm,__ATOMIC_SEQ_CST);
  memcpy(&s.beat,&beat,8);memcpy(&s.bpm,&bpm,8);
  s.generation=__atomic_load_n(&t->snapshotGeneration,__ATOMIC_SEQ_CST);
  if(before==__atomic_load_n(&t->snapshotSequence,__ATOMIC_SEQ_CST))return s;
 }
}
static inline void synth_sequence_apply_pending(SynthSequenceTransport *t) {
 if(t->pending<0)return;
 int old=t->active;
 if(!t->pendingRestart&&old>=0&&t->banks[old].timeUnit!=t->banks[t->pending].timeUnit) {
  __atomic_store_n(&t->bankState[t->pending],0,__ATOMIC_RELEASE);t->pending=-1;return;
 }
 int resetVariation=t->pendingRestart;
 if(old>=0&&!resetVariation) {
  const SynthSequenceConfig *a=&t->banks[old],*b=&t->banks[t->pending];
  resetVariation=a->variationRootSeeded!=b->variationRootSeeded||
   (a->variationRootSeeded&&a->variationRootSeed!=b->variationRootSeed)||
   a->variationSeedCount!=b->variationSeedCount||
   memcmp(a->variationSeeds,b->variationSeeds,(size_t)a->variationSeedCount*sizeof(uint32_t))!=0;
 }
 if(resetVariation)t->variationAttack=0;
 t->active=t->pending;t->pending=-1;
 if(old>=0)__atomic_store_n(&t->bankState[old],0,__ATOMIC_RELEASE);
 if(t->pendingRestart) {
  t->beat=t->nextBeat=t->beatCompensation=0;t->cursor=t->pairIndex=0;t->playing=1;t->lastStep=-1;t->generation++;
  t->swing=t->banks[t->active].swing;t->pairShift=0;
 }
 t->pendingRestart=0;
}
static inline void synth_sequence_begin_block(SynthSequenceTransport *t) {
 uint32_t p=__atomic_exchange_n(&t->mailbox,0,__ATOMIC_ACQ_REL);
 if(p) {
  if(t->pending>=0)__atomic_store_n(&t->bankState[t->pending],0,__ATOMIC_RELEASE);
  t->pending=(int)(p&7)-1;t->pendingRestart=(p&8)!=0;
  if(t->pendingRestart)t->lastRestartSerial=p>>4;
  t->bpm=t->banks[t->pending].bpm;
  if(t->pendingRestart||!t->playing)synth_sequence_apply_pending(t);
 }
 uint32_t stop=__atomic_exchange_n(&t->stopRequested,0,__ATOMIC_ACQ_REL);
 if(stop&&(int32_t)((stop-t->lastRestartSerial)<<4)>0) {t->playing=0;t->generation++;}
 if(!t->playing&&t->pending>=0)synth_sequence_apply_pending(t);
 synth_sequence_publish_state(t);
}
/* Call tick before rendering each frame, then advance_sample after rendering.
 * A generation change tells the renderer to release only transport-owned notes.
 * gateEndBeat is compared with t->beat, preserving gate position across BPM edits. */
static inline int synth_sequence_tick(SynthSequenceTransport *t,SynthSequenceEvent *event) {
 if(!t->playing||t->beat+1e-10<t->nextBeat)return 0;
 int previousPeriod=0;
 if(t->active>=0) {
  const SynthSequenceConfig *previous=&t->banks[t->active];
  previousPeriod=previous->mode==SYNTH_SEQUENCE_UPDOWN&&previous->orderCount>1?2*previous->orderCount-2:previous->orderCount;
 }
 synth_sequence_apply_pending(t);
 SynthSequenceConfig *c=&t->banks[t->active];
 int count=c->orderCount;
 int period=(c->mode==SYNTH_SEQUENCE_UPDOWN&&count>1)?2*count-2:count;
 /* A shrink can move an outstanding next step into the new traversal.
  * A cursor already at the old end must still complete, even if an edit
  * arrived after its final attack. Harmless edits cannot extend a score. */
 if(period>0&&period<previousPeriod&&t->cursor>=period&&t->cursor<previousPeriod)t->cursor%=period;
 if(period==0||(!c->loop&&t->cursor>=period)) {t->playing=0;return 0;}
 if(t->cursor>=period)t->cursor%=period;
 int pos=t->cursor;
 if(c->mode==SYNTH_SEQUENCE_UPDOWN&&pos>=count)pos=period-pos;
 int index=c->order[pos];SynthSequenceStep *s=&c->steps[index];
 double interval=s->duration>0?s->duration:c->stepDuration;
 if(!(t->pairIndex&1)) {
  t->swing=c->swing;
  int nextCursor=t->cursor+1;
  if(nextCursor>=period)nextCursor=c->loop?0:-1;
  double other=interval;
  if(nextCursor>=0) {
   int nextPos=nextCursor;
   if(c->mode==SYNTH_SEQUENCE_UPDOWN&&nextPos>=count)nextPos=period-nextPos;
   SynthSequenceStep *next=&c->steps[c->order[nextPos]];
   other=next->duration>0?next->duration:c->stepDuration;
  }
  t->pairShift=t->swing*fmin(interval,other);
 }
 double length=interval+((t->pairIndex&1)?-t->pairShift:t->pairShift);
 /* Structural edits can shorten the second interval mid-pair. */
 if(length<=0)length=interval*.25;
 memset(event,0,sizeof(*event));event->stepIndex=index;event->bank=t->active;
 event->noteCount=s->rest?0:s->noteCount;memcpy(event->notes,s->notes,sizeof(event->notes));
 for(int n=0;n<event->noteCount;n++)event->frequencies[n]=s->preparedFrequencies[n];
 event->length=s->length>0?s->length:length*s->gate;
 event->gateEndBeat=t->nextBeat+event->length;event->generation=t->generation;
 t->lastStep=index;t->nextBeat+=length;t->cursor++;t->pairIndex++;
 return 1;
}
static inline void synth_sequence_advance_sample(SynthSequenceTransport *t) {
 if(t->playing) {
  double increment=(t->active>=0&&t->banks[t->active].timeUnit==SYNTH_SEQUENCE_MS?1000/t->sampleRate:t->bpm/(60*t->sampleRate))-t->beatCompensation;
  double next=t->beat+increment;
  t->beatCompensation=(next-t->beat)-increment;t->beat=next;
 }
}
static inline double synth_sequence_frequency(const SynthSequenceConfig *c,int midi) {
 return c->tuning*pow(2.0,((double)midi-69+c->detune/100)/12);
}
#endif
