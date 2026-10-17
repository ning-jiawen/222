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
#import <mach-o/nlist.h>
#import <mach/vm_map.h>          // vm_protect 在这里；iOS SDK 没有 mach/vm_protect.h
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

// 不依赖 CydiaSubstrate / ellekit。
// 依据：原外挂 PxExtFFi（52 MB）里 MSHookFunction / fishhook / substrate 出现次数全是 0，
// 腾讯 tersafe / owl / pxauth 同样零依赖 —— 在这个无越狱重签环境里，第三方 hook 库
// 反而是最大的崩溃来源。所有 hook 都自己实现：
//   · objc 方法 → method_setImplementation
//   · C 函数   → 自己改 __la_symbol_ptr（见 installExitTrap）

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

    // constructor 阶段 Foundation 可能还没就绪，NSLog 会炸，这里只走 write(2)
    write(STDERR_FILENO, "[esp] ", 6);
    write(STDERR_FILENO, buf, strlen(buf));
    write(STDERR_FILENO, "\n", 1);
}

#define LOG(fmt, ...) pushLog(fmt, ##__VA_ARGS__)

// selfCheck 的字段表单独存一份：HUD 分页滚动显示，不用打开菜单也能截图核对
#define MAXCHECK 160
static char g_check[MAXCHECK][96];
static int  g_checkN = 0;

static void checkLine(const char *fmt, ...) {
    char buf[96];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (g_checkN < MAXCHECK) {
        snprintf(g_check[g_checkN], sizeof(g_check[0]), "%s", buf);
        g_checkN++;
    }
    pushLog("%s", buf);
}
#define CHECK(fmt, ...) checkLine(fmt, ##__VA_ARGS__)

// ---- 诊断状态（直接画在菜单里）----
static bool g_exitTrapOn   = false;
static bool g_antidebugOn  = false;
static bool g_hideOn       = false;
static bool g_presentOn    = false;
static bool g_il2cppOk     = false;
static bool g_disarmOn     = false;
static int  g_exitHits     = 0;
static int  g_trapHits     = 0;
static int  g_timerHits    = 0;
static int  g_disarmCount  = 0;
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

// ---- 1.1 退出熔断：直接改 __la_symbol_ptr / __got 里的函数指针 ----
//  这是从 PxExtFFi 反汇编里还原出来的做法（它 4 处 vm_protect 全是这个模式）：
//    vm_protect(task, page, size, false, prot | VM_PROT_WRITE | VM_PROT_COPY)
//    *slot = replacement
//    vm_protect(..., 原权限)
//  不依赖任何第三方 hook 库，纯 mach + 手工解析 LC_SYMTAB / LC_DYSYMTAB。
static void h_exit(int code)   { g_exitHits++; g_trapHits++; LOG("!! TRAP exit(%d)", code); }
static void h__exit(int code)  { g_exitHits++; g_trapHits++; LOG("!! TRAP _exit(%d)", code); }
static void h_abort(void)      { g_exitHits++; g_trapHits++; LOG("!! TRAP abort()"); }
static int  h_kill(pid_t pid, int sig) {
    if (pid == getpid()) { g_exitHits++; g_trapHits++; LOG("!! TRAP kill(self,%d)", sig); }
    return 0;
}
static int  h_raise(int sig) {
    if (sig == SIGKILL || sig == SIGABRT || sig == SIGTERM) {
        g_exitHits++; g_trapHits++; LOG("!! TRAP raise(%d)", sig);
    }
    return 0;
}

#define ESP_PAGE 0x4000
#ifndef VM_PROT_COPY
#define VM_PROT_COPY 0x10          // 写时复制，改 __DATA_CONST 的 GOT 必须带这个
#endif

static void page_protect(void *addr, size_t len, vm_prot_t prot) {
    vm_address_t start = (vm_address_t)addr & ~(vm_address_t)(ESP_PAGE - 1);
    vm_address_t end   = ((vm_address_t)addr + len + ESP_PAGE - 1) & ~(vm_address_t)(ESP_PAGE - 1);
    vm_protect(mach_task_self(), start, (vm_size_t)(end - start), FALSE, prot);
}

