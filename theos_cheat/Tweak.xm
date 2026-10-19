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
#import <math.h>              // v35：sinf 用于隐身灰闪，显式引入避免依赖传递包含

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
static int  g_pinN   = -1;      // v46：前 N 行固定（类 dump / 绑定日志），永不覆盖；-1=未定
// v47：一次性「事实行」按前缀钉住，永远显示在大 HUD 第一页，不随环形缓冲滚动
#define PIN_N 10
static char g_pinBuf[PIN_N][CHECKLEN];
#define PROBES_DEFAULT 1        // v49：1=探针开；兜底版 v49s 用 0（探针全关）
static int  g_freeze   = 0;     // v47：⏸ 冻结（不再接收新行 + 停止自动翻页）
static int  g_hideAll  = 0;     // v48：⊘ 只显示 HUD，不画任何框（截判据页用）
static int  g_frameStamp = 0;   // v47：帧序号（清陈旧 gone 条目用）
static int  g_thT[16] = {0};    // v47：T 直方图（供不依赖 ActorManager 的白名单自证）
static int  g_thN[16] = {0};
static int  g_thC = 0;
static int  g_hudPage = 0;      // HUD 当前页；selfCheck() 里要重置，所以提前声明
static int    g_imgCount   = 0; // 扫过的 image 数
static size_t g_clsScanned = 0; // 扫过的类数
static int    g_found      = 0; // 本轮命中的类数
static int    g_rescan     = 0; // 自动重扫轮次（手势回调要重置，所以放最前）

static const char *g_pinTag[PIN_N] = {
    "DK ", "PSTR off", "PSTR gap", "CTX ", "WHITELIST",
    "CNT ", "TH ", "PST ", "FOGV", "BUCKET"
};

