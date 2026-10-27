package com.example.myapplication.sync

import com.example.myapplication.localization.AppLanguage

data class RestoreSkippedEntity(val kind: String, val id: String, val status: Int, val dogId: String? = null, val confirmedRetirement: Boolean = false)

fun restoreWarningsText(warnings: List<RestoreSkippedEntity>, language: AppLanguage): String? {
    if(warnings.isEmpty()) return null
    val ru=language==AppLanguage.RUSSIAN
    val unknown=warnings.count { !it.confirmedRetirement }
    val title=if(ru) "Восстановление завершено частично: пропущено недоступных элементов ${warnings.size}; без подтверждения удаления — $unknown. Локальная копия не удаляется по одному ответу 404. Явные удаления сервера выполняются отдельно. Проверьте адрес и аккаунт, затем повторите восстановление." else "Restore completed partially: ${warnings.size} unavailable items skipped; $unknown without confirmed retirement. A 404 response alone does not remove a local copy. Explicit server retirements are applied separately. Check the server address and account, then retry restore."
    val details=warnings.take(20).joinToString("\n") { "${it.kind} ${it.id}: HTTP ${it.status}" }
    return title+"\n"+details+if(warnings.size>20) (if(ru) "\nЕщё ${warnings.size-20} элементов пропущено." else "\n${warnings.size-20} further items skipped.") else ""
}
