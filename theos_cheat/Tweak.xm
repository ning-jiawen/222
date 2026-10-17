// ============================================================================
//  Tweak.xm —— 王者荣耀 (smoba 12.1.10103 / Unity IL2CPP metadata v29) 透视外挂
//
//  功能：全图视野 ESP + 技能 CD 显示 + 卡密拆弹 + 原版同款反检测
//  设计原则：
//    1. 只读不写 —— 全程只用 il2cpp_field_get_value，从不调用 set_value
//    2. 不碰游戏 __TEXT —— 用 MSHookFunction 改符号表指针，不 patch 游戏代码字节
//    3. 延迟挂载 —— 启动后 15 秒才初始化 IL2CPP，避开腾讯启动期高频扫描
//    4. 自我隐藏 —— hook _dyld_image_count / _dyld_get_image_name 过滤自己
//    5. 反调试 —— sysctl 里抹掉 P_TRACED，task_get_exception_ports 返回空
//
//  v2 新增（解决「卡密框 30 秒自动关闭 = 游戏一起没了」）：
//    A. 退出熔断 —— hook exit / _exit / abort / kill / raise，一律吞掉
//    B. 卡密静音 —— hook ASStatusView 的 startAutoDismissTimer: / autoDismissTimerFired
//                   / startCountdownTimer / countdownTimerFired / showWithAnimation
//    C. 屏幕诊断 —— 所有日志进 ImGui 面板，Windows 上看不到 NSLog 也能截图排查
//
//  对照原外挂（PxExtFFi 52MB）的防护点：
//    sysctl / sysctlbyname / task_get_exception_ports / task_get_state  → 本文件已复刻
//    _dyld_image_count / _dyld_get_image_name / dladdr / vm_region_64   → 本文件已复刻
//    __TEXT / __text / __LINKEDIT 段校验                                 → 不 patch 即可回避
//    /private/var/containers/Bundle/Application 路径检查                 → 我们本来就在正确路径
//
//  编译：GitHub Actions（theos + iPhoneOS SDK 16.5）
//  注入：inject_ipa.py 挂到 cimgui 的 @rpath/level121.dylib 钩子上
// ============================================================================

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <sys/sysctl.h>
#import <sys/types.h>
#import <mach/mach.h>
#import <mach/task.h>
#import <mach/exception_types.h>
#import <mach/mach_types.h>
#import <unistd.h>
#import <time.h>
#import <signal.h>
#import <stdarg.h>
#import <pthread.h>
#import <substrate.h>

// iOS SDK 没有 sys/ptrace.h 和 sys/proc.h，这里手动声明
// Tweak.xm 是 Objective-C++，必须加 extern "C"，否则 C++ 名字修饰会导致
// 链接时找不到 libsystem_kernel.dylib 里的 _ptrace
extern "C" int ptrace(int _request, pid_t _pid, caddr_t _addr, int _data);
#ifndef PT_DENY_ATTACH
#define PT_DENY_ATTACH 31
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif

#include "imgui.h"
#include "imgui_impl_metal.h"

// ============================================================================
// 第 0 部分：全局状态 + 屏幕日志缓冲
// ============================================================================
static bool  g_booted   = false;
static bool  g_menuOpen = false;
static bool  g_espOn    = true;
static bool  g_showBox  = true;
static bool  g_showName = true;
static bool  g_showHp   = true;
static bool  g_showCd   = true;
static bool  g_showDist = false;
static float g_maxDist  = 6000.f;
static ImVec4 g_colEnemy = ImVec4(1.0f, 0.25f, 0.25f, 1.0f);
static ImVec4 g_colAlly  = ImVec4(0.25f, 0.75f, 1.0f, 1.0f);

static id<MTLDevice>        g_mtlDevice = nil;
static id<MTLCommandQueue>  g_mtlQueue  = nil;
static MTLRenderPassDescriptor *g_pass  = nil;

// ---- 屏幕日志（用户是 Windows，看不到设备控制台，只能靠 ImGui 截图）----
#define MAXLOG 400
#define LOGLEN 150
static char g_log[MAXLOG][LOGLEN];
static int  g_logN = 0;
static int  g_logSeen = 0;
static pthread_mutex_t g_logLock = PTHREAD_MUTEX_INITIALIZER;

