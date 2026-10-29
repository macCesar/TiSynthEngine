package ti.synthengine;

import android.util.Log;

import org.appcelerator.kroll.KrollDict;
import org.appcelerator.kroll.KrollModule;
import org.appcelerator.kroll.annotations.Kroll;

import java.util.HashSet;
import java.util.Set;

@Kroll.module(name = "TiSynthEngine", id = "ti.synthengine")
public class TiSynthEngineModule extends KrollModule {

    private static final String TAG = "TiSynthEngine";

    private static final int MAX_VOICES_LIMIT = SynthContract.MAX_MAX_VOICES;

    private static final double DEFAULT_FREQUENCY_HZ = SynthContract.DEFAULT_FREQUENCY_HZ;

    private static final int DURATION_DEFAULT_MS = SynthContract.DEFAULT_DURATION_MS;
    private static final int DURATION_MIN_MS = SynthContract.MIN_DURATION_MS;
    private static final int DURATION_MAX_MS = SynthContract.MAX_DURATION_MS;

    private static final int ATTACK_DEFAULT_MS = SynthContract.DEFAULT_ATTACK_MS;
    private static final int ATTACK_MIN_MS = SynthContract.MIN_ATTACK_MS;
    private static final int ATTACK_MAX_MS = SynthContract.MAX_ATTACK_MS;

    private static final int RELEASE_DEFAULT_MS = SynthContract.DEFAULT_RELEASE_MS;
    private static final int RELEASE_MIN_MS = SynthContract.MIN_RELEASE_MS;
    private static final int RELEASE_MAX_MS = SynthContract.MAX_RELEASE_MS;

    private static final double VOLUME_DEFAULT = SynthContract.DEFAULT_VOLUME;
    private static final double VOLUME_MIN = SynthContract.MIN_VOLUME;
    private static final double VOLUME_MAX = SynthContract.MAX_VOLUME;

    private static final double MIN_FREQUENCY_HZ = SynthContract.MIN_FREQUENCY_HZ;
    private static final int SEQUENCE_MAX_STEPS = SynthContract.MAX_SEQUENCE_STEPS;

    private volatile SynthThread synthThread;
    private boolean statsEnabled;
    private final java.util.concurrent.atomic.AtomicLong rejectedPublications=new java.util.concurrent.atomic.AtomicLong();
    private double[] lastStats = emptyStats();
    private final java.util.concurrent.atomic.AtomicLongArray rejected = new java.util.concurrent.atomic.AtomicLongArray(3);
    // JNI layout: shared ST_* fields 0..14, pending/buffer/xruns/rate/capacity/latency 15..20.
    private static double[] emptyStats() {
        double[] v = new double[22];
        for(int i=6;i<15;i++) v[i]=Double.NaN;
        v[16]=v[17]=v[20]=Double.NaN; v[18]=44100; v[19]=SynthContract.DEFAULT_MAX_VOICES;
        return v;
    }
    private boolean reject(int reason) { rejected.incrementAndGet(reason); return false; }
    private Object statNumber(double v) { return Double.isNaN(v) ? null : v; }
    private KrollDict stereoStats(double left, double right) {
        KrollDict v = new KrollDict(); v.put("left",left); v.put("right",right); return v;
    }
    @Kroll.method
    public synchronized KrollDict getStats() {
        double[] v = synthThread == null ? lastStats : synthThread.getStats();
        if(v == null) v=lastStats;
        KrollDict r = new KrollDict();
        String[] keys={"activeVoices","peakActiveVoices","tailVoices","spatialVoices","voiceStealCount","callbackFrames","renderLoad","peakRenderLoad"};
        for(int i=0;i<keys.length;i++) r.put(keys[i], statNumber(v[i]));
        r.put("outputPeakDbFS",Double.isNaN(v[8]) ? null : stereoStats(v[8],v[9]));
        r.put("outputRmsDbFS",Double.isNaN(v[10]) ? null : stereoStats(v[10],v[11]));
        r.put("limiterReductionDb",statNumber(v[12]));
        r.put("preLimiterPeakDb",statNumber(v[13])); r.put("maxLimiterReductionDb",statNumber(v[14]));
        r.put("pendingCommands",v[15]); r.put("bufferFrames",statNumber(v[16]));
        r.put("underrunCount",statNumber(v[17])); r.put("sampleRate",v[18]); r.put("maxVoices",v[19]);
        r.put("estimatedOutputLatencyMs",statNumber(v[20]));r.put("priorityDropCount",v.length>21?v[21]:0);
        r.put("rejectedPublicationCount",rejectedPublications.get());
        KrollDict reasons = new KrollDict();
        long validation=rejected.get(0), stopped=rejected.get(1), full=rejected.get(2);
        reasons.put("validation",validation); reasons.put("engineStopped",stopped); reasons.put("queueFull",full);
        r.put("rejectedRequestsByReason",reasons); r.put("rejectedRequestCount",validation+stopped+full);
        return r;
    }
    @Kroll.method
    public synchronized boolean setStatsEnabled(Object enabled) {
        if(!(enabled instanceof Boolean)) return reject(0);
        statsEnabled=(Boolean)enabled;
        if(synthThread != null) synthThread.statsControl(statsEnabled ? 1 : 0);
        for(int i=6;i<15;i++) lastStats[i]=Double.NaN;
        return true;
    }
    @Kroll.method
    public synchronized void resetStats() {
        rejectedPublications.set(0);
        for(int i=0;i<3;i++) rejected.set(i,0);
        if(synthThread != null) synthThread.statsControl(2);
        lastStats[4]=0;lastStats[21]=0; lastStats[1]=lastStats[0];
        if(!Double.isNaN(lastStats[17])) lastStats[17]=0;
        for(int i=6;i<15;i++) lastStats[i]=Double.NaN;
    }
    private final Set<String> warnedKeys = new HashSet<>();
    private final android.os.Handler sequenceEvents = new android.os.Handler(android.os.Looper.getMainLooper());
    // The end-event poll runs only while accepted sequences exist, so an idle
    // engine never wakes the main thread. One chain at a time: a listener that
    // restarts the engine inside a sequenceend event must not add a second one.
    private boolean sequencePollScheduled;
    private final Runnable sequencePoll = new Runnable() { public void run() {
        synchronized(TiSynthEngineModule.this) {
            sequencePollScheduled=false;
            if(synthThread==null)return;
            double[] ends=synthThread.sequenceEnds();
            if(ends!=null)for(int i=0;i+1<ends.length;i+=2) {
                int id=(int)ends[i];acceptedSequences.remove(id);
                KrollDict event=new KrollDict();event.put("sequenceId",id);
                event.put("reason",ends[i+1]==1?"completed":"stopped");fireEvent("sequenceend",event);
            }
            scheduleSequencePoll();
        }
    }};
    private void scheduleSequencePoll() {
        if(sequencePollScheduled||synthThread==null||acceptedSequences.isEmpty())return;
        sequencePollScheduled=true;
        sequenceEvents.postDelayed(sequencePoll,10);
    }
    private void cancelSequencePoll() {
        sequenceEvents.removeCallbacks(sequencePoll);
        sequencePollScheduled=false;
    }
    private long nextSequenceId=1;

