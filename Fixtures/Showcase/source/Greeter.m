#import <Foundation/Foundation.h>

// Logs a greeting with a fixed number.
@interface Greeter : NSObject
- (void)greet:(NSString *)name;
@end

@implementation Greeter
- (void)greet:(NSString *)name {
    NSLog(@"Hej %@, nummer %d", name, 42);
}
@end