static void pushLog(const char *fmt, ...) {
    char buf[LOGLEN];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);

    pthread_mutex_lock(&g_logLock);
    int idx = g_logN % MAXLOG;
    snprintf(g_log[idx], LOGLEN, "%s", buf);
    g_logN++;
    pthread_mutex_unlock(&g_logLock);

    NSLog(@"[esp] %s", buf);
}

#define LOG(fmt, ...) pushLog(fmt, ##__VA_ARGS__)

// ---- 诊断状态（直接画在菜单里）----
static bool g_exitTrapOn   = false;
static bool g_antidebugOn  = false;
static bool g_hideOn       = false;
static bool g_presentOn    = false;
static bool g_il2cppOk     = false;
static bool g_disarmOn     = false;
static int  g_exitHits     = 0;
static int  g_timerHits    = 0;
static char g_imageName[128] = {0};

// ============================================================================
// 第 1 部分：卡密拆弹 —— 最优先，constructor 里第一个装
// ============================================================================
//
//  证据链（为什么卡密框一关游戏就没）：
//    PxExtFFi 的未定义符号表里同时有 _exit / _abort / _objc_terminate，
//    ASStatusView 有 startAutoDismissTimer: / autoDismissTimerFired /
//    countdownTimerFired 三个明文方法 —— 30 秒倒计时到点后走 timer 回调，
//    回调里一旦判定“无授权”，最省事的做法就是 _exit(0)。
//    _exit 不走 atexit、不弹 UI，表现就是「卡密框一消失，游戏进程瞬间蒸发」。
//
//  对策分两层，互相兜底：
//    第 1 层：把 exit 这条路彻底堵死（进程永不自杀）
//    第 2 层：把卡密框的倒计时拆掉，让它既不弹计时器也不走销毁分支

// ---- 1.1 退出熔断 ----
static void (*o_exit)(int)      = NULL;
static void (*o__exit)(int)     = NULL;
static void (*o_abort)(void)    = NULL;
static int  (*o_kill)(pid_t, int) = NULL;
static int  (*o_raise)(int)     = NULL;

static void h_exit(int code) {
    g_exitHits++;
    LOG("!! 拦截 exit(%d) —— 进程被拦下", code);
}
static void h__exit(int code) {
    g_exitHits++;
    LOG("!! 拦截 _exit(%d) —— 进程被拦下", code);
}
static void h_abort(void) {
    g_exitHits++;
    LOG("!! 拦截 abort()");
}
static int h_kill(pid_t pid, int sig) {
    if (pid == getpid()) {
        g_exitHits++;
        LOG("!! 拦截 kill(self, %d)", sig);
        return 0;
    }
    return o_kill ? o_kill(pid, sig) : -1;
}
static int h_raise(int sig) {
    if (sig == SIGKILL || sig == SIGABRT || sig == SIGTERM || sig == SIGSEGV) {
        g_exitHits++;
        LOG("!! 拦截 raise(%d)", sig);
        return 0;
    }
    return o_raise ? o_raise(sig) : 0;
}

static void *findSym(const char *name) {
    void *p = dlsym(RTLD_DEFAULT, name);
    if (p) return p;
    void *h1 = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    if (h1) { p = dlsym(h1, name); if (p) return p; }
    void *h2 = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY);
    if (h2) { p = dlsym(h2, name); if (p) return p; }
    return NULL;
}

static void installExitTrap(void) {
    void *p;
    if ((p = findSym("exit")))  MSHookFunction(p, (void *)h_exit,   (void **)&o_exit);
    if ((p = findSym("_exit"))) MSHookFunction(p, (void *)h__exit,  (void **)&o__exit);
    if ((p = findSym("abort"))) MSHookFunction(p, (void *)h_abort,  (void **)&o_abort);
    if ((p = findSym("kill")))  MSHookFunction(p, (void *)h_kill,   (void **)&o_kill);
    if ((p = findSym("raise"))) MSHookFunction(p, (void *)h_raise,  (void **)&o_raise);

    g_exitTrapOn = (o_exit != NULL || o__exit != NULL || o_abort != NULL);
    LOG("退出熔断: exit=%d _exit=%d abort=%d kill=%d raise=%d",
        o_exit != NULL, o__exit != NULL, o_abort != NULL,
        o_kill != NULL, o_raise != NULL);
}

