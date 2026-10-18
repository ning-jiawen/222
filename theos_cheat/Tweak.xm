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
//  v11-S（截图版，2026-10-18）—— 设备不越狱，唯一数据通道是手机截图：
//    1. HUD 从「诊断文字」升级成「字段表阅读器」：每页 20 行，6 秒翻页，到底循环
//    2. 字段缓冲 160 → 760 行，每行带 `名字 @十六进制偏移`，类头带 `(Nf)` 总字段数
//    3. dump 名单改「包含匹配 + 相机优先」：CameraVP / CameraFocus / CameraOffs /
//       CameraUpd / GuishiCamera / ActorManager / CBattleHeroInfo / Blood / ActorConfig / Player
//    4. HUD 几何按屏幕算（17 Pro 横屏 874×402pt），左侧 62% 宽，10pt 等宽字，
//       window / view / label 三层 userInteractionEnabled = NO，全程不吃触摸
//    5. il2cpp 绑定从「15 秒一次」改成 12/22/35/50/70/95 秒六轮重试
//
//  v12 修（2026-10-18，esp11s 截图反馈：asm = Assembly-CSharp-firstpass.dll cls 7，dump 0 cls）：
//    - 根因：12 秒时真正的 Assembly-CSharp.dll 还没被 Unity 加载，strstr("Assembly-CSharp")
//      先把 firstpass（7 个类）选成主程序集，g_il2cppOk 被置真，后续重试全被
//      `if (g_il2cppOk) return;` 掐掉 —— 永远 7 个类、永远 0 命中
//    - 现在：firstpass 一律排除；选中程序集类数 < 1000 视为「没绑上」并继续重试
//    - 重试时刻拉到 20~320 秒，覆盖热更新把 Assembly-CSharp.dll 装进来的时间点
//    - 新增 4 指上滑 = 重新 dump / 重新绑定（overlay 不收触摸，菜单按钮点不动）
//
//  v13（2026-10-18，按原作者架构重构 dump 层）：
//    把 PxExtFFi.bin 又扒了一遍：只有 27 个 il2cpp_* API 名字是明文，
//    类名/字段名（ActorManager、Camera、Assets.Scripts.*）在 ascii / utf-16 / 反序里全是 0 命中
//    —— 原作者把名字加密了，抄不到。但架构抄得到：
//      他用的是 il2cpp_class_from_name + il2cpp_class_get_field_from_name，按名字取，
//      全程没有「先挑一本程序集再枚举」这种动作。
//    而那一步正是我们 12 秒撞上 Assembly-CSharp-firstpass.dll（7 类）的根源。
//    所以本版：绑定只确认 domain；dump 遍历所有 image 的所有类按名字匹配；
//    0 命中就每 15 秒自动重扫（最多 20 轮），另有 4 指上滑手动重扫。
//
//  v14（2026-10-18，实测截图反馈：CameraVPFrameCache 拿到了，但单位侧被接口抢名额）：
//    v13 用 strstr 模糊匹配 + 每关键词只收 1 个类，结果
//      IActorManager(0f) 顶掉了 ActorManager、ICBattleHeroInfoPanel(0f) 顶掉了 CBattleHeroInfo、
//      <astBloodBagInfo_bytes>e__FixedBuffer 顶掉了 Blood。
//    这次直接改成原作者的做法：il2cpp_class_from_name(image, ns, name) 精确取类，
//    接口 / 编译器生成类 / 同名异命名空间都不可能误命中；字段全量输出（每类 cap 40）。
//
//  v16（2026-10-18，第一版真正画东西）：
//    v15 证明三件事：① ActorManager 自己没有 ActorManager 类型的静态字段（单例在泛型基类）
//                    ② DictionaryView`2 / TinyValueList`1 的字段偏移全是 0（泛型定义不可信）
//                    ③ get_ActorList 是属性 getter，返回结构体，ABI 调用风险高
//    所以 v16 全部走「纯内存读」，两条硬规矩：
//      · 一切引擎内存访问用 vm_read_overwrite，坏指针返回失败而不是 SIGSEGV
//      · 不调用游戏托管方法，只用 field_get_type → class_from_il2cpp_type 拿实例化类的真实偏移
//    取法：沿父类链找 static 字段 → 值解引用 klass == ActorManager → 单例
//          → ActorManager+0x10 (Context 字典) → _count/_entries → Entry.value → ActorLinker*
//          → position @0x4C4 → worldToScreen(vp = CameraVPFrameCache._worldToClip @0x08) → 画框
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
// v11-S（截图版）：缓冲 160 → 760 行，每页 20 行 → 十几页拍完；6 秒翻页并循环
#define MAXCHECK   760
#define CHECKLEN   112
#define HUD_LINES   16          // v28：20 → 16，把省下的 4 行给首屏固定诊断块
#define HUD_DWELL  180          // CADisplayLink 30fps → 180 tick = 6 秒/页
static char g_check[MAXCHECK][CHECKLEN];
static int  g_checkN = 0;
static int  g_hudPage = 0;      // HUD 当前页；selfCheck() 里要重置，所以提前声明
static int    g_imgCount   = 0; // 扫过的 image 数
static size_t g_clsScanned = 0; // 扫过的类数
static int    g_found      = 0; // 本轮命中的类数
static int    g_rescan     = 0; // 自动重扫轮次（手势回调要重置，所以放最前）

static void checkLine(const char *fmt, ...) {
    char buf[CHECKLEN];
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
typedef void *(*t_class_from_il2cpp_type)(void *);          // v16：泛型实例化类型 → 真实类（偏移才对）
typedef void *(*t_class_get_field_from_name)(void *, const char *);
typedef void **(*t_class_get_fields)(void *, void **);
typedef const char *(*t_field_get_name)(void *);
typedef size_t (*t_field_get_offset)(void *);
typedef int (*t_field_get_flags)(void *);                    // v16：区分 static / instance，避免误读崩溃
typedef bool (*t_class_is_valuetype)(void *);                // v17：判断 CameraVPFrameCache 是类还是结构体
typedef void *(*t_field_get_type)(void *);          // v14：字段类型，判断是不是 Vector3/Matrix4x4
typedef const char *(*t_type_get_name)(void *);      // v14：类型名（原作者 27 个 API 里也有这个）
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
    t_class_from_il2cpp_type      class_from_il2cpp_type;
    t_class_get_field_from_name   class_get_field_from_name;
    t_class_get_fields            class_get_fields;
    t_field_get_name              field_get_name;
    t_field_get_offset            field_get_offset;
    t_field_get_flags             field_get_flags;
    t_class_is_valuetype          class_is_valuetype;
    t_field_get_type              field_get_type;
    t_type_get_name               type_get_name;
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
    BINDF(class_from_il2cpp_type,     "il2cpp_class_from_il2cpp_type");
    BINDF(class_get_field_from_name,  "il2cpp_class_get_field_from_name");
    BINDF(class_get_fields,           "il2cpp_class_get_fields");
    BINDF(field_get_name,             "il2cpp_field_get_name");
    BINDF(field_get_offset,           "il2cpp_field_get_offset");
    BINDF(field_get_flags,            "il2cpp_field_get_flags");
    BINDF(class_is_valuetype,         "il2cpp_class_is_valuetype");
    BINDF(field_get_type,             "il2cpp_field_get_type");
    BINDF(type_get_name,              "il2cpp_type_get_name");
    BINDF(field_get_value,            "il2cpp_field_get_value");
    BINDF(field_static_get_value,     "il2cpp_field_static_get_value");
    BINDF(class_get_methods,          "il2cpp_class_get_methods");
    BINDF(method_get_name,            "il2cpp_method_get_name");
    BINDF(class_get_method_from_name, "il2cpp_class_get_method_from_name");

    if (!I2.domain_get) return;
    I2.domain = I2.domain_get();
    if (!I2.domain) { LOG("domain not ready"); return; }        // il2cpp 还没起来，下一档再试
    if (!I2.domain_get_assemblies) { LOG("no domain_get_assemblies"); return; }

    // v13：这里不再“选主程序集”。原作者反汇编里用的是
    //   il2cpp_class_from_name / il2cpp_class_get_field_from_name —— 按名字直接取，
    //   全程没有“先挑一本 DLL 再枚举”这一步。我们之前为了枚举类硬加了这一步，
    //   于是 12 秒时撞上 Assembly-CSharp-firstpass.dll（7 类）就锁死了。
    // 现在 binding 只负责：拿到 domain + 数一下有几个 image，剩下交给 dump 全量扫。
    size_t n = 0;
    void **asms = I2.domain_get_assemblies(I2.domain, &n);
    g_imgCount = (int)n;

    const char *bigName = "?";
    size_t bigCount = 0, total = 0;
    for (size_t i = 0; i < n; i++) {
        void *img = I2.assembly_get_image(asms[i]);
        if (!img) continue;
        const char *nm = I2.image_get_name ? I2.image_get_name(img) : "?";
        size_t cc = I2.image_get_class_count ? I2.image_get_class_count(img) : 0;
        total += cc;
        if (cc > bigCount) { bigCount = cc; bigName = nm ? nm : "?"; }
        LOG("  [%zu] %s  classes=%zu", i, nm ? nm : "?", cc);
    }
    snprintf(g_imageName, sizeof(g_imageName), "%s", bigName);

    // 有 domain、有 image 就算“可用”——对错交给 dump 结果判断，不再自我宣布成功
    g_il2cppOk = (I2.domain != NULL && n > 0);
    LOG("bound: imgs=%d largest=%s cls=%zu", (int)n, g_imageName, total);
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
        "Visible", "alive", "Alive", "dead", "Dead", "distance", "Distance",
        // v11-S：相机/矩阵相关的补几个，截图时能排到每页最前面
        "world", "World", "screen", "Screen", "vp", "VP", "rot", "Rot",
        "quat", "Quat", "scale", "Scale", "trans", "Trans", "near", "far"
    };
    for (unsigned i = 0; i < sizeof(kw) / sizeof(kw[0]); i++) {
        if (strstr(n, kw[i])) return true;
    }
    return false;
}

static NSMutableString *g_dumpFile = nil;

// v14：一行 = 名字 @偏移 类型名。类型是关键：
//   m_vPosition 是 UnityEngine.Vector3 还是 int，直接决定能不能拿来做世界坐标。
static void emitField(void *f) {
    const char *fn = I2.field_get_name ? I2.field_get_name(f) : "?";
    size_t off = I2.field_get_offset ? I2.field_get_offset(f) : 0;
    const char *tn = NULL;
    if (I2.field_get_type && I2.type_get_name) {
        void *ft = I2.field_get_type(f);
        if (ft) tn = I2.type_get_name(ft);
    }
    if (g_dumpFile) [g_dumpFile appendFormat:@"  %s @%zX : %s\n",
                     fn ? fn : "?", off, tn ? tn : "?"];
    CHECK("%s @%zX %s", fn ? fn : "?", off, tn ? tn : "?");
}

