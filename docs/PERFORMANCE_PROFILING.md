# 性能排查方法论（macOS / SwiftUI）

> 核心原则：**卡顿先抓证据，不要猜代码。** 用 Instruments Time Profiler 拿到主线程真实热点，再针对性优化。

## 适用场景

- UI 滑动掉帧 / 卡顿
- 某操作明显发烫、转圈
- 怀疑主线程被阻塞

## 工具

- `xctrace`（随 Xcode 附带）：命令行驱动 Instruments，可附加到运行中的进程。
- Time Profiler 模板：按固定频率采样各线程调用栈，统计「时间花在哪个函数」。
  - 比 SwiftUI 模板更可靠：SwiftUI 模板在 `--attach` 模式下常常抓不到数据（`Trace file had no SwiftUI data`）。

## 步骤

### 1. 找到运行中的 app pid

```bash
pgrep -x AIUsage
```

### 2. 附加 Time Profiler 并复现卡顿

启动一个 ~50s 的抓取窗口，在窗口内**手动复现卡顿**（滑动目标页面来回几次）：

```bash
xctrace record --template "Time Profiler" --attach <pid> --time-limit 50s \
  --output /tmp/p.trace
```

### 3. 看 trace 里有哪些数据表

```bash
xctrace export --input /tmp/p.trace --toc 2>/dev/null | grep -E "<table"
```

关注三张表：

| schema | 用途 |
|--------|------|
| `time-profile` | 采样调用栈（主分析对象） |
| `potential-hangs` | >250ms 的硬卡顿事件（`hangs-threshold="250"`） |
| `hang-risks` | 运行时发出的卡顿风险告警 |

先看 `potential-hangs` / `hang-risks` 是否有行：有 → 有明确大卡顿；空 → 卡顿是亚 250ms 微卡或帧级抖动，继续看 `time-profile`。

### 4. 导出 time-profile

```bash
xctrace export --input /tmp/p.trace \
  --xpath '/trace-toc/run[@number="1"]/data/table[@schema="time-profile"]' \
  > /tmp/tp.xml
```

### 5. 按符号聚合主线程耗时

导出的 XML 里 **thread / frame / backtrace 都用 `id` 定义、`ref` 复用**，必须解 ref 才能正确聚合。用解析脚本统计：

- **按线程**的样本权重（确认主线程占比）
- **主线程叶子符号**的自耗时（self time）
- **主线程栈中出现**的符号总耗时（total time）
- 过滤出 app 自身符号（按视图名 / 类型名关键词），跳过 framework 噪声

参考解析思路（Python，`xml.etree`）：

```python
import xml.etree.ElementTree as ET
from collections import defaultdict
root = ET.parse("/tmp/tp.xml").getroot()
threads, frames, bts = {}, {}, {}
def thr(n):
    r=n.get('ref'); 
    if r: return threads.get(r,'?')
    threads[n.get('id')]=n.get('fmt','?'); return n.get('fmt','?')
def fr(f):
    r=f.get('ref')
    if r: return frames.get(r,'?')
    frames[f.get('id')]=f.get('name','?'); return f.get('name','?')
def names(bt):
    r=bt.get('ref')
    if r: return bts.get(r,[])
    ns=[fr(x) for x in bt.findall('frame')]; bts[bt.get('id')]=ns; return ns
total=defaultdict(int)
for row in root.iter('row'):
    t=row.find('thread'); fmt=thr(t) if t is not None else '?'
    if 'Main Thread' not in fmt: continue
    w_el=row.find('weight'); w=int(w_el.text) if (w_el is not None and w_el.get('ref') is None and w_el.text) else 1_000_000
    bt=row.find('tagged-backtrace/backtrace')
    if bt is None: bt=row.find('backtrace')
    for n in set(names(bt) if bt is not None else []):
        total[n]+=w
for s,w in sorted(total.items(), key=lambda x:-x[1])[:40]:
    print(f"{w/1e6:7.1f} ms  {s}")
```

### 6. 解读与修复

- 找主线程上**自身代码**（非 framework）的头号符号。
- 修复优先级：
  1. **高成本对象重复创建** → 静态常量 / `NSCache` 缓存（`NSRegularExpression`、大字典、`DateFormatter`）。
  2. **被多视图 body 反复读取的昂贵计算属性** → 失效式记忆化：缓存结果，输入源 `objectWillChange` 时置脏，读取命中缓存直接返回。
  3. **主线程文件系统调用**（`resolvingSymlinksInPath`/`fileExists`/`lstat`）→ 缓存或移出主线程。

### 7. 重抓对比

改完**重新跑一次同样的抓取 + 聚合**，确认目标符号确实跌出热点榜，而不是凭感觉。重启 app 前先确认 pid 变化（旧进程可能没被 `pkill` 杀掉而仍跑旧代码）。

## 案例：issue #28 「操作界面滑动卡顿」

**现象**：滑动仪表盘、代理页等都卡，换页照样卡。

**抓取**（50s 滑遍所有页面）：

- `potential-hangs` / `hang-risks` 为空 → 无 >250ms 硬卡顿。
- 主线程 CPU 不高，但其中 ~580ms 全在 SwiftUI 视图图更新，**触发源不是当前页面，而是常驻/定时刷新的仪表盘链路**。

**主线程头号热点（聚合后）**：

| 符号 | 耗时 |
|------|------|
| `AppState.providerAccountGroups.getter` | 116ms |
| `ProviderRefreshCoordinator.buildProviderEntries` | 90ms |
| `AccountStore.storedAccountMatchesLive` / `AccountIdentityPolicy.matchesLive` | 83ms |
| `AccountCredentialStore.normalizedAuthFilePath`（含 `lstat`） | 80ms |
| `localizedDynamicText` / `replacingRegex` | 50–57ms |

**根因**：

1. `providerAccountGroups` 是无缓存计算属性，每个观察 `AppState` 的视图 body 一读就全量重算 O(账号×live) 匹配。
2. 匹配里 `normalizedAuthFilePath` 每次 `resolvingSymlinksInPath()` 真碰文件系统（lstat），在嵌套循环里反复调。
3. `replacingRegex` 每次新编译 `NSRegularExpression`（违反规则#9）。

**修复**：

1. `normalizedAuthFilePath` 加 `NSCache` 静态缓存（路径稳定、同路径同结果）→ 消除 lstat。
2. `providerAccountGroups` 改失效式记忆化（输入源 `objectWillChange` / `selectedProviderIds.didSet` 置脏）→ 只在数据真变时算一次。
3. `localizedDynamicText` 的翻译字典改 `private static let`，`replacingRegex` 的正则用 `NSCache` 预编译缓存。

**重抓验证**：`providerAccountGroups`、`buildProviderEntries`、账号匹配链、`normalizedAuthFilePath` 全部跌出热点榜前 40。
