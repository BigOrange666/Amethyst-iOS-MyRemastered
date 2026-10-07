//
//  GameDirectoryResolver.m
//  Angel Aura Amethyst
//

#import "GameDirectoryResolver.h"
#import "LauncherPreferences.h"
#import "PLProfiles.h"
#import "utils.h"

NSString *const AMEIsolationShared = @"shared";
NSString *const AMEIsolationVersion = @"version";
NSString *const AMEIsolationCustom = @"custom";

@interface GameDirectoryResolver ()
+ (NSString *)versionIdForProfile:(NSDictionary *)profile override:(nullable NSString *)versionId;
+ (NSString *)gameDirValueForProfile:(NSDictionary *)profile;
+ (NSString *)resolveAliasVersionId:(NSString *)versionId;
@end

@implementation GameDirectoryResolver

#pragma mark - 目录

+ (NSString *)mainDirectory {
    const char *env = getenv("POJAV_GAME_DIR");
    if (env && env[0]) {
        return [NSString stringWithUTF8String:env];
    }
    return NSHomeDirectory();
}

+ (nullable NSString *)effectiveVersionIdForProfile:(NSDictionary *)profile {
    id raw = profile[@"lastVersionId"];
    if (![raw isKindOfClass:[NSString class]] || [(NSString *)raw length] == 0) {
        return nil;
    }
    return [self resolveAliasVersionId:(NSString *)raw];
}

/// 把 latest-release / latest-snapshot 解析成真实版本号；其余原样返回。
/// 解析不出来时返回原别名（由调用方决定如何兜底）。
+ (NSString *)resolveAliasVersionId:(NSString *)versionId {
    if (![versionId isKindOfClass:[NSString class]] || versionId.length == 0) {
        return versionId;
    }
    // 别名解析：与 MinecraftResourceDownloadTask.downloadVersionMetadata 同源
    if ([versionId isEqualToString:@"latest-release"]) {
        NSString *resolved = getPrefObject(@"internal.latest_version.release");
        if ([resolved isKindOfClass:[NSString class]] && resolved.length > 0) {
            return resolved;
        }
    } else if ([versionId isEqualToString:@"latest-snapshot"]) {
        NSString *resolved = getPrefObject(@"internal.latest_version.snapshot");
        if ([resolved isKindOfClass:[NSString class]] && resolved.length > 0) {
            return resolved;
        }
    }
    return versionId;
}

+ (NSString *)versionRootForProfile:(NSDictionary *)profile {
    return [self versionRootForProfile:profile versionId:nil];
}

+ (NSString *)versionRootForProfile:(NSDictionary *)profile
                          versionId:(NSString *)versionId {
    NSString *resolved = [self versionIdForProfile:profile override:versionId];
    if (resolved.length == 0) {
        NSLog(@"[GameDir] profile 没有可用的版本 ID，版本隔离目录回退主目录: %@",
              profile[@"name"] ?: @"(unnamed)");
        return [self mainDirectory];
    }
    return [[self mainDirectory] stringByAppendingPathComponent:
            [NSString stringWithFormat:@"versions/%@", resolved]];
}

+ (NSString *)absolutePath:(NSString *)path {
    if (path.length == 0) {
        return [self mainDirectory];
    }
    if ([path isAbsolutePath]) {
        return path.stringByStandardizingPath;
    }
    NSString *clean = [path hasPrefix:@"./"] ? [path substringFromIndex:2] : path;
    return [[[self mainDirectory] stringByAppendingPathComponent:clean] stringByStandardizingPath];
}

+ (AMEDirIsolation)isolationForProfile:(NSDictionary *)profile {
    return [self isolationForProfile:profile versionId:nil];
}

