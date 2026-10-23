package com.example.geocam

import android.app.Activity
import android.content.Context
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CaptureRequest
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.view.Display
import android.view.WindowManager
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraControl
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.CaptureRequestOptions
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.Camera
import androidx.camera.core.CameraFilter
import androidx.camera.core.CameraInfo
import androidx.camera.core.CameraSelector
import androidx.camera.core.CameraState
import androidx.camera.core.DisplayOrientedMeteringPointFactory
import androidx.camera.core.FocusMeteringAction
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.lifecycle.LifecycleOwner
import com.google.common.util.concurrent.ListenableFuture
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executor
import java.util.concurrent.TimeUnit

/**
 * Camera controls that the Flutter `camera` plugin does not expose.
 *
 * The plugin (camera_android_camerax) owns the camera: it binds Preview, ImageCapture and
 * ImageAnalysis to this activity's lifecycle. This bridge never opens, binds or unbinds use cases.
 * It looks up the plugin's LifecycleCamera with `bindToLifecycle(activity, selector)` and NO use
 * cases, which CameraX answers by returning the existing camera for that (lifecycle owner, camera)
 * pair without changing its session. All CameraControl objects for one physical camera share the
 * same Camera2 control, so settings applied here act on the session the plugin is running.
 *
 * Nothing is cached: every call looks the camera up again, so a camera switch or re-initialisation
 * in Flutter can never leave this bridge holding a stale camera.
 */
