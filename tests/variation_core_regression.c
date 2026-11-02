#include <assert.h>
#include <stdio.h>
#include <string.h>
#if __has_include("../shared/synth_variation.h")
#include "../shared/synth_variation.h"
int main(void) {
 SynthVariation v={0};v.amount=1;v.mask=1;v.low[0]=.2;v.high[0]=.8;
 assert(synth_variation_word(0,0,0,0)==0xe220a839u);
 assert(synth_variation_word(0u,UINT64_C(1),0u,0u)==0x6e789e6au);
 assert(synth_variation_word(4294967295u,UINT64_C(18446744073709551615),31u,7u)==0x8b85e92cu);
 assert(synth_variation_word(20261101u,UINT64_C(12345),7u,3u)==0xc5927ac9u);
 assert(synth_variation_word(0,1,0,0)!=synth_variation_word(0,0,0,0));
 assert(synth_variation_word(0,0,1,0)!=synth_variation_word(0,0,0,0));
 assert(synth_variation_word(0,0,0,1)!=synth_variation_word(0,0,0,0));
 SynthVariation before=v;
 double first=synth_variation_value(&v,0,1,0,0,0);
 for(unsigned i=0;i<10000;i++) {
  double x=synth_variation_value(&v,0,1,0,i,0);assert(x>=.2&&x<.8);
 }
 assert(first==synth_variation_value(&v,0,1,0,0,0));
 v.mask|=2;v.low[1]=20;v.high[1]=2000;assert(first==synth_variation_value(&v,0,1,0,0,0));v=before;
 assert(memcmp(&before,&v,sizeof(v))==0);
 v.amount=0;assert(synth_variation_value(&v,0,1,0,0,0)==1);
 v.amount=.5;assert(synth_variation_value(&v,0,1,0,0,0)==1+.5*(first-1));
 assert(synth_variation_value(&v,1,1000,0,0,0)==1000);
 printf("variation core PASS; config=%zu bytes\n",sizeof(v));return 0;
}
#else
int main(void) {fprintf(stderr,"FAIL: native variation helper unavailable\n");return 1;}
#endif
