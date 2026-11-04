// Silent, same-runtime comparison. Temporary Titanium app on a simulator/emulator.
// Progress: sound-api-performance-progress.json; final: sound-api-performance.json.
'use strict';
var synth = require('ti.synthengine');
var win = Ti.UI.createWindow({ backgroundColor: '#ffffff' });
var label = Ti.UI.createLabel({ color: '#222222', text: 'Preparing silent Sound API comparison', left: 20, right: 20 });
win.add(label);
var reportFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'sound-api-performance.json');
var progressFile = Ti.Filesystem.getFile(Ti.Filesystem.applicationDataDirectory, 'sound-api-performance-progress.json');
var epoch = Date.now(), phase = null, phaseIndex = -1, timer = null, pollTimer = null, watchdogTimer = null, heartbeatTimer = null, finished = false;
var nextVoice = 1000, currentControls = null, reusable = null, idleStage = 'initial-before-definitions';
var config = { maxVoices: 32, maxSequences: 4, mixingProfile: 'conservative', audioSession: 'ambient' };
var report = {
  schemaVersion: 1, complete: false, success: false, startedAt: new Date().toISOString(), startedAtEpochMs: epoch,
  platform: { osname: Ti.Platform.osname, version: Ti.Platform.version, model: Ti.Platform.model, architecture: Ti.Platform.architecture },
  protocol: {
    revision: 2, diagnosticsRevision: 1,
    soakDiagnostics: 'Raw native sequenceend and scoped completion rings max16; JS heartbeat100ms during held/pattern only; unchanged1500ms end watchdog captures state/stats/runtime/latency before shutdown',
    warmupBarrier: 'After warmup stopAll, asynchronously poll native pendingCommands every10ms; start measured time only after zero; fail after1000ms',
    comparison: 'Deprecated native calls versus reusable Sound calls in the same candidate binary, runtime and DSP',
    masterVolume: 0, statsEnabledInBothModes: true, maxVoices: 32, maxSequences: 4, seed: 424242,
    timer: 'Date.now(), integer millisecond wall time; timed batches contain 200 calls',
    dispatchMetric: 'Median/p95 of batch elapsed milliseconds divided by 200; not single-call latency percentiles',
    dispatchExcludes: 'Sound construction, getStats, file writes, UI updates, orchestration waits',
    renderMetric: 'Public native renderLoad/peakRenderLoad snapshots; no callback percentile is inferred',
    memory: 'availableMemory bytes have platform-specific scope: Android unused allocated Java heap; iOS system free pages. Neither is process RSS, JavaScript heap usage, allocation count or GC frequency',
    garbageCollection: 'No public GC/heap API assumed or forced; root collects CPU/RSS externally by persisted phase timestamps',
    musicalTiming: 'Pattern attacks use native scheduling. JavaScript delays only delimit benchmark batches, control lifetimes and lifecycle phases',
    order: 'Old/new for chords, new/old for finite bursts, old/new for held/pattern, new/old for lifecycle',
    limits: 'Same fixed call counts and recipes; dispatch speed can change native queue admission opportunities. Compare accepted/rejected counts with timing',
    thresholds: 'No automatic performance threshold; preserve raw paired measurements for review',
    nominalDurationMs: 174000, watchdogMs: 178000,
    bridgeCallModel: {
      revision: 'optimized-current-source',
      canonicalEntrySha256: '5d7ce25c7d5bd8272ee3aba01f252819b83e79ef3e77136c6a0fbe0e8b766411',
      scope: 'Source-derived native method invocations on successful active same-generation paths, not instrumented bridge tracing; excludes telemetry and native event registration',
      deprecatedFinite: 1, soundFinite: 1, soundConstruction: 1,
      deprecatedHeldStart: 1, soundNoteOn: 3, deprecatedHeldUpdate: 1, soundNoteUpdate: 3,
      deprecatedHeldOff: 1, soundNoteOff: 2, deprecatedPatternStart: 1, soundPatternStart: 2,
      deprecatedPatternUpdate: 1, soundPatternUpdate: 2, deprecatedPatternStop: 1, soundPatternStop: 2,
      deprecatedPatternGetState: 1, soundPatternGetState: 2,
      soundPatternListenerAttachmentRuntimeQueries: 1, soundPatternEndGenerationRuntimeQueries: 1,
      constructorNoteNameConversions: 'One additional native conversion per pattern note-name occurrence when compiling changed steps; this probe uses numeric MIDI steps',
      rejectedPublicationDiagnostic: 'A false finite, held-start, repetition or pattern publication/update can invoke one extra pure native validation diagnostic; held live updates already validate before publication',
      note: 'Cached successful finite play publishes once. Controls retain runtime generation checks. BEFORE reports contain the earlier unoptimized model; do not apply these counts to that binary'

    }
  }, phases: [], snapshots: [], errors: [], errorDetails: [], recentNativeSequenceEnds: [], nativeSequenceEndsObserved: 0
};
var frequencies = [];
for (var f = 0; f < 32; f++) frequencies.push(110 * Math.pow(2, f / 12));
var tone = { frequency: 440, frequencyEnd: 220, duration: 60, attack: 2, decay: 6, sustain: 0.6, release: 15,
  waveType: 0, volume: 0.02, fmRatio: 2, fmDepth: 0.3, fmDepthEnd: 0.1, bus: 'effects', priority: 1,
  variation: { amount: 1, seed: 424242, ranges: { volume: [0.015, 0.025], pitchCents: [-5, 5] } } };
