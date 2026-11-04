#!/usr/bin/env node
'use strict';
// Host-only measurements of the canonical JS layer over allocation-minimal spies.
// This does not measure Titanium, native validation, render CPU, DSP or audio.
const fs = require('node:fs');
const { Buffer } = require('node:buffer');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const v8 = require('node:v8');
const inspector = require('node:inspector');
const { performance, PerformanceObserver, constants } = require('node:perf_hooks');
const api = require('../assets/ti.synthengine');
if (!global.gc) throw new Error('Run Node with --expose-gc');
const output = process.argv[2];
if (!output) throw new Error('Usage: node --expose-gc tools/benchmark_sound_api.js OUTPUT.json');
const seed = 20261103;
const config = { seed, replicates: 7, finiteIterations: 12000, patternIterations: 160,
  warmupFinite: 4000, warmupPattern: 40, patternSteps: 512, allocationIterationsFinite: 4000,
  allocationIterationsPattern: 80, samplingInterval: 1024, allocationReplicates: 5, lifecycleReplicates: 5, lifecycleWarmup: 2000, lifecycleGroups: 10,
  lifecyclePerGroup: 400, weakCountPerKind: 500, gcTurns: 12 };
// Declared before measurement. Flags call for investigation, never automatic acceptance.
const thresholds = { finiteExtraUs: 10, patternExtraUs: 1000, ratio: 2,
  weakClearedFraction: .95, lifecycle: 'Investigate unexplained positive reachable-object/registry growth at any size; heap slope is diagnostic only.' };
const nextTurn = () => new Promise(resolve => setImmediate(resolve));
const jsonCopy = value => JSON.parse(JSON.stringify(value));
const gcEvents = [];
let phase = 'setup';
const observer = new PerformanceObserver(list => {
  for (const item of list.getEntries()) gcEvents.push({ phase, kind: item.detail.kind,
    flags: item.detail.flags, startTime: item.startTime, durationMs: item.duration });
});
observer.observe({ entryTypes: ['gc'] });
const kinds = Object.fromEntries(Object.entries(constants).filter(([key]) => key.startsWith('NODE_PERFORMANCE_GC_')));
function engine() {
  const calls = Object.create(null), listeners = new Map();
  const runtime = { generation: 1, running: true };
  let serial = 0, latestPattern = 0;
  const count = method => { calls[method] = (calls[method] || 0) + 1; };
  const native = {
    _validateSoundOptions() { count('_validateSoundOptions'); return null; },
    _soundRuntime() { count('_soundRuntime'); return runtime; },
    _allocateSoundNote() { count('_allocateSoundNote'); return ++serial; },
    _soundHeld() { count('_soundHeld'); return true; },
    _soundNoteToMidi() { count('_soundNoteToMidi'); return 60; },
    playTone() { count('playTone'); return true; },
    playChord() { count('playChord'); return true; },
    repeatTone() { count('repeatTone'); return ++serial; },
    playSequence() { count('playSequence'); latestPattern = ++serial; return latestPattern; },
    updateTone() { count('updateTone'); return true; },
    stopTone() { count('stopTone'); return true; },
    updateSequence() { count('updateSequence'); return true; },
    stopSequence() { count('stopSequence'); return true; },
    addEventListener(name, fn) {
      count('addEventListener');
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(fn);
    },
    removeEventListener(name, fn) { count('removeEventListener'); listeners.get(name)?.delete(fn); }
  };
  Object.assign(native, api);
  const completed = { sequenceId: 0, reason: 'completed' }, invalidation = { generation: 0 };
  function emit(name, event) { for (const fn of listeners.get(name) || []) fn(event); }
  return { native, calls, runtime,
    retire() { completed.sequenceId = latestPattern; emit('sequenceend', completed); },
    shutdown() { runtime.running = false; runtime.generation++; invalidation.generation = runtime.generation; emit('_soundinvalidate', invalidation); },
    start() { runtime.running = true; },
    listenerCounts() { return Object.fromEntries([...listeners].map(([name, set]) => [name, set.size])); },
    clearCounts() { for (const key of Object.keys(calls)) delete calls[key]; } };
}
const finite = { sound: { waveType: 0, attack: 2, release: 40, volume: .2 },
  playback: { type: 'tone', frequencies: [440], duration: 180 } };
