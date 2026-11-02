/* Compare this driver against HEAD and current source. Noise uses the existing
 * host's controlled seed clock. Public DSP is never replaced. */
int main(int argc,char **argv) {@autoreleasepool {
 BOOL zero=argc>1&&!strcmp(argv[1],"zero");
 for(int profile=0;profile<4;profile++)for(int wave=0;wave<6;wave++)for(int path=0;path<4;path++) {
  RenderRig *r=rig(48000);r->mixingProfile=profile;
  SynthCommand c=tone(r,0,wave,NO,path==1);c.volume=.03;
#ifdef SYNTH_VARIATION_H
  if(zero){c.variation.amount=0;c.variation.mask=129;c.variation.seeded=1;c.variation.low[0]=.01;c.variation.high[0]=.03;c.variation.low[7]=-12;c.variation.high[7]=12;}
#else
  assert(!zero);
#endif
  if(path<3) {
   int count=path==2?8:1;r->batchOrder=r->voiceOrder;r->batchRemaining=count;
   for(int i=0;i<count;i++){c.eventVoiceCount=count;[r startVoiceFromCommand:&c];r->batchRemaining--;}
  } else {
   SynthSequenceConfig *bank=synth_transport_begin_write(r->sequence,1,1);assert(bank);bank->stepCount=1;
   bank->steps[0].noteCount=2;bank->steps[0].notes[0]=60;bank->steps[0].notes[1]=64;bank->steps[0].voice.waveType=wave;
   bank->steps[0].voice.volume=.03;bank->steps[0].voice.wavetableSize=4;bank->steps[0].voice.wavetable[0]=-1;bank->steps[0].voice.wavetable[1]=-.2;bank->steps[0].voice.wavetable[2]=.7;bank->steps[0].voice.wavetable[3]=1;
#ifdef SYNTH_VARIATION_H
   if(zero)bank->steps[0].voice.variation=c.variation;
#endif
   assert(synth_transport_commit(r->sequence,bank,1));
  }
  float out[512];
  for(int block=0;block<12;block++) {
   if(block==3){SynthCommand overlap=tone(r,7,wave,NO,NO);[r startVoiceFromCommand:&overlap];}
   if(block==4)for(int i=0;i<32;i++)if(r->voices[i].isActive&&r->voices[i].held.voiceId)synth_held_release(&r->voices[i].held,r->voices[i].currentEnvelope);
   render(r,256,out,0);assert(fwrite(out,1,sizeof(out),stdout)==sizeof(out));
  }
  destroyRig(r);
 }
 return 0;
}}
