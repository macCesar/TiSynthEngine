package ti.synthengine;

import java.util.Map;

/**
 * TiSynthEngine public contract validation.
 *
 * This class deliberately has no Titanium or Android dependencies so the API
 * contract can be regression-tested on the host without touching the DSP.
 */
final class SynthContract {

    static final String API_VERSION = "1.1.0";

    static final int DEFAULT_MAX_VOICES = 8;
    static final String DEFAULT_MIXING_PROFILE = "conservative";
    static final String DEFAULT_AUDIO_SESSION = "playback";
    static final double DEFAULT_FREQUENCY_HZ = 440.0;
    static final int DEFAULT_DURATION_MS = 500;
    static final int DEFAULT_ATTACK_MS = 50;
    static final int DEFAULT_RELEASE_MS = 50;
    static final double DEFAULT_VOLUME = 1.0;
    static final int DEFAULT_WAVE_TYPE = 0;
    static final double DEFAULT_PAN = 0.0;
    static final double DEFAULT_FREQUENCY_END_HZ = 0.0;
    static final double DEFAULT_LFO_FREQUENCY_HZ = 0.0;
    static final double DEFAULT_LFO_DEPTH = 0.0;
    static final double DEFAULT_NOISE_RATE_HZ = 0.0;
    static final double DEFAULT_LOW_PASS_HZ = 0.0;
    static final double DEFAULT_PULSE_WIDTH = 0.5;
    static final int DEFAULT_BIT_DEPTH = 0;
    static final double DEFAULT_PAN_SPREAD = 0.0;
    static final double DEFAULT_BPM = 120.0;
    static final double DEFAULT_SWING = 0.0;
    static final double DEFAULT_STEP_DURATION_MS = 100.0;

    static final int MIN_MAX_VOICES = 1;
    static final int MAX_MAX_VOICES = 32;
    static final double MIN_FREQUENCY_HZ = 1.0;
    static final int MIN_DURATION_MS = 1;
    static final int MAX_DURATION_MS = 60000;
    static final int MIN_ATTACK_MS = 0;
    static final int MAX_ATTACK_MS = 2000;
    static final int MIN_RELEASE_MS = 0;
    static final int MAX_RELEASE_MS = 4000;
    static final double MIN_VOLUME = 0.0;
    static final double MAX_VOLUME = 2.0;
    static final int MIN_WAVE_TYPE = 0;
    static final int MAX_WAVE_TYPE = 5;
    static final int MIN_WAVETABLE_SAMPLES = 2;
    static final int MAX_WAVETABLE_SAMPLES = 64;
    static final double MIN_PULSE_WIDTH = 0.05;
    static final double MAX_PULSE_WIDTH = 0.95;
    static final int MIN_BIT_DEPTH = 2;
    static final int MAX_BIT_DEPTH = 16;
    static final int MAX_SEQUENCE_STEPS = 512;
    static final double MIN_BPM = 20.0;
    static final double MAX_BPM = 300.0;
    static final double MIN_SWING = -0.75;
    static final double MAX_SWING = 0.75;
    static final double MAX_LFO = 20000.0;

    static final int DEFAULT_DECAY_MS = 0;
    static final int MAX_DECAY_MS = 4000;
    static final double DEFAULT_SUSTAIN = 1.0;
    static final String DEFAULT_FILTER_TYPE = "none";
    static final String[] FILTER_TYPES = {"none", "lowpass", "highpass", "bandpass"};
    static final double DEFAULT_FILTER_HZ = 1000.0;
    static final double MIN_FILTER_HZ = 20.0;
    static final double DEFAULT_FILTER_Q = 0.7071;
    static final double MIN_FILTER_Q = 0.5;
    static final double MAX_FILTER_Q = 10.0;
    static final double DEFAULT_FM_RATIO = 1.0;
    static final double MIN_FM_RATIO = 0.1;
    static final double MAX_FM_RATIO = 16.0;
    static final double DEFAULT_FM_DEPTH = 0.0;
    static final double MAX_FM_DEPTH = 10.0;
    static final double DEFAULT_DETUNE_CENTS = 0.0;
    static final double MAX_DETUNE_CENTS = 1200.0;

    static final class Validation {
        final boolean accepted;
        final String key;
        final String reason;
        final Object value;

        private Validation(boolean accepted, String key, String reason, Object value) {
            this.accepted = accepted;
            this.key = key;
            this.reason = reason;
            this.value = value;
        }

        static Validation accepted() {
            return new Validation(true, null, null, null);
        }

        static Validation rejected(String key, String reason, Object value) {
            return new Validation(false, key, reason, value);
        }
    }

