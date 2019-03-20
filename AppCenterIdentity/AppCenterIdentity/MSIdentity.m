// Copyright (c) Microsoft Corporation. All rights reserved.
// Licensed under the MIT License.

#import "MSAppCenterInternal.h"
#import "MSAppDelegateForwarder.h"
#import "MSAuthTokenContext.h"
#import "MSChannelUnitConfiguration.h"
#import "MSConstants+Internal.h"
#import "MSIdentityAppDelegate.h"
#import "MSIdentityConfig.h"
#import "MSIdentityConfigIngestion.h"
#import "MSIdentityConstants.h"
#import "MSIdentityPrivate.h"
#import "MSKeychainAuthTokenStorage.h"
#import "MSServiceAbstractProtected.h"
#import "MSUtility+File.h"

// Service name for initialization.
static NSString *const kMSServiceName = @"Identity";

// The group Id for storage.
static NSString *const kMSGroupId = @"Identity";

// Singleton
static MSIdentity *sharedInstance = nil;
static dispatch_once_t onceToken;

@implementation MSIdentity

@synthesize channelUnitConfiguration = _channelUnitConfiguration;

#pragma mark - Service initialization

- (instancetype)init {
  if ((self = [super init])) {
    _channelUnitConfiguration = [[MSChannelUnitConfiguration alloc] initDefaultConfigurationWithGroupId:[self groupId]];
    _appDelegate = [MSIdentityAppDelegate new];
    _configUrl = kMSIdentityDefaultBaseURL;
    [MSUtility createDirectoryForPathComponent:kMSIdentityPathComponent];
  }
  return self;
}

#pragma mark - MSServiceInternal

+ (instancetype)sharedInstance {
  dispatch_once(&onceToken, ^{
    if (sharedInstance == nil) {
      sharedInstance = [[MSIdentity alloc] init];
    }
  });
  return sharedInstance;
}

+ (NSString *)serviceName {
  return kMSServiceName;
}

- (void)startWithChannelGroup:(id<MSChannelGroupProtocol>)channelGroup
                    appSecret:(nullable NSString *)appSecret
      transmissionTargetToken:(nullable NSString *)token
              fromApplication:(BOOL)fromApplication {
  [super startWithChannelGroup:channelGroup appSecret:appSecret transmissionTargetToken:token fromApplication:fromApplication];
  [[MSAuthTokenContext sharedInstance] setStorage:[MSKeychainAuthTokenStorage new]];
  MSLogVerbose([MSIdentity logTag], @"Started Identity service.");
}

+ (NSString *)logTag {
  return @"AppCenterIdentity";
}

- (NSString *)groupId {
  return kMSGroupId;
}

#pragma mark - MSServiceAbstract

- (void)setEnabled:(BOOL)isEnabled {
  [super setEnabled:isEnabled];
}

- (void)applyEnabledState:(BOOL)isEnabled {
  [super applyEnabledState:isEnabled];
  if (isEnabled) {
    [[MSAppDelegateForwarder sharedInstance] addDelegate:self.appDelegate];

    // Read Identity config file.
    NSString *eTag = nil;
    if ([self loadConfigurationFromCache]) {
      [self configAuthenticationClient];
      eTag = [MS_USER_DEFAULTS objectForKey:kMSIdentityETagKey];
    }
    [[MSAuthTokenContext sharedInstance] cacheAuthToken];

    // Download identity configuration.
    [self downloadConfigurationWithETag:eTag];
    MSLogInfo([MSIdentity logTag], @"Identity service has been enabled.");
  } else {
    [[MSAppDelegateForwarder sharedInstance] removeDelegate:self.appDelegate];
    [self clearAuthData];
    self.clientApplication = nil;
    [self clearConfigurationCache];
    self.ingestion = nil;
    NSError *error = [[NSError alloc] initWithDomain:MSIdentityErrorDomain
                                                code:MSIdentityErrorServiceDisabled
                                            userInfo:@{MSIdentityErrorDescriptionKey : @"Identity is disabled."}];
    [self completeAcquireTokenRequestForResult:nil withError:error];
    MSLogInfo([MSIdentity logTag], @"Identity service has been disabled.");
  }
}