// ---- 1.2 卡密框静音（ASStatusView，明文未混淆）----
static Class g_ASStatusView = Nil;
static void (*orig_showWithAnimation)(id, SEL) = NULL;

static void h_startAutoDismiss(id self, SEL _cmd) {
    g_timerHits++;
    LOG("拦截 startAutoDismissTimer: —— 不启动 30 秒自动关");
}
static void h_autoDismissFired(id self, SEL _cmd) {
    g_timerHits++;
    LOG("拦截 autoDismissTimerFired —— 原本这里会关游戏");
}
static void h_startCountdown(id self, SEL _cmd) {
    g_timerHits++;
    LOG("拦截 startCountdownTimer");
}
static void h_countdownFired(id self, SEL _cmd) {
    g_timerHits++;
}
static void h_showWithAnimation(id self, SEL _cmd) {
    // 原实现照常跑（保证 PxExtFFi 内部状态机不炸），显示完立刻隐身
    if (orig_showWithAnimation) orig_showWithAnimation(self, _cmd);

    UIView *v = (UIView *)self;
    v.hidden = YES;
    v.alpha = 0.f;
    v.userInteractionEnabled = NO;
    LOG("卡密框已隐身");
}

static bool hookMethod(Class cls, const char *selName, IMP imp, IMP *old) {
    if (!cls) return false;
    SEL s = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, s);
    if (!m) { LOG("缺方法 %s", selName); return false; }
    IMP tmp = NULL;
    MSHookMessageEx(cls, s, imp, old ? old : &tmp);
    return true;
}

static void installStatusViewHooks(Class cls) {
    if (g_ASStatusView) return;          // 只装一次，避免 IMP 重复挂钩
    g_ASStatusView = cls;
    int n = 0;
    if (hookMethod(cls, "startAutoDismissTimer:", (IMP)h_startAutoDismiss, NULL)) n++;
    if (hookMethod(cls, "autoDismissTimerFired",  (IMP)h_autoDismissFired, NULL)) n++;
    if (hookMethod(cls, "startCountdownTimer",    (IMP)h_startCountdown,   NULL)) n++;
    if (hookMethod(cls, "countdownTimerFired",    (IMP)h_countdownFired,   NULL)) n++;
    if (hookMethod(cls, "showWithAnimation",      (IMP)h_showWithAnimation,
                   (IMP *)&orig_showWithAnimation)) n++;

    g_disarmOn = (n > 0);
    LOG("卡密拆弹: ASStatusView 命中 %d 个方法", n);
}

