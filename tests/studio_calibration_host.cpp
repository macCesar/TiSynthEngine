// Generated preset table comes from tools/calibrate_studio.py; audio is the
// unchanged Android callback compiled for the host, never an emulated oscillator.
#define main legacy_main
#include "engine_render_host.cpp"
#undef main
#include <cassert>
struct CalibrationPreset { const char *id; Command command; };
#include CALIBRATION_PRESETS_HEADER
struct Measurement { double peakDb=-120, reductionDb=0, outputPeak=0; };
static Measurement calibrationScenario(const CalibrationPreset &preset,int count,int scenario) {
    Rig r(32,1);r.e().setVolume(2);r.render(48000);r.e().enableStats(true);
    Measurement m;
    auto render=[&](int frames) {m.outputPeak=std::max(m.outputPeak,peak(r.render(frames)));};
    const int offsets[]={0,2,4,5,7,9,11,12};
    auto on=[&](int id) {
        Command c=preset.command;c.type=SYNTH_CMD_HELD_ON;c.voiceId=id;
        c.eventVoiceCount=scenario==3?count:1;
        int base=scenario==0?12:scenario==2?100:48;
        int midi=scenario==4?60:std::min(127,base+offsets[(id-1)%8]+12*((id-1)/8));
        c.frequency=440*std::exp2((midi-69)/12.0);
        assert(!r.e().enqueue(c));r.e().processCommands();
        for(auto &v:r.e().voices_)if(v.active&&v.held.voiceId==id) {
            v.noise=uint64_t(id)*6364136223846793005ULL+1442695040888963407ULL;
            v.heldNoise=static_cast<int32_t>(v.noise>>32)/2147483648.;
        }
    };
    auto release=[&](int id) {Command c;c.type=SYNTH_CMD_HELD_OFF;c.voiceId=id;assert(!r.e().enqueue(c));};
    if(scenario==5) {
      // Repeated distinct IDs leave older releases overlapping newer attacks.
      for(int id=1;id<=count;id++){on(id);render(2400);release(id);}
    }else{for(int id=1;id<=count;id++)on(id);render(120000);for(int id=1;id<=count;id++)release(id);}
    render(static_cast<int>(preset.command.release)+4800);
    m.peakDb=r.e().stats_.values[ST_PRE_LIMITER_PEAK];
    m.reductionDb=r.e().stats_.values[ST_MAX_REDUCTION];
    assert(std::isfinite(m.peakDb)&&std::isfinite(m.reductionDb));return m;
}
static void publishEffects(Rig &r,const SynthEffectsConfig &effects) {
    Command command;command.type=8;command.effects=effects;
    assert(!r.e().enqueue(command));
}
static void verifyNativeEffects(const SynthEffectsConfig &effects) {
    Rig wet(1,1),dry(1,1);publishEffects(wet,effects);
    Command signal=note(wet,440,100,5,20,.05,0);
    assert(!wet.e().enqueue(signal));assert(!dry.e().enqueue(signal));
    auto wetOutput=wet.render(48000),dryOutput=dry.render(48000);
    double wetTail=0,dryTail=0;
    for(size_t i=14400*2;i<wetOutput.size();i++) {
        wetTail=std::max(wetTail,std::fabs(static_cast<double>(wetOutput[i])));
        dryTail=std::max(dryTail,std::fabs(static_cast<double>(dryOutput[i])));
    }
    assert(wet.e().effectsActive_&&wetTail>1e-6&&dryTail==0);
}
static int renderBenchmark(void) {
    Rig r(32,1);r.e().enableStats(true);
    SynthEffectsConfig effects=synth_effects_default_config();
    effects.chorus.enabled=effects.delay.enabled=effects.reverb.enabled=effects.saturation.enabled=1;
    effects.chorus.mix=.4;effects.delay.mix=.3;effects.reverb.mix=.3;effects.saturation.drive=2;effects.saturation.mix=.25;
    verifyNativeEffects(effects);
    publishEffects(r,effects);
    for(int i=0;i<32;i++) {
        Command c=note(r,100+i*17,5000,10,100,.015,1);
        c.type=SYNTH_CMD_HELD_ON;c.voiceId=i+1;c.spatial=true;c.spatialX=(i%8)/3.5-1;c.spatialY=(i/8)/1.5-1;
        c.filterType=SYNTH_FILTER_LOWPASS;c.filterHz=1600;c.hasModulations=true;
        c.modulations.lfo[0].enabled=1;c.modulations.lfo[0].depth=.3;
        c.modulations.lfo[1].enabled=1;c.modulations.lfo[1].target=SYNTH_MOD_TARGET_PWM;c.modulations.lfo[1].depth=.3;
        assert(!r.e().enqueue(c));
    }
    r.render(48000);
    // Guard against measuring the renderer's disabled-effects fast path.
    assert(r.e().effectsActive_);
    assert(r.e().effects_.chorusGate.active&&r.e().effects_.chorusGate.send==1);
    assert(r.e().effects_.delayGate.active&&r.e().effects_.delayGate.send==1);
    assert(r.e().effects_.reverbGate.active&&r.e().effects_.reverbGate.send==1);
    assert(r.e().effects_.saturationSend==1&&r.e().effects_.current.saturation.drive==2);
    assert(r.e().stats_.active==32&&r.e().stats_.spatial==32);
    for(const auto &voice:r.e().voices_)
        assert(voice.active&&voice.modulating&&voice.modulation.config.lfo[0].enabled&&voice.modulation.config.lfo[1].enabled);
    std::array<float,512> output;std::vector<double> loads,cpuLoads;loads.reserve(6000);cpuLoads.reserve(6000);
    int missed=0;
    for(int block=0;block<6000;block++) {
        struct timespec cpuBefore,cpuAfter;clock_gettime(CLOCK_THREAD_CPUTIME_ID,&cpuBefore);
        auto before=std::chrono::steady_clock::now();r.e().onAudioReady(nullptr,output.data(),256);
        double elapsed=std::chrono::duration<double>(std::chrono::steady_clock::now()-before).count();
        clock_gettime(CLOCK_THREAD_CPUTIME_ID,&cpuAfter);
        double cpu=(cpuAfter.tv_sec-cpuBefore.tv_sec)+(cpuAfter.tv_nsec-cpuBefore.tv_nsec)*1e-9;
        cpuLoads.push_back(cpu*48000/256);if(elapsed*48000/256>=1)missed++;
        loads.push_back(elapsed*48000/256);
        for(float sample:output)assert(std::isfinite(sample)&&fabs(sample)<=.850001);
    }
    std::sort(loads.begin(),loads.end());
    std::sort(cpuLoads.begin(),cpuLoads.end());
    SynthEffects highRate;assert(synth_effects_init(&highRate,192000));size_t bytes=synth_effects_memory_bytes(&highRate);synth_effects_destroy(&highRate);
    std::printf("{\"sampleRate\":48000,\"blockFrames\":256,\"blocks\":6000,\"voices\":32,\"spatial\":true,\"effects\":true,\"lfosPerVoice\":2,\"loadMedian\":%.9g,\"loadP95\":%.9g,\"loadMax\":%.9g,\"cpuLoadMedian\":%.9g,\"cpuLoadP95\":%.9g,\"cpuLoadMax\":%.9g,\"deadlineMisses\":%d,\"effectsBytes192k\":%zu}\n",loads[3000],loads[5700],loads.back(),cpuLoads[3000],cpuLoads[5700],cpuLoads.back(),missed,bytes);
    return loads[5700]<.5&&loads.back()<1&&bytes<32u*1024u*1024u?0:1;
}
int main(int argc,char **) {
    if(argc>1)return renderBenchmark();
    const char *names[]={"independentLow","independentMid","independentHigh","groupedChord","unison","overlappingReleases"};
    for(const auto &preset:calibrationPresets()) {
      double typicalPeak=-120;
      printf("{\"id\":\"%s\",\"scenarios\":[",preset.id);bool first=true;
      for(int count:{1,2,4,8,16,32})for(int scenario=0;scenario<6;scenario++) {
        auto m=calibrationScenario(preset,count,scenario);
        bool typical=count<=8;if(typical)typicalPeak=std::max(typicalPeak,m.peakDb);
        double gain=std::min(2./std::max(1e-9,preset.command.volume),std::pow(10.,(-6.01-m.peakDb)/20.));
        printf("%s{\"name\":\"%s\",\"voices\":%d,\"typical\":%s,\"prePeakDb\":%.9g,\"reductionDb\":%.9g,\"outputPeak\":%.9g,\"recommendedGain\":%.12g}",first?"":",",names[scenario],count,typical?"true":"false",m.peakDb,m.reductionDb,m.outputPeak,gain);first=false;
      }
      double gain=std::min(2./std::max(1e-9,preset.command.volume),std::pow(10.,(-6.01-typicalPeak)/20.));
      printf("],\"typicalPeakDb\":%.9g,\"gain\":%.12g}\n",typicalPeak,gain);fflush(stdout);
    }
}
