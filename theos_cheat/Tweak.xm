// Tweak.xm —— GATE：渲染可见性字段写入（C1..C5 单次装机轮换）
//
// 一句话：找到每个敌人的 Renderer / Behaviour / GameObject，按 10 秒一档轮换往
//         「可见性字段」写 1，写入前后四道校验 + 回读 + 200ms 节流，状态码上屏并落盘。
//         一次装机看模型在第几档出现。
//
// 与只读探针的区别（唯一）：本工程会写内存，且**写入面被严格限制**：
//   只写 m_Enabled / m_IsActive / m_ActiveSelf / layer（以及最后一档的逻辑可见字节）
//   不写 .text、不改代码、不 hook、不 vm_protect
//
// 关键修正（相对原始方案）：**每一档结束必须把写过的字段还原**。
//   否则 C1 写的 m_Enabled=1 会一直留着，后面几档全部被污染，实验作废。
//   所以每次写入前先存原值，换档时整体回滚。
//
// 状态码：ok=写入且回读一致 / rv=回读被冲回 / ne=本来就是目标值(未写) / nf=没找到对象 / rb=前置校验失败

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <dispatch/dispatch.h>
#include <mach/mach.h>
#include <mach/vm_region.h>
#include <dlfcn.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>
#include <math.h>
#include <stdarg.h>

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

static void gateUIInit(void) {
    if (g_uiWin) return;
    UIWindow *w = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    w.windowLevel = UIWindowLevelAlert + 1;
    UIViewController *vc = [[UIViewController alloc] init];
    w.rootViewController = vc;
    UITextView *tv = [[UITextView alloc] initWithFrame:CGRectInset(w.bounds, 6, 40)];
    tv.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    tv.textColor = [UIColor colorWithRed:0.45 green:1.0 blue:0.55 alpha:1.0];
    tv.font = [UIFont monospacedSystemFontOfSize:9.0 weight:UIFontWeightRegular];
    tv.editable = NO;
    tv.userInteractionEnabled = NO;
    tv.text = @"GATE booting...";
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
    if (![dir containsString:@"/Documents"]) {
        NSLog(@"[gate] WARN docs path unexpected: %s", [dir UTF8String]);
    }
    g_logPath = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"gate_%@.log", ts]];
    g_logFp = fopen([g_logPath UTF8String], "a");
}

// ============================================================================
// S0-2  读写原语
// ============================================================================
static bool rd(void *addr, void *out, size_t n) {
    if (!addr || !out || n == 0) return false;
    vm_size_t got = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)addr, n,
                                        (vm_address_t)out, &got);
    return (kr == KERN_SUCCESS && got == n);
}

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

// 同进程写入：目标就是本进程的堆对象，memcpy 与 vm_write 等价，
// 且不必依赖 mach_vm.h（iOS SDK 里那是 #error 桩，vm_write 不保证有声明）。
// 调用前 gateApplyOne 已用 inRW(addr,4) 确认可读；这里只碰 RW 堆对象。
static void wr8(uintptr_t a, uint8_t v) {
    memcpy((void *)a, &v, 1);
}

static void wr32(uintptr_t a, int32_t v) {
    memcpy((void *)a, &v, 4);
}

// 唯一真正落笔的函数：wr8 / wr32 只在这里被调用（写入点唯一，便于审计）
static void gateWriteRaw(uintptr_t addr, int is32, int32_t v32, uint8_t v8) {
    if (is32) wr32(addr, v32);
    else      wr8(addr, v8);
}

// ============================================================================
// S0-3  il2cpp 绑定
// ============================================================================
typedef void *(*t_domain_get)(void);
typedef void **(*t_domain_get_assemblies)(void *, size_t *);
typedef void *(*t_assembly_get_image)(void *);
typedef const char *(*t_image_get_name)(void *);
typedef void *(*t_class_from_name)(void *, const char *, const char *);
typedef const char *(*t_class_get_name)(void *);
typedef void *(*t_class_get_parent)(void *);
typedef void *(*t_class_get_field_from_name)(void *, const char *);
typedef size_t (*t_field_get_offset)(void *);