// cap：这个类最多往 HUD 塞几行；all=1 时先排关键字字段，再用其余字段补满
static void dumpClass(void *klass, const char *label, int cap, int all) {
    if (!klass) { CHECK("%s: not found", label); return; }
    if (!I2.class_get_fields) { CHECK("no class_get_fields"); return; }

    const char *ns = I2.class_get_namespace ? I2.class_get_namespace(klass) : "?";
    if (g_dumpFile) [g_dumpFile appendFormat:@"\n== %s.%s ==\n", ns ? ns : "?", label];

    void *it = NULL, *f;
    int total = 0;
    while ((f = I2.class_get_fields(klass, &it)) && total < 900) total++;

    // 头部写清总字段数：截图里看到 (18f) 就知道有没有被 cap 截掉
    CHECK("== %s.%s (%df) ==", ns ? ns : "?", label, total);

    int shown = 0;
    for (int pass = 0; pass < (all ? 2 : 1) && shown < cap; pass++) {
        it = NULL;
        while ((f = I2.class_get_fields(klass, &it)) && shown < cap) {
            bool key = interestingField(I2.field_get_name ? I2.field_get_name(f) : NULL);
            if (pass == 0 && !key) continue;
            if (pass == 1 && key) continue;
            emitField(f);
            shown++;
        }
    }
    if (shown < total) CHECK(".. %d/%d ..", shown, total);
}

// v15：这批 dump 已经把单位数据的落点确认了：
//   ActorLinker.position @4C4 (Vector3) / rotation @4D0 (Quaternion) / monsterCamp @504 (Byte)
//   CameraVPFrameCache._worldToClip @08 (Matrix4x4)
// 还差三块：① ActorManager 单例怎么拿 ② 单位容器的内存布局 ③ 血量/阵营在 134 个字段里的位置
// 这一版只补数据、不画框：ActorLinker 放到 50 行，ActorManager 连方法名和静态字段一起打出来，
// 再按名字试出三个泛型容器类（DictionaryView`2 / TinyValueList`1 / PoolObjHandle`1）的布局。
static const struct { const char *ns; const char *name; int cap; } g_targets[] = {
    {"Assets.Scripts.GameLogic",  "GuishiCamera",        36},
    {"Assets.Scripts.GameLogic",  "CameraVPFrameCache",   4},
};
#define NTARGET ((int)(sizeof(g_targets) / sizeof(g_targets[0])))

// ---- v16：ESP 数据链（声明提前，selfCheck 要打诊断）----
static void resolveEsp(void);
static void  *g_mgr        = NULL;   // ActorManager 实例
static void  *g_vpInst     = NULL;   // CameraVPFrameCache 实例
static int    g_unitCount  = 0;
static int    g_vpOk       = 0;
static int    g_offDict    = -1;     // ActorManager + offDict -> Dictionary 对象
static int    g_offCount   = -1;
static int    g_offEntries = -1;
static float  g_vp[16]     = {0};
static bool   g_vpReady    = false;
// v17.1：摄像机/视矩阵诊断变量也必须在这里声明 —— selfCheck 的诊断行在 ESP 段之前就用到它们
static void  *g_camClass   = NULL;
static void  *g_camInst    = NULL;
static int    g_vpSrc      = -100;   // -100 未试 / -1 失败 / >=0 命中偏移
static int    g_vpIsStruct = -1;
// v19：v18 的「扫所有 Camera 类静态字段」拆掉了。
// 原因：il2cpp_field_static_get_value 内部会做 class init（跑静态构造函数），
// 在加载期对一堆 Camera 相关类触发 cctor 就是崩溃源（v17 只碰已初始化的两条链，所以没事）。
// 现在只做「方法存在性探测」：class_get_method_from_name 纯查元数据，不执行任何代码。
static int    g_camApiProbed = 0;
static void   probeCameraApi(void);

// v20：这是场对局游戏 —— 大厅里根本没有“敌方单位/战斗相机”这些对象。
// 没开局时去碰相机相关的静态字段/实例，等于在游戏还没准备好的时候把它唤醒（cctor/场景依赖），
// 既没有意义又容易崩。所以：只有在「读到单位」之后（= 已经进对局）才做相机/视矩阵的解析。
static int    g_inMatch     = 0;
static int    g_resolveTick = 0;

// v21：按「不找矩阵」的路子走 —— 直接 Camera.get_main() + WorldToScreenPoint(pos)。
// 依据：v20 的探测结果 get_main=1 / w2sp=1 / w2cm=1 / projm=1，而 GuishiCamera.get_Instance=0。
// 调用方式是原文档里写的：MethodInfo 第一个字段就是 methodPointer，自己 blr 过去。
static void  *g_camObj       = NULL;   // Camera.main 拿到的对象
static void  *g_miGetMain    = NULL;   // Camera.get_main 的 MethodInfo*
static void  *g_miW2S        = NULL;   // Camera.WorldToScreenPoint 的 MethodInfo*
static int    g_camCallState = 0;      // 0 待试 / 1 成功 / -1 放弃
static float  g_uiScale      = 3.0f;   // UIScreen.scale（pixels → points）
static void   resolveCam(void);

// v22：实战修正。v21 在真机上会踩的三个坑，都在这一段解决：
//  ① g_camObj 一旦拿到就不再更新 —— 但一局结束 Unity 会销毁战斗相机，第二局拿旧指针
//     调 WorldToScreenPoint 就是踩已释放对象（闪退/黑屏的直接来源）。
//  ② 判「进对局」用的是 cnt>0，但 cnt 是裸读内存；它一旦是垃圾值，g_inMatch 会在大厅里也变 1。
//  ③ W2S 一旦能用，矩阵那两条扫描链（findInstanceByStatic*，会跑 field_static_get_value）
//     还会每 2 秒跑一遍，实战里就是周期性卡顿。
static int    g_camBadN     = 0;      // camcall bad 次数：有限重试，不再一次就永久放弃
static int    g_boxDrawn    = 0;      // 本帧真正画出的框数（0 = W2S 没产出可用坐标）
static int    g_hudForce    = 0;      // 1 = 强制展开大 HUD（3 指上滑）
static int    g_hudWasGood  = 0;      // 本局曾经真的画出过框（关掉 ESP 后 HUD 仍然保持收起）
static int    g_prevInMatch = 0;      // 进/出对局边沿
static void  *g_camKlass    = NULL;   // 被采纳的相机实例真实 klass（验活就比它）
static void  *g_uCamClass   = NULL;   // v23：UnityEngine.Camera —— 必须和 g_camClass(GuishiCamera) 分开！
                                      // v21 把两者塞进同一个变量，结果拿 GuishiCamera 去查 Camera.get_main，
                                      // 永远查不到（截图里 api get_main 1 但 camcall no get_main 就是这么来的）
static int    g_posOk       = 0;      // v23：坐标非零的单位数（大厅 vs 对局一看就知道）
static int    g_camPxLogged = 0;      // v23：像素尺寸只打一次
static int    g_ctxOff      = -1;     // v30：Context 在 DictionaryView 里的偏移（类=8 / 内联结构体=0）
static int    g_camPxW      = 0;      // v30：相机的 pixelWidth
static int    g_camPxH      = 0;      // v30：相机的 pixelHeight
static int    g_expW        = 0;      // v30：UIKit 期望的像素宽（点×scale）
static int    g_expH        = 0;      // v30：UIKit 期望的像素高
static int    g_pxWarn      = 0;      // v30：像素不匹配告警只打一次
static int    camIntProp(void *cam, const char *name);
static void  *camObjProp(void *cam, const char *name);
static void   adoptFromAllCameras(void);
static int    g_cntRaw      = 0;      // v24：字典 _count 的原始值（夹紧前）
static int    g_capNow      = -1;     // v28：entries 数组长度（原样）
static void  *g_dictPtr     = NULL;   // v28：当前当作 Dictionary 的那个对象
static void  *g_entPtr      = NULL;   // v28：当前当作 entries 的那个数组
static unsigned int g_dw[8] = {0};    // v28：dict+0x00..0x1F 的原始 dword（klass/buckets/entries/count 全在里面）
static unsigned int g_mw[8] = {0};    // v28：mgr +0x00..0x1F 的原始 dword
static float  g_w0[3]       = {0};    // v28：WorldToScreenPoint(0,0,0) 的结果
static void  *g_camMain     = NULL;   // v28：get_main 最近一次返回
static void  *g_camCur      = NULL;   // v28：get_current 最近一次返回
static int    g_pageFreeze  = 0;      // v28：1 = 停止自动翻页（2 指下滑切换）
static int    g_viewHop     = 0;      // v29：0 = *(mgr+offDict) 就是 Dictionary；
                                      //      >0 = 它其实是 DictionaryView，还要再 *(view+hop) 才是 Context
static int    g_hopTried    = 0;      // v29：已经跑过几次 hop 探测
static void   probeW2S0(void);

static int    g_arrBase     = 0x18;   // v27：固定 0x18，不自动翻。
                                      // 依据：_entries@0x10 / _count@0x18 两条运行期实测已经把 8 字节头钉死，
                                      // 所以「cap==0 → 16 字节头」「m20==1 → 基址 0x20」这两个推断都不成立。
                                      // v26 把它们写进自动采纳，等于用错误推断改掉唯一正确的值 —— 撤掉。
static int    g_diagFail    = 0;      // v24：链路失败日志配额（最多 6 条）
static int    g_diagDump    = 0;      // v24：内存转储次数（开局各一次，最多 3 次）
static int    g_curProbeN   = 0;      // v24：get_main / get_current 探测次数
static bool   camStillValid(void);

// 泛型类没有固定命名空间，挨个试（空命名空间排第一）
static const char *kNsGuess[] = {"", "UnityService.Collections", "Assets.Scripts.Common",
                                 "System.Collections.Generic", "Assets.Scripts.GameLogic"};
#define NNSGUESS ((int)(sizeof(kNsGuess) / sizeof(kNsGuess[0])))

static void *findClassByNames(size_t n, void **asms, const char *name) {
    for (size_t a = 0; a < n; a++) {
        void *img = I2.assembly_get_image(asms[a]);
        if (!img) continue;
        for (int i = 0; i < NNSGUESS; i++) {
            void *k = I2.class_from_name(img, kNsGuess[i], name);
            if (k) return k;
        }
    }
    return NULL;
}

// 只列方法名，绝不调用 —— 先看清楚签名，下一版再按名字调（原作者的 methodPointer 手法）
static void dumpMethodNames(void *klass, int maxN) {
    if (!I2.class_get_methods || !I2.method_get_name) return;
    void *it = NULL, *m;
    int cnt = 0;
    while ((m = I2.class_get_methods(klass, &it)) && cnt < 400) {
        const char *mn = I2.method_get_name(m);
        if (mn && cnt < maxN) CHECK("  m %s", mn);
        cnt++;
    }
    CHECK("  (%d methods)", cnt);
}

