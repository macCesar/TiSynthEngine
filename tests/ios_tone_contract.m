#import <Foundation/Foundation.h>
#import "../ios/Classes/TiSynthengineContract.h"
#include <assert.h>
int main(void) { @autoreleasepool {
 NSDictionary *base=@{@"frequency":@440,@"duration":@20,@"attack":@1,@"release":@2};
 for(NSNumber *interval in @[@1,@120,@60000]) {
  NSMutableDictionary *o=[base mutableCopy];o[@"intervalMs"]=interval;
  assert([TiSynthengineContract validateRepeatTone:o maxFrequency:20000]==nil);
 }
 for(id interval in @[@0,@60001,@1.5,@YES,@"120",[NSNull null],@(NAN)]) {
  NSMutableDictionary *o=[base mutableCopy];o[@"intervalMs"]=interval;
  assert([TiSynthengineContract validateRepeatTone:o maxFrequency:20000]!=nil);
 }
 assert(([TiSynthengineContract validateNoteOn:@{@"voiceId":@1,@"intervalMs":@120} maxFrequency:20000]!=nil));
 assert(([TiSynthengineContract validateChord:@{@"notes":@[@"A4"],@"intervalMs":@120} maxFrequency:20000]!=nil));
 assert([TiSynthengineContract validateRepeatTone:base maxFrequency:20000]!=nil);
 NSMutableDictionary *single=[base mutableCopy];single[@"intervalMs"]=@120;assert([TiSynthengineContract validateTone:single maxFrequency:20000]!=nil);
 NSDictionary *d=[TiSynthengineContract defaultsWithMaxFrequency:20000];
 assert([d[@"version"] isEqual:@"2.0.0"]);
 assert([d[@"capabilities"][@"toneRepetition"] boolValue]);
 assert([d[@"limits"][@"maxToneRepetitions"][@"max"] intValue]==32);
 puts("Apple repetition contract: valid/invalid intervals, source separation and API limits PASS");
 } return 0; }
