// Included after the production Apple callback and common render rig.
static void calibratePresets(void) {
 const char *names[]={"independentLow","independentMid","independentHigh","groupedChord","unison","overlappingReleases"};
 const int counts[]={1,2,4,8,16,32},offsets[]={0,2,4,5,7,9,11,12};
 for(unsigned p=0;p<sizeof(calibrationPresets)/sizeof(calibrationPresets[0]);p++) {
  const CalibrationPreset *preset=&calibrationPresets[p];double typicalPeak=-120;
  printf("{\"id\":\"%s\",\"scenarios\":[",preset->id);BOOL first=YES;
  for(int n=0;n<6;n++)for(int scenario=0;scenario<6;scenario++) {
   @autoreleasepool {
   int count=counts[n];RenderRig *r=rig(48000);atomic_store(&r->masterVolume,2);
   float output[2048];render(r,480,output,1);synth_stats_enable(&r->stats,YES);
   __block double outputPeak=0;
   // Render in bounded blocks, accumulating output without allocating audio.
   void (^frames)(int)=^(int total){while(total){int b=MIN(total,1024);float pcm[2048];render(r,b,pcm,1);for(int i=0;i<b*2;i++)outputPeak=fmax(outputPeak,fabs(pcm[i]));total-=b;}};
   // Peak is diagnostic; pre-protection peak/reduction use production stats.
   for(int id=1;id<=count;id++) {
    SynthCommand c=preset->command;c.type=SYNTH_CMD_HELD_ON;c.voiceId=id;c.voiceGeneration=id;c.eventVoiceCount=scenario==3?count:1;c.effectSend=-1;c.bus=1;
    int base=scenario==0?12:scenario==2?100:48;
    int midi=scenario==4?60:MIN(127,base+offsets[(id-1)%8]+12*((id-1)/8));c.frequency=440*exp2((midi-69)/12.0);
    assert(![r enqueueCommand:c]);
    if(scenario==5){frames(2400);SynthCommand off={0};off.type=SYNTH_CMD_HELD_OFF;off.voiceId=id;off.voiceGeneration=id;assert(![r enqueueCommand:off]);}
   }
   if(scenario!=5){frames(120000);for(int id=1;id<=count;id++){SynthCommand off={0};off.type=SYNTH_CMD_HELD_OFF;off.voiceId=id;off.voiceGeneration=id;assert(![r enqueueCommand:off]);}}
   frames(preset->command.releaseSamples+4800);
   double peak=r->stats.values[ST_PRE_LIMITER_PEAK],reduction=r->stats.values[ST_MAX_REDUCTION];
   assert(isfinite(peak)&&isfinite(reduction));BOOL typical=count<=8;if(typical)typicalPeak=fmax(typicalPeak,peak);
   double gain=fmin(2/fmax(1e-9,preset->command.volume),pow(10,(-6.01-peak)/20));
   printf("%s{\"name\":\"%s\",\"voices\":%d,\"typical\":%s,\"prePeakDb\":%.9g,\"reductionDb\":%.9g,\"outputPeak\":%.9g,\"recommendedGain\":%.12g}",first?"":",",names[scenario],count,typical?"true":"false",peak,reduction,outputPeak,gain);first=NO;destroyRig(r);
   }
  }
  double gain=fmin(2/fmax(1e-9,preset->command.volume),pow(10,(-6.01-typicalPeak)/20));
  printf("],\"typicalPeakDb\":%.9g,\"gain\":%.12g}\n",typicalPeak,gain);fflush(stdout);
 }
}
int main(void){@autoreleasepool{calibratePresets();}return 0;}
