package com.example.myapplication.sync

import com.example.myapplication.data.LocalAnimalIdentityConflict
import com.example.myapplication.data.normalizeAccountId
import com.example.myapplication.localization.AppLanguage

/** Never disclose another account's card name/UUID, nor offer selecting it in this scope. */
fun localAnimalIdentityConflictText(
    conflict: LocalAnimalIdentityConflict,
    activeAccountId: String?,
    language: AppLanguage,
): String {
    val sameAccount = activeAccountId?.let(::normalizeAccountId) == conflict.existingAccountId
    return if (language == AppLanguage.RUSSIAN) {
        if (sameAccount) "ID животного уже закреплён за карточкой «${conflict.existingProfileName}». Отмените создание и выберите существующее животное для редактирования. Смена клички не освобождает ID; черновик не удалён."
        else "ID животного уже закреплён за карточкой в другом аккаунте. Проверьте аккаунт и восстановите его данные с сервера, затем выберите существующее животное. Не создавайте новую карточку для обхода конфликта; черновик не удалён."
    } else {
        if (sameAccount) "Animal ID already belongs to “${conflict.existingProfileName}”. Cancel creation and select the existing animal to edit it. Renaming does not release the ID; your draft is preserved."
        else "Animal ID already belongs to a profile in another account. Check the account and restore its server data, then select the existing animal. Do not create a new profile to bypass this conflict; your draft is preserved."
    }
}