    public TiSynthEngineModule() {
        super();
    }

    // -------------------------------------------------------------------------
    // Public API
    // -------------------------------------------------------------------------

    @Kroll.method
    public KrollDict getDefaults() {
        KrollDict defaults = new KrollDict();
        defaults.put("maxVoices", SynthContract.DEFAULT_MAX_VOICES);
        defaults.put("mixingProfile", SynthContract.DEFAULT_MIXING_PROFILE);
        defaults.put("audioSession", SynthContract.DEFAULT_AUDIO_SESSION);
        defaults.put("frequency", DEFAULT_FREQUENCY_HZ);
        defaults.put("duration", DURATION_DEFAULT_MS);
        defaults.put("attack", ATTACK_DEFAULT_MS);
        defaults.put("release", RELEASE_DEFAULT_MS);
        defaults.put("volume", VOLUME_DEFAULT);
        defaults.put("waveType", SynthContract.DEFAULT_WAVE_TYPE);
        defaults.put("pan", SynthContract.DEFAULT_PAN);
        defaults.put("panEnd", SynthContract.DEFAULT_PAN);
        defaults.put("frequencyEnd", SynthContract.DEFAULT_FREQUENCY_END_HZ);
        defaults.put("lfoFreq", SynthContract.DEFAULT_LFO_FREQUENCY_HZ);
        defaults.put("lfoDepth", SynthContract.DEFAULT_LFO_DEPTH);
        defaults.put("noiseRate", SynthContract.DEFAULT_NOISE_RATE_HZ);
        defaults.put("noiseRateEnd", SynthContract.DEFAULT_NOISE_RATE_HZ);
        defaults.put("lowPassHz", SynthContract.DEFAULT_LOW_PASS_HZ);
        defaults.put("pulseWidth", SynthContract.DEFAULT_PULSE_WIDTH);
        defaults.put("pulseWidthEnd", 0.0);
        defaults.put("waveTable", new Object[]{});
        defaults.put("bitDepth", SynthContract.DEFAULT_BIT_DEPTH);
        defaults.put("panSpread", SynthContract.DEFAULT_PAN_SPREAD);
        defaults.put("bpm", SynthContract.DEFAULT_BPM);
        defaults.put("swing", SynthContract.DEFAULT_SWING);
        defaults.put("stepDuration", .25);
        defaults.put("gate",.8);defaults.put("timeUnit","beats");defaults.put("maxSequences",1);defaults.put("loop",false);
        defaults.put("bus","effects");defaults.put("priority",0);
        defaults.put("decay", SynthContract.DEFAULT_DECAY_MS);
        defaults.put("sustain", SynthContract.DEFAULT_SUSTAIN);
        defaults.put("filterType", SynthContract.DEFAULT_FILTER_TYPE);
        defaults.put("filterHz", SynthContract.DEFAULT_FILTER_HZ);
        defaults.put("filterHzEnd", 0.0);
        defaults.put("filterQ", SynthContract.DEFAULT_FILTER_Q);
        defaults.put("fmRatio", SynthContract.DEFAULT_FM_RATIO);
        defaults.put("fmDepth", SynthContract.DEFAULT_FM_DEPTH);
        defaults.put("detune", SynthContract.DEFAULT_DETUNE_CENTS);

        KrollDict limits = new KrollDict();
        limits.put("maxVoices", range(SynthContract.MIN_MAX_VOICES, MAX_VOICES_LIMIT));
        limits.put("frequency", range(MIN_FREQUENCY_HZ, maxFrequencyHz()));
        limits.put("duration", range(DURATION_MIN_MS, DURATION_MAX_MS));
        limits.put("attack", range(ATTACK_MIN_MS, ATTACK_MAX_MS));
        limits.put("release", range(RELEASE_MIN_MS, RELEASE_MAX_MS));
        limits.put("volume", range(VOLUME_MIN, VOLUME_MAX));
        limits.put("waveType", range(SynthContract.MIN_WAVE_TYPE, SynthContract.MAX_WAVE_TYPE));
        limits.put("sequenceSteps", range(1, SEQUENCE_MAX_STEPS));
        limits.put("pan", range(-1.0, 1.0));
        limits.put("spatialX", range(-1.0, 1.0));
        limits.put("spatialY", range(-1.0, 1.0));
        limits.put("panSpread", range(0.0, 1.0));
        limits.put("lfoFreq", range(0.0, SynthContract.MAX_LFO));
        limits.put("lfoDepth", range(0.0, SynthContract.MAX_LFO));
        limits.put("noiseRate", range(0.0, maxFrequencyHz()));
        limits.put("lowPassHz", range(0.0, maxFrequencyHz()));
        limits.put("pulseWidth", range(SynthContract.MIN_PULSE_WIDTH,
                SynthContract.MAX_PULSE_WIDTH));
        limits.put("waveTableSamples", range(SynthContract.MIN_WAVETABLE_SAMPLES,
                SynthContract.MAX_WAVETABLE_SAMPLES));
        limits.put("bitDepth", range(0, SynthContract.MAX_BIT_DEPTH));
        limits.put("bpm", range(SynthContract.MIN_BPM, SynthContract.MAX_BPM));
        limits.put("swing", range(SynthContract.MIN_SWING, SynthContract.MAX_SWING));
        limits.put("stepDuration", range(9/maxFrequencyHz(),300));
        limits.put("stepDurationMs",range(1800/maxFrequencyHz(),60000));
        limits.put("maxSequences",range(1,4));limits.put("priority",range(0,3));limits.put("effectSend",range(0,1));
        limits.put("decay", range(0, SynthContract.MAX_DECAY_MS));
        limits.put("sustain", range(0.0, 1.0));
        limits.put("filterHz", range(SynthContract.MIN_FILTER_HZ, maxFrequencyHz()));
        limits.put("filterQ", range(SynthContract.MIN_FILTER_Q, SynthContract.MAX_FILTER_Q));
        limits.put("fmRatio", range(SynthContract.MIN_FM_RATIO, SynthContract.MAX_FM_RATIO));
        limits.put("fmDepth", range(0.0, SynthContract.MAX_FM_DEPTH));
        limits.put("detune", range(-SynthContract.MAX_DETUNE_CENTS, SynthContract.MAX_DETUNE_CENTS));

        KrollDict waveTypes = new KrollDict();
        waveTypes.put("SINE", 0);
        waveTypes.put("SQUARE", 1);
        waveTypes.put("SAWTOOTH", 2);
        waveTypes.put("TRIANGLE", 3);
        waveTypes.put("NOISE", 4);
        waveTypes.put("WAVETABLE", 5);

        KrollDict result = new KrollDict();
        KrollDict capabilities=new KrollDict();capabilities.put("nativeSequence",true);capabilities.put("masterProcessing",true);capabilities.put("modulations",true);
        result.put("capabilities",capabilities);
        result.put("apiVersion", SynthContract.API_VERSION);
        result.put("defaults", defaults);
        result.put("limits", limits);
        result.put("mixingProfiles", new Object[]{"conservative", "raw", "balanced", "speakerSafe"});
        result.put("audioSessions", new Object[]{"playback", "ambient"});
        result.put("buses",new Object[]{"music","effects","ui","ambience"});
        result.put("filterTypes", SynthContract.FILTER_TYPES.clone());
        result.put("waveTypes", waveTypes);
        return result;
    }