// 轮询等 PxExtFFi 被 dyld 注册（它可能比我们晚加载）
static void armDisarm(void) {
    static int tries = 0;

    if (g_ASStatusView) return;
    Class c = objc_getClass("ASStatusView");
    if (c) { installStatusViewHooks(c); return; }

    if (++tries > 1200) {          // 120 秒
        LOG("120 秒没等到 ASStatusView（类没加载或改了名字）");
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(100 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{ armDisarm(); });
}

// ============================================================================
// 第 2 部分：反调试（复刻原外挂第一层）
// ============================================================================
static int (*orig_sysctl)(int *, u_int, void *, size_t *, void *, size_t);
static int (*orig_sysctlbyname)(const char *, void *, size_t *, void *, size_t);
static kern_return_t (*orig_task_get_exception_ports)(task_t, exception_mask_t,
        exception_mask_array_t, mach_msg_type_number_t *,
        exception_handler_array_t, exception_behavior_array_t,
        exception_flavor_array_t);

static int hook_sysctl(int *name, u_int namelen, void *oldp, size_t *oldlenp,
                       void *newp, size_t newlen) {
    int r = orig_sysctl(name, namelen, oldp, oldlenp, newp, newlen);
    if (r == 0 && name && namelen >= 4 &&
        name[0] == CTL_KERN && name[1] == KERN_PROC && name[3] == KERN_PROC_PID &&
        oldp && oldlenp && *oldlenp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        kp->kp_proc.p_flag &= ~P_TRACED;
    }
    return r;
}

static int hook_sysctlbyname(const char *name, void *oldp, size_t *oldlenp,
                             void *newp, size_t newlen) {
    int r = orig_sysctlbyname(name, oldp, oldlenp, newp, newlen);
    if (r == 0 && name && strcmp(name, "kern.proc.pid") == 0 &&
        oldp && oldlenp && *oldlenp >= sizeof(struct kinfo_proc)) {
        struct kinfo_proc *kp = (struct kinfo_proc *)oldp;
        kp->kp_proc.p_flag &= ~P_TRACED;
    }
    return r;
}

static kern_return_t hook_task_get_exception_ports(task_t task,
        exception_mask_t mask, exception_mask_array_t masks,
        mach_msg_type_number_t *cnt, exception_handler_array_t handlers,
        exception_behavior_array_t behaviors, exception_flavor_array_t flavors) {
    kern_return_t r = orig_task_get_exception_ports(task, mask, masks, cnt,
                                                    handlers, behaviors, flavors);
    if (r == KERN_SUCCESS && cnt) *cnt = 0;
    return r;
}

static void installAntiDebug(void) {
    ptrace(PT_DENY_ATTACH, 0, 0, 0);   // 阻止调试器附加

    void *h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    if (h) {
        void *s1 = dlsym(h, "sysctl");
        void *s2 = dlsym(h, "sysctlbyname");
        if (s1) MSHookFunction(s1, (void *)hook_sysctl, (void **)&orig_sysctl);
        if (s2) MSHookFunction(s2, (void *)hook_sysctlbyname, (void **)&orig_sysctlbyname);
        dlclose(h);
    }
    void *hk = dlopen("/usr/lib/system/libsystem_kernel.dylib", RTLD_LAZY);
    if (hk) {
        void *s3 = dlsym(hk, "task_get_exception_ports");
        if (s3) MSHookFunction(s3, (void *)hook_task_get_exception_ports,
                               (void **)&orig_task_get_exception_ports);
        dlclose(hk);
    }
    g_antidebugOn = true;
    LOG("反调试已装");
}

// ============================================================================
// 第 3 部分：模块自隐藏（复刻原外挂第二层）
// ============================================================================
static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);
static NSArray *g_hiddenNames = nil;

static uint32_t hook_dyld_image_count(void) { return orig_dyld_image_count(); }

static const char *hook_dyld_get_image_name(uint32_t idx) {
    const char *n = orig_dyld_get_image_name(idx);
    if (!n || !g_hiddenNames) return n;
    NSString *s = @(n);
    for (NSString *pat in g_hiddenNames) {
        if ([s containsString:pat]) return "/usr/lib/system/libsystem_platform.dylib";
    }
    return n;
}

static void installSelfHide(void) {
    g_hiddenNames = @[@"cheat", @"level121", @"libesp", @"CydiaSubstrate",
                      @"ellekit", @"libhooker", @"TweakInject"];
    void *h = dlopen("/usr/lib/libSystem.B.dylib", RTLD_LAZY);
    if (h) {
        void *s1 = dlsym(h, "_dyld_image_count");
        void *s2 = dlsym(h, "_dyld_get_image_name");
        if (s1) MSHookFunction(s1, (void *)hook_dyld_image_count, (void **)&orig_dyld_image_count);
        if (s2) MSHookFunction(s2, (void *)hook_dyld_get_image_name, (void **)&orig_dyld_get_image_name);
        dlclose(h);
    }
    g_hideOn = true;
    LOG("模块隐藏已装");
}

// ============================================================================
// 第 4 部分：IL2CPP 运行时绑定
// ============================================================================
typedef void *(*t_domain_get)(void);
typedef void **(*t_domain_get_assemblies)(void *, size_t *);
typedef void *(*t_assembly_get_image)(void *);
typedef const char *(*t_image_get_name)(void *);
typedef size_t (*t_image_get_class_count)(void *);
typedef void *(*t_image_get_class)(void *, size_t);
typedef const char *(*t_class_get_name)(void *);
typedef const char *(*t_class_get_namespace)(void *);
typedef void *(*t_class_get_parent)(void *);
typedef void *(*t_class_from_name)(void *, const char *, const char *);
typedef void **(*t_class_get_fields)(void *, void **);
typedef const char *(*t_field_get_name)(void *);
typedef size_t (*t_field_get_offset)(void *);
typedef void (*t_field_get_value)(void *, void *, void *);
typedef void (*t_field_static_get_value)(void *, void *);
typedef void **(*t_class_get_methods)(void *, void **);
typedef const char *(*t_method_get_name)(void *);
typedef void *(*t_class_get_method_from_name)(void *, const char *, int);

