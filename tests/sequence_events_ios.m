// Included after the unchanged production event/publication methods by the runner.
#define CHECK(value, message) do { if(!(value)){fprintf(stderr,"FAIL: %s\n",message);exit(1);} } while(0)
static NSDictionary *score(void) {
  return @{@"loop":@YES,@"steps":@[@{@"notes":@[@60]}]};
}
static void retire(TiSynthengineModule *rig) {
  synth_transport_begin_block(rig->sequence);
  synth_transport_stop_all(rig->sequence);
  synth_transport_begin_block(rig->sequence);
}
static void checkHeldRetirement(TiSynthengineModule *rig) {
  [rig startHarness];
  rig->commandQueue[0].type=SYNTH_CMD_HELD_ON;rig->commandQueue[0].voiceId=42;
  atomic_store(&rig->commandReadIndex,0);atomic_store(&rig->commandWriteIndex,1);
  [rig publishHeldMetadata];
  CHECK(rig->sequenceEventTimer,"accepted held voice schedules metadata cleanup");
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
    CHECK(rig->voiceGenerations.count==1,"queued held voice metadata must survive");
    synth_identity_set(&rig->identities[0],42,1);
    atomic_store(&rig->commandReadIndex,1);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
      CHECK(rig->voiceGenerations.count==1,"active held voice metadata must survive");
      synth_identity_set(&rig->identities[0],0,0);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,40*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        CHECK(!rig->voiceGenerations.count&&!rig->voicePositions.count&&!rig->voiceSpatialModes.count,"retired held voice metadata must be reclaimed");
        CHECK(!rig->sequenceEventTimer,"last held retirement must return to idle");
        [rig shutdownHarness];
        puts("iOS sequence events: idle, publication, retirement, reentry and held cleanup PASS");
        exit(0);
      });
    });
  });
}
int main(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    TiSynthengineModule *rig=[TiSynthengineModule new];[rig startHarness];
    CHECK(!rig->sequenceEventTimer,"an idle start must not schedule event polls");
    CHECK(![[rig publishSequence:@{@"steps":@[]} restart:YES] boolValue],"invalid sequence rejected");
    CHECK(!rig->sequenceEventTimer,"rejected publications must not start polling");
    NSNumber *first=[rig publishSequence:score() restart:YES];
    CHECK(first.intValue>0&&rig->sequenceEventTimer,"accepted sequence starts polling");
    dispatch_source_t timer=rig->sequenceEventTimer;
    NSNumber *second=[rig publishSequence:score() restart:YES];
    CHECK(second.intValue>first.intValue&&timer==rig->sequenceEventTimer,"concurrent sequences share one timer");
    retire(rig);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
      CHECK(rig->delivered.count==2,"both stopped sequences must deliver an event");
      CHECK([rig->delivered[0][@"reason"] isEqual:@"stopped"],"retirement reason preserved");
      CHECK(!rig->sequenceEventTimer,"last end event must stop polling");
      // Re-enter synchronously, as an event sink is allowed to do. The old drain
      // must not consume the replacement engine's already-pending end event.
      [rig->delivered removeAllObjects];
      [rig publishSequence:score() restart:YES];retire(rig);
      __weak TiSynthengineModule *owner=rig;
      rig->onEnd=^(NSDictionary *event){
        (void)event;TiSynthengineModule *r=owner;r->onEnd=nil;
        [r shutdownHarness];[r startHarness];
        [r publishSequence:score() restart:YES];retire(r);
      };
      [rig drainSequenceEvents];
      CHECK(rig->delivered.count==1,"old drain must not consume new engine events");
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,80*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        CHECK(rig->delivered.count==2,"new engine event must arrive exactly once");
        CHECK(!rig->sequenceEventTimer,"replacement engine returns to idle");
        [rig publishSequence:score() restart:YES];retire(rig);
        rig->onEnd=^(NSDictionary *event){(void)event;TiSynthengineModule *r=owner;r->onEnd=nil;[r shutdownHarness];};
        [rig drainSequenceEvents];
        CHECK(!rig->sequence&&!rig->sequenceEventTimer,"shutdown from listener cancels polling safely");
        checkHeldRetirement(rig);
      });
    });
  });
  dispatch_main();
}
