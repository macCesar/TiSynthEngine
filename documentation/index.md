# TiSynthEngine documentation

TiSynthEngine is a native tone synthesizer for Titanium on Android and iOS. It plays generated tones, held voices, chords, noise, timed patterns and sample-clock sequences, with optional native stereo effects and LFO modulation through the same native engine on both platforms. The 2.0.0 candidate adds reusable Sound objects: both `getContract().version` and `getDefaults().version` identify the installed TiSynth module as 2.0.0. Published 1.1.0 packages retain the previous interface.

Start with the [README](../README.md) if you have not installed the module yet. It explains the lifecycle, the public methods, the `sequenceend` event and common options.

## Guides

- [Sound objects: TiSynth 2.0.0](sound-api.md): definitions, flat overrides, held/repetition/pattern controls, strict validation, units and previous-method mappings.

- [Instruments, sound effects and complete sequences](instruments-and-effects.md): choose the playback contract, preserve full recipes, compose demos and budget overlapping voices.

- [Finite-tone repetition](api.md#finite-tone-repetition): native intervals, future-attack edits and cancellation without shortening sounding attacks.
- [Native attack variation](native-variation.md): the 1.1.0 dictionary, field limits, linear amount, seeds, chords, held voices and sequence revisions.
- [Guide](guide.md): installation, startup, cleanup and day-to-day use.
- [Binaural app integration](guide.md#integrate-binaural-in-a-2d-app): per-effect coordinates, switches, amplitude sliders and stereo fallback.
- [Sustained voice ownership](guide.md#hold-and-edit-a-voice): identified notes, live edits and release cleanup.
- [Native musical transport](guide.md#choose-the-musical-transport): step chords, gates, swing, edits and state.
- [Master effects](guide.md#add-master-effects): chorus, delay, reverb, optional saturation and defaults.
- [Advanced examples](examples.md#sustained-game-motor): held motors, sequences, LFOs and signal measurements.
- [Engine statistics](guide.md#read-engine-statistics): opt-in measurements, polling, reset and cleanup.
- [API reference](api.md): every public method, option, default and limit.
- [Sound design](sound-design.md): synthesis basics, filters, FM and recipes.
- [Examples](examples.md): complete snippets for tones, chords and patterns.
- [Audio engine](audio-engine.md): signal path, mixing and platform details.
- [Recommendations](recommendations.md): gain staging, lifecycle and testing.
- [Troubleshooting](troubleshooting.md): rejected calls, silence and glitches.
- [Performance validation](stats-performance.md): host comparisons, physical results and measurement limits.
- [Third-party notices](third-party-notices.md): licenses of bundled dependencies.

The runnable Titanium app is in [`example/app.js`](../example/app.js); follow its [setup and device checklist](../example/README.md). Host-side contract and DSP regressions are in [`tests/`](../tests/) and [`android/test/`](../android/test/). Both platforms share the DSP math in [`shared/`](../shared/).

## Validation records

[Sound API candidate validation](sound-api-validation.md) records acoustic equivalence, allocation/lifetime checks and the scope of runtime stress measurements.

[Native tone repetition validation](native-tone-repetition-validation.md) records the API 1.1.0 scheduler tests, memory and bounded host measurements.

Measured results and raw captures are kept in the separate [validation archive](../docs/validation/README.md). The [performance guide](stats-performance.md) explains their scope and limitations.
