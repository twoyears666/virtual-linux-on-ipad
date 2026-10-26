#import "VLStorageManager.h"

#import "VLStartupLog.h"

static NSString *const VLStorageManagerDefaultsKey = @"VLStorageLocations";
static NSString *const VLStorageManagerDefaultIdentifier = @"builtin";
static NSString *const VLStorageManagerDefaultFolder = @"VirtualMachines";

@interface VLStorageManager ()

@property (nonatomic, strong) NSMutableArray<VLStorageLocation *> *mutableLocations;

@end

@implementation VLStorageManager

+ (NSNotificationName)didChangeNotification {
	return @"VLStorageManagerDidChangeNotification";
}

+ (instancetype)sharedManager {
	static VLStorageManager *manager = nil;
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		manager = [[VLStorageManager alloc] init];
	});
	return manager;
}

- (instancetype)init {
	self = [super init];
	if (self) {
		_mutableLocations = [NSMutableArray array];
		[self loadLocations];
		[self ensureDefaultLocation];
	}
	return self;
}

- (NSArray<VLStorageLocation *> *)locations {
	return [self.mutableLocations copy];
}

#pragma mark - 默认位置

- (NSURL *)defaultDirectoryURL {
	NSURL *documents =
		[NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
	if (documents == nil) {
		documents = [NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES];
	}
	return [documents URLByAppendingPathComponent:VLStorageManagerDefaultFolder isDirectory:YES];
}

- (void)ensureDefaultLocation {
	NSURL *url = [self defaultDirectoryURL];
	[NSFileManager.defaultManager createDirectoryAtURL:url
						   withIntermediateDirectories:YES
											attributes:nil
												 error:NULL];

	VLStorageLocation *existing = [self locationWithIdentifier:VLStorageManagerDefaultIdentifier];
	if (existing == nil) {
		existing = [self locationWithPath:url.path];
	}
	if (existing != nil) {
		[existing updatePath:url.path bookmark:nil];
		return;
	}

	VLStorageLocation *location =
		[VLStorageLocation locationWithIdentifier:VLStorageManagerDefaultIdentifier
											 name:@"本机存储"
											 path:url.path
										 bookmark:nil
										  builtIn:YES];
	[self.mutableLocations insertObject:location atIndex:0];
	[self saveLocations];
}

- (VLStorageLocation *)defaultLocation {
	VLStorageLocation *location = [self locationWithIdentifier:VLStorageManagerDefaultIdentifier];
	if (location == nil) {
		[self ensureDefaultLocation];
		location = [self locationWithIdentifier:VLStorageManagerDefaultIdentifier];
	}
	return location;
}

- (VLStorageLocation *)locationWithIdentifier:(NSString *)identifier {
	if (identifier.length == 0) {
		return nil;
	}
	for (VLStorageLocation *location in self.mutableLocations) {
		if ([location.identifier isEqualToString:identifier]) {
			return location;
		}
	}
	return nil;
}

- (VLStorageLocation *)locationWithPath:(NSString *)path {
	if (path.length == 0) {
		return nil;
	}
	for (VLStorageLocation *location in self.mutableLocations) {
		if ([location.path isEqualToString:path]) {
			return location;
		}
	}
	return nil;
}

#pragma mark - 增删

- (VLStorageLocation *)addLocationWithURL:(NSURL *)url error:(NSError **)error {
	if (url == nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.Storage"
										 code:1
									 userInfo:@{ NSLocalizedDescriptionKey: @"没有选中任何文件夹" }];
		}
		return nil;
	}

	BOOL isDirectory = NO;
	if (![NSFileManager.defaultManager fileExistsAtPath:url.path isDirectory:&isDirectory] || !isDirectory) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"VirtualLinux.Storage"
										 code:2
									 userInfo:@{ NSLocalizedDescriptionKey: @"选中的不是可用文件夹" }];
		}
		return nil;
	}

	VLStorageLocation *existing = [self locationWithPath:url.path];
	if (existing != nil) {
		return existing;
	}

	if (![url startAccessingSecurityScopedResource]) {
		[VLStartupLog log:@"存储位置未拿到安全作用域访问权：%@", url.path];
	}

	NSError *bookmarkError = nil;
	NSData *bookmark = [url bookmarkDataWithOptions:0
					 includingResourceValuesForKeys:nil
									  relativeToURL:nil
											  error:&bookmarkError];
	if (bookmark == nil) {
		[VLStartupLog log:@"存储位置书签创建失败：%@（%@）", url.path, bookmarkError.localizedDescription];
		if (error != NULL) {
			*error = bookmarkError;
		}
		return nil;
	}

	VLStorageLocation *location =
		[VLStorageLocation locationWithIdentifier:NSUUID.UUID.UUIDString
											 name:url.lastPathComponent.length > 0 ? url.lastPathComponent : url.path
											 path:url.path
										 bookmark:bookmark
										  builtIn:NO];
	[self.mutableLocations addObject:location];
	[self saveLocations];

	[VLStartupLog log:@"登记存储位置：%@（%@）", location.name, location.path];
	[NSNotificationCenter.defaultCenter postNotificationName:VLStorageManager.didChangeNotification
													  object:self];
	return location;
}