+ (AMEDirIsolation)isolationForProfile:(NSDictionary *)profile
                             versionId:(NSString *)versionId {
    id explicit = profile[@"isolation"];
    if ([explicit isKindOfClass:[NSString class]]) {
        if ([explicit isEqualToString:AMEIsolationVersion]) return AMEDirIsolationVersion;
        if ([explicit isEqualToString:AMEIsolationCustom]) return AMEDirIsolationCustom;
        if ([explicit isEqualToString:AMEIsolationShared]) return AMEDirIsolationShared;
    }

    // 兼容存量数据：没有 isolation key 时由旧 gameDir 推导。
    // gameDir == "." → 不隔离；等于 versions/<版本ID> → 版本隔离；其余 → 自定义路径。
    id raw = profile[@"gameDir"];
    if (![raw isKindOfClass:[NSString class]] || [(NSString *)raw length] == 0 ||
        [(NSString *)raw isEqualToString:@"."]) {
        return AMEDirIsolationShared;
    }
    NSString *resolved = [self absolutePath:(NSString *)raw];
    // 两种写法都算版本隔离：./versions/<lastVersionId>（可能是 latest-* 别名，
    // 与解析后的版本号写在一起都认），避免别名被误判成自定义路径。
    if ([resolved isEqualToString:[self versionRootForProfile:profile versionId:versionId]]) {
        return AMEDirIsolationVersion;
    }
    id rawVid = profile[@"lastVersionId"];
    if ([rawVid isKindOfClass:[NSString class]] && [(NSString *)rawVid length] > 0) {
        NSString *rawVersionRoot = [[self mainDirectory] stringByAppendingPathComponent:
                                    [NSString stringWithFormat:@"versions/%@", rawVid]];
        if ([resolved isEqualToString:rawVersionRoot.stringByStandardizingPath]) {
            return AMEDirIsolationVersion;
        }
    }
    return AMEDirIsolationCustom;
}

+ (BOOL)profileIsIsolated:(NSDictionary *)profile {
    if ([self isModpackProfile:profile]) {
        return YES;
    }
    return [self isolationForProfile:profile] != AMEDirIsolationShared;
}

+ (NSString *)gameDirValueForIsolation:(AMEDirIsolation)isolation profile:(NSDictionary *)profile {
    switch (isolation) {
        case AMEDirIsolationVersion: {
            NSString *versionId = [self effectiveVersionIdForProfile:profile];
            if (versionId.length == 0) {
                return @".";
            }
            return [NSString stringWithFormat:@"./versions/%@", versionId];
        }
        case AMEDirIsolationCustom: {
            id raw = profile[@"gameDir"];
            // 之前是共享目录时没有可用的自定义值，用版本隔离目录作为起点，避免退化成 "."
            if (![raw isKindOfClass:[NSString class]] || [(NSString *)raw length] == 0 ||
                [(NSString *)raw isEqualToString:@"."]) {
                NSString *versionId = [self effectiveVersionIdForProfile:profile];
                if (versionId.length == 0) return @"./custom_gamedir";
                return [NSString stringWithFormat:@"./versions/%@", versionId];
            }
            return (NSString *)raw;
        }
        case AMEDirIsolationShared:
        default:
            return @".";
    }
}

+ (void)setIsolation:(AMEDirIsolation)isolation forProfile:(NSMutableDictionary *)profile {
    switch (isolation) {
        case AMEDirIsolationVersion: profile[@"isolation"] = AMEIsolationVersion; break;
        case AMEDirIsolationCustom:  profile[@"isolation"] = AMEIsolationCustom;  break;
        case AMEDirIsolationShared:
        default:                     profile[@"isolation"] = AMEIsolationShared;  break;
    }
    // gameDir 继续保持同步：老代码、Java 端 MinecraftProfile.gameDir 与
    // 用户从旧版本升级上来都依赖这个字段。
    profile[@"gameDir"] = [self gameDirValueForIsolation:isolation profile:profile];
}

+ (void)applyDefaultIsolationToProfile:(NSMutableDictionary *)profile modded:(BOOL)modded {
    NSString *policy = getPrefObject(@"general.default_isolation");
    if (![policy isKindOfClass:[NSString class]] || policy.length == 0) {
        policy = @"modded";
    }
    AMEDirIsolation isolation;
    if ([policy isEqualToString:@"always"]) {
        isolation = AMEDirIsolationVersion;
    } else if ([policy isEqualToString:@"never"]) {
        isolation = AMEDirIsolationShared;
    } else {
        // HMCL DefaultIsolationType.MODDED（默认）：仅带 Mod 加载器的实例隔离
        isolation = modded ? AMEDirIsolationVersion : AMEDirIsolationShared;
    }
    [self setIsolation:isolation forProfile:profile];
    NSLog(@"[GameDir] 新建 profile 应用默认隔离策略 policy=%@ modded=%d → %@",
          policy, modded, profile[@"isolation"]);
}

#pragma mark - 决策函数

+ (NSString *)runDirectoryForProfile:(NSDictionary *)profile {
    return [self runDirectoryForProfile:profile versionId:nil];
}