// 静态字段：只打印「类型名含 wantType」的，避免把 int 常量当指针解引用
static void dumpStaticsOf(void *klass, const char *wantType) {
    if (!I2.class_get_fields || !I2.field_static_get_value ||
        !I2.field_get_type || !I2.type_get_name) return;
    void *it = NULL, *f;
    int cnt = 0;
    while ((f = I2.class_get_fields(klass, &it)) && cnt < 200) {
        cnt++;
        void *ft = I2.field_get_type(f);
        const char *tn = ft ? I2.type_get_name(ft) : NULL;
        if (!tn || !strstr(tn, wantType)) continue;
        unsigned char buf[16] = {0};
        I2.field_static_get_value(f, buf);
        void *v = *(void **)buf;
        const char *fn = I2.field_get_name ? I2.field_get_name(f) : "?";
        CHECK("  S %s = %p", fn ? fn : "?", v);
    }
}

static void selfCheck(void) {
    g_checkN = 0;                 // 重跑时清空，否则页码翻倍
    g_hudPage = 0;
    g_found = 0;
    g_clsScanned = 0;
    CHECK("==== dump v31 ====");

    if (!I2.domain || !I2.domain_get_assemblies || !I2.class_from_name) {
        CHECK("no il2cpp"); return;
    }
    size_t n = 0;
    void **asms = I2.domain_get_assemblies(I2.domain, &n);
    g_imgCount = (int)n;
    CHECK("images: %zu", n);
    if (n == 0) return;

    g_dumpFile = [NSMutableString stringWithFormat:@"esp dump v31 images=%zu\n", n];

    // 只统计扫描面给 HUD 看（不影响选取）
    for (size_t a = 0; a < n; a++) {
        void *img = I2.assembly_get_image(asms[a]);
        if (!img) continue;
        g_clsScanned += I2.image_get_class_count ? I2.image_get_class_count(img) : 0;
    }

    int foundN = 0;
    for (int t = 0; t < NTARGET; t++) {
        void *klass = NULL;
        void *hitImg = NULL;
        for (size_t a = 0; a < n && !klass; a++) {
            void *img = I2.assembly_get_image(asms[a]);
            if (!img) continue;
            klass = I2.class_from_name(img, g_targets[t].ns, g_targets[t].name);
            if (klass) hitImg = img;
        }
        if (!klass) { CHECK("%s: none", g_targets[t].name); continue; }

        CHECK("HIT %s.%s", g_targets[t].ns, g_targets[t].name);
        if (g_dumpFile && hitImg && I2.image_get_name) {
            const char *inm = I2.image_get_name(hitImg);
            [g_dumpFile appendFormat:@"  (image %s)\n", inm ? inm : "?"];
        }
        dumpClass(klass, g_targets[t].name, g_targets[t].cap, 1);
        foundN++;
        g_found++;

        // ActorManager 是入口类：顺手把方法名和「指向自己的静态字段」打出来
        if (strcmp(g_targets[t].name, "ActorManager") == 0) {
            CHECK("-- ActorManager methods --");
            dumpMethodNames(klass, 16);
            CHECK("-- ActorManager statics --");
            dumpStaticsOf(klass, "ActorManager");
        }
    }

    // 泛型容器布局：名字试不出来就显示 none，不影响其它段
    {
        const char *gnames[3] = {"DictionaryView`2", "TinyValueList`1", "PoolObjHandle`1"};
        int gcaps[3] = {10, 10, 6};
        for (int g = 0; g < 3; g++) {
            void *gk = findClassByNames(n, asms, gnames[g]);
            if (!gk) { CHECK("%s: none", gnames[g]); continue; }
            CHECK("EXTRA %s", gnames[g]);
            dumpClass(gk, gnames[g], gcaps[g], 1);
            g_found++;
        }
    }

    CHECK("==== %d cls / %zu scanned ====", foundN, g_clsScanned);

    // v16：解析 ESP 数据链（实例 → 字典 → 偏移），结果直接进 HUD
    resolveEsp();
    CHECK("-- esp chain --");
    CHECK("mgr %p vp %p ok %d", g_mgr, g_vpInst, g_vpOk);
    CHECK("cam %p src %d struct %d", g_camInst, g_vpSrc, g_vpIsStruct);
    probeCameraApi();
    CHECK("off dict %d cnt %d ent %d", g_offDict, g_offCount, g_offEntries);
    CHECK("units %d", g_unitCount);

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

// ============================================================================
// v16：ESP 数据链（实例 → 字典 → 单位）
//
// 两条硬原则：
//  1) 所有引擎内存访问都走 vm_read_overwrite —— 地址无效只返回 KERN_FAILURE，
//     不会 SIGSEGV。第一次画框最大的风险就是错位指针，这个做法把它消掉。
//  2) 不调用游戏托管方法（get_ActorList 之类返回结构体，AArch64 是 sret，ABI 猜错直接闪退）。
//     全部用「字段偏移 + 内存读」，和原作者一样把偏移写死，只是他的偏移来自加密名字表，
//     我们的来自 v15 的 dump。
// ============================================================================
static bool rd(const void *addr, void *dst, size_t n) {
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr,
                                         (vm_size_t)n, (vm_address_t)dst, &got);
    return kr == KERN_SUCCESS && got == n;
}

static void *findCls(const char *ns, const char *name) {
    if (!I2.domain || !I2.domain_get_assemblies || !I2.class_from_name) return NULL;
    size_t n = 0;
    void **asms = I2.domain_get_assemblies(I2.domain, &n);
    for (size_t a = 0; a < n; a++) {
        void *img = I2.assembly_get_image(asms[a]);
        if (!img) continue;
        void *k = I2.class_from_name(img, ns, name);
        if (k) return k;
    }
    return NULL;
}

static void *g_mgrClass = NULL, *g_linkerClass = NULL, *g_vpClass = NULL;

// v17：按「字段类型名」找静态，处理 v16 漏掉的两种情况：
//   ① 静态字段是 T[]（数组里放着目标对象）
//   ② 静态字段声明在泛型基类、但类型名写全了（如 CameraVPFrameCache）
// 只对「类型名里含目标类名」的静态取值，避免把 int 常量当指针解引用。
static void *findInstanceByStaticTyped(void *klass) {
    if (!klass || !I2.class_get_fields || !I2.field_get_flags ||
        !I2.field_static_get_value || !I2.field_get_type ||
        !I2.type_get_name || !I2.class_get_name) return NULL;
    const char *kn = I2.class_get_name(klass);
    if (!kn || !kn[0]) return NULL;

    void *k = klass;
    for (int depth = 0; k && depth < 6; depth++) {
        void *it = NULL, *f;
        int guard = 0;
        while ((f = I2.class_get_fields(k, &it)) && guard++ < 400) {
            if (!(I2.field_get_flags(f) & 0x10)) continue;
            void *ft = I2.field_get_type(f);
            const char *tn = ft ? I2.type_get_name(ft) : NULL;
            if (!tn || !strstr(tn, kn)) continue;

            void *val = NULL;
            I2.field_static_get_value(f, &val);
            if (!val) continue;
            if (strstr(tn, "[]")) {                 // 数组：取第 0 个元素
                void *e0 = NULL;
                if (!rd((char *)val + 0x18, &e0, sizeof(e0)) || !e0) continue;
                val = e0;
            }
            void *vk = NULL;
            if (!rd(val, &vk, sizeof(vk))) continue;
            if (vk == klass) return val;
        }
        k = I2.class_get_parent ? I2.class_get_parent(k) : NULL;
    }
    return NULL;
}

// 在类里按「类型名包含某关键字」找字段，返回偏移（-1 = 没有）
static int fieldOffsetByType(void *klass, const char *typeSub) {
    if (!klass || !I2.class_get_fields || !I2.field_get_type || !I2.type_get_name) return -1;
    void *it = NULL, *f;
    int n = 0;
    while ((f = I2.class_get_fields(klass, &it)) && n++ < 400) {
        void *ft = I2.field_get_type(f);
        const char *tn = ft ? I2.type_get_name(ft) : NULL;
        if (!tn || !strstr(tn, typeSub)) continue;
        return (int)I2.field_get_offset(f);
    }
    return -1;
}

// 单例：沿父类链找 static 字段，把值当指针安全读第一字（klass 指针），等于目标类就是它。
// v15 的 dump 证明 ActorManager 自己没有 ActorManager 类型的静态字段 —— 单例在泛型基类上。
static void *findInstanceByStatic(void *klass) {
    if (!klass || !I2.class_get_fields || !I2.field_get_flags ||
        !I2.field_static_get_value) return NULL;
    void *k = klass;
    for (int depth = 0; k && depth < 6; depth++) {
        void *it = NULL, *f;
        int guard = 0;
        while ((f = I2.class_get_fields(k, &it)) && guard++ < 400) {
            if (!(I2.field_get_flags(f) & 0x10)) continue;   // FIELD_ATTRIBUTE_STATIC
            void *inst = NULL;
            I2.field_static_get_value(f, &inst);
            if (!inst) continue;
            void *ik = NULL;
            if (!rd(inst, &ik, sizeof(ik))) continue;
            if (ik == klass) return inst;
        }
        k = I2.class_get_parent ? I2.class_get_parent(k) : NULL;
    }
    return NULL;
}

// updatableActorList 是 DictionaryView<UInt32,ActorLinker>（结构体），内部 Context 是
// Dictionary<UInt32,Object> 的托管对象。泛型定义偏移不可信，必须经
// field_get_type → class_from_il2cpp_type 拿到「实例化类」再取 _count / _entries 偏移。
static void resolveDict(void *mgrClass) {
    if (g_offDict >= 0 || !mgrClass) return;
    if (!I2.class_get_field_from_name || !I2.field_get_type ||
        !I2.class_from_il2cpp_type) return;

    void *lf = I2.class_get_field_from_name(mgrClass, "updatableActorList");
    if (!lf) return;
    void *lt = I2.field_get_type(lf);
    void *viewCls = lt ? I2.class_from_il2cpp_type(lt) : NULL;
    if (!viewCls) return;
    void *cf = I2.class_get_field_from_name(viewCls, "Context");
    if (!cf) return;
    void *ct = I2.field_get_type(cf);
    void *dictCls = ct ? I2.class_from_il2cpp_type(ct) : NULL;
    if (!dictCls) return;
    void *cntF = I2.class_get_field_from_name(dictCls, "_count");
    void *entF = I2.class_get_field_from_name(dictCls, "_entries");
    if (!cntF || !entF) return;

    g_offDict    = (int)I2.field_get_offset(lf);
    g_offCount   = (int)I2.field_get_offset(cntF);
    g_offEntries = (int)I2.field_get_offset(entF);
    // v30：这一行是 v17→v27 一路 0 单位的真正原因 —— Context 的偏移算出来了却从来没用在读取路径上。
    // 期望 8（DictionaryView 是类：klass 8 + Context 8，由两个 view 相差 0x10 反推）；
    // 若为 0，说明它其实是内联结构体（老假设），读取路径会自动退回「不跳」。
    g_ctxOff     = (int)I2.field_get_offset(cf);
    CHECK("CTX off %d viewCls %p", g_ctxOff, viewCls);
}