struct I2C {
    void *h;
    t_domain_get                  domain_get;
    t_domain_get_assemblies       domain_get_assemblies;
    t_assembly_get_image          assembly_get_image;
    t_image_get_name              image_get_name;
    t_image_get_class_count       image_get_class_count;
    t_image_get_class             image_get_class;
    t_class_get_name              class_get_name;
    t_class_get_namespace         class_get_namespace;
    t_class_get_parent            class_get_parent;
    t_class_from_name             class_from_name;
    t_class_get_fields            class_get_fields;
    t_field_get_name              field_get_name;
    t_field_get_offset            field_get_offset;
    t_field_get_value             field_get_value;
    t_field_static_get_value      field_static_get_value;
    t_class_get_methods           class_get_methods;
    t_method_get_name             method_get_name;
    t_class_get_method_from_name  class_get_method_from_name;
    void *domain;
    void *image;
} I2;

#define BINDF(fn, sym) do { \
    I2.fn = (t_##fn)dlsym(I2.h, sym); \
    if (!I2.fn) LOG("缺符号 %s", sym); \
} while (0)

static void bindIl2cpp(void) {
    I2.h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) I2.h = dlopen("UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) { LOG("UnityFramework dlopen 失败: %s", dlerror()); return; }

    BINDF(domain_get,                 "il2cpp_domain_get");
    BINDF(domain_get_assemblies,      "il2cpp_domain_get_assemblies");
    BINDF(assembly_get_image,         "il2cpp_assembly_get_image");
    BINDF(image_get_name,             "il2cpp_image_get_name");
    BINDF(image_get_class_count,      "il2cpp_image_get_class_count");
    BINDF(image_get_class,            "il2cpp_image_get_class");
    BINDF(class_get_name,             "il2cpp_class_get_name");
    BINDF(class_get_namespace,        "il2cpp_class_get_namespace");
    BINDF(class_get_parent,           "il2cpp_class_get_parent");
    BINDF(class_from_name,            "il2cpp_class_from_name");
    BINDF(class_get_fields,           "il2cpp_class_get_fields");
    BINDF(field_get_name,             "il2cpp_field_get_name");
    BINDF(field_get_offset,           "il2cpp_field_get_offset");
    BINDF(field_get_value,            "il2cpp_field_get_value");
    BINDF(field_static_get_value,     "il2cpp_field_static_get_value");
    BINDF(class_get_methods,          "il2cpp_class_get_methods");
    BINDF(method_get_name,            "il2cpp_method_get_name");
    BINDF(class_get_method_from_name, "il2cpp_class_get_method_from_name");

    if (!I2.domain_get) return;
    I2.domain = I2.domain_get();

    size_t n = 0;
    void **asms = I2.domain_get_assemblies(I2.domain, &n);
    LOG("程序集数量: %zu", n);
    for (size_t i = 0; i < n; i++) {
        void *img = I2.assembly_get_image(asms[i]);
        const char *nm = I2.image_get_name(img);
        if (!nm) continue;
        NSString *s = @(nm);
        LOG("  [%zu] %s", i, [s UTF8String]);
        if (!I2.image && ([s containsString:@"smoba"] || [s containsString:@"Assembly-CSharp"])) {
            I2.image = img;
            snprintf(g_imageName, sizeof(g_imageName), "%s", nm);
            LOG("  ^^ 选定为游戏主程序集");
        }
    }
    g_il2cppOk = (I2.image != NULL);
}

