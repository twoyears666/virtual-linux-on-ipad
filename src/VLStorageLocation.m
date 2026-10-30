// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import "VLStorageLocation.h"

@interface VLStorageLocation ()

@property (nonatomic, copy, readwrite) NSString *identifier;
@property (nonatomic, copy, readwrite) NSString *name;
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, strong, readwrite) NSData *bookmark;
@property (nonatomic, assign, readwrite, getter=isBuiltIn) BOOL builtIn;

@end

@implementation VLStorageLocation

+ (instancetype)locationWithIdentifier:(NSString *)identifier
								  name:(NSString *)name
								  path:(NSString *)path
							  bookmark:(NSData *)bookmark
							   builtIn:(BOOL)builtIn {
	VLStorageLocation *location = [[VLStorageLocation alloc] init];
	location.identifier = identifier.length > 0 ? identifier : NSUUID.UUID.UUIDString;
	location.name = name.length > 0 ? name : path.lastPathComponent;
	location.path = path ?: @"";
	location.bookmark = bookmark;
	location.builtIn = builtIn;
	return location;
}

- (BOOL)isAvailable {
	if (self.path.length == 0) {
		return NO;
	}
	BOOL isDirectory = NO;
	BOOL exists = [NSFileManager.defaultManager fileExistsAtPath:self.path isDirectory:&isDirectory];
	return exists && isDirectory;
}

- (long long)availableCapacityBytes {
	if (!self.isAvailable) {
		return -1;
	}
	NSURL *url = [NSURL fileURLWithPath:self.path isDirectory:YES];
	NSError *error = nil;
	NSDictionary<NSURLResourceKey, id> *values =
		[url resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ] error:&error];
	if (values == nil) {
		return -1;
	}
	return [values[NSURLVolumeAvailableCapacityForImportantUsageKey] longLongValue];
}

- (NSURL *)machineDirectoryForIdentifier:(NSString *)machineIdentifier {
	return [[NSURL fileURLWithPath:self.path isDirectory:YES]
		URLByAppendingPathComponent:machineIdentifier isDirectory:YES];
}

- (void)updatePath:(NSString *)path bookmark:(NSData *)bookmark {
	if (path.length > 0) {
		self.path = path;
		self.name = path.lastPathComponent.length > 0 ? path.lastPathComponent : self.name;
	}
	if (bookmark != nil) {
		self.bookmark = bookmark;
	}
}

- (NSDictionary *)dictionaryRepresentation {
	NSMutableDictionary *dictionary = [NSMutableDictionary dictionary];
	dictionary[@"identifier"] = self.identifier ?: @"";
	dictionary[@"name"] = self.name ?: @"";
	dictionary[@"path"] = self.path ?: @"";
	dictionary[@"builtIn"] = @(self.builtIn);
	if (self.bookmark != nil) {
		dictionary[@"bookmark"] = self.bookmark;
	}
	return dictionary;
}

+ (instancetype)locationWithDictionaryRepresentation:(NSDictionary *)dictionary {
	if (dictionary == nil) {
		return nil;
	}
	return [self locationWithIdentifier:dictionary[@"identifier"]
								   name:dictionary[@"name"]
								   path:dictionary[@"path"]
							   bookmark:dictionary[@"bookmark"]
								builtIn:[dictionary[@"builtIn"] boolValue]];
}

@end
