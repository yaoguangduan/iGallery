# iGallery — Agent 工作手册

局域网相册（Rust 服务端 + Flutter 四端客户端）。
本文件是所有改动的强制规范，写代码前通读，违反即返工。

---

## 0. 设计哲学（大巧不工）

以最终效果为唯一基准。参照 YouTube 级的扁平、克制、信息密度。

- **不临时折中**：每一行代码都是最终方案，不写"先这样后面再改"。
- **不过度设计**：不做花里胡哨的抽象，不超前设计。三行重复好过一个不成熟的抽象。
- **一致**：同一件事只有一种做法。新写法替旧写法时全量替换，不留两套并存。
- **四端统一**：Android / iOS / macOS / Windows 行为和视觉完全一致，不做平台特例。
- **易于理解**：命名即文档，结构即意图。陌生人读一遍就能改。
- **代码不杂不乱**：每个文件职责单一，依赖方向单向。改一个需求只动一个地方。

---

## 1. 架构分层

```
client/lib/
├── core/              ← 平台无关，全端共享
│   ├── api.dart              统一 HTTP 层：ApiException、超时、竞态防护
│   ├── auth_store.dart       token 按 host:port 存 KvStore
│   ├── disk_cache.dart       缩略图/小视频磁盘缓存 (LRU + TTL)
│   ├── discovery_service.dart mDNS + 生命周期 + 网络切换重启
│   ├── display_prefs.dart    显示偏好 (ChangeNotifier)
│   ├── log_service.dart      客户端错误日志持久化 + 后台上传服务端
│   ├── kv_store.dart         SQLite KV + 上传历史表
│   ├── media_service.dart    服务端 API 封装
│   ├── mime.dart             mime 猜测 (双端一致)
│   ├── platform.dart         isDesktop / isMobile 单点定义
│   ├── server_state.dart     连接状态 + 多服务器 + 鉴权状态机
│   ├── time_fmt.dart         北京时间统一格式化
│   └── upload_history.dart   上传历史数据层
├── theme/
│   └── app_theme.dart        设计 token（唯一真相源）
└── ui/
    ├── shared/       两端复用
    │   ├── app_kit.dart        基础 primitives
    │   ├── app_toast.dart      顶部 toast (info/success/error)
    │   ├── cached_thumb.dart   走磁盘缓存的缩略图
    │   ├── common.dart         设置行 / 分组
    │   ├── gallery_view.dart   相册主 State
    │   ├── gallery_groups.dart 分组算法 (纯函数)
    │   ├── drag_select.dart    按住拖动连续多选 (相册网格 + 选择器共用)
    │   ├── gallery_widgets.dart MediaThumb / FolderThumb / FolderPickerDialog
    │   ├── media_picker.dart   微信风格图片选择器 (photo_manager)
    │   ├── media_viewer.dart   全屏查看器
    │   └── settings_sheet.dart 设置面板
    ├── mobile/       移动壳（仅布局包装）
    └── desktop/      桌面壳（仅布局包装）

server/src/
├── main.rs           启动 HTTP + mDNS + 加载 token
├── auth.rs           Bearer 中间件 + /v1/auth 探测
├── db.rs             SQLite + FromRow + UpdateFields + cursor 分页
├── media.rs          所有 API handlers
├── folder.rs         文件夹 CRUD
├── thumb.rs          缩略图 / 视频探测 (image + ffmpeg + mp4parse)
├── exif_util.rs      EXIF 元数据提取
├── archive.rs        async_zip 真流式打包
├── mdns.rs           mDNS 注册 (daemon 存 AppState)
├── sanitize.rs       文件名/ext/Content-Disposition
└── time.rs           北京时间统一入口 (UTC+8)
```