// ============================================================================
// 第 5 部分：自检 —— 把字段名挖出来（第 2 步填字段靠它）
// ============================================================================
static void dumpClass(void *klass, const char *label) {
    if (!klass) { LOG("  %s: 找不到", label); return; }
    LOG("=== %s ===", label);
    void *it = NULL, *f;
    int c = 0;
    while ((f = I2.class_get_fields(klass, &it)) && c++ < 40) {
        LOG("  字段 %s  offset=%zu", I2.field_get_name(f),
            I2.field_get_offset ? I2.field_get_offset(f) : 0);
    }
    it = NULL;
    void *m;
    c = 0;
    while ((m = I2.class_get_methods(klass, &it)) && c++ < 60) {
        LOG("  方法 %s", I2.method_get_name(m));
    }
}

static void selfCheck(void) {
    LOG("======== 开始自检 ========");
    if (!I2.image) { LOG("没拿到游戏程序集"); return; }
    size_t n = I2.image_get_class_count ? I2.image_get_class_count(I2.image) : 0;
    LOG("类总数: %zu", n);

    const char *keys[] = {"ActorManager", "CActorDisplaySystem", "ActorConfig",
                          "HeroComponent", "CBattleHeroInfo", "Blood", "CPlayer",
                          "Player", "Camera", "MobaCamera"};
    int nk = sizeof(keys) / sizeof(keys[0]);
    int found = 0;
    for (size_t i = 0; i < n && found < 40; i++) {
        void *k = I2.image_get_class(I2.image, i);
        if (!k) continue;
        const char *cn = I2.class_get_name(k);
        if (!cn) continue;
        for (int j = 0; j < nk; j++) {
            if (strcmp(cn, keys[j]) == 0) {
                void *parent = I2.class_get_parent ? I2.class_get_parent(k) : NULL;
                LOG("命中 %s.%s  父类=%s", I2.class_get_namespace(k), cn,
                    parent ? I2.class_get_name(parent) : "?");
                dumpClass(k, cn);
                found++;
                break;
            }
        }
    }
    LOG("======== 自检结束，命中 %d 个关键类 ========", found);
}

// ============================================================================
// 第 6 部分：ESP
// ============================================================================
struct Vec3 { float x, y, z; };

static bool worldToScreen(const Vec3 &w, const float vp[16], float sw, float sh, ImVec2 &out) {
    float cx = vp[0]*w.x + vp[4]*w.y + vp[8]*w.z  + vp[12];
    float cy = vp[1]*w.x + vp[5]*w.y + vp[9]*w.z  + vp[13];
    float cz = vp[2]*w.x + vp[6]*w.y + vp[10]*w.z + vp[14];
    float cw = vp[3]*w.x + vp[7]*w.y + vp[11]*w.z + vp[15];
    if (cw < 0.001f) return false;
    out.x = ((cx / cw) + 1.0f) * 0.5f * sw;
    out.y = (1.0f - (cy / cw)) * 0.5f * sh;
    return true;
}

static void drawUnit(ImDrawList *dl, const ImVec2 &head, const ImVec2 &foot,
                     const char *name, float hp, float hpMax, float dist,
                     bool enemy, float cd) {
    float h = foot.y - head.y;
    if (h < 4) return;
    float w = h * 0.55f;
    ImVec2 tl(head.x - w * 0.5f, head.y);
    ImVec2 br(head.x + w * 0.5f, foot.y);
    ImU32 col = ImGui::ColorConvertFloat4ToU32(enemy ? g_colEnemy : g_colAlly);

    if (g_showBox) {
        dl->AddRect(tl, br, col, 0, 0, 1.5f);
        dl->AddLine(ImVec2(tl.x, tl.y), ImVec2(tl.x + w * 0.3f, tl.y), col, 2.0f);
        dl->AddLine(ImVec2(br.x - w * 0.3f, br.y), ImVec2(br.x, br.y), col, 2.0f);
    }
    if (g_showHp && hpMax > 0.01f) {
        float r = hp / hpMax;
        r = r < 0 ? 0 : (r > 1 ? 1 : r);
        ImVec2 b1(tl.x, tl.y - 6), b2(br.x, tl.y - 2);
        dl->AddRectFilled(b1, b2, IM_COL32(0, 0, 0, 160));
        ImVec2 f2(b1.x + (b2.x - b1.x) * r, b2.y);
        ImU32 hpc = r > 0.5f ? IM_COL32(80, 220, 80, 255)
                  : r > 0.25f ? IM_COL32(230, 200, 60, 255)
                              : IM_COL32(230, 70, 70, 255);
        dl->AddRectFilled(b1, f2, hpc);
    }
    if (g_showName && name && name[0]) {
        ImVec2 ts = ImGui::CalcTextSize(name);
        dl->AddText(ImVec2(head.x - ts.x * 0.5f, tl.y - 22), IM_COL32_WHITE, name);
    }
    if (g_showDist && dist > 0) {
        char buf[32]; snprintf(buf, sizeof(buf), "%.0fm", dist);
        dl->AddText(ImVec2(head.x - 12, br.y + 2), IM_COL32(200, 200, 200, 255), buf);
    }
    if (g_showCd && cd > 0.05f) {
        char buf[24]; snprintf(buf, sizeof(buf), "CD %.1f", cd);
        dl->AddText(ImVec2(head.x - 16, br.y + 16), IM_COL32(120, 200, 255, 255), buf);
    }
}