    @Kroll.method
    public synchronized boolean start(KrollDict options) {
        if (!acceptValidation("start", SynthContract.validateStart(options))) return false;
        if (synthThread != null) return true;
        int maxVoices = readOptionalIntOption(options, "start", "maxVoices",
                SynthContract.DEFAULT_MAX_VOICES, 1, MAX_VOICES_LIMIT);
        int mixingProfile = readMixingProfile(options);
        if (mixingProfile < 0) return false;
        SynthThread candidate = new SynthThread(maxVoices, mixingProfile,readOptionalIntOption(options,"start","maxSequences",1,1,4));
        candidate.statsControl(statsEnabled ? 1 : 0);
        if (!candidate.startAudio()) {
            candidate.requestShutdown();
            return reject(1);
        }
        synthThread = candidate;
        acceptedSequences.clear();acceptedProcessing=null;rejectedPublications.set(0);
        cancelSequencePoll();
        lastStats=emptyStats();
        for(int i=0;i<3;i++) rejected.set(i,0);

        return true;
    }

    @Kroll.method
    public synchronized boolean setVolume(KrollDict options) {
        if (synthThread == null) return reject(1);
        if (!acceptValidation("setVolume", SynthContract.validateSetVolume(options))) return false;
        double volume = readOptionalDoubleOption(options, "setVolume", "volume",
                1.0, VOLUME_MIN, VOLUME_MAX);
        synthThread.setMasterVolume(volume);
        return true;
    }

    @Kroll.method
    public synchronized boolean playTone(KrollDict options) { return publishTone(options,0); }

    @Kroll.method
    public synchronized boolean noteOn(KrollDict options) {
        if(synthThread==null)return reject(1);
        if(!acceptValidation("noteOn",SynthContract.validateNoteOn(options,maxFrequencyHz())))return false;
        return publishTone(options,((Number)options.get("voiceId")).intValue());
    }

    @Kroll.method
    public synchronized boolean noteOff(KrollDict options) {
        if(synthThread==null)return reject(1);
        if(!acceptValidation("noteOff",SynthContract.validateNoteOff(options)))return false;
        boolean full=synthThread.voiceCommand(5,((Number)options.get("voiceId")).intValue(),0,null);
        if(full)reject(2); return !full;
    }

