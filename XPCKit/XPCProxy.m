//
//  XPCProxy.m
//  XPCKit
//
//  Created by Brian King on 2/25/12.
//

#import "XPCProxy.h"
#import "XPCConnection.h"

#pragma mark - Helper Object Categories.


@implementation NSNumber(XPCProxy)


+ (NSNumber *)numberFromBuffer:(void *)buffer ofType:(const char *)objCType
{
 
    if (!strcmp(objCType, @encode(BOOL)))  
        return [NSNumber numberWithBool:*((BOOL*)buffer)];
    else if (!strcmp(objCType, @encode(NSInteger))) 
        return [NSNumber numberWithInteger:*((NSInteger*)buffer)];
    else
        NSLog(@"Ignoring Unknown Return Type");
    return nil;
}

- (void)castType:(const char *)objcType intoBuffer:(void *)buffer
{
    if (!strcmp(objcType, @encode(int)))
        *((int *)buffer) = [self intValue];

    else if (!strcmp(objcType, @encode(uint)))
        *((uint *)buffer) = [self unsignedIntValue];

    else if (!strcmp(objcType, @encode(double)))
        *((double *)buffer) = [self doubleValue];        

    else
        NSAssert(FALSE, @"Do not know how to decode type");
}

- (void)castIntoBuffer:(void *)buffer
{
    // Not sure if I can count on the type of the NSNumber, or if I should
    // get it from the method info
    [self castType:[self objCType] intoBuffer:buffer];
}

@end

@implementation NSInvocation(XPCProxy)

- (NSDictionary *)dictionaryRepresentation
{
    NSUInteger argumentCount = [self methodSignature].numberOfArguments;
    NSMutableArray *arguments = [NSMutableArray array];
    char invocationBuffer[300];
    NSAssert(argumentCount - 2 < 28, @"Can not handle over 28 arguments - increase invocationBuffer");


    for (NSInteger index = 2; index < argumentCount; index++)
    {
        const char *objCType = [[self methodSignature] getArgumentTypeAtIndex:index];
        BOOL isObject = !strcmp(objCType, @encode(id));
        
        id argument = nil;
        if (isObject)
            [self getArgument:&argument atIndex:index];
        else 
        {
            void *buffer = &(invocationBuffer[index*10]);
            [self getArgument:buffer atIndex:index];            
            argument = [NSNumber numberFromBuffer:buffer ofType:objCType];
        }
        if (argument == nil)
            argument = [NSNull null];
        
        [arguments addObject:argument];
    }

    return [NSDictionary dictionaryWithObjectsAndKeys:
            NSStringFromSelector([self selector]), @"selector",
            arguments, @"arguments",
            nil];
}

@end

#pragma mark - XPCProxy 

@interface XPCProxy()

@property (nonatomic, assign) Class proxyClass;
@property (nonatomic, retain) XPCConnection *connection;
@property (nonatomic, retain) NSMutableDictionary *definition;

+ (NSObject *)proxyObjectNamed:(NSString *)name;

@end


@implementation XPCProxy

- (id)initForClass:(Class)proxyClass onConnection:(XPCConnection *)connection;
{
    self = [super init];
    if (self) {
        self.proxyClass = proxyClass;
        self.connection = connection;
        self.definition = [NSMutableDictionary dictionary];
        
        [self.definition setObject:@"XPCProxy" forKey:@"operation"];
    }
    return self;
}
- (void)dealloc
{
    [_connection release];
    [_definition release];
    [super dealloc];
}

@synthesize definition = _definition;
@synthesize connection = _connection;
@synthesize proxyClass = _proxyClass;

#pragma mark - Global Proxy Lookup
static NSMutableDictionary *__XPCRegisteredProxies = nil;
+ (void)registerProxy:(NSObject *)object named:(NSString *)named
{
    if (__XPCRegisteredProxies == nil)
        __XPCRegisteredProxies = [[NSMutableDictionary alloc] init];
    
    [__XPCRegisteredProxies setValue:object forKey:named];
}

+ (NSObject *)proxyObjectNamed:(NSString *)name
{
    return  [__XPCRegisteredProxies objectForKey:name];
}


+ (id)proxyClass:(NSString *)className named:(NSString *)name onConnection:(XPCConnection *)connection
{
    XPCProxy *proxy = [[[XPCProxy alloc] initForClass:NSClassFromString(className) 
                                         onConnection:connection] autorelease];
    [proxy.definition setObject:name forKey:@"lookupByName"];
    
    return proxy;
}

