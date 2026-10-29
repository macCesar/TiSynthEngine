# TiSynthEngine iOS module

This folder contains the iOS implementation of `ti.synthengine` 1.0.1. The public API is documented in the root [README](../README.md) and the [API reference](../documentation/api.md).

Release 1.0.0 exposes the same nineteen methods on both platforms. Effects and extra LFOs are opt-in; input gain starts at unity. See [new-feature integration](../documentation/guide.md#detect-required-capabilities) and [copyable examples](../documentation/examples.md#sustained-game-motor). Use `start({ maxSequences: 4 })` for up to four independent native sequences. Retain each positive sequence ID for edits, stopping and state queries. `setTempo` controls beat sequences and synchronized effects; millisecond sequences keep fixed times. Categories (`music`, `effects`, `ui`, `ambience`), explicit sends and optional priority share one renderer and one effects chain. Use the current official 1.0.1 packages and rebuild consumer apps after installing a native module.

## Runtime

The renderer uses `AVAudioEngine` and `AVAudioSourceNode` at the active audio session sample rate. It observes route and engine-configuration changes and resumes the graph when a hardware transition stops it.

The native engine provides:

- 1 to 32 voices with short steal and stop tails;
- sine, PolyBLEP square, PolyBLEP sawtooth, triangle, noise and custom wavetable sources;
- variable-rate sample-and-hold noise, per-voice low-pass filtering, variable pulse width and optional amplitude quantization;
- identified sustained voices, selective release and compatible 10 ms live edits;
- sample-clock sixteenth-note transport, step chords/gates, swing and arpeggios;
- optional shared stereo chorus, ping-pong delay, Schroeder reverb and creative saturation;
- two phase-preserving voice LFOs for cutoff/PWM/FM with free or native-tempo sync;
- fixed event gain and atomic chord publication;
- a lock-free render-thread consumer for the native command queue;
- smoothed master volume and a stereo-linked lookahead limiter;
- `conservative`, `balanced`, `speakerSafe` and `raw` mixing profiles.

The module targets iOS 15 or newer. The build configuration uses Titanium SDK 13.4.1.GA. Apps using the module need Titanium SDK 13.2.0.GA or newer, as declared in the module manifest. The archive supports device, simulator and Mac Catalyst builds.

Build the distributable module with the Titanium CLI from `ios/`. The expected archive is `dist/ti.synthengine-iphone-1.0.1.zip`.

Binaural HRTF data: copyright 1994 MIT Media Laboratory, measured by Bill Gardner and Keith Martin. Use is permitted with attribution. See [MIT KEMAR](https://sound.media.mit.edu/resources/KEMAR.html) and the module's third-party notices.
