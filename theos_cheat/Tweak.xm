## 自查完了 —— **发现并修掉 4 个隐患**，其中 1 个是会崩的

我按归档里的"踩坑清单"逐条机检 + 人工复看，写了个 `audit104.py`：

### 修掉的 4 个问题

| # | 隐患 | 性质 | 修法 |
|---|---|---|---|
| **1** | `v104Dump` **直接对 `g_mgr` 调托管方法**，但换场景时 `g_mgr` 可能是**悬空指针** | **会崩**（和 v98 同级别） | 调用前先读 `*(void**)g_mgr` 比对 `g_mgrClass`，不符就 `V104 mgr stale … -> skip calls` 并返回 |
| **2** | `rfKlassIs()` 用 `*(void**)obj` 取 klass（只判了 `okptr`，没判是否可读） | 会崩（野指针） | 改成 `rd(obj,&k,8)` —— vm_read 失败就返回 0，不崩 |
| **3** | `rfContainerCount()` 同上 | 会崩 | 同上 |
| **4** | `get_ActorList` 返回值的 klass 用 `*(void**)list` 直接读（两处） | 会崩 | 改成 `rd`；并且**找不到 `_size` 时自动试 `size`**，同时打印 `cls=类名` |

### 另外两个"拿不到数据"的隐患也补了

| 隐患 | 修法 |
|---|---|
| `v104Init` 里 `findClsDeep` 是全类扫描，失败会**每 4 秒扫一次 6 万个类**（卡顿） | 加 5 秒节流 |
| `get_ActorList` 如果返回的不是 `List<T>`（比如直接是数组或别的容器），`_size` 找不到 → 什么都不打 | 打印 `cls=真实类名`，下一版照名字改读取方式 |

### 现在的检查结果

```
[1] meta 走缓冲                : OK        （全部 mb[1024]，无 &meta）
[2] 托管方法调用守卫           : 3/3 都有 param_count 校验 + mgr klass 守卫
[3] get_Instance 调用          : 0 处调用（仅剩 1 处 name 字符串探测，安全）
[5] 游戏指针直接解引用         : 仅剩 10 处，全部是 MethodInfo->methodPointer 与栈缓冲（安全）
[6] v98One klass 校验          : OK
[7] 批次 klass 校验            : OK
七道闸（check_tweak/syntax/v14/i2arity/link/pre/ident）: 全绿
audit104.py 结论               : PASS
```

---

## 交付（hash 已变，请用这份）

```
C:\Users\Administrator\Documents\deepseek-harness\default-workspace\ipa_work\theos_cheat\Tweak.xm
6592 行   sha256 D2BB3807BAA305D6D90697540A2841EDC5E99D20C0AECC65D8BC60DE3281A2FB

D:\dump\v104-Tweak.zip   100,780 字节
```

```powershell
cd C:\Users\Administrator\Documents\deepseek-harness\default-workspace
git add ipa_work/theos_cheat/Tweak.xm
git commit -m "v104: real ActorManager API + hardening (mgr guard, rd-based klass reads, list class print)"
git push
```

---

## 装上后仍然可能失败的三种情况（我提前给出兜底，不用再试错）

| 现象 | 原因 | 我的下一步 |
|---|---|---|
| `V104 mgr stale …` 一直出现 | 换场景后 `g_mgr` 没重建 | 改成"从静态字段重取 mgr"再调用 |
| `V104 m total=0x0 host=0x0 list=0x0` | `ActorManager` 不是这三个方法的实现类（可能在 `IActorManager` 接口或子类） | 我按接口类再取一次 |
| `V104 total=43 … cls=System.Collections.Generic.List\`1` 但 `n=-1` | 泛型实例的 `_size` 名字不同 | 我改用 `_items` 的 `max_length`（数组头 +0x18）算长度 |

**这三种情况每种都只需要一行日志就能判断，不需要再盲试。**
