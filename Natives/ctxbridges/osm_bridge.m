#import <Foundation/Foundation.h>
#import "SurfaceViewController.h"

#include <dlfcn.h>
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

osm_render_window_t* osm_init_context(osm_render_window_t* share) {
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
    return render_window;
}

void osm_apply_current_ll() {
    if (currentBundle->osm.width == windowWidth && currentBundle->osm.height == windowHeight) {
        return;
    }

    currentBundle->osm.width = windowWidth;
    currentBundle->osm.height = windowHeight;
    currentBundle->osm.buffer = reallocf(currentBundle->osm.buffer, windowWidth * windowHeight * 4);

    handle.OSMesaMakeCurrent(currentBundle->osm.context, currentBundle->osm.buffer, GL_UNSIGNED_BYTE, currentBundle->osm.width, currentBundle->osm.height);
    handle.OSMesaPixelStore(OSMESA_ROW_LENGTH, currentBundle->osm.width);
    handle.OSMesaPixelStore(OSMESA_Y_UP, 0);
}

void osm_make_current(osm_render_window_t* bundle) {
    if(!bundle) {
        free(currentBundle->osm.buffer);
        CGColorSpaceRelease(currentBundle->osm.color_space);
        currentBundle->osm.buffer = NULL;
        currentBundle->osm.color_space = NULL;
        currentBundle->osm.width = currentBundle->osm.height = 0;
        currentBundle = NULL;
        //technically this does nothing as its not possible to unbind a context in OSMesa
        handle.OSMesaMakeCurrent(NULL, NULL, 0, 0, 0);
        return;
    }

    currentBundle = (basic_render_window_t *)bundle;
    currentBundle->osm.color_space = CGColorSpaceCreateDeviceRGB();
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