// 在一个镜像里把 want 这个符号的 GOT 槽全部指向 repl，返回命中数
static int hook_sym_in_image(const struct mach_header_64 *mh, intptr_t slide,
                             const char *want, void *repl)
{
    if (!mh || mh->magic != MH_MAGIC_64) return 0;

    const struct symtab_command *symtab = NULL;
    const struct dysymtab_command *dysym = NULL;
    const struct segment_command_64 *linkedit = NULL;

    uintptr_t p = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SYMTAB) {
            symtab = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_DYSYMTAB) {
            dysym = (const struct dysymtab_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            if (strcmp(sg->segname, "__LINKEDIT") == 0) linkedit = sg;
        }
        p += lc->cmdsize;
    }
    if (!symtab || !dysym || !linkedit) return 0;

    // 边界检查：ctor 阶段遍历的是所有镜像（含 dyld 自身 / 375MB 的 UnityFramework），
    // 任何一次越界读都会直接崩在 constructor 里
    const uint32_t le_size = (uint32_t)linkedit->filesize;
    if ((uint64_t)symtab->symoff + (uint64_t)symtab->nsyms * 16 > le_size) return 0;
    if ((uint64_t)symtab->stroff + (uint64_t)symtab->strsize > le_size) return 0;
    if ((uint64_t)dysym->indirectsymoff + (uint64_t)dysym->nindirectsyms * 4 > le_size) return 0;

    const uint8_t *le = (const uint8_t *)(uintptr_t)(linkedit->vmaddr + slide);
    const struct nlist_64 *nl = (const struct nlist_64 *)(le + symtab->symoff);
    const char *strtab = (const char *)(le + symtab->stroff);
    const uint32_t *indirect = (const uint32_t *)(le + dysym->indirectsymoff);

    int hits = 0;
    p = (uintptr_t)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)p;
        if (lc->cmdsize == 0) break;
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const struct segment_command_64 *)lc;
            const struct section_64 *sc = (const struct section_64 *)(sg + 1);
            for (uint32_t j = 0; j < sg->nsects; j++, sc++) {
                if (strcmp(sc->sectname, "__la_symbol_ptr") != 0 &&
                    strcmp(sc->sectname, "__got") != 0) continue;
                uintptr_t base = (uintptr_t)(sc->addr + slide);
                uint32_t cnt = (uint32_t)(sc->size / 8);
                uint32_t idx = sc->reserved1;
                for (uint32_t k = 0; k < cnt; k++, idx++) {
                    if (idx & (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) continue;
                    if (idx >= dysym->nindirectsyms) continue;
                    uint32_t sidx = indirect[idx];
                    if (sidx >= symtab->nsyms) continue;
                    uint32_t strx = nl[sidx].n_un.n_strx;
                    if (strx >= symtab->strsize) continue;
                    const char *nm = strtab + strx;
                    if (strcmp(nm, want) != 0) continue;
                    void **slot = (void **)(base + (uintptr_t)k * 8);
                    if (*slot == repl) continue;
                    if (vm_protect(mach_task_self(),
                                   (vm_address_t)slot & ~(vm_address_t)(ESP_PAGE - 1),
                                   (vm_size_t)ESP_PAGE, FALSE,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS)
                        continue;
                    *slot = repl;
                    hits++;
                }
            }
        }
        p += lc->cmdsize;
    }
    return hits;
}

static void installExitTrap(void) {
    uint32_t n = _dyld_image_count();
    int hits = 0;
    for (uint32_t i = 0; i < n; i++) {
        const struct mach_header *mh = _dyld_get_image_header(i);
        if (!mh || mh->magic != MH_MAGIC_64) continue;
        intptr_t slide = _dyld_get_image_vmaddr_slide(i);
        const struct mach_header_64 *m64 = (const struct mach_header_64 *)mh;
        hits += hook_sym_in_image(m64, slide, "_exit",   (void *)h_exit);
        hits += hook_sym_in_image(m64, slide, "__exit",  (void *)h__exit);
        hits += hook_sym_in_image(m64, slide, "_abort",  (void *)h_abort);
        hits += hook_sym_in_image(m64, slide, "_kill",   (void *)h_kill);
        hits += hook_sym_in_image(m64, slide, "_raise",  (void *)h_raise);
    }
    g_exitTrapOn = (hits > 0);
    LOG("GOT trap: %d slots over %u images", hits, n);
}