    // Packet schema: amount, mask, seed-presence, seed, then stable low/high slots.
    static final String[] VARIATION_FIELDS={"volume","filterHz","filterQ","fmDepth","noiseRate","lowPassHz","pulseWidth","pitchCents"};
    static double[] variationPacket(Map<String,Object> options) {
        double[] out=new double[20];
        if(!contains(options,"variation"))return out;
        Map<String,Object> v=SynthStudioContract.map(options.get("variation"));
        SynthStudioContract.keys(v,"amount","ranges","seed");
        out[0]=SynthStudioContract.number(v,"amount",1,0,1);
        if(v.containsKey("seed")) {
            out[2]=1;out[3]=SynthStudioContract.number(v,"seed",0,0,4294967295.0);
            if(out[3]!=Math.rint(out[3]))throw new IllegalArgumentException("seed");
        }
        if(v.containsKey("ranges")) {
            Map<String,Object> ranges=SynthStudioContract.map(v.get("ranges"));
            SynthStudioContract.keys(ranges,VARIATION_FIELDS);
            for(int i=0;i<8;i++)if(ranges.containsKey(VARIATION_FIELDS[i])) {
                Object raw=ranges.get(VARIATION_FIELDS[i]);
                if(!(raw instanceof Object[])||((Object[])raw).length!=2)throw new IllegalArgumentException("range");
                Object[] a=(Object[])raw;
                if(!(a[0] instanceof Number)||!(a[1] instanceof Number))throw new IllegalArgumentException("range");
                double lo=((Number)a[0]).doubleValue(),hi=((Number)a[1]).doubleValue();
                if(!Double.isFinite(lo)||!Double.isFinite(hi)||lo>hi)throw new IllegalArgumentException("range");
                out[1]=(int)out[1]|(1<<i);out[4+2*i]=lo;out[5+2*i]=hi;
            }
        }
        return out;
    }
    static Validation validateVariation(Map<String,Object> options,double frequency,double end,double maxHz) {
        if(!contains(options,"variation"))return Validation.accepted();
        try {
            double[] v=variationPacket(options);
            double[] min={0,20,.5,0,1,20,.05,-1200},max={2,maxHz,10,10,maxHz,maxHz,.95,1200};
            int wave=readInteger(options,"waveType",0),filter=contains(options,"filterType")?filterTypeIndex((String)options.get("filterType")):0;
            double noise=contains(options,"noiseRate")?finiteDouble(options.get("noiseRate")):0;
            double lowpass=contains(options,"lowPassHz")?finiteDouble(options.get("lowPassHz")):0;
            for(int i=0;i<8;i++)if(((int)v[1]&(1<<i))!=0) {
                if(v[4+2*i]<min[i]||v[5+2*i]>max[i]||((i==1||i==2)&&filter==0)||(i==3&&wave!=0)||(i==4&&(wave!=4||noise<1))||(i==5&&lowpass<20)||(i==6&&wave!=1))throw new IllegalArgumentException("range/source");
            }
            if(((int)v[1]&128)!=0) {
                double lo=Math.pow(2,v[0]*v[18]/1200),hi=Math.pow(2,v[0]*v[19]/1200);
                if(frequency*lo<1||frequency*hi>maxHz||(end>=1&&(end*lo<1||end*hi>maxHz)))throw new IllegalArgumentException("pitch");
            }
            return Validation.accepted();
        }catch(IllegalArgumentException|ClassCastException|NullPointerException e){return Validation.rejected("variation","invalid_variation",options.get("variation"));}
    }

    private SynthContract() {}

    static Validation validateStart(Map<String, Object> options) {
        Validation result = rejectUnknownOptions(options, "maxVoices", "mixingProfile",
                "audioSession", "maxSequences");
        if (!result.accepted) return result;
        result = optionalInteger(options, "maxVoices",
                MIN_MAX_VOICES, MAX_MAX_VOICES);
        if (!result.accepted) return result;

        result=optionalInteger(options,"maxSequences",1,4);if(!result.accepted)return result;
        if (contains(options, "mixingProfile")) {
            Object raw = options.get("mixingProfile");
            if (!(raw instanceof String)) {
                return Validation.rejected("mixingProfile", "not_string", raw);
            }
            String profile = ((String) raw).trim();
            if (!("raw".equalsIgnoreCase(profile)
                    || "conservative".equalsIgnoreCase(profile)
                    || "balanced".equalsIgnoreCase(profile)
                    || "speakerSafe".equalsIgnoreCase(profile))) {
                return Validation.rejected("mixingProfile", "unsupported_value", raw);
            }
        }

        if (contains(options, "audioSession")) {
            Object raw = options.get("audioSession");
            if (!(raw instanceof String)) {
                return Validation.rejected("audioSession", "not_string", raw);
            }
            String session = ((String) raw).trim();
            if (!("playback".equalsIgnoreCase(session)
                    || "ambient".equalsIgnoreCase(session))) {
                return Validation.rejected("audioSession", "unsupported_value", raw);
            }
        }
        return Validation.accepted();
    }

    static Validation validateSetVolume(Map<String, Object> options) {
        Validation result = rejectUnknownOptions(options, "volume");
        if (!result.accepted) return result;
        return optionalDouble(options, "volume", MIN_VOLUME, MAX_VOLUME);
    }