+ (id)proxyClass:(NSString *)className selector:(SEL)method onConnection:(XPCConnection *)connection
{
    XPCProxy *proxy = [[[XPCProxy alloc] initForClass:NSClassFromString(className)
                                         onConnection:connection] autorelease];

    NSArray *keypath = [NSArray arrayWithObjects:className, NSStringFromSelector(method), nil];

    [proxy.definition setObject:keypath forKey:@"lookupByKeypath"];
    
    return proxy;
}

#pragma mark - NSInvocation to NSDictionary

- (void)forwardInvocation:(NSInvocation *)invocation 
{
    [self.definition setObject:[invocation dictionaryRepresentation] forKey:@"invocation"];
    [self.connection sendMessage:self.definition];
}

- (NSMethodSignature *) methodSignatureForSelector:(SEL)selector {
    return [self.proxyClass instanceMethodSignatureForSelector:selector];
}


#pragma mark - NSDictionary to NSInvocation
+ (NSObject *)lookupProxyFromDictionary:(NSDictionary *)proxy
{
    NSString *byName = [proxy objectForKey:@"lookupByName"];
    NSArray *byKeypath = [proxy objectForKey:@"lookupByKeypath"];
    NSAssert(byName != nil || byKeypath != nil, @"Must specify a lookup key");
    
    if (byName)
        return [self proxyObjectNamed:byName];

    else if (byKeypath)
    {
        NSUInteger count  = [byKeypath count];
        NSString *class   = [byKeypath objectAtIndex:0];
        NSString *keypath = [[byKeypath subarrayWithRange:NSMakeRange(1, count - 1)] componentsJoinedByString:@"."];
        return [NSClassFromString(class) valueForKeyPath:keypath];
    }
    return nil;
}


+ (id)invokeProxyDictionary:(NSDictionary *)proxy
{
    NSObject *target   = [self lookupProxyFromDictionary:proxy];
    SEL selector       = NSSelectorFromString([proxy valueForKeyPath:@"invocation.selector"]);
    NSArray *arguments = [proxy valueForKeyPath:@"invocation.arguments"];

    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    char invocationBuffer[300];
    
    NSAssert(signature.numberOfArguments - 2 < 28, 
             @"Can not handle over 28 arguments - increase invocationBuffer");
    NSAssert(signature.numberOfArguments - 2 == [arguments count], 
             @"Wrong Argument Mapping (%d, %d)", signature.numberOfArguments - 2, [arguments count]);
    
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setSelector:selector];

    //
    // Create the argument list.  Indices 0 and 1 indicate the hidden arguments self and _cmd.
    // Unbox primitive arguments represented by NSNumber, otherwise fail.
    //
    const char *objCType;
    NSInteger index = 2; //
    for( id arg in arguments ) {
        objCType = [signature getArgumentTypeAtIndex:index];
        BOOL isObject = !strcmp(objCType, @encode(id));
        
        if (isObject == NO && [arg isKindOfClass:[NSNumber class]])
        {
            void *buffer = &(invocationBuffer[index*10]);
            [(NSNumber *)arg castType:objCType intoBuffer:buffer];
            [invocation setArgument:buffer atIndex:index];            
        }
        else if (isObject)
            [invocation setArgument:&arg atIndex:index];
        
        else 
            NSLog(@"Ignoring Unknown Argument Type");

        index++;
    }
    
    [invocation invokeWithTarget:target];
    
    //
    // Create the return object - pass (id) and box a few primitive types
    //
    objCType = signature.methodReturnType;
    BOOL isVoid = !strcmp(objCType, @encode(void));
    
    id returnValue = nil;
    if (!strcmp(objCType, @encode(id)))
        [invocation getReturnValue:&returnValue];
    
    else if (isVoid == NO)
    {
        NSUInteger length = [signature methodReturnLength];
        void *buffer = (void *)malloc(length);
        [invocation getReturnValue:buffer];
        
        returnValue = [NSNumber numberFromBuffer:buffer ofType:objCType];

        free(buffer);
    }
    return returnValue;     
}


+ (void)handleInvocationOfProxyMessage:(NSDictionary *)proxy fromConnection:(XPCConnection *)connection
{
    NSLog(@"Handle %@", proxy);
    if ([[proxy objectForKey:@"operation"] isEqualToString:@"XPCProxy"] == NO)
        return;
    
    id result = [self invokeProxyDictionary:proxy];
    
    [connection sendMessage:result];
}



@end
