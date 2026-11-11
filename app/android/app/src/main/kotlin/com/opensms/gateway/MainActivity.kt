package com.opensms.gateway

import android.Manifest
import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.telephony.SmsManager
import android.telephony.TelephonyManager
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Native side of the SMS bridge.
 *
 * Sending happens entirely through [SmsManager], so no SMS composer UI is ever
 * shown. Every part of a multipart SMS gets its own SENT PendingIntent; the
 * Dart future resolves only when all parts have been acknowledged (or the
 * first part fails / the 90s watchdog fires).
 *
 * Note: this uses the default SMS subscription. For dual-SIM devices where the
 * gateway must send from a specific SIM, replace [resolveSmsManager] with
 * `SmsManager.getSmsManagerForSubscriptionId(id)` and pass the subscription id
 * from the Flutter settings screen.
 */
class MainActivity : FlutterActivity() {

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "sendSms" -> handleSendSms(call, result)
                    "simInfo" -> result.success(simInfo())
                    "startForegroundService" -> {
                        GatewayForegroundService.start(
                            this,
                            call.argument<String>("text") ?: DEFAULT_NOTIFICATION,
                        )
                        result.success(true)
                    }
                    "stopForegroundService" -> {
                        GatewayForegroundService.stop(this)
                        result.success(true)
                    }
                    "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBatteryOptimizations())
                    "requestIgnoreBatteryOptimizations" -> result.success(requestIgnoreBatteryOptimizations())
                    else -> result.notImplemented()
                }
            }
    }

    /* ------------------------------- SMS ---------------------------------- */

    private fun handleSendSms(call: MethodCall, result: MethodChannel.Result) {
        val id = call.argument<String>("id") ?: UUID.randomUUID().toString()
        val to = call.argument<String>("to")?.trim()
        val message = call.argument<String>("message")

        if (to.isNullOrEmpty() || message.isNullOrEmpty()) {
            result.error("invalid_arguments", "Both 'to' and 'message' are required.", null)
            return
        }
        if (!hasPermission(Manifest.permission.SEND_SMS)) {
            result.error("permission_denied", "SEND_SMS permission is not granted.", null)
            return
        }

        val smsManager = resolveSmsManager()
        if (smsManager == null) {
            result.error("sms_unavailable", "SMS manager is unavailable on this device.", null)
            return
        }

        val parts = try {
            smsManager.divideMessage(message)
        } catch (e: Exception) {
            Log.w(TAG, "divideMessage failed, sending as a single part", e)
            null
        } ?: arrayListOf(message)

        val sentAction = "$SENT_ACTION_PREFIX.$id"
        val deliveredAction = "$DELIVERED_ACTION_PREFIX.$id"
        val flags = PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        val sentIntents = ArrayList<PendingIntent>(parts.size)
        val deliveredIntents = ArrayList<PendingIntent>(parts.size)

        for (index in parts.indices) {
            sentIntents.add(
                PendingIntent.getBroadcast(
                    this,
                    (id.hashCode() * 31) + index,
                    Intent(sentAction).setPackage(packageName),
                    flags,
                ),
            )
            // Delivery reports depend on the carrier; we create the intents so
            // they are available for future use, but the SENT intent is what
            // determines the reported status.
            deliveredIntents.add(
                PendingIntent.getBroadcast(
                    this,
                    (id.hashCode() * 37) + index,
                    Intent(deliveredAction).setPackage(packageName),
                    flags,
                ),
            )
        }

        val completed = AtomicBoolean(false)
        val remaining = intArrayOf(parts.size)
        val failure = arrayOfNulls<String>(1)
        val handler = Handler(Looper.getMainLooper())
        var receiver: BroadcastReceiver? = null

        fun finish(outcome: String, reason: String?) {
            if (!completed.compareAndSet(false, true)) return
            handler.removeCallbacksAndMessages(null)
            receiver?.let {
                try {
                    unregisterReceiver(it)
                } catch (_: IllegalArgumentException) {
                    // already unregistered
                }
            }
            receiver = null

            if (outcome == STATUS_SENT) {
                result.success(STATUS_SENT)
            } else {
                result.error("send_failed", reason ?: "The SMS could not be sent.", null)
            }
        }

        val smsReceiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action != sentAction) return
                if (resultCode != Activity.RESULT_OK) {
                    failure[0] = describeSentError(resultCode)
                }
                remaining[0] -= 1
                if (remaining[0] <= 0) {
                    val reason = failure[0]
                    if (reason == null) finish(STATUS_SENT, null) else finish(STATUS_FAILED, reason)
                }
            }
        }
        receiver = smsReceiver

        try {
            val filter = IntentFilter(sentAction)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(smsReceiver, filter, Context.RECEIVER_NOT_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(smsReceiver, filter)
            }
        } catch (e: Exception) {
            result.error("receiver_failed", e.message, null)
            return
        }

        handler.postDelayed({
            finish(STATUS_FAILED, "Timed out waiting for the network to confirm the SMS.")
        }, SEND_TIMEOUT_MS)

        try {
            if (parts.size == 1) {
                smsManager.sendTextMessage(to, null, message, sentIntents[0], deliveredIntents[0])
            } else {
                smsManager.sendMultipartTextMessage(to, null, parts, sentIntents, deliveredIntents)
            }
            Log.i(TAG, "SMS $id handed to the radio (parts=${parts.size})")
        } catch (e: Exception) {
            finish(STATUS_FAILED, e.message ?: "SmsManager rejected the request.")
        }
    }

    private fun resolveSmsManager(): SmsManager? = try {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            getSystemService(SmsManager::class.java)
        } else {
            @Suppress("DEPRECATION")
            SmsManager.getDefault()
        }
    } catch (e: Exception) {
        Log.e(TAG, "Unable to obtain SmsManager", e)
        null
    }

    private fun describeSentError(code: Int): String = when (code) {
        SmsManager.RESULT_ERROR_GENERIC_FAILURE -> "Generic radio failure."
        SmsManager.RESULT_ERROR_NO_SERVICE -> "No cellular service."
        SmsManager.RESULT_ERROR_NULL_PDU -> "Null PDU returned by the radio."
        SmsManager.RESULT_ERROR_RADIO_OFF -> "Radio is off (airplane mode?)."
        SmsManager.RESULT_ERROR_LIMIT_EXCEEDED -> "SMS sending limit exceeded."
        SmsManager.RESULT_ERROR_FDN_CHECK_FAILURE -> "Fixed dialing numbers check failed."
        else -> "SMS send failed (code $code)."
    }

    /* ---------------------------- Device info ----------------------------- */

    private fun simInfo(): Map<String, Any?> {
        val telephony = getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager
        val carrier = try {
            telephony?.networkOperatorName?.takeIf { it.isNotBlank() } ?: "Unknown carrier"
        } catch (_: SecurityException) {
            "Permission required"
        }
        val simState = try {
            when (telephony?.simState) {
                TelephonyManager.SIM_STATE_READY -> "ready"
                TelephonyManager.SIM_STATE_ABSENT -> "absent"
                TelephonyManager.SIM_STATE_PIN_REQUIRED -> "pin_required"
                TelephonyManager.SIM_STATE_PUK_REQUIRED -> "puk_required"
                else -> "unknown"
            }
        } catch (_: SecurityException) {
            "unknown"
        }
        return mapOf(
            "carrier" to carrier,
            "simState" to simState,
            "sdkInt" to Build.VERSION.SDK_INT,
        )
    }

    /* ------------------------ Battery optimisation ------------------------ */

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val power = getSystemService(Context.POWER_SERVICE) as? PowerManager ?: return false
        return power.isIgnoringBatteryOptimizations(packageName)
    }

    private fun requestIgnoreBatteryOptimizations(): Boolean {
        if (isIgnoringBatteryOptimizations()) return true
        return try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
            true
        } catch (e: Exception) {
            Log.w(TAG, "Battery optimisation intent unavailable", e)
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
                // Nothing else we can do; the UI keeps working.
            }
            false
        }
    }

    private fun hasPermission(permission: String): Boolean =
        checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED

    companion object {
        private const val TAG = "OpenSmsGateway"
        private const val CHANNEL = "opensms/gateway"
        private const val SENT_ACTION_PREFIX = "com.opensms.gateway.SMS_SENT"
        private const val DELIVERED_ACTION_PREFIX = "com.opensms.gateway.SMS_DELIVERED"
        private const val STATUS_SENT = "Sent"
        private const val STATUS_FAILED = "Failed"
        private const val SEND_TIMEOUT_MS = 90_000L
        private const val DEFAULT_NOTIFICATION = "Gateway running"
    }
}
