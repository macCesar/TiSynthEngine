#!/usr/bin/env python3
"""Exercise production Apple event polling with real dispatch timers/transport.

Only AVAudioEngine and the Titanium event sink are replaced. Startup's transport
initialization, event methods, publication and metadata pruning are verbatim.
"""
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / 'ios/Classes/TiSynthengineModule.m').read_text()

def method(name):
    match = re.search(r'^- \([^\n]+\)' + name + r'(?=[:\s])', source, re.M)
    if not match:
        return None
    opening = source.index('{', match.start())
    depth, end = 1, opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[match.start():end]

names = ['pruneVoiceMetadata', 'drainSequenceEvents', 'publishSequence',
         'maxFrequencyHz', 'acceptValidation', 'warnOnceMethod',
         'scheduleSequencePoll', 'cancelSequencePoll']
methods = [body for name in names if (body := method(name))]
prefix = source[source.index('#define DEFAULT_SAMPLE_RATE'):source.index('@interface TiSynthengineModule ()')]
ivars = source.split('@interface TiSynthengineModule () {', 1)[1].split('\n}\n@end', 1)[0]
init = source[source.index('synth_transport_init(sequence,'):source.index('processingOptions=synth_effects_default_config();')]
shutdown = method('shutdown')
cancel = shutdown.split('  [audioEngine stop];', 1)[1].split('  synth_effects_destroy', 1)[0]
imports = '''#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <dispatch/dispatch.h>
#include <assert.h>
#include <stdint.h>
#include <stdbool.h>
#define DebugLog(...) ((void)0)
@class AVAudioEngine, AVAudioSourceNode;
typedef NSString *AVAudioSessionCategory;
'''
for header in ['synth_core', 'synth_output', 'synth_effects', 'synth_held', 'synth_retrigger',
               'synth_modulation', 'synth_spatial', 'synth_stats', 'synth_transport']:
    imports += '#include "' + str(ROOT / 'shared' / (header + '.h')) + '"\n'
imports += '#import "' + str(ROOT / 'ios/Classes/TiSynthengineContract.h') + '"\n'
declarations = '\n'.join(m[:m.index('{')].strip() + ';' for m in methods)
held = re.search(r'  if\(!dropped&&voiceId\).*', source).group(0)
generated = imports + prefix + '\n@interface TiSynthengineModule : NSObject { @public\n' + ivars + '''
  NSMutableArray *delivered;
  void (^onEnd)(NSDictionary *);
}
- (void)startHarness;
- (void)shutdownHarness;
- (void)publishHeldMetadata;
- (void)fireEvent:(NSString *)name withObject:(NSDictionary *)event;
''' + declarations + '\n@end\n@implementation TiSynthengineModule\n' + '\n'.join(methods) + '''
- (void)startHarness {
  NSDictionary *options=@{@"maxSequences":@4};
  engineSampleRate=48000;engineMaxVoices=8;
  commandProducerLock=OS_UNFAIR_LOCK_INIT;
  voiceGenerations=[NSMutableDictionary dictionary];voicePositions=[NSMutableDictionary dictionary];voiceSpatialModes=[NSMutableDictionary dictionary];
  audioEngine=(AVAudioEngine *)[NSObject new];sequence=calloc(1,sizeof(*sequence));
  if(!delivered)delivered=[NSMutableArray array];
''' + init + '''
}
- (void)shutdownHarness {
''' + cancel + '''
  free(sequence);sequence=NULL;sequenceOptions=nil;audioEngine=nil;
  [voiceGenerations removeAllObjects];[voicePositions removeAllObjects];[voiceSpatialModes removeAllObjects];
}
- (void)fireEvent:(NSString *)name withObject:(NSDictionary *)event {
  assert([name isEqual:@"sequenceend"]);[delivered addObject:event];if(onEnd)onEnd(event);
}
''' + '''- (void)publishHeldMetadata {
  BOOL dropped=NO;int voiceId=42;SynthCommand cmd={0};cmd.voiceGeneration=1;
''' + held + '''
}
@end
''' + (ROOT / 'tests/sequence_events_ios.m').read_text()
with tempfile.TemporaryDirectory(prefix='synth-ios-events-') as folder:
    path = Path(folder) / 'events.m'
    path.write_text(generated)
    executable = Path(folder) / 'events'
    subprocess.run(['clang', '-std=c11', '-fobjc-arc', '-O1', '-Wall', '-Wextra',
                    '-Wno-unused-function', '-framework', 'Foundation', '-framework',
                    'AudioToolbox', str(path), str(ROOT / 'ios/Classes/TiSynthengineContract.m'),
                    '-o', str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=10)