#pragma mark - Service methods

+ (void)resetSharedInstance {

  // Resets the once_token so dispatch_once will run again.
  onceToken = 0;
  sharedInstance = nil;
}

+ (BOOL)openURL:(NSURL *)url {
  return [MSALPublicClientApplication handleMSALResponse:url];
}

+ (void)signInWithCompletionHandler:(MSSignInCompletionHandler _Nullable)completionHandler {

  // We allow completion handler to be optional but we need a non nil one to track operation progress internally.
  if (!completionHandler) {
    completionHandler = ^(MSUserInformation *_Nullable __unused userInformation, NSError *_Nullable __unused error) {
    };
  }
  @synchronized([MSIdentity sharedInstance]) {
    if ([[MSIdentity sharedInstance] canBeUsed] && [[MSIdentity sharedInstance] isEnabled]) {
      if ([MSIdentity sharedInstance].signInCompletionHandler) {
        MSLogError([MSIdentity logTag], @"signIn already in progress.");
        NSError *error = [[NSError alloc] initWithDomain:MSIdentityErrorDomain
                                                    code:MSIdentityErrorPreviousSignInRequestInProgress
                                                userInfo:@{MSIdentityErrorDescriptionKey : @"signIn already in progress."}];
        completionHandler(nil, error);
        return;
      }
      [MSIdentity sharedInstance].signInCompletionHandler = completionHandler;
      [[MSIdentity sharedInstance] signIn];
    } else {
      NSError *error = [[NSError alloc] initWithDomain:MSIdentityErrorDomain
                                                  code:MSIdentityErrorServiceDisabled
                                              userInfo:@{MSIdentityErrorDescriptionKey : @"Identity is disabled."}];
      completionHandler(nil, error);
    }
  }
}

+ (void)signOut {
  [[MSIdentity sharedInstance] signOut];
}

- (void)signIn {
  if ([[MS_Reachability reachabilityForInternetConnection] currentReachabilityStatus] == NotReachable) {
    [self completeSignInWithErrorCode:MSIdentityErrorSignInWhenNoConnection
                           andMessage:@"User sign-in failed. Internet connection is down."];
    return;
  }
  if (self.clientApplication == nil || self.identityConfig == nil) {
    [self completeSignInWithErrorCode:MSIdentityErrorSignInBackgroundOrNotConfigured
                           andMessage:@"signIn is called while it's not configured or not in the foreground."];
    return;
  }
  NSString *accountId = [[MSAuthTokenContext sharedInstance] accountId];
  MSALAccount *account = [self retrieveAccountWithAccountId:accountId];
  if (account) {
    [self acquireTokenSilentlyWithMSALAccount:account];
  } else {
    [self acquireTokenInteractively];
  }
}

+ (void)setConfigUrl:(NSString *)configUrl {
  [MSIdentity sharedInstance].configUrl = configUrl;
}

- (void)completeSignInWithErrorCode:(NSInteger)errorCode andMessage:(NSString *)errorMessage {
  if (!self.signInCompletionHandler) {
    return;
  }
  NSError *error = [[NSError alloc] initWithDomain:MSIdentityErrorDomain
                                              code:errorCode
                                          userInfo:@{MSIdentityErrorDescriptionKey : errorMessage}];
  self.signInCompletionHandler(nil, error);
}

- (void)signOut {
  @synchronized(self) {
    if (![self canBeUsed]) {
      return;
    }
    if ([self clearAuthData]) {
      MSLogInfo([MSIdentity logTag], @"User sign-out succeeded.");
    }
  }
}

#pragma mark - Private methods

- (NSString *)identityConfigFilePath {
  return [NSString stringWithFormat:@"%@/%@", kMSIdentityPathComponent, kMSIdentityConfigFilename];
}