    @Kroll.method
    public synchronized boolean updateVoice(KrollDict options) {
        if(synthThread==null)return reject(1);
        if(!acceptValidation("updateVoice",SynthContract.validateUpdateVoice(options,maxFrequencyHz())))return false;
        String[] keys={"frequency","volume","filterHz","filterQ","lfoFreq","lfoDepth","pulseWidth","fmRatio","fmDepth","noiseRate","lowPassHz","pan"};
        double[] values=new double[keys.length]; int mask=0;
        for(int i=0;i<keys.length;i++)if(containsKey(options,keys[i])) {mask|=1<<i; values[i]=((Number)options.get(keys[i])).doubleValue();}
        if(containsKey(options,"note")){mask|=1;values[0]=parseNoteToFrequency((String)options.get("note"));}
        int id=((Number)options.get("voiceId")).intValue(), allowed=synthThread.voiceMask(id);
        if(allowed>=0&&(containsKey(options,"spatialX")||containsKey(options,"spatialY"))&&(allowed&(1<<16))==0)return reject(0);
        if(allowed>=0 && (mask & ~allowed)!=0)return acceptValidation("updateVoice",SynthContract.Validation.rejected("changes","incompatible_voice_source",options));
        if(options.containsKey("modulations"))try {
            double[] mods=SynthStudioContract.modulations(options.get("modulations"),-1,-1);
            for(int i=0;i<2;i++)if(mods[i*6]!=0&&allowed>=0) {
                int target=(int)mods[i*6+2],bit=target==0?2:target==1?6:8;
                if((allowed&(1<<bit))==0)return reject(0);
            }
            values=java.util.Arrays.copyOf(values,24);System.arraycopy(mods,0,values,12,12);
        } catch(IllegalArgumentException e){return reject(0);}
        // Extra controls are carried in a fixed tail after the modulation packet.
        values=java.util.Arrays.copyOf(values,28);
        values[24]=(containsKey(options,"modulations")?2:0)+(containsKey(options,"spatialX")||containsKey(options,"spatialY")?1:0);
        values[25]=containsKey(options,"spatialX")?((Number)options.get("spatialX")).doubleValue():Double.NaN;
        values[26]=containsKey(options,"spatialY")?((Number)options.get("spatialY")).doubleValue():Double.NaN;
        values[27]=containsKey(options,"effectSend")?((Number)options.get("effectSend")).doubleValue():Double.NaN;
        boolean full=synthThread.voiceCommand(6,id,mask,values);
        if(full)reject(2); return !full;
    }

    private boolean publishTone(KrollDict options,int voiceId) {
        if (synthThread == null) return reject(1);
        if (options == null) options = new KrollDict();

        double maxFreq = maxFrequencyHz();
        if (voiceId==0 && !acceptValidation("playTone", SynthContract.validateTone(options, maxFreq))) return false;

        double frequency;
        if (containsKey(options, "note")) {
            Object noteObj = options.get("note");
            frequency = parseNoteToFrequency(noteObj != null ? noteObj.toString() : "");
        } else {
            frequency = readOptionalDoubleOption(options, "playTone", "frequency",
                    DEFAULT_FREQUENCY_HZ, MIN_FREQUENCY_HZ, maxFreq);
        }

        int duration = readOptionalIntOption(options, "playTone", "duration",
                voiceId>0 ? DURATION_MAX_MS : DURATION_DEFAULT_MS, DURATION_MIN_MS, DURATION_MAX_MS);

        int    attack  = readOptionalIntOption(options, "playTone", "attack",
                ATTACK_DEFAULT_MS, ATTACK_MIN_MS, ATTACK_MAX_MS);
        int    release = readOptionalIntOption(options, "playTone", "release",
                RELEASE_DEFAULT_MS, RELEASE_MIN_MS, RELEASE_MAX_MS);
        double volume  = readOptionalDoubleOption(options, "playTone", "volume",
                VOLUME_DEFAULT, VOLUME_MIN, VOLUME_MAX);
        int    waveType= readOptionalIntOption(options, "playTone", "waveType",
                0, 0, SynthContract.MAX_WAVE_TYPE);
        double pan     = readOptionalDoubleOption(options, "playTone", "pan",
                0.0, -1.0, 1.0);
        double panEnd  = readOptionalDoubleOption(options, "playTone", "panEnd",
                pan, -1.0, 1.0);
        double freqEnd = 0.0;
        if (containsKey(options, "frequencyEnd")) {
            Double fe = parseFiniteDouble(options.get("frequencyEnd"));
            if (fe != null && fe >= MIN_FREQUENCY_HZ) {
                freqEnd = clamp(fe, MIN_FREQUENCY_HZ, maxFreq);
            }
        }
        double lfoFreq  = readOptionalDoubleOption(options, "playTone", "lfoFreq",
                0.0, 0.0, 20000.0);
        double lfoDepth = readOptionalDoubleOption(options, "playTone", "lfoDepth",
                0.0, 0.0, 20000.0);
        double noiseRate = readOptionalDoubleOption(options, "playTone", "noiseRate",
                0.0, 0.0, maxFreq);
        double noiseRateEnd = readOptionalDoubleOption(options, "playTone", "noiseRateEnd",
                0.0, 0.0, maxFreq);
        double lowPassHz = readOptionalDoubleOption(options, "playTone", "lowPassHz",
                0.0, 0.0, maxFreq);
        double pulseWidth = readOptionalDoubleOption(options, "playTone", "pulseWidth",
                SynthContract.DEFAULT_PULSE_WIDTH, SynthContract.MIN_PULSE_WIDTH,
                SynthContract.MAX_PULSE_WIDTH);
        double pulseWidthEnd = readOptionalDoubleOption(options, "playTone", "pulseWidthEnd",
                0.0, 0.0, SynthContract.MAX_PULSE_WIDTH);
        int bitDepth = readOptionalIntOption(options, "playTone", "bitDepth",
                0, 0, SynthContract.MAX_BIT_DEPTH);
        double[] waveTable = parseWaveTable(options);
        double[] extras = readExtras(options, defaultExtras());
        extras[SynthThread.EXTRA_VOICE_ID]=voiceId;
        if(voiceId!=0&&options.containsKey("modulations")) {
            double[] mods=SynthStudioContract.modulations(options.get("modulations"),waveType,(int)extras[SynthThread.EXTRA_FILTER_TYPE]);
            System.arraycopy(mods,0,extras,13,12);
        }
        double detune = readOptionalDoubleOption(options, "playTone", "detune",
                0.0, -SynthContract.MAX_DETUNE_CENTS, SynthContract.MAX_DETUNE_CENTS);
        if (detune != 0.0) {
            double ratio = detuneRatio(detune);
            frequency = clamp(frequency * ratio, MIN_FREQUENCY_HZ, maxFreq);
            if (freqEnd >= MIN_FREQUENCY_HZ) {
                freqEnd = clamp(freqEnd * ratio, MIN_FREQUENCY_HZ, maxFreq);
            }
        }

        if (attack >= duration) attack = Math.max(0, duration - 1);
        int maxRelease = Math.max(0, duration - attack);
        if (release > maxRelease) release = maxRelease;

        boolean dropped = synthThread.enqueueNote(
                frequency, duration, attack, release, volume,
                waveType, pan, panEnd, freqEnd, lfoFreq, lfoDepth,
                noiseRate, noiseRateEnd, lowPassHz, pulseWidth, pulseWidthEnd,
                bitDepth, waveTable, extras);
        if (dropped) {
            warnOnce("playTone", "queue", "overflow", "command_queue_full", "drop_newest");
        }
        if(dropped) reject(2);
        return !dropped;
    }

