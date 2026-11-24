#import <Foundation/Foundation.h>

// Objective-C
@interface Greeter : NSObject
- (void)greet:(NSString *)name;
@end

@implementation Greeter
- (void)greet:(NSString *)name {
    NSLog(@"Hej %@", name);
}
@end
