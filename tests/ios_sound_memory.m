// Actual production public methods and Apple render callback, no audio device.
static void memoryCycles(RenderRig *r,BOOL modern) {
 float out[1024];
 for(int batch=0;batch<4;batch++) {
  @autoreleasepool {
   for(int i=0;i<1000;i++) {
    NSNumber *identifier=modern?[r _allocateSoundNote:nil]:@(1+batch*1000+i);
    NSDictionary *options=@{@"voiceId":identifier,@"frequency":@440,@"volume":@.01,@"attack":@1,@"release":@10};
    BOOL admitted=modern?[[r _soundHeld:@{@"operation":@"on",@"options":options}] boolValue]:[[r noteOn:options] boolValue];
    assert(admitted);render(r,64,out,1);
    NSDictionary *off=@{@"voiceId":identifier};
    assert((modern?[[r _soundHeld:@{@"operation":@"off",@"options":off}] boolValue]:[[r noteOff:off] boolValue]));
    render(r,512,out,1);
   }
  }
  printf("%s admitted/released batch=%d maps=%lu claims=%lu generations=%lu positions=%lu spatial=%lu\n",modern?"modern":"legacy",batch,(unsigned long)r->legacyHeldIds.count,(unsigned long)r->claimedHeldIds.count,(unsigned long)r->voiceGenerations.count,(unsigned long)r->voicePositions.count,(unsigned long)r->voiceSpatialModes.count);
 }
}
static BOOL activeHeld(RenderRig *r,int32_t identifier) {
 for(int i=0;i<r->engineMaxVoices;i++)if(r->voices[i].isActive&&r->voices[i].held.voiceId==identifier)return YES;
 return NO;
}
static void collisionCycles(BOOL legacyFirst,BOOL renderBeforeCollision) {
 RenderRig *r=rig(48000);float out[1024];
 NSNumber *publicLegacy=@(INT32_MAX),*owned=nil;
 NSDictionary *legacy=@{@"voiceId":publicLegacy,@"frequency":@660,@"volume":@.01,@"attack":@1,@"release":@10};
 if(legacyFirst)assert([[r noteOn:legacy] boolValue]);
 else {
  owned=[r _allocateSoundNote:nil];
  assert(([[r _soundHeld:@{@"operation":@"on",@"options":@{@"voiceId":owned,@"frequency":@440,@"volume":@.01,@"attack":@1,@"release":@10}}] boolValue]));
 }
 if(renderBeforeCollision)render(r,64,out,1);
 if(legacyFirst) {
  owned=[r _allocateSoundNote:nil];assert(owned.intValue!=publicLegacy.intValue);
  assert(([[r _soundHeld:@{@"operation":@"on",@"options":@{@"voiceId":owned,@"frequency":@440,@"volume":@.01,@"attack":@1,@"release":@10}}] boolValue]));
 }else assert([[r noteOn:legacy] boolValue]);
 NSNumber *alias=r->legacyHeldIds[publicLegacy];assert(alias&&alias.intValue!=owned.intValue);
 assert([r voiceMaskForId:alias.intValue]>=0&&[r voiceMaskForId:owned.intValue]>=0);
 for(int i=0;i<32;i++) {
  if(i%8==0)assert([[r noteOn:legacy] boolValue]);
  assert(([[r updateNote:@{@"voiceId":publicLegacy,@"volume":@.02}] boolValue]));
  assert([r heldIdentifier:publicLegacy.intValue]==alias.intValue);
  assert(r->legacyHeldIds.count==1&&r->claimedHeldIds.count==1);
 }
 assert((![[r _soundHeld:@{@"operation":@"off",@"options":@{@"voiceId":alias}}] boolValue]));
 render(r,64,out,1);assert(activeHeld(r,owned.intValue)&&activeHeld(r,alias.intValue));
 assert(([[r noteOff:@{@"voiceId":publicLegacy}] boolValue]));render(r,512,out,1);
 assert(!activeHeld(r,alias.intValue)&&activeHeld(r,owned.intValue));
 assert([r voiceMaskForId:alias.intValue]<0&&[r voiceMaskForId:owned.intValue]>=0);
 [r _allocateSoundNote:nil];assert(r->legacyHeldIds.count==0&&r->claimedHeldIds.count==0);
 assert(([[r _soundHeld:@{@"operation":@"off",@"options":@{@"voiceId":owned}}] boolValue]));render(r,512,out,1);
 assert(!activeHeld(r,owned.intValue));
 printf("collision order=%s phase=%s stable aliases, scoped release, retirement PASS\n",legacyFirst?"legacy-first":"modern-first",renderBeforeCollision?"rendered":"pending");destroyRig(r);
}
int main(void) { setbuf(stdout,NULL); @autoreleasepool {
 for(int order=0;order<2;order++)for(int rendered=0;rendered<2;rendered++)collisionCycles(order,rendered);
 RenderRig *modern=rig(48000);memoryCycles(modern,YES);
 assert(modern->legacyHeldIds.count==0&&modern->claimedHeldIds.count==0);
 destroyRig(modern);
 RenderRig *legacy=rig(48000);memoryCycles(legacy,NO);
 NSUInteger retained=legacy->legacyHeldIds.count+legacy->claimedHeldIds.count;
 destroyRig(legacy);
 assert(retained==0&&"completed legacy notes retain identity bookkeeping indefinitely");
 puts("Apple Sound memory: bounded admitted/released bookkeeping PASS");
 return 0;
}}
