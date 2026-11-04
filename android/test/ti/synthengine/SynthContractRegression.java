package ti.synthengine;

import java.util.HashMap;
import java.util.Map;

public final class SynthContractRegression {
    private static final double MAX_FREQUENCY = 19845.0;

    public static void main(String[] args) throws java.io.IOException {
        assertEquals("2.0.0", SynthContract.MODULE_VERSION, "public API version");
        assertTrue(SynthContract.validateStart(null).accepted, "omitted start options");
        assertEquals(8, SynthContract.DEFAULT_MAX_VOICES, "default voices");
        assertEquals("conservative", SynthContract.DEFAULT_MIXING_PROFILE, "default profile");
        assertEquals(32, SynthContract.MAX_MAX_VOICES, "voice capacity");

        assertAccepted(SynthContract.validateTone(map(), MAX_FREQUENCY), "default tone");
        assertAccepted(SynthContract.validateTone(map("frequency", 440.0), MAX_FREQUENCY), "frequency tone");
        assertAccepted(SynthContract.validateTone(map("note", "C#4"), MAX_FREQUENCY), "note tone");
        assertRejected(SynthContract.validateTone(map("frequencies", new Object[]{440.0}), MAX_FREQUENCY),
                "playTone sequence removed");
        assertRejected(SynthContract.validateTone(map("volume", 3.0), MAX_FREQUENCY), "strict volume");
        assertRejected(SynthContract.validateTone(map("volume", true), MAX_FREQUENCY), "boolean is not numeric");
        assertRejected(SynthContract.validateTone(map("duration", "500"), MAX_FREQUENCY), "numeric string rejected");
        assertRejected(SynthContract.validateTone(map("waveType", 1.5), MAX_FREQUENCY), "strict integer");
        assertRejectedWith(SynthContract.validateTone(map("frequency", null), MAX_FREQUENCY),
                "frequency", "non_numeric_or_non_finite", "present null is not omitted");
        assertRejectedWith(SynthContract.validateTone(map("frequencies", new Object[]{440.0}), MAX_FREQUENCY),
                "frequencies", "unsupported_option", "tone rejects unsupported sequence option neutrally");
        assertRejectedWith(SynthContract.validateTone(map("mystery", true), MAX_FREQUENCY),
                "mystery", "unsupported_option", "tone rejects unknown option");
        assertAccepted(SynthContract.validateTone(map(
                "frequency", 440.0,
                "noiseRate", 900.0,
                "noiseRateEnd", 7200.0,
                "lowPassHz", 2800.0,
                "pulseWidth", 0.25,
                "pulseWidthEnd", 0.75,
                "bitDepth", 8), MAX_FREQUENCY), "character controls");
        assertAccepted(SynthContract.validateTone(map(
                "frequency", 440.0,
                "waveType", 5,
                "waveTable", new Object[]{-1.0, -0.2, 0.7, 1.0, 0.1}),
                MAX_FREQUENCY), "custom wavetable");
        assertRejectedWith(SynthContract.validateTone(map("waveType", 5), MAX_FREQUENCY),
                "waveTable", "missing_required", "wavetable waveform needs samples");
        assertRejectedWith(SynthContract.validateTone(map(
                "waveTable", new Object[]{0.0}), MAX_FREQUENCY),
                "waveTable", "invalid_sample_count", "wavetable minimum");
        assertRejectedWith(SynthContract.validateTone(map(
                "waveTable", new Object[]{-1.0, 1.1}), MAX_FREQUENCY),
                "waveTable", "out_of_range", "wavetable sample range");
        assertRejectedWith(SynthContract.validateTone(map("bitDepth", 1), MAX_FREQUENCY),
                "bitDepth", "out_of_range", "bit depth excludes one bit");
        assertRejectedWith(SynthContract.validateTone(map("pulseWidthEnd", 0.99), MAX_FREQUENCY),
                "pulseWidthEnd", "out_of_range", "pulse-width sweep range");

        assertAccepted(SynthContract.validateChord(
                map("frequencies", new Object[]{440.0, 660.0}), MAX_FREQUENCY), "frequency chord");
        assertAccepted(SynthContract.validateChord(
                map("notes", new Object[]{"C4", "E4", "G4"}), MAX_FREQUENCY), "note chord");
        assertAccepted(SynthContract.validateChord(
                map("frequencies", new Object[]{220.0, 330.0}, "pulseWidth", 0.3,
                        "lowPassHz", 4000.0, "bitDepth", 8), MAX_FREQUENCY),
                "character chord");
        assertRejected(SynthContract.validateChord(
                map("frequencies", new Object[]{}), MAX_FREQUENCY), "empty chord");
        assertRejected(SynthContract.validateChord(
                map("frequencies", new Object[]{440.0}, "notes", new Object[]{"A4"}), MAX_FREQUENCY),
                "ambiguous chord");
        assertRejectedWith(SynthContract.validateChord(
                map("frequencies", new Object[]{440.0}, "frequencyEnd", 880.0), MAX_FREQUENCY),
                "frequencyEnd", "unsupported_option", "chord rejects sweep option");
        assertRejectedWith(SynthContract.validateChord(
                map("frequencies", new Object[]{440.0}, "pan", 0.5), MAX_FREQUENCY),
                "pan", "unsupported_option", "chord rejects ignored pan option");

        assertRejected(SynthContract.validateStart(map("maxVoices", 33)), "voice upper bound");
        assertRejectedWith(SynthContract.validateStart(map("latency", "low")),
                "latency", "unsupported_option", "start rejects unknown option");
        assertAccepted(SynthContract.validateStart(
                map("maxVoices", 32, "mixingProfile", "speakerSafe")), "stress capacity");
        assertAccepted(SynthContract.validateStart(map("maxVoices", 8)),
                "start without an audio session");
        assertAccepted(SynthContract.validateStart(map("audioSession", "playback")),
                "playback audio session");
        assertAccepted(SynthContract.validateStart(map("audioSession", " Ambient ")),
                "ambient audio session ignores case and whitespace");
        assertRejectedWith(SynthContract.validateStart(map("audioSession", "record")),
                "audioSession", "unsupported_value", "start rejects an unknown audio session");
        assertRejectedWith(SynthContract.validateStart(map("audioSession", 1)),
                "audioSession", "not_string", "start rejects a non-string audio session");
        assertRejectedWith(SynthContract.validateSetVolume(map("gain", 0.5)),
                "gain", "unsupported_option", "volume rejects unknown option");

        expressiveContract();
        heldContract();
        record("playTone", map("spatialX", -1.0, "spatialY", 1.0), SynthContract.validateTone(map("spatialX", -1.0, "spatialY", 1.0), MAX_FREQUENCY));
        record("playTone", map("spatialY", 1.01), SynthContract.validateTone(map("spatialY", 1.01), MAX_FREQUENCY));
        record("playTone", map("spatialY", true), SynthContract.validateTone(map("spatialY", true), MAX_FREQUENCY));
        record("playTone", map("spatialX", .2, "pan", 0.0), SynthContract.validateTone(map("spatialX", .2, "pan", 0.0), MAX_FREQUENCY));
        Map<String,Object> spatialChord = map("frequencies", new Object[]{440.0, 660.0}, "spatialY", -.5);
        record("playChord", spatialChord, SynthContract.validateChord(spatialChord, MAX_FREQUENCY));
        writeOrVerifyCorpus();

        System.out.println("SynthContractRegression: all tests passed");
    }

