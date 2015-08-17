#import "BTAnalyticsMetadata.h"
#import "BTAPIClient_Internal.h"
#import "BTLogger_Internal.h"

NSString *const BTAPIClientErrorDomain = @"com.braintreepayments.BTAPIClientErrorDomain";

@interface BTAPIClient ()
@property (nonatomic, strong) dispatch_queue_t configurationQueue;
@property (nonatomic, strong) BTJSON *cachedRemoteConfiguration;
@end

@implementation BTAPIClient

- (instancetype)initWithClientKey:(NSString *)clientKey {
    return [self initWithClientKey:clientKey error:NULL];
}

- (instancetype)initWithClientKey:(NSString *)clientKey error:(NSError **)error {
    return [self initWithClientKey:clientKey dispatchQueue:nil error:error];
}

- (instancetype)initWithClientKey:(NSString *)clientKey dispatchQueue:(dispatch_queue_t)dispatchQueue error:(NSError **)error {
    NSURL *baseURL = [self baseURLFromClientKey:clientKey error:error];
    if (!baseURL) {
        return nil;
    }

    self = [super init];
    if (self) {
        _clientKey = clientKey;
        _metadata = [[BTClientMetadata alloc] init];
        _http = [[BTHTTP alloc] initWithBaseURL:baseURL clientKey:clientKey];

        if (dispatchQueue) {
            _http.dispatchQueue = dispatchQueue;
        }
        _configurationQueue = dispatch_queue_create("com.braintreepayments.BTAPIClient", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (instancetype)copyWithSource:(BTClientMetadataSourceType)source
                   integration:(BTClientMetadataIntegrationType)integration
{
    BTAPIClient *copiedClient = [[[self class] alloc] initWithClientKey:self.clientKey dispatchQueue:self.dispatchQueue error:NULL];
    copiedClient.clientJWT = self.clientJWT;

    BTMutableClientMetadata *mutableMetadata = [self.metadata mutableCopy];
    mutableMetadata.source = source;
    mutableMetadata.integration = integration;
    copiedClient->_metadata = [mutableMetadata copy];

    return copiedClient;
}

#pragma mark - Accessors

- (dispatch_queue_t)dispatchQueue {
    return self.http.dispatchQueue ?: dispatch_get_main_queue();
}

#pragma mark - Base URL

- (NSURL *)baseURLFromClientKey:(NSString *)clientKey error:(NSError **)error {
    NSRegularExpression *regExp = [NSRegularExpression regularExpressionWithPattern:@"([a-zA-Z0-9]+)_[a-zA-Z0-9]+_([a-zA-Z0-9_]+)" options:0 error:NULL];

    NSArray *results = [regExp matchesInString:clientKey options:0 range:NSMakeRange(0, clientKey.length)];

    if (results.count != 1 || [[results firstObject] numberOfRanges] != 3) {
        if (error) {
            *error = [NSError errorWithDomain:BTAPIClientErrorDomain
                                         code:BTAPIClientErrorTypeInvalidClientKey
                                     userInfo:nil];
        }
        return nil;
    }

    NSString *environment = [clientKey substringWithRange:[results[0] rangeAtIndex:1]];
    NSString *merchantID = [clientKey substringWithRange:[results[0] rangeAtIndex:2]];

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = [self schemeForEnvironmentString:environment];
    NSString *host = [self hostForEnvironmentString:environment];
    NSArray *hostComponents = [host componentsSeparatedByString:@":"];
    components.host = hostComponents[0];
    if (hostComponents.count > 1) {
        components.port = hostComponents[1];
    }
    components.path = [self clientApiBasePathForMerchantID:merchantID];
    if (!components.host || !components.path) {
        if (error) {
            *error = [NSError errorWithDomain:BTAPIClientErrorDomain
                                         code:BTAPIClientErrorTypeInvalidClientKey
                                     userInfo:nil];
        }
        return nil;
    }

    return components.URL;
}

- (NSString *)schemeForEnvironmentString:(NSString *)environment {
    if ([[environment lowercaseString] isEqualToString:@"development"]) {
        return @"http";
    }
    return @"https";
}

- (NSString *)hostForEnvironmentString:(NSString *)environment {
    if ([[environment lowercaseString] isEqualToString:@"sandbox"]) {
        return @"sandbox.braintreegateway.com";
    } else if ([[environment lowercaseString] isEqualToString:@"production"]) {
        return @"braintreegateway.com";
    } else if ([[environment lowercaseString] isEqualToString:@"development"]) {
        return @"localhost:3000";
    } else {
        return nil;
    }
}

- (NSString *)clientApiBasePathForMerchantID:(NSString *)merchantID {
    if (merchantID.length == 0) {
        return nil;
    }

    return [NSString stringWithFormat:@"/merchants/%@/client_api", merchantID];
}

#pragma mark - Remote Configuration

- (void)fetchOrReturnRemoteConfiguration:(void (^)(BTConfiguration *, NSError *))completionBlock {
    // Guarantee that multiple calls to this method will successfully obtain configuration exactly once.
    //
    // Rules:
    //   - If cachedConfiguration is present, return it without a request
    //   - If cachedConfiguration is not present, fetch it and cache the succesful response
    //     - If fetching fails, return error and the next queued will try to fetch again
    //
    // Note: Configuration queue is SERIAL. This helps ensure that each request for configuration
    //       is processed independently. Thus, the check for cached configuration and the fetch is an
    //       atomic operation with respect to other calls to this method.
    //
    // Note: Uses dispatch_semaphore to block the configuration queue when the configuration fetch
    //       request is waiting to return. In this context, it is OK to block, as the configuration
    //       queue is a background queue to guarantee atomic access to the remote configuration resource.
    dispatch_async(self.configurationQueue, ^{
        __block NSError *fetchError;

        if (self.cachedRemoteConfiguration == nil) {
            dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
            [self.http GET:@"v1/configuration" completion:^(BTJSON *body, NSHTTPURLResponse *response, NSError *error) {
                if (error) {
                    fetchError = error;
                } else if (response.statusCode != 200) {
                    NSError *configurationDomainError =
                    [NSError errorWithDomain:BTAPIClientErrorDomain
                                        code:BTAPIClientErrorTypeConfigurationUnavailable
                                    userInfo:@{
                                               NSLocalizedFailureReasonErrorKey: @"Unable to fetch remote configuration from Braintree API at this time."
                                               }];
                    fetchError = configurationDomainError;
                } else {
                    self.cachedRemoteConfiguration = body;
                }

                // Important: Unlock semaphore in all cases
                dispatch_semaphore_signal(semaphore);
            }];

            dispatch_semaphore_wait(semaphore, DISPATCH_TIME_FOREVER);
        }

        dispatch_async(self.dispatchQueue, ^{
            BTConfiguration *configuration;
            if (self.cachedRemoteConfiguration) {
                configuration = [[BTConfiguration alloc] initWithJSON:self.cachedRemoteConfiguration];
            }
            completionBlock(configuration, fetchError);
        });
    });
}

#pragma mark - Analytics

- (void)postAnalyticsEvent:(NSString *)eventKind {
    [self postAnalyticsEvent:eventKind completion:nil];
}

- (void)postAnalyticsEvent:(NSString *)eventKind completion:(void(^)(NSError *error))completionBlock {
    [self fetchOrReturnRemoteConfiguration:^(BTConfiguration *configuration, NSError *error){
        if (error) {
            [[BTLogger sharedLogger] warning:[NSString stringWithFormat:@"Failed to send analytics event. Remote configuration fetch failed. %@", error.localizedDescription]];
            if (completionBlock) completionBlock(error);
            return;
        }

        NSURL *analyticsURL = configuration.json[@"analytics"][@"url"].asURL;
        if (analyticsURL) {
            if (!self.analyticsHttp) {
                self.analyticsHttp = [[BTHTTP alloc] initWithBaseURL:analyticsURL clientKey:self.clientKey];
            }
            // A special value passed in by unit tests to prevent BTHTTP from actually posting
            if ([self.analyticsHttp.baseURL isEqual:[NSURL URLWithString:@"test://do-not-send.url"]]) {
                if (completionBlock) completionBlock(nil);
                return;
            }

            [self.analyticsHttp POST:@"/"
                          parameters:@{ @"analytics": @[@{ @"kind": eventKind }],
                                        @"authorization_fingerprint": self.clientKey,
                                        @"_meta": self.metaParameters }
                          completion:^(__unused BTJSON *body, __unused NSHTTPURLResponse *response, NSError *error) {
                              if (completionBlock) completionBlock(error);
                          }];
        } else {
            [[BTLogger sharedLogger] debug:@"Skipping sending analytics event - analytics is disabled in remote configuration"];
            if (completionBlock) completionBlock(nil);
        }
    }];
}

- (NSDictionary *)metaParameters {
    BTClientMetadata *clientMetadata = self.metadata;
    NSMutableDictionary *clientMetadataParameters = [NSMutableDictionary dictionary];
    clientMetadataParameters[@"integration"] = clientMetadata.integrationString;
    clientMetadataParameters[@"source"] = clientMetadata.sourceString;
    clientMetadataParameters[@"sessionId"] = clientMetadata.sessionId;

    NSDictionary *analyticsMetadata = [BTAnalyticsMetadata metadata];

    NSMutableDictionary *metaParameters = [NSMutableDictionary dictionary];
    [metaParameters addEntriesFromDictionary:analyticsMetadata];
    [metaParameters addEntriesFromDictionary:clientMetadataParameters];

    return [metaParameters copy];
}

#pragma mark - HTTP Operations

- (void)GET:(NSString *)endpoint parameters:(NSDictionary *)parameters completion:(void(^)(BTJSON *body, NSHTTPURLResponse *response, NSError *error))completionBlock {
    [self.http GET:endpoint parameters:parameters completion:completionBlock];
}

- (void)POST:(NSString *)endpoint parameters:(NSDictionary *)parameters completion:(void(^)(BTJSON *body, NSHTTPURLResponse *response, NSError *error))completionBlock {
    NSMutableDictionary *mutableParameters = [NSMutableDictionary dictionary];
    mutableParameters[@"_meta"] = [self metaParameters];
    [mutableParameters addEntriesFromDictionary:parameters];
    [self.http POST:endpoint parameters:mutableParameters completion:completionBlock];

}

@end