    static Validation validateVoiceId(Map<String, Object> options) {
        if (!contains(options, "voiceId")) return Validation.rejected("voiceId", "missing_required", null);
        Validation result=optionalInteger(options, "voiceId", 1, Integer.MAX_VALUE);
        if(result.accepted && ((Number)options.get("voiceId")).doubleValue()!=Math.rint(((Number)options.get("voiceId")).doubleValue()))
            return Validation.rejected("voiceId","not_integer",options.get("voiceId"));
        return result;
    }

    private static boolean numberIsZero(Object value){return value instanceof Number&&((Number)value).doubleValue()==0;}

    static Validation validateNoteOn(Map<String, Object> options, double maxFrequencyHz) {
        Validation result = rejectUnknownOptions(options, "voiceId", "frequency", "note", "attack", "decay", "sustain", "release", "volume",
                "waveType", "pan", "lfoFreq", "lfoDepth", "noiseRate", "lowPassHz", "pulseWidth", "waveTable", "bitDepth",
                "filterType", "filterHz", "filterQ", "fmRatio", "fmDepth", "detune", "spatialX", "spatialY", "modulations", "bus", "effectSend", "priority", "variation");
        if (!result.accepted) return result;
        result = validateVoiceId(options); if (!result.accepted) return result;
        Map<String, Object> tone = new java.util.HashMap<>(options);
        tone.remove("voiceId"); tone.remove("modulations");tone.put("duration", MAX_DURATION_MS);
        if(contains(options,"modulations"))try {
            result=optionalDouble(options,"fmRatio",MIN_FM_RATIO,MAX_FM_RATIO);if(!result.accepted)return result;
            double[] mods=SynthStudioContract.modulations(options.get("modulations"),(int)SynthStudioContract.number(options,"waveType",0,0,5),contains(options,"filterType")&&options.get("filterType") instanceof String?filterTypeIndex((String)options.get("filterType")):0);
            boolean fm=false;for(int i=0;i<2;i++)if(mods[i*6]!=0&&mods[i*6+2]==2)fm=true;
            if(fm&&(!contains(options,"fmDepth")||numberIsZero(options.get("fmDepth"))))tone.remove("fmRatio");
        } catch(IllegalArgumentException|ClassCastException e){return Validation.rejected("modulations","invalid_modulation",options.get("modulations"));}
        return validateTone(tone, maxFrequencyHz);
    }

    static Validation validateNoteOff(Map<String, Object> options) {
        Validation result = rejectUnknownOptions(options, "voiceId");
        return result.accepted ? validateVoiceId(options) : result;
    }

    static Validation validateUpdateVoice(Map<String, Object> options, double maxFrequencyHz) {
        Validation result = rejectUnknownOptions(options, "voiceId", "frequency", "note", "volume", "filterHz", "filterQ",
                "lfoFreq", "lfoDepth", "pulseWidth", "fmRatio", "fmDepth", "modulations", "pan", "spatialX", "spatialY", "noiseRate", "lowPassHz", "effectSend");
        if (!result.accepted) return result;
        result = validateVoiceId(options); if (!result.accepted) return result;
        if (options.size() == 1) return Validation.rejected("changes", "missing_required", null);
        if (contains(options,"frequency") && contains(options,"note")) return Validation.rejected("frequency","conflicting_pitch_fields",options.get("frequency"));
        result = optionalDouble(options,"frequency",MIN_FREQUENCY_HZ,maxFrequencyHz); if(!result.accepted) return result;
        if(contains(options,"note")) {
            result=validNote(options.get("note"),"note"); if(!result.accepted) return result;
            if(parseNoteToFrequency((String)options.get("note"))>maxFrequencyHz) return Validation.rejected("note","out_of_range",options.get("note"));
        }
        if(contains(options,"modulations"))try {SynthStudioContract.modulations(options.get("modulations"),-1,-1);}
        catch(IllegalArgumentException e){return Validation.rejected("modulations","invalid_modulation",options.get("modulations"));}
        return validateVoiceOptions(options,maxFrequencyHz,true);
    }