var chord = { frequencies: frequencies, duration: 1500, attack: 2, release: 25, waveType: 3, volume: 0.01,
  bus: 'effects', priority: 1, variation: { amount: 1, seed: 424242, ranges: { volume: [0.008, 0.012], pitchCents: [-3, 3] } } };
var heldSound = { waveType: 0, volume: 0.015, attack: 2, release: 10, fmRatio: 2, fmDepth: 0.5,
  bus: 'effects', priority: 1, modulations: [{ target: 'fmDepth', wave: 'sine', rate: 2, depth: 0.1 }] };
var patternVoice = { waveType: 1, volume: 0.01, attack: 2, release: 10, bus: 'music', priority: 1,
  modulations: [{ target: 'pulseWidth', wave: 'sine', rate: 2, depth: 0.1 }],
  variation: { amount: 0.5, seed: 424242, ranges: { volume: [0.008, 0.012] } } };
var steps = [{ notes: [60], length: 30 }, { notes: [64, 67], length: 30 }, { rest: true }, { notes: [60, 64, 67], length: 30 }];
var oldPattern = { voice: patternVoice, timeUnit: 'ms', stepDuration: 50, loop: false, steps: steps };
var endCallbacks = {};
var schedule = [
  { mode: 'old', kind: 'chord32', durationMs: 8000, batches: 8 },
  { mode: 'sound', kind: 'chord32', durationMs: 8000, batches: 8 },
  { mode: 'sound', kind: 'finite', durationMs: 30000, batches: 30 },
  { mode: 'old', kind: 'finite', durationMs: 30000, batches: 30 },
  { mode: 'old', kind: 'held-pattern', durationMs: 30000 },
  { mode: 'sound', kind: 'held-pattern', durationMs: 30000 },
  { mode: 'sound', kind: 'lifecycle', durationMs: 10000, cycles: 10 },
  { mode: 'old', kind: 'lifecycle', durationMs: 10000, cycles: 10 }
];
function ownCopy(value) { return JSON.parse(JSON.stringify(value)); }
function platformMemory() {
  var value = Ti.Platform.availableMemory;
  var platform = Ti.Platform.osname;
  var scope = platform === 'android' ? 'Unused space inside the currently allocated Java heap (Runtime.freeMemory)'
    : ['iphone', 'ipad', 'ios'].indexOf(platform) !== -1 ? 'System free-page bytes (vm_page_size multiplied by vmStats.free_count)'
      : 'Platform scope not verified';
  return { availableMemoryBytes: typeof value === 'number' && isFinite(value) ? value : null,
    api: 'Ti.Platform.availableMemory', units: 'bytes', platform: platform, scope: scope,
    exclusions: 'Not process RSS or JavaScript heap usage; not comparable as the same memory category across platforms' };
}
function stats() { try { return synth.getStats(); } catch (error) { return { unavailable: String(error) }; } }
function saveReport() { reportFile.write(JSON.stringify(report)); }
function progress() {
  var now = Date.now();
  progressFile.write(JSON.stringify({ schemaVersion: 1, protocolRevision: 2, complete: report.complete, success: report.success, atEpochMs: now,
    at: new Date(now).toISOString(), startedAtEpochMs: epoch, elapsedMs: now - epoch,
    phaseIndex: phaseIndex, phase: phase ? phase.id : idleStage, mode: phase ? phase.mode : null,
    kind: phase ? phase.kind : 'idle', status: phase ? phase.status : 'idle',
    phaseStartedAtEpochMs: phase ? phase.startedAtEpochMs : epoch,
    measuredStartedAtEpochMs: phase ? phase.measuredStartedAtEpochMs : null,
    calls: phase ? phase.calls : 0, cycles: phase ? phase.cycles : 0, stats: stats(), platformMemory: platformMemory() }));
}
function sample(name) {
  var row = { name: name, atEpochMs: Date.now(), stats: stats(), platformMemory: platformMemory() };
  if (phase) { if (phase.samples.length < 120) phase.samples.push(row); }
  else report.snapshots.push(row);
  return row;
}
function errorInfo(error) {
  return { name: String(error && error.name || 'Error'), message: String(error && error.message || error), stack: String(error && error.stack || '') };
}
function fail(error) {
  if (finished) return;
  var detail = errorInfo(error);
  report.errors.push(detail.name + ': ' + detail.message);
  report.errorDetails.push(detail);
  report.errorName = detail.name; report.errorMessage = detail.message; report.errorStack = detail.stack;
  finish(false);
}
function boundedPush(rows, row) { rows.push(row); if (rows.length > 16) rows.shift(); }
function diagnosticRead(fn) { try { return fn(); } catch (error) { return { readError: errorInfo(error) }; } }
function runtimeDiagnostic() {
  return typeof synth._soundRuntime === 'function' ? diagnosticRead(function () { return synth._soundRuntime(); }) : { unavailable: true };
}
function beginHeartbeat(owner) {
  clearTimeout(heartbeatTimer);
  owner.heartbeat = { intervalMs: 100, ticks: 0, lastTickAtEpochMs: Date.now(), nextExpectedAtEpochMs: Date.now() + 100, maxLatenessMs: 0 };
  function tick() {
    if (finished || phase !== owner || owner.status !== 'running') return;
    var now = Date.now(), heartbeat = owner.heartbeat;
    heartbeat.lastLatenessMs = Math.max(0, now - heartbeat.nextExpectedAtEpochMs);
    heartbeat.maxLatenessMs = Math.max(heartbeat.maxLatenessMs, heartbeat.lastLatenessMs);
    heartbeat.lastTickAtEpochMs = now; heartbeat.ticks++;
    heartbeat.nextExpectedAtEpochMs = now + 100;
    heartbeatTimer = setTimeout(guard(tick), 100);
  }
  heartbeatTimer = setTimeout(guard(tick), 100);
}

