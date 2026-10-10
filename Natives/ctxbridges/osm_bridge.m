#import <Foundation/Foundation.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
#include <pthread.h>
#include "environ.h"
#include "utils.h"

#include "bridge_tbl.h"
#include "osm_bridge.h"
#include "osmesa_internal.h"

static osmesa_library handle;

void dlsym_OSMesa() {
    void* dl_handle = dlopen([NSString stringWithFormat:@"@rpath/%s", getenv("AMETHYST_RENDERER")].UTF8String, RTLD_GLOBAL);
    assert(dl_handle);
    handle.OSMesaMakeCurrent = dlsym(dl_handle,"OSMesaMakeCurrent");
    handle.OSMesaGetCurrentContext = dlsym(dl_handle,"OSMesaGetCurrentContext");
    handle.OSMesaCreateContext = dlsym(dl_handle, "OSMesaCreateContext");
    handle.OSMesaCreateContextAttribs = dlsym(dl_handle, "OSMesaCreateContextAttribs");
    handle.OSMesaDestroyContext = dlsym(dl_handle, "OSMesaDestroyContext");
    handle.OSMesaPixelStore = dlsym(dl_handle,"OSMesaPixelStore");
    handle.glGetString = dlsym(dl_handle,"glGetString");
    handle.glClearColor = dlsym(dl_handle, "glClearColor");
    handle.glClear = dlsym(dl_handle,"glClear");
    handle.glFinish = dlsym(dl_handle,"glFinish");
}

bool osm_init() {
    dlsym_OSMesa();
    return true; // no more specific initialization required
}

// OSMesa/zink 单屏约束：整个进程只有一个可用的底层 screen（zink 基于一个
// MoltenVK screen 实现），但 GLFW shim 路径（MC 26.x 隐藏工具窗，Task193 形态）
// 会再调一次 pojavCreateContext。无条件再建 OSMesaContext（第二次 br_init_context）
// 会与主 context 争抢同一个 zink screen —— 新建 context 一 current，主线程既有的
// LWJGL 状态（GL caps、函数指针）即失效：下一次 glCreateShader 返回 0、info log 为空、
// GL_COMPILE_STATUS=GL_FALSE，即 Angelica fontFilter 崩溃（latestlog3/4 11530）。
// 复用它进程内首个 bundle（与 SDL 路径 ame_SDL_GL_CreateContext 复用 g_glContext、
// Task193 层→表面单例同一思路：单游戏视图单渲染器，第二个请求只是能力查询）。
static osm_render_window_t* s_osm_primary = NULL;

osm_render_window_t* osm_init_context(osm_render_window_t* share) {
    // 二次请求直接复用首个 bundle，绝不再建第二个 zink/OSMesa 上下文。
    if (s_osm_primary != NULL) {
        NSLog(@"[OSMBridge] reuse primary bundle=%p for second context request (share=%p), "
              @"single OSMesa/zink screen", s_osm_primary, share);
        return s_osm_primary;
    }

    osm_render_window_t* render_window = calloc(1, sizeof(osm_render_window_t));
    OSMesaContext context = NULL;

    // 优先请求 core profile 上下文：Angelica/Celeritas 等新式渲染器要求 core
    // profile（日志 "Non-core GL context (profile mask 0x2); FFP emulation requires
    // a core profile"），而经典 OSMesaCreateContext 只会创建 compatibility profile。
    // Mesa >= 11.2（本构成为 Mesa 25.0.7）支持 OSMesaCreateContextAttribs 的
    // OSMESA_PROFILE=OSMESA_CORE_PROFILE + OSMESA_CONTEXT_MAJOR/MINOR_VERSION。
    // 请求 GL 3.3 core（Angelica 的最低要求；zink 实际会回 4.x core），
    // 若该入口或 core 上下文创建失败则回落到经典 compat API。
    // 逃生开关：AMETHYST_ZINK_COMPAT_PROFILE=1 强制保留 compatibility profile
    // （给显式依赖固定管线 glBegin/glMatrixMode 的老旧整合包用），无需重新构建。
    const char *forceCompat = getenv("AMETHYST_ZINK_COMPAT_PROFILE");
    const BOOL wantCore = handle.OSMesaCreateContextAttribs != NULL &&
                          !(forceCompat && forceCompat[0] == '1');
    if (wantCore) {
        const int coreAttribs[] = {
            OSMESA_FORMAT, OSMESA_RGBA,
            OSMESA_PROFILE, OSMESA_CORE_PROFILE,
            OSMESA_CONTEXT_MAJOR_VERSION, 3,
            OSMESA_CONTEXT_MINOR_VERSION, 3,
            0
        };
        context = handle.OSMesaCreateContextAttribs(coreAttribs,
                                                    share ? share->context : NULL);
        if (!context) {
            NSLog(@"OSMBridge: core profile context creation failed, falling back to compatibility profile");
        }
    } else if (forceCompat && forceCompat[0] == '1') {
        NSLog(@"OSMBridge: AMETHYST_ZINK_COMPAT_PROFILE=1, using compatibility profile");
    } else {
        NSLog(@"OSMBridge: OSMesaCreateContextAttribs unavailable, using legacy compatibility profile");
    }
    if (!context) {
        context = handle.OSMesaCreateContext(GL_RGBA, share ? share->context : NULL);
    }
    if (!context) {
        NSLog(@"OSMBridge: FAILED to create context");
        free(render_window);
        return NULL;
    }
    render_window->context = context;
    if (s_osm_primary == NULL) {
        s_osm_primary = render_window;
    }
    return render_window;
}