    @Kroll.method
    public synchronized boolean playChord(KrollDict options) {
        if (synthThread == null) return reject(1);
        if (options == null) return reject(0);

        double maxFreq = maxFrequencyHz();
        if (!acceptValidation("playChord", SynthContract.validateChord(options, maxFreq))) return false;
        double[] freqs = parseFreqArray(options, "playChord", maxFreq);
        if (freqs == null || freqs.length == 0) return false;

        int duration = readOptionalIntOption(options, "playChord", "duration",
                DURATION_DEFAULT_MS, DURATION_MIN_MS, DURATION_MAX_MS);

        int    attack    = readOptionalIntOption(options, "playChord", "attack",
                ATTACK_DEFAULT_MS, ATTACK_MIN_MS, ATTACK_MAX_MS);
        int    release   = readOptionalIntOption(options, "playChord", "release",
                RELEASE_DEFAULT_MS, RELEASE_MIN_MS, RELEASE_MAX_MS);
        double volume    = readOptionalDoubleOption(options, "playChord", "volume",
                VOLUME_DEFAULT, VOLUME_MIN, VOLUME_MAX);
        int    waveType  = readOptionalIntOption(options, "playChord", "waveType",
                0, 0, SynthContract.MAX_WAVE_TYPE);
        double panSpread = readOptionalDoubleOption(options, "playChord", "panSpread",
                0.0, 0.0, 1.0);
        double noiseRate = readOptionalDoubleOption(options, "playChord", "noiseRate",
                0.0, 0.0, maxFreq);
        double lowPassHz = readOptionalDoubleOption(options, "playChord", "lowPassHz",
                0.0, 0.0, maxFreq);
        double pulseWidth = readOptionalDoubleOption(options, "playChord", "pulseWidth",
                SynthContract.DEFAULT_PULSE_WIDTH, SynthContract.MIN_PULSE_WIDTH,
                SynthContract.MAX_PULSE_WIDTH);
        int bitDepth = readOptionalIntOption(options, "playChord", "bitDepth",
                0, 0, SynthContract.MAX_BIT_DEPTH);
        double[] waveTable = parseWaveTable(options);
        double[] extras = readExtras(options, defaultExtras());

        if (containsKey(options, "detunes")) {
            Object[] cents = (Object[]) options.get("detunes");
            for (int i = 0; i < cents.length && i < freqs.length; i++) {
                Double value = parseFiniteDouble(cents[i]);
                if (value != null && value != 0.0) {
                    freqs[i] = clamp(freqs[i] * detuneRatio(value), MIN_FREQUENCY_HZ, maxFreq);
                }
            }
        }

        if (attack >= duration) attack = Math.max(0, duration - 1);
        int maxRelease = Math.max(0, duration - attack);
        if (release > maxRelease) release = maxRelease;

        // Optional per-voice pans override
        double[] pansOverride = null;
        if (containsKey(options, "pans")) {
            Object raw = options.get("pans");
            if (raw instanceof Object[]) {
                Object[] arr = (Object[]) raw;
                pansOverride = new double[arr.length];
                for (int i = 0; i < arr.length; i++) {
                    Double v = parseFiniteDouble(arr[i]);
                    pansOverride[i] = v != null ? clamp(v, -1.0, 1.0) : 0.0;
                }
            }
        }

        double[] pans = new double[freqs.length];
        for (int i = 0; i < freqs.length; i++) {
            double pan = 0.0;
            if (pansOverride != null && i < pansOverride.length) {
                pan = pansOverride[i];
            } else if (panSpread > 0.0 && freqs.length > 1) {
                pan = panSpread * (2.0 * i / (freqs.length - 1) - 1.0);
            }
            pans[i] = pan;
        }
        boolean dropped = synthThread.enqueueChord(freqs, duration, attack, release,
                volume, waveType, pans, noiseRate, lowPassHz, pulseWidth,
                bitDepth, waveTable, extras);
        if (dropped) {
            warnOnce("playChord", "queue", "overflow", "command_queue_full", "drop_newest");
        }
        if(dropped) reject(2);
        return !dropped;
    }

