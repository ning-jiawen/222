// Tweak.xm —— GATE v2（成品版：自校准 + 结果持久化 + 定时还原）
//
// 目标：找到「让敌方英雄无视迷雾显示出来」的那一个可见性字段。
//
// 与 v1（探针）的区别（四处，都是"成品化"必需）：
//   ① 结果持久化：Documents/gate_cfg.txt 里写 winner=N。下次启动直接锁定该档，不再轮换。
//   ② 标记方式：**按一下音量键** = 把「当前档」记为 winner 并立即写盘（不影响触摸）。
//                 也可以事后在 Filza 里手改 gate_cfg.txt 的 winner=N。
//   ③ 50 秒到期：有 winner → 锁定；没有 → restoreAll() 后**停止写入**（绝不裸停在 C5）。
//   ④ 写入原语改 volatile 存储（不走 memcpy，不会被优化掉）。
//
// 安全边界（硬约束）：
//   · 只写 m_Enabled / m_IsActive / m_ActiveSelf / layer / 逻辑可见字节
//   · 不写 .text、不改代码、不 hook、不 vm_protect、不加载 Substrate
//   · 每档切换前 restoreAll()，不污染下一档
//   · 同一对象同一字段 ≥200ms 才写一次
//   · 进程退出时 restoreAll()

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <AVFoundation/AVFoundation.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/vm_map.h>
#include <mach/vm_region.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdarg.h>
#include <stdbool.h>

// ============================================================================
// S0-1  日志 / 结果窗
// ============================================================================
static NSString        *g_logPath = nil;
static FILE            *g_logFp   = NULL;
static UIWindow        *g_uiWin   = nil;
static UITextView      *g_uiTV    = nil;
static NSMutableString *g_uiBuf   = nil;

static NSString *gateDocs(void) {
    NSArray *d = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return d.count ? d[0] : NSTemporaryDirectory();
}

static NSString *gateCfgPath(void) {
    return [gateDocs() stringByAppendingPathComponent:@"gate_cfg.txt"];
}

static void gateUIInit(void) {
    if (g_uiWin) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    w.userInteractionEnabled = NO;              // 绝不吞触摸
    UIViewController *vc = [[UIViewController alloc] init];
    w.rootViewController = vc;
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectInset(w.bounds, 6, 40)];
    tv.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    tv.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    tv.font = [UIFont monospacedSystemFontOfSize:9.0 weight:UIFontWeightRegular];
    tv.editable = NO;
    tv.userInteractionEnabled = NO;
    tv.text = @"GATE v2 booting...";
    [vc.view addSubview:tv];
    w.hidden = NO;
    g_uiTV = tv; g_uiWin = w; g_uiBuf = [NSMutableString string];
}

static void gateUI(const char *line) {
    if (!line) return;
    NSString *s = [NSString stringWithUTF8String:line];
    if (!s) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_uiWin) gateUIInit();
        if (!g_uiBuf) return;
        [g_uiBuf appendFormat:@"%@\n", s];
        NSArray *arr = [g_uiBuf componentsSeparatedByString:@"\n"];
        if (arr.count > 400) {
            NSArray *tail = [arr subarrayWithRange:NSMakeRange(arr.count - 400, 400)];
            g_uiBuf = [NSMutableString stringWithString:[tail componentsJoinedByString:@"\n"]];
        }
        g_uiTV.text = g_uiBuf;
        if (g_uiBuf.length) [g_uiTV scrollRangeToVisible:NSMakeRange(g_uiBuf.length - 1, 1)];
    });
}

static void GL(const char *fmt, ...) {
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    NSLog(@"[gate] %s", buf);
    if (g_logFp) { fputs(buf, g_logFp); fputc('\n', g_logFp); fflush(g_logFp); }
    gateUI(buf);
}

static void gateOpenLog(void) {
    if (g_logFp) return;
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyyMMdd-HHmmss";
    NSString *ts = [f stringFromDate:[NSDate date]];
    NSString *dir = gateDocs();
    g_logPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"gate_%@.log", ts]];
    g_logFp = fopen([g_logPath UTF8String], "a");
}

// ============================================================================
// S0-2  读写原语（读用 vm_read_overwrite，写用 volatile 存储）
// ============================================================================
static bool rd(void *addr, void *out, size_t n) {
    if (!addr || !out || n == 0) return false;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, n,
                                        (vm_address_t)out, &got);
    return (kr == KERN_SUCCESS && got == n);
}

