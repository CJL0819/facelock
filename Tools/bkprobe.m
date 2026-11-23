#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <stdio.h>

static NSMutableString *sLog;
static void Put(NSString *line) {
    if (sLog == nil) {
        sLog = [NSMutableString string];
    }
    [sLog appendFormat:@"%@\n", line];
    fprintf(stderr, "%s\n", line.UTF8String);
    fflush(stderr);
    [[sLog dataUsingEncoding:NSUTF8StringEncoding] writeToFile:@"/var/mobile/bkprobe.txt" atomically:YES];
}

static void DumpMethods(Class cls) {
    if (cls == Nil) {
        Put(@"  (missing)");
        return;
    }
    unsigned int count = 0;
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned int index = 0; index < count; index++) {
        Put([NSString stringWithFormat:@"  - %s   %s",
             sel_getName(method_getName(methods[index])),
             method_getTypeEncoding(methods[index])]);
    }
    free(methods);
}

int main(void) {
    @autoreleasepool {
        if (dlopen("/System/Library/PrivateFrameworks/BiometricKit.framework/BiometricKit",
                   RTLD_NOW) == NULL) {
            Put(@"BiometricKit did not load");
            return 0;
        }
        Put(@"== BKMatchResultInfo");
        DumpMethods(objc_getClass("BKMatchResultInfo"));
        Put(@"== BKMatchEvent");
        DumpMethods(objc_getClass("BKMatchEvent"));
        Put(@"== classes with Match");
        {
            int count = objc_getClassList(NULL, 0);
            Class *classes = (Class *)malloc(sizeof(Class) * (size_t)count);
            count = objc_getClassList(classes, count);
            for (int index = 0; index < count; index++) {
                const char *name = class_getName(classes[index]);
                if (strcasestr(name, "match") != NULL) {
                    Put([NSString stringWithFormat:@"  %s", name]);
                }
            }
            free(classes);
        }
        Put(@"== BKIdentity");
        DumpMethods(objc_getClass("BKIdentity"));
        Put(@"== BKMatchPearlResult");
        DumpMethods(objc_getClass("BKMatchPearlResult"));
    }
    return 0;
}
