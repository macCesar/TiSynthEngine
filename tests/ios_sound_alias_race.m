// Production identity lookup with a deterministic callback transition injected
// by run_sound_alias_race_ios.py at the final active-identity read.
static BOOL aliasRaceActive(RenderRig *r,int32_t identifier) {
 for(int i=0;i<r->engineMaxVoices;i++)if(r->voices[i].isActive&&r->voices[i].held.voiceId==identifier)return YES;
 return NO;
}
int main(void) { setbuf(stdout,NULL); @autoreleasepool {
 RenderRig *r=rig(48000);float output[1024];
 NSNumber *owned=[r _allocateSoundNote:nil];
 assert(([[r _soundHeld:@{@"operation":@"on",@"options":@{@"voiceId":owned,@"frequency":@440,@"volume":@.01,@"attack":@1,@"release":@10}}] boolValue]));
 render(r,64,output,1);
 assert(([[r noteOn:@{@"voiceId":owned,@"frequency":@660,@"volume":@.01,@"attack":@1,@"release":@10}] boolValue]));
 NSNumber *alias=r->legacyHeldIds[owned];assert(alias&&alias.intValue!=owned.intValue);
 aliasRaceRig=r;aliasRaceTarget=alias.intValue;aliasRaceArmed=YES;
 assert(([[r noteOff:@{@"voiceId":owned}] boolValue]));
 assert(aliasRaceFired&&"the pending-to-active callback transition must run");
 printf("alias before=%d after=%d callbackTransition=%d\n",alias.intValue,[r->legacyHeldIds[owned] intValue],aliasRaceFired);
 assert([r->legacyHeldIds[owned] intValue]==alias.intValue&&"identity lookup lost an alias during pending-to-active transition");
 render(r,512,output,1);
 assert(!aliasRaceActive(r,alias.intValue)&&aliasRaceActive(r,owned.intValue));
 [r _allocateSoundNote:nil];assert(r->legacyHeldIds.count==0&&r->claimedHeldIds.count==0);
 aliasRaceRig=nil;destroyRig(r);
 // A queued retrigger's newest timbre wins over the currently sounding source.
 r=rig(48000);
 assert(([[r noteOn:@{@"voiceId":@17,@"frequency":@440,@"waveType":@0}] boolValue]));render(r,64,output,1);
 assert(([[r noteOn:@{@"voiceId":@17,@"frequency":@440,@"waveType":@1}] boolValue]));
 assert(([[r noteOn:@{@"voiceId":@17,@"frequency":@440,@"waveType":@3}] boolValue]));
 assert([r voiceMaskForId:17]==(int)synth_live_allowed(3,0));destroyRig(r);
 puts("Apple alias race: pending-to-active identity retained, isolated release, newest pending mask PASS");
 return 0;
}}
