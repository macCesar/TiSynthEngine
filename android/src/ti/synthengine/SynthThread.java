package ti.synthengine;

/**
 * Thin Java owner for the native Oboe engine. All synthesis and mixing runs in
 * Oboe's real-time float callback; Java only publishes control commands. The
 * class keeps its historical name because the JNI symbols are derived from it.
 */
public final class SynthThread {
    /** Layout of the extra voice parameters handed to the native renderer. */
    static final int EXTRA_DECAY_MS = 0;
    static final int EXTRA_SUSTAIN = 1;
    static final int EXTRA_FILTER_TYPE = 2;
    static final int EXTRA_FILTER_HZ = 3;
    static final int EXTRA_FILTER_HZ_END = 4;
    static final int EXTRA_FILTER_Q = 5;
    static final int EXTRA_FM_RATIO = 6;
    static final int EXTRA_FM_DEPTH = 7;
    /** NaN when the event has no modulation-depth sweep. */
    static final int EXTRA_FM_DEPTH_END = 8;
    static final int EXTRA_SPATIAL = 9;
    static final int EXTRA_SPATIAL_X = 10;
    static final int EXTRA_SPATIAL_Y = 11;
    static final int EXTRA_VOICE_ID = 12;
    static final int EXTRA_COUNT = 28;

    private long nativeHandle;

    public SynthThread(int requestedMaxVoices, int mixingProfile, int maxSequences) {
        nativeHandle = nativeCreate(requestedMaxVoices, mixingProfile,maxSequences);
    }

    public synchronized int getSampleRate() {
        long handle = nativeHandle;
        return handle != 0 ? nativeGetSampleRate(handle) : 44100;
    }

    public synchronized void setMasterVolume(double volume) {
        long handle = nativeHandle;
        if (handle != 0) nativeSetMasterVolume(handle, volume);
    }

    public synchronized boolean enqueueNote(
            double frequency, int durationMs, int attackMs, int releaseMs, double volume,
            int waveType, double pan, double panEnd, double freqEnd,
            double lfoFreq, double lfoDepth,
            double noiseRate, double noiseRateEnd, double lowPassHz,
            double pulseWidth, double pulseWidthEnd, int bitDepth, double[] waveTable,
            double[] extras) {
        long handle = nativeHandle;
        return handle == 0 || nativeEnqueueNote(handle, frequency, durationMs,
                attackMs, releaseMs, volume, waveType, pan, panEnd, freqEnd,
                lfoFreq, lfoDepth, noiseRate, noiseRateEnd, lowPassHz,
                pulseWidth, pulseWidthEnd, bitDepth, waveTable,
                extras);
    }

    public synchronized boolean enqueueChord(
            double[] frequencies, int durationMs, int attackMs, int releaseMs,
            double volume, int waveType, double[] pans, double noiseRate,
            double lowPassHz, double pulseWidth, int bitDepth, double[] waveTable,
            double[] extras) {
        long handle = nativeHandle;
        return handle == 0 || nativeEnqueueChord(handle, frequencies, durationMs,
                attackMs, releaseMs, volume, waveType, pans, noiseRate,
                lowPassHz, pulseWidth, bitDepth, waveTable, extras);
    }

    public synchronized int voiceMask(int voiceId) { return nativeHandle==0 ? -1 : nativeVoiceMask(nativeHandle,voiceId); }
    public synchronized boolean voiceCommand(int type,int voiceId,int mask,double[] values) {
        return nativeHandle==0 || nativeVoiceCommand(nativeHandle,type,voiceId,mask,values);
    }
    private static native int nativeVoiceMask(long handle,int voiceId);
    private static native boolean nativeVoiceCommand(long handle,int type,int voiceId,int mask,double[] values);

    public synchronized boolean masterProcessing(double[] packet) {return nativeHandle!=0 && nativeMasterProcessing(nativeHandle,packet);}
    private static native boolean nativeMasterProcessing(long handle,double[] packet);

    public synchronized boolean publishSequence(int id,double[] packet,boolean restart) {
        return nativeHandle!=0 && nativePublishSequence(nativeHandle,id,packet,restart);
    }
    public synchronized boolean stopSequence(int id) {return nativeHandle!=0&&nativeStopSequence(nativeHandle,id);}
    public synchronized double[] sequenceState(int id) {return nativeHandle==0?null:nativeSequenceState(nativeHandle,id);}
    public synchronized double[] sequenceEnds() {return nativeHandle==0?null:nativeSequenceEnds(nativeHandle);}
    public synchronized boolean setTempo(double bpm) {return nativeHandle!=0&&nativeSetTempo(nativeHandle,bpm);}
    private static native boolean nativePublishSequence(long handle,int id,double[] packet,boolean restart);
    private static native boolean nativeStopSequence(long handle,int id);
    private static native double[] nativeSequenceState(long handle,int id);
    private static native double[] nativeSequenceEnds(long handle);
    private static native boolean nativeSetTempo(long handle,double bpm);

    public synchronized boolean requestStopAll() {
        long handle = nativeHandle;
        return handle == 0 || nativeStopAll(handle);
    }

    public synchronized void requestShutdown() {
        long handle = nativeHandle;
        if (handle == 0) return;
        nativeHandle = 0;
        nativeDestroy(handle);
    }

    public synchronized boolean startAudio() { return nativeHandle != 0 && nativeStart(nativeHandle); }

    public synchronized double[] stopAndGetStats() {
        if(nativeHandle == 0) return null;
        nativeStatsControl(nativeHandle,3);
        return nativeGetStats(nativeHandle);
    }
    public synchronized double[] getStats() { return nativeHandle == 0 ? null : nativeGetStats(nativeHandle); }
    public synchronized void statsControl(int operation) { if(nativeHandle != 0) nativeStatsControl(nativeHandle, operation); }
    private static native double[] nativeGetStats(long handle);
    private static native void nativeStatsControl(long handle, int operation);
    private static native long nativeCreate(int maxVoices, int mixingProfile,int maxSequences);
    private static native int nativeGetSampleRate(long handle);
    private static native boolean nativeStart(long handle);
    private static native void nativeSetMasterVolume(long handle, double volume);
    private static native boolean nativeEnqueueNote(long handle, double frequency,
            int durationMs, int attackMs, int releaseMs, double volume, int waveType,
            double pan, double panEnd, double freqEnd, double lfoFreq, double lfoDepth,
            double noiseRate, double noiseRateEnd, double lowPassHz,
            double pulseWidth, double pulseWidthEnd, int bitDepth, double[] waveTable,
            double[] extras);
    private static native boolean nativeEnqueueChord(long handle, double[] frequencies,
            int durationMs, int attackMs, int releaseMs, double volume, int waveType,
            double[] pans, double noiseRate, double lowPassHz, double pulseWidth,
            int bitDepth, double[] waveTable, double[] extras);
    private static native boolean nativeStopAll(long handle);
    private static native void nativeDestroy(long handle);
}