// v18：扫所有「类名里含 Camera」的类，看它们有没有指向
// v19：只查「方法存不存在」，不调用、不读静态字段 —— 零副作用，不会再触发 cctor。
static void probeCameraApi(void) {
    if (g_camApiProbed) return;
    g_camApiProbed = 1;
    if (!I2.class_get_method_from_name) return;

    // v23：这两个类必须分别打出来。v21 只打了一个，才让「同一个变量装两个类」的 bug 藏了整整一版。
    void *ucam = findCls("UnityEngine", "Camera");
    if (ucam) g_uCamClass = ucam;
    CHECK("api ucam %p", ucam);
    if (ucam) {
        CHECK("api get_main %d", I2.class_get_method_from_name(ucam, "get_main", 0) ? 1 : 0);
        CHECK("api w2sp %d", I2.class_get_method_from_name(ucam, "WorldToScreenPoint", 1) ? 1 : 0);
        CHECK("api get_cur %d", I2.class_get_method_from_name(ucam, "get_current", 0) ? 1 : 0);
        CHECK("api w2cm %d", I2.class_get_method_from_name(ucam, "get_worldToCameraMatrix", 0) ? 1 : 0);
        CHECK("api projm %d", I2.class_get_method_from_name(ucam, "get_projectionMatrix", 0) ? 1 : 0);
    }
    void *gc = g_camClass;
    CHECK("api guishi %p", gc);
    if (gc) {
        CHECK("api ginst %d", I2.class_get_method_from_name(gc, "get_Instance", 0) ? 1 : 0);
        CHECK("api ginst2 %d", I2.class_get_method_from_name(gc, "GetInstance", 0) ? 1 : 0);
    }
}

static void resolveEsp(void) {
    if (!I2.domain) return;

    if (!g_linkerClass) g_linkerClass = findCls("Assets.Scripts.GameLogic", "ActorLinker");
    if (!g_vpClass)     g_vpClass     = findCls("Assets.Scripts.GameLogic", "CameraVPFrameCache");
    if (!g_mgrClass)    g_mgrClass    = findCls("Assets.Scripts.GameLogic", "ActorManager");
    if (!g_camClass)    g_camClass    = findCls("Assets.Scripts.GameLogic", "GuishiCamera");

    if (g_vpClass && g_vpIsStruct < 0 && I2.class_is_valuetype)
        g_vpIsStruct = I2.class_is_valuetype(g_vpClass) ? 1 : 0;

    // ---- 视矩阵：只有进对局后才碰（大厅里这些对象不存在，提前碰等于唤醒）----
    // v22：W2S 一旦可用，矩阵这两条链就整体停掉。它们每轮都对 GuishiCamera /
    // CameraVPFrameCache 的父类链跑 field_static_get_value（贵），实战里每 2 秒一次 = 卡顿。
    bool w2sLive = (g_camObj != NULL && g_miW2S != NULL && g_camCallState == 1);
    if (!w2sLive && g_inMatch && !g_vpReady) {
        // A) CameraVPFrameCache 自己是托管类，静态字段里有实例（v16 走的就是这条，实测没命中）
        if (!g_vpInst && g_vpClass) {
            g_vpInst = findInstanceByStatic(g_vpClass);
            if (!g_vpInst) g_vpInst = findInstanceByStaticTyped(g_vpClass);
        }
        if (g_vpInst) {
            unsigned char buf[64];
            if (rd((char *)g_vpInst + 0x08, buf, 64)) {
                memcpy(g_vp, buf, 64);
                unsigned char valid = 0;
                if (rd((char *)g_vpInst + 0x50, &valid, 1) && valid) {
                    g_vpOk = 1; g_vpReady = true; g_vpSrc = 8;
                }
            }
        }
    }
    if (!w2sLive && g_inMatch && !g_vpReady && g_camClass && !g_camInst) {
        g_camInst = findInstanceByStatic(g_camClass);
        if (!g_camInst) g_camInst = findInstanceByStaticTyped(g_camClass);
    }
    if (!w2sLive && g_inMatch && !g_vpReady && g_camInst && g_camClass) {
        // B) GuishiCamera 上直接有 Matrix4x4 字段
        int off = fieldOffsetByType(g_camClass, "Matrix4x4");
        if (off > 0) {
            unsigned char buf[64];
            if (rd((char *)g_camInst + off, buf, 64)) {
                memcpy(g_vp, buf, 64);
                g_vpOk = 1; g_vpReady = true; g_vpSrc = off;
            }
        }
        // C) GuishiCamera 上有 CameraVPFrameCache 字段：先按「引用」取一次，再按「内嵌结构体」取一次
        if (!g_vpReady) {
            int voff = fieldOffsetByType(g_camClass, "CameraVPFrameCache");
            if (voff > 0) {
                unsigned char buf[64];
                void *p = NULL;
                if (rd((char *)g_camInst + voff, &p, sizeof(p)) && p &&
                    rd((char *)p + 0x08, buf, 64)) {
                    memcpy(g_vp, buf, 64);
                    g_vpOk = 1; g_vpReady = true; g_vpSrc = voff;
                } else if (rd((char *)g_camInst + voff + 0x08, buf, 64)) {
                    memcpy(g_vp, buf, 64);
                    g_vpOk = 1; g_vpReady = true; g_vpSrc = voff + 8;
                }
            } else {
                g_vpSrc = -1;
            }
        }
    }

    if (!g_mgr && g_mgrClass) {
        g_mgr = findInstanceByStatic(g_mgrClass);
        if (g_mgr) resolveDict(g_mgrClass);
    }

    // v21：进对局后拿 Camera.main（拿不到就下一轮再试）
    if (g_inMatch) resolveCam();
}

// v22：拿到 Camera.main，并缓存 WorldToScreenPoint 的 MethodInfo。
// 和 v21 的差别（每条都是实战会踩到的）：
//  * 不再「有 g_camObj 就直接 return」—— 换局/换场景相机会换人，必须能重新取；
//  * MethodInfo 用「对象自己的 klass」去找：findCls 拿到的 Camera 和实例的 Camera 就算不是
//    同一个指针，也照样能取到方法（v21 会当场 -1 永久放弃）；
//  * 只有「get_main 这个方法本身不存在」才永久放弃，其它失败一律下一轮再试。
static void resolveCam(void) {
    if (g_camCallState < 0) return;
    // v24：去掉 `if (!g_inMatch) return;` —— 这一行让相机逻辑在对局外一次都不跑，
    // 于是 v23 的 c 永远是 0（而不是 -1），我们也就永远不知道 get_main 到底返回什么。
    // get_main / get_current 都是纯属性读取，在大厅调用没有任何副作用。
    if (!I2.class_get_method_from_name) return;
    if (!I2.domain) return;                       // v24：ticker 现在每秒都会调进来，先确认 il2cpp 已就绪
    // v23：用 g_uCamClass，绝不能用 g_camClass（那是 GuishiCamera）
    if (!g_uCamClass) g_uCamClass = findCls("UnityEngine", "Camera");
    if (!g_uCamClass) return;

    if (!g_miGetMain) g_miGetMain = I2.class_get_method_from_name(g_uCamClass, "get_main", 0);
    if (!g_miGetMain) { g_camCallState = -1; CHECK("camcall no get_main"); return; }

    void *fn = *(void **)g_miGetMain;            // MethodInfo 第一个字段就是 methodPointer
    if (!fn) { g_camCallState = -1; CHECK("camcall no fn"); return; }

    void *cam = ((void *(*)(void *))fn)(g_miGetMain);
    // v24：把 get_main 的返回值和 get_current 一起打一次。大厅里也打，否则「c 0」永远说不清。
    if (g_curProbeN < 6) {
        g_curProbeN++;
        void *cur = NULL;
        void *mc = I2.class_get_method_from_name(g_uCamClass, "get_current", 0);
        if (mc) { void *f2 = *(void **)mc; if (f2) cur = ((void *(*)(void *))f2)(mc); }
        g_camMain = cam; g_camCur = cur;
        CHECK("Dcam main %p cur %p", cam, cur);
    }
    if (!cam) {
        // v30：局内 main 为 null —— 这时才用 allCameras 兜底（每 5 秒最多一次）
        static int s_allN = 0;
        if (s_allN++ % 5 == 0) adoptFromAllCameras();
        return;
    }
    // v23：没换人就直接返回。换人（大厅相机 → 战斗相机）必须重新采纳，
    // 否则会一直拿大厅那台去投影。
    if (cam == g_camObj && g_miW2S) return;

    void *k = NULL;
    if (!rd(cam, &k, sizeof(k)) || !k) {
        if (++g_camBadN <= 3) CHECK("camcall bad %p", cam);
        return;                                   // 不永久放弃：下一轮再取
    }
    if (g_uCamClass && k != g_uCamClass && g_camBadN < 3)
        CHECK("camcall klass %p != %p", k, g_uCamClass);

    // 用对象真实 klass 取方法（两个 Camera 指针不一致时这一步就是救命的那一步）
    if (!g_miW2S) g_miW2S = I2.class_get_method_from_name(k, "WorldToScreenPoint", 1);
    void *prev = g_camObj;                        // 先存旧值，日志里才看得出「换人了」
    g_camObj = cam;                               // 相机先记住，矩阵路径也能用
    if (!g_miW2S) {
        if (++g_camBadN <= 3) CHECK("camcall no w2s");
        return;
    }
    g_camBadN = 0;
    if (prev != cam || g_camCallState != 1)
        CHECK("camcall ok %p (was %p) w2s %d", cam, prev, g_miW2S ? 1 : 0);
    g_camKlass = k;
    // v30：记下相机像素尺寸，用来识别「大厅相机残留」
    g_camPxW = camIntProp(cam, "get_pixelWidth");
    g_camPxH = camIntProp(cam, "get_pixelHeight");
    g_camCallState = 1;

    // v23：采纳相机后打一次像素尺寸。WorldToScreenPoint 返回的是「像素」，
    // 我们要除以 UIScreen.scale 才是点。如果游戏是降分辨率渲染，这两个数对不上，
    // 框就会整体缩小/偏移 —— 这个日志就是用来判定这件事的。
    if (!g_camPxLogged) {
        g_camPxLogged = 1;
        int pw = 0, ph = 0;
        void *mpw = I2.class_get_method_from_name ? I2.class_get_method_from_name(k, "get_pixelWidth", 0) : NULL;
        void *mph = I2.class_get_method_from_name ? I2.class_get_method_from_name(k, "get_pixelHeight", 0) : NULL;
        if (mpw) { void *f1 = *(void **)mpw; if (f1) pw = ((int (*)(void *, void *))f1)(cam, mpw); }
        if (mph) { void *f2 = *(void **)mph; if (f2) ph = ((int (*)(void *, void *))f2)(cam, mph); }
        CHECK("cam px %d x %d uiscale %.1f", pw, ph, g_uiScale);
    }
}