// 探针式可读性检查：分块读到本地，任何一块失败即不可读
static bool inRW(uintptr_t p, size_t n) {
    if (p < 0x10000000ULL) return false;
    uint8_t tmp[16];
    size_t off = 0;
    while (off < n) {
        size_t len = n - off;
        if (len > sizeof(tmp)) len = sizeof(tmp);
        vm_size_t got = 0;
        if (vm_read_overwrite(mach_task_self(), (vm_address_t)(p + off), len,
                              (vm_address_t)tmp, &got) != KERN_SUCCESS) return false;
        if (got == 0) return false;
        off += got;
    }
    return true;
}

// 唯一写入原语：同进程堆对象，volatile 存储（保证不被优化、不走 libc）
static void wr8(uintptr_t a, uint8_t v)  { *(volatile uint8_t  *)a = v; __sync_synchronize(); }
static void wr32(uintptr_t a, int32_t v) { *(volatile int32_t  *)a = v; __sync_synchronize(); }

static void gateWriteRaw(uintptr_t addr, int is32, int32_t v32, uint8_t v8) {
    if (is32) wr32(addr, v32);
    else      wr8 (addr, v8);
}

// ============================================================================
// S1  il2cpp 绑定
// ============================================================================
typedef struct {
    void *h;
    void *(*domain_get)(void);
    void *(*domain_get_assemblies)(void *, size_t *);
    void *(*assembly_get_image)(void *);
    void *(*class_from_name)(void *, const char *, const char *);
    const char *(*class_get_name)(void *);
    void *(*class_get_parent)(void *);
    void *(*class_get_field_from_name)(void *, const char *);
    int   (*field_get_offset)(void *);
    const char *(*field_get_name)(void *);
} I2T;
static I2T I2;

#define I2SYM(field, name) do { *(void **)(&I2.field) = dlsym(I2.h, name); if (!I2.field) { GL("A1a dlsym miss %s", name); return false; } } while (0)

static bool bindIl2cpp(void) {
    if (I2.h) return true;
    I2.h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) I2.h = dlopen("UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) { GL("A1a dlopen UnityFramework fail"); return false; }

    I2SYM(domain_get,               "il2cpp_domain_get");
    I2SYM(domain_get_assemblies,    "il2cpp_domain_get_assemblies");
    I2SYM(assembly_get_image,       "il2cpp_assembly_get_image");
    I2SYM(class_from_name,          "il2cpp_class_from_name");
    I2SYM(class_get_name,           "il2cpp_class_get_name");
    I2SYM(class_get_parent,         "il2cpp_class_get_parent");
    I2SYM(class_get_field_from_name,"il2cpp_class_get_field_from_name");
    I2SYM(field_get_offset,         "il2cpp_field_get_offset");
    I2SYM(field_get_name,           "il2cpp_field_get_name");
    return true;
}

static const char *clsName(void *k) {
    if (!k || !I2.class_get_name) return "";
    const char *s = I2.class_get_name(k);
    return s ? s : "";
}

static void *findClass(const char *ns, const char *name) {
    if (!I2.domain_get || !name) return NULL;
    void *d = I2.domain_get();
    if (!d) return NULL;
    size_t n = 0;
    void **asmv = (void **)I2.domain_get_assemblies(d, &n);
    if (!asmv) return NULL;
    if (n > 4096) n = 4096;
    for (size_t i = 0; i < n; i++) {
        void *img = I2.assembly_get_image(asmv[i]);
        if (!img) continue;
        void *k = I2.class_from_name(img, ns, name);
        if (k) return k;
    }
    return NULL;
}

// 沿父类链找字段偏移；找不到返回 -1
static int findFieldOff(void *klass, const char *name) {
    if (!klass || !name || !I2.class_get_field_from_name) return -1;
    int depth = 0;
    for (void *k = klass; k && depth < 16; k = I2.class_get_parent(k), depth++) {
        void *f = I2.class_get_field_from_name(k, name);
        if (f) {
            int off = I2.field_get_offset(f);
            if (off > 0) return off;
        }
    }
    return -1;
}

