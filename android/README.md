# TiSynthEngine Android module

This folder contains the Android implementation of `ti.synthengine` 1.0.0. The public API is documented in the root [README](../README.md) and the [API reference](../documentation/api.md).

Release 1.0.0 exposes the same nineteen methods on both platforms. Effects and extra LFOs are opt-in; input gain starts at unity. See [new-feature integration](../documentation/guide.md#detect-required-capabilities) and [copyable examples](../documentation/examples.md#sustained-game-motor). Use `start({ maxSequences: 4 })` for up to four independent native sequences. Retain each positive sequence ID for edits, stopping and state queries. `setTempo` controls beat sequences and synchronized effects; millisecond sequences keep fixed times. Categories (`music`, `effects`, `ui`, `ambience`), explicit sends and optional priority share one renderer and one effects chain. Use the matching official 1.0.0 packages and rebuild consumer apps after installing a native module.

## Runtime

The renderer runs in C++ through Oboe's floating-point audio callback. It requests low-latency mode and exclusive sharing when the device supports them, then falls back to a compatible stream when needed. Stream errors, including output-route disconnects, reopen the stream and refresh its sample rate. The module polls for `sequenceend` events only while accepted sequences exist. When Titanium destroys the root activity, the module shuts the engine down so that a cached process does not keep the output stream open.

The native engine provides:

- 1 to 32 voices with short steal and stop tails;
- sine, PolyBLEP square, PolyBLEP sawtooth, triangle, noise and custom wavetable sources;
- variable-rate sample-and-hold noise, per-voice low-pass filtering, variable pulse width and optional amplitude quantization;
- identified sustained voices, selective release and compatible 10 ms live edits;
- sample-clock sixteenth-note transport, step chords/gates, swing and arpeggios;
- optional shared stereo chorus, ping-pong delay, Schroeder reverb and creative saturation;
- two phase-preserving voice LFOs for cutoff/PWM/FM with free or native-tempo sync;
- fixed event gain and atomic chord publication;
- a lock-free audio-thread consumer for the native command queue;
- smoothed master volume and a stereo-linked lookahead limiter;
- `conservative`, `balanced`, `speakerSafe` and `raw` mixing profiles.

`build.gradle` resolves Oboe 1.11.0 through Prefab and extends Titanium's generated `Android.mk`. Supported ABIs are `arm64-v8a`, `armeabi-v7a`, `x86` and `x86_64`. The packaged AAR requires compile API 35 or newer and can be used by Titanium 13.2.0 projects.

`src/ti/synthengine/SynthDsp.java` is the host-testable mixing and limiter reference. The runtime renderer is in `jni/SynthOboeEngine.cpp`.

## Host tests

Run from this directory:

```sh
test_dir=$(mktemp -d /tmp/ti-synth-test.XXXXXX)
javac -d "$test_dir" \
  src/ti/synthengine/SynthContract.java \
  src/ti/synthengine/SynthStudioContract.java \
  test/ti/synthengine/SynthContractRegression.java \
  src/ti/synthengine/SynthDsp.java \
  test/ti/synthengine/SynthDspRegression.java
java -cp "$test_dir" ti.synthengine.SynthContractRegression
java -cp "$test_dir" ti.synthengine.SynthDspRegression
```

Build the distributable module with the Titanium CLI from `android/`. The expected archive is `dist/ti.synthengine-android-1.0.0.zip`.

Binaural HRTF data: copyright 1994 MIT Media Laboratory, measured by Bill Gardner and Keith Martin. Use is permitted with attribution. See [MIT KEMAR](https://sound.media.mit.edu/resources/KEMAR.html) and the module's third-party notices.
