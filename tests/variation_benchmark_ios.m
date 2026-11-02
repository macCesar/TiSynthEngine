int main(void) {@autoreleasepool {
 printf("layout voice=%zu step=%zu config=%zu transport=%zu fourTransports=%zu command=%zu\n",sizeof(SynthSequenceVoice),sizeof(SynthSequenceStep),sizeof(SynthSequenceConfig),sizeof(SynthSequenceTransport),4*sizeof(SynthSequenceTransport),sizeof(SynthCommand));
 for(int count=1;count<=32;count=count==1?8:count*2)for(int enabled=0;enabled<=1;enabled++) {
  RenderRig *r=rig(48000);float out[512];
  for(int id=1;id<=4;id++) {
   SynthSequenceConfig *c=synth_transport_begin_write(r->sequence,id,1);assert(c);c->loop=1;c->stepCount=1;c->stepDuration=.01;
   SynthSequenceStep *s=&c->steps[0];s->noteCount=count/4+(id<=count%4);s->rest=s->noteCount==0;
   SynthSequenceVoice *v=&s->voice;v->volume=.01;v->release=5;v->filterType=1;v->filterHz=1500;
   v->variation.amount=enabled;v->variation.mask=131;v->variation.low[0]=.005;v->variation.high[0]=.01;v->variation.low[1]=1000;v->variation.high[1]=2000;v->variation.low[7]=-10;v->variation.high[7]=10;
   for(int i=0;i<s->noteCount;i++)s->notes[i]=60+i;
   assert(synth_transport_commit(r->sequence,c,1));
  }
  for(int i=0;i<1000;i++)render(r,256,out,0);
  double cpu=seconds(CLOCK_THREAD_CPUTIME_ID),wall=seconds(CLOCK_MONOTONIC);
  for(int i=0;i<1000;i++)render(r,256,out,0);
  cpu=seconds(CLOCK_THREAD_CPUTIME_ID)-cpu;wall=seconds(CLOCK_MONOTONIC)-wall;
  printf("targetVoices=%d variation=%d fourSequences=1 callbackCpuSeconds=%.6f wallSeconds=%.6f load=%.6f\n",count,enabled,cpu,wall,cpu/(1000*256/48000.0));
  destroyRig(r);
 }
 return 0;
}}