// 打印某类的完整字段表（只在解析失败时用一次，帮助下一轮改名）
static void dumpFields(void *klass, const char *tag) {
    if (!klass) { GL("DUMP %s: null class", tag); return; }
    GL("DUMP %s class=%s", tag, clsName(klass));
    int depth = 0;
    for (void *k = klass; k && depth < 6; k = I2.class_get_parent(k), depth++) {
        GL("  -- %s", clsName(k));
        // il2cpp_class_get_fields 需要迭代器；这里用 field_from_name 无法枚举，
        // 故只列出我们关心的候选名是否命中
        static const char *probe[] = {
            "m_Enabled","enabled","m_IsActive","m_ActiveSelf","m_Active","activeSelf",
            "layer","m_Layer","_logicVisible","logicVisible","m_bLogicVisible",
            "m_bVisible","visible","_visible","bVisible","m_Visible",
            NULL
        };
        for (int i = 0; probe[i]; i++) {
            int off = findFieldOff(k, probe[i]);
            if (off > 0) GL("     %s @ 0x%X", probe[i], off);
        }
    }
}

// ============================================================================
// S2  actor 扫描（不依赖字典：直接找 klass == ActorLinker 的对象头）
// ============================================================================
#define GATE_MAXOBJ   24
#define GATE_SCAN_MB  1536

static void     *g_linkerClass = NULL;
static uintptr_t g_act[GATE_MAXOBJ];
static unsigned  g_actId[GATE_MAXOBJ];
static int       g_actN = 0;

static int scanActors(void) {
    g_actN = 0;
    if (!g_linkerClass) return 0;

    mach_vm_address_t addr = 0x10000000ULL;
    int found = 0;
    unsigned total = 0;
    double t0 = CFAbsoluteTimeGetCurrent();
    size_t chunk = 4u << 20;
    uint8_t *buf = (uint8_t *)malloc(chunk);
    if (!buf) return 0;

    mach_vm_address_t limit = 0x10000000ULL + (mach_vm_address_t)GATE_SCAN_MB * 1024ULL * 1024ULL;

    // 全区间扫描 + 轮转采样：不因为"前 N 个"就提前停（否则可能全是小兵/塔）
    while (addr < limit) {
        mach_vm_size_t sz = 0;
        // iOS SDK 没有 VM_REGION_SUBMAP_INFO_64，vm_region_basic_info_data_64_t 也没有
        // is_submap 成员（v147 踩过）。这里只用 basic-info，非 RW 区由 protection 过滤掉。
        vm_region_basic_info_data_64_t ri;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        if (vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&ri, &cnt, NULL) != KERN_SUCCESS) break;
        if (sz == 0) break;                       // 防死循环
        int rw = (ri.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE);
        if (!rw || sz < 4096) { addr += sz; continue; }

        for (mach_vm_size_t off = 0; off + 8 <= sz; off += chunk) {
            mach_vm_size_t len = sz - off;
            if (len > chunk) len = chunk;
            vm_size_t got = 0;
            if (vm_read_overwrite(mach_task_self(), addr + off, (vm_size_t)len,
                                  (vm_address_t)buf, &got) != KERN_SUCCESS) break;
            uintptr_t *sl = (uintptr_t *)buf;
            size_t n = (size_t)got / sizeof(uintptr_t);
            for (size_t i = 0; i < n; i++) {
                if (sl[i] != (uintptr_t)g_linkerClass) continue;
                uintptr_t o = addr + off + i * 8;          // klass 在 +0 ⇒ 这里就是对象基址
                if (!inRW(o, 0x500)) continue;
                unsigned aid = 0;
                if (!rd((void *)(o + 0x4AC), &aid, 4) || aid == 0 || aid > 0x0FFFFFFFu) continue;
                int dup = 0;
                for (int q = 0; q < found; q++) if (g_act[q] == o) { dup = 1; break; }
                if (dup) continue;
                if (found < GATE_MAXOBJ) {
                    g_act[found] = o; g_actId[found] = aid; found++;
                } else {
                    int slot = (int)(total % (unsigned)GATE_MAXOBJ);   // 轮转覆盖，样本分散
                    g_act[slot] = o; g_actId[slot] = aid;
                }
                total++;
            }
        }
        addr += sz;
    }
    free(buf);

    // 轮转覆盖可能留下重复，收尾去重
    int w = 0;
    for (int i = 0; i < found; i++) {
        int dup = 0;
        for (int j = 0; j < w; j++) if (g_act[j] == g_act[i]) { dup = 1; break; }
        if (!dup) { g_act[w] = g_act[i]; g_actId[w] = g_actId[i]; w++; }
    }
    g_actN = w;
    GL("scan: %u matches, kept %d, %.1fs", total, g_actN, CFAbsoluteTimeGetCurrent() - t0);
    return g_actN;
}

