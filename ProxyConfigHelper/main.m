//
//  main.m
//  ProxyConfigHelper
//

#import <Foundation/Foundation.h>
#import "ProxyConfigHelper.h"
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        [[NSProcessInfo processInfo] disableSuddenTermination];
        [[ProxyConfigHelper new] run];
        NSLog(@"ProxyConfigHelper exit");
    }
    return 0;
}
