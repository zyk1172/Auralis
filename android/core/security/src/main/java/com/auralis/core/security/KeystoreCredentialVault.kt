package com.auralis.core.security

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.auralis.core.opensubsonic.CredentialVault
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/**
 * Android Keystore 支撑的凭据存储。
 *
 * 对应 Apple 的做法：Room 只存 `credentialReference`，真正的密码 / API Key 存在
 * 系统安全存储里。Apple 用 Keychain（service = `com.auralis.player.credentials`，
 * accessible = afterFirstUnlockThisDeviceOnly，synchronizable = false）；
 * Android 用 MasterKey(AES256_GCM) + EncryptedSharedPreferences(AES256_SIV/GCM)，
 * 私钥由 Android Keystore 持有，不随备份导出。
 */
class KeystoreCredentialVault(context: Context) : CredentialVault {

    private val appContext = context.applicationContext

    private val prefs: SharedPreferences by lazy {
        val masterKey = MasterKey.Builder(appContext)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        EncryptedSharedPreferences.create(
            appContext,
            PREFERENCES_NAME,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    override suspend fun store(reference: String, secret: String) = withContext(Dispatchers.IO) {
        prefs.edit().putString(reference, secret).apply()
    }

    override suspend fun retrieve(reference: String): String? = withContext(Dispatchers.IO) {
        prefs.getString(reference, null)
    }

    override suspend fun delete(reference: String) = withContext(Dispatchers.IO) {
        prefs.edit().remove(reference).apply()
    }

    /** 全新引用，例如 `cred-<uuid>`。 */
    fun newReference(): String = "cred-${java.util.UUID.randomUUID()}"

    companion object {
        private const val PREFERENCES_NAME = "auralis_credentials"
    }
}
