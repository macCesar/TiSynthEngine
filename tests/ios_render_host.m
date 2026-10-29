// Included after the production ObjC helpers, ivars, methods and render body
// by build_ios_render_host.py. No replacement DSP implementation lives here.
static BOOL traceBytes;
static uint64_t hashBytes(uint64_t h,const void *data,size_t size) {
 if(traceBytes){assert(fwrite(data,1,size,stdout)==size);return h;}
 const unsigned char *p=data;while(size--){h^=*p++;h*=1099511628211ULL;}return h;
}
#define HASH(h, value) ((h)=hashBytes((h),&(value),sizeof(value)))
static double seconds(clockid_t clock) {struct timespec t;assert(!clock_gettime(clock,&t));return t.tv_sec+t.tv_nsec*1e-9;}
static RenderRig *rig(double rate) {
 RenderRig *r=[RenderRig new];r->engineMaxVoices=32;r->engineSampleRate=rate;
 r->mixingProfile=MIXING_PROFILE_CONSERVATIVE;r->lookaheadSize=MAX(1,(int)round(rate*.01));
 r->lookaheadL=calloc(r->lookaheadSize,sizeof(double));r->lookaheadR=calloc(r->lookaheadSize,sizeof(double));
 r->lookaheadPeaks=calloc(r->lookaheadSize+1,sizeof(double));r->lookaheadPeakIndices=calloc(r->lookaheadSize+1,sizeof(int64_t));
 r->sequence=calloc(1,sizeof(SynthTransport));assert(r->sequence);synth_transport_init(r->sequence,rate,4);
 assert(synth_effects_init(&r->effects,rate));r->processingOptions=synth_effects_default_config();
 r->voiceGenerations=[NSMutableDictionary dictionary];r->voicePositions=[NSMutableDictionary dictionary];r->voiceSpatialModes=[NSMutableDictionary dictionary];
 r->sequenceOptions=[NSMutableDictionary dictionary];r->warningKeys=[NSMutableSet set];r->audioEngine=(AVAudioEngine *)[NSObject new];
 synth_stats_init(&r->stats);mach_timebase_info(&r->statsTimebase);
 r->commandProducerLock=OS_UNFAIR_LOCK_INIT;r->gainReleaseCoeff=1-exp(-1/(.1*rate));
 r->stopFadeSamples=MAX(1,MsToSamples(20,rate));r->stealFadeSamples=MAX(1,MsToSamples(6,rate));
 atomic_store(&r->masterVolume,1);[r clearVoices];return r;
}
static void destroyRig(RenderRig *r) {
#ifdef SYNTH_HOST_HAS_EVENT_POLL
 [r cancelSequencePoll];
#endif
 synth_effects_destroy(&r->effects);free(r->sequence);r->sequence=NULL;
 free(r->lookaheadL);free(r->lookaheadR);free(r->lookaheadPeaks);free(r->lookaheadPeakIndices);
}
static SynthCommand tone(RenderRig *r,int index,int wave,BOOL spatial,BOOL held) {
 SynthCommand c={0};c.type=held?SYNTH_CMD_HELD_ON:CMD_NOTE_ON;c.voiceId=held?index+1:0;
 c.voiceGeneration=index+1;c.frequency=110+index*11;c.durationSamples=(int)(r->engineSampleRate*.04);
 c.attackSamples=MsToSamples(2,r->engineSampleRate);c.releaseSamples=MsToSamples(12,r->engineSampleRate);
 c.decaySamples=MsToSamples(4,r->engineSampleRate);c.sustain=.6;c.volume=.03;c.eventVoiceCount=1;c.waveType=wave;
 c.pulseWidth=.3;c.fmRatio=2;c.fmDepth=wave==0?1:0;c.filterHz=1200;c.filterQ=.8;c.pan=c.panEnd=(index%7-3)/3.0;
 c.noiseRate=1200;c.lowPassHz=3000;c.spatial=spatial;c.spatialX=.6;c.spatialY=-.4;c.effectSend=-1;c.bus=1;
 c.wavetableSize=4;c.wavetable[0]=-1;c.wavetable[1]=-.2;c.wavetable[2]=.7;c.wavetable[3]=1;
 return c;
}
// Semantic snapshots omit pointers, padding after the last original voice field
// and optional diagnostic wall time. All original voice/filter/FIR fields remain.
static uint64_t stateHash(RenderRig *r) {
 uint64_t h=1469598103934665603ULL;
 for(int i=0;i<32;i++) {
  h=hashBytes(h,&r->voices[i],offsetof(SynthVoice,fmDepthDelta)+sizeof(double));
  h=hashBytes(h,&r->tails[i],sizeof(TailVoice));HASH(h,r->identities[i]);
 }
 HASH(h,r->voiceOrder);HASH(h,r->sequenceVoiceId);HASH(h,r->batchOrder);HASH(h,r->batchRemaining);
 HASH(h,r->commandReadIndex);HASH(h,r->commandWriteIndex);
 HASH(h,r->smoothedMasterGain);HASH(h,r->masterGainTarget);HASH(h,r->masterGainStep);HASH(h,r->masterGainFramesRemaining);
 HASH(h,r->smoothedGain);HASH(h,r->limiterAttackTarget);HASH(h,r->limiterAttackStep);
 HASH(h,r->lookaheadIdx);HASH(h,r->lookaheadPeakHead);HASH(h,r->lookaheadPeakCount);HASH(h,r->limiterSampleIndex);
 h=hashBytes(h,r->lookaheadL,r->lookaheadSize*sizeof(double));h=hashBytes(h,r->lookaheadR,r->lookaheadSize*sizeof(double));
 h=hashBytes(h,r->lookaheadPeaks,(r->lookaheadSize+1)*sizeof(double));h=hashBytes(h,r->lookaheadPeakIndices,(r->lookaheadSize+1)*sizeof(int64_t));
 SynthEffects *fx=&r->effects;HASH(h,fx->config);HASH(h,fx->current);HASH(h,fx->step);
 h=hashBytes(h,&fx->chorusGate,sizeof(*fx)-offsetof(SynthEffects,chorusGate));
 for(int i=0;i<16;i++) {
  // Ring arrays are adjacent, but each array is indexed within its own bounds.
  SynthEffectRing *ring=i<2?&fx->chorus[i]:i<4?&fx->delay[i-2]:i<12?&fx->comb[(i-4)/4][(i-4)%4]:&fx->allpass[(i-12)/2][(i-12)%2];
  HASH(h,ring->size);HASH(h,ring->position);HASH(h,ring->epoch);
  h=hashBytes(h,ring->values,ring->size*sizeof(double));h=hashBytes(h,ring->tags,((ring->size+15)/16)*sizeof(uint64_t));
 }
 h=hashBytes(h,r->sequence,sizeof(*r->sequence));
 HASH(h,r->stats.active);HASH(h,r->stats.tails);HASH(h,r->stats.spatial);HASH(h,r->stats.steals);HASH(h,r->stats.peakActive);
 return h;
}
static void render(RenderRig *r,int frames,float *output,int layout) {
 struct {AudioBufferList list;AudioBuffer extra;} buffers={0};
 buffers.list.mNumberBuffers=layout==0?2:1;
 buffers.list.mBuffers[0]=(AudioBuffer){layout==1?2u:1u,(UInt32)(frames*sizeof(float)*(layout==1?2:1)),output};
 if(layout==0)buffers.extra=(AudioBuffer){1,(UInt32)(frames*sizeof(float)),output+frames};
 assert([r render:(AVAudioFrameCount)frames output:&buffers.list]==noErr);
}
static void sequence(RenderRig *r,int id,int mode,BOOL spatial,BOOL fx) {
 SynthSequenceConfig *c=synth_transport_begin_write(r->sequence,id,1);assert(c);
 c->stepCount=3;c->loop=1;c->timeUnit=id%2?SYNTH_SEQUENCE_BEATS:SYNTH_SEQUENCE_MS;
 c->stepDuration=c->timeUnit==SYNTH_SEQUENCE_MS?8:.016;c->swing=.3;c->mode=mode;
 for(int j=0;j<3;j++) {
  SynthSequenceStep *s=&c->steps[j];s->noteCount=8;s->gate=.8;s->voice.volume=.01;s->voice.attack=1;s->voice.decay=4;s->voice.sustain=.4;s->voice.release=10;
  s->voice.waveType=1;s->voice.filterType=1;s->voice.filterHz=1200;s->voice.filterQ=.8;
  s->voice.spatial=spatial;s->voice.spatialX=.6;s->voice.spatialY=-.4;
  if(fx){s->voice.mods[0]=1;s->voice.mods[2]=0;s->voice.mods[3]=2;s->voice.mods[4]=.3;s->voice.mods[6]=1;s->voice.mods[8]=1;s->voice.mods[9]=3;s->voice.mods[10]=.3;}
  for(int n=0;n<8;n++)s->notes[n]=(uint8_t)(36+id*8+n+j);
 }
 assert(synth_transport_commit(r->sequence,c,1));
}
static void fixtures(void) {
 const int rates[]={16000,44100,48000,96000,192000},sizes[]={0,1,3,4,7,8,9,15,16,17,23,31,256,512,1024};
 for(unsigned rate=0;rate<5;rate++)for(int kind=0;kind<24;kind++) {
  @autoreleasepool {
  RenderRig *r=rig(rates[rate]);BOOL spatial=kind&1,held=kind>=4,fx=kind>=8;
  int voices=kind<2?0:kind<4?1:32;
  if(kind==10||kind==11){for(int id=1;id<=4;id++)sequence(r,id,kind%4,spatial,fx);voices=0;}
  if(fx){SynthCommand c={0};c.type=7;c.processing=synth_effects_default_config();c.processing.inputGain=.8;c.processing.chorus.enabled=c.processing.delay.enabled=c.processing.reverb.enabled=c.processing.saturation.enabled=1;assert(![r enqueueCommand:c]);}
  if(kind>=12)voices=kind<18?1:32;
  for(int i=0;i<voices;i++){
   SynthCommand c=tone(r,i,kind%6,spatial,held);if(fx||kind==4||kind==5)c.effectSend=i%3==0?0:i%3==1?.37:1;
   if(kind>=12){c.filterType=1;c.hasModulations=YES;c.modulation=synth_modulation_default_config();
    for(int j=0;j<2;j++){c.modulation.lfo[j].enabled=1;c.modulation.lfo[j].depth=.2;c.modulation.lfo[j].rateHz=2+j;c.modulation.lfo[j].waveform=j;c.modulation.lfo[j].target=c.waveType==0?2:c.waveType==1?1:0;}}
   assert(![r enqueueCommand:c]);
  }
  uint64_t pcm=1469598103934665603ULL,states=pcm;float output[2048]={0};
  for(int block=0;block<180;block++) {
   if(block==35&&held) {SynthCommand c={0};c.type=SYNTH_CMD_HELD_UPDATE;c.voiceId=1;c.voiceGeneration=1;c.liveMask=(1u<<LIVE_VOLUME)|(1u<<LIVE_FREQUENCY);c.liveValues[LIVE_VOLUME]=.02;c.liveValues[LIVE_FREQUENCY]=440;
    c.hasSendUpdate=YES;c.effectSend=.63;
    if(kind>=12){c.liveMask|=(1u<<LIVE_FILTER_HZ)|(1u<<LIVE_FILTER_Q);c.liveValues[LIVE_FILTER_HZ]=2200;c.liveValues[LIVE_FILTER_Q]=1.3;}
    assert(![r enqueueCommand:c]);}
   if(block==50&&spatial) {SynthCommand c={0};c.type=SYNTH_CMD_HELD_UPDATE;c.voiceId=1;c.voiceGeneration=1;c.hasSpatialUpdate=YES;synth_spatial_prepare(&c.preparedSpatial,-.5,.7,r->engineSampleRate);assert(![r enqueueCommand:c]);}
   if(block==60)atomic_store(&r->masterVolume,.7);
   if(block==70&&held)for(int i=0;i<8;i++){SynthCommand c=tone(r,i,kind%6,spatial,YES);c.voiceGeneration+=100;assert(![r enqueueCommand:c]);}
   if(block==80&&kind>=12){SynthCommand c={0};c.type=SYNTH_CMD_HELD_UPDATE;c.voiceId=1;c.voiceGeneration=101;c.hasModulations=YES;c.modulation=synth_modulation_default_config();assert(![r enqueueCommand:c]);}
   if(block==85&&held)for(int i=0;i<32;i++){SynthCommand c={0};c.type=SYNTH_CMD_HELD_OFF;c.voiceId=i+1;c.voiceGeneration=i<8?i+101:i+1;assert(![r enqueueCommand:c]);}
   if(block==100&&fx){SynthCommand c={0};c.type=7;c.processing=synth_effects_default_config();assert(![r enqueueCommand:c]);}
   if(block==120){SynthCommand c={0};c.type=CMD_STOP_ALL;assert(![r enqueueCommand:c]);}
   int count=sizes[block%(sizeof(sizes)/sizeof(sizes[0]))],layout=block%3;memset(output,0,sizeof(output));render(r,count,output,layout);
   pcm=hashBytes(pcm,output,(layout==2?count:count*2)*sizeof(float));
   if(block%15==0||block==179){uint64_t state=stateHash(r);HASH(states,state);}
  }
  if(fx) {
   // Reach the quiet FX state after panic, then enable processing again. A
   // bypass may neither freeze hidden ramps nor leave stale history behind.
   for(int frame=0;frame<(int)(r->engineSampleRate*.25);frame+=256){render(r,256,output,0);pcm=hashBytes(pcm,output,256*2*sizeof(float));}
   uint64_t state=stateHash(r);HASH(states,state);
   SynthCommand processing={0};processing.type=7;processing.processing=synth_effects_default_config();processing.processing.inputGain=1.2;processing.processing.chorus.enabled=1;
   assert(![r enqueueCommand:processing]);SynthCommand c=tone(r,0,1,spatial,YES);c.effectSend=.27;assert(![r enqueueCommand:c]);
   for(int block=0;block<6;block++){render(r,256,output,0);pcm=hashBytes(pcm,output,256*2*sizeof(float));}
   state=stateHash(r);HASH(states,state);
  }
  printf("rate=%d kind=%d pcm=%016llx state=%016llx\n",rates[rate],kind,(unsigned long long)pcm,(unsigned long long)states);
  destroyRig(r);
  }
 }
}
static int cmpDouble(const void *a,const void *b){double x=*(const double*)a,y=*(const double*)b;return (x>y)-(x<y);}
static void benchmark(int kind,int loops,int frames) {
 assert(frames>=1&&frames<=1024);BOOL heldSine=kind==8||kind==9;
 RenderRig *r=rig(48000);BOOL spatial=kind&1;int voices=kind<2?0:kind<4?1:32;
 if(kind>=6&&!heldSine)for(int id=1;id<=4;id++)sequence(r,id,0,spatial,YES);
 else for(int i=0;i<voices;i++){SynthCommand c=tone(r,i,1,spatial,YES);
  if(heldSine){c=(SynthCommand){0};c.type=SYNTH_CMD_HELD_ON;c.voiceId=i+1;c.voiceGeneration=i+1;c.frequency=220*pow(2,i/12.0);c.attackSamples=MsToSamples(2,r->engineSampleRate);c.releaseSamples=MsToSamples(30,r->engineSampleRate);c.sustain=1;c.volume=.01;c.eventVoiceCount=1;c.waveType=0;c.pulseWidth=.5;c.spatial=spatial;c.spatialX=.6;c.spatialY=-.4;c.effectSend=-1;c.bus=1;}
  assert(![r enqueueCommand:c]);}
 if(heldSine)atomic_store(&r->masterVolume,.15);
 if(kind>=6&&!heldSine){SynthCommand c={0};c.type=7;c.processing=synth_effects_default_config();c.processing.chorus.enabled=c.processing.delay.enabled=c.processing.reverb.enabled=c.processing.saturation.enabled=1;assert(![r enqueueCommand:c]);}
 // Fixed per-scenario warmups are identical for the paired binaries. Thirty
 // idle blocks were too short to warm a process before a millisecond trial.
 int warmBlocks=kind==0?10000:kind==2?8000:kind==3?2000:kind==4?1000:kind==6?512:256;
 if(heldSine)warmBlocks=(48000*10+frames-1)/frames;
 float output[2048];for(int n=0;n<warmBlocks;n++)render(r,frames,output,0);
 double *wall=calloc(loops,sizeof(double)),*cpu=calloc(loops,sizeof(double)),wallTotal=0,cpuTotal=0;
 for(int n=0;n<loops;n++) {
  double c=seconds(CLOCK_THREAD_CPUTIME_ID),w=seconds(CLOCK_MONOTONIC);render(r,frames,output,0);
  wall[n]=seconds(CLOCK_MONOTONIC)-w;cpu[n]=seconds(CLOCK_THREAD_CPUTIME_ID)-c;wallTotal+=wall[n];cpuTotal+=cpu[n];
 }
 qsort(wall,loops,sizeof(double),cmpDouble);qsort(cpu,loops,sizeof(double),cmpDouble);
 struct rusage usage;getrusage(RUSAGE_SELF,&usage);
 printf("{\"kind\":%d,\"blocks\":%d,\"warmupBlocks\":%d,\"framesPerBlock\":%d,\"wallSeconds\":%.9g,\"cpuSeconds\":%.9g,\"wallP95\":%.9g,\"cpuP95\":%.9g,\"wallMax\":%.9g,\"cpuMax\":%.9g,\"peakRssBytes\":%ld}\n",kind,loops,warmBlocks,frames,wallTotal,cpuTotal,wall[(loops*95-1)/100],cpu[(loops*95-1)/100],wall[loops-1],cpu[loops-1],usage.ru_maxrss);
 free(wall);free(cpu);destroyRig(r);
}
static void pruneBenchmark(int loops) {
 RenderRig *r=rig(48000);malloc_statistics_t before,after;
 malloc_zone_statistics(NULL,&before);double c=seconds(CLOCK_THREAD_CPUTIME_ID),w=seconds(CLOCK_MONOTONIC);
 for(int i=0;i<loops;i++)[r pruneVoiceMetadata];
 double wall=seconds(CLOCK_MONOTONIC)-w,cpu=seconds(CLOCK_THREAD_CPUTIME_ID)-c;malloc_zone_statistics(NULL,&after);
 printf("{\"loops\":%d,\"wallSeconds\":%.9g,\"cpuSeconds\":%.9g,\"retainedAllocationBlocks\":%lld,\"retainedAllocationBytes\":%lld}\n",loops,wall,cpu,(long long)after.blocks_in_use-before.blocks_in_use,(long long)after.size_in_use-before.size_in_use);
 r->voiceGenerations[@1]=@1;r->voicePositions[@1]=@[@0,@0];r->voiceSpatialModes[@1]=@NO;
 [r pruneVoiceMetadata];assert(!r->voiceGenerations.count&&!r->voicePositions.count&&!r->voiceSpatialModes.count);
 destroyRig(r);
}
static void producerBenchmark(int steps,int loops) {
 RenderRig *r=rig(48000);NSMutableArray *score=[NSMutableArray array];
 for(int i=0;i<steps;i++){NSMutableArray *notes=[NSMutableArray array];for(int j=0;j<32;j++)[notes addObject:@(36+(i+j)%60)];[score addObject:@{@"notes":notes}];}
 NSDictionary *options=@{@"steps":score,@"loop":@YES,@"mode":@"up"};
 assert([[r publishSequence:options restart:YES] intValue]==1);synth_transport_begin_block(r->sequence);
 NSMutableDictionary *changes=[options mutableCopy];changes[@"sequenceId"]=@1;
 double *cpu=calloc(loops,sizeof(double)),*wall=calloc(loops,sizeof(double)),ct=0,wt=0;
 for(int i=0;i<loops+10;i++) {@autoreleasepool {
  double c=seconds(CLOCK_THREAD_CPUTIME_ID),w=seconds(CLOCK_MONOTONIC);assert([[r publishSequence:changes restart:NO] boolValue]);
  double elapsed=seconds(CLOCK_MONOTONIC)-w,work=seconds(CLOCK_THREAD_CPUTIME_ID)-c;
  if(i>=10){cpu[i-10]=work;wall[i-10]=elapsed;ct+=work;wt+=elapsed;}
  synth_transport_begin_block(r->sequence);r->sequence->slots[0].beat=r->sequence->slots[0].nextBeat;
  SynthSequenceEvent event;synth_transport_tick(r->sequence,0,&event);
 }}
 SynthSequenceTransport *slot=&r->sequence->slots[0];uint64_t h=hashBytes(1469598103934665603ULL,&slot->banks[slot->active],sizeof(SynthSequenceConfig));
 qsort(cpu,loops,sizeof(double),cmpDouble);qsort(wall,loops,sizeof(double),cmpDouble);struct rusage usage;getrusage(RUSAGE_SELF,&usage);
 printf("{\"steps\":%d,\"loops\":%d,\"cpuSeconds\":%.9g,\"wallSeconds\":%.9g,\"cpuP95\":%.9g,\"wallP95\":%.9g,\"cpuMax\":%.9g,\"wallMax\":%.9g,\"peakRssBytes\":%ld,\"state\":\"%016llx\"}\n",steps,loops,ct,wt,cpu[(loops*95-1)/100],wall[(loops*95-1)/100],cpu[loops-1],wall[loops-1],usage.ru_maxrss,(unsigned long long)h);
 free(cpu);free(wall);destroyRig(r);
}
static void metadataRegression(void) {
 RenderRig *r=rig(48000);float output[2];
 for(int i=1;i<=1000;i++) {
  assert(([[r updateVoice:@{@"voiceId":@(10000+i),@"spatialX":@.5}] boolValue]));
  render(r,0,output,0);[r pruneVoiceMetadata];
 }
 assert(!r->voiceGenerations.count&&!r->voicePositions.count&&!r->voiceSpatialModes.count);
 SynthCommand c=tone(r,0,0,YES,YES);assert(![r enqueueCommand:c]);
 r->voiceGenerations[@1]=@1;r->voicePositions[@1]=@[@.6,@(-.4)];r->voiceSpatialModes[@1]=@YES;
 [r pruneVoiceMetadata];assert(r->voiceGenerations.count==1);
 assert(([[r updateVoice:@{@"voiceId":@1,@"spatialX":@.7}] boolValue]));
 render(r,1,output,0);[r pruneVoiceMetadata];assert(r->voiceGenerations.count==1);
 assert([r->voicePositions[@1][0] doubleValue]==.7);
 [r fadeOutAllVoices];[r pruneVoiceMetadata];
 assert(!r->voiceGenerations.count&&!r->voicePositions.count&&!r->voiceSpatialModes.count);
 destroyRig(r);puts("Apple voice metadata: unknown edits retain nothing, queued/active owners survive, retired owner reclaimed PASS");
}
int main(int argc,char **argv) {@autoreleasepool {
 pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
 if(argc>1&&!strcmp(argv[1],"--trace")){traceBytes=YES;fixtures();}
 else if(argc>1&&!strcmp(argv[1],"--metadata"))metadataRegression();
 else if(argc>1&&atoi(argv[1])==-1)pruneBenchmark(argc>2?atoi(argv[2]):100000);
 else if(argc>1&&atoi(argv[1])==-2)producerBenchmark(argc>2?atoi(argv[2]):1,argc>3?atoi(argv[3]):100);
 else if(argc>1)benchmark(atoi(argv[1]),argc>2?atoi(argv[2]):2000,argc>3?atoi(argv[3]):256);else fixtures();
 }return 0;}