// v28：把世界原点投影一次。它与「读不到单位」完全无关，所以能在 u=0 的情况下
// 单独验证「相机是不是主相机 + W2S 的 ABI 对不对 + 换算比例」—— 这是本轮唯一新增的硬信号。
static void probeW2S0(void) {
    if (!g_camObj || !g_miW2S) return;
    void *fn = *(void **)g_miW2S;
    if (!fn) return;
    Vec3 wp = {0.0f, 0.0f, 0.0f};
    Vec3 sp = ((Vec3 (*)(void *, Vec3, void *))fn)(g_camObj, wp, g_miW2S);
    g_w0[0] = sp.x; g_w0[1] = sp.y; g_w0[2] = sp.z;
}

// v22：相机验活。托管对象头第一个 8 字节就是 klass 指针，这里只做两件事：
//  * 读不到（页已 unmap）→ 对象没了；
//  * klass 不再是 Camera → 这块内存被别的对象复用了。
// 两种都当作「相机已失效」，下一轮重新 get_main，绝不再拿旧指针调方法。
static bool camStillValid(void) {
    if (!g_camObj) return false;
    void *k = NULL;
    if (!rd(g_camObj, &k, sizeof(k)) || !k) return false;
    void *want = g_camKlass ? g_camKlass : g_uCamClass;
    if (want && k != want) return false;
    return true;
}

// v24：把一段内存按 32 位字打出来。全部走 rd()，读不到就记一行，不会崩。
static void dumpWords(const char *tag, const void *p, int n) {
    if (n > 12) n = 12;
    unsigned int w[12] = {0};
    if (!rd(p, w, (size_t)n * 4)) { CHECK("%s rd fail %p", tag, p); return; }
    char buf[12 * 9 + 16];
    int o = 0;
    for (int i = 0; i < n; i++) o += snprintf(buf + o, sizeof(buf) - o, " %08x", w[i]);
    CHECK("%s%s", tag, buf);
}