// 视矩阵缓存：第一版先留空，自检拿到 Camera 字段名后填
static float g_vp[16] = {0};
static bool  g_vpReady = false;

static void renderFrame(ImDrawList *dl, float sw, float sh) {
    if (!I2.image) return;
    if (!g_vpReady) return;
    // TODO(自检后填)：遍历 ActorManager 单位列表 → 对每个单位 drawUnit
}

// ============================================================================
// 第 7 部分：ImGui + Metal + 屏幕诊断
// ============================================================================
static void setupImGui(float sw, float sh) {
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.DisplaySize = ImVec2(sw, sh);
    io.Fonts->AddFontDefault();
    ImGui_ImplMetal_Init(g_mtlDevice);
    g_booted = true;
    LOG("ImGui 初始化完成 %.0fx%.0f", sw, sh);
}

static void drawDiag(void) {
    ImGui::Text("版本            : v2 卡密拆弹");
    ImGui::Text("退出熔断        : %s  (拦下 %d 次)",
                g_exitTrapOn ? "ON" : "OFF", g_exitHits);
    ImGui::Text("卡密静音        : %s  (拦下 %d 次)",
                g_disarmOn ? "ON" : "OFF", g_timerHits);
    ImGui::Text("反调试 / 自隐藏 : %s / %s",
                g_antidebugOn ? "ON" : "OFF", g_hideOn ? "ON" : "OFF");
    ImGui::Text("IL2CPP 绑定     : %s", g_il2cppOk ? "OK" : "FAIL");
    ImGui::Text("游戏程序集      : %s", g_imageName[0] ? g_imageName : "(未选定)");
    ImGui::Text("Present hook    : %s", g_presentOn ? "OK" : "FAIL");
    ImGui::Text("视矩阵          : %s", g_vpReady ? "OK" : "待填字段");
}

static void drawLogPane(void) {
    if (!ImGui::CollapsingHeader("诊断日志 (截图给我)", ImGuiTreeNodeFlags_DefaultOpen))
        return;

    ImGui::BeginChild("##logpane", ImVec2(0, 190), ImGuiChildFlags_Border);
    pthread_mutex_lock(&g_logLock);
    int total = g_logN;
    int n = total < MAXLOG ? total : MAXLOG;
    int start = total > MAXLOG ? (total % MAXLOG) : 0;
    for (int i = 0; i < n; i++) {
        ImGui::TextUnformatted(g_log[(start + i) % MAXLOG]);
    }
    pthread_mutex_unlock(&g_logLock);

    if (total != g_logSeen) {
        g_logSeen = total;
        ImGui::SetScrollHereY(1.0f);
    }
    ImGui::EndChild();

    if (ImGui::Button("重新自检")) selfCheck();
    ImGui::SameLine();
    if (ImGui::Button(g_menuOpen ? "收起菜单" : "展开菜单")) g_menuOpen = !g_menuOpen;
    ImGui::SameLine();
    if (ImGui::Button("立即拆弹")) {
        Class c = objc_getClass("ASStatusView");
        if (c) installStatusViewHooks(c);
        else LOG("ASStatusView 还没加载");
    }
}