    // Snapshot complete accepted recipes on the control thread. Arrays and nested
    // dictionaries belong to this revision, never to mutable application objects.
    static Object toneSnapshot(Object value) {
        if(value instanceof Map<?,?>) {
            Map<String,Object> copy=new java.util.HashMap<>();
            for(Map.Entry<?,?> e:((Map<?,?>)value).entrySet())copy.put((String)e.getKey(),toneSnapshot(e.getValue()));
            return copy;
        }
        if(value instanceof Object[]) {
            Object[] a=(Object[])value,copy=new Object[a.length];
            for(int i=0;i<a.length;i++)copy[i]=toneSnapshot(a[i]);return copy;
        }
        return value;
    }
    @SuppressWarnings("unchecked")
    static Map<String,Object> mergeTone(Map<String,Object> previous,Map<String,Object> changes,double maxHz) {
        if(changes==null)throw new IllegalArgumentException("tone options");
        if(changes.containsKey("note")&&changes.containsKey("frequency"))throw new IllegalArgumentException("pitch");
        Map<String,Object> merged=previous==null?new java.util.HashMap<>():new java.util.HashMap<>(previous);
        if(changes.containsKey("note"))merged.remove("frequency");
        if(changes.containsKey("frequency"))merged.remove("note");
        merged.putAll(changes);
        Validation interval=optionalInteger(merged,"intervalMs",1,60000);
        if(!merged.containsKey("intervalMs")||!interval.accepted||((Number)merged.get("intervalMs")).doubleValue()!=Math.rint(((Number)merged.get("intervalMs")).doubleValue()))throw new IllegalArgumentException("intervalMs");
        Map<String,Object> tone=new java.util.HashMap<>(merged);tone.remove("intervalMs");
        if(!validateTone(tone,maxHz).accepted)throw new IllegalArgumentException("tone recipe");
        return (Map<String,Object>)toneSnapshot(merged);
    }

    static Validation validateTone(Map<String, Object> options, double maxFrequencyHz) {
        Validation result = rejectUnknownOptions(options,
                "frequency", "note", "duration", "attack", "release", "volume",
                "waveType", "pan", "panEnd", "frequencyEnd", "lfoFreq", "lfoDepth",
                "noiseRate", "noiseRateEnd", "lowPassHz", "pulseWidth", "pulseWidthEnd",
                "waveTable", "bitDepth", "decay", "sustain", "filterType", "filterHz",
                "filterHzEnd", "filterQ", "fmRatio", "fmDepth", "fmDepthEnd", "detune", "spatialX", "spatialY", "bus", "effectSend", "priority", "variation");
        if (!result.accepted) return result;

        boolean hasFrequency = contains(options, "frequency");
        boolean hasNote = contains(options, "note");
        if (hasFrequency && hasNote) {
            return Validation.rejected("frequency", "conflicting_pitch_fields", options.get("frequency"));
        }
        if (hasFrequency) {
            result = optionalDouble(options, "frequency", MIN_FREQUENCY_HZ, maxFrequencyHz);
            if (!result.accepted) return result;
        }
        if (hasNote) {
            result = validNote(options.get("note"), "note");
            if (!result.accepted) return result;
        }

        result = validateVoiceOptions(options, maxFrequencyHz, true);
        if (!result.accepted) return result;
        result = validateWaveTableRequirement(options, DEFAULT_WAVE_TYPE, false);
        if (!result.accepted) return result;
        result = validateExplicitEnvelope(options);
        if (!result.accepted) return result;
        result = validateExpressiveRules(options, readInteger(options, "duration", DEFAULT_DURATION_MS));
        if (!result.accepted) return result;
        double toneFrequency = hasNote ? parseNoteToFrequency((String) options.get("note"))
                : (hasFrequency ? finiteDouble(options.get("frequency")) : DEFAULT_FREQUENCY_HZ);
        result=validateDetuneRange(options, toneFrequency, maxFrequencyHz);
        if(!result.accepted)return result;
        double ratio=detuneRatio(contains(options,"detune")?finiteDouble(options.get("detune")):0);
        return validateVariation(options,toneFrequency*ratio,(contains(options,"frequencyEnd")?finiteDouble(options.get("frequencyEnd")):0)*ratio,maxFrequencyHz);
    }