    private static final java.util.List<String> corpus = new java.util.ArrayList<>();

    private static SynthContract.Validation tone(Object... entries) {
        Map<String, Object> options = map(entries);
        return record("playTone", options, SynthContract.validateTone(options, MAX_FREQUENCY));
    }

    private static SynthContract.Validation chord(Object... entries) {
        Map<String, Object> options = map(entries);
        return record("playChord", options, SynthContract.validateChord(options, MAX_FREQUENCY));
    }

    /**
     * Every expressive-contract case is also written as one JSON line. The
     * iOS contract is replayed against the same file, so the two ports cannot
     * drift apart silently. Regenerate with -Dsynth.corpus.out=<path>.
     */
    private static SynthContract.Validation record(String method, Map<String, Object> options,
            SynthContract.Validation result) {
        StringBuilder line = new StringBuilder();
        line.append("{\"method\":").append(json(method))
                .append(",\"max\":").append(json(MAX_FREQUENCY))
                .append(",\"options\":").append(json(options))
                .append(",\"accepted\":").append(result.accepted);
        if (!result.accepted) {
            line.append(",\"key\":").append(json(result.key))
                    .append(",\"reason\":").append(json(result.reason));
        }
        corpus.add(line.append("}").toString());
        return result;
    }

    @SuppressWarnings("unchecked")
    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof String) {
            return "\"" + ((String) value).replace("\\", "\\\\").replace("\"", "\\\"") + "\"";
        }
        if (value instanceof Double) {
            double d = (Double) value;
            return d == Math.rint(d) && Math.abs(d) < 1e9 ? String.valueOf((long) d) + ".0" : Double.toString(d);
        }
        if (value instanceof Number || value instanceof Boolean) return value.toString();
        if (value instanceof Object[]) {
            StringBuilder out = new StringBuilder("[");
            Object[] items = (Object[]) value;
            for (int i = 0; i < items.length; i++) out.append(i > 0 ? "," : "").append(json(items[i]));
            return out.append("]").toString();
        }
        Map<String, Object> object = (Map<String, Object>) value;
        StringBuilder out = new StringBuilder("{");
        boolean first = true;
        for (String key : new java.util.TreeSet<>(object.keySet())) {
            out.append(first ? "" : ",").append(json(key)).append(":").append(json(object.get(key)));
            first = false;
        }
        return out.append("}").toString();
    }

    private static void writeOrVerifyCorpus() throws java.io.IOException {
        String outPath = System.getProperty("synth.corpus.out");
        java.nio.file.Path path = outPath != null ? java.nio.file.Paths.get(outPath)
                : java.nio.file.Paths.get("..", "tests", "contract_corpus.jsonl");
        String expected = String.join("\n", corpus) + "\n";
        if (outPath != null) {
            java.nio.file.Files.write(path, expected.getBytes(java.nio.charset.StandardCharsets.UTF_8));
            return;
        }
        String actual = new String(java.nio.file.Files.readAllBytes(path), java.nio.charset.StandardCharsets.UTF_8);
        assertEquals(actual, expected, "tests/contract_corpus.jsonl matches the Java contract (regenerate with -Dsynth.corpus.out)");
    }

    private static void heldContract() {
        for(String method:new String[]{"noteOn","noteOff","updateVoice"}) {
            for(Object id:new Object[]{1,2147483647,0,-1,1.5,1.0000000001,0.9999999999,true,"1",null,2147483648.0}) {
                Map<String,Object> o=map("voiceId",id);
                if(method.equals("updateVoice"))o.put("volume",.5);
                SynthContract.Validation r=method.equals("noteOn") ? SynthContract.validateNoteOn(o,MAX_FREQUENCY) : method.equals("noteOff") ? SynthContract.validateNoteOff(o) : SynthContract.validateUpdateVoice(o,MAX_FREQUENCY);
                record(method,o,r);
                assertTrue(r.accepted==(id instanceof Integer && ((Integer)id)>0),"held ID "+method+" "+id);
            }
        }
        for(String key:new String[]{"duration","frequencyEnd","panEnd","noiseRateEnd","pulseWidthEnd","filterHzEnd","fmDepthEnd"}) {
            Map<String,Object> o=map("voiceId",1,key,100);
            assertRejected(record("noteOn",o,SynthContract.validateNoteOn(o,MAX_FREQUENCY)),"held sweep "+key);
        }
        Map<String,Object> on=map("voiceId",1,"attack",2000,"decay",4000,"sustain",.5,"release",4000);
        assertAccepted(record("noteOn",on,SynthContract.validateNoteOn(on,MAX_FREQUENCY)),"held full ADSR");
        for(String key:new String[]{"attack","release","waveType","filterType","waveTable","bitDepth","detune"}) {
            Map<String,Object> o=map("voiceId",1,key,1);
            assertRejected(record("updateVoice",o,SynthContract.validateUpdateVoice(o,MAX_FREQUENCY)),"immutable "+key);
        }
        Map<String,Object> update=map("voiceId",1,"note","A4","filterHz",500.0,"filterQ",2.0,"fmRatio",2.0);
        assertAccepted(record("updateVoice",update,SynthContract.validateUpdateVoice(update,MAX_FREQUENCY)),"partial source-compatible ranges");
        for(Map<String,Object> o:java.util.Arrays.asList(map(),map("voiceId",1),map("voiceId",1,"volume",true),map("voiceId",1,"note","bad"),map("voiceId",1,"note","A4","frequency",440))) {
            assertRejected(record("updateVoice",o,SynthContract.validateUpdateVoice(o,MAX_FREQUENCY)),"invalid update");
        }
    }

    private static void expressiveContract() {
        // Decay and sustain.
        assertAccepted(tone("decay", 200, "sustain", 0.4, "attack", 5, "duration", 800), "decay and sustain");
        assertAccepted(tone("decay", 450, "attack", 50, "duration", 500), "decay exactly fills the budget");
        assertAccepted(tone("decay", 0, "sustain", 1.0), "explicit neutral envelope");
        assertRejectedWith(tone("decay", 451, "attack", 50, "duration", 500),
                "decay", "decay_exceeds_remaining_duration", "decay one over the budget");
        assertRejectedWith(tone("decay", 700),
                "decay", "decay_exceeds_remaining_duration", "default attack counts toward the decay budget");
        assertAccepted(tone("decay", 1, "duration", 30), "default attack is clamped to the duration for the budget");
        assertRejectedWith(tone("decay", 2, "duration", 30),
                "decay", "decay_exceeds_remaining_duration", "clamped default attack leaves one sample");
        assertRejectedWith(tone("decay", 4001, "duration", 60000),
                "decay", "out_of_range", "decay upper bound");
        assertRejectedWith(tone("decay", 1.5), "decay", "not_integer", "decay is an integer");
        assertRejectedWith(tone("sustain", 1.1), "sustain", "out_of_range", "sustain upper bound");
        assertRejectedWith(tone("sustain", -0.1), "sustain", "out_of_range", "sustain lower bound");
        assertRejectedWith(tone("sustain", 0.5),
                "sustain", "sustain_without_decay", "sustain below 1 needs a decay");
        assertAccepted(tone("sustain", 1.0), "sustain 1 needs no decay");
        assertAccepted(tone("sustain", 0.0, "decay", 100), "silent sustain with a decay");

        // Resonant filter.
        assertAccepted(tone("filterType", "lowpass", "filterHz", 800.0, "filterQ", 4.0), "lowpass filter");
        assertAccepted(tone("filterType", " BandPass ", "filterHz", 1200.0, "filterHzEnd", 4000.0),
                "filter type ignores case and whitespace; cutoff sweep");
        assertAccepted(tone("filterType", "highpass"), "filter with default cutoff and Q");
        assertAccepted(tone("filterType", "none"), "explicit no filter");
        assertAccepted(tone("filterType", "lowpass", "filterHzEnd", 0.0), "zero end cutoff disables the sweep");
        assertRejectedWith(tone("filterType", "notch"),
                "filterType", "unsupported_value", "unknown filter type");
        assertRejectedWith(tone("filterType", 3), "filterType", "not_string", "filter type must be a string");
        assertRejectedWith(tone("filterType", "lowpass", "filterHz", 19.0),
                "filterHz", "out_of_range", "cutoff lower bound");
        assertRejectedWith(tone("filterType", "lowpass", "filterHz", 20000.0),
                "filterHz", "out_of_range", "cutoff upper bound");
        assertRejectedWith(tone("filterType", "lowpass", "filterHzEnd", 5.0),
                "filterHzEnd", "out_of_range", "end cutoff is 0 or at least 20");
        assertRejectedWith(tone("filterType", "lowpass", "filterQ", 0.4),
                "filterQ", "out_of_range", "Q lower bound");
        assertRejectedWith(tone("filterType", "lowpass", "filterQ", 10.5),
                "filterQ", "out_of_range", "Q upper bound");
        assertRejectedWith(tone("filterHz", 800.0),
                "filterHz", "filter_type_required", "cutoff without a filter type");
        assertRejectedWith(tone("filterType", "none", "filterQ", 2.0),
                "filterQ", "filter_type_required", "Q with filter type none");
        assertRejectedWith(tone("filterHzEnd", 3000.0),
                "filterHzEnd", "filter_type_required", "end cutoff without a filter type");

        // FM.
        assertAccepted(tone("fmDepth", 2.0, "fmRatio", 3.5), "fm on the default sine");
        assertAccepted(tone("fmDepth", 3.0, "fmDepthEnd", 0.0, "fmRatio", 1.4142), "fm index that decays to nothing");
        assertAccepted(tone("fmDepth", 0.0, "fmDepthEnd", 4.0), "fm index that swells");
        assertAccepted(tone("waveType", 1, "fmDepth", 0.0), "zero fm depth on another wave is inert");
        assertRejectedWith(tone("fmDepth", 11.0), "fmDepth", "out_of_range", "fm depth upper bound");
        assertRejectedWith(tone("fmDepth", 1.0, "fmRatio", 0.05), "fmRatio", "out_of_range", "fm ratio lower bound");
        assertRejectedWith(tone("fmDepth", 1.0, "fmRatio", 17.0), "fmRatio", "out_of_range", "fm ratio upper bound");
        assertRejectedWith(tone("fmDepthEnd", -0.1), "fmDepthEnd", "out_of_range", "fm end depth lower bound");
        assertRejectedWith(tone("fmDepth", 2.0, "waveType", 1),
                "fmDepth", "fm_requires_sine", "fm needs a sine carrier");
        assertRejectedWith(tone("fmDepthEnd", 2.0, "waveType", 2),
                "fmDepthEnd", "fm_requires_sine", "fm sweep needs a sine carrier");
        assertRejectedWith(tone("fmRatio", 2.0),
                "fmRatio", "fm_depth_required", "fm ratio without depth");

        // Detune.
        assertAccepted(tone("note", "A4", "detune", -7.5), "detune a note");
        assertAccepted(tone("frequency", 440.0, "detune", 1200.0), "detune up one octave");
        assertRejectedWith(tone("detune", 1201.0), "detune", "out_of_range", "detune upper bound");
        assertRejectedWith(tone("detune", "5"), "detune", "non_numeric_or_non_finite", "detune is numeric");
        assertRejectedWith(tone("frequency", 15000.0, "detune", 600.0),
                "detune", "out_of_range", "detuned pitch above the limit");
        assertRejectedWith(tone("frequency", 1.0, "detune", -1200.0),
                "detune", "out_of_range", "detuned pitch below 1 Hz");
        assertRejectedWith(tone("frequency", 440.0, "frequencyEnd", 15000.0, "detune", 600.0),
                "detune", "out_of_range", "detuned sweep target above the limit");
        assertRejectedWith(tone("detunes", new Object[]{1.0}),
                "detunes", "unsupported_option", "tone has no per-note detunes");

        // Chords: fixed shaping only.
        assertAccepted(chord("notes", new Object[]{"C4", "E4", "G4"}, "decay", 300, "sustain", 0.5,
                "duration", 1500, "filterType", "lowpass", "filterHz", 900.0, "filterQ", 2.0,
                "fmDepth", 1.5, "fmRatio", 2.0, "detunes", new Object[]{-8.0, 0.0, 8.0}),
                "expressive chord");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "filterType", "lowpass", "filterHzEnd", 2000.0),
                "filterHzEnd", "unsupported_option", "chord rejects a cutoff sweep");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "fmDepth", 1.0, "fmDepthEnd", 0.0),
                "fmDepthEnd", "unsupported_option", "chord rejects an fm sweep");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "detune", 5.0),
                "detune", "unsupported_option", "chord uses detunes, not detune");
        assertRejectedWith(chord("notes", new Object[]{"C4", "E4"}, "detunes", new Object[]{1.0, 2.0, 3.0}),
                "detunes", "too_many_values", "more detunes than pitches");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "detunes", 5.0),
                "detunes", "not_array", "detunes must be an array");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "detunes", new Object[]{1300.0}),
                "detunes", "out_of_range", "a detune beyond an octave");
        assertRejectedWith(chord("frequencies", new Object[]{440.0, 19000.0}, "detunes", new Object[]{0.0, 600.0}),
                "detunes", "out_of_range", "a detuned chord pitch above the limit");
        assertAccepted(chord("frequencies", new Object[]{440.0, 19000.0}, "detunes", new Object[]{600.0}),
                "missing detunes count as zero");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "duration", 100, "attack", 10, "decay", 95),
                "decay", "decay_exceeds_remaining_duration", "chord decay budget");
        assertRejectedWith(chord("notes", new Object[]{"C4"}, "fmDepth", 1.0, "waveType", 3),
                "fmDepth", "fm_requires_sine", "chord fm needs a sine carrier");

        // Patterns: root values are inherited and every sounding step is checked on its own.
    }

    private static Map<String, Object> map(Object... entries) {
        Map<String, Object> result = new HashMap<>();
        for (int i = 0; i < entries.length; i += 2) {
            result.put((String) entries[i], entries[i + 1]);
        }
        return result;
    }

    private static Object[] steps(int count) {
        Object[] result = new Object[count];
        for (int i = 0; i < count; i++) result[i] = map("frequency", 440.0);
        return result;
    }

    private static void assertAccepted(SynthContract.Validation result, String message) {
        assertTrue(result.accepted, message + " rejected: " + result.key + "/" + result.reason);
    }

    private static void assertRejected(SynthContract.Validation result, String message) {
        assertTrue(!result.accepted, message + " accepted unexpectedly");
    }

    private static void assertRejectedWith(SynthContract.Validation result, String key,
            String reason, String message) {
        assertRejected(result, message);
        assertEquals(key, result.key, message + " key");
        assertEquals(reason, result.reason, message + " reason");
    }

    private static void assertTrue(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private static void assertEquals(Object expected, Object actual, String message) {
        if (!expected.equals(actual)) {
            throw new AssertionError(message + ": expected " + expected + ", got " + actual);
        }
    }
}