// ============================================================================
// S3  渲染对象解析（按类名，不猜偏移）
// ============================================================================
typedef struct {
    uintptr_t tr[4];  int ntr;   // Transform
    uintptr_t rv[8];  int nrv;   // *Renderer
    uintptr_t bh[4];  int nbh;   // *Behaviour
    uintptr_t go[4];  int ngo;   // GameObject
} GateObj;
static GateObj g_gate[GATE_MAXOBJ];

// what: 1=transform(收集) 2=renderer 3=behaviour 4=gameobject
static void scanWindow(uintptr_t base, size_t len, int what, GateObj *g) {
    for (size_t off = 0; off + 8 <= len; off += 8) {
        uintptr_t pv = 0;
        if (!rd((void *)(base + off), &pv, 8)) continue;
        if (pv < 0x10000000ULL) continue;
        void *k = NULL;
        if (!rd((void *)pv, &k, sizeof(k)) || !k) continue;
        const char *nm = clsName(k);
        if (!nm || !nm[0]) continue;

        if (what == 1) {
            if (strcmp(nm, "Transform") == 0 || strcmp(nm, "RectTransform") == 0) {
                if (g->ntr < 4) { g->tr[g->ntr++] = pv; }
                // 从 Transform 再扫一层，收集渲染相关对象
                if (g->nrv < 8 || g->nbh < 4 || g->ngo < 4)
                    scanWindow(pv, 0x200, 2, g);
            }
        } else if (what == 2) {
            if (strstr(nm, "Renderer") != NULL) { if (g->nrv < 8) g->rv[g->nrv++] = pv; continue; }
            if (strstr(nm, "Behaviour") != NULL) { if (g->nbh < 4) g->bh[g->nbh++] = pv; continue; }
            if (strcmp(nm, "GameObject") == 0)   { if (g->ngo < 4) g->go[g->ngo++] = pv; continue; }
        }
    }
}

static void resolveRender(void) {
    memset(g_gate, 0, sizeof(g_gate));
    for (int i = 0; i < g_actN; i++) {
        GateObj *g = &g_gate[i];
        scanWindow(g_act[i], 0x400, 1, g);
        for (int j = 0; j < g->ntr && (g->nrv < 8 || g->nbh < 4 || g->ngo < 4); j++)
            scanWindow(g->tr[j], 0x200, 2, g);
    }
}

// ============================================================================
// S4  候选表（每档带一组候选字段名，多别名提高一次命中率）
// ============================================================================
#define GATE_C5   5
#define GATE_THROTTLE_MS 200
#define GATE_SAVE_MAX    256

static const char *kC1[] = { "m_Enabled", "enabled", NULL };                       // Renderer
static const char *kC2[] = { "m_Enabled", "enabled", NULL };                       // Behaviour
static const char *kC3[] = { "m_IsActive", "m_ActiveSelf", "m_Active", "activeSelf", NULL }; // GameObject
static const char *kC4[] = { "layer", "m_Layer", NULL };                            // GameObject.layer
static const char *kC5[] = { "_logicVisible","logicVisible","m_bLogicVisible",
                             "m_bVisible","m_Visible","visible","_visible","bVisible", NULL };

static const char **candNames(int cand) {
    switch (cand) {
        case 1: return kC1;
        case 2: return kC2;
        case 3: return kC3;
        case 4: return kC4;
        case GATE_C5: return kC5;
        default: return NULL;
    }
}
static int candIs32(int cand)   { return cand == 4; }      // 只有 layer 是 int32
// 应用到哪一类对象：  0=actor 1=renderer 2=behaviour 3=gameobject
static int candKind(int cand) {
    if (cand == 1) return 1;      // Renderer.m_Enabled
    if (cand == 2) return 2;      // Behaviour.m_Enabled
    if (cand == GATE_C5) return 0; // 逻辑可见：写在 actor(ActorLinker) 自己身上
    return 3;                     // C3/C4：GameObject
}

// 每档 × 每类的已解析偏移（启动时算一次）
static int g_off[6][4];

typedef struct { uintptr_t addr; int is32; int32_t orig32; uint8_t orig8; int used; } GateSave;
static GateSave g_save[GATE_SAVE_MAX];
static int      g_saveN = 0;