function guard(fn) { return function () { if (finished) return; try { fn(); } catch (error) { fail(error); } }; }
function later(fn, delay) { timer = setTimeout(guard(fn), delay); }
function start() {
  if (!synth.start(config)) throw new Error('Engine startup rejected');
  if (!synth.setVolume(0)) throw new Error('Silent master rejected');
  if (!synth.enableStats()) throw new Error('Statistics enable rejected');
  if (!synth.setTempo(120)) throw new Error('Tempo rejected');
}
function definitions() {
  var shaping = ownCopy(tone);
  delete shaping.frequency; delete shaping.frequencyEnd; delete shaping.duration;
  var chordShaping = ownCopy(chord); delete chordShaping.frequencies; delete chordShaping.duration;
  return {
    tone: synth.createSound({ sound: shaping, playback: { type: 'tone', frequencies: [440], frequencyEnd: 220, duration: 60 } }),
    chord: synth.createSound({ sound: chordShaping, playback: { type: 'chord', frequencies: frequencies, duration: 1500 } }),
    held: synth.createSound({ sound: heldSound, playback: { type: 'held', frequencies: [220] } }),
    pattern: synth.createSound({ sound: patternVoice, playback: { type: 'pattern', timeUnit: 'ms', interval: 50, loop: false, steps: steps } })
  };
}
function accepted(value, operation) {
  phase.operations[operation] = (phase.operations[operation] || 0) + 1;
  if (value) phase.accepted++; else phase.rejected++;
  return value;
}
function dispatchFinite(mode, kind) {
  if (mode === 'sound') return reusable[kind === 'finite' ? 'tone' : 'chord'].play();
  return kind === 'finite' ? synth.playTone(tone) : synth.playChord(chord);
}
function batch(index) {
  sample('before-batch-' + index);
  var good = 0, bad = 0, began = Date.now();
  for (var i = 0; i < 200; i++) { if (dispatchFinite(phase.mode, phase.kind)) good++; else bad++; }
  var elapsed = Date.now() - began;
  phase.calls += 200; phase.accepted += good; phase.rejected += bad;
  phase.batches.push({ index: index, calls: 200, accepted: good, rejected: bad, elapsedMs: elapsed, meanDispatchMsPerCall: elapsed / 200 });
  sample('after-batch-' + index);
  progress();
  if (index + 1 < phase.target.batches) later(function () { batch(index + 1); }, Math.max(0, phase.measuredStartedAtEpochMs + (index + 1) * 1000 - Date.now()));
  else later(endPhase, Math.max(0, phase.measuredStartedAtEpochMs + phase.target.durationMs - Date.now()));
}
function releaseNote(control, mode) {
  return accepted(mode === 'sound' ? control.noteOff() : synth.noteOff({ voiceId: control }), 'heldOff');
}
function cycle() {
  if (Date.now() >= phase.deadlineEpochMs - 350) { later(endPhase, Math.max(0, phase.deadlineEpochMs - Date.now())); return; }
  var owner = phase, mode = phase.mode, ordinal = ++phase.cycles, cycleStartedAt = Date.now();
  var note = mode === 'sound' ? accepted(reusable.held.noteOn(), 'heldStart')
    : (accepted(synth.noteOn(Object.assign({ voiceId: ++nextVoice, frequency: 220 }, heldSound)), 'heldStart') ? nextVoice : false);
  if (note) accepted(mode === 'sound' ? note.update({ frequencies: [330], fmDepth: 0.25 })
    : synth.updateNote({ voiceId: note, frequency: 330, fmDepth: 0.25 }), 'heldUpdate');
  var pattern = accepted(mode === 'sound' ? reusable.pattern.play() : synth.playSequence(oldPattern), 'patternStart');
  if (!pattern) {
    if (note) releaseNote(note, mode);
    later(cycle, 50); return;
  }
  var completed = false, stopTimer = null, watchdog = null, publishedAt = Date.now(), watchdogDeadline = null;
  function ended(event) {
    if (completed || phase !== owner || finished) return;
    completed = true;
    clearTimeout(stopTimer); clearTimeout(watchdog);
    if (mode === 'sound') pattern.removeEventListener('end', ended); else delete endCallbacks[pattern];
    owner.events[event.reason] = (owner.events[event.reason] || 0) + 1;
    owner.lastCompletion = { phase: owner.id, mode: mode, cycle: ordinal, atEpochMs: Date.now(),
      cycleStartedAtEpochMs: cycleStartedAt, patternPublishedAtEpochMs: publishedAt,
      elapsedCycleMs: Date.now() - cycleStartedAt, elapsedSincePatternPublishMs: Date.now() - publishedAt,
      reason: event.reason, nativeSequenceId: mode === 'old' ? pattern : null };
    boundedPush(owner.recentCompletions, owner.lastCompletion);
    if (note) releaseNote(note, mode);
    currentControls = null;
    later(cycle, 10);
  }
  if (mode === 'sound') pattern.addEventListener('end', ended); else endCallbacks[pattern] = ended;
  currentControls = { note: note, pattern: pattern, mode: mode, cycle: ordinal, startedAtEpochMs: cycleStartedAt };
  accepted(mode === 'sound' ? pattern.update({ swing: 0.1 }) : synth.updateSequence({ sequenceId: pattern, swing: 0.1 }), 'patternUpdate');
  if (ordinal % 2 === 0) stopTimer = setTimeout(guard(function () {
    if (phase === owner && !completed) accepted(mode === 'sound' ? pattern.stop() : synth.stopSequence({ sequenceId: pattern }), 'patternStop');
  }), 100);
  watchdogDeadline = Date.now() + 1500;
  watchdog = setTimeout(guard(function () {
    if (!completed && phase === owner) {
      var now = Date.now(), heartbeat = owner.heartbeat;
      report.endWatchdog = { phase: owner.id, mode: mode, cycle: ordinal, atEpochMs: now,
        cycleStartedAtEpochMs: cycleStartedAt, patternPublishedAtEpochMs: publishedAt,
        watchdogDeadlineEpochMs: watchdogDeadline, watchdogLimitMs: 1500,
        elapsedCycleMs: now - cycleStartedAt, elapsedSincePatternPublishMs: now - publishedAt,
        watchdogTimerLatenessMs: Math.max(0, now - watchdogDeadline),
        nativeSequenceId: mode === 'old' ? pattern : null,
        state: diagnosticRead(function () { return mode === 'sound' ? pattern.getState() : synth.getSequenceState({ sequenceId: pattern }); }),
        stats: stats(), runtime: runtimeDiagnostic(), runtimeAtMeasuredStart: owner.runtimeAtMeasuredStart,
        heartbeat: heartbeat ? ownCopy(heartbeat) : null,
        heartbeatAgeMs: heartbeat ? now - heartbeat.lastTickAtEpochMs : null,
        heartbeatNextDeadlineLatenessMs: heartbeat ? Math.max(0, now - heartbeat.nextExpectedAtEpochMs) : null,
        lastCompletion: owner.lastCompletion || null, recentCompletions: owner.recentCompletions.slice(),
        recentNativeSequenceEnds: report.recentNativeSequenceEnds.slice(),
        rawEventCycleScope: 'cycleAtDelivery is JS phase context, not proof that a native ID belongs to a private Sound control' };
      throw new Error('Owned pattern end did not arrive within 1500 ms');
    }
  }), 1500);
}
function lifecycle(index) {
  var mode = phase.mode;
  if (index) start();
  var scratch = null;
  for (var i = 0; i < 100; i++) {
    scratch = mode === 'sound' ? synth.createSound({ sound: { volume: 0.01, attack: 2, release: 10 }, playback: { type: 'tone', frequencies: [440], duration: 60 } })
      : { sound: { volume: 0.01, attack: 2, release: 10 }, playback: { type: 'tone', frequencies: [440], duration: 60 } };
  }
  scratch = null;
  phase.discardedDefinitions += 100;
  var before = sample('definitions-without-play-' + index);
  if (before.stats.activeVoices !== 0) phase.notes.push('Nonzero active voices after construction-only exercise: ' + before.stats.activeVoices);
  var note = mode === 'sound' ? reusable.held.noteOn() : (synth.noteOn(Object.assign({ voiceId: ++nextVoice, frequency: 220 }, heldSound)) ? nextVoice : false);
  accepted(note, 'heldStart');
  var pattern = accepted(mode === 'sound' ? reusable.pattern.play() : synth.playSequence(oldPattern), 'patternStart');
  later(function () {
    if (note) releaseNote(note, mode);
    if (pattern) accepted(mode === 'sound' ? pattern.stop() : synth.stopSequence({ sequenceId: pattern }), 'patternStop');
    sample('before-shutdown-' + index);
    synth.shutdown(); phase.cycles++;
    currentControls = null;
    later(function () {
      sample('after-shutdown-' + index); progress();
      if (index + 1 < phase.target.cycles) later(function () { lifecycle(index + 1); }, Math.max(0, phase.measuredStartedAtEpochMs + (index + 1) * 1000 - Date.now()));
      else later(endPhase, Math.max(0, phase.deadlineEpochMs - Date.now()));
    }, 150);
  }, 100);
}
function percentile(sorted, fraction) { return sorted.length ? sorted[Math.max(0, Math.ceil(sorted.length * fraction) - 1)] : null; }
function endPhase() {
  clearTimeout(heartbeatTimer);
  phase.status = 'settling';
  phase.endedAtEpochMs = Date.now(); phase.elapsedMs = phase.endedAtEpochMs - phase.measuredStartedAtEpochMs;
  var ordered = phase.batches.map(function (row) { return row.meanDispatchMsPerCall; }).sort(function (a, b) { return a - b; });
  phase.dispatch = { batchCount: ordered.length, callsPerBatch: 200, medianBatchMeanMsPerCall: percentile(ordered, 0.5), p95BatchMeanMsPerCall: percentile(ordered, 0.95),
    zeroDurationBatches: phase.batches.filter(function (row) { return row.elapsedMs === 0; }).length,
    timingResolutionNote: 'Zero-ms batches are below Date.now resolution, not zero-cost calls; do not divide by a zero baseline',
    totalTimedMs: phase.batches.reduce(function (sum, row) { return sum + row.elapsedMs; }, 0), totalCalls: phase.calls };
  sample('end');
  currentControls = null; endCallbacks = {};
  synth.shutdown(); progress(); saveReport();
  later(nextPhase, 250);
}
function awaitNativeDrain(done) {
  var started = Date.now();
  phase.status = 'draining';
  phase.drain = { startedAtEpochMs: started, polls: 0, timeoutMs: 1000, intervalMs: 10 };
  function poll() {
    var now = Date.now();
    var pending = synth.getStats().pendingCommands;
    phase.drain.polls++;
    phase.drain.lastPendingCommands = pending;
    phase.drain.elapsedMs = now - started;
    if (now - started > 1000) throw new Error('Warmup native command drain exceeded1000ms');
    if (typeof pending !== 'number' || !isFinite(pending) || pending < 0) throw new Error('Native pendingCommands unavailable for warmup drain');
    if (pending === 0) {
      phase.drain.completedAtEpochMs = now;
      done();
      return;
    }
    later(poll, 10);
  }
  // Always yield first: a synchronous zero check cannot establish that the
  // audio thread has had an opportunity to apply the queued stopAll command.
  later(poll, 10);
}
function nextPhase() {
  if (++phaseIndex === schedule.length) {
    phase = null; idleStage = 'final-shutdown'; sample('final-shutdown-start'); progress();
    later(function () { sample('final-shutdown-settled'); finish(true); }, 4000); return;
  }
  var target = schedule[phaseIndex];
  phase = { id: target.kind + '-' + target.mode, mode: target.mode, kind: target.kind, target: target,
    status: 'warming', startedAtEpochMs: Date.now(), measuredStartedAtEpochMs: null, calls: 0, cycles: 0,
    accepted: 0, rejected: 0, discardedDefinitions: 0, batches: [], samples: [], operations: {}, events: {}, notes: [], recentCompletions: [] };
  report.phases.push(phase); label.text = 'Silent comparison: ' + phase.id; start(); progress();
  if (target.kind === 'finite' || target.kind === 'chord32') for (var i = 0; i < 100; i++) dispatchFinite(target.mode, target.kind);
  later(function () {
    synth.stopAll();
    awaitNativeDrain(function () {
      synth.resetStats();
      phase.status = 'running'; phase.measuredStartedAtEpochMs = Date.now(); phase.deadlineEpochMs = phase.measuredStartedAtEpochMs + target.durationMs;
      sample('measured-start'); progress(); saveReport();
      if (target.kind === 'finite' || target.kind === 'chord32') batch(0);
      else if (target.kind === 'held-pattern') { phase.runtimeAtMeasuredStart = runtimeDiagnostic(); beginHeartbeat(phase); cycle(); }
      else lifecycle(0);
    });
  }, 500);
}
function finish(success) {
  if (finished) return;
  finished = true; clearTimeout(timer); clearInterval(pollTimer); clearTimeout(watchdogTimer); clearTimeout(heartbeatTimer);
  try { synth.shutdown(); } catch (error) { report.errors.push(String(error)); }
  currentControls = null; endCallbacks = {}; reusable = null;
  report.complete = true; report.success = success && report.errors.length === 0;
  report.finishedAtEpochMs = Date.now(); report.elapsedMs = Date.now() - epoch;
  sample('finished'); saveReport(); progress();
  label.text = report.success ? 'Silent comparison complete. Export JSON and OS samples.' : 'Comparison failed. Export JSON for details.';
  Ti.API.info('SOUND_API_PERFORMANCE ' + JSON.stringify({ complete: true, success: report.success, elapsedMs: report.elapsedMs, phases: report.phases.length }));
}
synth.addEventListener('sequenceend', function (event) {
  if (!finished && phase && phase.kind === 'held-pattern') {
    report.nativeSequenceEndsObserved++;
    boundedPush(report.recentNativeSequenceEnds, { phase: phase.id, phaseIndex: phaseIndex, mode: phase.mode,
      cycleAtDelivery: phase.cycles, atEpochMs: Date.now(), sequenceId: event.sequenceId, reason: event.reason,
      ownership: phase.mode === 'old' && !!endCallbacks[event.sequenceId] ? 'matching legacy callback' : 'native tap; private Sound identity not exposed' });
  }
  var fn = endCallbacks[event.sequenceId]; if (fn) fn(event);
});
Ti.App.addEventListener('pause', function () { if (!finished) fail(new Error('App paused; comparison invalid')); });
win.addEventListener('open', function () {
  later(function () {
    report.version = synth.getContract().version;
    if (report.version !== '2.0.0' || synth.getDefaults().version !== report.version) throw new Error('Candidate module version mismatch');
    sample('after-require-before-definitions'); saveReport(); progress();
    pollTimer = setInterval(guard(function () { sample('poll'); progress(); }), 1000);
    watchdogTimer = setTimeout(guard(function () { throw new Error('178-second watchdog expired'); }), 178000);
    later(function () {
      reusable = definitions(); idleStage = 'initial-with-definitions'; report.retainedDefinitionsDuringRun = 4;
      sample('reusable-definitions-ready'); saveReport();
      later(nextPhase, 3000);
    }, 3000);
  }, 300);
});
win.open();
