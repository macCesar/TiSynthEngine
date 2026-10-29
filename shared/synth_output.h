/* Shared final stereo output. No sample buffering or allocation.
 * Master gain precedes routed effects; protection follows recombination.
 * Ceilings bound samples, not inter-sample peaks or speaker excursion.
 */
#ifndef SYNTH_OUTPUT_H
#define SYNTH_OUTPUT_H
#include <math.h>
typedef struct {
 double masterGain, masterTarget, masterStep;
 int masterRemaining, rampSamples, quietFrames;
 double gain, releaseCoeff;
} SynthOutput;
static inline void synth_output_init(SynthOutput *s,double sampleRate) {
 s->masterGain=s->masterTarget=s->gain=1;
 s->masterStep=0;s->masterRemaining=0;s->quietFrames=0;
 s->rampSamples=(int)fmax(1,round(.010*sampleRate));
 s->releaseCoeff=1-exp(-1/(.100*sampleRate));
}
/* The next processed sample takes the first step, including after a retarget.
 * Set the last sample explicitly to avoid accumulated rounding error.
 */
static inline double synth_output_master(SynthOutput *s,double target) {
 if(target!=s->masterTarget) {
  s->masterTarget=target;s->masterRemaining=s->rampSamples;
  s->masterStep=(target-s->masterGain)/s->masterRemaining;
 }
 if(s->masterRemaining>0) {
  s->masterGain+=s->masterStep;
  if(--s->masterRemaining==0){s->masterGain=s->masterTarget;s->masterStep=0;}
 }
 return s->masterGain;
}
/* Instantaneous linked reduction, exponential 100ms recovery bounded by the
 * current sample. Overload changes the waveform; it is not transparent.
 */
static inline void synth_output_protect(SynthOutput *s,double left,double right,
                                        double ceiling,double *outL,double *outR) {
 double peak=fmax(fabs(left),fabs(right));
 double required=peak>ceiling?ceiling/peak:1;
 /* One quiet frame may be a zero crossing. Recognize silence on the second
  * consecutive quiet stereo frame; no samples are stored or held back. */
 s->quietFrames=peak<=1e-12?(s->quietFrames<2?s->quietFrames+1:2):0;
 s->gain=s->quietFrames==2?1:fmin(required,s->gain+(1-s->gain)*s->releaseCoeff);
 *outL=left*s->gain;*outR=right*s->gain;
}
#endif
