# Sound API 2.0.0 candidate validation

This report covers the reusable Sound entry layer and consumer migration against baseline commit `3eff75d00fdcb62e45a1e15c06fc1415db40e73c`. It does not announce a release. The native rendering algorithms, gain profiles and scheduling cores were preserved.

## Functional and acoustic evidence

The pre-refactor engine passed all nine existing CI command groups. Focused additions exercise independent definitions and controls, recursive atomic edits, type precedence, temporary pitch overrides, generation invalidation, historical identifier collisions, processing units and unchanged legacy signatures.

There are 3,977 distinct compiled consumer requests replayed through the actual Java and Apple validators, including one intentionally rejected waveform. All match their expected outcome. The native Titanium bridge probe passes 35 checks on each virtual platform, including optional resets through the private full-revision boundary.

Eighty production-render PCM captures, compared independently within Android and Apple at five sample rates, are byte-identical to the baseline. Absolute and RMS errors are zero. The limits were fixed before comparison at maximum absolute error `1e-7` and RMS error `1e-8`; no alignment, gain normalization or time stretching was applied. Separate Apple callback tests compare old and owned held entries for six waveforms, spatial/stereo routing, seeded variation, live edits and release.

Optional-field reset tests use actual native contracts and the Apple render callback. They verify removal of old FM, filter, noise and modulation settings; atomic rejection; unchanged pattern clock and generation; unchanged next repetition deadline; and preserved variation seed/counter behavior. Deprecated partial-update methods retain their existing merge rules. A deterministic callback-transition test also covers the held-ID alias race when a pending note becomes active during metadata lookup.

## Allocation and lifetime evidence

Creating a Sound publishes no playback command and creates no independent native proxy. Reusable definitions hold private immutable revisions. Unchanged pattern steps are translated once; later revisions share untouched private branches without mutating another execution.

The initial implementation unnecessarily copied and validated complete recipes during every play. The measured correction reduced a 512-step host dispatch from roughly 1.49 ms and 6.07 MB of sampled allocation to about 1.01 microseconds and 1.50 KB. With temporary overrides, the final host medians are about 2.71 microseconds and 4.21 KB. A successful reusable finite play now invokes exactly one native publication method. These are Node/V8 measurements over native-shaped stand-ins, not Titanium bridge or audio-render timings. Batch quantiles and sampled allocations are retained separately from GC profiling.

All 2,500 weak targets cleared in the host reachability exercise. Thirty thousand measured control lifetimes produced no growth in control-method closures or engine listener subscriptions. Independent GC tests cover completed patterns, shutdown patterns, unused definitions and an unreachable engine registry. These observations concern the tested host and bounded workloads; they are not a universal GC guarantee.

A real retention defect was found in historical held-ID aliases. Before correction, 15,000 rejected Java requests and 4,000 completed Apple requests retained alias entries. Sparse aliases now retire after native voice retirement and clear on shutdown. Regression tests verify bounded maps, collision isolation and cleanup without requiring runtime RSS to return to its initial value.

## Runtime workload and interpretation

The portable probe compares deprecated and Sound entry points in the same candidate process, native module and runtime. Each mode requests 6,000 finite attacks and 1,600 32-pitch chords, plus held/pattern cycles and ten startup/shutdown cycles. Master output is muted; native voices and render statistics still run. Four persistent definitions are present in both modes.

Dispatch values are elapsed milliseconds per 200-call batch, divided by 200. Their median/p95 describe batch means, not individual-call latency. Native queue rejection changes the amount of admitted work, especially in intentionally saturated chord bursts and immediate pattern revisions. Raw CPU or render load must therefore be read with the admission counts. Accumulated native callback peaks are distinct from quantiles of polled render-load samples.

External process sampling records CPU time and RSS. `Ti.Platform.availableMemory` is reported separately: Android exposes unused currently allocated Java heap, while iOS exposes system free-page bytes. Neither is process RSS or JavaScript heap usage. The BEFORE report's older generic memory label is corrected by the accompanying interpretation record; its raw values are preserved.

The initial measurements used only virtual targets. The user subsequently authorized the connected Android and iPad: Studio was installed and launched on both, and the physical Android passed the 35-check native probe. Physical stress measurements are recorded separately from virtual results; no virtual-device metric establishes physical latency, battery use or extended-session stability.

## Consumer and Studio coverage

The migration covers Studio, Titanium Frontier, Titanium Guardian, Synth Playground, Ti-Synthetizer-App, BinauralLab, Simon Simple, Simon Game, TiSynth-Base and the official module example. Game firing paths reuse owner-local definitions and preserve complete temporary overrides, priorities, routing and retry behavior. Existing historical/audit tools remain available.

Studio tests cover generated recipes and actual publication parameters, cross-platform waveform serialization, format/version/capability rejection, editable state, naming/cancellation, active-tab copy/export, escaping and long Unicode recipes. Android native UI verification covers highlighted code, JSON file delivery through the system chooser, document selection, personal-preset creation and cancelling the optional load without changing the editor.

One unrelated pre-existing Studio test fails for roomy 900dp PWM pagination and was reproduced against its baseline controller. The independent review also deferred stricter rejection of Date/Map/class instances outside typed/plain JSON presets. Neither is represented as a passing check. The review of the performance, alias and full-revision fixes has no remaining Critical or Important findings.