    private double[] acceptedProcessing;
    @Kroll.method public synchronized boolean setMasterProcessing(KrollDict options) {
        if(synthThread==null)return reject(1);
        final double[] next;
        try {if(options==null)return reject(0);next=SynthStudioContract.effects(options,acceptedProcessing);}
        catch(IllegalArgumentException e){return reject(0);}
        if(!synthThread.masterProcessing(next))return reject(2);
        acceptedProcessing=next;return true;
    }
    private final java.util.Map<Integer,SynthStudioContract.Sequence> acceptedSequences=new java.util.HashMap<>();
    @Kroll.method public synchronized int playSequence(KrollDict options) {
        if(synthThread==null){reject(1);return 0;}
        if(nextSequenceId>Integer.MAX_VALUE){reject(2);return 0;}
        final SynthStudioContract.Sequence next;
        try {next=SynthStudioContract.sequence(options,null,true,maxFrequencyHz());}
        catch(IllegalArgumentException e){reject(0);return 0;}
        int id=(int)nextSequenceId++;
        if(!synthThread.publishSequence(id,next.packet,true)){rejectedPublications.incrementAndGet();reject(2);return 0;}
        acceptedSequences.put(id,next.acceptedState());scheduleSequencePoll();return id;
    }
    private int sequenceId(KrollDict options) {
        if(options==null||!(options.get("sequenceId") instanceof Number))return 0;
        double id=((Number)options.get("sequenceId")).doubleValue();
        return Double.isFinite(id)&&id>=1&&id<=Integer.MAX_VALUE&&id==Math.rint(id)?(int)id:0;
    }
    @Kroll.method public synchronized boolean updateSequence(KrollDict options) {
        if(synthThread==null)return reject(1);
        int id=sequenceId(options);if(id==0||!acceptedSequences.containsKey(id)||synthThread.sequenceState(id)==null)return reject(0);
        java.util.Map<String,Object> changes=new java.util.HashMap<>(options);changes.remove("sequenceId");
        final SynthStudioContract.Sequence next;
        try {next=SynthStudioContract.sequence(changes,acceptedSequences.get(id),false,maxFrequencyHz());}
        catch(IllegalArgumentException e){return reject(0);}
        if(!synthThread.publishSequence(id,next.packet,false)){rejectedPublications.incrementAndGet();return reject(2);}
        acceptedSequences.put(id,next.acceptedState());return true;
    }
    @Kroll.method public synchronized boolean stopSequence(KrollDict options) {
        if(synthThread==null)return reject(1);
        int id=sequenceId(options);if(id==0||options.size()!=1)return reject(0);
        return synthThread.stopSequence(id);
    }
    @Kroll.method public synchronized boolean setTempo(KrollDict options) {
        if(synthThread==null)return reject(1);
        try {if(options==null)return reject(0);SynthStudioContract.keys(options,"bpm");
            if(!options.containsKey("bpm"))return reject(0);
            return synthThread.setTempo(SynthStudioContract.number(options,"bpm",120,20,300));
        }catch(IllegalArgumentException e){return reject(0);}
    }
    @Kroll.method public synchronized KrollDict getSequenceState(KrollDict options) {
        int id=sequenceId(options);if(id==0||options.size()!=1)return null;
        double[] v=synthThread==null?null:synthThread.sequenceState(id);if(v==null)return null;
        KrollDict state=new KrollDict();state.put("sequenceId",id);state.put("playing",v[0]!=0);state.put("step",(int)v[1]);
        state.put("position",v[2]);state.put("beat",v[2]);state.put("bpm",v[3]);state.put("revision",v[4]);return state;
    }

    @Kroll.method
    public synchronized void stopAll() {
        if (synthThread == null) return;
        boolean dropped = synthThread.requestStopAll();
        if (dropped) {
            warnOnce("stopAll", "queue", "overflow", "command_queue_full", "fallback_control_flag");
        }
    }

    @Kroll.method
    public synchronized void shutdown() {
        cancelSequencePoll();
        if (synthThread == null) return;
        double[] finalStats=synthThread.stopAndGetStats();
        if(finalStats!=null) lastStats=finalStats;
        synthThread.requestShutdown();
        lastStats[0]=lastStats[2]=lastStats[3]=lastStats[5]=lastStats[15]=0;
        lastStats[20]=Double.NaN;
        for(int i=6;i<15;i++) lastStats[i]=Double.NaN;
        synthThread = null;
    }

    /**
     * The root activity is going away. Release the stream now: a cached process
     * must not keep an exclusive low-latency output open after the app closes.
     */
    @Override
    public void onDestroy(android.app.Activity activity) {
        super.onDestroy(activity);
        shutdown();
    }

    // -------------------------------------------------------------------------
    // Note name parser
    // Supports: C4, F#4, Bb3, Do4, Fa#4, Sib3 (solfege with optional octave digit)
    // Returns -1.0 on parse failure.
    // -------------------------------------------------------------------------
    static double parseNoteToFrequency(String noteName) {
        if (noteName == null || noteName.isEmpty()) return -1.0;
        String s     = noteName.trim();
        String upper = s.toUpperCase();
        int    pos   = 0;
        int    semitone;

        // Try solfege names (longest match first to avoid "Si" matching "Sol")
        if (upper.startsWith("SOL"))     { semitone = 7;  pos = 3; }
        else if (upper.startsWith("DO")) { semitone = 0;  pos = 2; }
        else if (upper.startsWith("RE")) { semitone = 2;  pos = 2; }
        else if (upper.startsWith("MI")) { semitone = 4;  pos = 2; }
        else if (upper.startsWith("FA")) { semitone = 5;  pos = 2; }
        else if (upper.startsWith("LA")) { semitone = 9;  pos = 2; }
        else if (upper.startsWith("SI")) { semitone = 11; pos = 2; }
        else if (upper.startsWith("TI")) { semitone = 11; pos = 2; }
        else {
            // Single letter names
            pos = 1;
            if (s.isEmpty()) return -1.0;
            switch (upper.charAt(0)) {
                case 'C': semitone = 0;  break;
                case 'D': semitone = 2;  break;
                case 'E': semitone = 4;  break;
                case 'F': semitone = 5;  break;
                case 'G': semitone = 7;  break;
                case 'A': semitone = 9;  break;
                case 'B': semitone = 11; break;
                default:  return -1.0;
            }
        }

        // Accidental: use original string (lowercase 'b' = flat, '#' = sharp)
        if (pos < s.length()) {
            char acc = s.charAt(pos);
            if (acc == '#') { semitone++; pos++; }
            else if (acc == 'b') { semitone--; pos++; }
        }

        // Octave digit (0–9, default 4)
        int octave = 4;
        if (pos < s.length()) {
            char c = s.charAt(pos);
            if (c >= '0' && c <= '9') octave = c - '0';
        }

        int midi = (octave + 1) * 12 + semitone;
        return 440.0 * Math.pow(2.0, (midi - 69.0) / 12.0);
    }