// ---- 1.2 卡密框静音（ASStatusView，明文未混淆）----
static Class g_ASStatusView = Nil;
static void (*orig_showWithAnimation)(id, SEL) = NULL;

static void h_startAutoDismiss(id self, SEL _cmd) {
    g_timerHits++;
    LOG("BLOCK startAutoDismissTimer:");
}
static void h_autoDismissFired(id self, SEL _cmd) {
    g_timerHits++;
    LOG("BLOCK autoDismissTimerFired");
}
static void h_startCountdown(id self, SEL _cmd) {
    g_timerHits++;
    LOG("BLOCK startCountdownTimer");
}
static void h_countdownFired(id self, SEL _cmd) {
    g_timerHits++;
}
static void h_showWithAnimation(id self, SEL _cmd) {
    // 不调原实现：框根本不上屏，触摸也就不会被它挡住
    UIView *v = (UIView *)self;
    v.hidden = YES;
    v.alpha = 0.f;
    v.userInteractionEnabled = NO;
    LOG("license view blocked");
}

// 递归把已经存在的 ASStatusView 全部藏掉（框是 PxExtFFi 的 ctor 弹的，比我们早）
static void sweepView(UIView *v) {
    if (!v) return;
    if (g_ASStatusView && [v isKindOfClass:g_ASStatusView]) {
        v.hidden = YES;
        v.alpha = 0.f;
        v.userInteractionEnabled = NO;
        LOG("swept license view");
    }
    for (UIView *sub in [v subviews]) sweepView(sub);
}

static int g_sweepTries = 0;
static void sweepLicenseViews(void) {
    UIApplication *app = [UIApplication sharedApplication];
    if (!app) {
        // UIApplicationMain 还没跑完，等它起来（最多试 10 秒）
        if (g_sweepTries++ < 40) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ sweepLicenseViews(); });
        }
        return;
    }
    for (UIWindow *w in [app windows]) {
        if (w.hidden == NO) sweepView(w);
        sweepView([w rootViewController].view);
    }
    LOG("sweep done (try %d)", g_sweepTries);
}

static bool hookMethod(Class cls, const char *selName, IMP imp, IMP *old) {
    if (!cls) return false;
    SEL s = sel_registerName(selName);
    Method m = class_getInstanceMethod(cls, s);
    if (!m) { LOG("missing method %s", selName); return false; }
    IMP prev = method_setImplementation(m, imp);   // 纯 objc runtime，零依赖
    if (old) *old = prev;
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

    g_disarmCount = n;
    g_disarmOn = (n > 0);
    LOG("disarm: ASStatusView hooked %d methods", n);

    // 立刻清扫已经弹出来的框，并把新的 exit 调用一并接住（PxExtFFi 可能刚加载完）
    installExitTrap();
    sweepLicenseViews();
}

