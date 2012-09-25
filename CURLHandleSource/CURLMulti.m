//
//  CURLMulti.m
//
//  Created by Sam Deane on 20/09/2012.
//  Copyright (c) 2012 Karelia Software. All rights reserved.
//

#import "CURLMulti.h"

#import "CURLHandle.h"

@interface CURLMulti()

@property (strong, nonatomic) NSMutableArray* handles;
@property (assign, nonatomic) CURLM* multi;
@property (strong, nonatomic) NSOperationQueue* queue;
@property (strong, nonatomic) NSThread* thread;
@property (assign, nonatomic) struct timeval timeout;

@end

#pragma mark - Callbacks

static int timeout_changed(CURLM *multi, long timeout_ms, void *userp);

int timeout_changed(CURLM *multi, long timeout_ms, void *userp)
{
    CURLMulti* source = userp;

    struct timeval timeout;
    timeout.tv_sec = timeout_ms / 1000;
    timeout.tv_usec = (timeout_ms % 1000) * 1000;
    source.timeout = timeout;

    CURLHandleLog(@"timeout changed to %ldms", timeout_ms);

    return CURLM_OK;
}

@implementation CURLMulti

@synthesize handles = _handles;
@synthesize multi = _multi;
@synthesize thread = _thread;
@synthesize timeout = _timeout;

- (id)init
{
    if ((self = [super init]) != nil)
    {
        self.multi = curl_multi_init(); // TODO: check for failure here?
        curl_multi_setopt(self.multi, CURLMOPT_TIMERFUNCTION, timeout_changed);
        curl_multi_setopt(self.multi, CURLMOPT_TIMERDATA, self);

        self.handles = [NSMutableArray array];
        NSOperationQueue* queue = [[NSOperationQueue alloc] init];
        queue.maxConcurrentOperationCount = 1;
        self.queue = queue;
        [queue release];
        struct timeval timeout;
        timeout.tv_sec = 0;
        timeout.tv_usec = 1000;
        self.timeout = timeout;
    }

    return self;
}

- (void)dealloc
{
    [self shutdown];

    [_handles release];
    [_thread release];

    [super dealloc];
}

- (void)startup

{
    [self createThread];
}

- (BOOL)addHandle:(CURLHandle*)handle error:(NSError**)error
{
    [self.queue addOperationWithBlock:^{
        [self.handles addObject:handle];
        CURLMcode result = curl_multi_add_handle(self.multi, [handle curl]);
        (void)result; // TODO: handle result
    }];

    return YES;
}

- (BOOL)removeHandle:(CURLHandle*)handle error:(NSError**)error
{
    [self.queue addOperationWithBlock:^{
        CURLMcode result = curl_multi_remove_handle(self.multi, [handle curl]);
        (void)result; // TODO: handle result
        [self.handles removeObject:handle];
    }];

    return YES;
}

- (CURLHandle*)handleWithEasyHandle:(CURL*)easy
{
    CURLHandle* result = nil;
    for (CURLHandle* handle in self.handles)
    {
        if ([handle curl] == easy)
        {
            result = handle;
            break;
        }
    }

    return result;
}

- (void)removeAllHandles
{
    [self.queue addOperationWithBlock:^{
        for (CURLHandle* handle in self.handles)
        {
            curl_multi_remove_handle(self.multi, [handle curl]);
        }

        [self.handles removeAllObjects];
    }];
}

- (void)shutdown
{
    if (self.multi)
    {
        [self removeAllHandles];
        [self releaseThread];
        [self.queue waitUntilAllOperationsAreFinished];

        curl_multi_cleanup(self.multi);
        self.multi = nil;
        CURLHandleLog(@"shutdown");
    }
}

- (BOOL)createThread // TODO: turn this into getter
{
    if (!self.thread)
    {
        NSThread* thread = [[NSThread alloc] initWithTarget:self selector:@selector(monitor) object:nil];
        self.thread = thread;
        [thread start];
        [thread release];
        CURLHandleLog(thread ? @"created thread" : @"failed to create thread");
    }

    return (self.thread != nil);
}

- (void)releaseThread
{
    if (self.thread)
    {
        [self.thread cancel];
        while (![self.thread isFinished])
        {
            // TODO: spin runloop here?
        }

        self.thread = nil;
        CURLHandleLog(@"released thread");
    }
}

- (void)monitor
{
    CURLHandleLog(@"started monitor thread");


    static int MAX_FDS = 128;
    __block fd_set read_fds;
    __block fd_set write_fds;
    __block fd_set exc_fds;
    __block int count = MAX_FDS;
    __block CURLMcode result;

    while (![self.thread isCancelled])
    {
        [self.queue addOperationWithBlock:^{
            FD_ZERO(&read_fds);
            FD_ZERO(&write_fds);
            FD_ZERO(&exc_fds);
            count = FD_SETSIZE;
            result = curl_multi_fdset(self.multi, &read_fds, &write_fds, &exc_fds, &count);
        }];

        [self.queue waitUntilAllOperationsAreFinished];

        if (result == CURLM_OK)
        {
            struct timeval timeout = self.timeout;
            count = select(count + 1, &read_fds, &write_fds, &exc_fds, &timeout);
            [self.queue addOperationWithBlock:^{
                curl_multi_perform(self.multi, &count);

                CURLMsg* message;
                while ((message = curl_multi_info_read(self.multi, &count)) != nil)
                {
                    CURLHandleLog(@"got multi message %d", message->msg);
                    if (message->msg == CURLMSG_DONE)
                    {
                        CURLHandle* handle = [self handleWithEasyHandle:message->easy_handle];
                        if (handle)
                        {
                            [handle completeWithMulti:self];
                        }
                        else
                        {
                            // this really shouldn't happen - there should always be a matching CURLHandle - but just in case...
                            CURLHandleLog(@"seem to have an easy handle without a matching CURLHandle");
                            curl_multi_remove_handle(self.multi, message->easy_handle);
                        }
                    }
                }
            }];

        }
    }

    CURLHandleLog(@"finished monitor thread");
}


@end
