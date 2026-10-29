# Changelog

## [Unreleased]

### Changed

- Poll for Android `sequenceend` events only while accepted sequences exist. An idle engine no longer wakes the main thread every 10 ms, and a listener that restarts the engine during a `sequenceend` event cannot start a second poll chain.
- Shut the Android engine down when Titanium destroys the root activity, so that a cached process does not keep the exclusive output stream open.
- Document the Linux build of the Android engine host checks.
- Link Oboe 1.11.0 on Android.

### Fixed

- Reopen the Android Oboe stream after every stream error, not only after an output-route disconnect. A timeout or invalid-state error no longer leaves a silent engine that the app believes is running.

## [1.0.0] - 2026-10-24

Initial official release. The earlier private snapshot and all subsequent changes belong to pre-release development.

### Added

- Add sample-clock `playSequence`, `updateSequence`, `stopSequence` and `getSequenceState`, positive sequence identifiers, up to four independent sequences, triple-bank publication, step chords and queue-independent musical gates.
- Add `setTempo` for a shared musical clock. Beat-based sequences and synchronized modulation follow tempo changes; millisecond sequences retain their timing. Steps support independent intervals and note lengths, swing, rests and arpeggios.
- Add shared stereo chorus, ping-pong delay, Schroeder reverb, explicit creative saturation and fixed input gain through `setMasterProcessing`. Select the music, effects, ui and ambience categories or override a voice's `effectSend`. Effects default to bypass; tails drain on disable and panic invalidates histories without scanning buffers.
- Add smooth sustained-voice position, noise-rate and one-pole low-pass updates while preserving oscillator, noise and spatial history. Voice priorities and atomic chord admission share the same pool; separate counters report priority drops and rejected sequence publications.
- Add two optional phase-preserving native LFOs on sustained/sequence voices, with filter, PWM and FM targets and free/tempo-sync rates.
- Add accumulated `preLimiterPeakDb` and `maxLimiterReductionDb` diagnostics. Studio preset calibration and listening acceptance are reported separately from module capabilities.

- Add matching `noteOn`, `noteOff` and `updateVoice` APIs for native sustained notes, current-level release and 10 ms live parameter ramps. Retain the timed playback methods alongside the identified sustained-voice API.

- Complete the interactive example with nine headphone positions, stereo comparison, spatial chords/patterns, audio-session selection and statistics read/reset/diagnostic controls.
- Handle playback rejection consistently in example actions and respect window safe areas; document setup, device checks, scheduler completion exceptions, statistics cleanup and idle render load.

- Add `getStats()`, `resetStats()` and opt-in `setStatsEnabled(Boolean)` with cross-platform voice, command and rejection counters, render timing and final-output signal meters.
- Avoid scanning empty voice/tail groups during render; verify identical host output against the previous engine.

- Add optional front-plane headphone binaural positioning with `spatialX` and `spatialY` on tones, chords and patterns.
- Share a compact MIT KEMAR HRTF FIR implementation between Android and iOS, including filter history during voice replacement and stopping.
- Add spatial contract parity and DSP regression coverage; ordinary calls keep stereo panning.
- Document per-effect JavaScript integration, app controls, installed-feature detection and stereo fallback; check API table coverage against the native contract.

- Native low-latency tone synthesis for Titanium on Android and iOS.
- Nineteen public methods: `getDefaults`, `start`, `playTone`, `playChord`, `playSequence`, `updateSequence`, `stopSequence`, `getSequenceState`, `setTempo`, `noteOn`, `noteOff`, `updateVoice`, `setMasterProcessing`, `setVolume`, `stopAll`, `shutdown`, `getStats`, `resetStats` and `setStatsEnabled`.
- Sine, square, sawtooth, triangle, white-noise and custom wavetable sources.
- Envelopes, stereo pan movement, pitch sweeps, vibrato, chords and timed patterns with tempo, note values and swing.
- Variable-rate sample-and-hold noise with optional rate sweeps.
- A per-voice one-pole low-pass filter for noise and oscillator shaping.
- Pulse-width control and pulse-width sweeps for the square oscillator.
- Custom stepped wavetables with 2 to 64 normalized samples.
- Optional 2-bit to 16-bit amplitude quantization.
- Voice pools from 1 to 32 voices and patterns of up to 512 structured steps.
- `conservative`, `balanced`, `speakerSafe` and `raw` mixing profiles.
- `start({ audioSession })` selects the iOS session category: `playback` (default) or `ambient`, which respects the silent switch and mixes with other apps' audio. The category is reapplied after a route change. Android validates the same values and leaves its output unchanged.
- Fixed event gain, atomic chord publication, smoothed master level and a stereo-linked lookahead limiter.
- Automatic stream recovery after output-route changes.
- Strict cross-platform validation rejects unknown options, invalid step representations and incompatible voice parameters before publication.
- Host-side contract, parity and DSP regressions, an interactive example app, and complete API and sound-design documentation.
- `decay` and `sustain` extend the envelope with a decay stage that settles to a held level before the release. The release scales the level it starts from, so one that begins during the decay stays continuous.
- A resonant state-variable filter: `filterType` (`lowpass`, `highpass` or `bandpass`), `filterHz`, `filterQ` and an exponential cutoff sweep with `filterHzEnd`. It runs after the one-pole `lowPassHz` filter.
- Two-operator FM on `SINE` voices: `fmRatio`, `fmDepth` and `fmDepthEnd`. The modulator keeps its ratio through pitch sweeps and vibrato.
- `detune` in cents on tones and sequence pitches, and `detunes` for per-note offsets in a chord.
- The `sequenceend` event reports each retired sequence identifier and its `completed` or `stopped` reason outside the audio callback.
- Cross-key validation with the reasons `sustain_without_decay`, `decay_exceeds_remaining_duration`, `filter_type_required`, `fm_requires_sine` and `fm_depth_required`.
- `getDefaults()` reports the new defaults and limits and a `filterTypes` list.
- The envelope, filter, sweep, FM and cents math live once in `shared/synth_core.h`, which both renderers include. Host checks cover that core, the Android engine render path and a replayed contract corpus for the iOS contract.
- Requires Titanium SDK 13.2.0.GA or newer and iOS 15 or newer.

### Changed

- Publish complete sequence scores without redundant bank copies on Android and iOS; reuse the iOS producer's validated preparation while retaining partial-edit and atomic rejection behavior.
- Retain the original Apple renderer after physical 32-stereo timing rejected the experimental eight-sample FIR/cache/idle-effects bundle. Exact compatibility, measured producer gains, rejected prototypes and physical acceptance limits are recorded in `documentation/performance-review.json`.

### Fixed

- Avoid allocating empty Android sequence-end results and empty iOS metadata-pruning collections. Unknown iOS voice edits remain accepted no-ops without retaining per-ID spatial positions.

- Reuse binaural FIR coefficients across eight consecutive samples on Android ARM64 while preserving sample results, sequence boundaries and release tails. Extended Sim80 measurements retain near 60 FPS presentation but still record occasional output underruns in both reference and candidate; listening and maximum-load acceptance remain separate.
- Preserve compatible released-key oscillator phases and pre-envelope filter history so repeated sustained notes do not cancel their tails; independent envelopes, gains and IDs remain unchanged.
- Protect sustained attack and release edges shorter than 3 ms from hard gating on Android and iOS. Longer envelopes and existing timed envelopes retain their behavior.
- Make the Android native limiter reach its target within the lookahead deadline, matching iOS and the Java DSP reference. Dense sums now respect the configured ceiling instead of escaping into hard clipping; drained-window gain resets without changing below-ceiling source gain.