// v30：entries 会留空槽（删除后 value=NULL），首元素恰好可能是空的。
// 所以判定用「前 8 项里命中 ActorLinker 的个数」：优先 >=2；只有 cnt<=1 时才接受单命中。
static int linkerHits(void *entries, int cnt) {
    if (!entries) return 0;
    int hits = 0, lim = (cnt < 8) ? cnt : 8;
    for (int i = 0; i < lim; i++) {
        void *v = NULL, *k = NULL;
        if (!rd((char *)entries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && k == g_linkerClass) hits++;
    }
    return hits;
}

// v29：判断「这个对象像不像我们要找的 Dictionary」。
// 只认元数据给的 _count/_entries 偏移（16/24），再要求 entries 前几项能解出 ActorLinker。
// v30：实例属性读取（int / 对象）。K 版显式传 klass，供 allCameras 循环里逐台判断；
// 非 K 版用当前采纳的相机 klass（g_camKlass），供 resolveCam / 采纳后读尺寸用。
static int camIntPropK(void *cam, void *klass, const char *name) {
    if (!cam || !klass || !I2.class_get_method_from_name) return 0;
    void *m = I2.class_get_method_from_name(klass, name, 0);
    if (!m) return 0;
    void *fn = *(void **)m;
    if (!fn) return 0;
    return ((int (*)(void *, void *))fn)(cam, m);
}

static void *camObjPropK(void *cam, void *klass, const char *name) {
    if (!cam || !klass || !I2.class_get_method_from_name) return NULL;
    void *m = I2.class_get_method_from_name(klass, name, 0);
    if (!m) return NULL;
    void *fn = *(void **)m;
    if (!fn) return NULL;
    return ((void *(*)(void *, void *))fn)(cam, m);
}

static int camIntProp(void *cam, const char *name) {
    return camIntPropK(cam, g_camKlass, name);
}

static void *camObjProp(void *cam, const char *name) {
    return camObjPropK(cam, g_camKlass, name);
}

// v30：局内 Camera.main 被证实是 null，所以补一条 allCameras 兜底：
// 只挑 targetTexture 为空、像素面积最大的那台。
static void adoptFromAllCameras(void) {
    if (!g_uCamClass || !I2.class_get_method_from_name) return;
    void *mc = I2.class_get_method_from_name(g_uCamClass, "get_allCamerasCount", 0);
    void *ma = I2.class_get_method_from_name(g_uCamClass, "get_allCameras", 0);
    if (!mc || !ma) { CHECK("CAM no allCameras api"); return; }
    void *fc = *(void **)mc, *fa = *(void **)ma;
    if (!fc || !fa) { CHECK("CAM allCameras fn null"); return; }
    int n = ((int (*)(void *))fc)(mc);
    void *arr = ((void *(*)(void *))fa)(ma);
    CHECK("CAM all n %d arr %p", n, arr);
    if (n <= 0 || n > 32 || !arr) return;
    void *best = NULL; int bestArea = -1;
    for (int i = 0; i < n; i++) {
        void *c = NULL;
        if (!rd((char *)arr + g_arrBase + (size_t)i * 8, &c, sizeof(c)) || !c) continue;
            void *ck = NULL;
        if (!rd(c, &ck, sizeof(ck)) || !ck) continue;
        if (camObjPropK(c, ck, "get_targetTexture")) continue;   // 渲染到 RT 的相机不要
        int w = camIntPropK(c, ck, "get_pixelWidth"), h = camIntPropK(c, ck, "get_pixelHeight");
        int area = w * h;
        if (area > bestArea) { bestArea = area; best = c; }
    }
    if (best) {
        void *kk = NULL;
        if (rd(best, &kk, sizeof(kk)) && kk) {
            g_camObj = best; g_camKlass = kk; g_camCallState = 1;
            // v30：从 allCameras 采纳时也要把 W2S 的 MethodInfo 补上 —— 否则 useW2S 永远 false，又白跑一版
            if (!g_miW2S) g_miW2S = I2.class_get_method_from_name(kk, "WorldToScreenPoint", 1);
            g_camPxW = camIntProp(best, "get_pixelWidth");
            g_camPxH = camIntProp(best, "get_pixelHeight");
            CHECK("CAM pick all %p %dx%d", best, g_camPxW, g_camPxH);
        }
    }
}

static int dictLooks(void *d, int *oCnt, void **oEnt, int *oCap, int *oMatch) {
    if (!d || g_offCount < 0 || g_offEntries < 0) return 0;
    int cnt = -1, cap = -1;
    void *ent = NULL, *v0 = NULL, *k0 = NULL;
    if (!rd((char *)d + g_offCount, &cnt, sizeof(cnt))) return 0;
    if (!rd((char *)d + g_offEntries, &ent, sizeof(ent)) || !ent) return 0;
    if (!rd((char *)ent + 0x10, &cap, sizeof(cap))) return 0;
    if (oCnt) *oCnt = cnt;
    if (oEnt) *oEnt = ent;
    if (oCap) *oCap = cap;
    if (rd((char *)ent + g_arrBase + 16, &v0, sizeof(v0)) && v0) rd(v0, &k0, sizeof(k0));
    if (oMatch) {
        int hits = linkerHits(ent, cnt);
        *oMatch = (hits >= 2 || (cnt <= 1 && hits == 1)) ? 1 : 0;   // v30：按命中数，不按首元素
    }
    return (cnt >= 0 && cnt <= 512 && cap > 0 && cap <= 65536) ? 1 : 0;
}

// v29：现场已证明 *(mgr+offDict) 拿到的是 DictionaryView（4 个指针字段），不是 Dictionary。
// 这里把它每个指针字段都试一遍，谁通过 Dictionary 测试，谁就是 Context。
static void probeViewHop(void) {
    if (!g_mgr || g_offDict < 0) return;
    void *view = NULL;
    if (!rd((char *)g_mgr + g_offDict, &view, sizeof(view)) || !view) return;
    g_hopTried++;
    int picked = 0, soft = -1;
    for (int hop = 0; hop <= 0x28; hop += 8) {
        void *t = view;
        if (hop > 0 && (!rd((char *)view + hop, &t, sizeof(t)) || !t)) continue;
        int cnt = -1, cap = -1, m = 0;
        void *ent = NULL;
        int ok = dictLooks(t, &cnt, &ent, &cap, &m);
        CHECK("H hop %02x p %p ok %d cnt %d cap %d m %d", hop, t, ok, cnt, cap, m);
        if (ok && !picked && soft < 0) soft = hop;      // 形状像 Dictionary 的，先记下来当备选
        if (ok && m && !picked) { g_viewHop = hop; picked = 1; }
    }
    if (picked) CHECK("H pick hop %02x", g_viewHop);
    else if (soft >= 0 && !g_viewHop) { g_viewHop = soft; CHECK("H soft hop %02x", soft); }
    else if (!g_viewHop) CHECK("H none (no Dictionary-shaped field)");
}

// v25：把 ActorManager 上所有 DictionaryView 字段扫一遍，逐个解到 Context，再读
// ent / cnt / cap，并同时用 0x18 和 0x20 两种基址去解第一个元素，看哪个 klass 等于 ActorLinker。
// 结论直接采纳：哪个字段能解出 ActorLinker，就把 g_offDict 换成它，基址也一并定下来。
// 这样「actorList@8 还是 updatableActorList@16」「0x18 还是 0x20」都不用再猜。
static void probeActorLists(void) {
    if (!g_mgr || !g_mgrClass || !I2.class_get_fields || !I2.field_get_type ||
        !I2.type_get_name || !I2.field_get_name) return;
    void *f = NULL;
    int total = 0, shown = 0, best = -1;
    int altOff[2] = {-1, -1}, altCnt[2] = {0, 0}, altN = 0;
    for (void *kc = g_mgrClass; kc && total < 300; kc = (I2.class_get_parent ? I2.class_get_parent(kc) : NULL)) {
        void *it = NULL;
        while ((f = I2.class_get_fields(kc, &it)) && total++ < 300) {
            if (I2.field_get_flags && (I2.field_get_flags(f) & 0x10)) continue;   // 跳过 static
            void *ft = I2.field_get_type(f);
            const char *tn = ft ? I2.type_get_name(ft) : NULL;
            if (!tn) continue;
            // v31：按类型分流，别用同一套判据去测所有容器（否则「L none」是假结论）
            bool isDV = (strstr(tn, "DictionaryView") != NULL);
            size_t tl = strlen(tn);
            bool isList = (!isDV && (strstr(tn, "List") != NULL ||
                                     (tl > 2 && strcmp(tn + tl - 2, "[]") == 0)));
            if (!isDV && !isList) continue;

            int off = (int)I2.field_get_offset(f);
            const char *fn = I2.field_get_name(f);
            void *holder = NULL;
            if (!rd((char *)g_mgr + off, &holder, sizeof(holder)) || !holder) {
                if (shown++ < 8) CHECK("L %s @%d null", fn ? fn : "?", off);
                continue;
            }

            if (isDV) {
                // 两跳：*(mgr+off) 是 DictionaryView，Context 在 +g_ctxOff（类=8）
                void *dict = holder;
                if (g_ctxOff > 0) {
                    void *c2 = NULL;
                    if (rd((char *)holder + g_ctxOff, &c2, sizeof(c2)) && c2) dict = c2;
                }
                int cnt = -1, cap = -1;
                void *ent = NULL;
                rd((char *)dict + g_offCount, &cnt, sizeof(cnt));
                if (rd((char *)dict + g_offEntries, &ent, sizeof(ent)) && ent)
                    rd((char *)ent + 0x10, &cap, sizeof(cap));
                int hits = linkerHits(ent, cnt);           // 前 8 项命中数
                if (shown++ < 8)
                    CHECK("L %s @%d ctx %p cnt %d cap %d hits %d", fn ? fn : "?", off, dict, cnt, cap, hits);
                if (cnt > 0 && cap > 0 && (hits >= 2 || (cnt <= 1 && hits == 1))) {
                    if (best < 0) best = off;
                    if (altN < 2) { altOff[altN] = off; altCnt[altN] = cnt; altN++; }
                }
            } else {
                // List<T> / T[]：_items@0x08、_size@0x10，元素步长 8（对象引用）
                void *items = NULL;
                int size = -1;
                rd((char *)holder + 0x08, &items, sizeof(items));
                rd((char *)holder + 0x10, &size, sizeof(size));
                int hits = 0, lim = (size < 8) ? size : 8;
                for (int i = 0; i < lim; i++) {
                    void *v = NULL, *kk = NULL;
                    if (!rd((char *)items + g_arrBase + (size_t)i * 8, &v, sizeof(v)) || !v) continue;
                    if (rd(v, &kk, sizeof(kk)) && kk == g_linkerClass) hits++;
                }
                if (shown++ < 8)
                    CHECK("LL %s @%d items %p size %d hits %d", fn ? fn : "?", off, items, size, hits);
            }
        }
    }
    if (best >= 0) {
        if (best != g_offDict) { g_offDict = best; CHECK("L pick @%d", best); }
        g_arrBase = 0x18;
        // v31：把并列候选的 cnt 一起打出来，一眼看出该选哪个
        if (altN >= 2) CHECK("L alt @%d cnt %d | @%d cnt %d", altOff[0], altCnt[0], altOff[1], altCnt[1]);
    } else {
        CHECK("L none (no DictionaryView field with ActorLinker)");
    }
}

// Dictionary<UInt32,Object> 的 Entry：hashCode(4) next(4) key(4) pad(4) value(8) = 24B
// 数组头 0x20（klass 8 + monitor 8 + bounds 8 + length 4 + pad 4）。
static void renderFrame(ImDrawList *dl, float sw, float sh) {
    g_boxDrawn = 0;                               // 每帧先归零：HUD 靠它判断「框到底画出来没有」
    if (!I2.domain || !g_mgr || !g_linkerClass) return;
    if (g_offDict < 0 || g_offCount < 0 || g_offEntries < 0) return;

    // v22：ActorManager 也可能被换掉（重登/断线重连），先验 klass；不对就丢掉重新找
    {
        void *mk = NULL;
        if (!rd(g_mgr, &mk, sizeof(mk)) || !mk || (g_mgrClass && mk != g_mgrClass)) {
            if (g_diagFail < 6) { g_diagFail++; CHECK("Dmgr bad %p k %p want %p", g_mgr, mk, g_mgrClass); }
            g_mgr = NULL; g_unitCount = 0; g_inMatch = 0; g_prevInMatch = 0;
            return;
        }
    }

    // v24：每一步读失败都要留一行。v22/v23 在这里全是裸 return，所以 HUD 只剩 u 0，
    // 根本分不清是空字典、偏移错、还是数组头错 —— 这就是「修了三个版本没框」的根源。
    // v29：*(mgr+offDict) 是 DictionaryView；真正的 Context 可能要再跳一层（g_viewHop）
    void *view = NULL;
    if (!rd((char *)g_mgr + g_offDict, &view, sizeof(view)) || !view) {
        if (g_diagFail < 6) { g_diagFail++; CHECK("Ddict fail mgr %p off %d -> %p", g_mgr, g_offDict, view); }
        dumpWords("Dmgr", g_mgr, 8);
        return;
    }
    // v30：先按元数据给的 Context 偏移跳一层（类=8），跳不动再退回 v29 探出来的 hop
    void *dict = view;
    if (g_ctxOff > 0) {
        void *ctx = NULL;
        if (rd((char *)view + g_ctxOff, &ctx, sizeof(ctx)) && ctx) dict = ctx;
    } else if (g_viewHop > 0) {
        void *hop = NULL;
        if (rd((char *)view + g_viewHop, &hop, sizeof(hop)) && hop) dict = hop;
    }
    int cnt = 0;
    if (!rd((char *)dict + g_offCount, &cnt, sizeof(cnt))) {
        if (g_diagFail < 6) { g_diagFail++; CHECK("Dcnt fail dict %p off %d", dict, g_offCount); }
        dumpWords("Ddict", dict, 10);
        return;
    }
    void *entries = NULL;
    if (!rd((char *)dict + g_offEntries, &entries, sizeof(entries)) || !entries) {
        if (g_diagFail < 6) { g_diagFail++; CHECK("Dent fail dict %p off %d -> %p", dict, g_offEntries, entries); }
        dumpWords("Ddict", dict, 10);
        return;
    }
    int cap = 0;
    if (!rd((char *)entries + 0x10, &cap, sizeof(cap))) {
        if (g_diagFail < 6) { g_diagFail++; CHECK("Dcap fail ent %p", entries); }
        return;
    }
    g_cntRaw  = cnt;
    // v28：把「当前认定的 dict / entries / cap」和它们前 16 字节原样存下来，供首屏显示。
    // r 出现 0x56004660 这种堆指针形态时，只有原始 dword 能说明问题。
    g_dictPtr = dict; g_entPtr = entries; g_capNow = cap;
    { unsigned int a[8] = {0}; rd(dict, a, sizeof(a)); for (int i = 0; i < 8; i++) g_dw[i] = a[i]; }
    { unsigned int b[8] = {0}; rd(g_mgr, b, sizeof(b)); for (int i = 0; i < 8; i++) g_mw[i] = b[i]; }

    // v24：v22 那条 `cap <= 0 → return` 是设计错误 —— 一个可疑数字就把整条链全丢掉，
    // 于是只剩 u 0。现在改成「记账 + 夹紧」：可疑就不采信，但一定把原始值留在 HUD 上。
    int cntRaw = cnt;
    if (cnt < 0 || cnt > 512) {
        if (g_diagFail < 6) { g_diagFail++; CHECK("Dcnt range %d (cap %d)", cntRaw, cap); }
        cnt = 0;
    }
    if (cap > 0 && cap < 65536 && cnt > cap) cnt = cap;
    if (cnt > 160) cnt = 160;                     // v22：原来 64 太小，实战里敌人可能排在后面

    // v22：进/出对局边沿。离开对局（载入中/回大厅）必须把相机和视矩阵整体作废，
    // 否则第二局就是拿着上一局已销毁的 Camera 在调 WorldToScreenPoint。
    int nowIn = (cnt > 0) ? 1 : 0;
    bool edgeIn = (g_prevInMatch == 0 && nowIn == 1);   // v24：进对局那一下，多转储一份
    if (g_prevInMatch == 1 && nowIn == 0) {
        g_camObj = NULL; g_camCallState = 0; g_camBadN = 0; g_camKlass = NULL;
        g_vpReady = false; g_vpInst = NULL; g_vpSrc = -100;
        g_hudWasGood = 0;
        CHECK("leave match: cam/vp reset");
    }
    g_prevInMatch = nowIn;
    // v20：读到单位 = 已经在对局里；只有这时才去碰相机/视矩阵（大厅里没有这些对象）
    g_inMatch = nowIn;

    // v24：一次性内存转储。第一帧 + 每次进对局各打一份，一共最多 3 份。
    // D1/D2/D3 是原始字，D4/D5 同时试「数组数据在 0x18」和「在 0x20」两种可能，
    // 用「第一个元素解引用后的 klass 是不是 ActorLinker」来裁决 —— 谁对看 match 那一位。
    if (g_diagDump < 3 && (g_diagDump == 0 || edgeIn)) {
        g_diagDump++;
        CHECK("D0 mgr %p dict %p cnt %d ent %p cap %d", g_mgr, dict, cntRaw, entries, cap);
        dumpWords("D1 mgr ", g_mgr, 6);
        dumpWords("D2 dict", dict, 10);
        dumpWords("D3 entr", entries, 8);
        void *v18 = NULL, *v20 = NULL, *k18 = NULL, *k20 = NULL;
        void *v18b = NULL, *k18b = NULL;
        if (rd((char *)entries + 0x18 + 16, &v18, sizeof(v18)) && v18) rd(v18, &k18, sizeof(k18));
        if (rd((char *)entries + 0x20 + 16, &v20, sizeof(v20)) && v20) rd(v20, &k20, sizeof(k20));
        // v27：第二个元素只在 cnt>=2 时存在，否则读越界（rd 不会崩，但没有意义）
        if (cntRaw >= 2 && rd((char *)entries + 0x18 + 24 + 16, &v18b, sizeof(v18b)) && v18b)
            rd(v18b, &k18b, sizeof(k18b));
        CHECK("D4 base18 v %p k %p | base20 v %p k %p", v18, k18, v20, k20);
        int m18 = (k18 && k18 == g_linkerClass) ? 1 : 0;
        int m20 = (k20 && k20 == g_linkerClass) ? 1 : 0;
        int m18b = (cntRaw < 2) ? -1 : ((k18b && k18b == g_linkerClass) ? 1 : 0);
        CHECK("D5 linker %p m18 %d m18b %d m20 %d cap %d", g_linkerClass, m18, m18b, m20, cap);
        // v27：这里只做记录，不改任何状态（基址恒 0x18）。
        // cap>0 只是再次确认「entries+0x10 是 max_length」，与 8 字节头一致；
        // m20 单独为 1 的含义是「这段内存像步长 8 的指针数组」，不是「基址 0x20」。
        if (cap == 0) CHECK("D5 cap0 —— entries 不是数组或空数组");
        if (m20 && !m18) CHECK("D5 m20 only —— 像步长 8 的指针数组");
    }
    // v17：第一个单位的坐标打一次，用来确认世界尺度（决定后面框的高度/距离怎么算）
    static bool s_posLogged = false;
    if (cnt > 0 && !s_posLogged) {
        void *o0 = NULL;
        if (rd((char *)entries + g_arrBase + 16, &o0, sizeof(o0)) && o0) {
            float p0[3] = {0, 0, 0};
            if (rd((char *)o0 + 0x4C4, p0, sizeof(p0))) {
                CHECK("u0 %.1f %.1f %.1f", p0[0], p0[1], p0[2]);
                s_posLogged = true;
            }
        }
    }
    g_unitCount = cnt;
    // v23：先小范围扫一遍坐标，统计「真的有坐标」的单位数。
    // 大厅里 u 可能也是 64（实测如此），但坐标多半是 0；p 才是判断「进没进对局」的硬指标。
    // 注意：这一段必须放在「没有相机就 return」之前 —— 相机挂了的时候，p 正是唯一能用的诊断。
    {
        int pOk = 0, lim = (cnt < 24) ? cnt : 24;
        for (int i = 0; i < lim; i++) {
            void *o = NULL;
            if (!rd((char *)entries + g_arrBase + (size_t)i * 24 + 16, &o, sizeof(o)) || !o) continue;
            float pp[3] = {0, 0, 0};
            if (!rd((char *)o + 0x4C4, pp, sizeof(pp))) continue;
            if (pp[0] != 0.0f || pp[1] != 0.0f || pp[2] != 0.0f) pOk++;
        }
        g_posOk = pOk;
    }
    // v22：相机每帧验活 —— 这是换局/第二局闪退的唯一有效防线
    if (g_camObj && !camStillValid()) {
        if (++g_camBadN <= 3) CHECK("cam gone, re-acquire");
        g_camObj = NULL; g_camCallState = 0;
    }
    // v22：W2S 优先（不需要矩阵）；只有相机不在时才退回矩阵路径
    bool useW2S = (g_camObj != NULL && g_miW2S != NULL);
    if (!useW2S && !g_vpReady) return;

    int drawn = 0;
    for (int i = 0; i < cnt && drawn < 32; i++) {
        void *obj = NULL;
        if (!rd((char *)entries + g_arrBase + (size_t)i * 24 + 16, &obj, sizeof(obj))) continue;
        if (!obj) continue;
        void *ok = NULL;
        if (!rd(obj, &ok, sizeof(ok)) || ok != g_linkerClass) continue;

        float pos[3] = {0, 0, 0};
        if (!rd((char *)obj + 0x4C4, pos, sizeof(pos))) continue;
        // v22：还没生成/雾里的单位坐标就是 (0,0,0)，投影出来是屏幕左下角的假框
        if (pos[0] == 0.0f && pos[1] == 0.0f && pos[2] == 0.0f) continue;
        unsigned char camp = 0;
        rd((char *)obj + 0x504, &camp, 1);
        unsigned int objId = 0;
        rd((char *)obj + 0x4AC, &objId, 4);

        float sx = 0, sy = 0;
        if (useW2S) {
            // 实例方法 Vector3 WorldToScreenPoint(Vector3)：HFA 在 s0-s2 传参/返回，
            // methodPointer 的签名是 (self, args..., MethodInfo*)。
            void *fn2 = *(void **)g_miW2S;
            if (!fn2) break;
            Vec3 wp = { pos[0], pos[1], pos[2] };
            Vec3 sp3 = ((Vec3 (*)(void *, Vec3, void *))fn2)(g_camObj, wp, g_miW2S);
            if (!(sp3.z > 0.01f)) continue;                       // z<=0 = 在相机背后
            if (!(sp3.x > -100000.0f && sp3.x < 100000.0f)) continue;
            if (!(sp3.y > -100000.0f && sp3.y < 100000.0f)) continue;
            // v31：换算系数现算 = 相机像素宽 / 窗口点数宽（2622/874≈3.0）。
            // 写死 UIScreen.scale 的话，降分辨率渲染 / iPad 分屏 / 动态分辨率都会整体偏。
            float sc = (g_camPxW > 0 && sw > 1.0f) ? ((float)g_camPxW / sw)
                                                  : ((g_uiScale > 0.1f) ? g_uiScale : 3.0f);
            sx = sp3.x / sc;                                       // Unity 像素 → 点
            sy = sh - sp3.y / sc;                                  // Unity 左下原点 → 屏幕左上
        } else {
            Vec3 w = { pos[0], pos[1], pos[2] };
            ImVec2 sp;
            if (!worldToScreen(w, g_vp, sw, sh, sp)) continue;
            sx = sp.x;
            sy = sp.y;
        }
        if (sx < -200 || sx > sw + 200 || sy < -200 || sy > sh + 200) continue;

        // 单位真实高度还没拿到（世界单位不是米），先用固定尺寸框 + 圆点 + ID
        float h  = 90.0f, wd = 45.0f;
        ImU32 col = (camp == 0) ? IM_COL32(90, 190, 255, 230)
                                : IM_COL32(255, 70, 70, 230);
        if (g_showBox) {
            dl->AddRect(ImVec2(sx - wd * 0.5f, sy - h),
                        ImVec2(sx + wd * 0.5f, sy), col, 0, 0, 1.6f);
        }
        dl->AddCircleFilled(ImVec2(sx, sy), 3.0f, col);
        char buf[40];
        snprintf(buf, sizeof(buf), "%u c%d", objId, (int)camp);
        dl->AddText(ImVec2(sx + 6, sy - h - 12), col, buf);
        drawn++;
    }
    g_boxDrawn = drawn;
    if (drawn > 0) g_hudWasGood = 1;
    static bool s_w2sLogged = false;
    if (useW2S && !s_w2sLogged && drawn > 0) {
        s_w2sLogged = true;
        CHECK("w2s usable %d/%d", drawn, cnt);
    }
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

static void updateHud(void) {
    if (!g_hudLabel) return;
    // v22：真的画出框以后自动收成 1 行 —— 实战里 24 行绿字把左半屏挡住是没法打的。
    // 想看完整诊断：3 指上滑（g_hudForce）。出框失败时永远保持完整 HUD。
    if (!g_hudForce && (g_boxDrawn > 0 || g_hudWasGood)) {
        g_hudLabel.text = [NSString stringWithFormat:
            @"ESP v31  u%d r%d b%d p%d in%d d%d c%d\n3-finger UP = full hud",
            g_unitCount, g_cntRaw, g_arrBase, g_posOk, g_inMatch, g_boxDrawn, g_camCallState];
        return;
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:4096];
    [s appendString:@"ESP v31\n"];
    // v13：不再报“选了哪本 DLL”，报扫描面：image 数 / 扫过的类 / 命中数
    // v16：再补单位数和 VP 状态；v22 再补 d（本帧画出的框数）
    [s appendFormat:@"imgs %d cls %zu hits %d u %d r %d b %d p %d in %d c %d d %d%s\n",
        g_imgCount, g_clsScanned, g_found, g_unitCount, g_cntRaw, g_arrBase, g_posOk, g_inMatch,
        g_camCallState, g_boxDrawn, g_il2cppOk ? "" : " WAIT"];
    [s appendFormat:@"il2cpp %@ present %@ mx %@\n",
        g_il2cppOk ? @"OK" : @"FAIL",
        g_presentOn ? @"OK" : @"FAIL",
        g_vpReady ? @"OK" : @"todo"];
    // v28：这 4 行永远在第一屏，不用翻页 —— 现场「没法自主翻页」时这是唯一能拿到数据的地方
    [s appendFormat:@"R %d CAP %d ENT %p\n", g_cntRaw, g_capNow, g_entPtr];
    [s appendFormat:@"D %08x %08x %08x %08x %08x %08x %08x %08x\n", g_dw[0], g_dw[1], g_dw[2], g_dw[3], g_dw[4], g_dw[5], g_dw[6], g_dw[7]];
    [s appendFormat:@"M %08x %08x %08x %08x %08x %08x %08x %08x\n", g_mw[0], g_mw[1], g_mw[2], g_mw[3], g_mw[4], g_mw[5], g_mw[6], g_mw[7]];
    [s appendFormat:@"W0 %.0f %.0f %.0f MAIN %p CUR %p\n",
        g_w0[0], g_w0[1], g_w0[2], g_camMain, g_camCur];
    {
        float winW = (float)g_overlayWin.bounds.size.width;
        float scl = (winW > 1.0f && g_camPxW > 0) ? ((float)g_camPxW / winW) : 0.0f;
        [s appendFormat:@"CTX %d PX %dx%d WIN %.0f SCL %.2f EXP %dx%d\n",
            g_ctxOff, g_camPxW, g_camPxH, winW, scl, g_expW, g_expH];
    }
    int pages = (g_checkN + HUD_LINES - 1) / HUD_LINES;
    if (pages < 1) pages = 1;
    int page = g_hudPage % pages;
    int first = page * HUD_LINES;
    int last  = first + HUD_LINES;
    if (last > g_checkN) last = g_checkN;
    // 每页第一行写页码，单张截图也能对位
    [s appendFormat:@"PAGE %d/%d\n", page + 1, pages];
    for (int i = first; i < last; i++) {
        [s appendFormat:@"%s\n", g_check[i]];
    }
    [s appendFormat:@"-- %d/%d -- loop", page + 1, pages];
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
    if (!g_pageFreeze && t % HUD_DWELL == 0) g_hudPage++;   // v28：冻结时不自动翻页
    // v22：相机每秒独立补一次 —— 不再挂在 resolveEsp 的条件里，
    // 否则 g_vpReady 一旦为 true 就永远走不到相机逻辑
    // v23：不再是「没有相机才取」——而是进对局后每秒无条件重取一次 Camera.main，
    // 指针变了（大厅→对局）就换。一次 il2cpp 调用，成本可以忽略。
    if (t % 30 == 0) { resolveCam(); probeW2S0(); }   // v24 取相机 / v28 顺便投一次世界原点
    // v25：还没读到单位，就每 5 秒把 ActorManager 的字典字段重扫一遍（会自动换 g_offDict / g_arrBase）
    // v29：探测最多跑 3 轮 —— 之前每 5 秒一轮把 HUD 顶到 38 页，翻都翻不完
    if (t % 150 == 0 && g_mgr && g_unitCount == 0 && g_hopTried < 3) { probeActorLists(); probeViewHop(); }
    if (t % 60 == 0 && (!g_vpReady || !g_mgr)) { resolveEsp(); }
}
@end

// overlay 的 VC 必须锁横屏：默认 UIViewController 支持所有方向，
// 会把游戏的横屏锁覆盖掉，导致弹窗一出现整个游戏被转成竖屏。
@interface EspOverlayVC : UIViewController
@end
@implementation EspOverlayVC
- (BOOL)shouldAutorotate { return NO; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
    return UIInterfaceOrientationMaskLandscape;
}
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation {
    return UIInterfaceOrientationLandscapeRight;
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

    // 屏幕是横屏尺寸（宽 > 高），即使 UIScreen.bounds 报的是竖屏也换算过来
    CGRect sb = [UIScreen mainScreen].bounds;
    CGRect frame = sb;
    if (sb.size.width < sb.size.height) {
        frame = CGRectMake(sb.origin.x, sb.origin.y, sb.size.height, sb.size.width);
    }
    w.frame = frame;

    w.windowLevel = UIWindowLevelAlert + 100;
    w.backgroundColor = [UIColor clearColor];
    // 关键：window 自己也是 UIView，默认 userInteractionEnabled=YES。
    // 只把 rootViewController.view 关掉没用 —— hitTest 会落回 window 本身，
    // 整个屏幕的触摸都会被它吃掉（esp9 就是卡在载入界面点不动的）。
    w.userInteractionEnabled = NO;

    EspOverlayVC *vc = [[EspOverlayVC alloc] init];
    vc.view.frame = w.bounds;
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = NO;      // 双保险：视图层也不收触摸
    w.rootViewController = vc;
    w.hidden = NO;                            // 先上屏，safeAreaInsets 才有值
    [w layoutIfNeeded];

    CAMetalLayer *ml = [CAMetalLayer layer];
    ml.device = MTLCreateSystemDefaultDevice();
    ml.pixelFormat = MTLPixelFormatBGRA8Unorm;
    ml.framebufferOnly = YES;
    ml.frame = w.bounds;
    ml.contentsScale = [UIScreen mainScreen].scale;
    ml.opaque = NO;
    [vc.view.layer addSublayer:ml];

    // v11-S HUD 几何：按屏幕算，不写死 —— 17 Pro 横屏 874×402pt
    // 4 行状态 + 4 行固定诊断 + HUD_LINES(16) 行分页字段，10pt Menlo 行高按 13pt 留余量
    UIEdgeInsets si = w.safeAreaInsets;
    CGFloat lh   = 13.0f;                    // 10pt Menlo 行高按 13 留余量，24 行不裁字
    CGFloat hudW = frame.size.width * 0.62f;
    if (hudW > 560) hudW = 560;
    // v28：实际打印 = 1(标题)+2(状态)+4(固定诊断)+1(PAGE)+HUD_LINES+1(尾) = HUD_LINES+9 行
    CGFloat hudH = (HUD_LINES + 12) * lh + 12;
    if (hudH > frame.size.height - 16) hudH = frame.size.height - 16;
    CGFloat ox = si.left + 4;  if (ox < 8) ox = 8;
    CGFloat oy = si.top  + 4;  if (oy < 6) oy = 6;

    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(ox, oy, hudW, hudH)];
    l.numberOfLines = 0;
    l.font = [UIFont monospacedSystemFontOfSize:10 weight:UIFontWeightRegular];
    l.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.45 alpha:1.0];
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.5];
    l.userInteractionEnabled = NO;      // 只是个 UILabel，全程不吃触摸
    l.text = @"ESP v31 booting";
    [vc.view addSubview:l];

    g_uiScale = (float)[UIScreen mainScreen].scale;
    if (g_uiScale < 1.0f) g_uiScale = 3.0f;

    g_expW = (int)(MAX(frame.size.width, frame.size.height) * [UIScreen mainScreen].scale);
    g_expH = (int)(MIN(frame.size.width, frame.size.height) * [UIScreen mainScreen].scale);
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
    ImGui::Text("build         : v31 esp (typed-probe)");
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
    // v22：ESP 关掉、菜单也关掉的时候，没必要 30 次/秒 clear+present 一张全透明的图 ——
    // 真机上这是实打实的发热和降频。清两帧把旧画面擦掉，然后彻底停下。
    static int s_idle = 0;
    if (!g_espOn && !g_menuOpen) {
        if (s_idle >= 2) { g_boxDrawn = 0; return; }   // d 要显示真实的 0，不能留上一帧的残值
        s_idle++;
    } else {
        s_idle = 0;
    }
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
    const char *cands[] = {
        "_ZN19UnityGraphicsMetal7PresentEP19MTLCommandBuffer",
        "_ZN19UnityGraphicsMetal7PresentEv",
    };
    // v23：之前一直打 present FAIL —— 因为只从 dlopen 的句柄里找符号。
    // 我们本来就是被 UnityFramework 加载的，符号在全局作用域里，先用 RTLD_DEFAULT 找。
    for (int i = 0; i < 2; i++) {
        if (dlsym(RTLD_DEFAULT, cands[i])) {
            g_presentOn = true;
            LOG("present symbol(global): %s", cands[i]);
            return;
        }
    }
    void *h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW);
    if (!h) { LOG("present: dlopen fail"); return; }
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
static bool g_gestureOn = false;      // 8 秒挂一次、绑成功后可能再挂一次，去重