struct I2C {
    void *h;
    t_domain_get domain_get;
    t_domain_get_assemblies domain_get_assemblies;
    t_assembly_get_image assembly_get_image;
    t_image_get_name image_get_name;
    t_class_from_name class_from_name;
    t_class_get_name class_get_name;
    t_class_get_parent class_get_parent;
    t_class_get_field_from_name class_get_field_from_name;
    t_field_get_offset field_get_offset;
    void *domain;
    void *image;
} I2;

static bool bindIl2cpp(void) {
    I2.h = dlopen("@rpath/UnityFramework.framework/UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) I2.h = dlopen("UnityFramework", RTLD_NOW | RTLD_GLOBAL);
    if (!I2.h) return false;
#define BINDF(fn) I2.fn = (t_##fn)dlsym(I2.h, "il2cpp_" #fn)
    BINDF(domain_get);
    BINDF(domain_get_assemblies);
    BINDF(assembly_get_image);
    BINDF(image_get_name);
    BINDF(class_from_name);
    BINDF(class_get_name);
    BINDF(class_get_parent);
    BINDF(class_get_field_from_name);
    BINDF(field_get_offset);
#undef BINDF
    if (!I2.domain_get || !I2.class_from_name) return false;
    I2.domain = I2.domain_get();
    if (!I2.domain) return false;
    size_t n = 0;
    void **asmv = I2.domain_get_assemblies(I2.domain, &n);
    if (!asmv || !n) return false;
    for (size_t i = 0; i < n; i++) {
        void *img = I2.assembly_get_image(asmv[i]);
        if (!img) continue;
        const char *nm = I2.image_get_name ? I2.image_get_name(img) : NULL;
        if (nm && strcmp(nm, "Assembly-CSharp.dll") == 0) { I2.image = img; break; }
    }
    return I2.image != NULL;
}

static const char *clsName(void *k) {
    if (!k || !I2.class_get_name) return NULL;
    return I2.class_get_name(k);
}

static bool clsNameIs(void *obj, const char *want, bool contains) {
    if (!obj) return false;
    void *k = NULL;
    if (!rd(obj, &k, sizeof(k)) || !k) return false;
    const char *n = clsName(k);
    if (!n) return false;
    return contains ? (strstr(n, want) != NULL) : (strcmp(n, want) == 0);
}

static void *findClass(const char *ns, const char *name) {
    if (!I2.image || !I2.class_from_name) return NULL;
    return I2.class_from_name(I2.image, ns, name);
}

static int findFieldOff(void *klass, const char *name) {
    if (!klass || !I2.class_get_field_from_name || !I2.field_get_offset) return -1;
    void *k = klass;
    for (int d = 0; k && d < 8; d++) {
        void *f = I2.class_get_field_from_name(k, name);
        if (f) return (int)I2.field_get_offset(f);
        k = I2.class_get_parent ? I2.class_get_parent(k) : NULL;
    }
    return -1;
}

// ============================================================================
// S1  取 actor（有界堆扫，身份一律用对象指针）
// ============================================================================
#define GATE_MAXOBJ  16
#define SCAN_CAP_MB  512
#define SCAN_CHUNK   (4u << 20)

static void      *g_linkerClass = NULL;
static uintptr_t  g_act[GATE_MAXOBJ];
static unsigned   g_actId[GATE_MAXOBJ];
static int        g_actN = 0;

static int scanActors(void) {
    if (!g_linkerClass) return 0;
    uint8_t *buf = (uint8_t *)malloc(SCAN_CHUNK);
    if (!buf) return 0;
    uintptr_t kc = (uintptr_t)g_linkerClass;
    uint64_t budget = (uint64_t)SCAN_CAP_MB << 20;
    int found = 0;
    vm_address_t addr = 0;
    while (budget > 0) {
        vm_size_t sz = 0;
        vm_region_basic_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_BASIC_INFO_COUNT_64;
        mach_port_t obj = MACH_PORT_NULL;
        if (vm_region_64(mach_task_self(), &addr, &sz, VM_REGION_BASIC_INFO_64,
                         (vm_region_info_t)&info, &cnt, &obj) != KERN_SUCCESS) break;
        if (obj != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), obj);
        if (sz == 0) break;
        if ((info.protection & (VM_PROT_READ | VM_PROT_WRITE)) == (VM_PROT_READ | VM_PROT_WRITE)) {
            for (vm_address_t off = 0; off + 8 <= sz && budget > 0; off += SCAN_CHUNK) {
                size_t len = (size_t)(sz - off);
                if (len > SCAN_CHUNK) len = SCAN_CHUNK;
                vm_size_t got = 0;
                if (vm_read_overwrite(mach_task_self(), addr + off, len,
                                      (vm_address_t)buf, &got) != KERN_SUCCESS) continue;
                budget = (budget > got) ? (budget - got) : 0;
                size_t nq = (size_t)got / 8;
                const uintptr_t *sl = (const uintptr_t *)buf;
                for (size_t i = 0; i < nq && found < GATE_MAXOBJ; i++) {
                    if (sl[i] != kc) continue;
                    uintptr_t o = (uintptr_t)(addr + off + i * 8);
                    if (!inRW(o, 0x500)) continue;
                    unsigned aid = 0;
                    if (!rd((void *)(o + 0x4AC), &aid, 4) || !aid) continue;
                    int dup = 0;
                    for (int q = 0; q < found; q++) if (g_act[q] == o) { dup = 1; break; }
                    if (dup) continue;
                    g_act[found] = o; g_actId[found] = aid; found++;
                }
            }
        }
        addr += sz;
    }
    free(buf);
    g_actN = found;
    return found;
}

