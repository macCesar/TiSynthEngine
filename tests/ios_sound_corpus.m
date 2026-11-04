int main(int argc,char **argv) { @autoreleasepool {
 assert(argc==2);RenderRig *r=rig(44100);
 NSString *text=[NSString stringWithContentsOfFile:[NSString stringWithUTF8String:argv[1]] encoding:NSUTF8StringEncoding error:nil];
 assert(text);int line=0,failures=0;
 for(NSString *raw in [text componentsSeparatedByString:@"\n"]) {
  if(!raw.length)continue;line++;
  NSDictionary *request=[NSJSONSerialization JSONObjectWithData:[raw dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];assert(request);
  NSDictionary *error=[r _validateSoundOptions:request];
  BOOL expected=![request[@"expected"] isEqual:@"rejected"];
  if((error==nil)!=expected){fprintf(stderr,"line %d %s: %s\n",line,[request[@"kind"] UTF8String],[[error description] UTF8String]);failures++;}
 }
 destroyRig(r);printf("Apple compiled Sound requests: %d cases, %d failures\n",line,failures);return failures?1:0;
}}