**铁律：**
- 业务逻辑只写一遍，全放 `core/`。UI 层禁止写网络请求、数据处理。
- 功能组件全做 `ui/shared/`，移动端和桌面端只做壳 + 布局包装。
- **新增或修复任何功能，必须同时覆盖移动端和桌面端**，禁止只做一端。
- 平台判断只用 `core/platform.dart`，不在 UI 里写 `Platform.isMacOS || ...`。
- HTTP 一律走 `core/api.dart::Api`，禁止裸 `http.get/post`。异常统一走 `showToast(kind: error)`。
- 时间统一走 `core/time_fmt.dart`（北京时间 UTC+8）。

---

## 2. 视觉设计规范（扁平 · 少色 · YouTube 级克制）

**核心原则：一张色板、一套字阶、四种形状、一套间距、零阴影。**

所有视觉 token 只在 `theme/app_theme.dart` 定义。UI 层禁止裸 `Color(0x...)`、裸字号、裸圆角、裸 padding 数字。可复用形态一律用 `app_kit.dart` 的 primitives，不各页面手搓容器。

### 2.1 配色（亮色 only · YouTube 对齐 · 单品牌 · 中性三层 · 语义）

**只有亮色主题，不做暗色，不做切换。**

- **品牌色 `brand`**（`#065FD4` YouTube 蓝）。只用于 5 处：主 CTA、链接、激活态、上传按钮、状态指示。禁止大面积 brand 填充。
- `brandSoft`：8% alpha，仅激活背景。
- **三层表面**：`bg`(`#FFFFFF` 纯白画布) → `surface`(`#FFFFFF` 卡片/浮层) → `surface2`(`#F2F2F2` 输入框/chip)。深度只靠 0.5px hairline，零阴影。
- **三级文本**：`onSurface`(`#0F0F0F` 正文 20.1:1) → `onSurfaceVariant`(`#606060` 次级 6.4:1) → `onMuted`(`#909090` 占位 3.1:1)。**对比度是量过的，不凭感觉调。**
- `outline`：`#E5E5E5` hairline。
- 语义色 `error`(`#CC0000`) / `warn`(`#B86E00`) / `ok`(`#0F7B3D`)，只用于删除/警告/连接状态。禁止装饰用。
- 除 brand + 三语义色外，不出现其它色相。

**遮罩层（图片上层专用，与主题无关）**：图片底色不可控，一律半透明黑 + 白字：
`scrimStrong`(85%) / `scrimMedium`(54%) / `scrimSoft`(38%) / `onScrim`(白)。

**MediaViewer 是永远深色的独立空间**（YouTube 播放器同理）。它内部的 `Colors.white70` 等是语义正确的，不走主题 token。深色底上的高亮色用文件内的 `_kViewerAccent`(`#5B9DFF`) / `_kViewerDanger`(`#FF6B6B`)，不用 `c.brand`（亮色品牌蓝在黑底上对比度不足）。

### 2.2 形状（只有 5 种圆角）
| Token | 值 | 用途 |
|---|---|---|
| `chip` | 8 | 标签、徽章 |
| `card` | 12 | 所有内容块——卡片、缩略图、输入框、按钮 |
| `dialog` | 12 | 居中对话框 |
| `sheet` | 16 | 底部 sheet |
| `pill` | 999 | 搜索框、圆形按钮 |

禁止出现其它圆角值。**所有缩略图（媒体/文件夹）都是 `card`(12) 圆角**。

### 2.3 间距（8 基数）
- `xs(4) / sm(8) / md(12) / lg(16) / xl(24) / xxl(32)`。
- 卡片内边距统一 `AppSpace.card`(全 16)。
- 禁止随手写 `EdgeInsets.fromLTRB(18,16,...)`。1-3px 光学微调允许，其余就近归档。

### 2.4 字号与字重
- 走 `AppType.*`。核心档：`xl`(24 页标题) / `mdPlus`(19 标题) / `base`(16 正文) / `sm`(15 次级) / `xs`(13 标签) / `xxs`(11.5 徽章)。
  这一档整体偏大是**故意的**（对齐 YouTube 移动端），调小会立刻回到"扁平紧凑"的观感。