// 轮询等 PxExtFFi 被 dyld 注册（它可能比我们晚加载）
static void armDisarm(void) {
    static int tries = 0;

    if (g_ASStatusView) return;
    Class c = objc_getClass("ASStatusView");
    if (c) { installStatusViewHooks(c); return; }

    if (++tries > 1200) {          // 120 秒
        LOG("120s timeout waiting ASStatusView");
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
    // PT_DENY_ATTACH 是 syscall，不需要 inline hook，仍然有效
    ptrace(PT_DENY_ATTACH, 0, 0, 0);
    // sysctl / task_get_exception_ports 的抹除需要 inline hook，本版不做
    g_antidebugOn = false;
    LOG("anti-debug: ptrace only");
}

// ============================================================================
// 第 3 部分：模块自隐藏（复刻原外挂第二层）
// ============================================================================
static uint32_t (*orig_dyld_image_count)(void);
static const char *(*orig_dyld_get_image_name)(uint32_t);

static uint32_t hook_dyld_image_count(void) { return orig_dyld_image_count(); }

static const char *hook_dyld_get_image_name(uint32_t idx) {
    const char *n = orig_dyld_get_image_name(idx);
    if (!n) return n;
    // 纯 C 实现：dyld 装载期调用时 ObjC 运行时可能尚未就绪，绝不能用 NSString
    static const char *pats[] = {
        "cheat", "level121", "libesp", "CydiaSubstrate",
        "ellekit", "libhooker", "TweakInject"
    };
    for (unsigned i = 0; i < sizeof(pats) / sizeof(pats[0]); i++) {
        if (strstr(n, pats[i])) return "/usr/lib/system/libsystem_platform.dylib";
    }
    return n;
}

static void installSelfHide(void) {
    // _dyld_image_count / _dyld_get_image_name 的 hook 需要 inline hook，本版不做
    g_hideOn = false;
    LOG("self-hide: n/a (objc-only build)");
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
    if (!I2.fn) LOG("missing symbol %s", sym); \
} while (0)

static void bindIl2cpp(void) {
    I2.h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) I2.h = dlopen("UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) { LOG("UnityFramework dlopen fail: %s", dlerror()); return; }

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
    LOG("assemblies: %zu", n);
    for (size_t i = 0; i < n; i++) {
        void *img = I2.assembly_get_image(asms[i]);
        const char *nm = I2.image_get_name(img);
        if (!nm) continue;
        NSString *s = @(nm);
        LOG("  [%zu] %s", i, [s UTF8String]);
        if (!I2.image && ([s containsString:@"smoba"] || [s containsString:@"Assembly-CSharp"])) {
            I2.image = img;
            snprintf(g_imageName, sizeof(g_imageName), "%s", nm);
            LOG("  ^^ picked game assembly");
        }
    }
    g_il2cppOk = (I2.image != NULL);
}

// ============================================================================
// 第 5 部分：自检 —— 智能字段 dump
// ============================================================================
// 干净包的 metadata 布局被腾讯改过（字段归属静态解析不出来），所以偏移一律
// 走运行时 il2cpp_field_get_offset。这里只筛「可能和透视有关」的字段名，
// 免得 HUD 要翻几百页。
static bool interestingField(const char *n) {
    if (!n) return false;
    static const char *kw[] = {
        "pos", "Pos", "POS", "loc", "Loc", "matrix", "Matrix", "camp", "Camp",
        "team", "Team", "hp", "Hp", "HP", "blood", "Blood", "health", "Health",
        "speed", "Speed", "radius", "Radius", "direction", "forward", "right",
        "up", "level", "Level", "star", "Star", "hero", "Hero", "actor", "Actor",
        "id", "ID", "Id", "battle", "Battle", "player", "Player", "camera",
        "Camera", "view", "View", "proj", "Proj", "fov", "FOV", "visible",
        "Visible", "alive", "Alive", "dead", "Dead", "distance", "Distance"
    };
    for (unsigned i = 0; i < sizeof(kw) / sizeof(kw[0]); i++) {
        if (strstr(n, kw[i])) return true;
    }
    return false;
}

static NSMutableString *g_dumpFile = nil;

static void dumpClass(void *klass, const char *label) {
    if (!klass) { CHECK("  %s: not found", label); return; }
    const char *ns = I2.class_get_namespace ? I2.class_get_namespace(klass) : "?";
    CHECK("== %s.%s ==", ns ? ns : "?", label);
    if (g_dumpFile) [g_dumpFile appendFormat:@"\n== %s.%s ==\n", ns ? ns : "?", label];

    void *it = NULL, *f;
    int total = 0, shown = 0;
    while ((f = I2.class_get_fields(klass, &it)) && total++ < 400) {
        const char *fn = I2.field_get_name(f);
        size_t off = I2.field_get_offset ? I2.field_get_offset(f) : 0;
        if (g_dumpFile) [g_dumpFile appendFormat:@"  %s @%zu\n", fn ? fn : "?", off];
        if (interestingField(fn)) {
            CHECK("  %s @%02zu", fn, off);
            shown++;
        }
    }
    if (total > shown) CHECK("  (%d fields, %d key)", total, shown);
}

static void selfCheck(void) {
    CHECK("==== selfcheck ====");
    if (!I2.image) { CHECK("no game assembly"); return; }
    size_t n = I2.image_get_class_count ? I2.image_get_class_count(I2.image) : 0;
    CHECK("classes: %zu", n);

    g_dumpFile = [NSMutableString stringWithFormat:@"esp dump classes=%zu\n", n];

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
                CHECK("HIT %s.%s  parent=%s", I2.class_get_namespace(k), cn,
                      parent ? I2.class_get_name(parent) : "?");
                dumpClass(k, cn);
                found++;
                break;
            }
        }
    }
    CHECK("==== done %d ====", found);

    // 全量写文件，HUD 只显示筛过的
    if (g_dumpFile) {
        NSArray *dirs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
        NSString *dir = dirs.count ? dirs[0] : NSTemporaryDirectory();
        NSString *path = [dir stringByAppendingPathComponent:@"esp_dump.txt"];
        NSError *err = nil;
        BOOL ok = [g_dumpFile writeToFile:path atomically:YES
                                 encoding:NSUTF8StringEncoding error:&err];
        LOG("dump file %s -> %s", ok ? "ok" : "fail", [path UTF8String]);
    }
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
// ---- overlay：自建 UIWindow + CAMetalLayer，不依赖 Unity 的 render pass ----
//  v2a 的坑：renderImGui() 里 `if (!g_pass) return;`，而 g_pass 从声明起就没被赋值过，
//  所以 ImGui 一帧都画不出来。这版把渲染搬到自己创建的 layer 上，Unity 只负责出帧。
//  另外加一个 UILabel HUD：哪怕 Metal 出问题，也能用文字确认 dylib 真的进了进程。
static UIWindow      *g_overlayWin   = nil;
static UILabel       *g_hudLabel     = nil;
static CAMetalLayer  *g_overlayLayer = nil;
static id<MTLCommandQueue> g_cmdQueue = nil;
static CADisplayLink *g_displayLink  = nil;
static int            g_hudTick      = 0;