typedef struct { uintptr_t addr; int cand; double last; } GateThr;
static GateThr  g_thr[GATE_SAVE_MAX];
static int      g_thrN = 0;

static int g_ok = 0, g_rv = 0, g_ne = 0, g_nf = 0, g_rb = 0;

static void rememberOrig(uintptr_t addr, int is32, int32_t v32, uint8_t v8) {
    for (int i = 0; i < g_saveN; i++) if (g_save[i].addr == addr) return;
    if (g_saveN >= GATE_SAVE_MAX) return;
    g_save[g_saveN].addr   = addr;
    g_save[g_saveN].is32   = is32;
    g_save[g_saveN].orig32 = v32;
    g_save[g_saveN].orig8  = v8;
    g_save[g_saveN].used   = 1;
    g_saveN++;
}

static void restoreAll(void) {
    int n = 0;
    for (int i = g_saveN - 1; i >= 0; i--) {
        if (!g_save[i].used) continue;
        if (!inRW(g_save[i].addr, 4)) continue;
        gateWriteRaw(g_save[i].addr, g_save[i].is32, g_save[i].orig32, g_save[i].orig8);
        n++;
    }
    if (n) GL("RESTORE %d fields", n);
    g_saveN = 0;
    memset(g_thr, 0, sizeof(g_thr));
    g_thrN = 0;
}

static bool throttled(uintptr_t addr, int cand) {
    double now = CFAbsoluteTimeGetCurrent() * 1000.0;
    for (int i = 0; i < g_thrN; i++) {
        if (g_thr[i].addr == addr && g_thr[i].cand == cand) {
            if (now - g_thr[i].last < (double)GATE_THROTTLE_MS) return true;
            g_thr[i].last = now;
            return false;
        }
    }
    if (g_thrN < GATE_SAVE_MAX) {
        g_thr[g_thrN].addr = addr;
        g_thr[g_thrN].cand = cand;
        g_thr[g_thrN].last = now;
        g_thrN++;
    }
    return false;
}

// 唯一写入点
static void gateApplyOne(uintptr_t obj, int cand, int32_t want) {
    int kind = candKind(cand);
    int off  = g_off[cand][kind];
    if (off <= 0) { g_rb++; return; }                     // ① 字段没解析出来
    uintptr_t addr = obj + (uintptr_t)off;
    if (!inRW(addr, 4)) { g_rb++; return; }               // ② 地址不可读
    if (throttled(addr, cand)) return;                    // ③ 节流

    if (candIs32(cand)) {
        int32_t cur = 0;
        if (!rd((void *)addr, &cur, 4)) { g_rb++; return; }
        if (cur == want) { g_ne++; return; }
        rememberOrig(addr, 1, cur, 0);
        gateWriteRaw(addr, 1, want, 0);
        int32_t back = 0;
        if (rd((void *)addr, &back, 4) && back == want) g_ok++; else g_rv++;
    } else {
        uint8_t cur = 0;
        if (!rd((void *)addr, &cur, 1)) { g_rb++; return; }
        if (cur == (uint8_t)want) { g_ne++; return; }
        rememberOrig(addr, 0, 0, cur);
        gateWriteRaw(addr, 0, 0, (uint8_t)want);
        uint8_t back = 0;
        if (rd((void *)addr, &back, 1) && back == (uint8_t)want) g_ok++; else g_rv++;
    }
}

static int g_curLayer = 0;

static int majorityLayer(void) {
    static int vals[8 * GATE_MAXOBJ];
    int n = 0, cap = (int)(sizeof(vals) / sizeof(vals[0]));
    for (int i = 0; i < g_actN; i++) {
        for (int j = 0; j < g_gate[i].ngo && n < cap; j++) {
            int off = g_off[4][3];
            if (off <= 0) break;
            int32_t v = 0;
            if (rd((void *)(g_gate[i].go[j] + (uintptr_t)off), &v, 4)) vals[n++] = v;
        }
    }
    if (!n) return 0;
    int best = vals[0], bestN = 0;
    for (int i = 0; i < n; i++) {
        int c = 0;
        for (int j = 0; j < n; j++) if (vals[j] == vals[i]) c++;
        if (c > bestN) { bestN = c; best = vals[i]; }
    }
    return best;
}

