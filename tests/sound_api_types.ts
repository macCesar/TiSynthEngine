import synth = require('../index');

const current: string = synth.getContract().version;
const previous: string = synth.getDefaults().version;
const sound = synth.createSound({
  name: 'Typed example',
  sound: { volume: 0.2, variation: { amount: 1, ranges: { volume: [0.1, 0.2] } } },
  playback: { notes: ['C4'], duration: 250 }
});
sound.set({ sound: { pan: null, variation: { amount: 0.5 } }, playback: { notes: [62] } });
const finite: boolean = sound.play({ type: 'tone', frequencies: [440] });
const heldSound = synth.createSound({ playback: { type: 'held', notes: ['C4'] } });
const held: synth.Note | false = heldSound.play({ type: 'held' });
if (held) {
  held.update({ notes: [64], volume: 0.1 });
  held.noteOff();
  // @ts-expect-error Controls never expose native identifiers.
  held.voiceId;
  // @ts-expect-error Variation is an attack-only property, not a live edit.
  held.update({ variation: { amount: 0 } });
}
const repeat = sound.play({ type: 'repeat', interval: 200 });
if (repeat) { repeat.update({ interval: 180 }); repeat.stop(); }
const patternSound = synth.createSound({ playback: { type: 'pattern', steps: [{ notes: [60] }] } });
const pattern = patternSound.play({ type: 'pattern', steps: [{ notes: [60], interval: 0.5, sound: { frequencyEnd: 880 } }, { rest: true }] });
if (pattern) {
  const callback = (event: synth.PatternEndEvent) => { const reason: 'completed' | 'stopped' = event.reason; void reason; };
  pattern.addEventListener('end', callback);
  pattern.removeEventListener('end', callback);
  const state = pattern.getState();
  if (state) {
    const step: number = state.step;
    void step;
    // @ts-expect-error Pattern state omits native sequence identity.
    state.sequenceId;
  }
}
const mixed = sound.play();
if (mixed && typeof mixed !== 'boolean' && 'noteOff' in mixed) mixed.noteOff();
synth.setVolume(0.8);
synth.setVolume({ volume: 0.8 });
synth.setTempo(110);
synth.setTempo({ bpm: 110 });
synth.setProcessing({ delay: { time: 250 }, reverb: { decay: 1500 } });
synth.setProcessing({ delay: { timeMs: 250 } });
synth.setMasterProcessing({ delay: { timeMs: 250 }, reverb: { decay: 1.5 } });
// @ts-expect-error A finite result has no individual playback control.
finite.stop();
// @ts-expect-error Nested execution overrides are rejected.
sound.play({ sound: { volume: 0.1 } });
// @ts-expect-error Use pitch arrays in the object interface.
sound.noteOn({ frequency: 440 });
// @ts-expect-error The two pitch sources cannot coexist.
sound.play({ notes: ['C4'], frequencies: [440] });
// @ts-expect-error Delay input aliases cannot coexist.
synth.setProcessing({ delay: { time: 200, timeMs: 250 } });
// @ts-expect-error Modulations are not live waveform changes.
if (held) held.update({ waveType: 1 });
void current; void previous;
// @ts-expect-error Explicit held execution rejects finite duration fields.
heldSound.play({ type: 'held', duration: 200 });
// @ts-expect-error Explicit patterns place pitches on their steps.
patternSound.play({ type: 'pattern', notes: [60] });
if (pattern) {
  // @ts-expect-error Active pattern controls do not change interpretation.
  pattern.update({ type: 'tone' });
}
// @ts-expect-error A chord definition requires an explicit pitch array.
synth.createSound({ playback: { type: 'chord' } });
if (repeat) repeat.update({ fmRatio: null, fmDepth: null });
if (pattern) pattern.update({ noiseRate: null, filterType: 'none', filterHz: null, filterQ: null });
// @ts-expect-error Held live edits require concrete values.
if (held) held.update({ fmDepth: null });

// @ts-expect-error TiSynth has one module version, no independent API counter.
synth.getContract().apiVersion;
// @ts-expect-error Native defaults identify the same module version.
synth.getDefaults().apiVersion;