static void bindAttempt(int round);   // 手势回调要用，先声明

// 手势必须挂在「游戏的」window 上：overlay 是 userInteractionEnabled=NO，
// 挂在自己身上等于失效。遍历所有 window，跳过我们那个。
static void attachMenuGesture(void) {
    if (g_gestureOn) return;
    UIWindow *win = nil;
    for (UIWindow *x in [UIApplication sharedApplication].windows) {
        if (x == g_overlayWin) continue;
        if (x.hidden || x.alpha < 0.01) continue;
        win = x;
        break;
    }
    if (!win) win = [UIApplication sharedApplication].keyWindow;
    if (!win || win == g_overlayWin) { LOG("no keyWindow, swipe not attached"); return; }

    UISwipeGestureRecognizer *g = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            g_menuOpen = !g_menuOpen;
        }] action:@selector(main)];
    g.numberOfTouchesRequired = 3;
    g.direction = UISwipeGestureRecognizerDirectionDown;
    [win addGestureRecognizer:g];
    g_gestureOn = true;
    LOG("3-finger swipe attached");

    // v13：4 指上滑 = 立刻重扫一遍（所有 image 全量扫）。
    // 菜单里的 re-selfcheck 按钮在真机上是摆设 —— overlay 的 window 不收触摸，
    // ImGui 的点按永远送不进来，所以补一个手势通道。
    UISwipeGestureRecognizer *g2 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            if (g_il2cppOk) { g_rescan = 0; selfCheck(); updateHud(); LOG("manual re-dump"); }
            else { bindAttempt(99); LOG("manual rebind"); }
        }] action:@selector(main)];
    g2.numberOfTouchesRequired = 4;
    g2.direction = UISwipeGestureRecognizerDirectionUp;
    [win addGestureRecognizer:g2];
    LOG("4-finger swipe up = re-dump");

    // v22：overlay 的 window 是 userInteractionEnabled=NO（必须，否则吃触摸没法玩），
    // 所以 ImGui 里的复选框真机上一个都按不到。实战要用的开关只能走手势：
    //   3 指上滑 = 展开/收起完整 HUD（默认出框后自动收起）
    //   4 指下滑 = ESP 开/关
    UISwipeGestureRecognizer *g3 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            g_hudForce = g_hudForce ? 0 : 1;
            updateHud();
            LOG("hud force %d", g_hudForce);
        }] action:@selector(main)];
    g3.numberOfTouchesRequired = 3;
    g3.direction = UISwipeGestureRecognizerDirectionUp;
    [win addGestureRecognizer:g3];

    UISwipeGestureRecognizer *g4 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            g_espOn = g_espOn ? false : true;
            updateHud();
            LOG("esp %d", g_espOn ? 1 : 0);
        }] action:@selector(main)];
    g4.numberOfTouchesRequired = 4;
    g4.direction = UISwipeGestureRecognizerDirectionDown;
    [win addGestureRecognizer:g4];
    // v28：现场反馈「没法自主翻页」，而关键数字原来只出现在后面几页。
    // 现在首屏就有固定块；再加两个手势，想看哪页看哪页：
    //   2 指左滑 = 下一页，2 指右滑 = 上一页，2 指下滑 = 冻结/恢复自动翻页
    UISwipeGestureRecognizer *g5 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            g_hudPage++; updateHud(); LOG("page %d", g_hudPage);
        }] action:@selector(main)];
    g5.numberOfTouchesRequired = 2;
    g5.direction = UISwipeGestureRecognizerDirectionLeft;
    [win addGestureRecognizer:g5];

    UISwipeGestureRecognizer *g6 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            if (g_hudPage > 0) g_hudPage--; updateHud(); LOG("page %d", g_hudPage);
        }] action:@selector(main)];
    g6.numberOfTouchesRequired = 2;
    g6.direction = UISwipeGestureRecognizerDirectionRight;
    [win addGestureRecognizer:g6];

    UISwipeGestureRecognizer *g7 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:[NSBlockOperation blockOperationWithBlock:^{
            g_pageFreeze = g_pageFreeze ? 0 : 1; updateHud(); LOG("freeze %d", g_pageFreeze);
        }] action:@selector(main)];
    g7.numberOfTouchesRequired = 2;
    g7.direction = UISwipeGestureRecognizerDirectionDown;
    [win addGestureRecognizer:g7];

    LOG("2-finger L/R = page, 2-finger down = freeze");
}

