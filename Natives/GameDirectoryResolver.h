//
//  GameDirectoryResolver.h
//  Angel Aura Amethyst
//
//  版本隔离（对齐 HMCL）——运行目录的唯一决策点。
//
//  HMCL 侧对应物：
//    - baseDirectory      = POJAV_GAME_DIR（.minecraft 主目录，符号链接到 instances/<实例名>）
//    - instanceRoot       = POJAV_GAME_DIR/versions/<版本ID>
//    - runDirectory       = computeRunDirectory()（本文件 runDirectoryForProfile:）
//    - DefaultIsolationType / overrideProperties → AMEDirIsolation + general.default_isolation
//
//  规则（与 HMCLGameRepository.computeRunDirectory 一一对应）：
//    ① 整合包 profile  → 强制隔离到自己的实例根（本仓为 custom_gamedir/<id>）
//    ② 隔离(version)   → <main>/versions/<版本ID>
//    ③ 自定义(custom)  → profile.gameDir（绝对路径原样，相对路径相对主目录）
//    ④ 不隔离(shared)  → <main> 主目录
//
//  saves / mods / config / resourcepacks / shaderpacks / screenshots / logs
//  一律从 runDirectory 派生；versions/<id>/<id>.jar、libraries、assets 永远共享。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AMEDirIsolation) {
    AMEDirIsolationShared = 0,  ///< 不隔离：所有版本共用主目录
    AMEDirIsolationVersion = 1, ///< 版本隔离：每个版本一份 versions/<id>/
    AMEDirIsolationCustom = 2,  ///< 自定义路径：gameDir 指向任意目录
};

/// profile 的 isolation key 取值（与 AMEDirIsolation 一一对应）
extern NSString *const AMEIsolationShared;
extern NSString *const AMEIsolationVersion;
extern NSString *const AMEIsolationCustom;

@interface GameDirectoryResolver : NSObject

#pragma mark - 目录

/// 主目录（POJAV_GAME_DIR，符号链接 → $POJAV_HOME/instances/<当前实例>）
+ (NSString *)mainDirectory;

/// profile 的有效版本 ID：把 latest-release / latest-snapshot 别名解析成真实版本号。
/// 解析不出来时返回原始值，完全没有版本号时返回 nil。
+ (nullable NSString *)effectiveVersionIdForProfile:(NSDictionary *)profile;

/// 版本隔离目录（= HMCL instanceRoot）：<main>/versions/<版本ID>。
/// 无有效版本 ID 时回退到主目录。
/// versionId 传 nil 时用 profile 自身的 lastVersionId（会解析 latest-* 别名）；
/// 启动期请传入 launchTarget 里已解析好的真实版本号。
+ (NSString *)versionRootForProfile:(NSDictionary *)profile;
+ (NSString *)versionRootForProfile:(NSDictionary *)profile
                          versionId:(nullable NSString *)versionId;

/// 唯一决策函数（= HMCL computeRunDirectory）：游戏内容目录（user.dir / CWD）。
+ (NSString *)runDirectoryForProfile:(NSDictionary *)profile;
+ (NSString *)runDirectoryForProfile:(NSDictionary *)profile
                           versionId:(nullable NSString *)versionId;

/// runDirectory 下的子目录绝对路径（saves / mods / config / logs ...）
+ (NSString *)pathForProfile:(NSDictionary *)profile subdir:(NSString *)subdir;

/// 把任意路径解析成绝对路径：绝对路径原样返回，相对路径相对主目录解析。
+ (NSString *)absolutePath:(NSString *)path;

#pragma mark - 模式

/// 读取 profile 的隔离模式；没有显式 isolation key 时由旧 gameDir 推导（兼容存量数据）。
/// versionId 传 nil 表示用 profile 自身的 lastVersionId。
+ (AMEDirIsolation)isolationForProfile:(NSDictionary *)profile;
+ (AMEDirIsolation)isolationForProfile:(NSDictionary *)profile
                             versionId:(nullable NSString *)versionId;

/// 是否处于隔离状态（整合包 profile 恒为 YES）
+ (BOOL)profileIsIsolated:(NSDictionary *)profile;

/// 是否是整合包 profile（type == "modpack"，或 gameDir 位于 custom_gamedir 下）
+ (BOOL)isModpackProfile:(NSDictionary *)profile;

/// 写入 isolation key 并同步 gameDir 字段（gameDir 仍是老代码与 Java 端的兜底）
+ (void)setIsolation:(AMEDirIsolation)isolation forProfile:(NSMutableDictionary *)profile;

/// 由隔离模式推导应写入 profile.gameDir 的值
+ (NSString *)gameDirValueForIsolation:(AMEDirIsolation)isolation profile:(NSDictionary *)profile;

/// 全局默认策略（general.default_isolation）：新建 profile 时求值一次并固化。
/// modded = 是否带 Mod 加载器（Fabric/Forge/NeoForge/Quilt/OptiFine）。
+ (void)applyDefaultIsolationToProfile:(NSMutableDictionary *)profile modded:(BOOL)modded;

/// UI 展示值：shared → 主目录名；version → versions/<id>；custom → gameDir
+ (NSString *)displayValueForProfile:(NSDictionary *)profile;

#pragma mark - 安全检查

/// 删除 versions/<id> 整目录前调用：只要有任何 profile 的运行目录位于其中（或就是它），
/// 就返回 YES —— 调用方必须改成只删版本二进制，否则会连带毁掉用户存档。
+ (BOOL)isVersionDirectoryReferencedByProfiles:(NSString *)versionDir;

@end

NS_ASSUME_NONNULL_END
