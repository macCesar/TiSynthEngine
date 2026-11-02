#import <Foundation/Foundation.h>
#import "../ios/Classes/TiSynthengineContract.h"
int main(int argc,char **argv) {
 @autoreleasepool {
 NSString *data=[NSString stringWithContentsOfFile:(argc>1?[NSString stringWithUTF8String:argv[1]]:@"tests/variation_contract_corpus.jsonl") encoding:NSUTF8StringEncoding error:nil];
 if(!data)return 2;
 int count=0,failures=0;
 for(NSString *line in [data componentsSeparatedByString:@"\n"]) {
  if(!line.length)continue;count++;
  NSDictionary *r=[NSJSONSerialization JSONObjectWithData:[line dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
  NSDictionary *o=r[@"options"],*f=nil;NSString *api=r[@"api"];
  if([api isEqual:@"tone"])f=[TiSynthengineContract validateTone:o maxFrequency:20000];
  else if([api isEqual:@"chord"])f=[TiSynthengineContract validateChord:o maxFrequency:20000];
  else if([api isEqual:@"noteOn"])f=[TiSynthengineContract validateNoteOn:o maxFrequency:20000];
  else if([api isEqual:@"updateVoice"])f=[TiSynthengineContract validateUpdateVoice:o maxFrequency:20000];
  else {SynthSequenceConfig *c=calloc(1,sizeof(*c));f=[TiSynthengineContract prepareSequence:o config:c maxFrequency:20000];free(c);}
  if((f==nil)!=[r[@"accepted"] boolValue]){failures++;fprintf(stderr,"FAIL iOS line %d %s: %s\n",count,api.UTF8String,f.description.UTF8String);}
 }
 for(NSDictionary *o in @[@{@"variation":@{@"amount":@(NAN)}},@{@"variation":@{@"seed":@(INFINITY)}},@{@"variation":@{@"ranges":@{@"volume":@[@0,@(INFINITY)]}}}]) {
  count++;if(![TiSynthengineContract validateTone:o maxFrequency:20000])failures++;
 }
 printf("iOS variation contracts: %d cases, %d failures\n",count,failures);return failures?1:0;
 }
}
