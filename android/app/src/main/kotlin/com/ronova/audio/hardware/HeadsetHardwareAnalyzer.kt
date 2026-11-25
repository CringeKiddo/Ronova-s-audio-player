package com.ronova.audio.hardware

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.content.pm.PackageManager
import android.media.AudioAttributes
import android.media.AudioDeviceCallback
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlin.coroutines.resume

/**
 * What Ronova Mode needs to know about the current output route.
 *
 * [deviceType]: 0 = built-in speaker, 1 = wired headset / USB-C DAC / USB dongle, 2 = Bluetooth.
 */
data class HeadsetInfo(
    val deviceType: Int,
    val deviceName: String,
    val transport: String,
    val maxSampleRate: Int,
    val sampleRateSource: String,
    val supportedSampleRates: List<Int>,
    val channelCount: Int,
    val channelCapability: String,
    val androidDeviceType: Int,
    val bluetoothPermissionGranted: Boolean,
) {
    fun toMap(): Map<String, Any?> = hashMapOf(
        "deviceType" to deviceType,
        "deviceName" to deviceName,
        "transport" to transport,
        "maxSampleRate" to maxSampleRate,
        "sampleRateSource" to sampleRateSource,
        "supportedSampleRates" to supportedSampleRates,
        "channelCount" to channelCount,
        "channelCapability" to channelCapability,
        "androidDeviceType" to androidDeviceType,
        "bluetoothPermissionGranted" to bluetoothPermissionGranted,
    )
}

class HeadsetHardwareAnalyzer(context: Context) {

    private val appContext = context.applicationContext
    private val audioManager = appContext.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private val monitorScope = CoroutineScope(SupervisorJob() + Dispatchers.Main.immediate)
    private val mediaAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    private var deviceCallback: AudioDeviceCallback? = null
    private var debounceJob: Job? = null

    // ---- Public API ----------------------------------------------------------------------------

    /** Full analysis, including the connected Bluetooth device name when permission allows it. */
    suspend fun analyze(): HeadsetInfo = withContext(Dispatchers.Default) {
        val device = pickActiveDevice()
        var bluetoothName: String? = null
        if (device != null && classify(device.type) == TYPE_BLUETOOTH) {
            bluetoothName = connectedA2dpDeviceName(device.productName?.toString())
        }
        buildInfo(device, bluetoothName)
    }

    /** Same as [analyze] without the Bluetooth profile lookup (safe on any thread, never waits). */
    fun analyzeBlocking(): HeadsetInfo = buildInfo(pickActiveDevice(), null)

    /** Calls [onChanged] (on the main thread, debounced) whenever the output route changes. */
    fun startMonitoring(onChanged: (HeadsetInfo) -> Unit) {
        stopMonitoring()
        val callback = object : AudioDeviceCallback() {
            override fun onAudioDevicesAdded(addedDevices: Array<out AudioDeviceInfo>?) = scheduleRefresh(onChanged)
            override fun onAudioDevicesRemoved(removedDevices: Array<out AudioDeviceInfo>?) = scheduleRefresh(onChanged)
        }
        deviceCallback = callback
        audioManager.registerAudioDeviceCallback(callback, Handler(Looper.getMainLooper()))
    }

    fun stopMonitoring() {
        debounceJob?.cancel()
        debounceJob = null
        deviceCallback?.let { audioManager.unregisterAudioDeviceCallback(it) }
        deviceCallback = null
    }

    fun hasBluetoothConnectPermission(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.S ||
            ContextCompat.checkSelfPermission(appContext, Manifest.permission.BLUETOOTH_CONNECT) ==
            PackageManager.PERMISSION_GRANTED

    // ---- Route selection -----------------------------------------------------------------------

    private fun scheduleRefresh(onChanged: (HeadsetInfo) -> Unit) {
        debounceJob?.cancel()
        debounceJob = monitorScope.launch {
            delay(ROUTE_SETTLE_MS)  // routing takes a moment to settle after plug / connect events
            onChanged(analyze())
        }
    }

    private fun pickActiveDevice(): AudioDeviceInfo? {
        // Android 13+ can tell us exactly which device media is routed to right now.
        val routed: List<AudioDeviceInfo> =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                try {
                    audioManager.getAudioDevicesForAttributes(mediaAttributes)
                } catch (_: Exception) {
                    emptyList()
                }
            } else {
                emptyList()
            }
        val pool = routed.filter { classify(it.type) >= 0 }.ifEmpty {
            audioManager.getDevices(AudioManager.GET_DEVICES_OUTPUTS)
                .filter { it.isSink && classify(it.type) >= 0 }
        }
        // Wired / USB beats Bluetooth beats the built-in speaker.
        return pool.maxByOrNull { priority(classify(it.type)) }
    }

    private fun classify(androidType: Int): Int = when (androidType) {
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> TYPE_SPEAKER

        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> TYPE_WIRED

        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER,
        AudioDeviceInfo.TYPE_HEARING_AID -> TYPE_BLUETOOTH

        else -> -1
    }

    private fun priority(deviceType: Int): Int = when (deviceType) {
        TYPE_WIRED -> 3
        TYPE_BLUETOOTH -> 2
        else -> 1
    }