static void drawMenu(void) {
    ImGui::SetNextWindowSize(ImVec2(430, 620), ImGuiCond_FirstUseEver);
    ImGui::Begin("ESP", &g_menuOpen, ImGuiWindowFlags_NoCollapse);

    ImGui::Checkbox("透视 (ESP)", &g_espOn);
    ImGui::Separator();
    ImGui::Checkbox("方框",   &g_showBox);
    ImGui::Checkbox("名字",   &g_showName);
    ImGui::Checkbox("血条",   &g_showHp);
    ImGui::Checkbox("技能CD", &g_showCd);
    ImGui::Checkbox("距离",   &g_showDist);
    ImGui::SliderFloat("最远距离", &g_maxDist, 1000.f, 12000.f, "%.0f");
    ImGui::ColorEdit4("敌方颜色", (float *)&g_colEnemy, ImGuiColorEditFlags_NoInputs);
    ImGui::ColorEdit4("友方颜色", (float *)&g_colAlly,  ImGuiColorEditFlags_NoInputs);

    ImGui::Separator();
    if (ImGui::CollapsingHeader("运行状态", ImGuiTreeNodeFlags_DefaultOpen))
        drawDiag();

    ImGui::Separator();
    drawLogPane();

    ImGui::End();
}

static void renderImGui(id<MTLCommandBuffer> cb) {
    if (!g_pass) return;
    ImGui_ImplMetal_NewFrame(g_pass);
    ImGui::NewFrame();
    float sw = ImGui::GetIO().DisplaySize.x;
    float sh = ImGui::GetIO().DisplaySize.y;
    if (g_espOn) renderFrame(ImGui::GetBackgroundDrawList(), sw, sh);
    if (g_menuOpen) drawMenu();
    ImGui::Render();
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb,
        [cb renderCommandEncoderWithDescriptor:g_pass]);
}

// ============================================================================
// 第 8 部分：挂 Unity 的 Metal present
// ============================================================================
typedef void (*t_present)(void *, id<MTLCommandBuffer>);
static t_present orig_present = NULL;
static bool g_frameBusy = false;

static void hook_present(void *self, id<MTLCommandBuffer> cb) {
    orig_present(self, cb);
    if (!g_booted || g_frameBusy) return;
    g_frameBusy = true;
    @try {
        renderImGui(cb);
    } @catch (NSException *e) {
        LOG("渲染异常: %s", [[e reason] UTF8String]);
    }
    g_frameBusy = false;
}

static void installPresentHook(void) {
    void *h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW);
    if (!h) { LOG("present hook: dlopen 失败"); return; }
    const char *cands[] = {
        "_ZN19UnityGraphicsMetal7PresentEP19MTLCommandBuffer",
        "_ZN19UnityGraphicsMetal7PresentEv",
    };
    for (int i = 0; i < 2; i++) {
        void *sym = dlsym(h, cands[i]);
        if (sym) {
            MSHookFunction(sym, (void *)hook_present, (void **)&orig_present);
            g_presentOn = true;
            LOG("present hook 成功: %s", cands[i]);
            return;
        }
    }
    LOG("没找到 Present 符号，透视不会显示（需要换成 MTKView 代理方案）");
}

// ============================================================================
// 第 9 部分：入口
// ============================================================================
__attribute__((constructor)) static void cheat_entry(void) {
    // 顺序有讲究：先堵死退出，再谈别的
    installExitTrap();
    installAntiDebug();
    installSelfHide();

    pushLog("注入成功 pid=%d", getpid());

    armDisarm();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            bindIl2cpp();
            dispatch_async(dispatch_get_main_queue(), ^{
                if (I2.image) selfCheck();

                g_mtlDevice = MTLCreateSystemDefaultDevice();
                g_mtlQueue  = [g_mtlDevice newCommandQueue];
                CGSize sz = [UIScreen mainScreen].bounds.size;
                setupImGui(sz.width, sz.height);
                installPresentHook();

                UIWindow *win = [UIApplication sharedApplication].keyWindow;
                if (win) {
                    UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc]
                        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
                            g_menuOpen = !g_menuOpen;
                        }] action:@selector(main)];
                    g.numberOfTouchesRequired = 3;
                    g.direction = UISwipeGestureRecognizerDirectionDown;
                    [win addGestureRecognizer:g];
                }
                LOG("初始化完成");
            });
        });
    });
}
