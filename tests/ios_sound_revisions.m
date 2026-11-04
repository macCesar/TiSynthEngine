@interface RenderRig (SoundRevisionHook)
- (NSNumber *)_updateSoundOptions:(id)args;
@end
// Full accepted Sound revisions must not retain omitted historical fields.
static BOOL soundRevision(RenderRig *r,NSString *kind,NSDictionary *options) {
 if([r respondsToSelector:@selector(_updateSoundOptions:)])return [[r _updateSoundOptions:@{@"kind":kind,@"options":options}] boolValue];
 // Before the private hook exists, demonstrate the historical merge mismatch.
 return [kind isEqual:@"repeat"]?[[r updateTone:options] boolValue]:[[r updateSequence:options] boolValue];
}
static void revisionFrames(RenderRig *r,int count) {float out[2048];while(count){int frames=MIN(count,1024);render(r,frames,out,1);count-=frames;}}
static void repeatReplacement(void) {
 RenderRig *r=rig(16000);
 NSDictionary *initial=@{@"frequency":@440,@"waveType":@4,@"noiseRate":@1200,@"lowPassHz":@3000,@"duration":@20,@"attack":@1,@"release":@2,@"volume":@.05,@"intervalMs":@20,@"variation":@{@"seed":@42,@"ranges":@{@"volume":@[@.01,@.1]}}};
 int identifier=[[r repeatTone:initial] intValue];assert(identifier>0);revisionFrames(r,1);
 int slot=synth_tone_find(&r->tones,identifier);assert(slot>=0);
 double remaining=r->tones.slots[slot].remaining;uint64_t attack=r->tones.slots[slot].variationAttack;unsigned seed=r->tones.slots[slot].variationSeed;
 NSDictionary *full=@{@"toneId":@(identifier),@"frequency":@660,@"waveType":@4,@"duration":@20,@"attack":@1,@"release":@2,@"volume":@.05,@"intervalMs":@40};
 assert(soundRevision(r,@"repeat",full));
 assert(!r->toneOptions[@(identifier)][@"noiseRate"]&&!r->toneOptions[@(identifier)][@"lowPassHz"]&&!r->toneOptions[@(identifier)][@"variation"]);
 assert(r->tones.slots[slot].remaining==remaining&&r->tones.slots[slot].variationAttack==attack);
 assert([r->toneOptions[@(identifier)][@"_effectiveSeed"] unsignedIntValue]==seed);
 NSDictionary *accepted=r->toneOptions[@(identifier)];int pending=r->tones.slots[slot].pending;
 assert(!soundRevision(r,@"repeat",@{@"toneId":@(identifier),@"volume":@(-1),@"intervalMs":@40}));
 assert(r->toneOptions[@(identifier)]==accepted&&r->tones.slots[slot].pending==pending&&r->tones.slots[slot].remaining==remaining);
 uint64_t voices=r->voiceOrder;revisionFrames(r,319);assert(r->voiceOrder==voices);revisionFrames(r,1);assert(r->voiceOrder==voices+1);
 assert(r->tones.slots[slot].variationSeed==seed&&r->tones.slots[slot].variationAttack==attack);
 revisionFrames(r,639);assert(r->voiceOrder==voices+1);revisionFrames(r,1);assert(r->voiceOrder==voices+2);
 assert(([[r updateTone:@{@"toneId":@(identifier),@"noiseRate":@900}] boolValue]));
 assert(([[r updateTone:@{@"toneId":@(identifier),@"volume":@.03}] boolValue]));
 assert([r->toneOptions[@(identifier)][@"noiseRate"] intValue]==900);
 destroyRig(r);
}
static void patternReplacement(void) {
 RenderRig *r=rig(16000);
 NSDictionary *initial=@{@"timeUnit":@"ms",@"stepDuration":@100,@"loop":@YES,@"voice":@{@"waveType":@0,@"volume":@.03,@"attack":@1,@"release":@2,@"fmRatio":@2,@"fmDepth":@1,@"variation":@{@"seed":@42,@"ranges":@{@"volume":@[@.01,@.04]}},@"filterType":@"lowpass",@"filterHz":@1200,@"modulations":@[@{@"wave":@"sine",@"target":@"filterHz",@"rate":@1,@"depth":@.1}]},@"steps":@[@{@"notes":@[@60]},@{@"notes":@[@62]}]};
 int identifier=[[r playSequence:initial] intValue];assert(identifier>0);revisionFrames(r,31);
 int slot=synth_transport_find(r->sequence,identifier);assert(slot>=0);
 double beat=r->sequence->beat,ms=r->sequence->milliseconds;uint64_t voices=r->voiceOrder,generation=r->sequence->slots[slot].generation,attack=r->sequence->slots[slot].variationAttack;uint32_t revision=r->sequence->slots[slot].banks[r->sequence->slots[slot].active].revision;
 NSDictionary *full=@{@"sequenceId":@(identifier),@"timeUnit":@"ms",@"stepDuration":@100,@"loop":@YES,@"voice":@{@"waveType":@0,@"volume":@.03,@"attack":@1,@"release":@2,@"variation":initial[@"voice"][@"variation"]},@"steps":initial[@"steps"]};
 assert(soundRevision(r,@"pattern",full));NSDictionary *voice=r->sequenceOptions[@(identifier)][@"voice"];
 assert(!voice[@"fmRatio"]&&!voice[@"fmDepth"]&&!voice[@"filterType"]&&!voice[@"filterHz"]&&!voice[@"modulations"]);
 assert(r->sequence->beat==beat&&r->sequence->milliseconds==ms);
 NSDictionary *accepted=r->sequenceOptions[@(identifier)];NSMutableDictionary *invalid=[full mutableCopy];invalid[@"steps"]=@[@{@"notes":@[@0]}];
 assert(!soundRevision(r,@"pattern",invalid));assert(r->sequenceOptions[@(identifier)]==accepted);
 invalid=[full mutableCopy];[invalid removeObjectForKey:@"timeUnit"];assert(!soundRevision(r,@"pattern",invalid));assert(r->sequenceOptions[@(identifier)]==accepted);
 revisionFrames(r,1569);assert(r->voiceOrder==voices);revisionFrames(r,1);assert(r->voiceOrder==voices+1);
 assert(r->sequence->slots[slot].generation==generation&&r->sequence->slots[slot].variationAttack==attack+1);
 assert(r->sequence->slots[slot].banks[r->sequence->slots[slot].active].revision>revision);
 assert(([[r updateSequence:@{@"sequenceId":@(identifier),@"voice":@{@"filterType":@"lowpass",@"filterHz":@1500}}] boolValue]));
 revisionFrames(r,1);
 assert(([[r updateSequence:@{@"sequenceId":@(identifier),@"voice":@{@"volume":@.04}}] boolValue]));
 assert([r->sequenceOptions[@(identifier)][@"voice"][@"filterHz"] intValue]==1500);
 destroyRig(r);
}
int main(void) {setbuf(stdout,NULL);@autoreleasepool {repeatReplacement();patternReplacement();puts("Sound complete revisions: omitted fields removed, clocks/seeds preserved, invalid edits atomic, legacy merges intact PASS");return 0;}}