    private fun transportName(androidType: Int): String = when (androidType) {
        AudioDeviceInfo.TYPE_USB_DEVICE,
        AudioDeviceInfo.TYPE_USB_HEADSET,
        AudioDeviceInfo.TYPE_USB_ACCESSORY -> "usb"

        AudioDeviceInfo.TYPE_WIRED_HEADSET,
        AudioDeviceInfo.TYPE_WIRED_HEADPHONES,
        AudioDeviceInfo.TYPE_LINE_ANALOG,
        AudioDeviceInfo.TYPE_LINE_DIGITAL -> "wired"

        AudioDeviceInfo.TYPE_BLUETOOTH_A2DP,
        AudioDeviceInfo.TYPE_HEARING_AID -> "bluetooth"

        AudioDeviceInfo.TYPE_BLE_HEADSET,
        AudioDeviceInfo.TYPE_BLE_SPEAKER -> "ble"

        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER,
        AudioDeviceInfo.TYPE_BUILTIN_SPEAKER_SAFE,
        AudioDeviceInfo.TYPE_BUILTIN_EARPIECE -> "speaker"

        else -> "other"
    }

    // ---- Info assembly -------------------------------------------------------------------------

    private fun buildInfo(device: AudioDeviceInfo?, bluetoothName: String?): HeadsetInfo {
        val permission = hasBluetoothConnectPermission()
        if (device == null) {
            return HeadsetInfo(
                deviceType = TYPE_SPEAKER,
                deviceName = "Phone speaker",
                transport = "speaker",
                maxSampleRate = systemOutputRate(),
                sampleRateSource = "system",
                supportedSampleRates = emptyList(),
                channelCount = 2,
                channelCapability = "stereo",
                androidDeviceType = AudioDeviceInfo.TYPE_UNKNOWN,
                bluetoothPermissionGranted = permission,
            )
        }

        val deviceType = classify(device.type)
        val transport = transportName(device.type)
        val reportedName = device.productName?.toString()?.trim().orEmpty()
        val name = when {
            deviceType == TYPE_SPEAKER -> "Phone speaker"
            !bluetoothName.isNullOrBlank() -> bluetoothName
            reportedName.isNotEmpty() -> reportedName
            deviceType == TYPE_BLUETOOTH -> "Bluetooth headset"
            transport == "usb" -> "USB audio device"
            else -> "Wired headphones"
        }

        val reportedRates = device.sampleRates.filter { it > 0 }.sorted()
        val maxRate: Int
        val source: String
        if (reportedRates.isNotEmpty()) {
            maxRate = reportedRates.last().coerceAtMost(MAX_REPORTED_RATE)
            source = "device"
        } else if (transport == "usb") {
            maxRate = DEFAULT_RATE  // USB descriptors were not exposed: be conservative
            source = "assumed"
        } else {
            maxRate = systemOutputRate()
            source = "system"
        }

        val maxChannels = device.channelCounts.maxOrNull()?.takeIf { it > 0 } ?: 2
        val capability = when {
            maxChannels <= 1 -> "mono"
            maxChannels == 2 -> "stereo"
            else -> "multichannel"
        }

        return HeadsetInfo(
            deviceType = deviceType,
            deviceName = name,
            transport = transport,
            maxSampleRate = maxRate,
            sampleRateSource = source,
            supportedSampleRates = reportedRates,
            channelCount = maxChannels,
            channelCapability = capability,
            androidDeviceType = device.type,
            bluetoothPermissionGranted = permission,
        )
    }

    private fun systemOutputRate(): Int =
        audioManager.getProperty(AudioManager.PROPERTY_OUTPUT_SAMPLE_RATE)?.toIntOrNull()
            ?.takeIf { it >= 44100 } ?: DEFAULT_RATE

    // ---- Bluetooth A2DP (requires BLUETOOTH_CONNECT on Android 12+) ----------------------------

    @SuppressLint("MissingPermission")
    private suspend fun connectedA2dpDeviceName(preferredName: String?): String? {
        if (!hasBluetoothConnectPermission()) return null
        val bluetoothAdapter = try {
            (appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
        } catch (_: Exception) {
            null
        }
        val adapter = bluetoothAdapter ?: return null

        val names: List<String> = withTimeoutOrNull(PROXY_TIMEOUT_MS) {
            suspendCancellableCoroutine<List<String>> { continuation ->
                val listener = object : BluetoothProfile.ServiceListener {
                    override fun onServiceConnected(profile: Int, proxy: BluetoothProfile) {
                        val found = try {
                            proxy.connectedDevices.mapNotNull { it.name?.trim()?.takeIf { n -> n.isNotEmpty() } }
                        } catch (_: SecurityException) {
                            emptyList()
                        }
                        try {
                            adapter.closeProfileProxy(profile, proxy)
                        } catch (_: Exception) {
                            // Proxy already gone.
                        }
                        if (continuation.isActive) continuation.resume(found)
                    }

                    override fun onServiceDisconnected(profile: Int) {
                        if (continuation.isActive) continuation.resume(emptyList())
                    }
                }
                val requested = try {
                    adapter.getProfileProxy(appContext, listener, BluetoothProfile.A2DP)
                } catch (_: SecurityException) {
                    false
                }
                if (!requested && continuation.isActive) continuation.resume(emptyList())
            }
        } ?: emptyList()

        if (names.isEmpty()) return null
        return names.firstOrNull { it.equals(preferredName, ignoreCase = true) } ?: names.first()
    }

    private companion object {
        const val TYPE_SPEAKER = 0
        const val TYPE_WIRED = 1
        const val TYPE_BLUETOOTH = 2
        const val DEFAULT_RATE = 48000
        const val MAX_REPORTED_RATE = 384000
        const val ROUTE_SETTLE_MS = 400L
        const val PROXY_TIMEOUT_MS = 900L
    }
}