// ============================================================================
// S2  找渲染对象（只用类名判据，不猜偏移）
// ============================================================================
#define R_MAX 8

typedef struct {
    uintptr_t tr;   int ntr;
    uintptr_t rv[R_MAX]; int nrv;
    uintptr_t bh[R_MAX]; int nbh;
    uintptr_t go[R_MAX]; int ngo;
} GateObj;

static GateObj g_gate[GATE_MAXOBJ];

static void scanWindow(uintptr_t base, size_t len, int what, GateObj *g) {
    if (!inRW(base, len)) return;
    for (size_t off = 0; off + 8 <= len; off += 8) {
        uintptr_t p = 0;
        if (!rd((void *)(base + off), &p, sizeof(p)) || !p) continue;
        if (p < 0x10000000ULL) continue;
        if (!inRW(p, 0x20)) continue;
        if (what == 0) {
            if (g->ntr < 1 && clsNameIs((void *)p, "Transform", false)) { g->tr = p; g->ntr = 1; }
        } else if (what == 1) {
            if (g->nrv < R_MAX && clsNameIs((void *)p, "Renderer", true)) {
                int dup = 0;
                for (int i = 0; i < g->nrv; i++) if (g->rv[i] == p) { dup = 1; break; }
                if (!dup) g->rv[g->nrv++] = p;
            }
        } else if (what == 2) {
            if (g->nbh < R_MAX && clsNameIs((void *)p, "Behaviour", true)) {
                int dup = 0;
                for (int i = 0; i < g->nbh; i++) if (g->bh[i] == p) { dup = 1; break; }
                if (!dup) g->bh[g->nbh++] = p;
            }
        } else {
            if (g->ngo < R_MAX && clsNameIs((void *)p, "GameObject", false)) {
                int dup = 0;
                for (int i = 0; i < g->ngo; i++) if (g->go[i] == p) { dup = 1; break; }
                if (!dup) g->go[g->ngo++] = p;
            }
        }
    }
}

static void resolveRender(void) {
    memset(g_gate, 0, sizeof(g_gate));
    for (int i = 0; i < g_actN; i++) {
        GateObj *g = &g_gate[i];
        scanWindow(g_act[i], 0x400, 0, g);
        uintptr_t bases[2];
        bases[0] = g_act[i];
        bases[1] = g->tr;
        for (int b = 0; b < 2; b++) {
            if (!bases[b]) continue;
            scanWindow(bases[b], 0x200, 1, g);
            scanWindow(bases[b], 0x200, 2, g);
            scanWindow(bases[b], 0x200, 3, g);
        }
    }
}

// ============================================================================
// S3/S4  写入：四道校验 + 回读 + 原值备份 + 节流
// ============================================================================
#define GATE_C5           5          // 逻辑可见字节那一档，只此一处引用
#define GATE_THROTTLE_MS  200
#define GATE_SAVE_MAX     128