    static Validation validateChord(Map<String, Object> options, double maxFrequencyHz) {
        Validation result = rejectUnknownOptions(options,
                "frequencies", "notes", "duration", "attack", "release", "volume",
                "waveType", "panSpread", "pans", "noiseRate", "lowPassHz",
                "pulseWidth", "waveTable", "bitDepth", "decay", "sustain", "filterType",
                "filterHz", "filterQ", "fmRatio", "fmDepth", "detunes", "spatialX", "spatialY", "bus", "effectSend", "priority", "variation");
        if (!result.accepted) return result;

        boolean hasFrequencies = contains(options, "frequencies");
        boolean hasNotes = contains(options, "notes");
        if (hasFrequencies == hasNotes) {
            return Validation.rejected("frequencies", hasFrequencies
                    ? "conflicting_pitch_fields" : "missing_required", null);
        }

        Object rawPitches = options.get(hasFrequencies ? "frequencies" : "notes");
        if (!(rawPitches instanceof Object[])) {
            return Validation.rejected(hasFrequencies ? "frequencies" : "notes", "not_array", rawPitches);
        }
        Object[] pitches = (Object[]) rawPitches;
        if (pitches.length < 1 || pitches.length > MAX_MAX_VOICES) {
            return Validation.rejected(hasFrequencies ? "frequencies" : "notes", "invalid_voice_count", pitches.length);
        }
        for (Object pitch : pitches) {
            result = hasFrequencies
                    ? finiteDoubleInRange(pitch, "frequencies", MIN_FREQUENCY_HZ, maxFrequencyHz)
                    : validNote(pitch, "notes");
            if (!result.accepted) return result;
        }

        result = validateVoiceOptions(options, maxFrequencyHz, false);
        if (!result.accepted) return result;
        result = validateWaveTableRequirement(options, DEFAULT_WAVE_TYPE, false);
        if (!result.accepted) return result;
        result = optionalDouble(options, "panSpread", 0.0, 1.0);
        if (!result.accepted) return result;

        if (contains(options, "pans")) {
            Object rawPans = options.get("pans");
            if (!(rawPans instanceof Object[])) {
                return Validation.rejected("pans", "not_array", rawPans);
            }
            Object[] pans = (Object[]) rawPans;
            if (pans.length > pitches.length) {
                return Validation.rejected("pans", "too_many_values", pans.length);
            }
            for (Object pan : pans) {
                result = finiteDoubleInRange(pan, "pans", -1.0, 1.0);
                if (!result.accepted) return result;
            }
        }
        result = validateExplicitEnvelope(options);
        if (!result.accepted) return result;

        Object[] detunes = null;
        if (contains(options, "detunes")) {
            Object rawDetunes = options.get("detunes");
            if (!(rawDetunes instanceof Object[])) {
                return Validation.rejected("detunes", "not_array", rawDetunes);
            }
            detunes = (Object[]) rawDetunes;
            if (detunes.length > pitches.length) {
                return Validation.rejected("detunes", "too_many_values", detunes.length);
            }
            for (Object detune : detunes) {
                result = finiteDoubleInRange(detune, "detunes", -MAX_DETUNE_CENTS, MAX_DETUNE_CENTS);
                if (!result.accepted) return result;
            }
        }

        result = validateExpressiveRules(options, readInteger(options, "duration", DEFAULT_DURATION_MS));
        if (!result.accepted) return result;
        if (detunes != null) {
            for (int i = 0; i < detunes.length; i++) {
                double cents = finiteDouble(detunes[i]);
                if (cents == 0.0) continue;
                double base = hasFrequencies ? finiteDouble(pitches[i]) : parseNoteToFrequency((String) pitches[i]);
                if (!frequencyInRange(base * detuneRatio(cents), maxFrequencyHz)) {
                    return Validation.rejected("detunes", "out_of_range", detunes[i]);
                }
            }
        }
        for(int i=0;i<pitches.length;i++) {
            double base=hasFrequencies?finiteDouble(pitches[i]):parseNoteToFrequency((String)pitches[i]);
            double ratio=detuneRatio(detunes!=null&&i<detunes.length?finiteDouble(detunes[i]):0);
            result=validateVariation(options,base*ratio,0,maxFrequencyHz);if(!result.accepted)return result;
        }
        return Validation.accepted();
    }

    @SuppressWarnings("unchecked")
    private static Validation validateWaveTableRequirement(Map<String, Object> options,
            int fallbackWaveType, boolean fallbackHasWaveTable) {
        int waveType = integerValue(options, "waveType", fallbackWaveType);
        boolean hasWaveTable = contains(options, "waveTable") || fallbackHasWaveTable;
        return waveType == 5 && !hasWaveTable
                ? Validation.rejected("waveTable", "missing_required", null)
                : Validation.accepted();
    }

    private static int integerValue(Map<String,Object> options,String key,int fallback) {return contains(options,key)?((Number)options.get(key)).intValue():fallback;}

    static double parseNoteToFrequency(String noteName) {
        if (noteName == null || noteName.trim().isEmpty()) return -1.0;
        String value = noteName.trim();
        String upper = value.toUpperCase();
        int position;
        int semitone;

        if (upper.startsWith("SOL")) { semitone = 7; position = 3; }
        else if (upper.startsWith("DO")) { semitone = 0; position = 2; }
        else if (upper.startsWith("RE")) { semitone = 2; position = 2; }
        else if (upper.startsWith("MI")) { semitone = 4; position = 2; }
        else if (upper.startsWith("FA")) { semitone = 5; position = 2; }
        else if (upper.startsWith("LA")) { semitone = 9; position = 2; }
        else if (upper.startsWith("SI") || upper.startsWith("TI")) { semitone = 11; position = 2; }
        else {
            position = 1;
            switch (upper.charAt(0)) {
                case 'C': semitone = 0; break;
                case 'D': semitone = 2; break;
                case 'E': semitone = 4; break;
                case 'F': semitone = 5; break;
                case 'G': semitone = 7; break;
                case 'A': semitone = 9; break;
                case 'B': semitone = 11; break;
                default: return -1.0;
            }
        }

        if (position < value.length()) {
            char accidental = value.charAt(position);
            if (accidental == '#') { semitone += 1; position += 1; }
            else if (accidental == 'b') { semitone -= 1; position += 1; }
        }

        int octave = 4;
        if (position < value.length()) {
            char digit = value.charAt(position);
            if (digit < '0' || digit > '9' || position + 1 != value.length()) return -1.0;
            octave = digit - '0';
        }
        int midi = (octave + 1) * 12 + semitone;
        return 440.0 * Math.pow(2.0, (midi - 69.0) / 12.0);
    }