const chord = { sound: { waveType: 2, attack: 2, release: 40, volume: .2, panSpread: .8 },
  playback: { type: 'chord', frequencies: Array.from({ length: 16 }, (_, i) => 220 * 2 ** (i / 12)), duration: 180 } };
const pattern = { sound: { waveType: 0, attack: 2, decay: 20, sustain: .6, release: 40, volume: .2 },
  playback: { type: 'pattern', timeUnit: 'ms', interval: 160, loop: false,
    steps: Array.from({ length: config.patternSteps }, (_, i) => ({ frequencies: [220 * 2 ** ((i * 7 + seed) % 24 / 12)],
      interval: 160, length: 120, sound: { pan: (i % 3 - 1) * .7, variation: { amount: .2, seed: i + seed, ranges: { volume: [.9, 1] } } } })) } };
function legacyDefinition(preset) {
  if (preset.playback.type === 'pattern') return { voice: jsonCopy(preset.sound), timeUnit: 'ms', stepDuration: 160, loop: false,
    steps: preset.playback.steps.map(step => ({ frequencies: step.frequencies.slice(), duration: step.interval, length: step.length, overrides: jsonCopy(step.sound) })) };
  return Object.assign({}, preset.sound, preset.playback.type === 'tone' ? { frequency: 440 } : { frequencies: preset.playback.frequencies.slice() }, { duration: 180 });
}
function caseRunner(name, preset, changed) {
  const rig = engine(), legacy = legacyDefinition(preset), sound = rig.native.createSound(preset);
  const isPattern = preset.playback.type === 'pattern';
  const method = isPattern ? 'playSequence' : preset.playback.type === 'chord' ? 'playChord' : 'playTone';
  const patch = { volume: .25 };
  return { name, rig, isPattern, sound,
    old() { rig.native[method](changed ? isPattern ? Object.assign({}, legacy, { voice: Object.assign({}, legacy.voice, patch) }) : Object.assign({}, legacy, patch) : legacy); if (isPattern) rig.retire(); },
    current() { sound.play(changed ? patch : undefined); if (isPattern) rig.retire(); } };
}
const percentile = (values, fraction) => values.slice().sort((a, b) => a - b)[Math.min(values.length - 1, Math.ceil(values.length * fraction) - 1)];
function summary(values) { return { samples: values, median: percentile(values, .5), p95: percentile(values, .95), min: Math.min(...values), max: Math.max(...values) }; }
function dispatch(fn, count) { const start = performance.now(); for (let i = 0; i < count; i++) fn(); return (performance.now() - start) * 1000 / count; }
async function collectGC() { global.gc(); await nextTurn(); await nextTurn(); }
async function timed(runner) {
  const n = runner.isPattern ? config.patternIterations : config.finiteIterations;
  const warm = runner.isPattern ? config.warmupPattern : config.warmupFinite;
  phase = runner.name + ':warmup';
  dispatch(runner.old, warm); dispatch(runner.current, warm);
  const samples = { old: [], current: [] }, heaps = { old: [], current: [] }, counts = {};
  for (let rep = 0; rep < config.replicates; rep++) {
    for (const mode of rep % 2 ? ['current', 'old'] : ['old', 'current']) {
      phase = runner.name + ':' + mode;
      await collectGC(); runner.rig.clearCounts();
      const before = process.memoryUsage().heapUsed;
      samples[mode].push(dispatch(runner[mode], n));
      heaps[mode].push((process.memoryUsage().heapUsed - before) / n);
      counts[mode] = Object.fromEntries(Object.entries(runner.rig.calls).map(([method, count]) => [method, count / n]));
      await nextTurn();
    }
  }
  const old = summary(samples.old), current = summary(samples.current);
  return { case: runner.name, iterationsPerBatch: n, units: 'microseconds per dispatch (pattern includes immediate simulated end delivery)', old, current,
    ratioOfMedians: current.median / old.median, extraUs: current.median - old.median,
    diagnosticSlowFlag: current.median / old.median >= thresholds.ratio && current.median - old.median > (runner.isPattern ? thresholds.patternExtraUs : thresholds.finiteExtraUs),
    bridgeMethodCallsPerDispatch: counts, netHeapBytesPerDispatchBeforeGC: { old: summary(heaps.old), current: summary(heaps.current) },
    listenerCountsAfterRetirement: runner.rig.listenerCounts() };
}
const session = new inspector.Session();
session.connect();
const post = (method, params = {}) => new Promise((resolve, reject) => session.post(method, params, (error, result) => error ? reject(error) : resolve(result)));
async function allocations(runner, mode) {
  phase = runner.name + ':' + mode + ':allocation-sampling';
  await collectGC();
  await post('HeapProfiler.startSampling', { samplingInterval: config.samplingInterval, includeObjectsCollectedByMajorGC: true, includeObjectsCollectedByMinorGC: true });
  const iterations = runner.isPattern ? config.allocationIterationsPattern : config.allocationIterationsFinite;
  dispatch(runner[mode], iterations);
  const { profile } = await post('HeapProfiler.stopSampling');
  const stacks = [];
  function walk(node) {
    if (node.selfSize) stacks.push({ function: node.callFrame.functionName || '(anonymous)', url: node.callFrame.url, bytes: node.selfSize });
    for (const child of node.children || []) walk(child);
  }
  walk(profile.head);
  const sampledBytes = stacks.reduce((sum, entry) => sum + entry.bytes, 0);
  const grouped = new Map();
  for (const entry of stacks) { const key = entry.function + ' @ ' + entry.url; grouped.set(key, (grouped.get(key) || 0) + entry.bytes); }
  return { case: runner.name, mode, iterations, sampledBytes, sampledBytesPerDispatch: sampledBytes / iterations,
    topAllocationSites: [...grouped].sort((a, b) => b[1] - a[1]).slice(0, 10),
    limitation: 'V8 statistical allocation sampling includes collected objects; estimated bytes, not exact object counts. Sampled separately from timing.' };
}
const smallPattern = { sound: { waveType: 0, release: 40 }, playback: { type: 'pattern', timeUnit: 'ms', interval: 160,
  steps: [{ notes: [60] }, { notes: [64] }, { notes: [67] }, { rest: true }] } };
