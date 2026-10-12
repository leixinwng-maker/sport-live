package com.wendao.ai_planner

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.plugin.common.MethodChannel
import java.io.File

// local_auth 生物识别要求 Activity 为 FlutterFragmentActivity（提供 Fragment 上下文）
class MainActivity : FlutterFragmentActivity() {
    private var pickResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: io.flutter.embedding.engine.FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "pickFolder" -> {
                        // Gadgetbridge 导出文件夹授权（SAF）
                        pickResult = result
                        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).addFlags(
                            Intent.FLAG_GRANT_READ_URI_PERMISSION
                                or Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION
                        )
                        startActivityForResult(intent, REQ_PICK_FOLDER)
                    }
                    "getSavedFolder" -> result.success(prefs().getString(KEY_TREE_URI, null))
                    "clearSavedFolder" -> {
                        val saved = prefs().getString(KEY_TREE_URI, null)
                        if (saved != null) {
                            try {
                                contentResolver.releasePersistableUriPermission(
                                    Uri.parse(saved), Intent.FLAG_GRANT_READ_URI_PERMISSION
                                )
                            } catch (_: Exception) {
                                // 权限已失效时忽略
                            }
                        }
                        prefs().edit().remove(KEY_TREE_URI).apply()
                        result.success(null)
                    }
                    "statExportFile" -> {
                        val candidates = call.argument<List<String>>("candidates") ?: emptyList()
                        try {
                            result.success(statExport(candidates))
                        } catch (e: Exception) {
                            result.error("SAF_STAT_FAILED", e.message, null)
                        }
                    }
                    "copyExportFile" -> {
                        val candidates = call.argument<List<String>>("candidates") ?: emptyList()
                        try {
                            result.success(copyExport(candidates))
                        } catch (e: Exception) {
                            result.error("SAF_COPY_FAILED", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_PICK_FOLDER) {
            val pending = pickResult
            pickResult = null
            val uri = data?.data
            if (resultCode == Activity.RESULT_OK && uri != null) {
                try {
                    contentResolver.takePersistableUriPermission(
                        uri, Intent.FLAG_GRANT_READ_URI_PERMISSION
                    )
                } catch (_: Exception) {
                    // 个别文件管理器不支持持久化授权，仍按一次性授权处理
                }
                prefs().edit().putString(KEY_TREE_URI, uri.toString()).apply()
                pending?.success(uri.toString())
            } else {
                pending?.success(null)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // ---- 内部工具 ----

    private fun prefs() = getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    private fun findExportDoc(candidates: List<String>): Pair<Uri, String>? {
        val treeUriStr = prefs().getString(KEY_TREE_URI, null) ?: return null
        val treeUri = Uri.parse(treeUriStr)
        val wanted = candidates.toHashSet()
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri)
        )
        contentResolver.query(
            childrenUri,
            arrayOf(
                DocumentsContract.Document.COLUMN_DOCUMENT_ID,
                DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            ),
            null, null, null
        )?.use { c ->
            val idIdx = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
            val nameIdx = c.getColumnIndexOrThrow(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
            while (c.moveToNext()) {
                val name = c.getString(nameIdx) ?: continue
                if (name in wanted) {
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, c.getString(idIdx))
                    return docUri to name
                }
            }
        }
        return null
    }

    /** 查询导出文件元信息：存在返回 {name,lastModified,size}，否则 null */
    private fun statExport(candidates: List<String>): Map<String, Any?>? {
        val found = findExportDoc(candidates) ?: return null
        return contentResolver.query(
            found.first,
            arrayOf(
                DocumentsContract.Document.COLUMN_LAST_MODIFIED,
                DocumentsContract.Document.COLUMN_SIZE,
            ),
            null, null, null
        )?.use { c ->
            if (c.moveToFirst()) {
                mapOf(
                    "name" to found.second,
                    "lastModified" to c.getLong(0),
                    "size" to c.getLong(1),
                )
            } else null
        }
    }

    /** 把导出文件拷贝到应用缓存（避免直接打开 SAF 流句柄过久），返回 {name,path,lastModified,size} */
    private fun copyExport(candidates: List<String>): Map<String, Any?>? {
        val found = findExportDoc(candidates) ?: return null
        // 取源文件的修改时间（用于增量判断；拷贝时间每次都会变，不能用来判断导出是否更新）
        val sourceMtime = contentResolver.query(
            found.first,
            arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED),
            null, null, null
        )?.use { c -> if (c.moveToFirst()) c.getLong(0) else null }
        val dir = File(cacheDir, "gb_import").apply { mkdirs() }
        // 先写临时文件再原子改名，避免拷贝中途读到半截库
        val tmp = File(dir, "export.db.tmp")
        val dest = File(dir, "export.db")
        contentResolver.openInputStream(found.first)?.use { input ->
            tmp.outputStream().use { output -> input.copyTo(output) }
        } ?: return null
        if (dest.exists()) dest.delete()
        if (!tmp.renameTo(dest)) {
            tmp.delete()
            throw IllegalStateException("临时文件改名失败")
        }
        return mapOf(
            "name" to found.second,
            "path" to dest.absolutePath,
            "lastModified" to (sourceMtime ?: dest.lastModified()),
            "size" to dest.length(),
        )
    }

    companion object {
        private const val CHANNEL = "wendao/gadgetbridge_saf"
        private const val PREFS_NAME = "wendao_saf"
        private const val KEY_TREE_URI = "gb_export_tree_uri"
        private const val REQ_PICK_FOLDER = 42001
    }
}
