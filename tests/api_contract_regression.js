// Static cross-platform API linkage checks complement the executable contract
// corpora and native renderer tests. They cannot establish audio correctness.
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const root = path.resolve(__dirname, '..')
const read = p => fs.readFileSync(path.join(root, p), 'utf8')
const java = read('android/src/ti/synthengine/TiSynthEngineModule.java')
const objc = read('ios/Classes/TiSynthengineModule.h')
const contractJava = read('android/src/ti/synthengine/SynthContract.java')
const contractIos = read('ios/Classes/TiSynthengineContract.m')
const methods = ['start', 'shutdown', 'getDefaults', 'playTone', 'playChord',
  'noteOn', 'noteOff', 'updateVoice', 'playSequence', 'updateSequence',
  'stopSequence', 'getSequenceState', 'setTempo', 'setMasterProcessing',
  'setVolume', 'stopAll', 'getStats', 'resetStats', 'setStatsEnabled',
  'repeatTone', 'updateNote', 'updateTone', 'stopTone', 'enableStats', 'disableStats'].sort()
assert.deepEqual([...java.matchAll(/@Kroll\.method\s+public\s+(?:synchronized\s+)?(?:boolean|int|void|KrollDict|Object)\s+(\w+)\(/g)].map(m => m[1]).sort(), methods)
assert.deepEqual([...objc.matchAll(/- \((?:NSDictionary \*|NSNumber \*|void)\)(\w+):/g)].map(m => m[1]).sort(), methods)
for (const validator of ['Start', 'SetVolume', 'Tone', 'Chord', 'NoteOn', 'NoteOff', 'UpdateVoice']) {
  const a = contractJava.split('static Validation validate' + validator + '(')[1]
  const b = contractIos.split('+ (NSDictionary *)validate' + validator + ':')[1]
  assert(a && b, 'both contracts implement ' + validator)
  const ja = a.match(/rejectUnknownOptions\(options,([\s\S]*?)\);/)[1]
  const ib = b.match(/RejectUnknownOptions\(options,\s*@\[([\s\S]*?)\]\)/)[1]
  const keys = s => [...s.matchAll(/@?"(\w+)"/g)].map(m => m[1]).sort()
  assert.deepEqual(keys(ja), keys(ib), validator + ' public allowlist parity')
}
const thread = read('android/src/ti/synthengine/SynthThread.java')
const native = read('android/jni/SynthOboeEngine.cpp')
assert.equal(thread.match(/EXTRA_COUNT = (\d+)/)[1], native.match(/kExtraCount = (\d+)/)[1], 'JNI packet width')
for (const source of [native, read('ios/Classes/TiSynthengineModule.m')]) {
  assert(source.includes('#include "../../shared/synth_transport.h"'), 'both callbacks use shared transport')
  assert(source.includes('synth_effects_process_routed('), 'both callbacks use shared selective processing')
}
console.log('API linkage: 25 methods, closed native option parity, JNI layout and shared core PASS')