// 记录最后一次 OSMesaMakeCurrent 所在线程。仅当“同线程”才可按尺寸跳过重绑；
// 仅凭尺寸匹配提前返回会把线程留在“无 current context”状态——GLFW shim 路径
// 二次 pojavCreateContext 舞蹈（make-current → window=0 解绑 → 重绑同 bundle）
// 后，Client 线程 glCreateShader 返回 0、info log 为空、GL_COMPILE_STATUS=GL_FALSE，
// 即 fontFilter 崩溃（latestlog3 1069/1624/1660）。
static pthread_t s_osm_bind_thread = (pthread_t)0;

void osm_apply_current_ll() {
    if (pthread_equal(s_osm_bind_thread, pthread_self()) &&
        currentBundle->osm.width == windowWidth && currentBundle->osm.height == windowHeight) {
        return;
    }

    if (currentBundle->osm.width != windowWidth || currentBundle->osm.height != windowHeight) {
        currentBundle->osm.width = windowWidth;
        currentBundle->osm.height = windowHeight;
        currentBundle->osm.buffer = reallocf(currentBundle->osm.buffer, windowWidth * windowHeight * 4);
    }

    handle.OSMesaMakeCurrent(currentBundle->osm.context, currentBundle->osm.buffer, GL_UNSIGNED_BYTE, currentBundle->osm.width, currentBundle->osm.height);
    handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, currentBundle->osm.width);
    handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
    s_osm_bind_thread = pthread_self();
}

void osm_make_current(osm_render_window_t* bundle) {
    if(!bundle) {
        // 仅解绑本线程并清除线程标记，强制下一次 osm_apply_current_ll 真正重绑。
        // 绝不释放 bundle 的 buffer/color_space：bundle 可能已被其他线程（Client）
        // 共享（s_osm_primary 复用），此时 free 会造成 use-after-free。
        currentBundle = NULL;
        s_osm_bind_thread = (pthread_t)0;
        handle.OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
        return;
    }

    currentBundle = (basic_render_window_t *)bundle;
    if (!currentBundle->osm.color_space) {
        currentBundle->osm.color_space = CGColorSpaceCreateDeviceRGB();
    }
    osm_apply_current_ll();
}

void osm_swap_buffers() {
    osm_apply_current_ll();
    handle.glFinish(); // this will force osmesa to write the last rendered image into the buffer
    osm_render_window_t bundle = currentBundle->osm;
    dispatch_async(dispatch_get_main_queue(), ^{
    CGDataProviderRef bitmapProvider = CGDataProviderCreateWithData(NULL, bundle.buffer, windowWidth * windowHeight * 4, NULL);
    CGImageRef bitmap = CGImageCreate(windowWidth, windowHeight, 8, 32, 4 * windowWidth, bundle.color_space, kCGImageAlphaNoneSkipLast | kCGBitmapByteOrderDefault, bitmapProvider, NULL, FALSE, kCGRenderingIntentDefault);
    SurfaceViewController.surface.layer.contents = (__bridge id)bitmap;
    CGImageRelease(bitmap);
    CGDataProviderRelease(bitmapProvider);
    });
}

void osm_swap_interval(int swapInterval) {
    // Nothing to do here
}

void osm_terminate() {
    // Nothing to do here
}

void set_osm_bridge_tbl() {
    br_init = osm_init;
    br_init_context = (br_init_context_t) osm_init_context;
    br_make_current = (br_make_current_t) osm_make_current;
    br_swap_buffers = osm_swap_buffers;
    br_swap_interval = osm_swap_interval;
    br_terminate = osm_terminate;
}
