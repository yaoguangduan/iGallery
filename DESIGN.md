# iGallery — 局域网相册

局域网内的照片视频管理工具。笔记本做服务器，手机/电脑自动发现连接，零配置。

## 技术栈

- **服务端**: Rust (Axum) — 单二进制，低资源占用
- **客户端**: Flutter 四端 (Android/iOS/macOS/Windows)
- **发现**: mDNS (`_igallery._tcp.local`)
- **存储**: 服务端本地文件系统 + SQLite 索引

## 服务端

### 依赖

```toml
axum = "0.8"
tokio = { version = "1", features = ["full"] }
serde = { version = "1", features = ["derive"] }
serde_json = "1"
sqlx = { version = "0.8", features = ["runtime-tokio", "sqlite"] }
tower-http = { version = "0.6", features = ["cors", "fs"] }
uuid = { version = "1", features = ["v4"] }
image = "0.25"              # 缩略图生成
kamadak-exif = "0.6"        # EXIF 读取
zip = "2"                   # 压缩下载
mdns-sd = "0.11"            # mDNS 服务注册
chrono = "0.4"
tracing = "0.1"
tracing-subscriber = "0.3"
```

### 存储结构

```
data/
  media/          # 原始文件 {uuid}.{ext}
  thumbs/         # 缩略图 {uuid}.jpg (300x300)
  gallery.db      # SQLite 索引
```

### 数据库表

```sql
CREATE TABLE media (
  id TEXT PRIMARY KEY,          -- UUID
  filename TEXT NOT NULL,        -- 原始文件名
  mime TEXT NOT NULL,            -- image/jpeg, video/mp4 等
  size INTEGER NOT NULL,         -- 字节
  width INTEGER,
  height INTEGER,
  taken_at TEXT,                 -- EXIF 拍摄时间 (ISO 8601)
  created_at TEXT NOT NULL,      -- 上传时间
  checksum TEXT                  -- SHA256 去重
);
```

### API

```
GET    /v1/media                   列表 (?page=1&size=50&order=taken_at)
GET    /v1/media/{id}              原图/视频
GET    /v1/media/{id}/thumb        缩略图 (300x300 JPEG)
POST   /v1/media/upload            单文件上传 (multipart/form-data)
POST   /v1/media/upload-batch      批量上传 (多个 file 字段)
DELETE /v1/media/{id}              删除
POST   /v1/media/batch-delete      批量删除 (JSON body: {ids: [...]})
POST   /v1/media/download          批量下载 → zip (JSON body: {ids: [...]})
POST   /v1/media/download-all      全量下载 → zip
GET    /v1/info                    服务器信息 (名称/版本/存储空间/文件数)
```

**上传保留元数据:**
- multipart 字段: `file` (文件) + 可选 `taken_at` (客户端传原始拍摄时间)
- 服务端从 EXIF 提取 `DateTimeOriginal`，客户端传的 `taken_at` 作为 fallback
- 原始文件不做任何处理（不压缩、不剥 EXIF），保持原样存储

**批量下载:**
- 流式 zip，不需要先写临时文件
- 文件名用原始 filename，冲突加序号
- 支持选择是否压缩图片质量 (`?quality=original|compressed`)

### mDNS 广播

```rust
// 启动时注册:
// 服务名: iGallery-{hostname}
// 类型: _igallery._tcp.local
// 端口: 9600
// TXT: version=1, name={用户设置的名称}
```

### 源码结构

```
server/src/
  main.rs          # 启动 HTTP + mDNS
  db.rs            # SQLite 连接 + 查询
  media.rs         # upload/download/list/delete handlers
  thumb.rs         # 缩略图生成 (image crate resize)
  exif_util.rs     # EXIF 时间提取
  archive.rs       # zip 打包
  mdns.rs          # mDNS 注册
```

## 客户端 (Flutter)

### 设计风格

沿用 iEnglish 的大巧不工风格:
- 移动端底部导航 (2 tab: 相册 / 设置)
- 桌面端侧边栏
- 共享组件在 `lib/ui/shared/`
- 主题/字体/间距复用 iEnglish 的 `app_theme.dart` 模式

### 页面

1. **相册页 (GalleryView)**
   - 照片墙：按日期分组（今天 / 昨天 / 2024年8月 ...）
   - GridView 瀑布流，加载缩略图
   - 长按多选 → 底部操作栏（下载 / 删除）
   - 点击 → 全屏查看 (MediaViewer)
   - 右上角上传按钮

2. **全屏查看 (MediaViewer)**
   - PageView 左右滑动
   - 双指缩放
   - 底部显示文件名 / 拍摄时间 / 尺寸
   - 视频用 `video_player` 播放
   - 右上角: 下载原图 / 删除 / 详情

3. **上传页 (UploadPage)**
   - `file_picker` / `image_picker` 选择多文件
   - 显示进度条（每个文件单独进度 + 总进度）
   - 保留原始拍摄时间上传

4. **设置页 (SettingsPage)**
   - 服务器连接状态（自动发现 / 手动输入 IP）
   - 服务器信息（名称 / 存储空间 / 文件数）
   - 主题切换

### 核心服务

```dart
// mDNS 自动发现
class DiscoveryService {
  Stream<ServerInfo> discover();   // bonsoir 扫描
  ServerInfo? current;             // 当前连接的服务器
}

// 媒体操作
class MediaService {
  Future<PageResult<MediaItem>> list({int page, int size});
  Future<void> upload(List<XFile> files, {void Function(double)? onProgress});
  Future<void> delete(List<String> ids);
  Future<File> download(String id);
  Future<File> downloadBatch(List<String> ids);  // → zip
  String thumbUrl(String id);
  String fullUrl(String id);
}
```

### 依赖

```yaml
dependencies:
  flutter: { sdk: flutter }
  provider: ^6.1.5
  http: ^1.6.0
  bonsoir: ^5.1.0           # mDNS 发现
  file_picker: ^8.1.6
  video_player: ^2.9.0
  photo_view: ^0.15.0       # 双指缩放
  path_provider: ^2.1.6
  share_plus: ^12.0.2
  intl: ^0.20.3
```

## 启动方式

### 服务端

```bash
cd server
cargo run --release
# 默认 0.0.0.0:9600, 数据存在 ./data/
# 环境变量: PORT, DATA_DIR, DEVICE_NAME
```

### 客户端

```bash
flutter run -d macos    # 或 android / ios / windows
# 自动发现同局域网的 iGallery 服务，零配置
```

## 实现顺序

1. 服务端骨架: main.rs + db.rs + media.rs (上传/列表/下载)
2. 缩略图 + EXIF: thumb.rs + exif_util.rs
3. mDNS: mdns.rs
4. Flutter 骨架: shell + 设置页 + 发现连接
5. 相册页: GridView + 缩略图加载 + 按日期分组
6. 全屏查看 + 视频播放
7. 批量操作: 多选 + 批量下载(zip) + 批量删除
8. 上传页: 多文件选择 + 进度 + 元数据保留
