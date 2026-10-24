package ing.lalala.d110_studio

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothSocket
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.CancellationSignal
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.SystemClock
import android.provider.OpenableColumns
import android.util.AtomicFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileNotFoundException
import java.io.IOException
import java.io.InputStream
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import java.nio.charset.StandardCharsets
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** A single RFCOMM socket and serialized worker queue; no Bluetooth/file I/O on the UI thread. */
class PrinterBridge(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    companion object {
        private const val PERMISSION_REQUEST = 11031
        private const val IMAGE_REQUEST = 11032
        private const val ENABLE_REQUEST = 11033
        private const val IMAGE_LIMIT = 16 * 1024 * 1024
        private const val RESPONSE_LIMIT = 65536
        private const val WRITE_LIMIT = 1024 * 1024
        private const val STATE_LIMIT = 64 * 1024 * 1024
        private const val DISCOVERY_SECONDS = 12L
        private val SPP_UUID = UUID.fromString("00001101-0000-1000-8000-00805f9b34fb")
    }

    private val channel = MethodChannel(messenger, "d110_studio/device")
    private val main = Handler(Looper.getMainLooper())
    private val broadcasts = HandlerThread("d110-bluetooth-events").apply { start() }
    private val broadcastHandler = Handler(broadcasts.looper)
    private val worker = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "d110-device-io")
    }
    // Socket.close() aborts a blocked connect/write. It must not wait behind that operation.
    private val watchdog = Executors.newSingleThreadScheduledExecutor { runnable ->
        Thread(runnable, "d110-device-timeout")
    }
    private val replies = ConcurrentHashMap.newKeySet<Reply>()
    private val connectionLock = Any()
    @Volatile private var socket: BluetoothSocket? = null
    @Volatile private var destroyed = false
    private var aclReceiver: BroadcastReceiver? = null
    // Guarded by connectionLock so a connect cannot publish a socket after a power-off event.
    private var adapterPowerState: Int? = null
    // Only read and written by main-thread notification delivery.
    private var lastAdapterState: Map<String, Any?>? = null
    private val adapterReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent?.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
            val powerState = intent.getIntExtra(BluetoothAdapter.EXTRA_STATE, BluetoothAdapter.ERROR)
            if (powerState != BluetoothAdapter.STATE_ON &&
                powerState != BluetoothAdapter.STATE_OFF &&
                powerState != BluetoothAdapter.STATE_TURNING_ON &&
                powerState != BluetoothAdapter.STATE_TURNING_OFF) return
            val current = synchronized(connectionLock) {
                if (destroyed) return
                adapterPowerState = powerState
                socket
            }
            val state = adapterState(powerState)
            main.post {
                if (!destroyed && lastAdapterState != state) {
                    lastAdapterState = state
                    channel.invokeMethod("adapterChanged", state)
                }
            }
            if (powerState == BluetoothAdapter.STATE_OFF ||
                powerState == BluetoothAdapter.STATE_TURNING_OFF) {
                // This handler is independent of blocked connect/write work.
                // The identity check cannot close a replacement socket after power-on.
                if (current != null) closeConnection(current)
            }
        }
    }
    @Volatile private var documentCancellation: CancellationSignal? = null
    @Volatile private var documentInput: InputStream? = null
    private var pendingPermission: PermissionAction? = null
    private var pendingImage: Reply? = null
    private var pendingEnable: Reply? = null

    private class BridgeFailure(val code: String, message: String) : IOException(message)
    private data class PermissionAction(
        val permissions: Array<String>,
        val reply: Reply,
        val action: () -> Unit,
    )

    private inner class Reply(private val result: MethodChannel.Result) {
        private val completed = AtomicBoolean(false)

        init {
            replies.add(this)
        }

        fun success(value: Any?) {
            if (completed.compareAndSet(false, true)) {
                replies.remove(this)
                main.post { result.success(value) }
            }
        }

        fun error(code: String, message: String) {
            if (completed.compareAndSet(false, true)) {
                replies.remove(this)
                main.post { result.error(code, message, null) }
            }
        }

        fun notImplemented() {
            if (completed.compareAndSet(false, true)) {
                replies.remove(this)
                main.post { result.notImplemented() }
            }
        }
    }


    init {
        channel.setMethodCallHandler(this)
        // ACTION_STATE_CHANGED is protected by Android; registration is passive even
        // before Nearby Devices permission is granted and lasts for the whole bridge.
        registerReceiver(adapterReceiver, IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED))
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val reply = Reply(result)
        if (destroyed) {
            reply.error("disposed", "The device bridge has been closed")
            return
        }
        try {
            when (call.method) {
                "lastPrinterAddress" -> submit(reply) { loadLastPrinterAddress() }
                "saveLastPrinterAddress" -> {
                    val address = call.argument<String>("address")
                        ?: throw BridgeFailure("invalid_arguments", "Bluetooth address is required")
                    if (!BluetoothAdapter.checkBluetoothAddress(address)) {
                        throw BridgeFailure("invalid_address", "Invalid Bluetooth address")
                    }
                    submit(reply) {
                        saveText(lastPrinterFile(), address)
                        null
                    }
                }
                // Passive inspection must not bring up a permission dialog.
                "adapterState" -> submit(reply) { adapterState() }
                "requestEnableBluetooth" -> withBluetoothPermissions(false, reply) {
                    requestEnableBluetooth(reply)
                }
                "devices" -> withBluetoothPermissions(true, reply) {
                    submit(reply) { discoverDevices() }
                }
                "connect" -> {
                    val address = call.argument<String>("address")
                        ?: throw BridgeFailure("invalid_arguments", "Bluetooth address is required")
                    if (!BluetoothAdapter.checkBluetoothAddress(address)) {
                        throw BridgeFailure("invalid_address", "Invalid Bluetooth address")
                    }
                    withBluetoothPermissions(
                        false, reply,
                        requestPermission = call.argument<Boolean>("requestPermission") != false,
                    ) {
                        submit(reply, disconnectOnError = true) {
                            connect(address)
                            null
                        }
                    }
                }
                "disconnect" -> submit(reply) {
                    closeConnection()
                    null
                }
                "write" -> {
                    val bytes = commandBytes(call)
                    submit(reply, disconnectOnError = true) {
                        val current = connectedSocket()
                        withSocketDeadline(current, 15000) {
                            ensureNoPendingResponse(current)
                            current.outputStream.write(bytes)
                            current.outputStream.flush()
                        }
                        null
                    }
                }
                "exchange" -> {
                    val bytes = commandBytes(call)
                    val expected = call.argument<Int>("expectedLength")
                        ?: throw BridgeFailure("invalid_arguments", "expectedLength is required")
                    val timeout = call.argument<Int>("timeoutMs")
                        ?: throw BridgeFailure("invalid_arguments", "timeoutMs is required")
                    if (expected !in 0..RESPONSE_LIMIT || timeout !in 1..60000) {
                        throw BridgeFailure("invalid_arguments", "Invalid response length or timeout")
                    }
                    submit(reply, disconnectOnError = true) {
                        val current = connectedSocket()
                        withSocketDeadline(current, timeout.toLong()) {
                            ensureNoPendingResponse(current)
                            current.outputStream.write(bytes)
                            current.outputStream.flush()
                            readResponse(current, expected, timeout)
                        }
                    }
                }
                "pickImage" -> pickImage(reply)
                "readState" -> {
                    val file = stateFile(call.argument<String>("slot"))
                    submit(reply) { readState(file) }
                }
                "writeState" -> {
                    val file = stateFile(call.argument<String>("slot"))
                    val json = call.argument<String>("json")
                        ?: throw BridgeFailure("invalid_arguments", "State JSON is required")
                    submit(reply) {
                        if (json.toByteArray(StandardCharsets.UTF_8).size > STATE_LIMIT) {
                            throw BridgeFailure("storage_error", "State exceeds the 64 MiB limit")
                        }
                        saveText(file, json)
                        null
                    }
                }
                "loadTemplates" -> submit(reply) { loadTemplates() }
                "saveTemplates" -> {
                    val json = call.argument<String>("json")
                        ?: throw BridgeFailure("invalid_arguments", "Template JSON is required")
                    submit(reply) {
                        saveTemplates(json)
                        null
                    }
                }
                else -> reply.notImplemented()
            }
        } catch (failure: Exception) {
            reportFailure(reply, failure)
        }
    }

    private fun commandBytes(call: MethodCall): ByteArray {
        val bytes = call.argument<ByteArray>("bytes")
            ?: throw BridgeFailure("invalid_arguments", "bytes must be a Uint8List")
        if (bytes.isEmpty() || bytes.size > WRITE_LIMIT) {
            throw BridgeFailure("invalid_arguments", "Invalid Bluetooth command size")
        }
        return bytes
    }

    private fun submit(reply: Reply, disconnectOnError: Boolean = false, action: () -> Any?) {
        try {
            worker.execute {
                if (destroyed) {
                    reply.error("disposed", "The device bridge has been closed")
                    return@execute
                }
                try {
                    reply.success(action())
                } catch (failure: Exception) {
                    if (disconnectOnError) closeConnection()
                    reportFailure(reply, failure)
                }
            }
        } catch (_: RejectedExecutionException) {
            reply.error("disposed", "The device bridge has been closed")
        }
    }

    private fun reportFailure(reply: Reply, failure: Exception) {
        when (failure) {
            is BridgeFailure -> reply.error(failure.code, failure.message ?: "Device operation failed")
            is SecurityException -> reply.error("permission_denied", "Required device or document permission was denied")
            is InterruptedException -> reply.error("cancelled", "Device operation was cancelled")
            else -> reply.error("io_error", failure.message ?: "Device or storage I/O failed")
        }
    }

    private fun withBluetoothPermissions(
        discovery: Boolean,
        reply: Reply,
        requestPermission: Boolean = true,
        action: () -> Unit,
    ) {
        val required = when {
            Build.VERSION.SDK_INT >= 31 -> arrayOf(
                Manifest.permission.BLUETOOTH_CONNECT,
                // cancelDiscovery() before connect also requires SCAN on Android 12+.
                Manifest.permission.BLUETOOTH_SCAN,
            )
            discovery && Build.VERSION.SDK_INT >= 23 -> arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
            else -> emptyArray()
        }
        val missing = required.filter {
            activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }.toTypedArray()
        if (missing.isEmpty()) {
            action()
            return
        }
        if (!requestPermission) {
            reply.error("permission_denied", "Bluetooth permission is required")
            return
        }
        if (pendingPermission != null) {
            reply.error("busy", "A Bluetooth permission request is already in progress")
            return
        }
        pendingPermission = PermissionAction(missing, reply, action)
        try {
            activity.requestPermissions(missing, PERMISSION_REQUEST)
        } catch (failure: Exception) {
            pendingPermission = null
            reportFailure(reply, failure)
        }
    }

    fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        if (requestCode != PERMISSION_REQUEST) return
        val pending = pendingPermission ?: return
        pendingPermission = null
        val denied = permissions.isEmpty() || permissions.size != grantResults.size ||
            grantResults.any { it != PackageManager.PERMISSION_GRANTED } ||
            pending.permissions.any {
                activity.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
            }
        if (destroyed) {
            pending.reply.error("disposed", "The device bridge has been closed")
        } else if (denied) {
            pending.reply.error("permission_denied", "Allow Nearby Devices (or Location on Android 11 and earlier) to use Bluetooth")
        } else {
            try {
                pending.action()
            } catch (failure: Exception) {
                reportFailure(pending.reply, failure)
            }
        }
    }

    private fun adapterState(powerState: Int? = null): Map<String, Any?> {
        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
        val canReadAdapter = Build.VERSION.SDK_INT < 31 ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        val permitted = canReadAdapter && (Build.VERSION.SDK_INT < 31 ||
            activity.checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED)
        return mapOf(
            "available" to (adapter != null),
            "enabled" to if (adapter != null && canReadAdapter) {
                powerState?.let { it == BluetoothAdapter.STATE_ON } ?: adapter.isEnabled
            } else null,
            "permitted" to permitted,
        )
    }

    private fun requestEnableBluetooth(reply: Reply) {
        if (pendingEnable != null) {
            reply.error("busy", "A Bluetooth enable request is already open")
            return
        }
        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
            ?: throw BridgeFailure("bluetooth_unavailable", "This device has no Bluetooth adapter")
        if (adapter.isEnabled) {
            reply.success("enabled")
            return
        }
        pendingEnable = reply
        try {
            activity.startActivityForResult(Intent(BluetoothAdapter.ACTION_REQUEST_ENABLE), ENABLE_REQUEST)
        } catch (failure: Exception) {
            pendingEnable = null
            reportFailure(reply, failure)
        }
    }

    private fun enabledAdapter(): BluetoothAdapter {
        val manager = activity.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        val adapter = manager?.adapter
            ?: throw BridgeFailure("bluetooth_unavailable", "This device has no Bluetooth adapter")
        if (!adapter.isEnabled) {
            throw BridgeFailure("bluetooth_disabled", "Turn on Bluetooth in system settings")
        }
        return adapter
    }

    private fun registerReceiver(receiver: BroadcastReceiver, filter: IntentFilter) {
        if (Build.VERSION.SDK_INT >= 33) {
            // Bluetooth broadcasts may originate from the privileged Bluetooth app,
            // rather than the system UID, so NOT_EXPORTED would miss them.
            activity.registerReceiver(receiver, filter, null, broadcastHandler, Context.RECEIVER_EXPORTED)
        } else {
            activity.registerReceiver(receiver, filter, null, broadcastHandler)
        }
    }

    private fun bluetoothDevice(intent: Intent): BluetoothDevice? =
        if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
        }

    private fun discoverDevices(): List<Map<String, Any?>> {
        val adapter = enabledAdapter()
        val devices = linkedMapOf<String, Map<String, Any?>>()
        val finished = CountDownLatch(1)
        val discoveryFailure = AtomicReference<Exception?>()
        fun add(device: BluetoothDevice) {
            if (device.type != BluetoothDevice.DEVICE_TYPE_CLASSIC &&
                device.type != BluetoothDevice.DEVICE_TYPE_DUAL) return
            val address = device.address
            val name = device.name?.takeIf { it.isNotBlank() } ?: address
            val services = device.uuids
            val spp = services?.takeIf { it.isNotEmpty() }?.any { it.uuid == SPP_UUID }
            synchronized(devices) {
                devices[address] = mapOf(
                    "name" to name,
                    "address" to address,
                    "classic" to true,
                    "spp" to spp,
                )
            }
        }
        adapter.bondedDevices.forEach { add(it) }
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                when (intent?.action) {
                    BluetoothDevice.ACTION_FOUND -> {
                        try {
                            bluetoothDevice(intent)?.let { add(it) }
                        } catch (failure: SecurityException) {
                            discoveryFailure.set(failure)
                            finished.countDown()
                        }
                    }
                    BluetoothAdapter.ACTION_DISCOVERY_FINISHED -> finished.countDown()
                }
            }
        }
        val filter = IntentFilter(BluetoothDevice.ACTION_FOUND).apply {
            addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED)
        }
        registerReceiver(receiver, filter)
        var startedByUs = false
        try {
            if (!adapter.isDiscovering) {
                startedByUs = adapter.startDiscovery()
                if (!startedByUs) {
                    throw BridgeFailure("discovery_failed", "Bluetooth discovery could not start; check system Bluetooth and Location settings")
                }
            }
            finished.await(DISCOVERY_SECONDS, TimeUnit.SECONDS)
            if (destroyed) throw BridgeFailure("disposed", "The device bridge has been closed")
            discoveryFailure.get()?.let { throw it }
            return synchronized(devices) {
                devices.values.sortedWith(compareBy<Map<String, Any?>> { it["name"] as String }.thenBy { it["address"] as String })
            }
        } finally {
            try {
                if (startedByUs && adapter.isDiscovering) adapter.cancelDiscovery()
            } finally {
                activity.unregisterReceiver(receiver)
            }
        }
    }

    private fun connect(address: String) {
        val adapter = enabledAdapter()
        adapter.cancelDiscovery()
        closeConnection()
        val candidate = adapter.getRemoteDevice(address).createInsecureRfcommSocketToServiceRecord(SPP_UUID)
        synchronized(connectionLock) {
            if (destroyed) {
                candidate.close()
                throw BridgeFailure("disposed", "The device bridge has been closed")
            }
            if (adapterPowerState != null && adapterPowerState != BluetoothAdapter.STATE_ON) {
                candidate.close()
                throw BridgeFailure("bluetooth_disabled", "Turn on Bluetooth in system settings")
            }
            socket = candidate
        }
        withSocketDeadline(candidate, 10000) {
            candidate.connect()
            if (!candidate.isConnected) {
                throw BridgeFailure("connect_failed", "Bluetooth did not establish an RFCOMM connection")
            }
        }
        synchronized(connectionLock) {
            if (destroyed || socket !== candidate) {
                throw BridgeFailure("disconnected", "Bluetooth connection closed before registration")
            }
            val receiver = object : BroadcastReceiver() {
                override fun onReceive(context: Context?, intent: Intent?) {
                    if (intent?.action != BluetoothDevice.ACTION_ACL_DISCONNECTED) return
                    val device = bluetoothDevice(intent) ?: return
                    val disconnectedAddress = try {
                        device.address
                    } catch (_: SecurityException) {
                        return
                    }
                    if (disconnectedAddress != address) return
                    try {
                        watchdog.execute { closeConnection(candidate) }
                    } catch (_: RejectedExecutionException) {
                        // Lifecycle cleanup already owns this connection.
                    }
                }
            }
            registerReceiver(receiver, IntentFilter(BluetoothDevice.ACTION_ACL_DISCONNECTED))
            aclReceiver = receiver
        }
    }

    private fun connectedSocket(): BluetoothSocket {
        val current = socket
        if (current == null || !current.isConnected) {
            throw BridgeFailure("disconnected", "The printer is not connected")
        }
        return current
    }

    private fun ensureNoPendingResponse(current: BluetoothSocket) {
        if (current.inputStream.available() != 0) {
            throw BridgeFailure("protocol_error", "Unexpected unread printer data; reconnect before continuing")
        }
    }

    private fun <T> withSocketDeadline(current: BluetoothSocket, timeoutMs: Long, action: () -> T): T {
        val active = AtomicBoolean(true)
        val expired = AtomicBoolean(false)
        val timeout = watchdog.schedule({
            if (active.compareAndSet(true, false)) {
                expired.set(true)
                closeConnection(current)
            }
        }, timeoutMs, TimeUnit.MILLISECONDS)
        try {
            val value = action()
            if (!active.compareAndSet(true, false) || expired.get()) {
                throw BridgeFailure("timeout", "Printer operation timed out; it was not retried")
            }
            return value
        } catch (failure: Exception) {
            if (expired.get()) throw BridgeFailure("timeout", "Printer operation timed out; it was not retried")
            throw failure
        } finally {
            active.set(false)
            timeout.cancel(false)
        }
    }

    private fun readResponse(current: BluetoothSocket, expected: Int, timeoutMs: Int): ByteArray {
        val input = current.inputStream
        val deadline = SystemClock.elapsedRealtime() + timeoutMs
        val exact = if (expected > 0) ByteArray(expected) else null
        val variable = if (expected == 0) ByteArrayOutputStream(64) else null
        val fragment = if (expected == 0) ByteArray(1024) else null
        var received = 0
        var lastByteAt = 0L
        while (true) {
            if (destroyed || socket !== current || !current.isConnected) {
                throw BridgeFailure("disconnected", "Printer connection closed during an exchange")
            }
            val now = SystemClock.elapsedRealtime()
            val available = input.available()
            if (available > 0) {
                val count = if (exact != null) {
                    input.read(exact, received, minOf(available, expected - received))
                } else {
                    input.read(fragment!!, 0, minOf(available, fragment.size))
                }
                if (count <= 0) throw BridgeFailure("disconnected", "Printer closed its response stream")
                if (variable != null) variable.write(fragment!!, 0, count)
                received += count
                if (received > RESPONSE_LIMIT) {
                    throw BridgeFailure("protocol_error", "Printer response exceeded the size limit")
                }
                lastByteAt = SystemClock.elapsedRealtime()
                if (exact != null && received == expected) return exact
            } else if (expected == 0 && received > 0 && now - lastByteAt >= 100) {
                return variable!!.toByteArray()
            }
            if (now >= deadline) {
                throw BridgeFailure("timeout", "Incomplete printer response; reconnect before continuing")
            }
            Thread.sleep(5)
        }
    }

    private fun closeConnection(expected: BluetoothSocket? = null) {
        val current = synchronized(connectionLock) {
            val existing = socket
            if (expected != null && existing !== expected) return
            socket = null
            aclReceiver?.let { receiver ->
                try {
                    activity.unregisterReceiver(receiver)
                } catch (_: IllegalArgumentException) {
                    // Activity destruction may already have removed the receiver.
                }
            }
            aclReceiver = null
            existing
        } ?: return
        try {
            current.close()
        } catch (_: Exception) {
            // Local state is disconnected even if closing a failed socket reports an error.
        } finally {
            main.post {
                if (!destroyed) channel.invokeMethod("disconnected", null)
            }
        }
    }

    private fun pickImage(reply: Reply) {
        if (pendingImage != null) {
            reply.error("busy", "An image picker is already open")
            return
        }
        pendingImage = reply
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "image/*"
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            activity.startActivityForResult(intent, IMAGE_REQUEST)
        } catch (failure: Exception) {
            pendingImage = null
            reportFailure(reply, failure)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == ENABLE_REQUEST) {
            val reply = pendingEnable ?: return
            pendingEnable = null
            try {
                val state = adapterState()
                // RESULT_CANCELED remains declined even if some other app enabled it.
                reply.success(if (resultCode == Activity.RESULT_OK && state["enabled"] == true) "enabled" else "declined")
            } catch (failure: Exception) {
                reportFailure(reply, failure)
            }
            return
        }
        if (requestCode != IMAGE_REQUEST) return
        val reply = pendingImage ?: return
        pendingImage = null
        if (resultCode != Activity.RESULT_OK) {
            reply.success(null)
            return
        }
        val uri = data?.data
        if (uri == null) {
            reply.error("document_error", "The image picker returned no document")
            return
        }
        submit(reply) { readImage(uri, reply) }
    }

    private fun readImage(uri: Uri, reply: Reply): ByteArray {
        val cancellation = CancellationSignal()
        val active = AtomicBoolean(true)
        val expired = AtomicBoolean(false)
        synchronized(connectionLock) {
            if (destroyed) throw BridgeFailure("disposed", "The device bridge has been closed")
            documentCancellation = cancellation
        }
        val timeout = watchdog.schedule({
            if (active.compareAndSet(true, false)) {
                expired.set(true)
                reply.error("timeout", "Reading the selected image timed out")
                cancelDocumentRead()
            }
        }, 30, TimeUnit.SECONDS)
        try {
            val resolver = activity.contentResolver
            var announcedSize = -1L
            resolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null, cancellation)?.use { cursor ->
                val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (column >= 0 && cursor.moveToFirst() && !cursor.isNull(column)) {
                    announcedSize = cursor.getLong(column)
                }
            }
            if (announcedSize > IMAGE_LIMIT) {
                throw BridgeFailure("image_too_large", "Select an image no larger than 16 MiB")
            }
            val initialSize = if (announcedSize in 1..IMAGE_LIMIT.toLong()) announcedSize.toInt() else 65536
            val output = ByteArrayOutputStream(initialSize)
            val buffer = ByteArray(65536)
            val descriptor = resolver.openAssetFileDescriptor(uri, "r", cancellation)
                ?: throw BridgeFailure("document_error", "The selected image could not be opened")
            descriptor.use {
                val input = it.createInputStream()
                input.use {
                    synchronized(connectionLock) {
                        if (destroyed || !active.get()) {
                            throw BridgeFailure("cancelled", "Image import was cancelled")
                        }
                        documentInput = input
                    }
                    while (true) {
                        if (destroyed || !active.get() || Thread.currentThread().isInterrupted) {
                            throw BridgeFailure("cancelled", "Image import was cancelled")
                        }
                        val count = input.read(buffer)
                        if (count < 0) break
                        if (output.size() + count > IMAGE_LIMIT) {
                            throw BridgeFailure("image_too_large", "Select an image no larger than 16 MiB")
                        }
                        output.write(buffer, 0, count)
                    }
                }
            }
            if (output.size() == 0) throw BridgeFailure("document_error", "The selected image is empty")
            if (!active.compareAndSet(true, false) || expired.get()) {
                throw BridgeFailure("timeout", "Reading the selected image timed out")
            }
            return output.toByteArray()
        } finally {
            active.set(false)
            timeout.cancel(false)
            synchronized(connectionLock) {
                documentInput = null
                documentCancellation = null
            }
        }
    }

    private fun cancelDocumentRead() {
        var input: InputStream? = null
        var cancellation: CancellationSignal? = null
        synchronized(connectionLock) {
            input = documentInput
            cancellation = documentCancellation
            documentInput = null
            documentCancellation = null
        }
        try {
            input?.close()
        } catch (_: Exception) {
            // The worker also closes the stream when its cancelled read unwinds.
        }
        try {
            cancellation?.cancel()
        } catch (_: Exception) {
            // Cleanup must still release Bluetooth receivers and executors.
        }
    }

    private fun templateFile() = AtomicFile(File(activity.filesDir, "templates.json"))
    private fun lastPrinterFile() = AtomicFile(File(activity.filesDir, "last-printer-address"))

    private fun stateFile(slot: String?): AtomicFile {
        val filename = when (slot) {
            "lastPrinted" -> "last-printed.json"
            "workspace" -> "workspace.json"
            "mediaProfile" -> "media-profile.json"
            "mediaCalibration" -> "media-calibration.json"
            else -> throw BridgeFailure("invalid_arguments", "Unknown state slot")
        }
        return AtomicFile(File(activity.filesDir, filename))
    }

    private fun readState(file: AtomicFile): String? {
        val bytes = try {
            file.openRead().use { input ->
                val output = ByteArrayOutputStream()
                val buffer = ByteArray(8192)
                while (true) {
                    val count = input.read(buffer)
                    if (count < 0) break
                    if (output.size() + count > STATE_LIMIT) {
                        throw BridgeFailure("storage_error", "State exceeds the 64 MiB limit")
                    }
                    output.write(buffer, 0, count)
                }
                output.toByteArray()
            }
        } catch (failure: FileNotFoundException) {
            if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
            throw failure
        }
        return StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }

    private fun loadLastPrinterAddress(): String? {
        val file = lastPrinterFile()
        val address = try {
            file.openRead().use { String(it.readBytes(), StandardCharsets.US_ASCII).trim() }
        } catch (failure: FileNotFoundException) {
            if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return null
            throw failure
        }
        if (!BluetoothAdapter.checkBluetoothAddress(address)) {
            throw BridgeFailure("storage_error", "Saved printer address is invalid")
        }
        return address
    }

    private fun loadTemplates(): String {
        val file = templateFile()
        val bytes = try {
            file.openRead().use { it.readBytes() }
        } catch (failure: FileNotFoundException) {
            if (!file.baseFile.exists() && !File(file.baseFile.path + ".bak").exists()) return "[]"
            throw failure
        }
        return StandardCharsets.UTF_8.newDecoder()
            .onMalformedInput(CodingErrorAction.REPORT)
            .onUnmappableCharacter(CodingErrorAction.REPORT)
            .decode(ByteBuffer.wrap(bytes)).toString()
    }

    private fun saveTemplates(json: String) = saveText(templateFile(), json)

    private fun saveText(file: AtomicFile, text: String) {
        val output = file.startWrite()
        try {
            output.write(text.toByteArray(StandardCharsets.UTF_8))
            file.finishWrite(output)
        } catch (failure: Exception) {
            file.failWrite(output)
            throw failure
        }
    }

    fun close() {
        synchronized(connectionLock) {
            if (destroyed) return
            destroyed = true
            try {
                activity.unregisterReceiver(adapterReceiver)
            } catch (_: IllegalArgumentException) {
                // Activity destruction may already have removed the receiver.
            }
        }
        channel.setMethodCallHandler(null)
        pendingPermission = null
        pendingImage = null
        pendingEnable = null
        replies.toList().forEach { it.error("disposed", "The device bridge has been closed") }
        worker.shutdownNow()
        watchdog.execute {
            closeConnection()
            cancelDocumentRead()
        }
        broadcasts.quitSafely()
        watchdog.shutdown()
    }
}