    private static Validation validateSpatial(Map<String, Object> options) {
        Validation result = optionalDouble(options, "spatialX", -1.0, 1.0);
        if (!result.accepted) return result;
        result = optionalDouble(options, "spatialY", -1.0, 1.0);
        if (!result.accepted) return result;
        if (contains(options, "spatialX") || contains(options, "spatialY")) {
            for (String key : new String[]{"pan", "panEnd", "pans", "panSpread"}) {
                if (contains(options, key)) return Validation.rejected(key, "conflicting_spatial_fields", options.get(key));
            }
        }
        return Validation.accepted();
    }

    private static Validation validateVoiceOptions(Map<String, Object> options,
            double maxFrequencyHz, boolean allowSweep) {
        Validation result=optionalInteger(options,"priority",0,3);if(!result.accepted)return result;
        result=optionalDouble(options,"effectSend",0,1);if(!result.accepted)return result;
        if(contains(options,"bus"))try{SynthStudioContract.bus(options.get("bus"));}catch(IllegalArgumentException e){return Validation.rejected("bus","unsupported_value",options.get("bus"));}
        result = validateSpatial(options);
        if (!result.accepted) return result;
        result = optionalInteger(options, "duration", MIN_DURATION_MS, MAX_DURATION_MS);
        if (!result.accepted) return result;
        result = optionalInteger(options, "attack", MIN_ATTACK_MS, MAX_ATTACK_MS);
        if (!result.accepted) return result;
        result = optionalInteger(options, "release", MIN_RELEASE_MS, MAX_RELEASE_MS);
        if (!result.accepted) return result;
        result = optionalDouble(options, "volume", MIN_VOLUME, MAX_VOLUME);
        if (!result.accepted) return result;
        result = optionalInteger(options, "waveType", MIN_WAVE_TYPE, MAX_WAVE_TYPE);
        if (!result.accepted) return result;
        result = optionalDouble(options, "pan", -1.0, 1.0);
        if (!result.accepted) return result;
        result = optionalDouble(options, "noiseRate", 0.0, maxFrequencyHz);
        if (!result.accepted) return result;
        result = optionalDouble(options, "lowPassHz", 0.0, maxFrequencyHz);
        if (!result.accepted) return result;
        result = optionalDouble(options, "pulseWidth", MIN_PULSE_WIDTH, MAX_PULSE_WIDTH);
        if (!result.accepted) return result;
        result = optionalWaveTable(options, "waveTable");
        if (!result.accepted) return result;
        result = optionalBitDepth(options, "bitDepth");
        if (!result.accepted) return result;
        result = optionalInteger(options, "decay", 0, MAX_DECAY_MS);
        if (!result.accepted) return result;
        result = optionalDouble(options, "sustain", 0.0, 1.0);
        if (!result.accepted) return result;
        result = optionalFilterType(options, "filterType");
        if (!result.accepted) return result;
        result = optionalDouble(options, "filterHz", MIN_FILTER_HZ, maxFrequencyHz);
        if (!result.accepted) return result;
        result = optionalDouble(options, "filterQ", MIN_FILTER_Q, MAX_FILTER_Q);
        if (!result.accepted) return result;
        result = optionalDouble(options, "fmRatio", MIN_FM_RATIO, MAX_FM_RATIO);
        if (!result.accepted) return result;
        result = optionalDouble(options, "fmDepth", 0.0, MAX_FM_DEPTH);
        if (!result.accepted) return result;

        if (allowSweep) {
            result = optionalDouble(options, "panEnd", -1.0, 1.0);
            if (!result.accepted) return result;
            result = optionalDouble(options, "frequencyEnd", 0.0, maxFrequencyHz);
            if (!result.accepted) return result;
            result = optionalDouble(options, "lfoFreq", 0.0, MAX_LFO);
            if (!result.accepted) return result;
            result = optionalDouble(options, "lfoDepth", 0.0, MAX_LFO);
            if (!result.accepted) return result;
            result = optionalDouble(options, "noiseRateEnd", 0.0, maxFrequencyHz);
            if (!result.accepted) return result;
            result = optionalPulseWidthEnd(options, "pulseWidthEnd");
            if (!result.accepted) return result;
            result = optionalFilterHzEnd(options, "filterHzEnd", maxFrequencyHz);
            if (!result.accepted) return result;
            result = optionalDouble(options, "fmDepthEnd", 0.0, MAX_FM_DEPTH);
            if (!result.accepted) return result;
            result = optionalDouble(options, "detune", -MAX_DETUNE_CENTS, MAX_DETUNE_CENTS);
            if (!result.accepted) return result;
        }
        return Validation.accepted();
    }