static void renderOverlay(void);
static int  g_hudPage = 0;

static void updateHud(void) {
    if (!g_hudLabel) return;
    NSMutableString *s = [NSMutableString stringWithCapacity:900];
    [s appendString:@"ESP v2 loaded\n"];
    [s appendFormat:@"trap %@(%d)  disarm %d/%d  timer %d\n",
        g_exitTrapOn ? @"ON" : @"OFF", g_trapHits,
        g_disarmOn ? 1 : 0, g_disarmCount, g_timerHits];
    [s appendFormat:@"il2cpp %@  present %@  mx %@\n",
        g_il2cppOk ? @"OK" : @"FAIL",
        g_presentOn ? @"OK" : @"FAIL",
        g_vpReady ? @"OK" : @"todo"];
    int pages = (g_checkN + 7) / 8;
    if (pages < 1) pages = 1;
    int page = g_hudPage % pages;
    for (int i = page * 8; i < g_checkN && i < page * 8 + 8; i++) {
        [s appendFormat:@"%s\n", g_check[i]];
    }
    [s appendFormat:@"-- %d/%d --", page + 1, pages];
    g_hudLabel.text = s;
}

@interface EspTicker : NSObject
- (void)tick:(CADisplayLink *)link;
@end

@implementation EspTicker
- (void)tick:(CADisplayLink *)link {
    renderOverlay();
    int t = ++g_hudTick;
    if (t % 30 == 0) updateHud();
    if (t % 120 == 0) g_hudPage++;      // 每 4 秒翻一页字段表
}
@end