- 不内嵌字体。中文走 `familyFallback`：PingFang SC → MiSans → HarmonyOS Sans SC → Source Han Sans SC → Noto Sans SC → Microsoft YaHei。
- **字重三档**：`w700` 页标题 / `w600` 按钮+激活态 / `w500` 正文。禁止 w400。

### 2.5 扁平（零阴影）
- 全 flat，不用任何 `boxShadow`。深度只靠表面色阶 + hairline。
- 分割线只用 `AppDivider`（0.5px `outline`）。
- 图标尺寸只用 `AppIconSize`：`sm(16)` / `md(18)` / `lg(20)` / `xl(22)` / `hero(32)`。
- 移动端可点击目标 ≥ 40×40。
- 顶栏 58px + 底部 0.5px hairline。

### 2.6 网格（YouTube 卡片式）

YouTube 的"简约但大气"来自**留白和字号**，不是把东西塞紧。
下面这组数比 Material 默认偏大，**不要为了一屏多塞一行往回调**。

- 缩略图圆角 `card`(12)，**留白优先于密度**。
- **缩略图区恒为正方形**（`AspectRatio(1)`，服务端 `resize_to_fill` 出的就是
  300×300）。不要用 `Expanded` —— 那样图片高度 = 格子高度减标签占用，
  开了标签就变竖长方形，横图被裁成中间一条，和手机图库不一样。
  格子的 `childAspectRatio` 要留出标签行：有标签 0.78，无标签 1.0。
- 网格 padding 水平 16，间距 `mainAxisSpacing: 16` / `crossAxisSpacing: 14`。
- 文件夹网格 `maxCrossAxisExtent: 150`，`childAspectRatio: 0.84`。
- 分组标题：`mdPlus`(19) + `w700` + `letterSpacing: -0.3` + `onSurface`
  （不是灰色小字），上下留白 28/12。
- 缩略图下方 label：文件名 `xs` + `w500`，其余 `xxs` + `onSurfaceVariant`。
- **格子窄于 96px 就不画 label**（`MediaThumb._labelMinTileWidth`）：
  字号调大后 3~5 行元信息会把密集网格里的 `Expanded` 挤成 0 高，缩略图直接消失。
  同时视频播放圆圈和角标缩一档、时长徽章隐藏。YouTube 密集布局下也是只留图。

### 2.7 通知
- 统一用 `showToast(context, msg, kind: ToastKind.xxx)`，显示在屏幕顶部。
- `ToastKind`：`info`（灰点）· `success`（绿点）· `error`（红点，延时更长）。
- 禁止 `SnackBar` / `ScaffoldMessenger`。
- **零装饰**：只有左侧 6px 圆点 + 文字，不加下划线/图标/边框强调。

---

## 3. 交互规范

### 3.1 导航结构
- 无底部导航、无侧边栏。单页全屏相册，顶部工具栏。
- **顶栏只放操作，不放目录信息**。顶栏宽度有限，深目录的面包屑放那儿
  必然被截断看不全。目录信息一律走内容区（见 §3.1.2）。
- **顶栏左槽是固定位**：非多选放设置(menu)，多选放退出(X)。
  两者必须占同一个位置 —— 让退出键跑到最右侧会导致进出多选时 icon 满屏换位，
  是实打实的心智负担。同理"全选"也是图标而不是文字按钮，宽度不跳。
- 右上：功能按钮 **全部平铺，不收进三点菜单**（多选/新建文件夹/上传/显示设置）。
  收纳过的版本被否决 —— 常用操作藏两层不方便。
- **桌面端右键菜单**：网格空白处 → 新建文件夹/刷新/上传；
  缩略图上 → 打开/收藏/移动/删除。移动端不做右键。
- 显示设置：桌面右侧 Drawer / 手机底部 Sheet。

### 3.1.2 内容区自上而下的顺序

```
顶栏           只有 menu/X + 操作按钮，无目录信息
─────────────  ↑ 固定
筛选 chips      全部 / 图片 / 视频 / 收藏
─────────────  ↓ 跟着滚
面包屑          仅在目录里时出现，每层可点，横向可滚
搜索框          默认藏在视野上方
文件夹网格
媒体分组网格
```