- (BOOL)loadConfigurationFromCache {
  NSData *configData = [MSUtility loadDataForPathComponent:[self identityConfigFilePath]];
  if (configData == nil) {
    MSLogWarning([MSIdentity logTag], @"Identity config file doesn't exist.");
  } else {
    MSIdentityConfig *config = [self deserializeData:configData];
    if ([config isValid]) {
      self.identityConfig = config;
      return YES;
    }
    [self clearConfigurationCache];
    self.identityConfig = nil;
    MSLogError([MSIdentity logTag], @"Identity config file is not valid.");
  }
  return NO;
}

- (MSIdentityConfigIngestion *)ingestion {
  if (!_ingestion) {
    _ingestion = [[MSIdentityConfigIngestion alloc] initWithBaseUrl:self.configUrl appSecret:self.appSecret];
  }
  return _ingestion;
}

- (void)downloadConfigurationWithETag:(nullable NSString *)eTag {

  // Download configuration.
  [self.ingestion sendAsync:nil
                       eTag:eTag
          completionHandler:^(__unused NSString *callId, NSHTTPURLResponse *response, NSData *data, __unused NSError *error) {
            MSIdentityConfig *config = nil;
            if (response.statusCode == MSHTTPCodesNo304NotModified) {
              MSLogInfo([MSIdentity logTag], @"Identity configuration hasn't changed.");
            } else if (response.statusCode == MSHTTPCodesNo200OK) {
              config = [self deserializeData:data];
              if ([config isValid]) {
                NSURL *configUrl = [MSUtility createFileAtPathComponent:[self identityConfigFilePath]
                                                               withData:data
                                                             atomically:YES
                                                         forceOverwrite:YES];

                // Store eTag only when the configuration file is created successfully.
                if (configUrl) {
                  NSString *newETag = [MSHttpIngestion eTagFromResponse:response];
                  if (newETag) {
                    [MS_USER_DEFAULTS setObject:newETag forKey:kMSIdentityETagKey];
                  }
                } else {
                  MSLogWarning([MSIdentity logTag], @"Couldn't create Identity config file.");
                }
                @synchronized(self) {
                  self.identityConfig = config;

                  // Reinitialize client application.
                  [self configAuthenticationClient];
                }
              } else {
                MSLogError([MSIdentity logTag], @"Downloaded identity configuration is not valid.");
              }
            } else {
              MSLogError([MSIdentity logTag], @"Failed to download identity configuration. Status code received: %ld",
                         (long)response.statusCode);
            }
          }];
}

- (void)configAuthenticationClient {

  // Init MSAL client application.
  NSError *error;
  MSALAuthority *auth = [MSALAuthority authorityWithURL:(NSURL * _Nonnull) self.identityConfig.authorities[0].authorityUrl error:nil];
  self.clientApplication = [[MSALPublicClientApplication alloc] initWithClientId:(NSString * _Nonnull) self.identityConfig.clientId
                                                                       authority:auth
                                                                     redirectUri:self.identityConfig.redirectUri
                                                                           error:&error];
  self.clientApplication.validateAuthority = NO;
  if (error != nil) {
    MSLogError([MSIdentity logTag], @"Failed to initialize client application.");
  }
}

- (void)clearConfigurationCache {
  [MSUtility deleteItemForPathComponent:[self identityConfigFilePath]];
  [MS_USER_DEFAULTS removeObjectForKey:kMSIdentityETagKey];
}

- (MSIdentityConfig *)deserializeData:(NSData *)data {
  NSError *error;
  MSIdentityConfig *config;
  if (data) {
    id dictionary = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:&error];
    if (error) {
      MSLogError([MSIdentity logTag], @"Couldn't parse json data: %@", error.localizedDescription);
    } else {
      config = [[MSIdentityConfig alloc] initWithDictionary:dictionary];
    }
  }
  return config;
}