static void checkLine(const char *fmt, ...) {
    char buf[CHECKLEN];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    for (int i = 0; i < PIN_N; i++) {          // v48：钉住捕获必须在冻结判断之前
        size_t tl = strlen(g_pinTag[i]);
        if (strncmp(buf, g_pinTag[i], tl) == 0) {
            snprintf(g_pinBuf[i], CHECKLEN, "%s", buf);
            break;
        }
    }
    if (g_freeze) return;                     // 冻结只影响 ring，不影响钉位
    if (g_checkN >= MAXCHECK) {
        // v46：满了丢最旧的一行（但保留固定头），保住最新输出 —— 否则探针行永远进不来
        int pin = (g_pinN < 0) ? 0 : g_pinN;
        if (pin > MAXCHECK / 2) pin = MAXCHECK / 2;
        if (pin < MAXCHECK - 1) {
            memmove(g_check + (size_t)pin * CHECKLEN,
                    g_check + (size_t)(pin + 1) * CHECKLEN,
                    (size_t)(MAXCHECK - pin - 1) * CHECKLEN);
            snprintf(g_check[MAXCHECK - 1], CHECKLEN, "%s", buf);
            return;
        }
    }
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
typedef void *(*t_method_get_return_type)(void *);   // v61：返回 Il2CppType*，用来判 sret
typedef unsigned int (*t_method_get_param_count)(void *);      // v64：L3b 看参数
typedef void *(*t_method_get_param)(void *, unsigned int);     // v64：参数类型 Il2CppType*

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
    t_method_get_return_type      method_get_return_type;   // v61
    t_method_get_param_count      method_get_param_count;   // v64
    t_method_get_param            method_get_param;         // v64
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
    BINDF(method_get_return_type,     "il2cpp_method_get_return_type");
    BINDF(method_get_param_count,     "il2cpp_method_get_param_count");
    BINDF(method_get_param,           "il2cpp_method_get_param");

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
static int    g_ctxOff      = -1;
// v33：单位身份。全部走元数据（字段类型 → class_from_il2cpp_type → 按名字取偏移），不猜偏移
static void  *g_metaCls     = NULL;
static int    g_offTheMeta  = -1;
static int    g_metaStruct  = -1;     // 1 = ActorMeta 是内联结构体，0 = 引用
static int    g_offAType    = -1;
static int    g_offACamp    = -1;
static int    g_offCfgId    = -1;
static int    g_offPid      = -1;
static int    g_offHostCfg  = -1;     // v34：HostConfigId（和 ConfigId 谁才是英雄 ID，一次定死）
static int    g_offRawPid   = -1;     // v34：RawPlayerId
static int    g_heroType    = -1;     // v34：自证出来的「英雄」ActorType；-1 = 未定，照旧全画
static int    g_verifyN     = 0;      // v34：计数自证跑过几次（最多 3）
static void  *g_lastDict    = NULL;   // v34：上一帧用的 dict / entries / count
static void  *g_lastEntries = NULL;
static int    g_lastCnt     = 0;
// v35：生命周期字段（全部按名字从元数据取，取不到就是 -1，规则自动降级）
static int    g_offMeshVis   = -1;    // _meshVisible    网格是否可见
static int    g_offLogicVis  = -1;    // _logicVisible   逻辑是否可见
static int    g_offInCam     = -1;    // _inCamera
static int    g_offMirror    = -1;    // isMirrorActor   分身
static int    g_offHostActor = -1;    // hostActor       被谁挂载（傀儡/召唤物）
static int    g_offCallActor = -1;    // callActor
static int    g_mirrorSafe   = 0;     // 只有确认存在「三个字段全 0」的干净单位，才允许按分身过滤
static int    g_deadTotal    = 0;     // 累计判成死亡/失联的次数（HUD 用）
static int    g_flagTrust    = 1;     // v35：一旦发现「大半单位都被判成死亡」，立即停用旗标判定
static int    g_frameDead    = 0;     // 本帧判成死亡/失联的单位数
static int    g_frameAll     = 0;     // 本帧实际检查过的单位数
static void   bindLinkerFlags(void);
// 死亡/失联的短期记忆（按 ObjID 记住「第一次看不到」的时刻），最多 64 个
typedef struct { unsigned int id; float tGone; int lastF; } GoneEnt;
static GoneEnt g_gone[64];
static unsigned int g_seenId[64];     // 本帧已画过的 ObjID（去重）
static int    g_seenN = 0;
// v36：FOG 探针的记忆（按 ObjID 记住上一次的位置/可见性），最多 16 个英雄
typedef struct {
    unsigned int id;
    float p[3];
    float t;
    int   n;            // 采样过几次
    int   movedOnce;    // 曾经动过（v37：frozen 的前提）
    int   stillCnt;     // 连续不动的次数
    int   frz;          // 已经计过 frozen（按唯一英雄计，不按采样次数累加）
    int   evzCnt;       // v55：这个单位被计入「唯一单位」过没
    int   evzMoved;     // v55：它曾在 mv0（不可见）时发生过位移
    int   lastMv;       // v56：上一次采样时的 mv（用来排除「刚走出视野」那一次）
} FogEnt;
static FogEnt g_fog[16];
static int    g_fogRuns = 0;          // 探针跑过几次（最多 24 次 = 2 分钟）
static int    g_rawHostId = -2;       // v38：GetRawHostPlayerActorId 的缓存（-2 = 还没问过）
static float  g_scrW = 0, g_scrH = 0; // v39：最近一帧的窗口点数尺寸（ref2 判屏幕中心要用）
// v40：只统计敌方主身，4 个桶：0-2k / 2-4k / 4-6k / 6k+
static int    g_bktTot[4] = {0,0,0,0};
static int    g_bktMov[4] = {0,0,0,0};
static int    g_myCamp   = 0;         // 0 = 未知；由参考点那个英雄的 ActorCamp 定
static int    g_rawOk    = 0;         // v40：rawHostId 是否可用（不用 <0 判断）
static int    g_enemyN   = -1;        // 最近一次采样里的敌方主身数（5v5 应恒为 5）
// v41：每个单位的轨迹（用来在「坐标冻结」时外推预测位置）
typedef struct {
    unsigned int id;
    float p[3];
    float v[3];
    float tMove;
    int   dkPrev;      // v44：上一帧 lastDeadKiller 是否非 0（边沿触发用）
    float tDead;       // v44：判死时刻（用于 3 秒强制解锁）
} TkEnt;
// v42：死亡/轨迹相关字段（全部按名字取，取不到就是 -1，规则自动降级）
static int    g_offDeadKiller = -1;   // lastDeadKiller
static int    g_dkIsPtr       = -1;   // v43：1=对象指针 0=int id（由字段类型自证，不再猜）
static int    g_offFrameNum   = -1;   // v43：lastPositionXZChangedFrameNum（位置更新的帧号）
// v48：忽略大小写比较（不引 strings.h，避免头文件差异）
static int pinCount(void) {
    int c = 0;
    for (int i = 0; i < PIN_N; i++) if (g_pinBuf[i][0]) c++;
    return c;
}

static int ciEq(const char *a, const char *b) {
    while (*a && *b) {
        char x = *a, y = *b;
        if (x >= 'A' && x <= 'Z') x = (char)(x + 32);
        if (y >= 'A' && y <= 'Z') y = (char)(y + 32);
        if (x != y) return 0;
        a++; b++;
    }
    return (*a == 0 && *b == 0) ? 1 : 0;
}

// v50：字段查找 —— 只用 class_get_field_from_name（字符串查找），**不再枚举 class_get_fields**。
// v48/v49 用枚举做「忽略大小写 + k__BackingField」回退，这条路径在 v47 里不存在，
// 而 v48 起开始闪退（枚举 API 在泛型/接口类上有踩到 il2cpp 内部断言的风险）。
// 这里改成显式候选名：精确名 / 首字母大写 / 首字母小写 / <Name>k__BackingField。
static void *findFieldOne(void *cls, const char *name) {
    if (!cls || !I2.class_get_field_from_name) return NULL;
    void *f = I2.class_get_field_from_name(cls, name);
    if (f) return f;

    char cand[4][96];
    int n = 0;
    snprintf(cand[n++], 96, "%s", name);

    char cap[96], low[96];
    snprintf(cap, sizeof(cap), "%s", name);
    snprintf(low, sizeof(low), "%s", name);
    if (cap[0] >= 'a' && cap[0] <= 'z') cap[0] = (char)(cap[0] - 32);
    if (low[0] >= 'A' && low[0] <= 'Z') low[0] = (char)(low[0] + 32);
    snprintf(cand[n++], 96, "%s", cap);
    snprintf(cand[n++], 96, "%s", low);

    char bf[96];
    snprintf(bf, sizeof(bf), "<%s>k__BackingField", name);
    snprintf(cand[n++], 96, "%s", bf);

    for (int i = 1; i < n; i++) {              // 第一个就是精确名，已经试过
        f = I2.class_get_field_from_name(cls, cand[i]);
        if (f) return f;
    }
    return NULL;
}

// v55：class_get_field_from_name 不遍历父类 —— IsEmptyActor / IsMirrorActor 这类继承字段
// 之前一直是 -1，很可能就是这个原因。这里沿 class_get_parent 往上找最多 5 层。
static void *findField(void *cls, const char *name) {
    if (!cls) return NULL;
    void *c = cls;
    for (int depth = 0; depth < 5 && c; depth++) {
        void *f = findFieldOne(c, name);
        if (f) {
            if (depth > 0) {
                static int s_log2 = 0;
                if (s_log2 < 8) {
                    s_log2++;
                    const char *cn = I2.class_get_name ? I2.class_get_name(c) : "?";
                    CHECK("FLD %s in parent#%d %s", name, depth, cn ? cn : "?");
                }
            }
            return f;
        }
        c = I2.class_get_parent ? I2.class_get_parent(c) : NULL;
    }
    return NULL;
}

// v49：忽略大小写比较（保留给别处用；findField 已不再依赖它）
// v43：死亡计时（灰虚线 1.5s 淡出后不再画）
typedef struct { unsigned int id; float t; } DeadEnt;
static DeadEnt g_deadTbl[64];
// v45：每个 id 记住「上一次采样到的记录末位」，用来算跨采样变化 dl（这才是判据）
typedef struct { unsigned int id; float lx, lz; int n; int cn; } PstEnt;
static PstEnt g_pst[16];
static int    g_offEmptyActor = -1;   // IsEmptyActor：池回收标记
static int    g_offPosRec     = -1;   // PositionRecords：定时记录位置的那个容器
static int    g_posRecKind    = 0;    // 0=未知 1=List<Vector3> 2=Vector3[]
static float  g_posRecGap     = 0;    // K_PositionRecordsTimeGap（静态常量，能读到就用它算时间轴）
static int    g_pstRuns       = 0;    // PositionRecords 探针跑过几次（最多 3）
static int    g_pidRuns       = 0;    // PlayerId 分组打印次数（最多 3）
static void  *findField(void *cls, const char *name);
static int    ciEq(const char *a, const char *b);
static int    pinCount(void);
static int    g_btnN    = 0;    // v48：已创建并加进窗口的按钮数（自证用）
static int    g_campRuns = 0;   // CampsActors 探针次数
static int    g_mvRuns   = 0;   // MoveControl 探针次数
static int    g_deepRuns = 0;   // v60：英雄深度 dump 次数
static int    g_campMemRuns = 0; // v60：阵营成员关系探针次数
static int    g_l2Runs  = 0;     // v64：L2 连续采样次数
static int    g_l3Runs  = 0;     // v64：L3（L3a+L3b 合并扫描）次数
static void   probeCamps(void);
static void   probeMove(void);
static void   probeHeroDeep(void);
static void   probeCampMem(void);
static void   probeL2(void);
static void   probeL3scan(void);
static void  *fieldByNameish(void *cls, const char *name);
static void   bindExtraLazy(void);
static void   bindExtraFlags(void);
static void   probeExtras(void);
static TkEnt g_tk[64];
static NSMutableArray *g_keepAlive = nil;   // v41：手势/按钮 target 必须强持有，否则立刻释放
static id  keepAlive(id o);
static int projPred(float x, float y, float z, float sw, float sh, float *ox, float *oy);
static int    w2sPx(float x, float y, float z, float *sx, float *sy);
#define FOG_RUNS 24
static float  g_fogLastT = 0;
static void   fogProbe(void);
static int    callInt0(void *self, const char *mname);
static int    callInt1(void *self, const char *mname, int a);
static void   verifyIdentity(void);
static int    g_unitDump    = 0;      // 已 dump 身份的单位数（最多 6）
static int    g_metaTried   = 0;      // 只尝试绑定一次，避免刷 HUD
static void   bindMeta(void);
static int    readIdentity(void *obj, int *aType, int *aCamp, int *cfg, int *pid);
static int    readIdentity2(void *obj, int *aType, int *aCamp, int *cfg, int *pid,
                            int *hostcfg, int *rawpid);     // v30：Context 在 DictionaryView 里的偏移（类=8 / 内联结构体=0）
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
    CHECK("==== dump v64 ====");

    if (!I2.domain || !I2.domain_get_assemblies || !I2.class_from_name) {
        CHECK("no il2cpp"); return;
    }
    size_t n = 0;
    void **asms = I2.domain_get_assemblies(I2.domain, &n);
    g_imgCount = (int)n;
    CHECK("images: %zu", n);
    if (n == 0) return;

    g_dumpFile = [NSMutableString stringWithFormat:@"esp dump v64 images=%zu\n", n];

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
    if (g_linkerClass) bindMeta();        // v33：拿到 theMeta 的偏移与 ActorMeta 字段偏移
    if (g_linkerClass) bindLinkerFlags(); // v35：拿到 _meshVisible / _logicVisible / 分身三兄弟
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

// v33：读托管字符串（il2cpp string = klass(8) + length(4) + UTF-16 chars）。
// 8 字节对象头时 chars 在 0x0C；解不出来再试 0x14。
static int readUtf16At(void *s, int off, char *out, int cap) {
    int len = 0;
    // v34：长度必须落在 1..64，读不到就判失败。不做「换个偏移再试」——
    // 8 字节头下 chars 恒在 0x0C，回退到 0x14 只会在 length 异常时凑出一个
    // 「长度合法、内容是垃圾」的字符串，属于假成功。
    if (!rd((char *)s + 0x08, &len, sizeof(len))) return 0;
    if (len <= 0 || len > 64) return 0;
    unsigned short w[70] = {0};
    if (!rd((char *)s + off, w, len * 2)) return 0;
    int n = 0, bad = 0;
    for (int i = 0; i < len && n < cap - 1; i++) {
        unsigned short c = w[i];
        if (c == 0 || c > 0x7E) { out[n++] = '?'; bad++; continue; }
        out[n++] = (char)c;
    }
    out[n] = 0;
    return (n > 0 && bad * 2 <= n) ? 1 : 0;
}

static void readName(void *s, char *out, int cap) {
    out[0] = 0;
    if (!s || cap < 2) return;
    readUtf16At(s, 0x0C, out, cap);       // v34：只此一条路
}

// v33：theMeta 的位置和 ActorMeta 里那几个字段的偏移，全部问元数据要。
// 和 Context 那次是同一招：字段类型 → class_from_il2cpp_type → 按名字取偏移。
static void bindMeta(void) {
    if (g_offTheMeta >= 0 || g_metaTried) return;
    g_metaTried = 1;
    if (!g_linkerClass || !I2.class_get_field_from_name || !I2.field_get_type ||
        !I2.class_from_il2cpp_type) return;

    void *f = I2.class_get_field_from_name(g_linkerClass, "theMeta");
    if (!f) { CHECK("META no theMeta"); return; }
    g_offTheMeta = (int)I2.field_get_offset(f);

    void *ft = I2.field_get_type(f);
    g_metaCls = ft ? I2.class_from_il2cpp_type(ft) : NULL;
    if (!g_metaCls) { CHECK("META no class"); return; }
    if (I2.class_is_valuetype) g_metaStruct = I2.class_is_valuetype(g_metaCls) ? 1 : 0;

    void *fa = I2.class_get_field_from_name(g_metaCls, "ActorType");
    void *fc = I2.class_get_field_from_name(g_metaCls, "ActorCamp");
    void *fi = I2.class_get_field_from_name(g_metaCls, "ConfigId");
    void *fp = I2.class_get_field_from_name(g_metaCls, "PlayerId");
    void *fh = I2.class_get_field_from_name(g_metaCls, "HostConfigId");
    void *fr = I2.class_get_field_from_name(g_metaCls, "RawPlayerId");
    if (fa) g_offAType = (int)I2.field_get_offset(fa);
    if (fc) g_offACamp = (int)I2.field_get_offset(fc);
    if (fi) g_offCfgId = (int)I2.field_get_offset(fi);
    if (fp) g_offPid   = (int)I2.field_get_offset(fp);
    if (fh) g_offHostCfg = (int)I2.field_get_offset(fh);
    if (fr) g_offRawPid  = (int)I2.field_get_offset(fr);

    CHECK("META off %d struct %d | type %d camp %d cfg %d pid %d",
          g_offTheMeta, g_metaStruct, g_offAType, g_offACamp, g_offCfgId, g_offPid);
}

// v35：把生命周期用到的几个字段偏移按名字问出来（不猜偏移）。
// 任何一个取不到就保持 -1，对应的判据自动失效，退回「全画」，不会因为缺字段就白屏。
// v51：**lazy 绑定** —— 这 5 个字段只在「第一次真正进对局」时才查一次。
// 主菜单不会触碰，类未就绪也不崩；失败只试一次，不反复刷。
static void bindExtraLazy(void) {
    static int done = 0;
    if (done) return;
    done = 1;
    if (!g_linkerClass) { CHECK("LAZY no linkerClass"); return; }
    // ---- v42：死亡 / 轨迹相关（同一个「按名字问偏移」的路子）
    void *f2;
    // v42/v43：lastDeadKiller 到底是「对象指针」还是「int id」，问字段类型 —— 不猜。
    // 猜错的两种后果都很隐蔽：当 id 猜成指针 → 永远不判死；当指针猜成 id → 满屏灰虚线。
    if ((f2 = findField(g_linkerClass, "lastDeadKiller"))) {
        g_offDeadKiller = (int)I2.field_get_offset(f2);
        void *dt = I2.field_get_type(f2);
        const char *tn = (dt && I2.type_get_name) ? I2.type_get_name(dt) : "?";
        // v44：用「值类型 / 引用类型」这个语义判断，不靠名字拼写。
        // strstr("Int") 会把枚举（enDeadType 之类）误判成指针 —— 按指针读枚举 = 野指针。
        void *kc = (dt && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(dt) : NULL;
        if (kc && I2.class_is_valuetype) g_dkIsPtr = I2.class_is_valuetype(kc) ? 0 : 1;
        else g_dkIsPtr = -1;                       // 未知：按 int 读，日志标 dk?
        CHECK("DK off %d type %s ptr %d", g_offDeadKiller, tn ? tn : "?", g_dkIsPtr);
    } else {
        CHECK("DK no field");
        g_dkIsPtr = 0;
    }
    if ((f2 = findField(g_linkerClass, "lastPositionXZChangedFrameNum")))
        g_offFrameNum = (int)I2.field_get_offset(f2);
    if ((f2 = findField(g_linkerClass, "IsEmptyActor")))    g_offEmptyActor = (int)I2.field_get_offset(f2);
    if ((f2 = findField(g_linkerClass, "PositionRecords"))) {
        g_offPosRec = (int)I2.field_get_offset(f2);
        void *pt = I2.field_get_type(f2);
        const char *pn = pt ? I2.type_get_name(pt) : NULL;
        if (pn) {
            size_t pl = strlen(pn);
            if (strstr(pn, "List")) g_posRecKind = 1;
            else if (pl > 2 && strcmp(pn + pl - 2, "[]") == 0) g_posRecKind = 2;
        }
        CHECK("PSTR off %d kind %d type %s", g_offPosRec, g_posRecKind, pn ? pn : "?");
    } else {
        CHECK("PSTR no PositionRecords");
    }
    if ((f2 = findField(g_linkerClass, "K_PositionRecordsTimeGap")) && I2.field_static_get_value) {
        float gap = 0;
        I2.field_static_get_value(f2, &gap);
        if (gap > 0.0f && gap < 10.0f) g_posRecGap = gap;
        CHECK("PSTR gap %.3f", g_posRecGap);
    }
}

static void bindLinkerFlags(void) {
    static int tried = 0;
    if (tried || !g_linkerClass || !I2.class_get_field_from_name) return;
    tried = 1;
    void *f;
    if ((f = I2.class_get_field_from_name(g_linkerClass, "_meshVisible")))    g_offMeshVis   = (int)I2.field_get_offset(f);
    if ((f = I2.class_get_field_from_name(g_linkerClass, "_logicVisible")))   g_offLogicVis  = (int)I2.field_get_offset(f);
    if ((f = I2.class_get_field_from_name(g_linkerClass, "_inCamera")))       g_offInCam     = (int)I2.field_get_offset(f);
    if ((f = I2.class_get_field_from_name(g_linkerClass, "isMirrorActor")))   g_offMirror    = (int)I2.field_get_offset(f);
    if ((f = I2.class_get_field_from_name(g_linkerClass, "hostActor")))       g_offHostActor = (int)I2.field_get_offset(f);
    if ((f = I2.class_get_field_from_name(g_linkerClass, "callActor")))       g_offCallActor = (int)I2.field_get_offset(f);
    CHECK("LFLAG mesh %d logic %d cam %d mirror %d host %d call %d",
          g_offMeshVis, g_offLogicVis, g_offInCam, g_offMirror, g_offHostActor, g_offCallActor);
    CHECK("DEAD killer %d empty %d", g_offDeadKiller, g_offEmptyActor);
}

// v41：手势/控件 target 保活。UIGestureRecognizer 只保留 target 的 unsafe_unretained 引用，
// 用 NSBlockOperation 当 target 时它出作用域就释放了 —— 之前 7 个手势全死就是这个原因。
static id keepAlive(id o) {
    if (!o) return nil;
    if (!g_keepAlive) g_keepAlive = [NSMutableArray new];
    [g_keepAlive addObject:o];
    return o;
}

// v41：世界点 → 屏幕点（预测框用，复用已跑通的 W2S）
static int projPred(float x, float y, float z, float sw, float sh, float *ox, float *oy) {
    float px = 0, py = 0;
    if (!w2sPx(x, y, z, &px, &py)) return 0;
    float sc = (g_camPxW > 0 && sw > 1.0f) ? ((float)g_camPxW / sw)
                                           : ((g_uiScale > 0.1f) ? g_uiScale : 3.0f);
    *ox = px / sc;
    *oy = sh - py / sc;
    return 1;
}

// v39：把世界点投到 W2S 的像素空间，供 ref2 用（复用已经跑通的 ABI）
static int w2sPx(float x, float y, float z, float *sx, float *sy) {
    if (!g_camObj || !g_miW2S) return 0;
    void *fn = *(void **)g_miW2S;
    if (!fn) return 0;
    Vec3 wp = { x, y, z };
    Vec3 sp = ((Vec3 (*)(void *, Vec3, void *))fn)(g_camObj, wp, g_miW2S);
    if (!(sp.z > 0.01f)) return 0;
    if (!(sp.x > -1e6f && sp.x < 1e6f && sp.y > -1e6f && sp.y < 1e6f)) return 0;
    *sx = sp.x; *sy = sp.y;
    return 1;
}

// v38：这个 ObjID 是否处于「死亡/失联」记忆里（位置是冻结的，不能参与 FOG 统计）
static int isGoneById(unsigned int id) {
    if (id == 0) return 0;
    for (int k = 0; k < 64; k++) if (g_gone[k].id == id && g_gone[k].id != 0) return 1;
    return 0;
}

// v40：ref1 —— 按 GetRawHostPlayerActorId() 的 id 找本机主身。
// 注意：id 用 unsigned 比较，是否可用由 g_rawOk 决定，绝不用「<0」当失败标志，
// 否则 id 高位为 1 的正数会被误判成失败。
static int heroIdxById(unsigned int *lid, int n) {
    if (g_rawHostId == -2) {
        if (!g_mgr) return -1;
        int rc = callInt0(g_mgr, "GetRawHostPlayerActorId");
        g_rawHostId = rc;
        g_rawOk = (rc != -2 && rc != -3 && rc != -1) ? 1 : 0;   // -1/-2/-3 是调用失败码
    }
    if (!g_rawOk || g_rawHostId <= 0) return -1;
    unsigned int want = (unsigned int)g_rawHostId;
    for (int i = 0; i < n; i++) if (lid[i] == want) return i;
    return -1;
}

// v40：ref2 —— W2S 投影最接近屏幕中心的那个主身（王者相机就是跟自己的）。
// 阈值收到 fullW * 0.15 ≈ 393px：太松的话相机一旦不是本局那台，W2S 整体错位，
// 我们仍会「挑到最近的那个」，静默给出错误参考点。
static int heroIdxByScreen(float lp[][3], int n) {
    float fullW = (g_camPxW > 0) ? (float)g_camPxW : (g_scrW * 3.0f);
    float fullH = (g_camPxH > 0) ? (float)g_camPxH : (g_scrH * 3.0f);
    if (fullW < 100.0f) return -1;
    float ccx = fullW * 0.5f, ccy = fullH * 0.5f;
    float best = 1e9f; int bi = -1;
    for (int i = 0; i < n; i++) {
        float px = 0, py = 0;
        if (!w2sPx(lp[i][0], lp[i][1], lp[i][2], &px, &py)) continue;
        float dd = fabsf(px - ccx) + fabsf(py - ccy);
        if (dd < best) { best = dd; bi = i; }
    }
    return (bi >= 0 && best < fullW * 0.15f) ? bi : -1;
}

// v40：ref3 —— 相机 transform.position，带地理 gate（局内 Camera.main 是 null，
// g_camObj 可能是大厅那台，坐标若不在英雄包围盒 ±2000 内就弃用）。
static int camRefPos(float lp[][3], int n, float *ox, float *oz) {
    static int s_tpWarn = 0;
    if (!g_camObj || !g_uCamClass || !I2.class_get_method_from_name) return 0;
    // v49：只有相机对象的 klass 与 g_uCamClass 一致时才调它的方法
    {
        void *ck = NULL;
        if (!rd(g_camObj, &ck, sizeof(ck)) || !ck || ck != g_uCamClass) {
            if (!s_tpWarn) { s_tpWarn = 1; CHECK("FOGV camRef skip (klass != uCamClass)"); }
            return 0;
        }
    }
    void *mTr = I2.class_get_method_from_name(g_uCamClass, "get_transform", 0);
    if (!mTr || !*(void **)mTr) return 0;
    void *tr = ((void *(*)(void *, void *))(*(void **)mTr))(g_camObj, mTr);
    void *trCls = NULL;
    if (!tr || !rd(tr, &trCls, sizeof(trCls)) || !trCls) return 0;
    void *mPos = I2.class_get_method_from_name(trCls, "get_position", 0);
    if (!mPos || !*(void **)mPos) return 0;
    Vec3 v = ((Vec3 (*)(void *, void *))(*(void **)mPos))(tr, mPos);
    if (!(v.x == v.x && v.z == v.z && (v.x != 0.0f || v.z != 0.0f))) return 0;
    float mnx = 1e9f, mxx = -1e9f, mnz = 1e9f, mxz = -1e9f;
    for (int i = 0; i < n; i++) {
        if (lp[i][0] < mnx) mnx = lp[i][0];
        if (lp[i][0] > mxx) mxx = lp[i][0];
        if (lp[i][2] < mnz) mnz = lp[i][2];
        if (lp[i][2] > mxz) mxz = lp[i][2];
    }
    if (v.x < mnx - 2000.0f || v.x > mxx + 2000.0f ||
        v.z < mnz - 2000.0f || v.z > mxz + 2000.0f) {
        if (!s_tpWarn) { s_tpWarn = 1; CHECK("FOGV camPos rejected (camera not in map)"); }
        return 0;
    }
    *ox = v.x; *oz = v.z;
    return 1;
}

// v48：按「名字/忽略大小写」找字段（给探针用，找不到返回 NULL）
static void *fieldByNameish(void *cls, const char *name) { return findField(cls, name); }

// v48：定点数换算系数（VInt3.Precision 之类）。0 = 还没读到
static float g_vintScale = 0.0f;

// 在 VInt3 类里找 Precision / PrecisionFactor 静态字段，读出换算系数
static float vintScaleOf(void *vcls) {
    if (g_vintScale > 0.0f) return g_vintScale;
    if (!vcls || !I2.field_static_get_value) return 1000.0f;
    const char *names[2] = { "Precision", "PrecisionFactor" };
    for (int i = 0; i < 2; i++) {
        void *f = fieldByNameish(vcls, names[i]);
        if (!f) continue;
        // v49：非静态字段调 field_static_get_value 会从无效静态区取值 → 闪退。
        // il2cpp 的 FIELD_ATTRIBUTE_STATIC = 0x10。
        if (I2.field_get_flags && !(I2.field_get_flags(f) & 0x10)) {
            CHECK("MVSCALE %s not static, skip", names[i]);
            continue;
        }
        unsigned char raw[16] = {0};
        I2.field_static_get_value(f, raw);
        float asF = 0; int asI = 0;
        memcpy(&asF, raw, 4); memcpy(&asI, raw, 4);
        float cand = 0;
        if (asF > 0.001f && asF < 1e6f) cand = asF;
        else if (asI > 0 && asI < 1000000) cand = (float)asI;
        if (cand > 0.0f) {
            // v48：语义可能反 —— Precision 有存 1000（整数→float 要除）也有存 0.001（要乘）。
            // 统一成「除数」：0.001 → 1000。
            if (cand < 1.0f) cand = 1.0f / cand;
            g_vintScale = cand;
            CHECK("MVSCALE %s = %.3f (as divisor)", names[i], cand);
            return cand;
        }
    }
    g_vintScale = 1000.0f;      // 兜底：MOBA 定点常见 1000
    CHECK("MVSCALE default 1000");
    return g_vintScale;
}

// v48：读一个「位置类」字段 —— 可能是 Vector3(float×3)，也可能是 VInt3(int×3 定点)
// v48：把「位置类字段」的原始整数也打出来，量级对不对一眼可见（判 MVSCALE 方向用）
static int readPosFieldRaw(void *obj, void *fld, float *out, int *raw, const char **kindOut) {
    void *ft = I2.field_get_type(fld);
    const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : NULL;
    if (!tn) return 0;
    int off = (int)I2.field_get_offset(fld);
    if (strstr(tn, "Vector3")) {
        rd((char *)obj + off, out, sizeof(float) * 3);
        *kindOut = "V3";
        if (raw) { raw[0] = raw[1] = raw[2] = 0; }
        return 1;
    }
    if (strstr(tn, "VInt3") || strstr(tn, "Int3")) {
        int iv[3] = {0, 0, 0};
        rd((char *)obj + off, iv, sizeof(iv));
        void *vcls = (ft && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(ft) : NULL;
        float sc = vintScaleOf(vcls);
        out[0] = (float)iv[0] / sc;
        out[1] = (float)iv[1] / sc;
        out[2] = (float)iv[2] / sc;
        if (raw) { raw[0] = iv[0]; raw[1] = iv[1]; raw[2] = iv[2]; }
        *kindOut = "VI3";
        return 1;
    }
    return 0;
}

// v48：MoveControl 可能是 PoolObjHandle<T> 包装（值类型或装箱对象），
// 这时要先从 _handleObj 解出真正的组件指针，否则会对着一层壳枚举字段，误判「没有位置字段」。
static void *resolvePoolHandle(void *holder, void *holderCls) {
    if (!holder || !holderCls) return NULL;
    const char *cn = I2.class_get_name ? I2.class_get_name(holderCls) : NULL;
    if (cn && !strstr(cn, "PoolObjHandle") && !strstr(cn, "Handle")) return holder;   // 不是包装
    void *hf = fieldByNameish(holderCls, "_handleObj");
    if (!hf) return holder;
    int hoff = (int)I2.field_get_offset(hf);
    void *inner = NULL;
    if (rd((char *)holder + hoff, &inner, sizeof(inner)) && inner) {
        static int s_log = 0;
        if (!s_log) { s_log = 1; CHECK("MVH unwrap %s _handleObj @%d -> %p", cn ? cn : "?", hoff, inner); }
        return inner;
    }
    return NULL;
}

static int readPosField(void *obj, void *fld, float *out, const char **kindOut) {
    void *ft = I2.field_get_type(fld);
    const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : NULL;
    if (!tn) return 0;
    int off = (int)I2.field_get_offset(fld);
    if (strstr(tn, "Vector3")) {
        rd((char *)obj + off, out, sizeof(float) * 3);
        *kindOut = "V3";
        return 1;
    }
    if (strstr(tn, "VInt3") || strstr(tn, "Int3")) {
        int iv[3] = {0, 0, 0};
        rd((char *)obj + off, iv, sizeof(iv));
        void *vcls = (ft && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(ft) : NULL;
        float sc = vintScaleOf(vcls);
        out[0] = (float)iv[0] / sc;
        out[1] = (float)iv[1] / sc;
        out[2] = (float)iv[2] / sc;
        *kindOut = "VI3";
        return 1;
    }
    return 0;
}

// v48：CampsActors 探针 —— ActorManager 上按阵营分组的容器。
// 注意：actorList / updatableActorList 都是 DictionaryView（结构体包装，Context@8），
// CampsActors 极可能也是 → 类型名含 DictionaryView 就先跳 Context 再读。
static void probeCamps(void) {
    if (!g_mgr) return;
    void *mcls = NULL;
    if (!rd(g_mgr, &mcls, sizeof(mcls)) || !mcls) { CHECK("CAMP no mcls"); return; }
    void *f = fieldByNameish(mcls, "CampsActors");
    if (!f) { CHECK("CAMP no field"); return; }
    int off = (int)I2.field_get_offset(f);
    void *ft = I2.field_get_type(f);
    const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : "?";
    void *cv = NULL;
    rd((char *)g_mgr + off, &cv, sizeof(cv));
    CHECK("CAMP off %d type %s obj %p", off, tn ? tn : "?", cv);
    if (!cv) return;
    void *dict = cv;
    if (tn && strstr(tn, "DictionaryView")) {
        void *ctx = NULL;
        if (g_ctxOff > 0 && rd((char *)cv + g_ctxOff, &ctx, sizeof(ctx)) && ctx) {
            dict = ctx;
            CHECK("CAMP view -> ctx %p", dict);
        } else {
            CHECK("CAMP view but no ctx (ctxOff %d)", g_ctxOff);
        }
    }
    int cnt = 0; void *ent = NULL;
    rd((char *)dict + 0x18, &cnt, sizeof(cnt));
    rd((char *)dict + 0x10, &ent, sizeof(ent));
    CHECK("CAMP cnt %d ent %p", cnt, ent);
    if (!ent || cnt <= 0 || cnt > 4096) return;
    for (int i = 0; i < cnt && i < 3; i++) {
        int key = 0;
        rd((char *)ent + g_arrBase + (size_t)i * 24 + 8, &key, sizeof(key));
        void *val = NULL;
        rd((char *)ent + g_arrBase + (size_t)i * 24 + 16, &val, sizeof(val));
        CHECK("CAMP key %d val %p", key, val);
    }
}

// v48：MoveComponent 探针 —— 位置真值很可能不在 ActorLinker.position（渲染副本），
// 而在 curPosition（平滑后的显示值）/ remotePosition（服务器下发的权威值）里。

// ================= v60：侦察版 =================
// 三条纪律：只做 1 个英雄 / 枚举前判空并校验类 / 数值必须带类型打印。

// UTF-16 → UTF-8。**8 字节对象头**：len@0x08，chars@0x0C（和 readUtf16At 一致）。
// v61：上一版写成 len@0x10 —— 那是 16 字节头的布局，混用会拿字符内容当长度，轻则乱码重则崩。
static void readStrUtf8(void *sObj, char *out, int cap) {
    out[0] = 0;
    if (!sObj || cap < 4) return;
    int len = 0;
    if (!rd((char *)sObj + 0x08, &len, 4) || len <= 0 || len > 64) return;
    unsigned short buf[65];
    if (!rd((char *)sObj + 0x0C, buf, (size_t)len * 2)) return;
    buf[len] = 0;
    NSString *ns = [NSString stringWithCharacters:buf length:(NSUInteger)len];
    const char *u = ns ? [ns UTF8String] : NULL;
    if (u) snprintf(out, cap, "%s", u);
}

// v63：名字按 ObjID 缓存 —— 每个单位只解一次 UTF-16，不每帧解
static unsigned int g_nmId[32] = {0};
static char         g_nmStr[32][40];
static int          g_nmN = 0;

static const char *nameOfUnit(void *obj, unsigned int id) {
    if (!obj || !id) return "";
    for (int i = 0; i < g_nmN; i++) if (g_nmId[i] == id) return g_nmStr[i];
    void *sp = NULL;
    rd((char *)obj + 0x4B0, &sp, sizeof(sp));
    char tmp[40];
    readStrUtf8(sp, tmp, sizeof(tmp));
    if (g_nmN < 32) {
        g_nmId[g_nmN] = id;
        snprintf(g_nmStr[g_nmN], 40, "%s", tmp);
        g_nmN++;
        return g_nmStr[g_nmN - 1];
    }
    return "";
}

// v63：自己的世界坐标（优先 rawHostId 对应的单位，取不到就用相机点）
static float g_selfX = 0, g_selfZ = 0;
static int   g_selfOk = 0;

// 把一个对象的字段全打出来（只打会读的值类型，其余只报名字，避免把指针当数字）
static int dumpObjFields(const char *tag, void *obj, void *cls, int maxLines) {
    if (!obj || !cls || !I2.class_get_fields) { CHECK("%s skip (null)", tag); return 0; }
    void *it = NULL;
    void **fs = I2.class_get_fields(cls, &it);
    if (!fs) { CHECK("%s skip (no fields)", tag); return 0; }
    int shown = 0;
    for (int i = 0; fs[i] && shown < maxLines; i++) {
        void *f = fs[i];
        const char *fn = I2.field_get_name ? I2.field_get_name(f) : NULL;
        if (!fn) continue;
        int off = (int)I2.field_get_offset(f);
        if (off < 0) continue;
        void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
        const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : "?";
        if (!tn) tn = "?";
        if (strstr(tn, "Int32") || strstr(tn, "UInt32") || strstr(tn, "Boolean")) {
            int v = 0; rd((char *)obj + off, &v, 4);
            CHECK("%s %s @%d %s = %d", tag, fn, off, tn, v);
        } else if (strstr(tn, "Single")) {
            float v = 0; rd((char *)obj + off, &v, 4);
            CHECK("%s %s @%d %s = %.2f", tag, fn, off, tn, v);
        } else if (strstr(tn, "Vector3") || strstr(tn, "VInt3") || strstr(tn, "Int3")) {
            float v[3] = {0, 0, 0}; rd((char *)obj + off, v, 12);
            CHECK("%s %s @%d %s = %.1f,%.1f,%.1f", tag, fn, off, tn, v[0], v[1], v[2]);
        } else {
            CHECK("%s %s @%d %s", tag, fn, off, tn);   // 其它类型只报名字
        }
        shown++;
    }
    if (shown == 0) CHECK("%s (no printable field)", tag);
    return shown;
}

// v61：把「候选字段名 → 偏移 / 命中类」并列打出来。
// 上一版把 MoveControl 解析到 @1144，和 PositionRecords@1144 撞了 —— 同偏移不可能是两个字段，
// 所以先把每个候选名的真实归属打清楚，再决定用哪个。
static void *findFieldEx(void *cls, const char *name, int *depthOut, void **ownerOut);
static void probeCompOffsets(void) {
    // v62：判据是**类型指纹**（类型比偏移硬）：同名同偏移两次打出不同类型，
    // 说明父类链上有同名字段、谁先命中看遍历顺序 —— 所以每行带上 parent#N + 类名。
    // v62b：want 分两类 —— 组件引用在本代码库里就是 PoolObjHandle<T> 包装，属正常写法；
    //        只有数据字段（PositionRecords）才要求精确类型。
    struct { const char *n; const char *expect; int wrapOk; } tab[] = {
        { "PositionRecords", "List",           0 },
        { "MoveComponent",   "MoveComponent",  1 },
        { "MoveControl",     "MoveComponent",  1 },
        { "MoveCtrl",        "MoveComponent",  1 },
        { "ActorMove",       "MoveComponent",  1 },
        { "ValueComponent",  "ValueComponent", 1 },
        { "SkillControl",    "SkillControl",   1 },
        { "SkillComponent",  "SkillControl",   1 },
        { "charInfo",        "CharInfo",       1 },
        { "CharInfo",        "CharInfo",       1 },
    };
    for (int i = 0; i < (int)(sizeof(tab) / sizeof(tab[0])); i++) {
        int depth = -1; void *owner = NULL;
        void *f = findFieldEx(g_linkerClass, tab[i].n, &depth, &owner);
        if (!f) { CHECK("COFF %-16s (none)", tab[i].n); continue; }
        int off = (int)I2.field_get_offset(f);
        void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
        const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : "?";
        const char *oc = (owner && I2.class_get_name) ? I2.class_get_name(owner) : "?";
        int exact   = (tn && strstr(tn, tab[i].expect)) ? 1 : 0;
        int wrapped = (tab[i].wrapOk && tn && strstr(tn, "PoolObjHandle")) ? 1 : 0;
        const char *verdict = exact ? "OK" : (wrapped ? "OK(wrapped)" : "MISMATCH");
        CHECK("COFF %-16s @%d in parent#%d %-14s type %-34s want %-14s %s",
              tab[i].n, off, depth, oc ? oc : "?", tn ? tn : "?", tab[i].expect, verdict);
    }
}

// v62：带「命中了哪一层父类」的字段查找 —— 同名同偏移可能来自父类，必须打清楚
static void *findFieldEx(void *cls, const char *name, int *depthOut, void **ownerOut) {
    void *c = cls;
    for (int d = 0; d < 5 && c; d++) {
        void *f = findFieldOne(c, name);
        if (f) {
            if (depthOut) *depthOut = d;
            if (ownerOut) *ownerOut = c;
            return f;
        }
        c = I2.class_get_parent ? I2.class_get_parent(c) : NULL;
    }
    return NULL;
}

// 取英雄上的一个组件（自动区分「内联结构体」和「引用」），然后 dump 它的字段
static void dumpOneComponent(const char *fieldName, void *hero, int maxLines) {
    void *f = findField(g_linkerClass, fieldName);
    if (!f) { CHECK("HID %s (no such field)", fieldName); return; }
    int off = (int)I2.field_get_offset(f);
    void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
    void *kc = (ft && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(ft) : NULL;
    if (!kc) { CHECK("HID %s @%d (type->class failed)", fieldName, off); return; }
    int isVal = I2.class_is_valuetype ? (I2.class_is_valuetype(kc) ? 1 : 0) : 0;
    void *obj = NULL;
    if (isVal) {
        obj = (char *)hero + off;
    } else {
        rd((char *)hero + off, &obj, sizeof(obj));
        if (!obj) { CHECK("HID %s @%d ptr null", fieldName, off); return; }
        void *k2 = NULL;
        if (!rd(obj, &k2, sizeof(k2)) || k2 != kc) {
            CHECK("HID %s @%d klass mismatch skip", fieldName, off);
            return;
        }
    }
    const char *cn = I2.class_get_name ? I2.class_get_name(kc) : "?";
    CHECK("HID %s @%d %s %s", fieldName, off, isVal ? "inline" : "ptr", cn ? cn : "?");
    // v62：PoolObjHandle<T> 只是包装，真正的组件在 _handleObj 里 —— 必须再解一层，
    // 否则会误判「ValueComponent 里没有 hp」。
    if (cn && strstr(cn, "PoolObjHandle")) {
        void *hf = findFieldOne(kc, "_handleObj");
        if (!hf) {
            CHECK("HID   PoolObjHandle has no _handleObj");
        } else {
            int hoff = (int)I2.field_get_offset(hf);
            // v62b：偏移 0 不是「在开头」，而是**拿到了开放泛型**（实测开放泛型下
            // _handleSeq/_handleObj 都报 0）。此时按 0 去读会把 seq 的低 32 位当指针解引用。
            if (hoff == 0) {
                CHECK("HID   unwrap skip: _handleObj@0 (open generic?)");
            } else {
                unsigned int seq = 0;
                void *sf = findFieldOne(kc, "_handleSeq");
                int soff = sf ? (int)I2.field_get_offset(sf) : -1;
                if (soff > 0) rd((char *)obj + soff, &seq, 4);
                void *target = NULL;
                rd((char *)obj + hoff, &target, sizeof(target));
                CHECK("HID   handle seq %u obj %p", seq, target);
                if (!target) {
                    CHECK("HID   _handleObj null");
                } else {
                    void *tk = NULL;
                    if (rd(target, &tk, sizeof(tk)) && tk) {
                        const char *tcn = I2.class_get_name ? I2.class_get_name(tk) : "?";
                        CHECK("HID   unwrap _handleObj -> %s", tcn ? tcn : "?");
                        dumpObjFields("HID   ", target, tk, 30);
                    }
                }
            }
        }
    }
    // v61：撞偏移自检 —— 同一个偏移被两个候选名命中就打印出来
    static int s_seenOff[16]; static char s_seenName[16][24]; static int s_seenN = 0;
    for (int i = 0; i < s_seenN; i++) {
        if (s_seenOff[i] == off && strcmp(s_seenName[i], fieldName) != 0)
            CHECK("COFF collision @%d: %s vs %s", off, s_seenName[i], fieldName);
    }
    if (s_seenN < 16) {
        s_seenOff[s_seenN] = off;
        snprintf(s_seenName[s_seenN], 24, "%s", fieldName);
        s_seenN++;
    }
    dumpObjFields("HID  ", obj, kc, maxLines);
}

// 找一个「真英雄」：type 匹配 + pid>0 + ObjID!=0
static void *findHeroForDeep(unsigned int *outId, int *outPid) {
    if (!g_lastEntries || g_lastCnt <= 0) return NULL;
    int lim = (g_lastCnt < 160) ? g_lastCnt : 160;
    int want = (g_heroType >= 0) ? g_heroType : 0;
    for (int i = 0; i < lim; i++) {
        void *v = NULL, *k = NULL;
        if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;
        int T = 0, C = 0, pid = 0;
        readIdentity2(v, &T, &C, NULL, &pid, NULL, NULL);
        if (T != want || pid <= 0) continue;
        unsigned int id = 0;
        rd((char *)v + 0x4AC, &id, 4);
        if (!id) continue;
        if (outId) *outId = id;
        if (outPid) *outPid = pid;
        return v;
    }
    return NULL;
}

static void probeHeroDeep(void) {
    unsigned int id = 0; int pid = 0;
    void *hero = findHeroForDeep(&id, &pid);
    if (!hero) { CHECK("HID none (heroType %d)", g_heroType); return; }
    char nm[64]; void *sp = NULL;
    rd((char *)hero + 0x4B0, &sp, sizeof(sp));
    readStrUtf8(sp, nm, sizeof(nm));
    float p[3] = {0, 0, 0};
    rd((char *)hero + 0x4C4, p, sizeof(p));
    CHECK("HID id %u pid %d T %d name \"%s\" pos %.0f,%.0f", id, pid, g_heroType, nm, p[0], p[2]);

    // 视野 / 隐身候选（有就打印原始值，不做解释）
    const char *visNames[] = { "bGetVisibleComponent", "invisibleSpecialComponents", "hudDisguiseType" };
    for (int i = 0; i < 3; i++) {
        void *f = findField(g_linkerClass, visNames[i]);
        if (!f) { CHECK("HID %s (no field)", visNames[i]); continue; }
        int off = (int)I2.field_get_offset(f);
        int v = 0; rd((char *)hero + off, &v, 4);
        void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
        const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : "?";
        CHECK("HID %s @%d %s raw %d", visNames[i], off, tn ? tn : "?", v);
    }

    // v61：先把候选字段名 → 偏移/类的对照表打出来（撞偏移一眼可见）
    probeCompOffsets();

    // 组件深度 dump（名字都试两种写法）
    dumpOneComponent("MoveControl", hero, 30);
    dumpOneComponent("MoveComponent", hero, 30);
    dumpOneComponent("ValueComponent", hero, 30);
    dumpOneComponent("SkillControl", hero, 30);
    dumpOneComponent("SkillComponent", hero, 30);
    dumpOneComponent("charInfo", hero, 30);
    dumpOneComponent("CharInfo", hero, 30);
}

// v60：阵营走成员关系 —— GetCampActors(1)/(2) 返回 List，打 size + 头 8 个 dword
static void probeCampMem(void) {
    if (!g_mgr || !g_mgrClass || !I2.class_get_method_from_name) { CHECK("CAMP2 no mgr"); return; }
    void *mi = I2.class_get_method_from_name(g_mgrClass, "GetCampActors", 1);
    if (!mi) { CHECK("CAMP2 no GetCampActors(int)"); return; }
    void *fn = *(void **)mi;
    if (!fn) { CHECK("CAMP2 methodPointer null"); return; }
    // v61：先看返回类型。引用类型 → x0 即指针，可普通调用；
    // 值类型/结构体 → 必须走 sret（隐藏 x8 缓冲区），按指针调会拿到垃圾甚至崩。
    {
        void *rt = I2.method_get_return_type ? I2.method_get_return_type(mi) : NULL;
        const char *tn = (rt && I2.type_get_name) ? I2.type_get_name(rt) : "?";
        void *rc = (rt && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(rt) : NULL;
        int rval = (rc && I2.class_is_valuetype) ? (I2.class_is_valuetype(rc) ? 1 : 0) : -1;
        CHECK("CAMP2 ret %s val %d", tn ? tn : "?", rval);
        if (rval == 1) { CHECK("CAMP2 value-type return, sret not attempted"); return; }
        if (rval < 0)  { CHECK("CAMP2 return type unresolved, skip call");  return; }
    }
    for (int camp = 1; camp <= 2; camp++) {
        void *lst = ((void *(*)(void *, int, void *))fn)(g_mgr, camp, mi);
        if (!lst) { CHECK("CAMP2 camp%d list null", camp); continue; }
        void *lk = NULL; rd(lst, &lk, sizeof(lk));
        const char *cn = (lk && I2.class_get_name) ? I2.class_get_name(lk) : "?";
        int d[8] = {0};
        rd(lst, d, sizeof(d));
        CHECK("CAMP2 camp%d %s d0 %08x d1 %08x d2 %08x d3 %08x d4 %08x d5 %08x",
              camp, cn ? cn : "?", d[0], d[1], d[2], d[3], d[4], d[5]);
        // 若是 List<T>：_items@0x08, _size@0x10
        void *items = NULL; int size = -1;
        rd((char *)lst + 0x08, &items, sizeof(items));
        rd((char *)lst + 0x10, &size, 4);
        CHECK("CAMP2 camp%d items %p size %d", camp, items, size);
    }
}
// ================= v60 end =================


// ================= v64：L2 / L3（合并扫描） =================
// ① L3a/L3b 合并成一次全表遍历：只卡一次，两段看到同一帧类表
// ② L2 每行带 via（组件字段名@偏移 + 类名），判据在日志里自证

// 类的字段布局（只打名字/偏移/类型，不读值）
static void dumpClassLayout(const char *tag, void *cls, int maxLines) {
    if (!cls || !I2.class_get_fields) { CHECK("%s skip", tag); return; }
    void *it = NULL;
    void **fs = I2.class_get_fields(cls, &it);
    if (!fs) { CHECK("%s no fields", tag); return; }
    int shown = 0;
    for (int i = 0; fs[i] && shown < maxLines; i++) {
        void *f = fs[i];
        const char *fn = I2.field_get_name ? I2.field_get_name(f) : NULL;
        if (!fn) continue;
        int off = (int)I2.field_get_offset(f);
        void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
        const char *tn = (ft && I2.type_get_name) ? I2.type_get_name(ft) : "?";
        int isStatic = 0;
        if (I2.field_get_flags) isStatic = (I2.field_get_flags(f) & 0x10) ? 1 : 0;
        CHECK("%s %s @%d %s%s", tag, fn, off, tn ? tn : "?", isStatic ? " static" : "");
        shown++;
    }
    if (shown == 0) CHECK("%s (no printable field)", tag);
}

static int nameHasAny(const char *n, const char *const *keys, int kn) {
    if (!n) return 0;
    for (int i = 0; i < kn; i++) if (strstr(n, keys[i])) return 1;
    return 0;
}

// L3b：把一个协议类里「方法名命中 + 参数含 COMDT_」的方法打出来
static int dumpProtocolMethods(const char *cnm, void *c, int budget) {
    if (!c || !I2.class_get_methods || !budget) return 0;
    static const char *mKeys[] = { "OnRecv", "Handle", "Dispatch", "Process", "Recv", "Msg", "Cmd", "Sync" };
    void *mit = NULL;
    void **ms = I2.class_get_methods(c, &mit);
    if (!ms) return 0;
    int shown = 0;
    for (int m = 0; ms[m] && m < 64 && shown < budget; m++) {
        void *mi = ms[m];
        const char *mn = I2.method_get_name ? I2.method_get_name(mi) : NULL;
        if (!nameHasAny(mn, mKeys, 8)) continue;
        unsigned int pc = I2.method_get_param_count ? I2.method_get_param_count(mi) : 0;
        if (pc == 0 || pc > 8) continue;
        const char *hit = NULL;
        for (unsigned int p = 0; p < pc; p++) {
            void *pt = I2.method_get_param ? I2.method_get_param(mi, p) : NULL;
            const char *ptn = (pt && I2.type_get_name) ? I2.type_get_name(pt) : NULL;
            if (ptn && strstr(ptn, "COMDT_")) { hit = ptn; break; }
        }
        if (hit) {
            CHECK("L3b %s::%s(%s) pc %u", cnm ? cnm : "?", mn ? mn : "?", hit, pc);
            shown++;
        }
    }
    return shown;
}

// L3：一次遍历，同时做 L3a（ActorNodeInfo/ActorData 布局）和 L3b（协议入口）
static void probeL3scan(void) {
    if (!I2.domain_get || !I2.domain_get_assemblies || !I2.assembly_get_image) { CHECK("L3 no api"); return; }
    void *dom = I2.domain_get();
    size_t asmN = 0;                                  // v64b：这个出参是 size_t（个数），不是 void**
    void **a = dom ? I2.domain_get_assemblies(dom, &asmN) : NULL;
    if (!a) { CHECK("L3 no assemblies"); return; }
    int an = (asmN < 512) ? (int)asmN : 512;

    static const char *l3aNames[2] = { "ActorNodeInfo", "ActorData" };
    static const char *clsKeys[] = { "Protocol", "Msg", "Handler", "Dispatch", "Net", "Cmd", "Battle", "Sync" };

    int scanned = 0, l3aHit = 0, clsMatched = 0, methodHit = 0;
    for (int i = 0; i < an; i++) {
        void *img = I2.assembly_get_image(a[i]);
        if (!img) continue;
        int cn = (int)I2.image_get_class_count(img);
        for (int k = 0; k < cn; k++) {
            void *c = I2.image_get_class(img, k);
            if (!c) continue;
            if (++scanned > 64000) break;
            const char *nm = I2.class_get_name ? I2.class_get_name(c) : NULL;
            if (!nm || !nm[0]) continue;

            if (l3aHit < 2) {
                for (int z = 0; z < 2; z++) {
                    if (strcmp(nm, l3aNames[z]) != 0) continue;
                    CHECK("L3a %s found cls %p", nm, c);
                    dumpClassLayout("L3a  ", c, 40);
                    l3aHit++;
                    break;
                }
            }
            if (methodHit < 12 && nameHasAny(nm, clsKeys, 8)) {
                clsMatched++;
                methodHit += dumpProtocolMethods(nm, c, 12 - methodHit);
            }
        }
    }
    CHECK("L3 done scan %d l3a %d cls %d hit %d", scanned, l3aHit, clsMatched, methodHit);
}

// L2：前 3 个英雄的 cur/rem 连续采样（dcur / drem），每行带 via
typedef struct { unsigned int id; float cur[3]; float rem[3]; int n; } L2Ent;
static L2Ent g_l2[3];

static void probeL2(void) {
    unsigned int ids[3]; void *objs[3]; int hn = 0;
    int lim = (g_lastCnt < 160) ? g_lastCnt : 160;
    int want = (g_heroType >= 0) ? g_heroType : 0;
    for (int i = 0; i < lim && hn < 3; i++) {
        void *v = NULL, *k = NULL;
        if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;
        int T = 0, C = 0, pid = 0;
        readIdentity2(v, &T, &C, NULL, &pid, NULL, NULL);
        if (T != want || pid <= 0) continue;
        unsigned int id = 0; rd((char *)v + 0x4AC, &id, 4);
        if (!id) continue;
        ids[hn] = id; objs[hn] = v; hn++;
    }
    if (hn == 0) { CHECK("L2 none (heroType %d)", g_heroType); return; }

    for (int i = 0; i < hn; i++) {
        void *f = findField(g_linkerClass, "MoveComponent");
        const char *fname = "MoveComponent";
        if (!f) { f = findField(g_linkerClass, "MoveControl"); fname = "MoveControl"; }
        if (!f) { CHECK("L2 no MoveComponent field"); return; }
        int off = (int)I2.field_get_offset(f);
        void *ft = I2.field_get_type ? I2.field_get_type(f) : NULL;
        void *mcls = (ft && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(ft) : NULL;
        if (!mcls) { CHECK("L2 no comp class"); return; }
        int isVal = I2.class_is_valuetype ? (I2.class_is_valuetype(mcls) ? 1 : 0) : 0;
        void *mc = NULL;
        if (isVal) {
            mc = (char *)objs[i] + off;
        } else {
            rd((char *)objs[i] + off, &mc, sizeof(mc));
            if (!mc) { CHECK("L2 id %u comp null", ids[i]); continue; }
            void *k2 = NULL;
            if (!rd(mc, &k2, sizeof(k2)) || k2 != mcls) { CHECK("L2 id %u comp klass mismatch", ids[i]); continue; }
        }
        // 被 PoolObjHandle 包着就解一层（并把解包这件事记进 via）
        const char *viaKind = "ptr";
        const char *cn = I2.class_get_name ? I2.class_get_name(mcls) : "?";
        if (cn && strstr(cn, "PoolObjHandle")) {
            void *hf = findFieldOne(mcls, "_handleObj");
            if (hf) {
                int hoff = (int)I2.field_get_offset(hf);
                if (hoff > 0) {
                    void *t = NULL; rd((char *)mc + hoff, &t, sizeof(t));
                    if (t) {
                        void *tk = NULL;
                        if (rd(t, &tk, sizeof(tk)) && tk) { mc = t; mcls = tk; viaKind = "PoolObjHandle"; }
                    }
                } else {
                    CHECK("L2 id %u via skip: _handleObj@0 (open generic)", ids[i]);
                }
            }
        }
        const char *ccn = I2.class_get_name ? I2.class_get_name(mcls) : "?";
        void *fc = findField(mcls, "curPosition");
        void *fr = findField(mcls, "remotePosition");
        float cv[3] = {0, 0, 0}, rv[3] = {0, 0, 0};
        int offC = -1, offR = -1;
        const char *tnC = "?", *tnR = "?";
        if (fc) {
            offC = (int)I2.field_get_offset(fc);
            rd((char *)mc + offC, cv, 12);
            void *t = I2.field_get_type ? I2.field_get_type(fc) : NULL;
            tnC = (t && I2.type_get_name) ? I2.type_get_name(t) : "?";
        }
        if (fr) {
            offR = (int)I2.field_get_offset(fr);
            rd((char *)mc + offR, rv, 12);
            void *t = I2.field_get_type ? I2.field_get_type(fr) : NULL;
            tnR = (t && I2.type_get_name) ? I2.type_get_name(t) : "?";
        }
        // v64b：间距断言 —— VInt3/Vector3 各 12 字节，两者不可能只隔 4 字节；
        // 间距 < 12 说明至少一个不是向量字段，这时 drem 读数不可信。
        if (offC >= 0 && offR > offC && (offR - offC) < 12) {
            CHECK("L2 warn: curPos@%d %s / remPos@%d %s 间距 %d < 12 → 可能不是向量字段",
                  offC, tnC, offR, tnR, offR - offC);
        }

        int sl = -1;
        for (int x = 0; x < 3; x++) if (g_l2[x].id == ids[i]) { sl = x; break; }
        if (sl < 0) { for (int x = 0; x < 3; x++) if (g_l2[x].id == 0) { sl = x; break; } }
        if (sl < 0) { CHECK("L2 table full"); return; }
        float dcur = -1, drem = -1;
        if (g_l2[sl].n > 0) {
            float da = cv[0] - g_l2[sl].cur[0], db = cv[2] - g_l2[sl].cur[2];
            dcur = sqrtf(da * da + db * db);
            da = rv[0] - g_l2[sl].rem[0]; db = rv[2] - g_l2[sl].rem[2];
            drem = sqrtf(da * da + db * db);
        }
        g_l2[sl].id = ids[i];
        g_l2[sl].cur[0] = cv[0]; g_l2[sl].cur[2] = cv[2];
        g_l2[sl].rem[0] = rv[0]; g_l2[sl].rem[2] = rv[2];
        g_l2[sl].n++;
        CHECK("L2 id %u via %s %s@%d | curPos@%d %s | remPos@%d %s | n%d cur %.0f,%.0f rem %.0f,%.0f dcur %.1f drem %.1f",
              ids[i], viaKind, fname, off, offC, tnC, offR, tnR, g_l2[sl].n,
              cv[0], cv[2], rv[0], rv[2], dcur, drem);
    }
}
// ================= v64 end =================

static void probeMove(void) {
    if (!g_lastEntries || g_lastCnt <= 0 || !g_linkerClass) return;
    void *f = fieldByNameish(g_linkerClass, "MoveComponent");
    if (!f) f = fieldByNameish(g_linkerClass, "MoveControl");
    if (!f) {
        // 退一步：按名字枚举含 Move 的字段，把候选打出来
        CHECK("MV no MoveComponent/MoveControl field");
        return;
    }
    int off = (int)I2.field_get_offset(f);
    // v60：先挑出「真英雄」（type 对 + pid>0），再对它们读组件 ——
    // 旧代码直接取列表前 3 个 Actor，取到的全是塔/兵，所以 MV 一直 mc 0x0。
    void *hv[3] = {NULL, NULL, NULL};
    unsigned int hid[3] = {0, 0, 0};
    int hn = 0;
    {
        int lim2 = (g_lastCnt < 160) ? g_lastCnt : 160;
        int want = (g_heroType >= 0) ? g_heroType : 0;
        for (int i = 0; i < lim2 && hn < 3; i++) {
            void *v = NULL, *k = NULL;
            if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
            if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;
            int T = 0, C = 0, pid = 0;
            readIdentity2(v, &T, &C, NULL, &pid, NULL, NULL);
            if (T != want || pid <= 0) continue;
            unsigned int id2 = 0; rd((char *)v + 0x4AC, &id2, 4);
            if (!id2) continue;
            hv[hn] = v; hid[hn] = id2; hn++;
        }
    }
    if (hn == 0) { CHECK("MV none (heroType %d)", g_heroType); return; }
    int shown = 0;
    for (int i = 0; i < hn && shown < 3; i++) {
        void *v = hv[i];
        unsigned int id = hid[i];
        void *mc = NULL;
        void *mft = I2.field_get_type(f);
        void *mcls = (mft && I2.class_from_il2cpp_type) ? I2.class_from_il2cpp_type(mft) : NULL;
        int mval = (mcls && I2.class_is_valuetype) ? (I2.class_is_valuetype(mcls) ? 1 : 0) : 0;
        void *mccls = NULL;
        if (mval) {
            // v49：值类型内联 —— **不能**把结构体首地址当对象头读 klass（那是野指针，
            // 拿它去 class_get_fields 会闪退）。直接用声明类型的字段偏移。
            mc = (char *)v + off;
            mccls = mcls;
        } else {
            rd((char *)v + off, &mc, sizeof(mc));
            if (!mc) {
                CHECK("MV id %u mc 0x0 pos %.0f,%.0f (component not created)", id, 0.0f, 0.0f);
                shown++;
                continue;
            }
            void *k2 = NULL;
            if (!rd(mc, &k2, sizeof(k2)) || !k2) { shown++; continue; }
            // PoolObjHandle 包装：解出真正的组件指针
            const char *cn0 = (mcls && I2.class_get_name) ? I2.class_get_name(mcls) : NULL;
            if (cn0 && (strstr(cn0, "PoolObjHandle") || strstr(cn0, "Handle"))) {
                void *inner = resolvePoolHandle(mc, mcls);
                if (!inner) { CHECK("MV id %u handle empty", id); shown++; continue; }
                mc = inner;
                if (!rd(mc, &k2, sizeof(k2)) || !k2) { shown++; continue; }
            }
            // v49：klass 必须等于字段声明类型，否则就是野指针/读偏了 —— 直接放弃
            if (mcls && k2 != mcls) {
                CHECK("MV id %u klass mismatch (%p != %p), skip", id, k2, mcls);
                shown++;
                continue;
            }
            mccls = k2;
        }
        if (!mc || !mccls) { shown++; continue; }
        float pos[3] = {0, 0, 0};
        rd((char *)v + 0x4C4, pos, sizeof(pos));

        // v50：不再枚举字段（v48 那处枚举已证明可疑），改固定候选名 —— 位置类字段就那么几个
        static int s_dumped = 0;
        if (!s_dumped) {
            s_dumped = 1;
            const char *cn = I2.class_get_name ? I2.class_get_name(mccls) : "?";
            CHECK("MVF cls %s", cn ? cn : "?");
            static const char *kPosNames[] = {
                "curPosition", "remotePosition", "position", "m_Position", "pos",
                "moveForward", "rotation", "tarRotation", "targetPos"
            };
            int dumped = 0;
            for (int j = 0; j < (int)(sizeof(kPosNames) / sizeof(kPosNames[0])); j++) {
                void *fl = fieldByNameish(mccls, kPosNames[j]);
                if (!fl) continue;
                float p3[3] = {0, 0, 0}; int raw3[3] = {0, 0, 0}; const char *kk = "?";
                if (!readPosFieldRaw(mc, fl, p3, raw3, &kk)) continue;
                CHECK("MVF %s @%d %s raw %d,%d -> %.0f,%.0f", kPosNames[j],
                      (int)I2.field_get_offset(fl), kk, raw3[0], raw3[2], p3[0], p3[2]);
                dumped++;
            }
            if (!dumped) CHECK("MVF none (no known pos field)");
        }

        // 每帧都打的对照行：pos vs curPosition vs remotePosition
        float cur[3] = {0, 0, 0}, rem[3] = {0, 0, 0};
        int hasCur = 0, hasRem = 0;
        void *fc = fieldByNameish(mccls, "curPosition");
        void *fr = fieldByNameish(mccls, "remotePosition");
        const char *kk = "?";
        if (fc) hasCur = readPosField(mc, fc, cur, &kk);
        if (fr) hasRem = readPosField(mc, fr, rem, &kk);
        if (hasCur || hasRem) {
            CHECK("MV id %u mc %p pos %.0f,%.0f | cur %.0f,%.0f | rem %.0f,%.0f",
                  id, mc, pos[0], pos[2],
                  hasCur ? cur[0] : -99999.0f, hasCur ? cur[2] : -99999.0f,
                  hasRem ? rem[0] : -99999.0f, hasRem ? rem[2] : -99999.0f);
        } else {
            CHECK("MV id %u mc %p pos %.0f,%.0f | (no cur/rem)", id, mc, pos[0], pos[2]);
        }
        shown++;
    }
}

// v42：探 PositionRecords 是否在「敌人不可见时仍然滚动」，并打印英雄的 PlayerId 分组。
// 这两条决定「掌握动向」是真数据还是只能外推：
//   PositionRecords 的 cnt/首尾在动 → 有真轨迹；全静止 → 客户端只有渲染层那一份副本。
//   PlayerId 1..10 通常按阵营分组，一眼就能反推 camp（ActorMeta.ActorCamp 恒 0 的替代）。
static void probeExtras(void) {
    if (!g_lastEntries || g_lastCnt <= 0) return;
    int lim = (g_lastCnt < 64) ? g_lastCnt : 64;
    int pstN = 0, pidN = 0;
    for (int i = 0; i < lim; i++) {
        if (pstN >= 6 && pidN >= 5) break;
        void *v = NULL, *k = NULL;
        if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;

        unsigned int id = 0;
        rd((char *)v + 0x4AC, &id, 4);
        int aT = 0, aC = 0, cfg = 0, pid = 0, hcfg = 0, rpid = 0;
        readIdentity2(v, &aT, &aC, &cfg, &pid, &hcfg, &rpid);

        // 只统计主身（分身/傀儡会污染 n 与 PlayerId 分组）
        int mir = 0, host = 0, call = 0;
        unsigned char bb = 0;
        if (g_offMirror    >= 0) { bb = 0; rd((char *)v + g_offMirror,    &bb, 1); mir  = bb ? 1 : 0; }
        if (g_offHostActor >= 0) { void *p = NULL; rd((char *)v + g_offHostActor, &p, sizeof(p)); host = p ? 1 : 0; }
        if (g_offCallActor >= 0) { void *p = NULL; rd((char *)v + g_offCallActor, &p, sizeof(p)); call = p ? 1 : 0; }
        int isHero = (g_heroType < 0) ? 1 : (aT == g_heroType);
        if (mir || host || call) continue;

        // ---- PlayerId 分组（按可靠性，这是 camp 恒 0 之后最省事的替代）
        if (pidN < 10 && isHero) {
            CHECK("HP id %u T %d pid %d raw %d cfg %d st %d", id, aT, pid, rpid, cfg, aC);
            pidN++;
        }

        // ---- PositionRecords：同时打「记录末位 l」和「当前 position p」
        if (pstN < 6 && isHero && g_offPosRec >= 0 && g_posRecKind > 0) {
            void *rec = NULL;
            if (rd((char *)v + g_offPosRec, &rec, sizeof(rec)) && rec) {
                int cnt = -1;
                void *data = NULL;
                if (g_posRecKind == 1) { rd((char *)rec + 0x08, &data, sizeof(data)); rd((char *)rec + 0x10, &cnt, 4); }
                else { data = rec; rd((char *)rec + 0x10, &cnt, 4); }
                float cur[3] = {0, 0, 0}, last[3] = {0, 0, 0}, first[3] = {0, 0, 0};
                rd((char *)v + 0x4C4, cur, sizeof(cur));
                if (data && cnt > 0 && cnt <= 512) {
                    int li = (cnt > 1) ? (cnt - 1) : 0;
                    rd((char *)data + g_arrBase, first, sizeof(first));
                    rd((char *)data + g_arrBase + (size_t)li * 12, last, sizeof(last));
                }
                int fn = -1;
                if (g_offFrameNum >= 0) rd((char *)v + g_offFrameNum, &fn, sizeof(fn));
                int dn = -1;
                // ---- v45：跨采样变化量 dl = |l - l_上次采样|
                float dl = -1.0f;
                int ps = -1;
                for (int x = 0; x < 16; x++) if (g_pst[x].id == id && id) { ps = x; break; }
                if (ps < 0) {
                    for (int x = 0; x < 16; x++) if (g_pst[x].id == 0) { ps = x; g_pst[x].id = id; g_pst[x].n = 0; break; }
                }
                if (ps >= 0) {
                    if (g_pst[ps].n > 0) {
                        float ddx = last[0] - g_pst[ps].lx, ddz = last[2] - g_pst[ps].lz;
                        dl = sqrtf(ddx * ddx + ddz * ddz);
                        dn = cnt - g_pst[ps].cn;          // v48：n 的增量，核对「1 秒/点」
                    }
                    g_pst[ps].cn = cnt;
                    g_pst[ps].lx = last[0]; g_pst[ps].lz = last[2]; g_pst[ps].n++;
                }
                int lv = 1, mv = 1;
                unsigned char lb = 0;
                if (g_offLogicVis >= 0) { lb = 0; rd((char *)v + g_offLogicVis, &lb, 1); lv = lb ? 1 : 0; }
                if (g_offMeshVis  >= 0) { lb = 0; rd((char *)v + g_offMeshVis,  &lb, 1); mv = lb ? 1 : 0; }
                // 说明：|l - p| 不再是判据 —— 活着可见时记录末位本来就等于当前位置，
                // 冻结时记录器写的也是那个冻结值，两种情况的 |l-p| 都≈0，区分不了。
                // 判据是上面的 dl（跨采样变化）。
                CHECK("PST id %u n %d dn %d p %.0f,%.0f l %.0f,%.0f dl %.0f lv%d mv%d fn %d gap %.2f",
                      id, cnt, dn, cur[0], cur[2], last[0], last[2], dl, lv, mv, fn, g_posRecGap);
                pstN++;
            } else {
                CHECK("PST id %u rec null", id);
                pstN++;
            }
        }
    }
    if (g_pidRuns < 3) g_pidRuns++;
    if (g_pstRuns < 3) g_pstRuns++;
}

// v40：FOG 探针。判据只看「敌方主身」+「距离分桶 + 位移」。
// 队友永远可见（小地图一直有），远处的队友会一直在动 —— 混进 6k+ 就会把结论灌成
// 「全图实时下发」，和之前用英雄质心是同一类假阳性。所以这里先定本阵营，只统计敌人。
static void fogProbe(void) {
    if (!g_lastEntries || g_lastCnt <= 0) return;
    if (g_unitCount < 40) return;                 // 兵线没出来不采样
    if (g_heroType < 0) {
        if (g_fogRuns == 0) CHECK("FOGV skip (heroType unknown)");
        return;
    }
    // v49：白名单自证成功后，fog 的参考点计算会第一次真正执行。
    // 先用「对象头 klass」确认相机没换类型，再往下走，避免跨类型调方法。
    {
        void *ck = NULL;
        if (!g_camObj || !rd(g_camObj, &ck, sizeof(ck)) || !ck) {
            if (g_fogRuns == 1) CHECK("FOGV skip (no camera)");
            return;
        }
        if (g_camKlass && ck != g_camKlass) {
            if (g_fogRuns <= 2) CHECK("FOGV skip (cam klass changed)");
            return;
        }
    }
    float now = (float)CACurrentMediaTime();
    int lim = (g_lastCnt < 160) ? g_lastCnt : 160;   // v59：和绘制/直方图一致，别漏掉排在后面的英雄

    unsigned int lid[16]; float lp[16][3]; int lT[16], lC[16], lmv[16], llv[16], lcam[16];
    int lPid[16];
    int n = 0, summon = 0, inact = 0;
    for (int i = 0; i < lim && n < 16; i++) {
        void *v = NULL, *k = NULL;
        if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;
        int T = 0, C = 0, pid = 0;
        readIdentity2(v, &T, &C, NULL, &pid, NULL, NULL);
        if (T != g_heroType) continue;
        int mv = 1, lv = 1, cam = 0, mir = 0, host = 0, call = 0;
        unsigned char bb = 0;
        if (g_offMeshVis  >= 0) { bb = 0; rd((char *)v + g_offMeshVis,  &bb, 1); mv  = bb ? 1 : 0; }
        if (g_offLogicVis >= 0) { bb = 0; rd((char *)v + g_offLogicVis, &bb, 1); lv  = bb ? 1 : 0; }
        if (g_offInCam    >= 0) { bb = 0; rd((char *)v + g_offInCam,    &bb, 1); cam = bb ? 1 : 0; }
        if (g_offMirror   >= 0) { bb = 0; rd((char *)v + g_offMirror,   &bb, 1); mir = bb ? 1 : 0; }
        if (g_offHostActor >= 0) { void *p = NULL; rd((char *)v + g_offHostActor, &p, sizeof(p)); host = p ? 1 : 0; }
        if (g_offCallActor >= 0) { void *p = NULL; rd((char *)v + g_offCallActor, &p, sizeof(p)); call = p ? 1 : 0; }
        if (mir || host || call) { summon++; continue; }        // 分身/傀儡单独计
        // v54：**不再过滤**。雾里单位天然 mv=0，过滤掉就等于把「要测的东西」删了。
        // 改成按 mv 分组统计（下面 g1m/g1t），让「一组有位移、一组恒 0」自己浮出来。
        if (!mv && !cam) inact++;      // 只计数，不停采样
        unsigned int id = 0;
        rd((char *)v + 0x4AC, &id, 4);
        lid[n] = id; lT[n] = T; lC[n] = C; lmv[n] = mv; llv[n] = lv; lcam[n] = cam; lPid[n] = pid;
        lp[n][0] = lp[n][1] = lp[n][2] = 0;
        rd((char *)v + 0x4C4, lp[n], sizeof(float) * 3);
        if (lp[n][0] == 0.0f && lp[n][2] == 0.0f) { inact++; continue; }   // 回收槽
        n++;
    }
    if (n == 0) { CHECK("FOGV none (u %d inact %d)", g_unitCount, inact); return; }

    // ---- 参考点：ref1 → ref2 → ref3
    int i1 = heroIdxById(lid, n);
    int i2 = heroIdxByScreen(lp, n);
    if (i1 >= 0 && i2 >= 0 && i1 != i2) {
        float dx = lp[i1][0] - lp[i2][0], dz = lp[i1][2] - lp[i2][2];
        float dd = sqrtf(dx * dx + dz * dz);
        if (dd > 1500.0f)
            CHECK("REF MISMATCH r1 %.0f,%.0f r2 %.0f,%.0f d %.0f",
                  lp[i1][0], lp[i1][2], lp[i2][0], lp[i2][2], dd);
    }
    float rx = 0, rz = 0; int refSrc = 0, refIdx = -1;
    if (i1 >= 0)      { rx = lp[i1][0]; rz = lp[i1][2]; refSrc = 1; refIdx = i1; }
    else if (i2 >= 0) { rx = lp[i2][0]; rz = lp[i2][2]; refSrc = 2; refIdx = i2; }
    else if (camRefPos(lp, n, &rx, &rz)) { refSrc = 3; }
    if (!refSrc) { CHECK("FOGV skip (no local pos) rawHost %d ok %d", g_rawHostId, g_rawOk); return; }

    if (g_myCamp == 0 && refIdx >= 0) g_myCamp = lC[refIdx];     // 本阵营 = 参考点英雄的 ActorCamp

    int mov = 0, rt = 0, fz = 0, ninit = 0, enemies = 0;
    int g1m[2] = {0, 0}, g1t[2] = {0, 0};   // v54：[0]=mv0 组，[1]=mv1 组；m=有位移数 t=总数
    int evz = 0, evzTot = 0;                // v55：mv0 && dv>0 && pid>0 的唯一单位数 / 唯一单位总数
    float dmin = 1e9f, dmax = 0;
    for (int i = 0; i < n; i++) {
        int isMe = (i == refIdx);
        int isAlly = (g_myCamp != 0 && lC[i] == g_myCamp);
        int sl = -1;
        for (int x = 0; x < 16; x++) if (g_fog[x].id == lid[i] && lid[i] != 0) { sl = x; break; }
        if (sl < 0) {
            for (int x = 0; x < 16; x++) if (g_fog[x].id == 0) { sl = x; break; }
            if (sl >= 0) {
                g_fog[sl].id = lid[i]; g_fog[sl].n = 0;
                g_fog[sl].movedOnce = 0; g_fog[sl].stillCnt = 0; g_fog[sl].frz = 0;
                g_fog[sl].evzCnt = 0; g_fog[sl].evzMoved = 0;
                g_fog[sl].lastMv = 1;      // 首次见面当作「上次可见」，避免第一拍就误判
                g_fog[sl].t = now;
            }
        }
        float dv = -1.0f;
        if (sl >= 0) {
            if (g_fog[sl].n > 0) {
                float dx = lp[i][0] - g_fog[sl].p[0], dz = lp[i][2] - g_fog[sl].p[2];
                dv = sqrtf(dx * dx + dz * dz);
            }
            // v58：换人判据改用 ObjID（表本来就是按 id 匹配，新槽位分配时已重置并写入 id）。
            // 阈值只作 sanity：超过 5000 说明这一拍数据不可信，**只作废这一拍的 dv**，
            // 不做记忆重置 —— 因为 5 秒间隔下英雄直线跑就有 2000~2500，2000 阈值会误伤正常奔跑。
            if (g_fog[sl].id != lid[i]) {
                g_fog[sl].id = lid[i];             // 补写，否则下一拍仍不等、每拍都重置
                g_fog[sl].n = 0;
                g_fog[sl].movedOnce = 0; g_fog[sl].stillCnt = 0; g_fog[sl].frz = 0;
                g_fog[sl].evzCnt = 0; g_fog[sl].evzMoved = 0;
                g_fog[sl].lastMv = 1;
                dv = -1.0f;
            } else if (dv > 5000.0f) {
                dv = -1.0f;                        // 只丢这一拍
            }
            g_fog[sl].p[0] = lp[i][0]; g_fog[sl].p[1] = lp[i][1]; g_fog[sl].p[2] = lp[i][2];
            g_fog[sl].n++;
            if (dv > 0.5f) { g_fog[sl].movedOnce = 1; g_fog[sl].stillCnt = 0; }
            else if (dv >= 0.0f) {
                if (!g_fog[sl].movedOnce) ninit++;
                else if (++g_fog[sl].stillCnt >= 2 && !g_fog[sl].frz) { g_fog[sl].frz = 1; fz++; }
            }
        }
        float dx = lp[i][0] - rx, dz = lp[i][2] - rz;
        float dc = sqrtf(dx * dx + dz * dz);
        if (!isMe && dc < dmin) dmin = dc;
        if (!isMe && dc > dmax) dmax = dc;
        if (g_myCamp != 0 && !isMe && !isAlly) enemies++;   // 本阵营未知时不数，避免把队友算成敌人
        int pv = (sl >= 0) ? g_fog[sl].lastMv : -1;   // v56：上一次采样的 mv
        {   // v54/v55：按 mv 分组统计位移；mv0 组再按「唯一单位」累计一次
            int g = lmv[i] ? 1 : 0;
            g1t[g]++;
            if (dv > 0.5f) g1m[g]++;
            // v55：判据收紧 —— 只有挂真实玩家 id 的单位，在「不可见(mv0)」时位移才算证据
            int isZombie = (lid[i] == 0);
            if (!isZombie && sl >= 0) {
                if (!g_fog[sl].evzCnt) { g_fog[sl].evzCnt = 1; evzTot++; }
                // v56：必须**连续两次**都不可见（pv==0 && mv==0）才算证据 ——
                // 否则「刚走出视野」那一次会拿可见期间的位移冒充，系统性假阳性。
                if (pv == 0 && lmv[i] == 0 && dv > 0.5f && lPid[i] > 0 && !g_fog[sl].evzMoved) {
                    g_fog[sl].evzMoved = 1;
                    evz++;
                }
            }
        }
        if (sl >= 0) g_fog[sl].lastMv = lmv[i];       // v56：写回，供下一拍判 pv
        if (i < 6)
            // v55：删掉 d（违反三角不等式，是噪声），只留原始世界坐标
            // v56：加 pv 自证（上一次的 mv），判据在日志里就能验，不用回来读代码
            CHECK("FOG %u pid%d pv%d T%d C%d mv%d lv%d cam%d dv %.1f @ %.0f,%.0f%s",
                  lid[i], lPid[i], pv, lT[i], lC[i], lmv[i], llv[i], lcam[i], dv,
                  lp[i][0], lp[i][2],
                  isGoneById(lid[i]) ? " gone" : (isAlly ? " ally" : ""));
        // ---- v40：只有「敌方主身」进桶；队友永远可见，进来就是假阳性
        if (isMe || isAlly || g_myCamp == 0) continue;
        if (isGoneById(lid[i])) continue;
        int bk = (dc < 2000.0f) ? 0 : (dc < 4000.0f) ? 1 : (dc < 6000.0f) ? 2 : 3;
        g_bktTot[bk]++;
        if (dv > 0.5f) { g_bktMov[bk]++; mov++; }
    }
    g_enemyN = (g_myCamp != 0) ? enemies : -1;

    CHECK("FOGV t %d/%d n %d inact %d enemy %d summon %d | mov %d still %d ninit %d", 
          g_fogRuns, FOG_RUNS, n, inact, enemies, summon, mov, fz, ninit);
    CHECK("FOGG mv1 %d/%d mv0 %d/%d | evz %d/%d | rng? %.0f..%.0f ref %d raw %d ok %d camp %d",
          g1m[1], g1t[1], g1m[0], g1t[0], evz, evzTot, dmin, dmax,
          refSrc, g_rawHostId, g_rawOk, g_myCamp);
    CHECK("BUCKET(cum) enemy 0-2k %d/%d | 2-4k %d/%d | 4-6k %d/%d | 6k+ %d/%d",
          g_bktMov[0], g_bktTot[0], g_bktMov[1], g_bktTot[1],
          g_bktMov[2], g_bktTot[2], g_bktMov[3], g_bktTot[3]);
    g_fogLastT = now;
}

// v35：灰虚线框（ImGui 没有原生虚线，按段画）
static void dashRect(ImDrawList *dl, ImVec2 a, ImVec2 b, ImU32 col) {
    const float seg = 6.0f;
    for (float x = a.x; x < b.x; x += seg * 2.0f) {
        float e = x + seg; if (e > b.x) e = b.x;
        dl->AddLine(ImVec2(x, a.y), ImVec2(e, a.y), col, 1.4f);
        dl->AddLine(ImVec2(x, b.y), ImVec2(e, b.y), col, 1.4f);
    }
    for (float y = a.y; y < b.y; y += seg * 2.0f) {
        float e = y + seg; if (e > b.y) e = b.y;
        dl->AddLine(ImVec2(a.x, y), ImVec2(a.x, e), col, 1.4f);
        dl->AddLine(ImVec2(b.x, y), ImVec2(b.x, e), col, 1.4f);
    }
}

// v34：调用 ActorManager 上的无参/单参 int 方法。ABI 与 get_pixelWidth 完全相同：
// 返回值在 w0，MethodInfo* 放在最后一个参数寄存器。
static int callInt0(void *self, const char *mname) {
    if (!self || !g_mgrClass || !I2.class_get_method_from_name) return -1;
    void *mi = I2.class_get_method_from_name(g_mgrClass, mname, 0);
    if (!mi) return -2;
    void *fn = *(void **)mi;
    if (!fn) return -3;
    return ((int (*)(void *, void *))fn)(self, mi);
}

static int callInt1(void *self, const char *mname, int a) {
    if (!self || !g_mgrClass || !I2.class_get_method_from_name) return -1;
    void *mi = I2.class_get_method_from_name(g_mgrClass, mname, 1);
    if (!mi) return -2;
    void *fn = *(void **)mi;
    if (!fn) return -3;
    return ((int (*)(void *, int, void *))fn)(self, a, mi);
}

// v34：拿 ActorManager 自己的计数去给 ActorType 定语义。
// hero==(T==X 的个数) 且唯一 → X 就是英雄，白名单自动生成，不用人肉对截图。
static void verifyIdentity(void) {
    if (!g_mgr || !g_lastEntries || g_lastCnt <= 0) return;
    // v59：数组从 16 扩到 32、扫描上限从 64 提到 160 ——
    // 实测 u=137 时英雄排在 64 之后，旧上限把 T0 整类漏掉，白名单因此自证失败。
    int tv[32] = {0}, tc[32] = {0}, n = 0;
    int lim = (g_lastCnt < 160) ? g_lastCnt : 160;
    for (int i = 0; i < lim; i++) {
        void *v = NULL, *k = NULL;
        if (!rd((char *)g_lastEntries + g_arrBase + (size_t)i * 24 + 16, &v, sizeof(v)) || !v) continue;
        if (rd(v, &k, sizeof(k)) && g_linkerClass && k != g_linkerClass) continue;
        int T = 0;
        readIdentity2(v, &T, NULL, NULL, NULL, NULL, NULL);
        int j = 0;
        for (; j < n; j++) if (tv[j] == T) { tc[j]++; break; }
        if (j == n && n < 32) { tv[n] = T; tc[n] = 1; n++; }
    }
    int total = callInt0(g_mgr, "GetActorTotalCount");
    int hero = callInt0(g_mgr, "GetHeroActorCount");
    int organ = callInt0(g_mgr, "GetOrganActorCount");
    int sold = callInt0(g_mgr, "GetSoldierActorCount");
    int dragon = callInt0(g_mgr, "GetDragonActorCount");
    int buff = callInt0(g_mgr, "GetBuffMonsterCount");
    int c1 = callInt1(g_mgr, "GetCampActorCount", 1);
    int c2 = callInt1(g_mgr, "GetCampActorCount", 2);
    CHECK("CNT total %d hero %d organ %d soldier %d dragon %d buff %d c1 %d c2 %d",
          total, hero, organ, sold, dragon, buff, c1, c2);
    if (n > 0) {
        static char th[200];
        int p = 0;
        th[0] = 0;
        for (int i = 0; i < n && p < 180; i++) {
            p += snprintf(th + p, sizeof(th) - p, "T%d=%d ", tv[i], tc[i]);
            if (i < 16) { g_thT[i] = tv[i]; g_thN[i] = tc[i]; }
        }
        g_thC = n;
        CHECK("TH %s| u %d", th, g_lastCnt);
    }
    // 唯一定位英雄类型
    if (g_heroType < 0) {
        // v47：先按「数量」自证 —— 5v5 里主身英雄恒为 10，单边 5。
        // 这一条不依赖任何 ActorManager 方法，比 GetHeroActorCount 稳。
        // v48：放宽 —— 元歌傀儡/盾山的盾也会算进英雄类型，计数可能是 11 而不是 10。
        // 取「最接近 10、且 ≥5、且唯一」的那一档。
        int bestT = -1, bestD = 99, bestCnt = 0, bestTie = 0;
        for (int i = 0; i < n; i++) {
            if (tc[i] < 5) continue;
            int d = (tc[i] > 10) ? (tc[i] - 10) : (10 - tc[i]);
            if (d < bestD) { bestD = d; bestT = tv[i]; bestCnt = tc[i]; bestTie = 0; }
            else if (d == bestD) bestTie = 1;
        }
        // v48：把第二名一起打出来，机器选错也能当场发现
        int sT = -1, sCnt = 0;
        for (int i = 0; i < n; i++) {
            if (tv[i] == bestT) continue;
            if (tc[i] > sCnt) { sCnt = tc[i]; sT = tv[i]; }
        }
        if (bestT >= 0 && bestD <= 2 && !bestTie) {
            g_heroType = bestT;
            CHECK("WHITELIST T=%d (cnt %d) 2nd: T%d (cnt %d)", bestT, bestCnt, sT, sCnt);
        } else if (hero > 0) {
            int hit = 0, cand = -1;
            for (int i = 0; i < n; i++) if (tc[i] == hero) { hit++; cand = tv[i]; }
            if (hit == 1) {
                g_heroType = cand;
                CHECK("WHITELIST T=%d (hero %d)", cand, hero);
            } else {
                CHECK("WHITELIST none (hit %d, hero %d) 1st T%d(%d) 2nd T%d(%d)",
                      hit, hero, bestT, bestCnt, sT, sCnt);
            }
        } else {
            CHECK("WHITELIST none 1st T%d (cnt %d) 2nd T%d (cnt %d) hero %d",
                  bestT, bestCnt, sT, sCnt, hero);
        }
    }
}

// v33：读一个单位的身份。结构体内联就直接算地址，是类就再解一次指针。
static int readIdentity2(void *obj, int *aType, int *aCamp, int *cfg, int *pid,
                          int *hostcfg, int *rawpid) {
    if (aType) *aType = 0;
    if (aCamp) *aCamp = 0;
    if (cfg) *cfg = 0;
    if (pid) *pid = 0;
    if (hostcfg) *hostcfg = 0;
    if (rawpid) *rawpid = 0;
    if (!obj || g_offTheMeta < 0) return 0;
    void *meta = (char *)obj + g_offTheMeta;
    if (!g_metaStruct) {                       // 引用：再解一次
        void *p = NULL;
        if (!rd(meta, &p, sizeof(p)) || !p) return 0;
        meta = p;
    }
    if (g_offAType >= 0 && aType) rd((char *)meta + g_offAType, aType, 4);
    if (g_offACamp >= 0 && aCamp) rd((char *)meta + g_offACamp, aCamp, 4);
    if (g_offCfgId >= 0 && cfg)   rd((char *)meta + g_offCfgId, cfg, 4);
    if (g_offPid   >= 0 && pid)   rd((char *)meta + g_offPid,   pid, 4);
    if (g_offHostCfg >= 0 && hostcfg) rd((char *)meta + g_offHostCfg, hostcfg, 4);
    if (g_offRawPid  >= 0 && rawpid)  rd((char *)meta + g_offRawPid,  rawpid, 4);
    return 1;
}

// 老调用点用这个薄的
static int readIdentity(void *obj, int *aType, int *aCamp, int *cfg, int *pid) {
    return readIdentity2(obj, aType, aCamp, cfg, pid, NULL, NULL);
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
        if (g_diagFail < 6) {
            g_diagFail++;
            CHECK("Dcnt fail dict %p off %d", dict, g_offCount);
            dumpWords("Ddict", dict, 10);      // v46：只在限流内转储，且每帧不再重复刷
        }
        return;
    }
    void *entries = NULL;
    if (!rd((char *)dict + g_offEntries, &entries, sizeof(entries)) || !entries) {
        if (g_diagFail < 6) {
            g_diagFail++;
            CHECK("Dent fail dict %p off %d -> %p", dict, g_offEntries, entries);
            dumpWords("Ddict", dict, 10);
        }
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
    g_lastDict = dict; g_lastEntries = entries; g_lastCnt = (cnt > 0) ? cnt : 0;   // v34：供自证用
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
    if (nowIn && g_pinN < 0) g_pinN = g_checkN;   // v46：把「类 dump + 绑定日志」固定住
    if (nowIn) bindExtraLazy();                   // v51：首次进对局才绑这 5 个字段
    if (edgeIn) {                                 // v48：每次进对局重置探针额度 ——
        g_verifyN = 0;                            // 载入界面那点零星 actor 会把 3 次额度吃光，
        g_pstRuns = 0;                            // 正式对局里就再也不打印 CNT/TH/PST 了
        g_pidRuns = 0;
        g_fogRuns = 0;
        g_diagFail = 0;
        for (int k = 0; k < 16; k++) { g_pst[k].id = 0; g_pst[k].n = 0; }
    }

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
    g_scrW = sw; g_scrH = sh;                      // v39：ref2 判屏幕中心要用
    g_frameStamp++;                                // v47
    if ((g_frameStamp & 127) == 0) {               // 每 ~128 帧清一次超过 900 帧没出现的条目
        for (int k = 0; k < 64; k++)
            if (g_gone[k].id != 0 && g_frameStamp - g_gone[k].lastF > 900) { g_gone[k].id = 0; g_gone[k].tGone = 0; }
    }
    g_seenN = 0;                                   // v35：本帧去重表清空
    g_frameDead = 0; g_frameAll = 0;
    if (cnt <= 0) {                                 // v35：换局/回大厅，清空生命周期记忆
        for (int k = 0; k < 64; k++) { g_gone[k].id = 0; g_gone[k].tGone = 0; }
        g_mirrorSafe = 0;
        for (int b = 0; b < 4; b++) { g_bktTot[b] = 0; g_bktMov[b] = 0; }   // v40：换局清空累计
        for (int k = 0; k < 64; k++) { g_tk[k].id = 0; g_tk[k].v[0] = g_tk[k].v[2] = 0; }   // v41：换局清轨迹
        for (int k = 0; k < 64; k++) { g_deadTbl[k].id = 0; g_deadTbl[k].t = 0; }             // v43：换局清死亡表
        for (int k = 0; k < 16; k++) { g_pst[k].id = 0; g_pst[k].n = 0; }                       // v45：换局清 PST 记忆
        g_myCamp = 0; g_enemyN = -1;
    }
    if (g_hideAll) {                               // v48：⊘ 只显示 HUD，不画任何框
        g_boxDrawn = 0;
        return;
    }
    // v63：每帧定位「自己」—— 距离显示要用
    g_selfOk = 0;
    {
        int hit = 0;
        if (g_rawOk && g_rawHostId > 0) {
            for (int i = 0; i < cnt && i < 160; i++) {
                void *o = NULL;
                if (!rd((char *)entries + g_arrBase + (size_t)i * 24 + 16, &o, sizeof(o)) || !o) continue;
                unsigned int oid = 0; rd((char *)o + 0x4AC, &oid, 4);
                if (oid != (unsigned int)g_rawHostId) continue;
                float pp[3] = {0, 0, 0};
                if (!rd((char *)o + 0x4C4, pp, sizeof(pp))) continue;
                if (pp[0] == 0.0f && pp[2] == 0.0f) continue;
                g_selfX = pp[0]; g_selfZ = pp[2]; g_selfOk = 1; hit = 1; break;
            }
        }
        if (!hit) {
            float lpx[1][3]; if (camRefPos(lpx, 1, &g_selfX, &g_selfZ)) g_selfOk = 1;
        }
    }
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

        // v33：身份（ActorType / ActorCamp / ConfigId / PlayerId）
        // v34：再带上 HostConfigId / RawPlayerId，一次把「英雄 ID 在哪个字段」定死
        int aT = 0, aC = 0, cfg = 0, pid = 0, hcfg = 0, rpid = 0;
        readIdentity2(obj, &aT, &aC, &cfg, &pid, &hcfg, &rpid);
        // v34：白名单一旦自证成功，就只画英雄；没自证出来时保持「全画」，不会白跑
        if (g_heroType >= 0 && aT != g_heroType) { continue; }

        // ---- v35 规则1：身份用 ObjID —— 同一帧同一个 ObjID 只画一次
        // （逻辑 actor 与 mesh actor 会各自进列表，不去重就会出现「框特别粗」）
        {
            int dup = 0;
            for (int k = 0; k < g_seenN; k++) if (g_seenId[k] == objId) { dup = 1; break; }
            if (dup) continue;
            if (g_seenN < 64) g_seenId[g_seenN++] = objId;
        }

        // ---- v35 规则2：活跃度只看 _meshVisible / _logicVisible
        int mesh = 1, logic = 1, inCam = 0, mirror = 0, host = 0, call = 0;
        unsigned char b = 0;
        if (g_offMeshVis  >= 0) { b = 0; rd((char *)obj + g_offMeshVis,  &b, 1); mesh  = b ? 1 : 0; }
        if (g_offLogicVis >= 0) { b = 0; rd((char *)obj + g_offLogicVis, &b, 1); logic = b ? 1 : 0; }
        if (g_offInCam    >= 0) { b = 0; rd((char *)obj + g_offInCam,    &b, 1); inCam = b ? 1 : 0; }
        if (g_offMirror   >= 0) { b = 0; rd((char *)obj + g_offMirror,   &b, 1); mirror = b ? 1 : 0; }
        if (g_offHostActor >= 0) { void *p = NULL; rd((char *)obj + g_offHostActor, &p, sizeof(p)); host = p ? 1 : 0; }
        if (g_offCallActor >= 0) { void *p = NULL; rd((char *)obj + g_offCallActor, &p, sizeof(p)); call = p ? 1 : 0; }

        // v45 修正：nowT 原来声明在下面那一段（v35 规则3），但死亡边沿逻辑在它之前就要用 →
        // CI 报 “use of undeclared identifier 'nowT'”。这里提到最前面，声明一次就够了。
        float nowT = (float)CACurrentMediaTime();

        // v36（对面改口，我认同）：分身/傀儡 **不清除**，改成细框 + 另一种颜色。
        // 元歌傀儡贴脸的时候，正是最需要看见的东西；过滤掉等于自断信息。
        // v42：死亡用 lastDeadKiller（!=0 = 已被击杀）为主判据；IsEmptyActor 作为池回收补充。
        // _meshVisible/_logicVisible 在死亡后可能仍是 1（有尸体/影子），不能单独当死亡判据。
        // v44：lastDeadKiller 可能「复活后不清零」（游戏留着做击杀回放）。
        // 所以不能用「非 0 = 死亡」这种电平判据，改成：
        //   边沿触发（0→非0 记死亡时刻）+ 活着证据（可见 或 位置动了）立即拉回
        //   + 判死 3 秒还没被拉回就强制解锁（兜底）。
        int isDead = 0;
        int dkNow = 0;
        if (g_offDeadKiller >= 0) {
            if (g_dkIsPtr == 1) {                  // 引用类型：按 8 字节读
                void *dk = NULL;
                rd((char *)obj + g_offDeadKiller, &dk, sizeof(dk));
                dkNow = dk ? 1 : 0;
            } else {                               // 值类型（-1 未知也按 4 字节读，最安全）
                int dv = 0;
                rd((char *)obj + g_offDeadKiller, &dv, sizeof(dv));
                dkNow = (dv != 0) ? 1 : 0;
            }
        }
        if (g_dkIsPtr < 0) {                      // v45：类型未知，打一次原始 8 字节便于回看
            static int s_dkRaw = 0;
            if (!s_dkRaw) {
                s_dkRaw = 1;
                unsigned long long raw = 0;
                rd((char *)obj + g_offDeadKiller, &raw, sizeof(raw));
                CHECK("DK raw %016llx", raw);
            }
        }
        int ti0 = -1;
        for (int k = 0; k < 64; k++) if (g_tk[k].id == objId && objId) { ti0 = k; break; }
        if (ti0 >= 0) {
            if (dkNow && !g_tk[ti0].dkPrev) { g_tk[ti0].dkPrev = 1; g_tk[ti0].tDead = nowT; }
            if (!dkNow) g_tk[ti0].dkPrev = 0;
            int aliveEv = (mesh || logic) ? 1 : 0;
            float adx = pos[0] - g_tk[ti0].p[0], adz = pos[2] - g_tk[ti0].p[2];
            if (fabsf(adx) > 5.0f || fabsf(adz) > 5.0f) aliveEv = 1;
            // v45：这里**不再**做时间兜底。死亡后复活要 20~40 秒，3 秒兜底只会在每一次正常死亡上误触发：
            // 灰虚线 1.5s 消失后又被翻成「失联」，以灰实框永久挂在死亡点。
            // 「字段复活不清零」那种情况，靠 aliveEv 就够（复活必然在泉水走动 → 位置差 >5 自动拉回）。
            isDead = (g_tk[ti0].dkPrev && !aliveEv) ? 1 : 0;
        }
        if (g_offEmptyActor >= 0) {
            unsigned char eb = 0; rd((char *)obj + g_offEmptyActor, &eb, 1);
            if (eb) isDead = 1;
        }
        // v43：安全网只统计「真死亡」。失联（双旗标=0）在视野外很常见，绝不能算进去，
        // 否则会误触「旗标不可信」而把失联/隐身状态整体关掉。
        g_frameAll++;
        if (isDead) g_frameDead++;
        // v42：分身样式只对「英雄类型」生效 —— 否则红 buff 这类被挂载对象也会套上特殊框
        int isSummon = ((mirror || host || call) && (g_heroType < 0 || aT == g_heroType)) ? 1 : 0;
        if (isSummon) g_mirrorSafe = 1;

        // ---- v35 规则3：死亡 / 失联 = 停滞 + 灰框 + 超时
        // （nowT 已在上面统一声明，这里不再重复声明 —— 重复会报 redeclaration）
        int gi = -1;
        for (int k = 0; k < 64; k++) if (g_gone[k].id == objId && g_gone[k].id != 0) { gi = k; break; }
        float goneAge = -1.0f;
        if (!g_flagTrust) { mesh = 1; logic = 1; }         // 旗标不可信 → 当作正常，绝不白屏
        if (mesh == 0 && logic == 0) {
            if (gi < 0 && g_offMeshVis >= 0) {              // 第一次看不到：记时刻
                for (int k = 0; k < 64; k++) if (g_gone[k].id == 0) {
                    g_gone[k].id = objId; g_gone[k].tGone = nowT;
                    gi = k; g_deadTotal++;                  // v47：只有真分配到槽位才计数
                    break;
                }
            }
            if (gi >= 0) g_gone[gi].lastF = g_frameStamp;
            if (gi >= 0) goneAge = nowT - g_gone[gi].tGone;
            // v36：撤回「超时丢弃」。视野外的敌人坐标可能是冻结的，丢掉就是主动放弃信息；
            // 只有 ObjID 从单位表里消失才真正不画（那种情况本来也进不来这个循环）。
            // 于是这里只记年龄，用于在框上标「最后已知 N 秒前」。
        } else if (gi >= 0) {
            g_gone[gi].id = 0; g_gone[gi].tGone = 0;        // 又看得见了：清记忆
        }
        if (!isDead) {                                      // v43：活着 → 清死亡计时，避免复活后再死时立刻超时
            for (int k = 0; k < 64; k++) if (g_deadTbl[k].id == objId) { g_deadTbl[k].id = 0; g_deadTbl[k].t = 0; }
        }

        if (g_unitDump < 6) {
            void *nm = NULL;
            rd((char *)obj + 0x4B0, &nm, sizeof(nm));
            char sbuf[24];
            readName(nm, sbuf, sizeof(sbuf));
            CHECK("U%d id %u T %d C %d cfg %d host %d pid %d raw %d | %s",
                  g_unitDump, objId, aT, aC, cfg, hcfg, pid, rpid, sbuf);
            g_unitDump++;
        }

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

        // ---- v41：轨迹与外推。视野外客户端拿不到新坐标（位置冻结），
        // 所以用「最后一次移动的速度」外推一个预测点，画成橙色虚线框 + 连线 + 年龄。
        float predX = 0, predY = 0, predAge = 0;
        int havePred = 0;
        {
            int ti = -1;
            for (int k = 0; k < 64; k++) if (g_tk[k].id == objId && objId != 0) { ti = k; break; }
            if (ti < 0) {
                for (int k = 0; k < 64; k++) if (g_tk[k].id == 0) {
                    ti = k; g_tk[k].id = objId;
                    g_tk[k].dkPrev = 0; g_tk[k].tDead = 0;      // v44
                    g_tk[k].v[0] = g_tk[k].v[1] = g_tk[k].v[2] = 0;
                    g_tk[k].p[0] = pos[0]; g_tk[k].p[1] = pos[1]; g_tk[k].p[2] = pos[2];
                    g_tk[k].tMove = nowT;
                    break;
                }
            }
            if (ti >= 0) {
                float ddx = pos[0] - g_tk[ti].p[0], ddz = pos[2] - g_tk[ti].p[2];
                float dd = sqrtf(ddx * ddx + ddz * ddz);
                if (dd > 3000.0f) {                       // 瞬移/重连/换视野：别外推
                    g_tk[ti].v[0] = 0; g_tk[ti].v[2] = 0;
                    g_tk[ti].tMove = nowT;
                } else if (dd > 0.3f) {
                    float dt = nowT - g_tk[ti].tMove; if (dt < 0.05f) dt = 0.05f;
                    float nvx = ddx / dt, nvz = ddz / dt;
                    float sp = sqrtf(nvx * nvx + nvz * nvz);
                    if (sp > 3000.0f) { nvx *= 3000.0f / sp; nvz *= 3000.0f / sp; }
                    g_tk[ti].v[0] = nvx; g_tk[ti].v[2] = nvz;
                    g_tk[ti].tMove = nowT;
                }
                g_tk[ti].p[0] = pos[0]; g_tk[ti].p[1] = pos[1]; g_tk[ti].p[2] = pos[2];
                predAge = nowT - g_tk[ti].tMove;
                float sp = sqrtf(g_tk[ti].v[0] * g_tk[ti].v[0] + g_tk[ti].v[2] * g_tk[ti].v[2]);
                // v48：三道 gate —— 速度要像人走出来的、预测位移有上限、阵营未知一律不画。
                // 之前只判 sp>20，晃动一点就出一条乱飞的线，而且队友也照画。
                if (g_myCamp != 0 && predAge > 0.8f && sp >= 20.0f && sp <= 1500.0f) {
                    float a = (predAge > 5.0f) ? 5.0f : predAge;
                    float pd = sp * a;
                    if (pd <= 3000.0f &&
                        projPred(g_tk[ti].p[0] + g_tk[ti].v[0] * a, g_tk[ti].p[1],
                                 g_tk[ti].p[2] + g_tk[ti].v[2] * a, sw, sh, &predX, &predY))
                        havePred = 1;
                }
            }
        }

        // 单位真实高度还没拿到（世界单位不是米），先用固定尺寸框 + 圆点 + ID
        float h  = 90.0f, wd = 45.0f;
        ImU32 col = (camp == 0) ? IM_COL32(90, 190, 255, 230)
                                : IM_COL32(255, 70, 70, 230);
        int deadStyle = 0;                                  // 0=正常 1=灰虚线淡出 2=隐身灰闪
        if (isDead) {
            // v43 态③：死亡 —— 灰虚线 + 十字，1.5 秒后不再画
            int di = -1;
            for (int k = 0; k < 64; k++) if (g_deadTbl[k].id == objId && objId) { di = k; break; }
            if (di < 0) {
                for (int k = 0; k < 64; k++) if (g_deadTbl[k].id == 0) { g_deadTbl[k].id = objId; g_deadTbl[k].t = nowT; di = k; break; }
            }
            float dAge = (di >= 0) ? (nowT - g_deadTbl[di].t) : 0.0f;
            if (dAge > 1.5f) continue;                 // 淡出结束：不再画
            int ai = (int)(210 * (1.0f - dAge / 1.5f));
            col = IM_COL32(190, 190, 190, ai < 40 ? 40 : ai);
            deadStyle = 2;
        } else if (!isDead && mesh == 0 && logic == 0) {
            // v48：这里只用「两个旗标都为 0」= 这一帧完全没被渲染（雾里/裁剪），作为**纯外观**提示；
            // 死亡判定只认 lastDeadKiller / IsEmptyActor，隐身判定已删除。
            // 用「位置停滞」代替会有副作用：塔、站着不动的英雄也会被判成失联，所以不用它。
            col = IM_COL32(175, 175, 175, 130);
            deadStyle = 1;
        }
        if (g_showBox) {
            if (deadStyle == 2) {
                // 死亡：虚线框 + 十字
                dashRect(dl, ImVec2(sx - wd * 0.5f, sy - h), ImVec2(sx + wd * 0.5f, sy), col);
                dl->AddLine(ImVec2(sx - 10, sy - h * 0.5f), ImVec2(sx + 10, sy - h * 0.5f), col, 1.4f);
                dl->AddLine(ImVec2(sx, sy - h * 0.5f - 10), ImVec2(sx, sy - h * 0.5f + 10), col, 1.4f);
            } else if (deadStyle == 1) {
                dl->AddRect(ImVec2(sx - wd * 0.5f, sy - h), ImVec2(sx + wd * 0.5f, sy), col, 0, 0, 1.2f);
            } else if (isSummon) {
                // 分身/傀儡：细框 + 紫青色，明显区别于真身
                dl->AddRect(ImVec2(sx - wd * 0.42f, sy - h * 0.9f),
                            ImVec2(sx + wd * 0.42f, sy), IM_COL32(200, 130, 255, 220), 0, 0, 1.0f);
            } else {
                dl->AddRect(ImVec2(sx - wd * 0.5f, sy - h),
                            ImVec2(sx + wd * 0.5f, sy), col, 0, 0, 1.6f);
            }
        }
        // v41：预测框 —— 橙色虚线 + 从最后已知位置的连线 + 年龄标签
        if (havePred) {
            dashRect(dl, ImVec2(predX - wd * 0.5f, predY - h), ImVec2(predX + wd * 0.5f, predY),
                     IM_COL32(255, 185, 60, 200));
            dl->AddLine(ImVec2(sx, sy), ImVec2(predX, predY), IM_COL32(255, 185, 60, 130), 1.2f);
            char pb[32];
            snprintf(pb, sizeof(pb), "~%.0fs", predAge);
            dl->AddText(ImVec2(predX + 6, predY - h - 12), IM_COL32(255, 185, 60, 230), pb);
        }
        dl->AddCircleFilled(ImVec2(sx, sy), 3.0f, col);
        char buf[96];
        const char *nm = nameOfUnit(obj, objId);
        float dist = 0.0f;
        if (g_selfOk) {
            float ddx = pos[0] - g_selfX, ddz = pos[2] - g_selfZ;
            dist = sqrtf(ddx * ddx + ddz * ddz);
        }
        if (deadStyle == 2) {
            snprintf(buf, sizeof(buf), "%s dead", (nm && nm[0]) ? nm : "?");
        } else if (nm && nm[0]) {
            if (g_selfOk) snprintf(buf, sizeof(buf), "%s %.0f", nm, dist);
            else          snprintf(buf, sizeof(buf), "%s", nm);
        } else if (deadStyle == 1 && goneAge >= 0.5f) {
            snprintf(buf, sizeof(buf), "%u ?%.0fs", objId, goneAge);
        } else {
            snprintf(buf, sizeof(buf), "%u T%d C%d", objId, aT, aC);
        }
        dl->AddText(ImVec2(sx + 6, sy - h - 12), col, buf);
        drawn++;
    }
    // v35 安全网：一帧里 >90% 的单位都被判成死亡/失联，只可能是旗标偏移不对，
    // 这时立刻停用旗标判定（回到 v34 行为），并留一行日志自证，避免整屏空框白跑一版。
    if (g_flagTrust && g_frameAll >= 4 && g_frameDead * 10 > g_frameAll * 9) {
        g_flagTrust = 0;
        CHECK("LFLAG distrust dead %d/%d", g_frameDead, g_frameAll);
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
static UIWindow      *g_btnWin       = nil;   // v52：按钮独立小窗口
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
            @"ESP v64  u%d r%d b%d p%d in%d d%d c%d  pg%d full%d fz%d pin%d btn%d\n3-finger UP = full hud",
            g_unitCount, g_cntRaw, g_arrBase, g_posOk, g_inMatch, g_boxDrawn, g_camCallState,
            g_hudPage % 100, g_hudForce, g_freeze, pinCount(), g_btnN];
        return;
    }
    NSMutableString *s = [NSMutableString stringWithCapacity:4096];
    [s appendString:@"ESP v64\n"];
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
        for (int i = 0; i < PIN_N; i++)
        if (g_pinBuf[i][0]) [s appendFormat:@"%s\n", g_pinBuf[i]];
    [s appendFormat:@"HERO T %d (u %d) gone %d summon %d fog %d/%d\n",
        g_heroType, g_unitCount, g_deadTotal, g_mirrorSafe, g_fogRuns, FOG_RUNS];
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
    // v34：进对局、读到单位之后，跑 3 次计数自证（计数会随兵线变化，多跑几次更稳）
    if (PROBES_DEFAULT && t % 90 == 0 && g_mgr && g_unitCount > 0 && g_verifyN < 3) { g_verifyN++; verifyIdentity(); }
    // v36：FOG 探针每 5 秒一次，最多 12 次（1 分钟），够看清机制就停，不刷页
    if (PROBES_DEFAULT && t % 150 == 0 && g_unitCount >= 40 && g_fogRuns < FOG_RUNS) { g_fogRuns++; fogProbe(); }
    // v42：PositionRecords / PlayerId 分组，各跑 3 次就够
    if (PROBES_DEFAULT && t % 150 == 0 && g_unitCount > 0 && (g_pstRuns < 3 || g_pidRuns < 3)) probeExtras();
    // v48：阵营容器 + 运动组件，各跑 2 次就够
    if (PROBES_DEFAULT && t % 150 == 30 && g_unitCount > 0 && g_campRuns < 1) { g_campRuns++; probeCamps(); }
    if (PROBES_DEFAULT && t % 150 == 60 && g_unitCount > 0 && g_mvRuns   < 1) { g_mvRuns++;   probeMove();  }
    if (PROBES_DEFAULT && t % 150 == 90 && g_unitCount >= 40 && g_deepRuns < 1) { g_deepRuns++; probeHeroDeep(); }
    if (PROBES_DEFAULT && t % 150 == 120 && g_unitCount >= 40 && g_campMemRuns < 1) { g_campMemRuns++; probeCampMem(); }
    // v64：L2 连续 8 拍（40 秒），L3a/L3b 各一次
    if (PROBES_DEFAULT && t % 150 == 30 && g_unitCount >= 40 && g_l2Runs < 8) { g_l2Runs++; probeL2();   }
    if (PROBES_DEFAULT && t % 150 == 70 && g_unitCount >= 40 && g_l3Runs < 1) { g_l3Runs++; probeL3scan(); }
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

// v52：按钮搬到**自己的小窗口**里。
// 之前的做法是 addSubview 到游戏 keyWindow —— 游戏重建视图层级时按钮被盖住/清掉，
// 而手势挂在 window 本身上不受影响，于是出现「手势能用、按钮不见了」。
// 这个窗口只有 52pt 宽，只吃右上角那一条的触摸。
static void createButtonWindow(void) {
    if (g_btnWin) return;
    CGRect sb = [UIScreen mainScreen].bounds;
    CGFloat W = MAX(sb.size.width, sb.size.height);
    CGFloat H = MIN(sb.size.width, sb.size.height);
    CGFloat bw = 44, gap = 8;
    CGFloat wx = W - bw - 8;
    CGFloat wy = 52;
    CGFloat wh = (bw + gap) * 4 + 4;

    UIWindow *bw2 = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if ([sc isKindOfClass:[UIWindowScene class]]) {
                bw2 = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)sc];
                break;
            }
        }
    }
    if (!bw2) bw2 = [[UIWindow alloc] initWithFrame:CGRectMake(wx, wy, bw, wh)];
    bw2.frame = CGRectMake(wx, wy, bw, wh);
    bw2.windowLevel = UIWindowLevelAlert + 200;      // 压在我们的 overlay 之上
    bw2.backgroundColor = [UIColor clearColor];
    bw2.userInteractionEnabled = YES;                // 只有这一小块收触摸
    bw2.hidden = NO;

    UIViewController *vc = [[UIViewController alloc] init];
    vc.view.frame = bw2.bounds;
    vc.view.backgroundColor = [UIColor clearColor];
    vc.view.userInteractionEnabled = YES;
    bw2.rootViewController = vc;
    [bw2 layoutIfNeeded];

    struct { const char *title; CGFloat size; int tag; } defs[4] = {
        { "≡", 22, 0 }, { "▤", 20, 1 }, { "⏸", 20, 2 }, { "⊘", 18, 3 }
    };
    for (int i = 0; i < 4; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(0, 2 + i * (bw + gap), bw, bw);
        b.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.45];
        b.layer.cornerRadius = 10;
        b.tag = defs[i].tag;
        b.titleLabel.font = [UIFont boldSystemFontOfSize:defs[i].size];
        [b setTitle:[NSString stringWithUTF8String:defs[i].title] forState:UIControlStateNormal];
        [b setTitleColor:[UIColor colorWithRed:0.6 green:1.0 blue:0.6 alpha:0.95]
                forState:UIControlStateNormal];
        int tag = defs[i].tag;
        [b addAction:[UIAction actionWithHandler:^(UIAction *a) {
            if (tag == 0) { g_hudPage++; }
            else if (tag == 1) { g_hudForce = g_hudForce ? 0 : 1; }
            else if (tag == 2) { g_freeze = g_freeze ? 0 : 1; g_pageFreeze = g_freeze; }
            else { g_hideAll = g_hideAll ? 0 : 1; }
            updateHud();
        }] forControlEvents:UIControlEventTouchUpInside];
        [vc.view addSubview:b];
        g_btnN++;
    }
    g_btnWin = bw2;
    LOG("button window created (%d buttons) at %.0f,%.0f", g_btnN, wx, wy);
}

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
    l.text = @"ESP v64 booting";
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
    createButtonWindow();   // v52：按钮用自己的窗口，不再挂到游戏窗口上
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
    ImGui::Text("build         : v64 esp (L2L3)");
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

    // v53：删掉 3 指下滑的 ImGui 菜单手势 —— overlay 不收触摸，那个窗口点不动，是死 UI。
    g_gestureOn = true;   // 仍然标记「手势已挂」，避免重复 attach

    // v13：4 指上滑 = 立刻重扫一遍（所有 image 全量扫）。
    // 菜单里的 re-selfcheck 按钮在真机上是摆设 —— overlay 的 window 不收触摸，
    // ImGui 的点按永远送不进来，所以补一个手势通道。
    UISwipeGestureRecognizer *g2 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            if (g_il2cppOk) { g_rescan = 0; selfCheck(); updateHud(); LOG("manual re-dump"); }
            else { bindAttempt(99); LOG("manual rebind"); }
        }]) action:@selector(main)];
    g2.numberOfTouchesRequired = 4;
    g2.direction = UISwipeGestureRecognizerDirectionUp;
    [win addGestureRecognizer:g2];
    LOG("4-finger swipe up = re-dump");

    // v22：overlay 的 window 是 userInteractionEnabled=NO（必须，否则吃触摸没法玩），
    // 所以 ImGui 里的复选框真机上一个都按不到。实战要用的开关只能走手势：
    //   3 指上滑 = 展开/收起完整 HUD（默认出框后自动收起）
    //   4 指下滑 = ESP 开/关
    UISwipeGestureRecognizer *g3 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            g_hudForce = g_hudForce ? 0 : 1;
            updateHud();
            LOG("hud force %d", g_hudForce);
        }]) action:@selector(main)];
    g3.numberOfTouchesRequired = 3;
    g3.direction = UISwipeGestureRecognizerDirectionUp;
    [win addGestureRecognizer:g3];

    UISwipeGestureRecognizer *g4 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            g_espOn = g_espOn ? false : true;
            updateHud();
            LOG("esp %d", g_espOn ? 1 : 0);
        }]) action:@selector(main)];
    g4.numberOfTouchesRequired = 4;
    g4.direction = UISwipeGestureRecognizerDirectionDown;
    [win addGestureRecognizer:g4];
    // v28：现场反馈「没法自主翻页」，而关键数字原来只出现在后面几页。
    // 现在首屏就有固定块；再加两个手势，想看哪页看哪页：
    //   2 指左滑 = 下一页，2 指右滑 = 上一页，2 指下滑 = 冻结/恢复自动翻页
    UISwipeGestureRecognizer *g5 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            g_hudPage++; updateHud(); LOG("page %d", g_hudPage);
        }]) action:@selector(main)];
    g5.numberOfTouchesRequired = 2;
    g5.direction = UISwipeGestureRecognizerDirectionLeft;
    [win addGestureRecognizer:g5];

    UISwipeGestureRecognizer *g6 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            if (g_hudPage > 0) g_hudPage--; updateHud(); LOG("page %d", g_hudPage);
        }]) action:@selector(main)];
    g6.numberOfTouchesRequired = 2;
    g6.direction = UISwipeGestureRecognizerDirectionRight;
    [win addGestureRecognizer:g6];

    UISwipeGestureRecognizer *g7 = [[UISwipeGestureRecognizer alloc]
        initWithTarget:keepAlive([NSBlockOperation blockOperationWithBlock:^{
            g_pageFreeze = g_pageFreeze ? 0 : 1; updateHud(); LOG("freeze %d", g_pageFreeze);
        }]) action:@selector(main)];
    g7.numberOfTouchesRequired = 2;
    g7.direction = UISwipeGestureRecognizerDirectionDown;
    [win addGestureRecognizer:g7];

    LOG("2-finger L/R = page, 2-finger down = freeze");

    createButtonWindow();   // v52：按钮走独立窗口（原来挂游戏窗口会被游戏视图盖掉）
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
