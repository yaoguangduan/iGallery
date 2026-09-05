package dtdyq.igallery

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Settings
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        private const val CHANNEL = "igallery/media_permission"
        private const val SDK_S = 31 // Build.VERSION_CODES.S
    }

    /// Android 12+「允许管理所有媒体文件」(MANAGE_MEDIA) 的查询与设置页跳转。
    /// 授予后 MediaStore 删除请求由系统静默放行：photo_manager 的 createDeleteRequest
    /// 不再弹「允许删除?」确认框（免弹是系统 PermissionActivity 侧行为，与插件版本无关）。
    /// Android 11 及以下系统无免弹通道，Dart 侧据 unsupported 不做引导。
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "manageMediaStatus" -> result.success(manageMediaStatus())
                    "openManageMediaSettings" -> result.success(openManageMediaSettings())
                    else -> result.notImplemented()
                }
            }
    }

    /// 三态：unsupported(Android<12 无此权限) / granted / notGranted。
    /// 用 checkSelfPermission 而非 MediaStore.canManageMedia：后者是 API 31 才有的方法，
    /// 前者 API 23+ 即可用；MANAGE_MEDIA 是 String 常量、编译期内联，低版本运行时无引用。
    private fun manageMediaStatus(): String {
        if (Build.VERSION.SDK_INT < SDK_S) return "unsupported"
        val granted = checkSelfPermission(Manifest.permission.MANAGE_MEDIA) ==
            PackageManager.PERMISSION_GRANTED
        return if (granted) "granted" else "notGranted"
    }

    /// 打开系统「允许管理所有媒体文件」设置页。该页无结果回调，
    /// 用户切完开关返回后由 Dart 侧重新查询 manageMediaStatus。
    private fun openManageMediaSettings(): Boolean {
        if (Build.VERSION.SDK_INT < SDK_S) return false
        return try {
            startActivity(
                Intent(Settings.ACTION_REQUEST_MANAGE_MEDIA).apply {
                    data = Uri.parse("package:$packageName")
                }
            )
            true
        } catch (e: Exception) {
            false // 个别 ROM 缺该设置页
        }
    }
}