@OptIn(ExperimentalCamera2Interop::class)
class CameraTuningBridge(private val activity: Activity, messenger: BinaryMessenger) :
    MethodChannel.MethodCallHandler {

    private val channel = MethodChannel(messenger, CHANNEL)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val mainExecutor = Executor { mainHandler.post(it) }

    init {
        channel.setMethodCallHandler(this)
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val cameraId = call.argument<String>("cameraId")
        if (cameraId.isNullOrEmpty()) {
            result.error("bad_args", "cameraId is required", null)
            return
        }
        try {
            when (call.method) {
                "capabilities" -> result.success(capabilities(cameraId))
                "probe" -> withLiveCamera(cameraId, result) { camera -> result.success(probe(cameraId, camera)) }
                "setExposureIndex" -> {
                    val index = call.argument<Int>("index") ?: return result.error("bad_args", "index is required", null)
                    withLiveCamera(cameraId, result) { camera -> setExposureIndex(camera, index, result) }
                }
                "focusAndMeter" -> withLiveCamera(cameraId, result) { camera -> focusAndMeter(cameraId, camera, call, result) }
                "cancelFocusAndMeter" -> withLiveCamera(cameraId, result) { camera ->
                    complete(camera.cameraControl.cancelFocusAndMetering(), result) { true }
                }
                "applyOverrides" -> withLiveCamera(cameraId, result) { camera -> applyOverrides(cameraId, camera, call, result) }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("camera_tuning_failed", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // ------------------------------------------------------------------ capability discovery

    private fun characteristics(cameraId: String): CameraCharacteristics {
        val manager = activity.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        return manager.getCameraCharacteristics(cameraId)
    }

    /** What the device reports for this camera. Reported support is not proof the control works. */
    private fun capabilities(cameraId: String): Map<String, Any?> {
        val c = characteristics(cameraId)
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val iso = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
        val exposure = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
        val aeComp = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val aeStep = c.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
        return mapOf(
            "hardwareLevel" to hardwareLevelName(c.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)),
            "manualSensor" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR),
            "readSensorSettings" to caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_READ_SENSOR_SETTINGS),
            "isoRange" to iso?.let { listOf(it.lower, it.upper) },
            "exposureTimeRangeNs" to exposure?.let { listOf(it.lower, it.upper) },
            "aeCompensationRange" to aeComp?.let { listOf(it.lower, it.upper) },
            "aeCompensationStep" to aeStep?.toDouble(),
            "aeLockAvailable" to (c.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) ?: false),
            "awbLockAvailable" to (c.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) ?: false),
            "aeModes" to (c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_MODES)?.toList() ?: emptyList<Int>()),
            "afModes" to (c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toList() ?: emptyList<Int>()),
            "awbModes" to (c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toList() ?: emptyList<Int>()),
            // Diopters; 0 means a fixed-focus lens. Calibration says whether the units are real dioptres.
            "minFocusDistance" to (c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE)?.toDouble() ?: 0.0),
            "focusCalibration" to c.get(CameraCharacteristics.LENS_INFO_FOCUS_DISTANCE_CALIBRATION),
            "maxRegionsAe" to (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0),
            "maxRegionsAf" to (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0),
            "maxRegionsAwb" to (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AWB) ?: 0),
            "sceneModes" to (c.get(CameraCharacteristics.CONTROL_AVAILABLE_SCENE_MODES)?.toList() ?: emptyList<Int>()),
            "faceDetectModes" to (c.get(CameraCharacteristics.STATISTICS_INFO_AVAILABLE_FACE_DETECT_MODES)?.toList() ?: emptyList<Int>()),
        )
    }

    private fun hardwareLevelName(level: Int?): String = when (level) {
        CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
        CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
        CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
        CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level3"
        CameraMetadata.INFO_SUPPORTED_HARDWARE_LEVEL_EXTERNAL -> "external"
        else -> "unknown"
    }

    // ------------------------------------------------------------------ live camera lookup

    /**
     * Finds the plugin's camera for [cameraId] and runs [block] with it on the main thread.
     * Fails (instead of guessing) when the camera is not open, e.g. before the plugin has
     * initialised it or while the app is in the background.
     */
    private fun withLiveCamera(cameraId: String, result: MethodChannel.Result, block: (Camera) -> Unit) {
        val owner = activity as? LifecycleOwner
        if (owner == null) {
            result.error("no_lifecycle_owner", "Activity is not a LifecycleOwner", null)
            return
        }
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            try {
                val provider = future.get()
                val selector = CameraSelector.Builder()
                    .addCameraFilter(CameraFilter { infos: List<CameraInfo> ->
                        infos.filter { Camera2CameraInfo.from(it).getCameraId() == cameraId }
                    })
                    .build()
                // No use cases: returns the existing LifecycleCamera; does not bind or rebind anything.
                val camera = provider.bindToLifecycle(owner, selector)
                val state = camera.cameraInfo.cameraState.value?.type
                if (state != CameraState.Type.OPEN) {
                    result.error("camera_not_open", "Camera $cameraId is not open (state: $state)", null)
                    return@addListener
                }
                block(camera)
            } catch (e: Exception) {
                result.error("camera_lookup_failed", e.message ?: e.javaClass.simpleName, null)
            }
        }, mainExecutor)
    }

    /** Proof-of-concept read-back: lets Dart check that this handle sees the plugin's live state. */
    private fun probe(cameraId: String, camera: Camera): Map<String, Any?> {
        val exposure = camera.cameraInfo.exposureState
        return mapOf(
            "cameraId" to Camera2CameraInfo.from(camera.cameraInfo).getCameraId(),
            "requestedCameraId" to cameraId,
            "cameraState" to camera.cameraInfo.cameraState.value?.type?.name,
            "exposureSupported" to exposure.isExposureCompensationSupported,
            "exposureIndex" to exposure.exposureCompensationIndex,
            "exposureRange" to listOf(exposure.exposureCompensationRange.lower, exposure.exposureCompensationRange.upper),
            "exposureStep" to exposure.exposureCompensationStep.toDouble(),
        )
    }

    // ------------------------------------------------------------------ exposure compensation

    private fun setExposureIndex(camera: Camera, requested: Int, result: MethodChannel.Result) {
        val exposure = camera.cameraInfo.exposureState
        if (!exposure.isExposureCompensationSupported) {
            result.error("unsupported", "Exposure compensation is not supported by this camera", null)
            return
        }
        val range = exposure.exposureCompensationRange
        val index = requested.coerceIn(range.lower, range.upper)
        complete(camera.cameraControl.setExposureCompensationIndex(index), result) { it }
    }

    // ------------------------------------------------------------------ focus / metering

    /**
     * Tap-to-focus/meter. x and y are 0..1 over the preview as displayed (the plugin's convention).
     * Returns whether the camera reported a successful autofocus; for metering-only requests that
     * flag is meaningless and Dart ignores it.
     */
    private fun focusAndMeter(cameraId: String, camera: Camera, call: MethodCall, result: MethodChannel.Result) {
        val x = (call.argument<Double>("x") ?: 0.5).toFloat().coerceIn(0f, 1f)
        val y = (call.argument<Double>("y") ?: 0.5).toFloat().coerceIn(0f, 1f)
        val size = (call.argument<Double>("size") ?: 0.15).toFloat().coerceIn(0.02f, 1f)
        val wantAf = call.argument<Boolean>("af") ?: true
        val wantAe = call.argument<Boolean>("ae") ?: true
        val wantAwb = call.argument<Boolean>("awb") ?: false
        val lock = call.argument<Boolean>("lock") ?: false

        val c = characteristics(cameraId)
        var flags = 0
        if (wantAf && (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0) flags = flags or FocusMeteringAction.FLAG_AF
        if (wantAe && (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0) flags = flags or FocusMeteringAction.FLAG_AE
        if (wantAwb && (c.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AWB) ?: 0) > 0) flags = flags or FocusMeteringAction.FLAG_AWB
        if (flags == 0) {
            result.error("unsupported", "This camera does not support focus or metering regions", null)
            return
        }

        val factory = DisplayOrientedMeteringPointFactory(display(), camera.cameraInfo, 1f, 1f)
        val point = factory.createPoint(x, y, size)
        val builder = FocusMeteringAction.Builder(point, flags)
        if (lock) builder.disableAutoCancel() else builder.setAutoCancelDuration(AUTO_CANCEL_SECONDS, TimeUnit.SECONDS)
        val action = builder.build()
        val future = camera.cameraControl.startFocusAndMetering(action)
        future.addListener({
            try {
                val r = future.get()
                result.success(mapOf("focusSuccessful" to r.isFocusSuccessful, "af" to (flags and FocusMeteringAction.FLAG_AF != 0),
                    "ae" to (flags and FocusMeteringAction.FLAG_AE != 0)))
            } catch (e: Exception) {
                // Cancelled by a newer tap, or the camera closed: not an app error.
                result.success(mapOf("focusSuccessful" to false, "cancelled" to true, "reason" to (e.cause?.message ?: e.message)))
            }
        }, mainExecutor)
    }

    @Suppress("DEPRECATION")
    private fun display(): Display =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) activity.display!!
        else (activity.getSystemService(Context.WINDOW_SERVICE) as WindowManager).defaultDisplay

    // ------------------------------------------------------------------ Camera2 overrides

    /**
     * Applies the full set of manual overrides, replacing any previous ones. An empty set returns
     * the camera to CameraX's automatic behaviour. Values are validated against the camera's
     * reported ranges here as well as in Dart.
     */
    private fun applyOverrides(cameraId: String, camera: Camera, call: MethodCall, result: MethodChannel.Result) {
        val c = characteristics(cameraId)
        val caps = c.get(CameraCharacteristics.REQUEST_AVAILABLE_CAPABILITIES)?.toList() ?: emptyList()
        val builder = CaptureRequestOptions.Builder()
        var any = false

        val iso = call.argument<Int>("iso")
        val exposureNs = call.argument<Number>("exposureNs")?.toLong()
        if (iso != null || exposureNs != null) {
            if (!caps.contains(CameraMetadata.REQUEST_AVAILABLE_CAPABILITIES_MANUAL_SENSOR) || iso == null || exposureNs == null) {
                return result.error("unsupported", "Manual ISO/shutter is not supported by this camera", null)
            }
            val isoRange = c.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)
                ?: return result.error("unsupported", "No ISO range reported", null)
            val expRange = c.get(CameraCharacteristics.SENSOR_INFO_EXPOSURE_TIME_RANGE)
                ?: return result.error("unsupported", "No exposure time range reported", null)
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AE_MODE, CameraMetadata.CONTROL_AE_MODE_OFF)
            builder.setCaptureRequestOption(CaptureRequest.SENSOR_SENSITIVITY, iso.coerceIn(isoRange.lower, isoRange.upper))
            builder.setCaptureRequestOption(CaptureRequest.SENSOR_EXPOSURE_TIME, exposureNs.coerceIn(expRange.lower, expRange.upper))
            any = true
        } else if (call.argument<Boolean>("aeLock") == true) {
            if (c.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) != true) {
                return result.error("unsupported", "Exposure lock is not supported by this camera", null)
            }
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AE_LOCK, true)
            any = true
        }

        val diopters = call.argument<Double>("focusDiopters")
        if (diopters != null) {
            val minFocus = c.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0f
            val afModes = c.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)?.toList() ?: emptyList()
            if (minFocus <= 0f || !afModes.contains(CameraMetadata.CONTROL_AF_MODE_OFF)) {
                return result.error("unsupported", "Manual focus is not supported by this camera", null)
            }
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AF_MODE, CameraMetadata.CONTROL_AF_MODE_OFF)
            builder.setCaptureRequestOption(CaptureRequest.LENS_FOCUS_DISTANCE, diopters.toFloat().coerceIn(0f, minFocus))
            any = true
        }

        val awbMode = call.argument<Int>("awbMode")
        if (awbMode != null && awbMode != CameraMetadata.CONTROL_AWB_MODE_AUTO) {
            val awbModes = c.get(CameraCharacteristics.CONTROL_AWB_AVAILABLE_MODES)?.toList() ?: emptyList()
            if (!awbModes.contains(awbMode) || awbMode == CameraMetadata.CONTROL_AWB_MODE_OFF) {
                return result.error("unsupported", "White balance mode $awbMode is not supported by this camera", null)
            }
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_MODE, awbMode)
            any = true
        }
        if (call.argument<Boolean>("awbLock") == true) {
            if (c.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) != true) {
                return result.error("unsupported", "White balance lock is not supported by this camera", null)
            }
            builder.setCaptureRequestOption(CaptureRequest.CONTROL_AWB_LOCK, true)
            any = true
        }

        val control = Camera2CameraControl.from(camera.cameraControl)
        val future = if (any) control.setCaptureRequestOptions(builder.build()) else control.clearCaptureRequestOptions()
        complete(future, result) { true }
    }

    // ------------------------------------------------------------------ helpers

    private fun <T> complete(future: ListenableFuture<T>, result: MethodChannel.Result, map: (T) -> Any?) {
        future.addListener({
            try {
                result.success(map(future.get()))
            } catch (e: Exception) {
                result.error("camera_operation_failed", e.cause?.message ?: e.message ?: e.javaClass.simpleName, null)
            }
        }, mainExecutor)
    }

    companion object {
        const val CHANNEL = "geocam/camera_tuning"
        private const val AUTO_CANCEL_SECONDS = 5L
    }
}
