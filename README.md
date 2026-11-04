# TiSynthEngine

TiSynthEngine 2.0.0 is a native synthesizer for Titanium apps on Android and iOS. Define a sound once, then play it wherever the app needs it. Oscillators generate the audio; the native audio clock schedules repetitions and patterns. The module does not play recorded samples.

```javascript
var synth = require('ti.synthengine')
var W = synth.getContract().waveTypes

synth.start({ maxVoices: 16, audioSession: 'ambient' })

var bell = synth.createSound({
  sound: { waveType: W.SINE, volume: 0.25, attack: 5, release: 120 },
  playback: { type: 'tone', notes: ['A4'], duration: 400 }
})

bell.play()
bell.play({ notes: ['C5'], volume: 0.15 })
```

`sound` contains the synthesis settings. `playback` contains default pitches, timing and the playback type. Arguments to `play()` change only that execution; `set()` changes the stored definition for future executions. See the [complete Sound reference](documentation/sound-api.md) for properties, units and validation.

## Requirements

- Titanium SDK 13.2.0.GA or newer.
- Android projects compiled against API 35 or newer, using `arm64-v8a`, `armeabi-v7a`, `x86` or `x86_64`.
- iOS 15.0 or newer; device, simulator and Mac Catalyst builds are supported.

## Install