static void applyCand(int cand) {
    g_ok = 0; g_rv = 0; g_ne = 0; g_nf = 0; g_rb = 0;
    if (!candNames(cand)) return;
    int kind = candKind(cand);
    int32_t want = 1;
    if (cand == 4) want = (int32_t)g_curLayer;

    for (int i = 0; i < g_actN; i++) {
        GateObj *g = &g_gate[i];
        bool any = false;
        int n = 0;
        uintptr_t *arr = NULL;
        uintptr_t one[1];
        if (kind == 0)      { one[0] = g_act[i]; arr = one; n = 1; }   // C5：写在 actor 自己身上
        else if (kind == 1) { arr = g->rv; n = g->nrv; }
        else if (kind == 2) { arr = g->bh; n = g->nbh; }
        else                { arr = g->go; n = g->ngo; }
        for (int j = 0; j < n; j++) { gateApplyOne(arr[j], cand, want); any = true; }
        if (!any) g_nf++;
    }
}

// 启动时把 5 档 × 3 类的偏移各解析一次（用第一个可用对象当样本）
static void resolveOffsets(void) {
    memset(g_off, 0, sizeof(g_off));
    for (int cand = 1; cand <= 5; cand++) {
        const char **names = candNames(cand);
        if (!names) continue;
        int kind = candKind(cand);
        // 找到该类的一个样本对象
        void *sample = NULL;
        if (kind == 0) {
            sample = g_linkerClass;                       // C5：字段就在 actor 自己身上
        } else {
            for (int i = 0; i < g_actN && !sample; i++) {
                GateObj *g = &g_gate[i];
                uintptr_t *arr = (kind == 1) ? g->rv : (kind == 2) ? g->bh : g->go;
                int n = (kind == 1) ? g->nrv : (kind == 2) ? g->nbh : g->ngo;
                for (int j = 0; j < n; j++) {
                    void *k = NULL;
                    if (rd((void *)arr[j], &k, sizeof(k)) && k) { sample = k; break; }
                }
            }
        }
        if (!sample) { g_off[cand][kind] = -1; continue; }
        int off = -1;
        for (int i = 0; names[i]; i++) {
            int o = findFieldOff(sample, names[i]);
            if (o > 0) { off = o; GL("C%d field=%s off=0x%X", cand, names[i], o); break; }
        }
        g_off[cand][kind] = off;
        if (off <= 0) GL("C%d field NOT FOUND (tried %s..)", cand, names[0]);
    }
}

// ============================================================================
// S5  配置持久化 + 音量键标记
// ============================================================================
static volatile int g_markReq = 0;
static int g_winner = 0, g_locked = 0, g_done = 0;
static int g_cand = 1;

static int gateCfgRead(void) {
    NSString *s = [NSString stringWithContentsOfFile:gateCfgPath()
                                            encoding:NSUTF8StringEncoding error:NULL];
    if (!s) return 0;
    for (NSString *ln in [s componentsSeparatedByString:@"\n"]) {
        NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([t hasPrefix:@"winner="]) {
            int v = [[t substringFromIndex:7] intValue];
            return (v >= 1 && v <= 5) ? v : 0;
        }
    }
    return 0;
}

