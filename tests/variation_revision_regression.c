#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include "../shared/synth_sequence.h"
int main(void) {
 SynthSequenceTransport *t=calloc(1,sizeof(*t));synth_sequence_init(t,48000);
 SynthSequenceConfig *c=synth_sequence_begin_write(t);c->stepCount=2;c->loop=1;c->variationRootSeeded=1;c->variationRootSeed=42;
 c->steps[0].noteCount=1;c->steps[0].notes[0]=60;
 c->steps[0].voice.variation.seeded=1;c->steps[0].voice.variation.seed=42;
 c->steps[1].rest=1;
 assert(synth_sequence_commit(t,c,1));synth_sequence_begin_block(t);t->variationAttack=7;
 c=synth_sequence_begin_write(t);c->steps[2]=c->steps[1];c->steps[1]=c->steps[0];c->steps[0]=c->steps[1];c->steps[0].rest=1;c->steps[0].noteCount=0;c->stepCount=3;
 assert(synth_sequence_commit(t,c,0));
 synth_sequence_begin_block(t);synth_sequence_apply_pending(t);
 assert(t->variationAttack==7);
 c=synth_sequence_begin_write(t);c->variationRootSeed=43;assert(synth_sequence_commit(t,c,0));synth_sequence_begin_block(t);synth_sequence_apply_pending(t);assert(t->variationAttack==0);
 t->variationAttack=8;c=synth_sequence_begin_write(t);c->stepCount=4;c->steps[3]=c->steps[0];c->steps[3].voice.variation.seeded=3;c->steps[3].voice.variation.seed=0;
 assert(synth_sequence_commit(t,c,0));synth_sequence_begin_block(t);synth_sequence_apply_pending(t);assert(t->variationAttack==0);
 t->variationAttack=9;c=synth_sequence_begin_write(t);SynthSequenceStep temp=c->steps[0];c->steps[0]=c->steps[3];c->steps[3]=temp;
 assert(synth_sequence_commit(t,c,0));synth_sequence_begin_block(t);synth_sequence_apply_pending(t);assert(t->variationAttack==9);
 free(t);puts("sequence structural variation revision PASS");return 0;
}
