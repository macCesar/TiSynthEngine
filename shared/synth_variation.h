/* Attack-only parameter selection. No mutable RNG, noise state, or allocation.
 * Slots are part of schema 1: never reorder them. Counters wrap modulo 2^64.
 * SplitMix64 finalization, with independent odd strides for each coordinate;
 * the high 32 bits map exactly to [0,1) via division by 2^32. */
#ifndef SYNTH_VARIATION_H
#define SYNTH_VARIATION_H
#include <stdint.h>
#include <math.h>
#include <string.h>
/* seeded bit 1 is the deterministic seed; bit 2 marks an explicit step seed. */
enum { SYNTH_VAR_SEEDED=1, SYNTH_VAR_STEP_SEED=2 };
enum { SYNTH_VAR_VOLUME, SYNTH_VAR_FILTER_HZ, SYNTH_VAR_FILTER_Q,
 SYNTH_VAR_FM_DEPTH, SYNTH_VAR_NOISE_RATE, SYNTH_VAR_LOWPASS_HZ,
 SYNTH_VAR_PULSE_WIDTH, SYNTH_VAR_PITCH_CENTS, SYNTH_VAR_COUNT };
typedef struct {
 double amount,low[SYNTH_VAR_COUNT],high[SYNTH_VAR_COUNT];
 uint32_t seed;
 uint16_t mask,seeded;
} SynthVariation;
static inline uint32_t synth_variation_word(uint32_t seed,uint64_t attack,uint32_t voice,unsigned field) {
 uint64_t x=(uint64_t)seed+UINT64_C(0x9e3779b97f4a7c15)*(attack+1)
  +UINT64_C(0xd1b54a32d192ed03)*voice+UINT64_C(0x94d049bb133111eb)*field;
 x=(x^(x>>30))*UINT64_C(0xbf58476d1ce4e5b9);
 x=(x^(x>>27))*UINT64_C(0x94d049bb133111eb);
 return (uint32_t)((x^(x>>31))>>32);
}
static inline int synth_variation_active(const SynthVariation *v) {return v->mask&&v->amount>0;}
static inline double synth_variation_value(const SynthVariation *v,unsigned field,double authored,uint32_t seed,uint64_t attack,uint32_t voice) {
 if(!synth_variation_active(v)||!(v->mask&(1u<<field)))return authored;
 double u=(double)synth_variation_word(seed,attack,voice,field)*(1.0/4294967296.0);
 double sampled=v->low[field]+u*(v->high[field]-v->low[field]);
 return authored+v->amount*(sampled-authored);
}
/* Control-side source/range validation; pitch is already tuned/detuned. */
static inline int synth_variation_valid(const SynthVariation *v,int wave,int filter,double noiseRate,double lowPass,double frequency,double end,double ceiling) {
 if(!isfinite(v->amount)||v->amount<0||v->amount>1||v->mask>=256)return 0;
 const double minimum[8]={0,20,.5,0,1,20,.05,-1200};
 const double maximum[8]={2,ceiling,10,10,ceiling,ceiling,.95,1200};
 for(unsigned i=0;i<8;i++)if(v->mask&(1u<<i)) {
  double lo=v->low[i],hi=v->high[i];
  if(!isfinite(lo)||!isfinite(hi)||lo>hi||lo<minimum[i]||hi>maximum[i])return 0;
  if((i==1||i==2)&&!filter)return 0;
  if(i==3&&wave!=0)return 0;
  if(i==4&&(wave!=4||noiseRate<1))return 0;
  if(i==5&&lowPass<20)return 0;
  if(i==6&&wave!=1)return 0;
 }
 if(v->mask&(1u<<SYNTH_VAR_PITCH_CENTS)) {
  double lo=pow(2,v->amount*v->low[7]/1200),hi=pow(2,v->amount*v->high[7]/1200);
  if(frequency*lo<1||frequency*hi>ceiling)return 0;
  if(end>=1&&(end*lo<1||end*hi>ceiling))return 0;
 }
 return 1;
}
#endif