    // -------------------------------------------------------------------------
    // Note value → duration in milliseconds
    // -------------------------------------------------------------------------


    // -------------------------------------------------------------------------
    // Frequency array parser (from "frequencies" or "notes" key in dict)
    // -------------------------------------------------------------------------
    private double[] parseFreqArray(KrollDict options, String method, double maxFreq) {
        if (containsKey(options, "frequencies")) {
            Object raw = options.get("frequencies");
            if (raw instanceof Object[]) {
                Object[] arr = (Object[]) raw;
                double[] result = new double[arr.length];
                for (int i = 0; i < arr.length; i++) {
                    Double v = parseFiniteDouble(arr[i]);
                    if (v != null) {
                        result[i] = clamp(v, MIN_FREQUENCY_HZ, maxFreq);
                    } else {
                        double f = parseNoteToFrequency(arr[i] != null ? arr[i].toString() : "");
                        result[i] = f >= MIN_FREQUENCY_HZ ? clamp(f, MIN_FREQUENCY_HZ, maxFreq)
                                                          : MIN_FREQUENCY_HZ;
                    }
                }
                return result;
            }
        }

        if (containsKey(options, "notes")) {
            Object raw = options.get("notes");
            if (raw instanceof Object[]) {
                Object[] arr = (Object[]) raw;
                double[] result = new double[arr.length];
                for (int i = 0; i < arr.length; i++) {
                    double f = parseNoteToFrequency(arr[i] != null ? arr[i].toString() : "");
                    result[i] = f >= MIN_FREQUENCY_HZ ? clamp(f, MIN_FREQUENCY_HZ, maxFreq)
                                                      : MIN_FREQUENCY_HZ;
                }
                return result;
            }
        }

        return null;
    }

    private double[] parseWaveTable(KrollDict options) {
        if (!containsKey(options, "waveTable")) return null;
        Object raw = options.get("waveTable");
        if (!(raw instanceof Object[])) return null;
        Object[] values = (Object[]) raw;
        int count = Math.min(values.length, SynthContract.MAX_WAVETABLE_SAMPLES);
        double[] result = new double[count];
        for (int i = 0; i < count; i++) {
            Double value = parseFiniteDouble(values[i]);
            result[i] = value == null ? 0.0 : clamp(value, -1.0, 1.0);
        }
        return result;
    }

    // -------------------------------------------------------------------------
    // Helpers
    // -------------------------------------------------------------------------

    private static double detuneRatio(double cents) {
        return Math.pow(2.0, cents / 1200.0);
    }

    private static double[] defaultExtras() {
        double[] extras = new double[SynthThread.EXTRA_COUNT];
        extras[SynthThread.EXTRA_DECAY_MS] = SynthContract.DEFAULT_DECAY_MS;
        extras[SynthThread.EXTRA_SUSTAIN] = SynthContract.DEFAULT_SUSTAIN;
        extras[SynthThread.EXTRA_FILTER_TYPE] = 0;
        extras[SynthThread.EXTRA_FILTER_HZ] = SynthContract.DEFAULT_FILTER_HZ;
        extras[SynthThread.EXTRA_FILTER_HZ_END] = 0.0;
        extras[SynthThread.EXTRA_FILTER_Q] = SynthContract.DEFAULT_FILTER_Q;
        extras[SynthThread.EXTRA_FM_RATIO] = SynthContract.DEFAULT_FM_RATIO;
        extras[SynthThread.EXTRA_FM_DEPTH] = SynthContract.DEFAULT_FM_DEPTH;
        extras[SynthThread.EXTRA_FM_DEPTH_END] = Double.NaN;
        return extras;
    }

    /** The decay, sustain, filter and FM values of one event, over the values it inherits. */
    private double[] readExtras(KrollDict options, double[] inherited) {
        double[] extras = inherited.clone();
        if (containsKey(options, "spatialX") || containsKey(options, "spatialY")) {
            extras[SynthThread.EXTRA_SPATIAL] = 1.0;
        }
        copyNumber(options, "spatialX", extras, SynthThread.EXTRA_SPATIAL_X);
        copyNumber(options, "spatialY", extras, SynthThread.EXTRA_SPATIAL_Y);
        copyNumber(options, "decay", extras, SynthThread.EXTRA_DECAY_MS);
        copyNumber(options, "sustain", extras, SynthThread.EXTRA_SUSTAIN);
        copyNumber(options, "filterHz", extras, SynthThread.EXTRA_FILTER_HZ);
        copyNumber(options, "filterHzEnd", extras, SynthThread.EXTRA_FILTER_HZ_END);
        copyNumber(options, "filterQ", extras, SynthThread.EXTRA_FILTER_Q);
        copyNumber(options, "fmRatio", extras, SynthThread.EXTRA_FM_RATIO);
        copyNumber(options, "fmDepth", extras, SynthThread.EXTRA_FM_DEPTH);
        copyNumber(options, "fmDepthEnd", extras, SynthThread.EXTRA_FM_DEPTH_END);
        if (containsKey(options, "filterType")) {
            extras[SynthThread.EXTRA_FILTER_TYPE] =
                    SynthContract.filterTypeIndex((String) options.get("filterType"));
        }
        extras[25]=SynthStudioContract.bus(options.getOrDefault("bus","effects"));
        extras[26]=containsKey(options,"effectSend")?((Number)options.get("effectSend")).doubleValue():-1;
        extras[27]=containsKey(options,"priority")?((Number)options.get("priority")).doubleValue():0;
        return extras;
    }

    private void copyNumber(KrollDict options, String key, double[] target, int index) {
        if (!containsKey(options, key)) return;
        Double value = parseFiniteDouble(options.get(key));
        if (value != null) target[index] = value;
    }