static void gateCfgWrite(int cand, const char *why) {
    NSDateFormatter *f = [[NSDateFormatter alloc] init];
    f.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *ts = [f stringFromDate:[NSDate date]];
    NSString *s = [NSString stringWithFormat:@"winner=%d\nts=%@\nwhy=%s\n", cand, ts, why ? why : "-"];
    [s writeToFile:gateCfgPath() atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    GL("CFG written -> %s (winner=%d)", [gateCfgPath() UTF8String], cand);
}

@interface GateVolWatcher : NSObject
@end
@implementation GateVolWatcher
- (void)observeValueForKeyPath:(NSString *)kp ofObject:(id)obj
                        change:(NSDictionary *)ch context:(void *)ctx {
    if ([kp isEqualToString:@"outputVolume"]) g_markReq = 1;
}
@end
static GateVolWatcher *g_volW = nil;

static void installMarkKey(void) {
    @try {
        AVAudioSession *s = [AVAudioSession sharedInstance];
        g_volW = [[GateVolWatcher alloc] init];
        [s addObserver:g_volW forKeyPath:@"outputVolume"
               options:NSKeyValueObservingOptionNew context:NULL];
        GL("mark key: volume +/- marks current candidate");
    } @catch (NSException *e) {
        GL("mark key unavailable (%s) — 手改 gate_cfg.txt 亦可", [[e reason] UTF8String]);
    }
}

static void gateLock(int cand) {
    if (cand < 1 || cand > 5) return;
    g_winner = cand; g_locked = 1; g_done = 0; g_cand = cand;
    gateCfgWrite(cand, "volume-key");
    GL("LOCK C%d", cand);
}

// ============================================================================
// 主循环
// ============================================================================
static double g_startTs = 0, g_lastLog = 0;
#define GATE_STEP_SEC 10.0
#define GATE_TOTAL_SEC 50.0

static void gateRun(void) {
    gateOpenLog();
    GL("=== GATE v2 start pid=%d ===", getpid());
    GL("cfg path: %s", [gateCfgPath() UTF8String]);

    if (!bindIl2cpp()) return;

    g_linkerClass = findClass("Assets.Scripts.GameLogic", "ActorLinker");
    if (!g_linkerClass) g_linkerClass = findClass("", "ActorLinker");
    if (!g_linkerClass) { GL("A1b ActorLinker not found"); return; }
    GL("linker=%p (%s)", g_linkerClass, clsName(g_linkerClass));

    if (scanActors() <= 0) { GL("A1c no actor"); return; }
    GL("actors=%d", g_actN);
    for (int i = 0; i < g_actN; i++) GL("  act[%d] id=%u", i, g_actId[i]);

    resolveRender();
    {
        int tr = 0, rv = 0, bh = 0, go = 0;
        for (int i = 0; i < g_actN; i++) {
            tr += g_gate[i].ntr; rv += g_gate[i].nrv;
            bh += g_gate[i].nbh; go += g_gate[i].ngo;
        }
        GL("render tr=%d rv=%d bh=%d go=%d", tr, rv, bh, go);
        if (rv + bh + go == 0) {
            GL("A2 no render object — 尝试 dump 一个 actor 的字段表供下一轮改名");
            dumpFields(g_linkerClass, "ActorLinker");
        }
    }

    resolveOffsets();
    g_curLayer = majorityLayer();
    GL("layer(majority)=%d", g_curLayer);

    // 是否已有配置
    g_winner = gateCfgRead();
    if (g_winner > 0) {
        g_locked = 1; g_cand = g_winner;
        GL("cfg: LOCKED C%d (from previous run)", g_winner);
    } else {
        GL("no cfg: calibration mode, %d s per candidate, press volume key to mark winner",
           (int)GATE_STEP_SEC);
    }

    installMarkKey();
    g_startTs = CFAbsoluteTimeGetCurrent();

    for (;;) {
        if (g_markReq) { g_markReq = 0; gateLock(g_cand); }

        double t = CFAbsoluteTimeGetCurrent() - g_startTs;

        if (!g_locked && !g_done) {
            int want = 1 + (int)(t / GATE_STEP_SEC);
            if (want > 5) {
                if (g_winner > 0) {
                    g_locked = 1; g_cand = g_winner; g_done = 0;
                    GL("LOCK(from mark) C%d", g_cand);
                } else {
                    restoreAll();
                    g_done = 1;
                    GL("NONE: 5 candidates done, no winner -> restored & STOP writing");
                    GL("=> 把 gate_cfg.txt 的 winner= 改成实际那一档，或下一轮重新校准");
                }
            } else if (want != g_cand) {
                GL("SWITCH C%d -> C%d", g_cand, want);
                restoreAll();                 // 换档先还原，避免污染
                g_cand = want;
            }
        }

        if (!g_done) applyCand(g_cand);

        if (t - g_lastLog >= 1.0) {
            g_lastLog = t;
            GL("GATE c=C%d t=%d lock=%d done=%d off=%d obj=%d ok=%d rv=%d ne=%d nf=%d rb=%d L=%d",
               g_cand, (int)t, g_locked, g_done, g_off[g_cand][candKind(g_cand)],
               g_actN, g_ok, g_rv, g_ne, g_nf, g_rb, g_curLayer);
        }
        usleep(200 * 1000);
    }
}

// ============================================================================
// 退出时还原
// ============================================================================
static void gateOnTerminate(void) {
    restoreAll();
    GL("terminate: restored");
}

__attribute__((constructor))
static void gateInit(void) {
    [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationWillTerminateNotification
                                                      object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { gateOnTerminate(); }];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sleep(12);
        dispatch_async(dispatch_get_main_queue(), ^{ gateUIInit(); });
        gateRun();
    });
}