- (BOOL)clearAuthData {
  BOOL result = YES;
  if (![self removeAccount]) {
    MSLogWarning([MSIdentity logTag], @"Couldn't remove account data.");
    result = NO;
  }
  if (![[MSAuthTokenContext sharedInstance] clearAuthToken]) {
    MSLogWarning([MSIdentity logTag], @"Couldn't clear authToken: it doesn't exist.");
    result = NO;
  }
  return result;
}

- (BOOL)removeAccount {
  if (!self.clientApplication) {
    return NO;
  }
  NSString *accountId = [[MSAuthTokenContext sharedInstance] accountId];
  MSALAccount *account = [self retrieveAccountWithAccountId:accountId];
  if (account) {
    NSError *error;
    [self.clientApplication removeAccount:account error:&error];
    if (error) {
      MSLogWarning([MSIdentity logTag], @"Failed to remove account: %@", error.localizedDescription);
      return NO;
    }
  }
  return YES;
}

- (void)acquireTokenSilentlyWithMSALAccount:(MSALAccount *)account {
  __weak typeof(self) weakSelf = self;
  [self.clientApplication
      acquireTokenSilentForScopes:@[ (NSString * _Nonnull) self.identityConfig.identityScope ]
                          account:account
                  completionBlock:^(MSALResult *result, NSError *e) {
                    typeof(self) strongSelf = weakSelf;
                    if (e) {
                      MSLogWarning([MSIdentity logTag],
                                   @"Silent acquisition of token failed with error: %@. Triggering interactive acquisition", e);
                      [strongSelf acquireTokenInteractively];
                    } else {
                      MSALAccountId *accountId = (MSALAccountId * _Nonnull) result.account.homeAccountId;
                      [[MSAuthTokenContext sharedInstance] setAuthToken:result.idToken
                                                          withAccountId:accountId.identifier
                                                              expiresOn:result.expiresOn];
                      [strongSelf completeAcquireTokenRequestForResult:result withError:nil];
                      MSLogInfo([MSIdentity logTag], @"Silent acquisition of token succeeded.");
                    }
                  }];
}

- (void)acquireTokenInteractively {
  __weak typeof(self) weakSelf = self;
  [self.clientApplication acquireTokenForScopes:@[ (NSString * _Nonnull) self.identityConfig.identityScope ]
                                completionBlock:^(MSALResult *result, NSError *e) {
                                  typeof(self) strongSelf = weakSelf;
                                  if (e) {
                                    if (e.code == MSALErrorUserCanceled) {
                                      MSLogWarning([MSIdentity logTag], @"User canceled sign-in.");
                                    } else {
                                      MSLogError([MSIdentity logTag], @"User sign-in failed. Error: %@", e);
                                    }
                                  } else {
                                    MSALAccountId *accountId = (MSALAccountId * _Nonnull) result.account.homeAccountId;
                                    [[MSAuthTokenContext sharedInstance] setAuthToken:result.idToken
                                                                        withAccountId:accountId.identifier
                                                                            expiresOn:result.expiresOn];
                                    MSLogInfo([MSIdentity logTag], @"User sign-in succeeded.");
                                  }
                                  [strongSelf completeAcquireTokenRequestForResult:result withError:e];
                                }];
}

- (void)completeAcquireTokenRequestForResult:(MSALResult *)result withError:(NSError *)error {
  @synchronized(self) {
    if (!self.signInCompletionHandler) {
      return;
    }
    if (error) {
      self.signInCompletionHandler(nil, error);
    } else {
      MSUserInformation *userInformation = [MSUserInformation new];
      userInformation.accountId = (NSString * _Nonnull) result.uniqueId;
      self.signInCompletionHandler(userInformation, nil);
    }
    self.signInCompletionHandler = nil;
  }
}

- (MSALAccount *)retrieveAccountWithAccountId:(NSString *)homeAccountId {
  if (!homeAccountId) {
    return nil;
  }
  NSError *error;
  MSALAccount *account = [self.clientApplication accountForHomeAccountId:homeAccountId error:&error];
  if (error) {
    MSLogWarning([MSIdentity logTag], @"Could not get MSALAccount for homeAccountId. Error: %@", error);
  }
  return account;
}

@end