    private double maxFrequencyHz() {
        return synthThread != null ? synthThread.getSampleRate() * 0.45 : 44100.0 * 0.45;
    }

    private int readMixingProfile(KrollDict options) {
        if (!containsKey(options, "mixingProfile")) {
            return SynthDsp.MIXING_PROFILE_CONSERVATIVE;
        }

        Object rawValue = options.get("mixingProfile");
        if (!(rawValue instanceof String)) {
            warnOnce("start", "mixingProfile", "not_string",
                    rawValue, "engine_not_started");
            return -1;
        }

        String profile = ((String) rawValue).trim();
        if ("raw".equalsIgnoreCase(profile)) return SynthDsp.MIXING_PROFILE_RAW;
        if ("conservative".equalsIgnoreCase(profile)) {
            return SynthDsp.MIXING_PROFILE_CONSERVATIVE;
        }
        if ("balanced".equalsIgnoreCase(profile)) {
            return SynthDsp.MIXING_PROFILE_BALANCED;
        }
        if ("speakerSafe".equalsIgnoreCase(profile)) {
            return SynthDsp.MIXING_PROFILE_SPEAKER_SAFE;
        }

        warnOnce("start", "mixingProfile", "unsupported_value",
                rawValue, "engine_not_started");
        return -1;
    }

    private void warnOnce(String method, String key, String reason, Object value, String action) {
        String onceKey = method + ":" + key + ":" + reason;
        synchronized (warnedKeys) {
            if (warnedKeys.contains(onceKey)) return;
            warnedKeys.add(onceKey);
        }
        Log.w(TAG, "event=validation_warning method=" + method + " key=" + key
                + " reason=" + reason + " action=" + action + " value=" + value);
    }

    private boolean acceptValidation(String method, SynthContract.Validation validation) {
        if (validation.accepted) return true;
        reject(0);
        warnOnce(method, validation.key, validation.reason, validation.value, "rejected");
        return false;
    }

    private KrollDict range(double min, double max) {
        KrollDict result = new KrollDict();
        result.put("min", min);
        result.put("max", max);
        return result;
    }

    private boolean containsKey(KrollDict options, String key) {
        return options != null && options.containsKey(key);
    }

    private Integer readRequiredIntOption(KrollDict options, String method, String key) {
        if (!containsKey(options, key)) {
            warnOnce(method, key, "missing_required", "null", "ignored");
            return null;
        }
        Double parsed = parseFiniteDouble(options.get(key));
        if (parsed == null) {
            warnOnce(method, key, "non_numeric_or_non_finite", options.get(key), "ignored");
            return null;
        }
        double rounded = Math.rint(parsed);
        if (Math.abs(parsed - rounded) > 1e-9) {
            warnOnce(method, key, "not_integer", options.get(key), "ignored");
            return null;
        }
        if (rounded < Integer.MIN_VALUE || rounded > Integer.MAX_VALUE) {
            warnOnce(method, key, "integer_overflow", options.get(key), "ignored");
            return null;
        }
        return (int) rounded;
    }

    private Double readRequiredDoubleOption(KrollDict options, String method, String key) {
        if (!containsKey(options, key)) {
            warnOnce(method, key, "missing_required", "null", "ignored");
            return null;
        }
        Double parsed = parseFiniteDouble(options.get(key));
        if (parsed == null) {
            warnOnce(method, key, "non_numeric_or_non_finite", options.get(key), "ignored");
            return null;
        }
        return parsed;
    }

    private int readOptionalIntOption(KrollDict options, String method, String key,
            int defaultValue, int minValue, int maxValue) {
        if (!containsKey(options, key)) return defaultValue;
        Double parsed = parseFiniteDouble(options.get(key));
        if (parsed == null) {
            warnOnce(method, key, "non_numeric_or_non_finite", options.get(key), "fallback_default");
            return defaultValue;
        }
        double rounded = Math.rint(parsed);
        if (Math.abs(parsed - rounded) > 1e-9) {
            warnOnce(method, key, "not_integer", options.get(key), "rounded");
        }
        if (rounded < Integer.MIN_VALUE || rounded > Integer.MAX_VALUE) {
            warnOnce(method, key, "integer_overflow", options.get(key), "fallback_default");
            return defaultValue;
        }
        int raw     = (int) rounded;
        int clamped = clamp(raw, minValue, maxValue);
        if (clamped != raw) {
            warnOnce(method, key, "out_of_range", options.get(key), "clamped");
        }
        return clamped;
    }

    private double readOptionalDoubleOption(KrollDict options, String method, String key,
            double defaultValue, double minValue, double maxValue) {
        if (!containsKey(options, key)) return defaultValue;
        Double parsed = parseFiniteDouble(options.get(key));
        if (parsed == null) {
            warnOnce(method, key, "non_numeric_or_non_finite", options.get(key), "fallback_default");
            return defaultValue;
        }
        double clamped = clamp(parsed, minValue, maxValue);
        if (clamped != parsed) {
            warnOnce(method, key, "out_of_range", options.get(key), "clamped");
        }
        return clamped;
    }

    private Double parseFiniteDouble(Object value) {
        if (value instanceof Number) {
            double parsed = ((Number) value).doubleValue();
            return Double.isFinite(parsed) ? parsed : null;
        }
        if (value instanceof String) {
            try {
                double parsed = Double.parseDouble((String) value);
                return Double.isFinite(parsed) ? parsed : null;
            } catch (NumberFormatException ignored) {
                return null;
            }
        }
        return null;
    }

    private static int clamp(int value, int minValue, int maxValue) {
        if (value < minValue) return minValue;
        if (value > maxValue) return maxValue;
        return value;
    }

    private static double clamp(double value, double minValue, double maxValue) {
        if (value < minValue) return minValue;
        if (value > maxValue) return maxValue;
        return value;
    }
}
