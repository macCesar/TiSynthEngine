// Production Objective-C bridge/control methods and exact Apple render callback.
static NSDictionary *recipe(int interval,BOOL spatial) {
 NSMutableDictionary *o=[@{@"frequency":@440,@"duration":@20,@"attack":@1,@"release":@2,@"volume":@.05,@"waveType":@1,@"pulseWidth":@.3} mutableCopy];
 if(interval)o[@"intervalMs"]=@(interval);
 if(spatial){o[@"spatialX"]=@.5;o[@"spatialY"]=@(-.3);}
 return o;
}
static void frames(RenderRig *r,int count) {float out[2048];while(count){int n=MIN(count,1024);render(r,n,out,1);count-=n;}}
static void identicalAttacks(void) {
 NSArray *shapes=@[@{},@{@"frequencyEnd":@800,@"pan":@(-.8),@"panEnd":@.8,@"decay":@2,@"sustain":@.5},@{@"waveType":@0,@"fmRatio":@2,@"fmDepth":@1,@"fmDepthEnd":@0},@{@"waveType":@4,@"noiseRate":@1200,@"noiseRateEnd":@2000,@"lowPassHz":@3000},@{@"filterType":@"lowpass",@"filterHz":@300,@"filterHzEnd":@1800,@"filterQ":@1.2},@{@"variation":@{@"amount":@1,@"seed":@123,@"ranges":@{@"volume":@[@.01,@.1],@"pitchCents":@[@(-20),@20]}}}];
 for(int spatial=0;spatial<2;spatial++)for(NSDictionary *shape in shapes) {
  RenderRig *a=rig(44100),*b=rig(44100);NSMutableDictionary *one=[recipe(0,spatial) mutableCopy];[one addEntriesFromDictionary:shape];if(spatial){[one removeObjectForKey:@"pan"];[one removeObjectForKey:@"panEnd"];}
  NSMutableDictionary *repeat=[one mutableCopy];repeat[@"intervalMs"]=@60000;
  NSNumber *single=[a playTone:one];assert(CFGetTypeID((__bridge CFTypeRef)single)==CFBooleanGetTypeID()&&single.boolValue);
  NSNumber *identifier=[b repeatTone:repeat];assert(identifier.intValue>0&&CFGetTypeID((__bridge CFTypeRef)identifier)!=CFBooleanGetTypeID());
  float left[2048],right[2048];for(int i=0;i<8;i++){render(a,256,left,1);render(b,256,right,1);assert(!memcmp(left,right,512*sizeof(float)));}
  assert(a->voiceOrder==1&&b->voiceOrder==1);destroyRig(a);destroyRig(b);
 }
}
static void sampleClockAndEdits(void) {
 RenderRig *r=rig(44100);int id=[[r repeatTone:recipe(1,YES)] intValue];assert(id>0);
 float out[2048];render(r,0,out,1);assert(!r->voiceOrder);
 // Independent variable block boundaries and exact fractional 44.1-frame grid.
 int frame=0;uint64_t expected=0;
 for(int block=0;block<800;block++) {
  int sizes[]={1,3,17,31,256};int n=sizes[block%5];
  if(block==100)assert(synth_transport_set_tempo(r->sequence,300));
  if(block==300)assert(synth_transport_set_tempo(r->sequence,20));
  render(r,n,out,1);frame+=n;expected=(uint64_t)floor(((frame-1)+1e-7)/44.1)+1;assert(r->voiceOrder==expected);
 }
 assert(([[r stopTone:@{@"toneId":@(id)}] boolValue]));uint64_t ended=r->voiceOrder;frames(r,1000);assert(r->voiceOrder==ended);
 assert((![[r updateTone:@{@"toneId":@(id),@"volume":@.1}] boolValue]));
 destroyRig(r);
 r=rig(16000);id=[[r repeatTone:recipe(10,NO)] intValue];frames(r,1);assert(r->voiceOrder==1);
 assert(([[r updateTone:@{@"toneId":@(id),@"intervalMs":@20,@"note":@"A3",@"volume":@.2}] boolValue]));
 assert((![[r updateTone:@{@"toneId":@(id),@"frequency":@100,@"note":@"A4"}] boolValue]));
 assert((![[r updateTone:@{@"toneId":@(id),@"duration":@1}] boolValue]));
 frames(r,159);assert(r->voiceOrder==1);frames(r,1);assert(r->voiceOrder==2);assert(fabs(r->voices[1].phaseIncrement-(220./16000))<1e-12);assert(fabs(r->voices[1].volume-.2*VoiceGainForEvent(r->mixingProfile,1,0))<1e-12);
 frames(r,319);assert(r->voiceOrder==2);frames(r,1);assert(r->voiceOrder==3);
 assert(([[r updateTone:@{@"toneId":@(id),@"frequency":@330}] boolValue]));frames(r,320);assert(r->voiceOrder==4);
 destroyRig(r);
}
static void capacityStopAndQueue(void) {
 RenderRig *r=rig(44100);int first=0,last=0;
 for(int i=0;i<32;i++){last=[[r repeatTone:recipe(1,NO)] intValue];assert(last>0);if(!i)first=last;}
 assert(![[r repeatTone:recipe(1,NO)] intValue]);
 assert(([[r stopTone:@{@"toneId":@(first)}] boolValue]));assert((![[r stopTone:@{@"toneId":@(first)}] boolValue]));
 assert((![[r stopTone:@{@"toneId":@YES}] boolValue]));
 SynthCommand harmless={0};harmless.type=SYNTH_CMD_HELD_UPDATE;harmless.voiceId=123;
 for(int i=0;i<COMMAND_QUEUE_CAPACITY-1;i++)assert(![r enqueueCommand:harmless]);assert([r enqueueCommand:harmless]);
 assert(([[r stopTone:@{@"toneId":@(last)}] boolValue]));
 frames(r,1);assert(r->voiceOrder==30);
 int next=[[r repeatTone:recipe(10,NO)] intValue];assert(next>last);
 [r stopAll:nil];assert((![[r updateTone:@{@"toneId":@(next),@"volume":@.2}] boolValue]));frames(r,441);assert(!r->tones.activeMask);
 destroyRig(r);
}
static void variationStreamAndRejection(void) {
 RenderRig *r=rig(44100);NSMutableDictionary *o=[recipe(1,NO) mutableCopy];o[@"variation"]=@{@"amount":@1,@"seed":@42,@"ranges":@{@"volume":@[@.01,@.1]}};
 int id=[[r repeatTone:o] intValue];frames(r,1);int slot=synth_tone_find(&r->tones,id);assert(slot>=0&&r->tones.slots[slot].variationAttack==1);
 double first=r->voices[0].volume;frames(r,45);assert(r->tones.slots[slot].variationAttack==2);assert(first!=r->voices[1].volume);
 assert(([[r updateTone:@{@"toneId":@(id),@"volume":@.03}] boolValue]));frames(r,44);assert(r->tones.slots[slot].variationAttack==3);
 assert(([[r updateTone:@{@"toneId":@(id),@"variation":@{@"amount":@1,@"seed":@43,@"ranges":@{@"volume":@[@.01,@.1]}}}] boolValue]));frames(r,44);assert(r->tones.slots[slot].variationAttack==1);
 assert(([[r updateTone:@{@"toneId":@(id),@"variation":@{@"amount":@0}}] boolValue]));frames(r,44);assert(r->tones.slots[slot].variationAttack==1);
 destroyRig(r);
 r=rig(44100);r->engineMaxVoices=1;SynthCommand protected=tone(r,0,0,NO,YES);protected.priority=3;assert(![r enqueueCommand:protected]);id=[[r repeatTone:o] intValue];frames(r,100);slot=synth_tone_find(&r->tones,id);assert(r->tones.slots[slot].variationAttack==0&&r->priorityDrops==3);
 [r clearVoices];frames(r,34);assert(r->tones.slots[slot].variationAttack==1);destroyRig(r);
}
static void standaloneAndCancellation(void) {
 RenderRig *r=rig(44100);
 for(int i=0;i<40;i++){NSNumber *ok=[r playTone:recipe(0,NO)];assert(CFGetTypeID((__bridge CFTypeRef)ok)==CFBooleanGetTypeID()&&ok.boolValue);frames(r,5);}
 assert(r->voiceOrder==40&&!r->tones.activeMask);
 int id=[[r repeatTone:recipe(120,NO)] intValue];assert(id>0);
 assert(([[r stopTone:@{@"toneId":@(id)}] boolValue]));frames(r,100);assert(r->voiceOrder==40);
 id=[[r repeatTone:recipe(120,NO)] intValue];frames(r,1);assert(r->voiceOrder==41);
 assert(([[r stopTone:@{@"toneId":@(id)}] boolValue]));frames(r,10);assert(r->stats.active>0);frames(r,44100);assert(!r->stats.active&&r->voiceOrder==41);
 assert((![[r updateTone:@{@"toneId":@(id)}] boolValue]));
 assert((![[r updateTone:@{@"toneId":@(id),@"volume":@.1}] boolValue]));
 NSNumber *singleReject=[r playTone:recipe(120,NO)];assert(!singleReject.boolValue&&CFGetTypeID((__bridge CFTypeRef)singleReject)==CFBooleanGetTypeID());
 NSNumber *missing=[r repeatTone:recipe(0,NO)];assert(!missing.intValue&&CFGetTypeID((__bridge CFTypeRef)missing)!=CFBooleanGetTypeID());
 NSNumber *bad=[r repeatTone:@{@"intervalMs":@0}];assert(!bad.intValue&&CFGetTypeID((__bridge CFTypeRef)bad)!=CFBooleanGetTypeID());
 destroyRig(r);
}
static void acceptedSnapshotAndPanicOrdering(void) {
 RenderRig *r=rig(44100);
 NSMutableArray *range=[NSMutableArray arrayWithArray:@[@.01,@.1]];
 NSMutableDictionary *variation=[@{@"amount":@1,@"seed":@42,@"ranges":@{@"volume":range}} mutableCopy];
 NSMutableDictionary *options=[recipe(10,NO) mutableCopy];options[@"variation"]=variation;
 int id=[[r repeatTone:options] intValue];assert(id>0);frames(r,1);
 variation[@"amount"]=@0;range[0]=@.5;range[1]=@.6;
 assert(([[r updateTone:@{@"toneId":@(id),@"volume":@.03}] boolValue]));
 int slot=synth_tone_find(&r->tones,id);const SynthToneConfig *accepted=&r->tones.slots[slot].banks[r->tones.slots[slot].latest];
 assert(accepted->recipe.variation.amount==1&&accepted->recipe.variation.low[0]==.01&&accepted->recipe.variation.high[0]==.1);
 [r stopAll:nil];int replacement=[[r repeatTone:recipe(10,NO)] intValue];assert(replacement>id);
 frames(r,1);assert(synth_tone_find(&r->tones,replacement)>=0);uint64_t starts=r->voiceOrder;
 frames(r,441);assert(r->voiceOrder==starts+1);
 NSMutableArray *wave=[NSMutableArray arrayWithArray:@[@(-1),@.2,@1]];
 NSMutableDictionary *table=[recipe(10,NO) mutableCopy];table[@"waveType"]=@5;table[@"waveTable"]=wave;
 int tableId=[[r repeatTone:table] intValue];assert(tableId>0);wave[1]=@(-.8);
 assert(([[r updateTone:@{@"toneId":@(tableId),@"volume":@.02}] boolValue]));
 slot=synth_tone_find(&r->tones,tableId);accepted=&r->tones.slots[slot].banks[r->tones.slots[slot].latest];
 assert(accepted->recipe.wavetableSize==3&&accepted->recipe.wavetable[1]==.2);
 destroyRig(r);
}
static void aliases(void) {
 RenderRig *a=rig(44100),*b=rig(44100);
 assert([[a enableStats:nil] boolValue]&&[[b setStatsEnabled:@YES] boolValue]);assert(a->statsEnabled&&b->statsEnabled);
 assert([[a disableStats:nil] boolValue]&&[[b setStatsEnabled:@NO] boolValue]);assert(!a->statsEnabled&&!b->statsEnabled);
 assert(![[a setStatsEnabled:@1] boolValue]);
 NSDictionary *on=@{@"voiceId":@7,@"frequency":@440,@"volume":@.1};assert([[a noteOn:on] boolValue]&&[[b noteOn:on] boolValue]);
 NSDictionary *edit=@{@"voiceId":@7,@"frequency":@220,@"volume":@.02};assert([[a updateNote:edit] boolValue]&&[[b updateVoice:edit] boolValue]);
 float x[2048],y[2048];render(a,512,x,1);render(b,512,y,1);assert(!memcmp(x,y,1024*sizeof(float)));
 NSDictionary *bad=@{@"voiceId":@7,@"variation":@{@"amount":@0}};assert(![[a updateNote:bad] boolValue]&&![[b updateVoice:bad] boolValue]);
 NSDictionary *gone=@{@"voiceId":@999,@"volume":@.2};assert([[a updateNote:gone] boolValue]&&[[b updateVoice:gone] boolValue]);
 destroyRig(a);destroyRig(b);
}
int main(void) { @autoreleasepool {
 identicalAttacks();sampleClockAndEdits();capacityStopAndQueue();variationStreamAndRejection();standaloneAndCancellation();acceptedSnapshotAndPanicOrdering();aliases();
 printf("Apple tone repetition: PCM parity, fractional clock, edits, overlap, capacity, independent stop, variation, priority rejection, aliases PASS (scheduler bytes=%zu)\n",sizeof(SynthToneTransport));
 }return 0; }
