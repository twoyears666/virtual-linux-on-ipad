// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 twoyears666

#import <Foundation/Foundation.h>

/// 一个虚拟机存放位置，例如 App 文档目录，或外接磁盘上用户自选的文件夹。
/// 位置只是登记，彼此独立；某位置不可用时，它下面的虚拟机被冻结。
@interface VLStorageLocation : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
/// 目录的绝对路径。外接目录换路径时会随之更新。
@property (nonatomic, copy, readonly) NSString *path;
/// security-scoped 书签，用于重启后重新拿到外接目录的访问权。
@property (nonatomic, strong, readonly) NSData *bookmark;
/// 内置的默认位置（App 文档目录），不可删除。
@property (nonatomic, assign, readonly, getter=isBuiltIn) BOOL builtIn;

+ (instancetype)locationWithIdentifier:(NSString *)identifier
								  name:(NSString *)name
								  path:(NSString *)path
							  bookmark:(NSData *)bookmark
							   builtIn:(BOOL)builtIn;

/// 目录存在且是文件夹。
@property (nonatomic, readonly, getter=isAvailable) BOOL available;

/// 剩余可用空间（字节）；取不到时返回 -1。
- (long long)availableCapacityBytes;

/// 拼出某台虚拟机的目录 <path>/<machineIdentifier>（只拼路径，不创建）。
- (NSURL *)machineDirectoryForIdentifier:(NSString *)machineIdentifier;

/// 外接目录换路径或书签失效时，由 VLStorageManager 更新登记信息。
- (void)updatePath:(NSString *)path bookmark:(NSData *)bookmark;

- (NSDictionary *)dictionaryRepresentation;
+ (instancetype)locationWithDictionaryRepresentation:(NSDictionary *)dictionary;

@end
