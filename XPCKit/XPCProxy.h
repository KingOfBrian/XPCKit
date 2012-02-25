//
//  XPCProxy.h
//  XPCKit
//
//  Created by Brian King on 2/25/12.
//

#import <Foundation/Foundation.h>
#import "XPCConnection.h"



@interface XPCProxy : NSObject
{
    Class _proxyClass;
    XPCConnection *_connection;
    NSMutableDictionary *_definition;
}
/*
 * Name an object in the service to expose objects to those connecting.
 */
+ (void)registerProxy:(NSObject *)object named:(NSString *)named;

/*
 * Return a proxy for the class represented by Class with the selector method.  IE:
 *
 * p = [XPCProxy proxyClass:@"ClassName"
 *                 selector:@selector(singletonSelector) 
 *             onConnection:_connection];
 *
 * BOOL b = [p methodWithDate:date integer:i andArray:a];
 *
 * This will serialize the NSInvocation into dictionaries, and send the dictionary over the connection.
 *  On the service, it will deserialize into an NSInvocation, call [ClassName singletonSelector], and then
 *  invoke the invocation on the result.
 *
 */
+ (id)proxyClass:(NSString *)className selector:(SEL)method onConnection:(XPCConnection *)connection;


/*
 * Same as above but with named lookup
 */
+ (id)proxyClass:(NSString *)className named:(NSString *)name onConnection:(XPCConnection *)connection;



// Call this method in the event handler of the service
+ (void)handleInvocationOfProxyMessage:(NSDictionary *)proxy fromConnection:(XPCConnection *)connection;

@end
