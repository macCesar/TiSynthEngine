// Host callback cost only: no AVAudioEngine, device deadline or listening claim.
int main(void) { @autoreleasepool {
 printf("schedulerBytes=%zu commandBytes=%zu\n",sizeof(SynthToneTransport),sizeof(SynthCommand));
 for(int count=1;count<=32;count*=32)for(int spatial=0;spatial<2;spatial++) {
  RenderRig *r=rig(48000);
  for(int i=0;i<count;i++) {
   NSMutableDictionary *o=[@{@"intervalMs":@50,@"duration":@100,@"frequency":@(220+i*11),@"waveType":@1,@"volume":@.01,@"attack":@1,@"release":@10,@"variation":@{@"amount":@.5,@"seed":@(i+1),@"ranges":@{@"volume":@[@.005,@.015]}}} mutableCopy];
   if(spatial){o[@"spatialX"]=@.5;o[@"spatialY"]=@.2;}
   assert([[r repeatTone:o] intValue]>0);
  }
  float out[512];for(int i=0;i<100;i++)render(r,256,out,1);
  double cpu=seconds(CLOCK_THREAD_CPUTIME_ID),wall=seconds(CLOCK_MONOTONIC);
  for(int i=0;i<1000;i++)render(r,256,out,1);
  cpu=seconds(CLOCK_THREAD_CPUTIME_ID)-cpu;wall=seconds(CLOCK_MONOTONIC)-wall;
  printf("repetitions=%d spatial=%d callbackCpuSeconds=%.6f wallSeconds=%.6f hostLoad=%.6f\n",count,spatial,cpu,wall,cpu/(1000*256/48000.0));
  destroyRig(r);
 }
 }return 0; }