static bool g_initDone = false;
static dispatch_queue_t g_bindQ = NULL;

// 绑定尝试时刻（秒）。v13：domain 一出现就绑，之后靠 15 秒一轮的 rescan 等程序集装载。
// 绑定时不再挑程序集，只确认 domain/image 存在；命中与否由 dump 结果说话。
static const int kBindAt[] = {20, 30, 40, 50, 60, 75, 90, 110, 130, 160, 200, 260, 320};
#define kBIND_N ((int)(sizeof(kBindAt) / sizeof(kBindAt[0])))

// v13：扫不到就每 15 秒重扫一次（最多 20 轮），直到命中为止。
// 这解决了“20 秒时程序集还没装载 → 一次空转到底”的整类问题。
static void rescanTick(void) {
    if (g_found > 0 || g_rescan >= 20) return;
    g_rescan++;
    selfCheck();
    updateHud();
    if (g_found == 0) {
        LOG("rescan %d: 0 hit, next in 15s", g_rescan);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ rescanTick(); });
    } else {
        LOG("rescan %d: %d cls hit", g_rescan, g_found);
    }
}

static void onIl2cppReady(void) {
    selfCheck();
    installPresentHook();
    updateHud();
    attachMenuGesture();
    if (g_found == 0) rescanTick();
    LOG("init done");
}

// v11-S：绑定改成多轮重试。整包重签装一次不容易，一次没绑上就白跑。
static void bindAttempt(int round) {
    if (g_il2cppOk) return;
    if (!g_bindQ) g_bindQ = dispatch_queue_create("esp.bind", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_bindQ, ^{
        bindIl2cpp();
        bool ok = g_il2cppOk;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (ok) {
                if (!g_initDone) { g_initDone = true; onIl2cppReady(); }
            } else {
                updateHud();
                LOG("bind round %d failed", round);
            }
        });
    });
}

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

        // v13：20 秒起每档重试一次，直到 domain 就绪；之后 rescan 等程序集装载
        for (int i = 0; i < kBIND_N; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)kBindAt[i] * NSEC_PER_SEC),
                           dispatch_get_main_queue(), ^{
                if (g_il2cppOk) return;
                bindAttempt(i);
            });
        }

        // 手势不等 il2cpp：绑不上也要能开菜单看日志
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(8 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            attachMenuGesture();
        });
    });
}
