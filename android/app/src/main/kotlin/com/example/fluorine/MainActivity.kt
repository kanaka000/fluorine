package com.example.fluorine

import android.content.ActivityNotFoundException
import android.content.Intent
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    // 添付ファイルを外部アプリで開く（2026-11-19）
    // 添付はアプリ専用の一時フォルダ（cache/attachments）にだけ置き、そこにあるファイルだけを
    // 一時的な読み取り許可付きで外部アプリに渡す。ストレージの権限は使わない
    private val attachmentsDir: File
        get() = File(cacheDir, "attachments").apply { mkdirs() }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "app/attachments")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "dir" -> result.success(attachmentsDir.canonicalPath)
                    "open" -> {
                        val path = call.argument<String>("path")
                        val mime = call.argument<String>("mime")
                        if (path == null || mime == null) {
                            result.error("args", "path と mime が必要です", null)
                            return@setMethodCallHandler
                        }
                        try {
                            val file = File(path).canonicalFile
                            val root = attachmentsDir.canonicalPath + File.separator
                            // 一時フォルダの外のファイルは渡さない
                            if (!file.path.startsWith(root) || !file.isFile) {
                                result.error("path", "一時フォルダの外のファイルです", null)
                                return@setMethodCallHandler
                            }
                            val uri = FileProvider.getUriForFile(this, "$packageName.attachments", file)
                            val intent = Intent(Intent.ACTION_VIEW)
                                .setDataAndType(uri, mime)
                                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                            startActivity(intent)
                            result.success("ok")
                        } catch (e: ActivityNotFoundException) {
                            result.success("noApp")
                        } catch (e: Exception) {
                            result.error("open", e.toString(), null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }
}