Use matching Android and iOS 2.0.0 packages from the [releases page](https://github.com/macCesar/TiSynthEngine/releases), or build them from this source. Check the available release version before downloading. Source builds produce `android/dist/ti.synthengine-android-2.0.0.zip` and `ios/dist/ti.synthengine-iphone-2.0.0.zip`.

Put both archives in the Titanium app root and declare the modules in `tiapp.xml`:

```xml
<modules>
  <module platform="android" version="2.0.0">ti.synthengine</module>
  <module platform="iphone" version="2.0.0">ti.synthengine</module>
</modules>
```

Build and reinstall the app after replacing a native package. `getContract().version` and `getDefaults().version` report the installed module version. `getContract()` also describes the Sound interface, units and property allowlists.

## Quick start

Create reusable definitions during setup. Run startup after layout settles, handle operational rejection when it matters to the application, and shut down the engine when its owner closes. Creating a Sound does not start audio or reserve a voice.

```javascript
var synth = require('ti.synthengine')
var contract = synth.getContract()

if (!synth.start({ maxVoices: 16, maxSequences: 4, audioSession: 'ambient' })) {
  throw new Error('Audio startup rejected')
}

var explosion = synth.createSound({
  sound: { waveType: contract.waveTypes.NOISE, volume: 0.2, attack: 2, release: 100 },
  playback: { type: 'tone', frequencies: [80], duration: 250 }
})

explosion.play()
```

On iOS, `ambient` respects silent mode and mixes with other apps; the default `playback` policy ignores silent mode. Android validates this setting without changing its output. Changing the session policy, mixing profile or voice capacity requires shutdown and startup.

## Public methods

| Owner | Method | Purpose |
| --- | --- | --- |
| Module | `createSound({ name?, sound?, playback? })` | Create a validated reusable definition |
| Sound | `play(changes?)` | Play with optional flat overrides |
| Sound | `noteOn(changes?)` | Start a single held note |
| Sound | `set({ sound?, playback? })` | Validate and apply an atomic stored revision |
| Sound | `getPreset()` | Return an independent copy of the definition |
| Note control | `update(changes)`, `noteOff()` | Change or release that held note |
| Repetition control | `update(changes)`, `stop()` | Change future attacks or cancel repetition |
| Pattern control | `update(changes)`, `stop()`, `getState()` | Edit, stop or inspect that pattern |
| Pattern control | `addEventListener('end', listener)`, `removeEventListener('end', listener)` | Observe completion or stopping |
| Module | `start(options)`, `shutdown()` | Own the native audio lifecycle |
| Module | `setVolume(number)`, `setTempo(number)` | Set master gain or beats per minute |
| Module | `setProcessing(options)` | Configure shared effects and category routing |
| Module | `stopAll()` | Global panic: stop scheduling, fade voices and clear effect histories |
| Module | `getContract()`, `getDefaults()` | Read metadata, constants, defaults and limits |
| Module | `getStats()`, `resetStats()`, `enableStats()`, `disableStats()` | Read and control diagnostics |

The [direct native reference](documentation/api.md) documents supported low-level calls and their exact parameter ranges. The [upgrade guide](documentation/upgrade-2.0.0.md) contains the method mapping and naming changes.

## Playback types and controls

| `playback.type` | Use | Accepted return from `play()` |
| --- | --- | --- |
| `tone` | One finite pitch | `true`; it finishes naturally |
| `chord` | One atomic group of pitches | `true`; it finishes naturally |
| `held` | One note released by interaction | Note control |
| `repeat` | A finite tone repeated by the native clock | Repetition control |
| `pattern` | Ordered notes, chords and rests | Pattern control |

Operational rejection returns `false`. Finite tones and chords expose no individual stop identifier. Release a held note through its own control; stopping a repetition cancels future attacks while admitted finite attacks finish. Pattern stopping releases that pattern's voices. Release and processing tails may remain after a pattern's `end` event.

Controls belong to the engine generation that created them. Shutdown invalidates them; old controls cannot affect playback after a restart. Sound definitions remain reusable.

## Properties and units

Use `notes` for note names or MIDI pitch numbers, or `frequencies` for hertz. Tone, repetition and held execution use one pitch; chords accept up to 32. Patterns contain up to 512 steps, with notes, frequencies or a rest in each step. MIDI numbers identify pitches; the module does not read MIDI files.

Synthesis settings include waveform, volume, ADSR, filters, FM, vibrato, noise shaping, PWM, wavetable, quantization, detune, stereo/spatial placement, LFOs, routing and variation. Their compatibility depends on the playback type and source. See the [property allowlists](documentation/sound-api.md#property-allowlists) and [native ranges](documentation/api.md).

| Property | Meaning |
| --- | --- |
| `sound.attack`, `decay`, `release` | Milliseconds |
| Finite `playback.duration` | Total milliseconds, including release |
| Repetition `playback.interval` | Integer milliseconds between starts |
| Pattern root/step `interval` and step `length` | Beats by default, or milliseconds with `timeUnit: 'ms'` |
| `setTempo(number)` | Beats per minute |
| Processing delay `time` and reverb `decay` | Milliseconds |

A pattern interval sets the next onset; its `length` or `gate` determines when release begins. Changing interpretation can change envelope and sweep behavior. Preserve the intended playback type when reusing an authored effect.

## Variation

Put bounded random variation in the sound definition. The native engine selects values once per admitted attack and keeps them for that voice. Amount interpolates from the authored value toward each range; explicit seeds reproduce parameter selections.

```javascript
var bell = synth.createSound({
  sound: {
    waveType: synth.getContract().waveTypes.SINE,
    volume: 0.25, attack: 5, release: 120,
    variation: {
      amount: 0.6,
      ranges: { volume: [0.18, 0.25], pitchCents: [-8, 8] }
    }
  },
  playback: { type: 'tone', notes: ['A4'], duration: 400 }
})

bell.play()
```

See [variation](documentation/native-variation.md) for source restrictions, inheritance and seed behavior. Variation does not require application randomization or an attack timer.

## Processing and gain

```javascript
synth.setVolume(0.6)
synth.setTempo(110)
synth.setProcessing({
  applyTo: ['music'],
  delay: { enabled: true, time: 250, feedback: 0.25, mix: 0.1 },
  reverb: { enabled: true, decay: 1500, damping: 0.6, mix: 0.12 }
})
```

Chorus, delay, reverb and creative saturation start disabled. `sound.bus` selects `music`, `effects`, `ui` or `ambience`; an explicit `effectSend` overrides category selection. There is one shared effects chain and one final stereo sample-peak protector. Event gain is fixed; starting unrelated voices does not normalize existing ones. Chords retain their native grouping and gain compensation.

The pool supports up to 32 voices and four patterns. Budget releases, overlapping attacks and processing tails. `maxVoices` sets capacity, not loudness. Mixing profiles are `conservative`, `balanced`, `speakerSafe` and `raw`. Read [gain recommendations](documentation/recommendations.md) before raising levels.

## Strict options

Sound definitions, revisions and execution overrides reject unknown keys, wrong types, incompatible combinations and out-of-range values with descriptive errors. `set()` validates the complete result before publishing it. It recursively merges objects and replaces arrays; active executions keep their own settings.

A valid request can still fail operationally because the engine is stopped or native capacity/publication is unavailable. Playback returns `false` for that case. Module lifecycle and global setters retain their documented return contracts. See [errors and lifetime](documentation/sound-api.md#lifetime-and-errors).

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


## More documentation

- [Sound reference](documentation/sound-api.md): methods, properties, controls, validation and units.
- [Guide](documentation/guide.md) and [examples](documentation/examples.md): application integration.
- [Instruments and effects](documentation/instruments-and-effects.md): choose the intended playback behavior.
- [Sound design](documentation/sound-design.md): oscillators, envelopes, filters and recipes.
- [Audio engine](documentation/audio-engine.md): rendering, output protection and platform details.
- [Troubleshooting](documentation/troubleshooting.md): rejection, silence and glitches.
- [Interactive example](example/README.md): build and device checklist.

## Validation and performance

The [Sound validation report](documentation/sound-api-validation.md) records within-platform acoustic comparisons and bounded performance/memory tests, including unresolved results. The [validation archive](docs/validation/README.md) preserves source-specific measurements. Historical measurements describe the revisions that produced them; they do not certify every device, route or workload.

Diagnostics are optional. `getStats()` returns counters and available measurements; keep unmeasured values as `null`. Render load measures callback work, not whole-app CPU. See [statistics and measurement limits](documentation/stats-performance.md).

## Build and test

Build each platform from its directory with the Titanium CLI. Host and native contract checks are documented in the platform READMEs and `.github/workflows/tests.yml`. Run checks appropriate to the changed behavior. Build and reinstall consumer apps after replacing native binaries.

## License

MIT. Binaural HRTF data and other bundled components have their own attribution requirements; see [third-party notices](documentation/third-party-notices.md).