**筛选 chips** 单选，联动 `mediaFilter`，是媒体类型筛选的唯一入口
（显示设置抽屉里不再有"媒体类型"）。选中"收藏"时隐藏文件夹区。

**面包屑**在内容区顶部，不在顶栏。每一层（含"首页"和当前层）都可点，
当前层是实心深底白字。深目录横向可滚，加载后自动停在尾部让当前层可见。

**搜索默认不可见**：首帧把滚动位置跳到 `_headerScrollExtent`，
把搜索框顶出视野。滚到顶再往下拉一点才露出，位置介于内容和刷新指示器之间。
它始终在 widget 树里，靠滚动位置隐藏而不是靠 `if` 摘除，所以下拉能连续把它带出来，
继续下拉照样触发 `RefreshIndicator`，**刷新不受影响**。

- **没有"搜索模式"这个状态**。有没有在搜索完全由 `_searchQuery` 是否为空决定，
  不要再引入 `_searching` 布尔量：它和 `_searchQuery` 必然会不同步。
- 输入时不发请求，只在 `onSubmitted` 提交。`onChanged` 仅用来让清除按钮显隐。
- **换目录必须清搜索**（`_enterFolder` / `_goBack` / `_navigateToPathIndex` 三处）：
  否则旧关键词会静默过滤新目录，连子文件夹一起藏掉。
- `_headerScrollExtent` 要跟着 `_buildInlineHeader` 的实际构成走
  （有无面包屑高度不同）。算少了会露出半截搜索框，算多了会把文件夹标题吃掉。

### 3.1.3 返回手势：canPop 和 _handleBack 必须枚举同一组状态

手机侧滑返回/返回键的处理集中在 `gallery_view` 的一个 `PopScope`，
优先级从"最浮在上面"到"最底层"：

| # | 状态 | 动作 |
|---|---|---|
| 1 | 查看器打开 | **只拦截，不处理** —— 查看器有自己的 PopScope 负责关闭动画 |
| 2 | 多选中 | 退出多选 |
| 3 | 有搜索结果 | 清搜索 |
| 4 | 在子目录 | 回上一级 |
| 5 | 都没有 | 真的 pop（退出 app） |

**`canPop` 的条件必须和 `_handleBack` 的分支一一对应。** 漏掉一个状态的表现是
"返回键越级"——比如漏了多选，长按进多选后按返回会直接退出当前文件夹。
加新的可关闭状态（抽屉、弹层、编辑态…）时**两处一起改**。

第 1 条的 `if (_viewerIndex != null) return;` 看着像空分支，但不能删：
删了会继续往下落到第 4 条，变成"在查看器里按返回直接退出了当前文件夹"。

### 3.1.4 铁律：条件包装会重置滚动位置

**滚动子树里的 widget，其父节点类型不能随状态变化。** 这条踩过两次，
表现都是"进多选/缩放后列表跳回顶部、缩略图变空白"：

```dart
// ✘ enabled 翻转时 child 的父节点类型变了，element 被卸载重建，
//   CustomScrollView 的滚动位置直接丢失
if (!enabled) return child;
return RawGestureDetector(gestures: {...}, child: child);

// ✔ 永远渲染同一层，只切内容。空 map 不会创建识别器，零开销
return RawGestureDetector(
  gestures: enabled ? {...} : const {},
  child: child,
);
```

同理 `_pinchWrap` 必须**永远**返回 `Transform.scale`（idle 时 scale=1.0），
不能写 `if (idle) return child`。

sliver 同理：用 `SliverOpacity` + `SliverIgnorePointer` 隐藏，
不要用 `if (...)` 从 `slivers:` 数组里增删 —— 增删会让后续所有 sliver 位移。

### 3.1.1 手势：必须用 RawGestureDetector，不要用 GestureDetector

滚动容器里的自定义手势会和 ScrollView 的 `VerticalDragGestureRecognizer`
抢手势竞技场，而 drag 通常先赢。踩过两次，都别再改回去：