- (BOOL)removeLocation:(VLStorageLocation *)location {
	if (location == nil || location.isBuiltIn || location.identifier.length == 0) {
		return NO;
	}
	[self.mutableLocations removeObject:location];
	[self saveLocations];
	[VLStartupLog log:@"移除存储位置登记：%@（%@）", location.name, location.path];
	[NSNotificationCenter.defaultCenter postNotificationName:VLStorageManager.didChangeNotification
													  object:self];
	return YES;
}

#pragma mark - 持久化与书签

- (void)loadLocations {
	NSArray *saved = [NSUserDefaults.standardUserDefaults arrayForKey:VLStorageManagerDefaultsKey];
	for (NSDictionary *dictionary in saved) {
		VLStorageLocation *location = [VLStorageLocation locationWithDictionaryRepresentation:dictionary];
		if (location != nil) {
			[self.mutableLocations addObject:location];
		}
	}
}

- (void)saveLocations {
	NSMutableArray *serialized = [NSMutableArray arrayWithCapacity:self.mutableLocations.count];
	for (VLStorageLocation *location in self.mutableLocations) {
		[serialized addObject:[location dictionaryRepresentation]];
	}
	[NSUserDefaults.standardUserDefaults setObject:serialized forKey:VLStorageManagerDefaultsKey];
}

- (void)restoreAccess {
	BOOL changed = NO;
	for (VLStorageLocation *location in self.mutableLocations) {
		if (location.bookmark == nil) {
			continue;
		}

		BOOL stale = NO;
		NSError *error = nil;
		NSURL *resolved = [NSURL URLByResolvingBookmarkData:location.bookmark
													options:NSURLBookmarkResolutionWithoutUI
											  relativeToURL:nil
										bookmarkDataIsStale:&stale
													  error:&error];
		if (resolved == nil) {
			[VLStartupLog log:@"存储位置书签解析失败：%@（%@）", location.name, error.localizedDescription];
			continue;
		}

		if (![resolved.path isEqualToString:location.path]) {
			[VLStartupLog log:@"存储位置路径变化：%@ → %@", location.path, resolved.path];
			[location updatePath:resolved.path bookmark:nil];
			changed = YES;
		}

		[resolved startAccessingSecurityScopedResource];

		if (stale) {
			NSData *bookmark = [resolved bookmarkDataWithOptions:0
								 includingResourceValuesForKeys:nil
												  relativeToURL:nil
														  error:NULL];
			if (bookmark != nil) {
				[location updatePath:nil bookmark:bookmark];
				changed = YES;
			}
		}
	}

	if (changed) {
		[self saveLocations];
	}
}

@end