const held = { sound: { waveType: 0, release: 40 }, playback: { type: 'held', frequencies: [440] } };
const repeat = { sound: { waveType: 0, release: 40 }, playback: { type: 'repeat', frequencies: [440], duration: 180, interval: 200 } };
function regressionSlope(values) {
  const meanX = (values.length - 1) / 2, meanY = values.reduce((sum, value) => sum + value, 0) / values.length;
  return values.reduce((sum, value, i) => sum + (i - meanX) * (value - meanY), 0) / values.reduce((sum, _, i) => sum + (i - meanX) ** 2, 0);
}
async function lifecycle(mode) {
  phase = 'lifecycle:' + mode;
  const rig = engine(), sounds = mode === 'current' ? [held, repeat, smallPattern].map(preset => rig.native.createSound(preset)) : null;
  let callbacks = 0;
  const onEnd = () => { callbacks++; };
  const heaps = [], listeners = [];
  for (let i = 0; i < config.lifecycleWarmup; i++) {
    if (mode === 'current') { sounds[0].noteOn().noteOff(); sounds[1].play().stop(); sounds[2].play(); rig.retire(); }
    else { const a = { stop() {} }; a.stop(); }
  }
  rig.shutdown(); rig.start();
  await collectGC(); await collectGC();
  for (let group = 0; group < config.lifecycleGroups; group++) {
    for (let i = 0; i < config.lifecyclePerGroup; i++) {
      if (mode === 'current') {
        sounds[0].noteOn().noteOff(); sounds[1].play().stop();
        const control = sounds[2].play(); control.addEventListener('end', onEnd); rig.retire();
      } else {
        // Same bounded scaffolding count; no retained references to the bare controls.
        const a = { noteOff() {} }, b = { stop() {} }, c = { listener: onEnd };
        a.noteOff(); b.stop(); c.listener();
      }
    }
    rig.shutdown(); rig.start();
    await collectGC();
    heaps.push(process.memoryUsage().heapUsed); listeners.push(rig.listenerCounts());
  }
  return { mode, createdControls: config.lifecycleGroups * config.lifecyclePerGroup * 3, callbacks,
    expectedCallbacks: config.lifecycleGroups * config.lifecyclePerGroup, postGCHeapBytes: heaps,
    heapSlopeBytesPerGroup: regressionSlope(heaps), heapSlopeBytesPerControl: regressionSlope(heaps) / (config.lifecyclePerGroup * 3),
    listenerCounts: listeners, gcObserverDisabled: true, limitation: 'Heap slope includes JIT/runtime variance; compare bare scaffolding and WeakRef results, never infer reachability solely from heapUsed.' };
}
async function weakReachability(mode) {
  phase = 'weak-reachability:' + mode;
  const rig = engine(), weak = { sound: [], held: [], repeat: [], completedPattern: [], shutdownPattern: [] }, finalized = {};
  const registry = new FinalizationRegistry(kind => { finalized[kind] = (finalized[kind] || 0) + 1; });
  function watch(value, kind) { weak[kind].push(new WeakRef(value)); registry.register(value, kind); }
  function createUnreachable() {
    for (let i = 0; i < config.weakCountPerKind; i++) {
      if (mode === 'current') {
        watch(rig.native.createSound(finite), 'sound');
        const note = rig.native.createSound(held).noteOn(); note.noteOff(); watch(note, 'held');
        const repetition = rig.native.createSound(repeat).play(); repetition.stop(); watch(repetition, 'repeat');
        const patternControl = rig.native.createSound(smallPattern).play(); patternControl.addEventListener('end', () => {}); rig.retire(); watch(patternControl, 'completedPattern');
        const cancelled = rig.native.createSound(smallPattern).play(); cancelled.addEventListener('end', () => {}); watch(cancelled, 'shutdownPattern');
      } else for (const kind of Object.keys(weak)) watch({ kind, i }, kind);
    }
    rig.shutdown(); rig.start();
  }
  createUnreachable();
  // No deref until all asynchronous GC turns finish: deref keeps its target alive for the current job.
  await nextTurn();
  for (let i = 0; i < config.gcTurns; i++) await collectGC();
  const remaining = Object.fromEntries(Object.entries(weak).map(([kind, refs]) => [kind, refs.reduce((sum, ref) => sum + (ref.deref() === undefined ? 0 : 1), 0)]));
  return { mode, objectsPerKind: config.weakCountPerKind, gcTurns: config.gcTurns, remaining, finalized,
    flag: Object.values(remaining).some(count => count > config.weakCountPerKind * (1 - thresholds.weakClearedFraction)),
    listenerCounts: rig.listenerCounts(), limitation: 'Finalization timing is nondeterministic; WeakRef clearing after separate jobs is the primary reachability observation.' };
}
async function persistentSounds() {
  phase = 'idle-sound-cost'; await collectGC();
  const before = process.memoryUsage().heapUsed;
  let sounds = Array.from({ length: 3000 }, () => engineForIdle.native.createSound(finite));
  await collectGC(); const retained = process.memoryUsage().heapUsed;
  const count = sounds.length; sounds = null;
  await collectGC();
  return { sounds: count, postGCBytesPerRetainedSoundIncludingArraySlots: (retained - before) / count,
    heapBefore: before, heapWhileRetained: retained, heapAfterDropping: process.memoryUsage().heapUsed,
    bridgeCallsDuringDefinition: engineForIdle.calls, limitation: 'Same small preset; no native proxies allocated by spies. Native resources cannot be measured here.' };
}
async function snapshotCounts() {
  await collectGC();
  const chunks = [];
  for await (const chunk of v8.getHeapSnapshot()) chunks.push(chunk);
  const snapshot = JSON.parse(Buffer.concat(chunks).toString());
  const fields = snapshot.snapshot.meta.node_fields, types = snapshot.snapshot.meta.node_types[0];
  const stride = fields.length, typeIndex = fields.indexOf('type'), nameIndex = fields.indexOf('name'), sizeIndex = fields.indexOf('self_size');
  const categories = {}, controlClosures = {};
  const selected = new Set(['play', 'noteOn', 'set', 'getPreset', 'noteOff', 'update', 'stop', 'getState', 'addEventListener', 'removeEventListener']);
  for (let offset = 0; offset < snapshot.nodes.length; offset += stride) {
    const type = types[snapshot.nodes[offset + typeIndex]], name = snapshot.strings[snapshot.nodes[offset + nameIndex]];
    if (!categories[type]) categories[type] = { count: 0, shallowBytes: 0 };
    categories[type].count++; categories[type].shallowBytes += snapshot.nodes[offset + sizeIndex];
    if (type === 'closure' && selected.has(name)) controlClosures[name] = (controlClosures[name] || 0) + 1;
  }
  return { categories, controlClosures };
}
async function retentionSnapshots(mode) {
  const rig = engine(), sounds = mode === 'current' ? [held, repeat, smallPattern].map(preset => rig.native.createSound(preset)) : null;
  function batch(n) {
    for (let i = 0; i < n; i++) {
      if (mode === 'current') { sounds[0].noteOn().noteOff(); sounds[1].play().stop(); sounds[2].play(); rig.retire(); }
      else { const a = { noteOff() {} }, b = { stop() {} }; a.noteOff(); b.stop(); }
    }
  }
  batch(4000); rig.shutdown(); rig.start(); await collectGC();
  const before = await snapshotCounts();
  for (let group = 0; group < 20; group++) { batch(500); rig.shutdown(); rig.start(); await collectGC(); }
  const after = await snapshotCounts();
  const controlClosureDeltas = Object.fromEntries([...new Set([...Object.keys(before.controlClosures), ...Object.keys(after.controlClosures)])]
    .map(name => [name, (after.controlClosures[name] || 0) - (before.controlClosures[name] || 0)]));
  const categoryDeltas = Object.fromEntries(Object.keys(after.categories).map(type => [type, {
    count: after.categories[type].count - (before.categories[type]?.count || 0),
    shallowBytes: after.categories[type].shallowBytes - (before.categories[type]?.shallowBytes || 0) }]));
  return { mode, measuredControls: 30000, warmupControls: 12000, before, after, controlClosureDeltas, categoryDeltas,
    listenerCounts: rig.listenerCounts(), limitation: 'Two host heap snapshots around bounded work; method closure counts include other runtime objects with the same names, with bare scaffolding for comparison. This cannot establish native resource lifetime.' };
}
const engineForIdle = engine();
(async () => {
  const source = fs.readFileSync(path.join(__dirname, '../assets/ti.synthengine.js'));
  const results = { schema: 1, generatedAt: new Date().toISOString(), command: [process.execPath, ...process.execArgv, ...process.argv.slice(1)],
    system: { platform: process.platform, arch: process.arch, osRelease: os.release(), cpu: os.cpus()[0]?.model, cpuCount: os.cpus().length,
      totalMemory: os.totalmem(), loadAverageAtStart: os.loadavg(), node: process.version, versions: process.versions }, canonicalSHA256: crypto.createHash('sha256').update(source).digest('hex'),
    benchmarkSHA256: crypto.createHash('sha256').update(fs.readFileSync(process.argv[1])).digest('hex'),
    config, thresholds, measurementLimits: [
      'Node/V8 host JS over no-op native-shaped spies; no real Titanium bridge, native validation, audio rendering, native memory, mobile CPU, or acoustic evidence.',
      'Legacy baseline receives prepared native dictionaries; current API owns immutable presets and validates through a no-op hook. Bridge counts are invocation counts only.',
      'Pattern dispatch includes synchronous simulated end delivery to retire controls, not real native scheduling or IPC.',
      'Timing p95 is across seven batch means, not individual-call latency. GC and allocation sampling are separate signals; heap delta is net allocation before incidental collections.'
    ], dispatch: [], allocationSampling: [], lifecycle: [], weakReachability: [] };
  const retentionOnly = process.argv.includes('--retention-only');
  if (retentionOnly) observer.disconnect();
  const runners = [];
  for (const [name, preset] of retentionOnly ? [] : [['finite', finite], ['chord16', chord], ['pattern512', pattern]]) for (const changed of [false, true]) runners.push(caseRunner(name + (changed ? ':overrides' : ':no-overrides'), preset, changed));
  for (const runner of runners) {
    const result = await timed(runner); results.dispatch.push(result);
    process.stderr.write(result.case + ': old ' + result.old.median.toFixed(3) + 'us; current ' + result.current.median.toFixed(3) + 'us; ratio ' + result.ratioOfMedians.toFixed(1) + '\n');
  }
  // Complete every timing case before statistical profiling can affect the JIT.
  for (const runner of runners) {
    for (let rep = 0; rep < config.allocationReplicates; rep++) {
      for (const mode of rep % 2 ? ['current', 'old'] : ['old', 'current']) results.allocationSampling.push({ replicate: rep, ...await allocations(runner, mode) });
    }
  }
  results.allocationSummary = runners.flatMap(runner => ['old', 'current'].map(mode => ({ case: runner.name, mode,
    sampledBytesPerDispatch: summary(results.allocationSampling.filter(item => item.case === runner.name && item.mode === mode).map(item => item.sampledBytesPerDispatch)) })));
  // Stop retaining GC event records before measuring post-GC heap trends.
  await nextTurn(); await nextTurn(); observer.disconnect();
  if (!retentionOnly) results.persistentSounds = await persistentSounds();
  for (let rep = 0; rep < (retentionOnly ? 0 : config.lifecycleReplicates); rep++) {
    for (const mode of rep % 2 ? ['current', 'bare'] : ['bare', 'current']) results.lifecycle.push({ replicate: rep, ...await lifecycle(mode) });
  }
  results.lifecycleSummary = (retentionOnly ? [] : ['bare', 'current']).map(mode => ({ mode, heapSlopeBytesPerControl: summary(results.lifecycle.filter(item => item.mode === mode).map(item => item.heapSlopeBytesPerControl)) }));
  for (const mode of retentionOnly ? [] : ['bare', 'current']) results.weakReachability.push(await weakReachability(mode));
  if (retentionOnly) { results.retentionSnapshots = []; for (const mode of ['bare', 'current']) results.retentionSnapshots.push(await retentionSnapshots(mode)); }
  await nextTurn(); await nextTurn(); observer.disconnect(); session.disconnect();
  results.gc = { constants: kinds, events: gcEvents, count: gcEvents.length, totalPauseMs: gcEvents.reduce((sum, event) => sum + event.durationMs, 0),
    attributionLimit: 'Observer delivery can lag one job; labels are coarse phase attribution, not exact GC origin. Explicit full-GC pauses are included.' };
  results.finalHeapStatistics = v8.getHeapStatistics();
  results.system.loadAverageAtEnd = os.loadavg();
  fs.mkdirSync(path.dirname(path.resolve(output)), { recursive: true });
  fs.writeFileSync(output, JSON.stringify(results, null, 2) + '\n');
  process.stderr.write('Wrote ' + output + '\n');
})().catch(error => { session.disconnect(); observer.disconnect(); console.error(error); process.exitCode = 1; });
