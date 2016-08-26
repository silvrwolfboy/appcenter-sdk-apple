#import "AVAFile.h"
#import "AVAFileHelper.h"
#import "AVAFileStorage.h"
#import "AVALogger.h"
#import "AVAUtils.h"

static NSString *const kAVALogsDirectory = @"com.microsoft.avalanche/logs";
static NSString *const kAVAFileExtension = @"ava";
static NSUInteger const AVADefaultBucketFileCountLimit = 50;

@implementation AVAFileStorage

@synthesize bucketFileCountLimit = _bucketFileCountLimit;

#pragma mark - Initialisation

- (instancetype)init {
  if (self = [super init]) {
    _buckets = [NSMutableDictionary<NSString *, AVAStorageBucket *> new];
    _bucketFileCountLimit = AVADefaultBucketFileCountLimit;
  }
  return self;
}

#pragma mark - Public

- (void)saveLog:(id<AVALog>)log withStorageKey:(NSString *)storageKey {
  if (!log) {
    return;
  }

  AVAStorageBucket *bucket = [self bucketForStorageKey:storageKey];
  if (bucket.currentLogs.count == 0) {

    // Drop oldest files if needed
    if ([self maxFileCountReachedForStorageKey:storageKey]) {
      AVAFile *oldestFile = [bucket.availableFiles lastObject];
      [self deleteLogsForId:oldestFile.fileId withStorageKey:storageKey];
    }

    // Make current file available and create new current file
    [bucket.availableFiles insertObject:bucket.currentFile atIndex:0];
  }

  [bucket.currentLogs addObject:log];
  NSData *logsData = [NSKeyedArchiver archivedDataWithRootObject:bucket.currentLogs];
  [AVAFileHelper writeData:logsData toFile:bucket.currentFile];
}

- (void)deleteLogsForId:(NSString *)logsId withStorageKey:(NSString *)storageKey {
  AVAStorageBucket *bucket = self.buckets[storageKey];
  AVAFile *file = [bucket fileWithId:logsId];

  if (file) {
    [AVAFileHelper deleteFile:file];
    [bucket removeFile:file];
  }
}

- (void)loadLogsForStorageKey:(NSString *)storageKey withCompletion:(nullable AVALoadDataCompletionBlock)completion {
  NSArray<AVALog> *logs;
  NSString *fileId;
  AVAStorageBucket *bucket = [self bucketForStorageKey:storageKey];

  [self renewCurrentFileForStorageKey:storageKey];

  // Get data of oldest file
  if (bucket.availableFiles.count > 0) {
    AVAFile *file = bucket.availableFiles.lastObject;
    fileId = file.fileId;
    NSData *logData = [AVAFileHelper dataForFile:file];
    logs = [NSKeyedUnarchiver unarchiveObjectWithData:logData];
    [bucket.blockedFiles addObject:file];
    [bucket.availableFiles removeLastObject];
  }

  if (completion) {
    completion(logs, fileId);
  }
}

- (BOOL)maxFileCountReachedForStorageKey:(NSString *)storageKey {
  AVAStorageBucket *bucket = self.buckets[storageKey];
  NSUInteger filesCount = bucket.availableFiles.count + bucket.blockedFiles.count;
  return (filesCount >= self.bucketFileCountLimit);
}

#pragma mark - Helper

- (AVAStorageBucket *)createNewBucketForStorageKey:(NSString *)storageKey {
  AVAStorageBucket *bucket = [AVAStorageBucket new];
  NSString *storageDirectory = [self directoryPathForStorageKey:storageKey];
  NSArray *existingFiles = [AVAFileHelper filesForDirectory:storageDirectory withFileExtension:kAVAFileExtension];
  if (existingFiles) {
    [bucket.availableFiles addObjectsFromArray:existingFiles];
    [bucket sortAvailableFilesByCreationDate];
  }
  self.buckets[storageKey] = bucket;
  [self renewCurrentFileForStorageKey:storageKey];

  return bucket;
}

- (AVAStorageBucket *)bucketForStorageKey:(NSString *)storageKey {
  AVAStorageBucket *bucket = self.buckets[storageKey];
  if (!bucket) {
    bucket = [self createNewBucketForStorageKey:storageKey];
  }

  return bucket;
}

- (void)renewCurrentFileForStorageKey:(NSString *)storageKey {
  AVAStorageBucket *bucket = [self bucketForStorageKey:storageKey];
  NSDate *creationDate = [NSDate date];
  NSString *fileId = kAVAUUIDString;
  NSString *filePath = [self filePathForStorageKey:storageKey logsId:fileId];
  AVAFile *file = [[AVAFile alloc] initWithPath:filePath fileId:fileId creationDate:creationDate];
  bucket.currentFile = file;
  [bucket.currentLogs removeAllObjects];
}

- (NSString *)directoryPathForStorageKey:(nonnull NSString *)storageKey {
  NSString *filePath = [self.baseDirectoryPath stringByAppendingPathComponent:storageKey];

  return filePath;
}

- (NSString *)filePathForStorageKey:(nonnull NSString *)storageKey logsId:(nonnull NSString *)logsId {
  NSString *fileName = [logsId stringByAppendingPathExtension:kAVAFileExtension];
  NSString *filePath = [[self directoryPathForStorageKey:storageKey] stringByAppendingPathComponent:fileName];

  return filePath;
}

- (NSString *)baseDirectoryPath {
  if (!_baseDirectoryPath) {
    NSString *appSupportPath =
        [[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) lastObject]
            stringByStandardizingPath];
    if (appSupportPath) {
      _baseDirectoryPath = [appSupportPath stringByAppendingPathComponent:kAVALogsDirectory];
    }

    AVALogVerbose(@"Storage Path:\n%@", _baseDirectoryPath);
  }

  return _baseDirectoryPath;
}

@end