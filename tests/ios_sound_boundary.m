// Executed against extracted production methods and the actual Apple callback.
static void heldPcmParity(void) {
 for(int wave=0;wave<6;wave++)for(int spatial=0;spatial<2;spatial++) {
  RenderRig *old=rig(44100),*modern=rig(44100);
  NSMutableDictionary *legacy=[@{@"voiceId":@17,@"frequency":@440,@"volume":@.04,@"waveType":@(wave),@"attack":@8,@"release":@45,
      @"variation":@{@"seed":@123,@"ranges":@{@"volume":@[@.03,@.05],@"pitchCents":@[@(-8),@8]}}} mutableCopy];
  if(wave==5)legacy[@"waveTable"]=@[@(-1),@(-.2),@.7,@1];
  if(wave==0){legacy[@"fmRatio"]=@2;legacy[@"fmDepth"]=@1;}
  if(spatial){legacy[@"spatialX"]=@.4;legacy[@"spatialY"]=@(-.2);}
  NSMutableDictionary *current=[legacy mutableCopy];current[@"voiceId"]=[modern _allocateSoundNote:nil];
  assert([[old noteOn:legacy] boolValue]);assert(([[modern _soundHeld:@{@"operation":@"on",@"options":current}] boolValue]));
  float a[1024],b[1024];
  for(int block=0;block<32;block++) {
   if(block==4) {
    NSMutableDictionary *before=[@{@"voiceId":@17,@"volume":@.02,@"frequency":@660} mutableCopy];
    if(wave==0){before[@"fmDepth"]=@0;before[@"fmRatio"]=@1;}
    NSMutableDictionary *after=[before mutableCopy];after[@"voiceId"]=current[@"voiceId"];
    assert([[old updateNote:before] boolValue]);assert(([[modern _soundHeld:@{@"operation":@"update",@"options":after}] boolValue]));
   }
   if(block==8) {
    assert([[old noteOff:@{@"voiceId":@17}] boolValue]);
    assert(([[modern _soundHeld:@{@"operation":@"off",@"options":@{@"voiceId":current[@"voiceId"]}}] boolValue]));
   }
   int frames=block%2?257:113;render(old,frames,a,1);render(modern,frames,b,1);assert(!memcmp(a,b,(size_t)frames*2*sizeof(float)));
  }
  destroyRig(old);destroyRig(modern);
 }
}
int main(void) { @autoreleasepool {
 RenderRig *cold=[RenderRig new];
 assert(([cold _validateSoundOptions:@{@"kind":@"processing",@"options":@{}}]==nil));
 heldPcmParity();
 RenderRig *r=rig(48000);
 assert(([r _validateSoundOptions:@{@"kind":@"tone",@"options":@{@"volume":@.2}}]==nil));
 assert(([r _validateSoundOptions:@{@"kind":@"tone",@"options":@{@"volume":@(-1)}}]!=nil));
 assert([r _soundNoteToMidi:@"C4"].intValue==60);
 int owned=[r _allocateSoundNote:nil].intValue;assert(owned>0);
 assert([r heldIdentifier:owned]!=owned);
 assert([r _allocateSoundNote:nil].intValue!=owned);
 NSUInteger claims=r->claimedHeldIds.count;for(int i=0;i<1000;i++)assert([r _allocateSoundNote:nil].intValue>0);
 assert(r->claimedHeldIds.count==claims);
 assert([[r setVolume:@.5] boolValue]);
 assert([[r setVolume:@{@"volume":@.5}] boolValue]);
 assert(([[r _soundHeld:@{@"operation":@"on",@"options":@{@"voiceId":@(owned),@"frequency":@440,@"volume":@.02}}] boolValue]));
 float out[512];render(r,128,out,1);
 assert(([[r _soundHeld:@{@"operation":@"off",@"options":@{@"voiceId":@(owned)}}] boolValue]));
 render(r,128,out,1);
 double generation=[[r _soundRuntime:nil][@"generation"] doubleValue];
 [r invalidateSoundControls];assert([[r _soundRuntime:nil][@"generation"] doubleValue]>generation);
 destroyRig(r);
 puts("Apple Sound boundary: pure validation, signatures, owned identities, held rendering and generation PASS");
 return 0;
}}