typedef struct { uintptr_t addr; int is32; int32_t orig32; uint8_t orig8; int used; } GateSave;
static GateSave g_save[GATE_SAVE_MAX];
static int      g_saveN = 0;

typedef struct { uintptr_t obj; int cand; double last; } GateThr;
static GateThr  g_thr[GATE_SAVE_MAX];
static int      g_thrN = 0;

static int g_ok = 0, g_rv = 0, g_ne = 0, g_nf = 0, g_rb = 0;

static bool candField(int cand, const char **outName, int *outIs32, int *outKind) {
    switch (cand) {
        case 1: *outName = "m_Enabled";      *outIs32 = 0; *outKind = 1; return true;
        case 2: *outName = "m_Enabled";      *outIs32 = 0; *outKind = 2; return true;
        case 3: *outName = "m_IsActive";     *outIs32 = 0; *outKind = 3; return true;
        case 4: *outName = "layer";          *outIs32 = 1; *outKind = 3; return true;
        case GATE_C5: *outName = "_logicVisible";  *outIs32 = 0; *outKind = 0; return true;   // C5：逻辑可见字节，最后一档
        default: return false;
    }
}

static void rememberOrig(uintptr_t addr, int is32, int32_t v32, uint8_t v8) {
    for (int i = 0; i < g_saveN; i++) if (g_save[i].addr == addr) return;
    if (g_saveN >= GATE_SAVE_MAX) return;
    g_save[g_saveN].addr = addr;
    g_save[g_saveN].is32 = is32;
    g_save[g_saveN].orig32 = v32;
    g_save[g_saveN].orig8 = v8;
    g_save[g_saveN].used = 1;
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

static bool throttled(uintptr_t obj, int cand) {
    double now = CFAbsoluteTimeGetCurrent() * 1000.0;
    for (int i = 0; i < g_thrN; i++) {
        if (g_thr[i].obj == obj && g_thr[i].cand == cand) {
            if (now - g_thr[i].last < (double)GATE_THROTTLE_MS) return true;
            g_thr[i].last = now;
            return false;
        }
    }
    if (g_thrN < GATE_SAVE_MAX) {
        g_thr[g_thrN].obj = obj;
        g_thr[g_thrN].cand = cand;
        g_thr[g_thrN].last = now;
        g_thrN++;
    }
    return false;
}

// 唯一写入点：wr8 / wr32 只在这里被调用
static void gateApplyOne(uintptr_t obj, void *klass, int cand, int32_t want) {
    const char *fname = NULL;
    int is32 = 0, kind = 0;
    if (!candField(cand, &fname, &is32, &kind)) { g_rb++; return; }

    if (!klass) { g_rb++; return; }                       // ① klass 非空
    int off = findFieldOff(klass, fname);
    if (off <= 0) { g_rb++; return; }                     // ② field 非空
    uintptr_t addr = obj + (uintptr_t)off;
    if (!inRW(addr, 4)) { g_rb++; return; }               // ③ offset 可用 + 可读
    if (throttled(obj, cand)) return;                     // ④ 节流

    if (is32) {
        int32_t cur = 0;
        if (!rd((void *)addr, &cur, 4)) { g_rb++; return; }
        if (cur == want) { g_ne++; return; }
        rememberOrig(addr, 1, cur, 0);
        gateWriteRaw(addr, 1, want, 0);
        int32_t back = 0;
        rd((void *)addr, &back, 4);
        if (back == want) g_ok++; else g_rv++;
    } else {
        uint8_t cur = 0;
        if (!rd((void *)addr, &cur, 1)) { g_rb++; return; }
        if (cur == (uint8_t)want) { g_ne++; return; }
        rememberOrig(addr, 0, 0, cur);
        gateWriteRaw(addr, 0, 0, (uint8_t)want);
        uint8_t back = 0;
        rd((void *)addr, &back, 1);
        if (back == (uint8_t)want) g_ok++; else g_rv++;
    }
}

// ============================================================================
// S5  候选调度器
// ============================================================================
static int    g_cand = 1;
static double g_startTs = 0;
static double g_lastLog = 0;
static int    g_curLayer = 0;

static int majorityLayer(void) {
    static int vals[R_MAX * GATE_MAXOBJ];
    int n = 0;
    int cap = (int)(sizeof(vals) / sizeof(vals[0]));
    for (int i = 0; i < g_actN; i++) {
        for (int j = 0; j < g_gate[i].ngo && n < cap; j++) {
            void *k = NULL;
            if (!rd((void *)g_gate[i].go[j], &k, sizeof(k)) || !k) continue;
            int off = findFieldOff(k, "layer");
            if (off <= 0) continue;
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
    const char *fname = NULL;
    int is32 = 0, kind = 0;
    if (!candField(cand, &fname, &is32, &kind)) return;

    int32_t want = 1;
    if (cand == 4) want = (int32_t)g_curLayer;

    for (int i = 0; i < g_actN; i++) {
        GateObj *g = &g_gate[i];
        bool any = false;
        if (kind == 0) {
            void *k = NULL;
            if (rd((void *)g_act[i], &k, sizeof(k)) && k) { gateApplyOne(g_act[i], k, cand, want); any = true; }
        } else if (kind == 1) {
            for (int j = 0; j < g->nrv; j++) {
                void *k = NULL;
                if (rd((void *)g->rv[j], &k, sizeof(k)) && k) { gateApplyOne(g->rv[j], k, cand, want); any = true; }
            }
        } else if (kind == 2) {
            for (int j = 0; j < g->nbh; j++) {
                void *k = NULL;
                if (rd((void *)g->bh[j], &k, sizeof(k)) && k) { gateApplyOne(g->bh[j], k, cand, want); any = true; }
            }
        } else {
            for (int j = 0; j < g->ngo; j++) {
                void *k = NULL;
                if (rd((void *)g->go[j], &k, sizeof(k)) && k) { gateApplyOne(g->go[j], k, cand, want); any = true; }
            }
        }
        if (!any) g_nf++;
    }
}

// ============================================================================
// 主循环
// ============================================================================
static void gateRun(void) {
    gateOpenLog();
    GL("=== GATE start pid=%d ===", getpid());

    if (!bindIl2cpp()) { GL("A1a il2cpp bind fail"); return; }
    g_linkerClass = findClass("Assets.Scripts.GameLogic", "ActorLinker");
    if (!g_linkerClass) g_linkerClass = findClass("", "Assets.Scripts.GameLogic.ActorLinker");
    if (!g_linkerClass) { GL("A1b ActorLinker not found"); return; }
    GL("linker=%p", g_linkerClass);

    if (scanActors() <= 0) { GL("A1c no actor"); return; }
    GL("actors=%d", g_actN);

    resolveRender();
    {
        int ntr = 0, nrv = 0, nbh = 0, ngo = 0;
        for (int i = 0; i < g_actN; i++) {
            ntr += g_gate[i].ntr; nrv += g_gate[i].nrv;
            nbh += g_gate[i].nbh; ngo += g_gate[i].ngo;
        }
        GL("render tr=%d rv=%d bh=%d go=%d", ntr, nrv, nbh, ngo);
    }
    g_curLayer = majorityLayer();
    GL("layer(majority)=%d", g_curLayer);

    g_startTs = CFAbsoluteTimeGetCurrent();
    for (;;) {
        double t = CFAbsoluteTimeGetCurrent() - g_startTs;
        int want = 1 + (int)(t / 10.0);
        if (want > 5) want = 5;
        if (want != g_cand) {
            GL("SWITCH C%d -> C%d", g_cand, want);
            restoreAll();                 // 换档先还原，避免上一档的写入污染下一档
            g_cand = want;
        }
        applyCand(g_cand);

        if (t - g_lastLog >= 1.0) {
            g_lastLog = t;
            GL("GATE c=C%d t=%d/50 obj=%d ok=%d rv=%d ne=%d nf=%d rb=%d L=%d",
               g_cand, (int)t, g_actN, g_ok, g_rv, g_ne, g_nf, g_rb, g_curLayer);
        }
        usleep(200 * 1000);
    }
}

__attribute__((constructor))
static void gateInit(void) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        sleep(12);
        dispatch_async(dispatch_get_main_queue(), ^{ gateUIInit(); });
        gateRun();
    });
}