+ (NSString *)runDirectoryForProfile:(NSDictionary *)profile
                           versionId:(NSString *)versionId {
    if (![profile isKindOfClass:[NSDictionary class]] || profile.count == 0) {
        return [self mainDirectory];
    }

    // ① 整合包 profile：强制隔离到自己的实例根（HMCL computeRunDirectory 的 modpack 分支）
    if ([self isModpackProfile:profile]) {
        NSString *gameDir = [self gameDirValueForProfile:profile];
        if (gameDir.length > 0 && ![gameDir isEqualToString:@"."]) {
            return [self absolutePath:gameDir];
        }
        return [self versionRootForProfile:profile versionId:versionId];
    }

    switch ([self isolationForProfile:profile versionId:versionId]) {
        case AMEDirIsolationVersion:
            return [self versionRootForProfile:profile versionId:versionId];
        case AMEDirIsolationCustom: {
            NSString *gameDir = [self gameDirValueForProfile:profile];
            if (gameDir.length == 0 || [gameDir isEqualToString:@"."]) {
                return [self mainDirectory];
            }
            return [self absolutePath:gameDir];
        }
        case AMEDirIsolationShared:
        default:
            return [self mainDirectory];
    }
}

+ (NSString *)pathForProfile:(NSDictionary *)profile subdir:(NSString *)subdir {
    NSString *base = [self runDirectoryForProfile:profile];
    if (subdir.length == 0) return base;
    return [base stringByAppendingPathComponent:subdir];
}

+ (NSString *)displayValueForProfile:(NSDictionary *)profile {
    if ([self isModpackProfile:profile]) {
        NSString *gameDir = [self gameDirValueForProfile:profile];
        return gameDir.length ? gameDir : [self mainDirectory];
    }
    switch ([self isolationForProfile:profile]) {
        case AMEDirIsolationVersion: {
            NSString *versionId = [self effectiveVersionIdForProfile:profile];
            return versionId.length ? [NSString stringWithFormat:@"versions/%@", versionId] : @"versions/";
        }
        case AMEDirIsolationCustom:
            return [self gameDirValueForProfile:profile];
        case AMEDirIsolationShared:
        default:
            // 保持老 UI 的展示形态："." + " → /instances/<实例名>"
            return @".";
    }
}

#pragma mark - 安全检查

+ (BOOL)isVersionDirectoryReferencedByProfiles:(NSString *)versionDir {
    if (versionDir.length == 0) return NO;
    NSString *target = versionDir.stringByStandardizingPath;

    NSDictionary *profiles = PLProfiles.current.profiles;
    if (![profiles isKindOfClass:[NSDictionary class]]) return NO;

    for (id name in profiles) {
        id raw = profiles[name];
        if (![raw isKindOfClass:[NSDictionary class]]) continue;
        NSString *runDir = [self runDirectoryForProfile:(NSDictionary *)raw].stringByStandardizingPath;
        if ([runDir isEqualToString:target] ||
            [runDir hasPrefix:[target stringByAppendingString:@"/"]]) {
            NSLog(@"[GameDir] 目录 %@ 正被 profile '%@' 使用（runDir=%@），不能整目录删除",
                  target, name, runDir);
            return YES;
        }
    }
    return NO;
}

#pragma mark - Private

/// 启动期可用 launchTarget 解析好的真实版本号覆盖 profile 的 lastVersionId
/// （后者可能是 latest-release 这类别名）。覆盖值本身是别名时照样走解析。
+ (NSString *)versionIdForProfile:(NSDictionary *)profile override:(NSString *)versionId {
    // 有覆盖值就解析它自己（含 latest-* 别名），不要回落到 profile.lastVersionId——
    // 启动的版本和 profile 记录的版本可能不一致（比如临时切换了启动版本）。
    if ([versionId isKindOfClass:[NSString class]] && versionId.length > 0 &&
        [versionId rangeOfString:@"/"].location == NSNotFound) {
        return [self resolveAliasVersionId:versionId];
    }
    NSString *effective = [self effectiveVersionIdForProfile:profile];
    if (effective.length > 0) {
        return effective;
    }
    return @"";
}

/// 整合包判定：与 ModpackImportService 写入的 profile.type == "modpack" 对齐，
/// 另外兜底识别 gameDir 位于 custom_gamedir 下（历史数据可能缺 type）。
+ (BOOL)isModpackProfile:(NSDictionary *)profile {
    id type = profile[@"type"];
    if ([type isKindOfClass:[NSString class]] && [type isEqualToString:@"modpack"]) {
        return YES;
    }
    NSString *gameDir = [self gameDirValueForProfile:profile];
    return gameDir.length > 0 && [gameDir rangeOfString:@"custom_gamedir/"].location != NSNotFound;
}

+ (NSString *)gameDirValueForProfile:(NSDictionary *)profile {
    id raw = profile[@"gameDir"];
    if ([raw isKindOfClass:[NSString class]] && [(NSString *)raw length] > 0) {
        return (NSString *)raw;
    }
    return @".";
}

@end
