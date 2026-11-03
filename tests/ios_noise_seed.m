// Exercise production voice admission and rendering with deterministic host seeds.
int main(void) { @autoreleasepool {
  RenderRig *a=rig(48000), *b=rig(48000), *c=rig(48000);
  a->noiseSeedState=b->noiseSeedState=42;c->noiseSeedState=43;
  for(int i=0;i<32;i++) {
    SynthCommand command=tone(a,i,4,NO,NO);
    assert(![a enqueueCommand:command]);
    assert(![b enqueueCommand:command]);
    assert(![c enqueueCommand:command]);
  }
  float x[512]={0},y[512]={0},z[512]={0};
  render(a,1,x,1);render(b,1,y,1);render(c,1,z,1);
  for(int i=0;i<32;i++) {
    assert(a->voices[i].noiseState==b->voices[i].noiseState);
    assert(a->voices[i].noiseState!=c->voices[i].noiseState);
    for(int j=0;j<i;j++)assert(a->voices[i].noiseState!=a->voices[j].noiseState);
  }
  render(a,256,x,1);
  render(b,127,y,1);render(b,129,y+254,1);
  render(c,256,z,1);
  assert(!memcmp(x,y,sizeof(x))); // Same seed, regardless of callback partition.
  assert(memcmp(x,z,sizeof(x))); // Fresh module seed changes noise realization.
  for(int i=0;i<512;i++)assert(isfinite(x[i])&&fabs(x[i])<=.850001);
  atomic_store(&a->emergencyStopRequested,true);
  for(int block=0;block<8;block++)render(a,256,x,1);
  for(int i=0;i<32;i++)assert(!a->voices[i].isActive);
  for(int i=0;i<512;i++)assert(x[i]==0);
  destroyRig(a);destroyRig(b);destroyRig(c);
  puts("Apple noise seeds: 32 distinct admissions, reproducibility, block partition, changed seed, finite output and global stop PASS");
  return 0;
} }
