package com.photohub.compressor.auth

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import com.photohub.compressor.data.AppSettings
import com.photohub.compressor.network.ApiHttpException
import com.photohub.compressor.network.PhotoHubApiClient
import com.photohub.compressor.sync.LocalProxySyncManager
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import java.security.MessageDigest
import java.security.SecureRandom

class GoogleAuthManager private constructor(context: Context) {
    private val appContext = context.applicationContext
    private val settings = AppSettings.getInstance(appContext)
    private val prefs = appContext.getSharedPreferences("photohub_pkce_state", Context.MODE_PRIVATE)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)

    private val _isAuthenticating = MutableStateFlow(false)
    val isAuthenticating: StateFlow<Boolean> = _isAuthenticating.asStateFlow()

    private val _errorMessage = MutableStateFlow<String?>(null)
    val errorMessage: StateFlow<String?> = _errorMessage.asStateFlow()

    fun startSignIn(activityContext: Context) {
        if (_isAuthenticating.value) return
        val gatewayUrl = settings.current.gatewayUrl
        if (gatewayUrl == null) {
            _errorMessage.value = "App build does not have PHOTOHUB_GATEWAY_URL configured."
            return
        }

        _errorMessage.value = null
        _isAuthenticating.value = true

        val verifier = generateCodeVerifier()
        val challenge = makeCodeChallenge(verifier)
        prefs.edit().putString("pending_verifier", verifier).apply()

        val authUri = Uri.parse("$gatewayUrl/api/auth/google/start")
            .buildUpon()
            .appendQueryParameter("code_challenge", challenge)
            .appendQueryParameter("redirect_uri", REDIRECT_URI)
            .build()

        try {
            val customTabs = CustomTabsIntent.Builder().build()
            customTabs.launchUrl(activityContext, authUri)
        } catch (_: Exception) {
            try {
                val browserIntent = Intent(Intent.ACTION_VIEW, authUri)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                activityContext.startActivity(browserIntent)
            } catch (err: Exception) {
                _isAuthenticating.value = false
                _errorMessage.value = err.localizedMessage ?: "No browser available for Google sign-in."
            }
        }
    }

    fun cancelPendingUiStateIfReturnedWithoutCallback() {
        // Allows user to retry if they backed out of the Chrome Custom Tab manually
        if (_isAuthenticating.value && prefs.contains("pending_verifier")) {
            _isAuthenticating.value = false
        }
    }

    fun handleAuthCallbackIntent(intent: Intent?) {
        val uri = intent?.data ?: return
        if (uri.scheme != "photohub" || uri.host != "auth") return

        val oauthErr = uri.getQueryParameter("error")
        if (!oauthErr.isNullOrBlank()) {
            prefs.edit().remove("pending_verifier").apply()
            _isAuthenticating.value = false
            _errorMessage.value = oauthErr
            return
        }

        val oneTimeCode = uri.getQueryParameter("code")
        val verifier = prefs.getString("pending_verifier", null)
        val gatewayUrl = settings.current.gatewayUrl
        prefs.edit().remove("pending_verifier").apply()

        if (oneTimeCode.isNullOrBlank() || verifier.isNullOrBlank() || gatewayUrl == null) {
            _isAuthenticating.value = false
            _errorMessage.value = "Google sign-in did not return a valid authorization code."
            return
        }

        _isAuthenticating.value = true
        _errorMessage.value = null
        scope.launch {
            try {
                val client = PhotoHubApiClient(appContext, settings)
                val exchange = client.exchangeGoogleAuthCode(
                    code = oneTimeCode,
                    codeVerifier = verifier,
                    gatewayUrl = gatewayUrl
                )
                settings.applyGoogleSession(
                    token = exchange.token,
                    serverUrl = exchange.serverUrl,
                    nodeId = exchange.nodeId,
                    email = exchange.user.email,
                    name = exchange.user.name,
                    folderName = exchange.user.folderName
                )
                runCatching {
                    val info = PhotoHubApiClient(appContext, settings).whoami()
                    settings.updateServerStorage(info.storage)
                }
                LocalProxySyncManager.getInstance(appContext).syncFromServerOnLaunch()
            } catch (err: Exception) {
                _errorMessage.value = err.localizedMessage ?: "Sign-in failed."
            } finally {
                _isAuthenticating.value = false
            }
        }
    }

    suspend fun refreshGatewayRouteAndStorage() {
        val current = settings.current
        if (!current.isSignedIn) return
        val gatewayUrl = current.gatewayUrl ?: return

        try {
            val resolved = PhotoHubApiClient(appContext, settings).resolveAssignedNode(gatewayUrl)
            settings.updateResolvedNode(
                serverUrl = resolved.serverUrl,
                nodeId = resolved.nodeId,
                folderName = resolved.user?.folderName,
                email = resolved.user?.email,
                name = resolved.user?.name
            )
            val info = PhotoHubApiClient(appContext, settings).whoami()
            settings.updateServerStorage(info.storage)
        } catch (err: ApiHttpException) {
            if (err.statusCode == 401) {
                LocalProxySyncManager.getInstance(appContext).cancel()
                settings.signOut()
            }
        } catch (_: Exception) {
            runCatching {
                val info = PhotoHubApiClient(appContext, settings).whoami()
                settings.updateServerStorage(info.storage)
            }
        }
    }

    private fun generateCodeVerifier(): String {
        val bytes = ByteArray(32)
        SecureRandom().nextBytes(bytes)
        return Base64.encodeToString(bytes, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    private fun makeCodeChallenge(verifier: String): String {
        val digest = MessageDigest.getInstance("SHA-256").digest(verifier.toByteArray(Charsets.UTF_8))
        return Base64.encodeToString(digest, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)
    }

    companion object {
        const val REDIRECT_URI = "photohub://auth/callback"

        @Volatile
        private var instance: GoogleAuthManager? = null

        fun getInstance(context: Context): GoogleAuthManager =
            instance ?: synchronized(this) {
                instance ?: GoogleAuthManager(context).also { instance = it }
            }
    }
}