**滑选（`drag_select.dart`）** —— 用 `RawGestureDetector` +
`DelayedMultiDragGestureRecognizer`（160ms），不要用 `onLongPressStart/MoveUpdate`。
后者要等 500ms，期间任何移动都被 scroll 抢走，结果"按住滑动变成上下滚动"，
滑选永远触发不了。命中判定走 hit-test 找 `DragSelectItem` 埋的 `MetaData`，
不做网格几何换算 —— CustomScrollView 多 sliver（文件夹区 + 按天分组的多个网格）
下几何根本算不出来。快速滑动时指针事件稀疏，要补齐跨过的中间下标。

**双指缩放列数** —— 用 `Listener` 自己数指针，不要用 `ScaleGestureRecognizer`。
数到 2 指就把 `physics` 换成 `NeverScrollableScrollPhysics` 让 scroll 退出竞争。
缩放过程中只做 `Transform.scale` 视觉反馈，**松手才真正改列数**：过程中改列数
每跨一档都要重建整棵网格，手感是一顿一顿的。

### 3.2 收藏
- 数据：`media.favorite` 0/1，服务端 `PATCH /v1/media/{id}` 或 `POST /v1/media/batch-favorite`。
- 图标：`favorite_border`(空心) → `favorite`(实心)，颜色用近黑(#0F0F0F)而非黄色，查看器深色底上用纯白。
- 缩略图角标：收藏时右上角显示白色小心形(12px)，不选择时才显示。
- 多选工具栏心形按钮：选中项全部已收藏→取消收藏，否则→全部收藏。
- chips「收藏」：纯文字，与「全部/图片/视频」风格一致，无图标。

### 3.3 下载（一律先选保存位置）
- 单张（查看器）/ 打包（多选）：弹系统"另存为"对话框（桌面），移动端存到应用文档目录 `iGallery/`。
- 逐个下载（多选）：弹"选择文件夹"对话框。
- 禁止写进 `getTemporaryDirectory()`（用户看不到）。
- 下载保留原始 `taken_at` 作为文件修改时间。

### 3.4 图片查看器
- 全屏覆盖层（Stack），不跳路由。
- 背景：高斯模糊 + 半透明黑。点击背景关闭。
- 系统返回手势（侧滑/返回键）关闭查看器（PopScope）。
- 鼠标移入自动显示 UI（桌面），轻点显示/隐藏（手机）。
- 左右箭头 + PageView 滑动切换。
- 默认显示详情面板，点 info 隐藏。
- **工具栏只留三个**：关闭（左）· 缩放百分比 + 收藏 + 三点菜单（右）。
  其余操作（下载/重命名/详情/删除）全部收进三点菜单。
- 缩放：**点击百分比数字循环** 100% → 150% → 200% → 50%，不做 +/- 按钮。
- 视频工具：播放/暂停 + 进度条 + 倍速 + 全屏。
  倍速按钮必须自己订阅 `player.stream.rate`（它被塞进 `bottomButtonBar`，
  父级 `setState` 不会重建它 —— 这是"倍速显示永远 1x"的根因）。
- 过渡动画可配（淡入/缩放/无）。
- **不做裁剪/编辑**。本项目定位是纯管理工具，不做图片编辑。

### 3.5 多服务器
- 启动默认连 `127.0.0.1:9600`，连不上 3 秒重试。
- mDNS 发现并行运行。
- 服务器列表：激活的绿色 ✓，其他可点击切换，× 删除。
- 点击已激活的服务器取消选择。

### 3.6 弹层规范
| 场景 | 移动端 | 桌面端 |
|---|---|---|
| 全局设置 | `Navigator.push` 整页 | 左侧 `Drawer` |
| 显示设置 | 底部 `Sheet` | 右侧 `endDrawer` |
| 选项选择 | 底部 `Sheet` | 底部 `Sheet`（统一） |
| 确认删除 | 居中 `Dialog` | 居中 `Dialog` |
| 重命名 | 居中 `Dialog` | 居中 `Dialog` |

---

## 4. 服务端规范

### 4.1 数据库 Schema（28 字段）
```
media 表：
id, filename, ext, mime, media_type(image/video/audio/other),
size, width, height, duration, orientation,
taken_at, created_at, updated_at, deleted_at(逻辑删除),
checksum(SHA256),
exif_make, exif_model, exif_lens, exif_focal_length,
exif_aperture, exif_iso, exif_exposure,
exif_gps_lat, exif_gps_lng,
favorite, tags(JSON 数组), notes, has_thumb
```

- 逻辑删除：`deleted_at` 为 NULL 表示存活，有值表示已删。支持 restore。
- 11 个索引覆盖所有查询模式。
- 宁多不少：字段全预留，避免后续加字段。

### 4.2 查询 API（cursor 分页）
```
POST /v1/media/query
{
  "filter": {
    "and": [
      {"field": "deleted_at", "op": "is_null"},
      {"field": "media_type", "op": "=", "value": "image"},
      {"field": "size", "op": ">=", "value": 1048576}
    ]
  },
  "sort": [{"field": "taken_at", "dir": "desc"}],
  "size": 50,
  "cursor": "eyJ2IjoiMjAyNi0wOS0wMi4uLiIsImlkIjoidXVpZC0uLi4ifQ",  // base64({v, id}), 可选
  "with_total": false     // 首页可 true 拿一次 total, 后续 false 减少 count 开销
}

// 响应
{
  "items": [...MediaRow],
  "next_cursor": "base64...",   // null 表示到底
  "total": 12345                 // with_total=true 时才有
}
```

- 支持 `and` / `or` 嵌套。
- 操作符：`= != > < >= <= like in between is_null is_not_null`。
- 任意字段可排序。**cursor 由主排序字段值 + id 组成**，翻页无漂移。
- 兼容旧 `page` 参数（不传 cursor 时按 page 逻辑），但新代码一律用 cursor。

### 4.3 上传
- 流式写入磁盘（`field.chunk()`），不全量缓存内存。
- SHA256 边写边算，写完去重。
- Body limit 4GB，支持大视频。

**拍摄时间优先级（高 → 低），别再改顺序：**

| # | 来源 | 谁提供 |
|---|---|---|
| 1 | `taken_at` 字段 | 客户端从系统相册库读到的权威值（移动端 `AssetEntity.createDateTime`） |
| 2 | EXIF | `DateTimeOriginal` → `DateTime` |
| 3 | QuickTime | 视频 `creation_time`（ffprobe） |
| 4 | `file_mtime` 字段 | 客户端文件 mtime，最弱兜底 |

- **1 必须压过 2**：移动端交上来的 File 是相册**导出的缓存副本**，mtime 是导出
  那一刻；iOS 走 `PHImageManager` 导出时还可能把 EXIF `DateTime` 写成导出时刻，
  那样 EXIF 反而是错的。系统相册库里的 `createDateTime` 才是真实拍摄时间。
- **`taken_at` 和 `file_mtime` 必须分成两个字段**：合成一个的话，桌面端送上来的
  mtime 会盖掉本该胜出的 EXIF。桌面选的是磁盘原文件，只送 `file_mtime`。
- 两个字段都过 `normalize_ts()` 归一成北京时间 RFC3339，解析失败视为未提供。
  cursor 分页按 `taken_at` **字符串**排序，格式不一致会让翻页乱序。
- multipart 里这些字段必须排在 `file` 之前才生效。`http` 包的 `MultipartRequest`
  先写 fields 再写 files，客户端天然满足，但换 HTTP 库时要重新确认。

### 4.4 完整 API 列表
```
POST   /v1/media/query          通用查询（cursor 分页）
POST   /v1/media/probe          秒传探测（客户端上传前算 SHA256）
POST   /v1/media/upload         单/多文件上传（multipart）
POST   /v1/media/upload-batch   批量上传
GET    /v1/media/{id}           原始文件（immutable cache）
GET    /v1/media/{id}/thumb     缩略图 300×300 JPEG（immutable cache）
GET    /v1/media/{id}/download  作为附件下载（RFC 5987 filename）
DELETE /v1/media/{id}           逻辑删除
PATCH  /v1/media/{id}           更新字段（返回更新后完整 row）
POST   /v1/media/{id}/restore   恢复删除
POST   /v1/media/batch-delete   批量逻辑删除（单条 UPDATE）
POST   /v1/media/batch-move     批量移动到文件夹
POST   /v1/media/batch-favorite 批量收藏/取消收藏 {ids, favorite}
POST   /v1/media/download       批量流式 ZIP（async_zip）
GET    /v1/folders              列表（parent_id 查询串，一条 SQL 拿 cover+count）
POST   /v1/folders              创建
GET    /v1/folders/{id}         详情
GET    /v1/folders/{id}/ancestors  祖先路径（面包屑用）
PATCH  /v1/folders/{id}         重命名
DELETE /v1/folders/{id}         删除（递归：子树内媒体逻辑删除，子文件夹一并移除）
GET    /v1/info                 服务器信息
GET    /v1/auth                 {required, authorized}（探测是否需 token）
```

**鉴权**：启动时 `--token <val>` 或 `IGALLERY_TOKEN=<val>` env；未指定则关闭鉴权。启用时除 `/v1/auth` 外所有请求必须带 `Authorization: Bearer <val>`。

---

## 5. 显示偏好（DisplayPrefs）

所有可配项集中在 `display_prefs.dart`，通过 Provider 全局响应。

| 类别 | 配置项 | 默认值 |
|---|---|---|
| 排序 | sortField / sortOrder | takenAt / desc |
| 筛选 | mediaFilter / minSize / maxSize / dateFrom / dateTo | all / null |
| 缩略图标签 | showName / showTime / showSize / showDimensions / showCamera | off / on / off / off / off |
| 标签位置 | labelPosition | overlay |
| 网格 | gridDensity | medium |
| 分组 | groupMode | day |
| 查看器 | viewerTransition | fade |

---

## 6. 性能

- 几千张图片全走服务端分页 + 索引查询，客户端不做全量过滤。
- 上传流式写磁盘，内存占用恒定。
- 缩略图 300×300 JPEG，网格滚动流畅。
- 长列表加 `RepaintBoundary`。
- **磁盘缓存**（`core/disk_cache.dart`）：
  - 缩略图：`getApplicationSupportDirectory()/igallery_cache/thumbs/{id}.jpg`，30 天 TTL + 200 MB LRU
  - 视频原文件：单文件 ≤ 50 MB 才缓存，图片原文件 ≤ 20 MB，合计上限 800 MB LRU
  - 用户完全无感知；设置里"本地缓存"入口显示占用并可清理
- **HTTP 缓存**：服务端 `/v1/media/{id}` 和 `/v1/media/{id}/thumb` 返回 `Cache-Control: public, max-age=2592000, immutable`
- **秒传**：客户端上传前算 SHA256 → `POST /v1/media/probe`，命中直接跳过传输
- **并发上传**：默认 4 并发

## 7. 鉴权

启动服务端时可选加 `--token abc123` 或 `IGALLERY_TOKEN=abc123` env。未指定则关闭鉴权（局域网默认无门槛）。

客户端流程：
1. `connect(info)` → `GET /v1/auth` → `{required, authorized}`
2. `required=true, authorized=false` → 状态置 `needAuth`（服务器行显示黄色钥匙）
3. 用户点击 → 弹密码输入框 → `submitToken(info, token)` → 校验成功存 `AuthStore`
4. token 存于 `KvStore` 里，key = `token:{host}:{port}`，切服务器互不影响

服务器状态色：`ok`（绿）· `needAuth`（黄）· `unreachable`（红）

---

## 8. 验证

- 服务端：`cargo build` 编译通过。
- 客户端：`flutter analyze` 零报错。
- 端到端：启动服务端 → 客户端自动连接 → 上传/浏览/筛选/删除/多服务器切换。
- 四端行为一致。

---

## 9. 构建环境

构建失败绝大多数不是代码问题，而是环境不匹配。换机器先对照这里。

### 9.1 版本要求

| 组件 | 版本 | 说明 |
|---|---|---|
| Flutter | 3.47+ stable | 低于此版本 `file_picker 12` 装不上（要求 Flutter 3.38+ / Dart 3.10+） |
| JDK | **21** | 由 `client/android/gradle/gradle-daemon-jvm.properties` 强制。不要用 JDK 25：Gradle 8.x 不支持；不要用 17 以下：AGP 9 不支持 |
| Android SDK | Platform 33–36 + Build-Tools 36 + NDK 28.2.13676358 + CMake 3.22.1 | 缺的组件 AGP 会自动下载（首次约 4GB，25 分钟），不需要 cmdline-tools |
| Xcode | 完整版，非 Command Line Tools | 只装 CLT 会让 `flutter run -d macos` 报 "No macOS desktop project configured"，因为 CLT 没有 `xcodebuild` |
| CocoaPods | 不需要 | 全部插件支持 SPM，macOS 走 `macos/Flutter/ephemeral/Packages/` |

工具链固定为 Gradle 9.3.1 + AGP 9.1.0 + Kotlin 2.4.0，由 `client/android/` 下的 wrapper 和 settings 锁定。

### 9.1.1 服务端运行时依赖：ffmpeg（可选）

`thumb.rs` 用 `Command::new("ffmpeg")` / `ffprobe`，**纯走 PATH 解析**
（Windows 上 std 自动补 `.exe`）。所以三端都一样：装好 + 加进 PATH + 重启服务，
**不需要改配置、不需要写绝对路径、不需要重新编译**。

- macOS：`brew install ffmpeg`
- Windows：装 [gyan.dev](https://www.gyan.dev/ffmpeg/builds/) 的 release build，
  把 `bin/` 加进系统 PATH，**然后重开终端再启服务** —— PATH 变更不会作用于已运行的进程。
- Linux（musl 静态包同样适用）：发行版包管理器装即可。

缺了不会致命：视频照样能传能播，只是**没有缩略图**，时长/分辨率退回 `mp4parse`
（只认 mp4/mov），QuickTime `creation_time` 也拿不到。

启动日志会打印 `ffmpeg: OK` / `ffprobe: OK`，缺了就是
`不在 PATH 上 —— 视频缩略图会缺失`。没法在目标机器上手动验证时看这两行就够了。

### 9.2 新机器初始化

```bash
brew install openjdk@21
sudo ln -sfn /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk \
  /Library/Java/JavaVirtualMachines/openjdk-21.jdk
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

JDK 由 Gradle 按 `toolchainVersion=21` 自动选择，不必设 `JAVA_HOME`，也不必 `flutter config --jdk-dir`。

### 9.3 构建命令

```bash
cd client
flutter build apk --release      # → build/app/outputs/flutter-apk/app-release.apk
flutter build macos --release    # → build/macos/Build/Products/Release/igallery.app
```

### 9.4 铁律

- **平台目录必须进版本控制**：`client/android/`、`client/macos/` 是源码不是产物。删掉靠 `flutter create` 重建会带进当前 Flutter 版本的新模板，导致工具链漂移。忽略边界由各平台目录自带的 `.gitignore` 界定，不要自己加规则。
- **`pubspec.lock` 必须提交**。
- **依赖升级看插件的 `compileSdk`**：插件在自己的 `android/build.gradle` 里硬编码 `compileSdk` 时，新版 AGP 的 AAR metadata 校验会直接失败。优先升级插件到跟随 `flutter.compileSdkVersion` 的版本，不要在 app 的 `build.gradle.kts` 里覆盖插件配置。
- **不留未使用的依赖**：`pubspec.yaml` 里零引用的包要删，它们会拖来无谓的版本冲突。
