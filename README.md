# TiSynthEngine

TiSynthEngine is a native synthesizer for Titanium apps on Android and iOS. It generates tones, sustained voices, chords, sweeps, noise and sample-clock sequences without bundled audio files. Optional native chorus, ping-pong delay, reverb, creative saturation and two voice LFOs add movement and space. Optional `spatialX` and `spatialY` provide headphone positioning on a front plane; see [binaural positioning](documentation/api.md#binaural-front-plane-positioning) and [app integration](documentation/guide.md#integrate-binaural-in-a-2d-app).

The module id is `ti.synthengine`. The current Android and iOS packages are version `1.0.2`; both retain the public API version `1.0.0`. See the [audio pipeline changes and compatibility notes](documentation/audio-pipeline-validation.md).

## What it is for

Use TiSynthEngine for game and interface feedback, retro effects, alarms, notes, chords, arpeggios and simple noise-based percussion. Decay and sustain, a resonant filter, FM and detune also produce plucks, keys, bells and thick pads.

It is a synthesizer, not a sample player. It does not decode `.wav` or `.mp3` files, play recorded samples or provide MIDI. Sustained voices use app-supplied IDs for release and live updates. See [known limits](documentation/recommendations.md#known-limits) before using it for a long-running music or ambience system.

## Find your starting point

| You want to... | Read this |
| --- | --- |
| Install the module and hear a first note | [Install](#install) and [quick start](#quick-start) |
| Add game sounds or interface feedback | [Sound design and recipes](documentation/sound-design.md) |
| Build playable keys or a sustained game motor | [Held voice ownership](documentation/guide.md#hold-and-edit-a-voice) |
| Schedule music, chords, swing or arpeggios | [Native musical transport](documentation/guide.md#choose-the-musical-transport) |
| Find an option, range or return value | [API reference](documentation/api.md) |
| Run an interactive device example | [Example app and checklist](example/README.md) |
| Diagnose silence, rough sound or missed audio buffers | [Troubleshooting](documentation/troubleshooting.md) and [statistics](documentation/stats-performance.md) |
| Understand what has actually been verified | [Validation and performance](#validation-and-performance) |

The [documentation index](documentation/index.md) connects all guides. Start with the [sound design guide](documentation/sound-design.md) if synthesis terminology is new to you.

## Requirements

- Titanium SDK 13.2.0.GA or newer.
- Android projects must compile against API 35 or newer.
- Android: `arm64-v8a`, `armeabi-v7a`, `x86` or `x86_64`.
- iOS 15.0 or newer.
- iOS builds can target a device, simulator or Mac Catalyst.

## Install

Download the platform-specific packages from [Android 1.0.2](https://github.com/macCesar/TiSynthEngine/releases/tag/android-1.0.2) and [iOS 1.0.2](https://github.com/macCesar/TiSynthEngine/releases/tag/ios-1.0.2), then copy both archives into the Titanium app root:

- `ti.synthengine-android-1.0.2.zip`
- `ti.synthengine-iphone-1.0.2.zip`

Declare both platform modules in `tiapp.xml`:

```xml
<modules>
  <module platform="android" version="1.0.2">ti.synthengine</module>
  <module platform="iphone" version="1.0.2">ti.synthengine</module>
</modules>
```

The Titanium CLI will install them under `modules/<platform>/ti.synthengine/1.0.2/` during the next build.

## Quick start

Run this after the owning window has settled. The [layout-aware startup](#start-after-layout) section below shows how to defer startup and cancel it during cleanup.

```javascript
var synth = require('ti.synthengine')
var contract = synth.getDefaults()

if (contract.apiVersion !== '1.0.0') {
  throw new Error('TiSynthEngine 1.0.0 is required')
}

if (synth.start({
  maxVoices: 16,
  mixingProfile: 'conservative',
  audioSession: 'ambient'
}) === false) {
  throw new Error('The audio engine could not start')
}

if (!synth.playTone({ note: 'A4' })) {
  synth.shutdown()
  throw new Error('The first note was rejected')
}
```

This game-oriented example uses `ambient`: on iOS it respects silent mode and mixes with other apps. The module default is `playback`, which ignores silent mode. Android validates this option without changing its output. Changing the session policy requires `shutdown()` followed by `start()`.

Call `shutdown()` when the screen or app that owns the audio closes. For timed sounds, follow the [interactive example setup and test checklist](example/README.md). The [copyable advanced examples](documentation/examples.md#sustained-game-motor) cover held voices, sample-clock transport, effects and modulation.

## Start after layout

Do not open the low-latency stream while Titanium is still laying out the first window. On some Android devices that work competes with audio startup and the first sound underruns.

Register `postlayout` before opening the window, debounce it, and cancel the pending start during cleanup. A plain screen usually settles within 250 ms:

```javascript
var engineRunning = false
var startTimer = null

function onPostLayout () {
  if (startTimer !== null) clearTimeout(startTimer)
  startTimer = setTimeout(function () {
    startTimer = null
    win.removeEventListener('postlayout', onPostLayout)
    engineRunning = synth.start({ maxVoices: 16 })
  }, 250)
}

function cleanup () {
  win.removeEventListener('postlayout', onPostLayout)
  if (startTimer !== null) clearTimeout(startTimer)
  if (engineRunning) synth.shutdown()
}

win.addEventListener('postlayout', onPostLayout)
win.addEventListener('close', cleanup)
win.open()
```

Apps that start ads, remote configuration or entry animations may need a longer quiet period. The [guide](documentation/guide.md#lifecycle) and [`example/app.js`](example/app.js) include full cleanup.

## Public methods

Native sample-clock sequencing, stereo chorus/delay/reverb and optional creative saturation are available through the native APIs. New processing starts disabled. See the [transport and processing contract](documentation/api.md#native-sequence-transport).

The module exposes nineteen methods and one event, `sequenceend`.

| Method                  | Returns   | What it does                                                                                             |
| ----------------------- | --------- | -------------------------------------------------------------------------------------------------------- |
| `getStats()`            | `Object`  | Returns basic counters and enabled diagnostics; see the [stats contract](documentation/api.md#getstats). |
| `resetStats()`          | nothing   | Resets accumulated statistics without stopping sounds.                                                   |
| `setStatsEnabled(bool)` | `Boolean` | Enables optional timing and signal measurements (off by default).                                        |
| `getDefaults()`         | `Object`  | Reports the API version, defaults, limits, profiles and waveform constants.                              |
| `start(options)`  | `Boolean` | Opens the native stream and fixes its voice capacity and mixing profile.                                 |
| `noteOn(options)`      | `Boolean` | Starts an identified sustained voice; see [sustained notes](documentation/api.md#noteonoptions). |
| `noteOff(options)`     | `Boolean` | Begins the identified voice’s release from its current level. |
| `updateVoice(options)` | `Boolean` | Ramps compatible active-voice parameters over 10 ms without retriggering. |
| `playTone(options)`     | `Boolean` | Plays one pitch with optional sweep, pan movement and vibrato.                                           |
| `playChord(options)`    | `Boolean` | Starts 1 to 32 pitches as one atomic event.                                                              |
| `playSequence(options)` | positive ID or 0 | Publishes an independent sample-clock sequence. |
| `setTempo({ bpm })` | `Boolean` | Changes global musical tempo, preserving position. |
| `updateSequence({ sequenceId, ...changes })` | `Boolean` | Publishes an atomic transport edit without restarting. |
| `stopSequence({ sequenceId })` | `Boolean` | Stops transport and releases only its voices. |
| `getSequenceState({ sequenceId })` | `Object` or `null` | Reports applied step, musical position, tempo and revision. |
| `setMasterProcessing(options)` | `Boolean` | Configures fixed input gain, stereo effects and optional saturation. |
| `setVolume(options)`    | `Boolean` | Changes the master level with a short ramp.                                                              |
| `stopAll()`             | nothing   | Releases all sounding voices through a short fade.                                                       |
| `shutdown()`            | nothing   | Stops the stream, cancels pending pattern steps and frees resources.                                     |

Boolean methods return `true` when accepted. A `false` result means the payload was rejected, the engine is not running, the stream could not open, or the command queue was full.

## Sustained voices, musical transport and effects

| Feature | What you can build | Start here |
| --- | --- | --- |
| `noteOn`, `noteOff`, `updateVoice` | Playable keys, a held game motor, drones and final fanfare chords; compatible live controls ramp over 10 ms. | [Held voice ownership](documentation/guide.md#hold-and-edit-a-voice) |
| `playSequence`, `updateSequence`, `stopSequence`, `getSequenceState` | Beat or millisecond timing, step chords, rests, gates, swing and arpeggios, up to 512 steps. | [Musical transport](documentation/guide.md#choose-the-musical-transport) |
| `setMasterProcessing` | Stereo chorus, free/synced ping-pong delay and damped stereo reverb; optional creative saturation. | [Master effects](documentation/guide.md#add-master-effects) |
| `modulations` on held/sequence voices | Up to two sine/triangle LFOs for filter cutoff, square PWM or sine FM, with free or tempo-synced rates. | [LFO example](documentation/examples.md#two-voice-lfos) |
| Accumulated signal diagnostics | See brief pre-limiter peaks and limiter attenuation that happened between UI polls. | [Measure the mix](documentation/examples.md#measure-peaks-and-limiter-reduction) |

The release reports `apiVersion: '1.0.0'`. Detect the methods you need and rebuild the app with matching official Android/iOS packages. The [guide](documentation/guide.md#detect-required-capabilities) shows feature detection. Timed playback remains available through its existing methods.

The initial module state is `inputGain: 1`, all four master processors disabled and no additional voice LFOs. Turning an effect on is explicit; these features are available to every Titanium consumer, including games. Select processed categories with `applyTo`; an explicit per-voice `effectSend` overrides category selection. Music, effects, UI and ambience share one effects chain and one final limiter. Turning them off drains their tails; `stopAll()` performs panic and clears effect histories. Saturation changes timbre and remains separate from final limiter protection.

```javascript
if (typeof synth.playSequence !== 'function' ||
    typeof synth.setMasterProcessing !== 'function') {
  throw new Error('Install the official TiSynthEngine packages and rebuild')
}
if (!synth.setMasterProcessing({ reverb: { enabled: true, decay: 1.1, mix: 0.12 } })) {
  throw new Error('Reverb configuration rejected')
}
synth.setTempo({ bpm: 110 })
if (!synth.playSequence({ loop: false,
  voice: { waveType: contract.waveTypes.TRIANGLE, volume: 0.3, release: 180 },
  steps: [{ notes: [60] }, { notes: [64] }, { notes: [67] }, { notes: [60, 64, 67] }] })) {
  synth.shutdown()
  throw new Error('Sequence publication rejected')
}
```

The engine owns each note start and release; JavaScript need not trigger the steps. A sequence step uses MIDI numbers, while `playTone`, `playChord` and `noteOn` accept note-name strings. A positive sequence ID means accepted publication, not that the audio callback already applied it. See the [API](documentation/api.md#native-sequence-transport) for edits, cancellation and state polling, and [technical validation limits](documentation/audio-engine.md#native-transport-and-processing) before sizing a realtime workload.

## Strict options

Option dictionaries are closed contracts. A misspelled or unsupported key is rejected with `reason=unsupported_option`. Values with the wrong type, `NaN`, `Infinity` or an out-of-range number are also rejected. Explicit values are never clamped.

```javascript
synth.playTone({ note: 'C4', duraton: 200 })
// false; "duraton" is not a supported option
```

When a validation failure emits a structured diagnostic, it uses this form in logcat or the Xcode console:

```text
event=validation_warning method=playTone key=duraton reason=unsupported_option action=rejected value=200
```

Warnings are deduplicated by method, key and reason so a bad call in a loop does not flood the log. Some transport and control failures return rejection without a structured warning; always check the return value. The [API reference](documentation/api.md) lists accepted options and rejection reasons.

## Notes and frequencies

`playTone` accepts either `note` or `frequency`. Do not send both.

```javascript
synth.playTone({ note: 'F#4' })
synth.playTone({ note: 'Sib3' })
synth.playTone({ frequency: 523.25 })
```

Note names accept English letters and solfège names. Accidentals use `#` or a lowercase `b`. Octave 4 is assumed when the octave is omitted. `A4` is 440 Hz and the other notes use twelve-tone equal temperament.

The frequency range starts at 1 Hz. Its upper bound is 45 percent of the current sample rate. Read `getDefaults().limits.frequency.max` after starting the engine if the app validates user input.

## Waveforms

Use the constants returned by `getDefaults()` instead of duplicating numbers:

```javascript
var WAVE = synth.getDefaults().waveTypes

synth.playTone({ note: 'C4', waveType: WAVE.SINE })
synth.playTone({ note: 'C4', waveType: WAVE.SQUARE })
synth.playTone({ note: 'C4', waveType: WAVE.SAWTOOTH })
synth.playTone({ note: 'C4', waveType: WAVE.TRIANGLE })
synth.playTone({
  note: 'C4',
  waveType: WAVE.WAVETABLE,
  waveTable: [-1, -0.4, 0.2, 1, 0.5, -0.2]
})
synth.playTone({
  frequency: 200,
  waveType: WAVE.NOISE,
  duration: 90,
  attack: 1,
  release: 75
})
```

| Constant    | Value | Character                                                 |
| ----------- | ----: | --------------------------------------------------------- |
| `SINE`      |   `0` | Pure fundamental; useful for clean pitches and low notes. |
| `SQUARE`    |   `1` | Hollow, bright and suited to retro sounds.                |
| `SAWTOOTH`  |   `2` | Dense harmonic spectrum with a buzzy edge.                |
| `TRIANGLE`  |   `3` | Softer than square, with more body than sine.             |
| `NOISE`     |   `4` | White or sample-and-hold noise for hits and texture.      |
| `WAVETABLE` |   `5` | A repeating stepped table supplied by the caller.         |

Square and sawtooth use PolyBLEP band-limiting. Noise is unpitched, so its `frequency` value does not change the sound. `WAVETABLE` requires `waveTable` with 2 to 64 values from -1 to 1. Its stepped lookup can add digital grain even when the table contains sine samples; the character changes with pitch. This is distinct from clipping or an enabled saturation effect. See [rough wavetable sound](documentation/troubleshooting.md#a-wavetable-sounds-rough).

## Wave-shaping controls

Optional shaping controls include variable-rate sample-and-hold noise, a per-voice low-pass filter, variable pulse width, custom wavetables and amplitude quantization. These controls are disabled by default.

```javascript
synth.playTone({
  frequency: 120,
  duration: 700,
  attack: 1,
  release: 500,
  waveType: WAVE.NOISE,
  noiseRate: 12000,
  noiseRateEnd: 700,
  lowPassHz: 2800,
  bitDepth: 8
})
```

`noiseRate` changes white noise into sample-and-hold noise at the requested update rate. `noiseRateEnd` sweeps that rate over the event. Zero keeps the original white-noise behavior or disables the sweep.

`lowPassHz` enables a per-voice one-pole low-pass filter. `bitDepth` quantizes amplitude from 2 to 16 bits; zero leaves the signal unquantized.

Square waves also accept `pulseWidth` from 0.05 to 0.95 and an optional `pulseWidthEnd` sweep:

```javascript
synth.playTone({
  note: 'A3',
  duration: 650,
  waveType: WAVE.SQUARE,
  pulseWidth: 0.12,
  pulseWidthEnd: 0.82,
  release: 180
})
```

These controls are available on `playTone`, in sequence `voice` and step `overrides`, and as fixed values on `playChord`. Chords do not accept sweep fields.

## Envelopes

Every note has an attack, an implicit full-level middle section and a release. `duration` includes all three.

```javascript
synth.playTone({
  note: 'C4',
  duration: 1000,
  attack: 200,
  release: 400
})
```

That sound rises for 200 ms, holds for 400 ms and fades for 400 ms.

Explicit envelopes must fit. `attack` must be shorter than `duration`, and `release` cannot exceed the time left after attack. Defaults are shortened when a very short duration needs it, but values supplied by the caller are rejected instead of rewritten.

Add `decay` and `sustain` for sounds that start loud and settle, such as plucks, keys and bells. The level falls from full scale to `sustain` over `decay` milliseconds, then holds until the release:

```javascript
synth.playTone({ note: 'E4', duration: 900, attack: 2, decay: 260, sustain: 0.18, release: 380 })
```

`sustain` below 1 needs a `decay`, and `attack` plus `decay` must fit in `duration`.

## Panning, sweeps and vibrato

`pan` runs from `-1` on the left to `1` on the right. `panEnd` moves the note across the stereo field during its lifetime:

```javascript
synth.playTone({
  frequency: 440,
  duration: 1800,
  pan: -1,
  panEnd: 1
})
```

The same event can sweep pitch and add vibrato. `lfoFreq` is the vibrato rate and `lfoDepth` is its pitch deviation in Hz:

```javascript
synth.playTone({
  frequency: 180,
  frequencyEnd: 1100,
  duration: 420,
  waveType: WAVE.SAWTOOTH,
  lfoFreq: 5,
  lfoDepth: 8
})
```

The [sound design guide](documentation/sound-design.md) explains how these controls change the result and includes tested recipes.

## Filter, FM and detune

`filterType` adds a resonant 12 dB per octave filter: `lowpass`, `highpass` or `bandpass`. `filterQ` sets the resonance and `filterHzEnd` sweeps the cutoff exponentially:

```javascript
synth.playTone({
  note: 'A2', duration: 1000, waveType: WAVE.SAWTOOTH,
  filterType: 'bandpass', filterHz: 350, filterHzEnd: 2400, filterQ: 5
})
```

`fmDepth` turns a sine into a two-operator FM voice. `fmRatio` is the modulator frequency as a multiple of the carrier, and `fmDepthEnd` moves the index over the note, so bells and electric pianos start bright and mellow out:

```javascript
synth.playTone({
  note: 'C5', duration: 2600, decay: 2000, sustain: 0.02,
  fmRatio: 3.5, fmDepth: 4, fmDepthEnd: 0
})
```

`detune` shifts a pitch in cents. A chord takes `detunes`, one offset per note, so repeated pitches beat and thicken:

```javascript
synth.playChord({
  notes: ['A3', 'A3', 'E4', 'E4'], detunes: [-8, 8, -8, 8],
  duration: 2000, waveType: WAVE.SAWTOOTH
})
```

Tones and pattern steps take every one of these keys. Chords take them as fixed values, use `detunes` instead of `detune`, and have no `*End` sweeps. The [API reference](documentation/api.md#expressive-controls) lists the ranges and the rules that tie the keys together.

## Chords and polyphony

Use `playChord` when notes belong to one simultaneous musical or sound-design event:

```javascript
synth.playChord({
  notes: ['C3', 'G3', 'C4', 'E4'],
  duration: 2600,
  attack: 500,
  release: 1000,
  waveType: WAVE.TRIANGLE,
  volume: 0.55,
  pans: [-0.7, -0.2, 0.2, 0.7]
})
```

The command is atomic. The render thread sees the complete chord or none of it, even if the queue is nearly full. The mixer also knows the chord's voice count and applies constant-power gain.

Separate `playTone` calls are independent events. They are appropriate for unrelated touches or collisions, but several of them can produce a hotter sum than the same notes in one chord.

`maxVoices` sets voice capacity without changing volume. Timed-only pools replace the voice with the least time remaining. Sustained/transport replacement prefers releasing voices, then the oldest attack; every replacement has a short fade tail. Optional priority 0-3 selects the lowest eligible victims first. A chord is admitted or dropped as a whole; no voices are reserved.

## Sequences

Use one native sample clock for successive sounds. Beats follow the global tempo; millisecond sequences retain fixed times. Steps support chords, duplicates, rests, variable intervals, independent note lengths and sound overrides.

```javascript
synth.setTempo({ bpm: 112 })
var sequenceId = synth.playSequence({
  stepDuration: 0.5, swing: 0.12, bus: 'music',
  voice: { waveType: WAVE.SQUARE, volume: 0.55 },
  steps: [{ notes: [60] }, { notes: [64], overrides: { pan: -0.4, panEnd: 0.4 } },
    { rest: true }, { notes: [67], duration: 1, length: 0.8 }]
})
if (sequenceId === 0) throw new Error('Sequence rejected')
// Stop this owner without affecting unrelated voices:
synth.stopSequence({ sequenceId: sequenceId })
```

Start with `maxSequences: 4` for up to four independent sequences. Sequence identifiers never repeat during the module lifetime. Completion/stop emits `sequenceend` with `{ sequenceId, reason: 'completed' | 'stopped' }` outside the callback. See the [full contract](documentation/api.md#native-sequence-transport).

## Binaural headphone positioning

Send `spatialX` (left/right) and `spatialY` (below/above), each from -1 to 1, on a tone, chord or sequence voice. Either coordinate enables binaural; omit both for ordinary stereo. Never combine them with `pan`, `panEnd`, `pans` or `panSpread`, including inherited voice fields. Timed events keep their position; spatial held voices can be updated smoothly.

Use stereo headphones and broadband noise to compare height. This is a front plane with two-channel output, without rear sources or head tracking. The [integration guide](documentation/guide.md#integrate-binaural-in-a-2d-app) covers app switches and coordinate conversion; the [interactive example](example/README.md#headphone-positioning) offers nine positions and a stereo comparison.

## Engine statistics

`getStats()` reads counters without resetting them. `setStatsEnabled(true)` enables optional callback timing and signal meters; `resetStats()` clears accumulated statistics without stopping playback. Diagnostics default off. Display `null` as unavailable or unmeasured so it remains distinct from zero.

See the [integration and cleanup recipe](documentation/guide.md#read-engine-statistics) and [statistics field reference](documentation/api.md#getstats). Render load measures callback work; it does not measure total app CPU.

## Mixing profiles

The profile is chosen in `start()` and stays fixed until `shutdown()`.

| Profile        | Sine voice gain | Limiter ceiling | Good fit                                                        |
| -------------- | --------------: | --------------: | --------------------------------------------------------------- |
| `conservative` |           0.440 |            0.85 | General use and polyphony.                                      |
| `balanced`     |           0.622 |            0.85 | Mostly one or two voices when more level is needed.             |
| `speakerSafe`  |           0.311 |            0.70 | Small speakers, low pitches or device-side acoustic distortion. |
| `raw`          |           1.000 |            0.85 | App-managed gain staging and controlled tests.                  |

Protected profiles calibrate waveform RMS and divide chord gain by the square root of its voice count. A stereo-linked sample-peak protector immediately reduces peaks above the ceiling, adding no sample retention. Gain recovers with a 100 ms exponential constant and resets after two consecutive quiet stereo frames (≤1e-12), preserving recovery across isolated zero crossings. An unattenuated mix below the ceiling is unchanged; deliberate overload changes its waveform.

Start with `conservative`. If a small phone speaker sounds harsh while headphones remain clean, try `speakerSafe` and raise low pitches before adding more limiting.

## Master volume

`setVolume({ volume })` scales the whole mix and ramps changes linearly over 10 ms on both platforms, starting on the next processed sample and reaching the destination exactly. Values up to 2 are accepted, though values above 1 make limiting more likely.

## Audio route changes

Connecting or disconnecting an output may cut the note crossing the hardware transition. Android reopens its Oboe stream and iOS resumes `AVAudioEngine`; later notes continue on the new route. See [troubleshooting](documentation/troubleshooting.md#audio-changes-after-connecting-headphones) if later notes remain silent.

## More documentation

- [Getting started guide](documentation/guide.md)
- [API reference](documentation/api.md)
- [Sound design guide](documentation/sound-design.md)
- [Copyable examples](documentation/examples.md)
- [Audio engine internals](documentation/audio-engine.md)
- [Recommendations](documentation/recommendations.md)
- [Troubleshooting](documentation/troubleshooting.md)

## Validation and performance

Release 1.0.0 has real Android builds for all four listed ABIs and Apple builds for device, simulator and Catalyst. The own-Apple renderer was compared byte-for-byte with its frozen reference across 120 scenarios, five sample rates from 16 to 192 kHz, and short, irregular and 1024-frame blocks. Audio and original semantic state matched. These Apple results compare the Apple renderer with its own reference; they do not claim sample equality between Android and iOS.

Full-score publication and control-memory improvements are retained. The experimental Apple FIR/cache/idle-effects bundle was removed after physical 32-voice stereo timing regressed. Production iOS retains its original renderer. No buffer increase, added latency or reduction in voices, effects or quality was used to improve a result.

| Evidence | What it establishes | What remains open |
| --- | --- | --- |
| Native builds and contract/renderer checks | Build coverage, accepted payloads and the recorded own-platform audio/state comparisons | Hardware timing and audible output require device checks |
| Android and iPad game runs | Approximately 60 FPS in the measured Sim20 and Sim80 scenarios | Strict iPad population-matched comparison remains inconclusive; occasional Android Sim80 output underruns persist |
| Physical load and memory tests | Recorded callback deadlines, bounded recovery checks and compact 48 kHz memory measurements | The extreme Android load fails feasibility; physical 192 kHz memory/output and full listening certification remain open |

Read the [performance review](documentation/performance-review.json) for accepted, rejected and pending candidates, and the [raw evidence archive](documentation/performance-review-evidence.zip) for reproducibility. Host CPU measurements are not whole-app CPU measurements or promises of the same gain on a device. The [statistics guide](documentation/stats-performance.md) explains how to interpret the counters.

## Build and test

The [Android notes](android/README.md), [iOS notes](ios/README.md) and [audio engine guide](documentation/audio-engine.md#regression-coverage) contain the build and host-test commands.

## License

MIT. See [LICENSE](LICENSE). The Android module bundles Oboe under the Apache License 2.0; see [third-party notices](documentation/third-party-notices.md).