static void setupOverlay(void) {
    // iOS 13+ 如果有 Scene，必须用 initWithWindowScene，否则窗口不会显示
    UIWindow *w = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *s in [UIApplication sharedApplication].connectedScenes) {
            if ([s isKindOfClass:[UIWindowScene class]]) {
                w = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)s];
                break;
            }
        }
    }
    if (!w) w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];

    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.frame = w.bounds;
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;      // 触摸穿透，游戏照常操作
    w.rootViewController = vc;

    CAMetalLayer *ml = [CAMetalLayer layer];
    ml.device = MTLCreateSystemDefaultDevice();
    ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
    ml.framebufferOnly = YES;
    ml.frame = w.bounds;
    ml.contentsScale = [UIScreen mainScreen].scale;
    ml.opaque = NO;
    [vc.view.layer addSublayer:ml];

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(6, 36, 420, 300)];
    l.numberOfLines = 0;
    l.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightRegular];
    l.textColor = [UIColor greenColor];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
    l.text = @"ESP v2 已加载（初始化中）";
    [vc.view addSubview:l];

    w.hidden = NO;

    g_overlayWin   = w;
    g_overlayLayer = ml;
    g_hudLabel     = l;
    g_cmdQueue     = [ml.device newCommandQueue];

    EspTicker *tk = [[EspTicker alloc] init];
    g_displayLink = [CADisplayLink displayLinkWithTarget:tk selector:@selector(tick:)];
    g_displayLink.preferredFramesPerSecond = 30;
    [g_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];

    LOG("overlay created %dx%d", (int)w.bounds.size.width, (int)w.bounds.size.height);
}

static void setupImGui(void) {
    if (!g_overlayLayer || !g_overlayWin) {
        LOG("ImGui skip: overlay not ready");
        return;
    }
    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.DisplaySize = ImVec2(g_overlayWin.bounds.size.width,
                            g_overlayWin.bounds.size.height);
    io.Fonts->AddFontDefault();
    ImGui_ImplMetal_Init(g_overlayLayer.device);
    g_booted = true;
    LOG("ImGui ready");
}

static void drawDiag(void) {
    ImGui::Text("build         : v2 disarm");
    ImGui::Text("exit trap     : %s  (%d hit)",
                g_exitTrapOn ? "ON" : "OFF", g_exitHits);
    ImGui::Text("disarm        : %s  (%d hit)",
                g_disarmOn ? "ON" : "OFF", g_timerHits);
    ImGui::Text("anti-dbg/hide : %s / %s",
                g_antidebugOn ? "ON" : "OFF", g_hideOn ? "ON" : "OFF");
    ImGui::Text("il2cpp bind   : %s", g_il2cppOk ? "OK" : "FAIL");
    ImGui::Text("game asm      : %s", g_imageName[0] ? g_imageName : "(none)");
    ImGui::Text("present hook  : %s", g_presentOn ? "OK" : "FAIL");
    ImGui::Text("view matrix   : %s", g_vpReady ? "OK" : "todo");
}

static void drawLogPane(void) {
    if (!ImGui::CollapsingHeader("log (screenshot me)", ImGuiTreeNodeFlags_DefaultOpen))
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

    if (ImGui::Button("re-selfcheck")) selfCheck();
    ImGui::SameLine();
    if (ImGui::Button(g_menuOpen ? "collapse" : "expand")) g_menuOpen = !g_menuOpen;
    ImGui::SameLine();
    if (ImGui::Button("disarm now")) {
        Class c = objc_getClass("ASStatusView");
        if (c) installStatusViewHooks(c);
        else LOG("ASStatusView not loaded yet");
    }
}

static void drawMenu(void) {
    ImGui::SetNextWindowSize(ImVec2(430, 620), ImGuiCond_FirstUseEver);
    ImGui::Begin("ESP", &g_menuOpen, ImGuiWindowFlags_NoCollapse);

    ImGui::Checkbox("ESP", &g_espOn);
    ImGui::Separator();
    ImGui::Checkbox("Box",   &g_showBox);
    ImGui::Checkbox("Name",   &g_showName);
    ImGui::Checkbox("HP bar",   &g_showHp);
    ImGui::Checkbox("Skill CD", &g_showCd);
    ImGui::Checkbox("Distance",   &g_showDist);
    ImGui::SliderFloat("Max distance", &g_maxDist, 1000.f, 12000.f, "%.0f");
    ImGui::ColorEdit4("Enemy color", (float *)&g_colEnemy, ImGuiColorEditFlags_NoInputs);
    ImGui::ColorEdit4("Ally color", (float *)&g_colAlly,  ImGuiColorEditFlags_NoInputs);

    ImGui::Separator();
    if (ImGui::CollapsingHeader("Status", ImGuiTreeNodeFlags_DefaultOpen))
        drawDiag();

    ImGui::Separator();
    drawLogPane();

    ImGui::End();
}