    private static Validation optionalFilterType(Map<String, Object> options, String key) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        if (!(raw instanceof String)) return Validation.rejected(key, "not_string", raw);
        return filterTypeIndex((String) raw) >= 0
                ? Validation.accepted() : Validation.rejected(key, "unsupported_value", raw);
    }

    /** Index into FILTER_TYPES (0 means none), or -1 when the name is not allowed. */
    static int filterTypeIndex(String raw) {
        String value = raw.trim();
        for (int i = 0; i < FILTER_TYPES.length; i++) {
            if (FILTER_TYPES[i].equalsIgnoreCase(value)) return i;
        }
        return -1;
    }

    private static Validation optionalFilterHzEnd(Map<String, Object> options, String key,
            double maxFrequencyHz) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        Double parsed = finiteDouble(raw);
        if (parsed == null) return Validation.rejected(key, "non_numeric_or_non_finite", raw);
        if (parsed != 0.0 && (parsed < MIN_FILTER_HZ || parsed > maxFrequencyHz)) {
            return Validation.rejected(key, "out_of_range", raw);
        }
        return Validation.accepted();
    }

    private static double detuneRatio(double cents) {
        return Math.pow(2.0, cents / 1200.0);
    }

    private static boolean frequencyInRange(double frequency, double maxFrequencyHz) {
        return frequency >= MIN_FREQUENCY_HZ && frequency <= maxFrequencyHz;
    }

    /**
     * Rules that span several keys, evaluated on the effective values of one
     * sounding event (a pattern step already merged over its pattern root).
     */
    private static boolean variationEnablesFm(Map<String,Object> options) {
        try {double[] v=variationPacket(options);return v[0]>0&&((int)v[1]&8)!=0&&v[11]>0;}
        catch(IllegalArgumentException|ClassCastException e){return false;}
    }
    private static Validation validateExpressiveRules(Map<String, Object> eff, int durationMs) {
        int decay = readInteger(eff, "decay", DEFAULT_DECAY_MS);
        if (contains(eff, "sustain") && finiteDouble(eff.get("sustain")) < 1.0 && decay == 0) {
            return Validation.rejected("sustain", "sustain_without_decay", eff.get("sustain"));
        }
        if (decay > 0) {
            int attack = Math.min(readInteger(eff, "attack", DEFAULT_ATTACK_MS), Math.max(0, durationMs - 1));
            if (attack + decay > durationMs) {
                return Validation.rejected("decay", "decay_exceeds_remaining_duration", eff.get("decay"));
            }
        }

        boolean filtered = contains(eff, "filterType")
                && filterTypeIndex((String) eff.get("filterType")) > 0;
        if (!filtered) {
            for (String key : new String[]{"filterHz", "filterHzEnd", "filterQ"}) {
                if (contains(eff, key)) return Validation.rejected(key, "filter_type_required", eff.get(key));
            }
        }

        double depth = contains(eff, "fmDepth") ? finiteDouble(eff.get("fmDepth")) : DEFAULT_FM_DEPTH;
        boolean fmActive = depth > 0.0 || contains(eff, "fmDepthEnd") || variationEnablesFm(eff);
        if (fmActive && integerValue(eff, "waveType", DEFAULT_WAVE_TYPE) != 0) {
            String key = depth > 0.0 ? "fmDepth" : "fmDepthEnd";
            return Validation.rejected(key, "fm_requires_sine", eff.get(key));
        }
        if (contains(eff, "fmRatio") && !fmActive) {
            return Validation.rejected("fmRatio", "fm_depth_required", eff.get("fmRatio"));
        }
        return Validation.accepted();
    }

    /** Detune must leave the starting pitch, and any sweep target, inside the audible range. */
    private static Validation validateDetuneRange(Map<String, Object> eff, double frequency,
            double maxFrequencyHz) {
        if (!contains(eff, "detune")) return Validation.accepted();
        double cents = finiteDouble(eff.get("detune"));
        if (cents == 0.0) return Validation.accepted();
        double ratio = detuneRatio(cents);
        boolean inRange = frequencyInRange(frequency * ratio, maxFrequencyHz);
        if (inRange && contains(eff, "frequencyEnd")) {
            double end = finiteDouble(eff.get("frequencyEnd"));
            if (end != 0.0) inRange = frequencyInRange(end * ratio, maxFrequencyHz);
        }
        return inRange ? Validation.accepted()
                : Validation.rejected("detune", "out_of_range", eff.get("detune"));
    }

    private static Validation optionalWaveTable(Map<String, Object> options, String key) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        if (!(raw instanceof Object[])) return Validation.rejected(key, "not_array", raw);
        Object[] values = (Object[]) raw;
        if (values.length < MIN_WAVETABLE_SAMPLES || values.length > MAX_WAVETABLE_SAMPLES) {
            return Validation.rejected(key, "invalid_sample_count", values.length);
        }
        for (Object value : values) {
            Validation result = finiteDoubleInRange(value, key, -1.0, 1.0);
            if (!result.accepted) return result;
        }
        return Validation.accepted();
    }

    private static Validation optionalBitDepth(Map<String, Object> options, String key) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        Double parsed = finiteDouble(raw);
        if (parsed == null) return Validation.rejected(key, "non_numeric_or_non_finite", raw);
        double rounded = Math.rint(parsed);
        if (Math.abs(parsed - rounded) > 1e-9) return Validation.rejected(key, "not_integer", raw);
        if (rounded != 0.0 && (rounded < MIN_BIT_DEPTH || rounded > MAX_BIT_DEPTH)) {
            return Validation.rejected(key, "out_of_range", raw);
        }
        return Validation.accepted();
    }

    private static Validation optionalPulseWidthEnd(Map<String, Object> options, String key) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        Double parsed = finiteDouble(raw);
        if (parsed == null) return Validation.rejected(key, "non_numeric_or_non_finite", raw);
        if (parsed != 0.0 && (parsed < MIN_PULSE_WIDTH || parsed > MAX_PULSE_WIDTH)) {
            return Validation.rejected(key, "out_of_range", raw);
        }
        return Validation.accepted();
    }

    private static Validation validateExplicitEnvelope(Map<String, Object> options) {
        if (options == null) return Validation.accepted();
        int duration = readInteger(options, "duration", DEFAULT_DURATION_MS);
        int attack = readInteger(options, "attack", DEFAULT_ATTACK_MS);
        if (contains(options, "attack") && attack >= duration) {
            return Validation.rejected("attack", "attack_greater_or_equal_duration", attack);
        }
        if (contains(options, "release") && readInteger(options, "release", DEFAULT_RELEASE_MS)
                > Math.max(0, duration - attack)) {
            return Validation.rejected("release", "release_exceeds_remaining_duration",
                    options.get("release"));
        }
        return Validation.accepted();
    }

    private static Validation optionalNoteValue(Map<String, Object> options, String key) {
        if (!contains(options, key)) return Validation.accepted();
        Object raw = options.get(key);
        if (!(raw instanceof String)) return Validation.rejected(key, "not_string", raw);
        String value = ((String) raw).trim();
        if ("1n".equals(value) || "2n".equals(value) || "2n.".equals(value)
                || "4n".equals(value) || "4n.".equals(value)
                || "8n".equals(value) || "8n.".equals(value) || "8t".equals(value)
                || "16n".equals(value) || "16t".equals(value)) {
            return Validation.accepted();
        }
        return Validation.rejected(key, "unsupported_note_value", raw);
    }

    private static Validation validNote(Object raw, String key) {
        if (!(raw instanceof String)) return Validation.rejected(key, "not_string", raw);
        return parseNoteToFrequency((String) raw) >= MIN_FREQUENCY_HZ
                ? Validation.accepted()
                : Validation.rejected(key, "invalid_note", raw);
    }

    private static Validation optionalInteger(Map<String, Object> options, String key,
            int min, int max) {
        if (!contains(options, key)) return Validation.accepted();
        Double parsed = finiteDouble(options.get(key));
        if (parsed == null) return Validation.rejected(key, "non_numeric_or_non_finite", options.get(key));
        double rounded = Math.rint(parsed);
        if (Math.abs(parsed - rounded) > 1e-9) {
            return Validation.rejected(key, "not_integer", options.get(key));
        }
        if (rounded < min || rounded > max) {
            return Validation.rejected(key, "out_of_range", options.get(key));
        }
        return Validation.accepted();
    }

    private static Validation optionalDouble(Map<String, Object> options, String key,
            double min, double max) {
        if (!contains(options, key)) return Validation.accepted();
        return finiteDoubleInRange(options.get(key), key, min, max);
    }

    private static Validation finiteDoubleInRange(Object raw, String key, double min, double max) {
        Double parsed = finiteDouble(raw);
        if (parsed == null) return Validation.rejected(key, "non_numeric_or_non_finite", raw);
        if (parsed < min || parsed > max) return Validation.rejected(key, "out_of_range", raw);
        return Validation.accepted();
    }

    private static Validation rejectUnknownOptions(Map<String, Object> options,
            String... supportedKeys) {
        if (options == null) return Validation.accepted();
        for (String key : options.keySet()) {
            boolean supported = false;
            for (String supportedKey : supportedKeys) {
                if (supportedKey.equals(key)) {
                    supported = true;
                    break;
                }
            }
            if (!supported) {
                return Validation.rejected(key, "unsupported_option", options.get(key));
            }
        }
        return Validation.accepted();
    }

    private static boolean contains(Map<String, Object> options, String key) {
        return options != null && options.containsKey(key);
    }

    private static int readInteger(Map<String, Object> options, String key, int defaultValue) {
        if (!contains(options, key)) return defaultValue;
        return (int) Math.rint(finiteDouble(options.get(key)));
    }

    private static Double finiteDouble(Object value) {
        if (value instanceof Number) {
            double parsed = ((Number) value).doubleValue();
            return Double.isFinite(parsed) ? parsed : null;
        }
        return null;
    }
}
