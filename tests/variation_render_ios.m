int main(void) {@autoreleasepool {
 RenderRig *r=rig(48000);SynthCommand c=tone(r,0,0,NO,YES);
 c.variation.amount=1;c.variation.seeded=1;c.variation.seed=0;c.variation.mask=129;
 c.variation.low[0]=.1;c.variation.high[0]=.2;c.variation.low[7]=-100;c.variation.high[7]=100;
 [r startVoiceFromCommand:&c];SynthVoice *v=&r->voices[0];
 double freq=c.frequency*pow(2,synth_variation_value(&c.variation,7,0,0,0,0)/1200);
 assert(v->phaseIncrement==freq/48000);
 assert(v->live.value[LIVE_VOLUME]==synth_variation_value(&c.variation,0,c.volume,0,0,0));
 float output[512];render(r,256,output,0);assert(v->phaseIncrement==freq/48000);
 SynthCommand other=tone(r,1,0,NO,YES);[r startVoiceFromCommand:&other];render(r,256,output,0);
 assert(v->phaseIncrement==freq/48000);
 destroyRig(r);
 for(int wave=0;wave<6;wave++) {
  RenderRig *a=rig(48000),*b=rig(48000);SynthCommand x=tone(a,0,wave,NO,NO),y=x;
  y.variation=c.variation;y.variation.amount=0;
  [a startVoiceFromCommand:&x];[b startVoiceFromCommand:&y];
  float left[512],right[512];render(a,256,left,0);render(b,256,right,0);assert(!memcmp(left,right,sizeof(left)));
  destroyRig(a);destroyRig(b);
 }
 for(int wave=0;wave<6;wave++)for(int profile=0;profile<4;profile++)for(int path=0;path<3;path++) {
  RenderRig *a=rig(48000),*b=rig(48000);a->mixingProfile=b->mixingProfile=profile;
  SynthCommand x=tone(a,0,wave,NO,path==0),y=x;y.variation=c.variation;y.variation.amount=0;
  if(path<2)for(int side=0;side<2;side++) {
   RenderRig *r=side?b:a;SynthCommand cmd=side?y:x;
   int count=path==1?8:1;r->batchOrder=r->voiceOrder;r->batchRemaining=count;
   for(int i=0;i<count;i++){cmd.eventVoiceCount=count;cmd.variationOrdinal=i;[r startVoiceFromCommand:&cmd];r->batchRemaining--;}
  }
  else for(int side=0;side<2;side++) {
   RenderRig *r=side?b:a;SynthSequenceConfig *bank=synth_transport_begin_write(r->sequence,1,1);assert(bank);
   bank->stepCount=1;bank->steps[0].noteCount=2;bank->steps[0].notes[0]=60;bank->steps[0].notes[1]=64;
   SynthSequenceVoice *v=&bank->steps[0].voice;v->waveType=wave;v->volume=.03;v->release=20;v->wavetableSize=4;
   v->wavetable[0]=-1;v->wavetable[1]=-.2;v->wavetable[2]=.7;v->wavetable[3]=1;if(side)v->variation=y.variation;
   assert(synth_transport_commit(r->sequence,bank,1));float out[2];render(r,1,out,0);
  }
  float left[512],right[512];render(a,256,left,0);render(b,256,right,0);assert(!memcmp(left,right,sizeof(left)));
  for(int i=0;i<32;i++) {
   if(a->voices[i].isActive&&a->voices[i].held.voiceId)synth_held_release(&a->voices[i].held,a->voices[i].currentEnvelope);
   if(b->voices[i].isActive&&b->voices[i].held.voiceId)synth_held_release(&b->voices[i].held,b->voices[i].currentEnvelope);
  }
  for(int i=0;i<5;i++){render(a,256,left,0);render(b,256,right,0);assert(!memcmp(left,right,sizeof(left)));}
  destroyRig(a);destroyRig(b);
 }
 RenderRig *seq=rig(48000);
 NSDictionary *options=@{@"loop":@YES,@"stepDuration":@.01,@"voice":@{@"volume":@.2,@"variation":@{@"seed":@0,@"ranges":@{@"volume":@[@.1,@.2],@"pitchCents":@[@-100,@100]}}},@"steps":@[@{@"notes":@[@60,@64]},@{@"rest":@YES}]};
 SynthSequenceConfig *bank=synth_transport_begin_write(seq->sequence,1,1);assert(bank);
 assert(![TiSynthengineContract prepareSequence:options config:bank maxFrequency:21600]);
 assert(synth_transport_commit(seq->sequence,bank,1));render(seq,1,output,0);
 SynthSequenceTransport *slot=&seq->sequence->slots[0];assert(slot->variationAttack==1);
 assert(seq->voices[0].live.value[LIVE_VOLUME]!=seq->voices[1].live.value[LIVE_VOLUME]);
 render(seq,240,output,0);assert(slot->variationAttack==1);render(seq,240,output,0);assert(slot->variationAttack==2);
 bank=synth_transport_begin_write(seq->sequence,1,0);bank->swing=.1;assert(synth_transport_commit(seq->sequence,bank,0));render(seq,240,output,0);render(seq,240,output,0);assert(slot->variationAttack==3);
 bank=synth_transport_begin_write(seq->sequence,1,0);bank->variationRootSeeded=1;bank->variationRootSeed=42;bank->steps[0].voice.variation.seed=42;assert(synth_transport_commit(seq->sequence,bank,0));render(seq,240,output,0);render(seq,240,output,0);assert(slot->variationAttack==1);
 destroyRig(seq);
 puts("Apple variation renderer PASS");return 0;
}}