static void renderOverlay(void) {
    if (!g_booted || !g_overlayLayer) return;
    @autoreleasepool {
        id<CAMetalDrawable> dr = [g_overlayLayer nextDrawable];
        if (!dr) return;

        MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture     = dr.texture;
        pass.colorAttachments[0].loadAction  = MTLLoadActionClear;
        pass.colorAttachments[0].clearColor  = MTLClearColorMake(0, 0, 0, 0);
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;

        id<MTLCommandBuffer> cb = [g_cmdQueue commandBuffer];
        id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:pass];

        ImGuiIO &io = ImGui::GetIO();
        io.DisplaySize = ImVec2(g_overlayWin.bounds.size.width,
                                g_overlayWin.bounds.size.height);
        CGFloat sc = g_overlayWin.screen.scale ?: [UIScreen mainScreen].scale;
        io.DisplayFramebufferScale = ImVec2(sc, sc);

        ImGui_ImplMetal_NewFrame(pass);
        ImGui::NewFrame();

        if (g_espOn) renderFrame(ImGui::GetBackgroundDrawList(), io.DisplaySize.x, io.DisplaySize.y);
        if (g_menuOpen) drawMenu();

        ImGui::Render();
        ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);

        [enc endEncoding];
        [cb presentDrawable:dr];
        [cb commit];
    }
}

// ============================================================================
// 第 8 部分：挂 Unity 的 Metal present
// ============================================================================
typedef void (*t_present)(void *, id<MTLCommandBuffer>);
static t_present orig_present = NULL;

static void hook_present(void *self, id<MTLCommandBuffer> cb) {
    if (orig_present) orig_present(self, cb);
}

static void installPresentHook(void) {
    // 只做符号探测，不 inline hook。Unity 的 Present 不在关键路径上，
    // 渲染由 overlay 的 CADisplayLink 驱动，探测到符号只用于 HUD 诊断。
    void *h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW);
    if (!h) { LOG("present: dlopen fail"); return; }
    const char *cands[] = {
        "_ZN19UnityGraphicsMetal7PresentEP19MTLCommandBuffer",
        "_ZN19UnityGraphicsMetal7PresentEv",
    };
    for (int i = 0; i < 2; i++) {
        if (dlsym(h, cands[i])) {
            g_presentOn = true;
            LOG("present symbol: %s", cands[i]);
            return;
        }
    }
    LOG("Present symbol not found");
}

// ============================================================================
// 第 9 部分：入口
// ============================================================================
__attribute__((constructor)) static void cheat_entry(void) {
    // 干净包（无 PxExtFFi 外挂 / 无卡密系统）：ctor 只记一行日志。
    // 所有 ObjC / UIKit 一律推到主队列 —— esp7 就是死在 ctor 里碰 UIKit。
    pushLog("ctor pid=%d", getpid());

    dispatch_async(dispatch_get_main_queue(), ^{
        installAntiDebug();
        pushLog("hooks ready");

        // overlay 尽早建：不用等 il2cpp，进游戏就能看到 HUD 文字
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            setupOverlay();
            setupImGui();
            updateHud();
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                bindIl2cpp();
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (I2.image) selfCheck();
                    installPresentHook();
                    updateHud();

                    UIWindow *win = [UIApplication sharedApplication].keyWindow;
                    if (win) {
                        UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc]
                            initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
                                g_menuOpen = !g_menuOpen;
                            }] action:@selector(main)];
                        g.numberOfTouchesRequired = 3;
                        g.direction = UISwipeGestureRecognizerDirectionDown;
                        [win addGestureRecognizer:g];
                        LOG("3-finger swipe attached");
                    } else {
                        LOG("no keyWindow, swipe not attached");
                    }
                    LOG("init done");
                });
            });
        });
    });
}
