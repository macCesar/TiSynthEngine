// The production output stage is shared by the C++ and ObjC callbacks.
#include "../shared/synth_output.h"
#include <assert.h>
#include <stdio.h>
static void near(double a,double b) { assert(fabs(a-b)<1e-12); }
int main(void) {
 const int rates[]={16000,44100,48000,96000,192000};
 for(int k=0;k<5;k++) {
  SynthOutput s;synth_output_init(&s,rates[k]);
  int n=(int)round(rates[k]*.01);
  for(int i=1;i<=n;i++)near(synth_output_master(&s,0),1-(double)i/n);
  assert(s.masterGain==0 && s.masterRemaining==0);
  for(int i=1;i<=n;i++)near(synth_output_master(&s,2),2.*i/n);
  assert(s.masterGain==2);
  synth_output_master(&s,0);double start=s.masterGain;
  for(int i=1;i<=n;i++)near(synth_output_master(&s,.25),start+(.25-start)*i/n);
  for(int profile=0;profile<4;profile++) {
   synth_output_init(&s,rates[k]);double ceiling=profile==3?.70:.85,l,r;
   synth_output_protect(&s,.1,-.2,ceiling,&l,&r);near(l,.1);near(r,-.2);
   synth_output_protect(&s,10,-5,ceiling,&l,&r);near(l,ceiling);near(r,-ceiling/2);
   double g=s.gain;
   for(int i=0;i<rates[k]/10;i++) {
    synth_output_protect(&s,.1,-.1,ceiling,&l,&r);
    assert(s.gain>=g && s.gain<=1);g=s.gain;
   }
   near(s.gain,1-(1-ceiling/10)*exp(-1));
   double before=s.gain;
   synth_output_protect(&s,0,0,ceiling,&l,&r);
   near(s.gain,before+(1-before)*s.releaseCoeff); // isolated zero crossing is not silence
   synth_output_protect(&s,.1,-.1,ceiling,&l,&r);
   synth_output_protect(&s,0,0,ceiling,&l,&r);assert(s.gain<1);
   synth_output_protect(&s,0,0,ceiling,&l,&r);assert(s.gain==1 && l==0 && r==0);
   for(int i=0;i<100000;i++) {
    double x=sin(i*1.234)*20,y=cos(i*.631)*10;
    synth_output_protect(&s,x,y,ceiling,&l,&r);
    assert(isfinite(l)&&isfinite(r)&&fabs(l)<=ceiling+1e-12&&fabs(r)<=ceiling+1e-12);
   }
   synth_output_init(&s,rates[k]);assert(s.gain==1 && s.masterGain==1);
  }
 }
 puts("output core: zero retention, linked ceiling, 100ms recovery, silence/reset, exact 10ms ramps at five rates PASS");
}
