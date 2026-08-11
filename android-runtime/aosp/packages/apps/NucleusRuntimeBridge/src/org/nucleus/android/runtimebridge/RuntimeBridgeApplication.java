package org.nucleus.android.runtimebridge;

import android.app.ActivityManager;
import android.app.ActivityOptions;
import android.app.ActivityTaskManager;
import android.app.Application;
import android.app.TaskStackListener;
import android.content.BroadcastReceiver;
import android.content.ClipData;
import android.content.ClipboardManager;
import android.content.ComponentName;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.LauncherActivityInfo;
import android.content.pm.LauncherApps;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.PointF;
import android.graphics.drawable.Drawable;
import android.hardware.display.DisplayManager;
import android.hardware.display.IDisplayManager;
import android.hardware.input.IPointerIconChangedListener;
import android.hardware.input.InputManager;
import android.hardware.input.VirtualKeyEvent;
import android.hardware.input.VirtualKeyboard;
import android.hardware.input.VirtualKeyboardConfig;
import android.hardware.input.VirtualMouse;
import android.hardware.input.VirtualMouseButtonEvent;
import android.hardware.input.VirtualMouseConfig;
import android.hardware.input.VirtualMouseRelativeEvent;
import android.hardware.input.VirtualMouseScrollEvent;
import android.hardware.input.VirtualTouchEvent;
import android.hardware.input.VirtualTouchscreen;
import android.hardware.input.VirtualTouchscreenConfig;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Process;
import android.os.RemoteException;
import android.os.ServiceManager;
import android.os.SystemClock;
import android.os.UserHandle;
import android.os.UserManager;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.util.Log;
import android.view.Display;
import android.view.KeyEvent;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class RuntimeBridgeApplication extends Application {
    private static final String TAG = "NucleusRuntimeBridge";
    private static final String SOCKET_PATH =
            "/dev/nucleus-runtime/broker.sock";
    private static final int MAXIMUM_PACKET_BYTES = 256 * 1024;
    private static final AtomicBoolean STARTED = new AtomicBoolean();

    private static final class ClipboardSnapshot {
        final long generation;
        final String text;

        ClipboardSnapshot(long generation, String text) {
            this.generation = generation;
            this.text = text;
        }
    }

    private static final class PendingLaunch {
        final String requestId;
        final long requestedPresentationId;
        final int displayId;
        final ComponentName component;
        final long minimumLastActiveTime;
        final long deadlineMillis;

        PendingLaunch(
                String requestId,
                long requestedPresentationId,
                int displayId,
                ComponentName component) {
            this.requestId = requestId;
            this.requestedPresentationId = requestedPresentationId;
            this.displayId = displayId;
            this.component = component;
            minimumLastActiveTime = 0;
            deadlineMillis = SystemClock.elapsedRealtime() + 20_000;
        }

        PendingLaunch(
                String requestId,
                long requestedPresentationId,
                int displayId,
                long minimumLastActiveTime) {
            this.requestId = requestId;
            this.requestedPresentationId = requestedPresentationId;
            this.displayId = displayId;
            component = null;
            this.minimumLastActiveTime = minimumLastActiveTime;
            deadlineMillis = SystemClock.elapsedRealtime() + 20_000;
        }
    }

    private final class PresentationInputDevices implements AutoCloseable {
        final long presentationId;
        final int displayId;
        final long configurationGeneration;
        final VirtualMouse mouse;
        final VirtualKeyboard keyboard;
        final VirtualTouchscreen touchscreen;
        final Set<Integer> pressedButtons = new HashSet<>();
        final Set<Integer> pressedKeys = new HashSet<>();
        final Map<Integer, PointF> touches = new HashMap<>();
        boolean pointerPresent;
        float pointerX;
        float pointerY;

        PresentationInputDevices(
                long presentationId,
                int displayId,
                long configurationGeneration) {
            this.presentationId = presentationId;
            this.displayId = displayId;
            this.configurationGeneration = configurationGeneration;
            InputManager input = getSystemService(InputManager.class);
            Display display = getSystemService(DisplayManager.class).getDisplay(displayId);
            if (display == null) {
                throw new IllegalStateException(
                        "Android presentation display is unavailable");
            }
            Display.Mode mode = display.getMode();
            VirtualTouchscreenConfig touchConfig =
                    new VirtualTouchscreenConfig.Builder(
                            mode.getPhysicalWidth(), mode.getPhysicalHeight())
                            .setVendorId(0x18d1)
                            .setProductId(0x4e57)
                            .setInputDeviceName("Nucleus touchscreen " + presentationId)
                            .setAssociatedDisplayId(displayId)
                            .build();
            VirtualMouse createdMouse = input.createVirtualMouse(
                    new VirtualMouseConfig.Builder()
                            .setVendorId(0x18d1)
                            .setProductId(0x4e55)
                            .setInputDeviceName("Nucleus mouse " + presentationId)
                            .setAssociatedDisplayId(displayId)
                            .build());
            VirtualKeyboard createdKeyboard = null;
            VirtualTouchscreen createdTouchscreen = null;
            try {
                createdKeyboard = input.createVirtualKeyboard(
                        new VirtualKeyboardConfig.Builder()
                                .setVendorId(0x18d1)
                                .setProductId(0x4e56)
                                .setInputDeviceName("Nucleus keyboard " + presentationId)
                                .setAssociatedDisplayId(displayId)
                                .build());
                createdTouchscreen = input.createVirtualTouchscreen(touchConfig);
                input.setPointerIconVisible(false, displayId);
            } catch (RuntimeException error) {
                try {
                    createdMouse.close();
                } catch (RuntimeException closeError) {
                    error.addSuppressed(closeError);
                }
                if (createdKeyboard != null) {
                    try {
                        createdKeyboard.close();
                    } catch (RuntimeException closeError) {
                        error.addSuppressed(closeError);
                    }
                }
                if (createdTouchscreen != null) {
                    try {
                        createdTouchscreen.close();
                    } catch (RuntimeException closeError) {
                        error.addSuppressed(closeError);
                    }
                }
                try {
                    input.setPointerIconVisible(true, displayId);
                } catch (RuntimeException restoreError) {
                    error.addSuppressed(restoreError);
                }
                throw error;
            }
            mouse = createdMouse;
            keyboard = createdKeyboard;
            touchscreen = createdTouchscreen;
        }

        void alignPointer(float x, float y, long eventTimeNanos) {
            if (!pointerPresent) {
                PointF current = mouse.getCursorPosition();
                pointerX = Float.isFinite(current.x) ? current.x : x;
                pointerY = Float.isFinite(current.y) ? current.y : y;
                pointerPresent = true;
            }
            float deltaX = x - pointerX;
            float deltaY = y - pointerY;
            if (deltaX != 0 || deltaY != 0) {
                mouse.sendRelativeEvent(
                        new VirtualMouseRelativeEvent.Builder()
                                .setRelativeX(deltaX)
                                .setRelativeY(deltaY)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
            }
            pointerX = x;
            pointerY = y;
        }

        void releasePointer(long eventTimeNanos) {
            for (int button : new ArrayList<>(pressedButtons)) {
                mouse.sendButtonEvent(
                        new VirtualMouseButtonEvent.Builder()
                                .setButtonCode(button)
                                .setAction(VirtualMouseButtonEvent.ACTION_BUTTON_RELEASE)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
            }
            pressedButtons.clear();
            pointerPresent = false;
        }

        void releaseKeyboard(long eventTimeNanos) {
            for (int keyCode : new ArrayList<>(pressedKeys)) {
                keyboard.sendKeyEvent(
                        new VirtualKeyEvent.Builder()
                                .setKeyCode(keyCode)
                                .setAction(VirtualKeyEvent.ACTION_UP)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
            }
            pressedKeys.clear();
        }

        void cancelTouches(long eventTimeNanos) {
            for (Map.Entry<Integer, PointF> entry
                    : new ArrayList<>(touches.entrySet())) {
                PointF point = entry.getValue();
                touchscreen.sendTouchEvent(
                        new VirtualTouchEvent.Builder()
                                .setPointerId(entry.getKey())
                                .setToolType(VirtualTouchEvent.TOOL_TYPE_PALM)
                                .setAction(VirtualTouchEvent.ACTION_CANCEL)
                                .setX(point.x)
                                .setY(point.y)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
            }
            touches.clear();
        }

        void cancel(long eventTimeNanos) {
            releasePointer(eventTimeNanos);
            releaseKeyboard(eventTimeNanos);
            cancelTouches(eventTimeNanos);
        }

        @Override
        public void close() {
            closeDevices(true);
        }

        void retireForConfiguration() {
            closeDevices(false);
        }

        private void closeDevices(boolean restorePointerIcon) {
            RuntimeException failure = null;
            try {
                cancel(SystemClock.uptimeNanos());
            } catch (RuntimeException error) {
                failure = error;
            }
            try {
                mouse.close();
            } catch (RuntimeException error) {
                failure = error;
            }
            try {
                keyboard.close();
            } catch (RuntimeException error) {
                if (failure == null) {
                    failure = error;
                } else {
                    failure.addSuppressed(error);
                }
            }
            try {
                touchscreen.close();
            } catch (RuntimeException error) {
                if (failure == null) {
                    failure = error;
                } else {
                    failure.addSuppressed(error);
                }
            }
            if (restorePointerIcon) {
                try {
                    getSystemService(InputManager.class)
                            .setPointerIconVisible(true, displayId);
                } catch (RuntimeException error) {
                    if (failure == null) {
                        failure = error;
                    } else {
                        failure.addSuppressed(error);
                    }
                }
            }
            if (failure != null) {
                Log.w(TAG, "closing Android virtual input failed", failure);
            }
        }
    }

    private final Set<String> dirtyPackages =
            ConcurrentHashMap.newKeySet();
    private final Set<Long> activePresentations =
            ConcurrentHashMap.newKeySet();
    private final Map<Integer, Long> presentationByDisplayId =
            new HashMap<>();
    private final Map<Long, Integer> displayByPresentationId =
            new HashMap<>();
    private final Map<Integer, Long> presentationByTaskId =
            new HashMap<>();
    private final Map<Long, Set<Integer>> taskIdsByPresentation =
            new HashMap<>();
    private final Map<String, PendingLaunch> pendingLaunches =
            new HashMap<>();
    private final Map<Integer, String> publishedTasks =
            new HashMap<>();
    private final ConcurrentLinkedQueue<Integer> removedTaskIds =
            new ConcurrentLinkedQueue<>();
    private final AtomicBoolean taskStateDirty = new AtomicBoolean();
    private final AtomicLong clipboardGeneration = new AtomicLong();
    private final AtomicReference<ClipboardSnapshot> pendingClipboard =
            new AtomicReference<>();
    private final Object clipboardLock = new Object();
    private long lastShellClipboardGeneration;
    private boolean awaitingShellClipboardCallback;
    private String expectedShellClipboardText;
    private final Map<Long, PresentationInputDevices> inputDevicesByPresentation =
            new HashMap<>();
    private final ConcurrentHashMap<Integer, Integer> pendingPointerIcons =
            new ConcurrentHashMap<>();
    private final IPointerIconChangedListener pointerIconChangedListener =
            new IPointerIconChangedListener.Stub() {
                @Override
                public void onPointerIconChanged(
                        int displayId, int pointerIconType) {
                    pendingPointerIcons.put(displayId, pointerIconType);
                }
            };
    private final TaskStackListener taskStackListener =
            new TaskStackListener() {
                @Override
                public void onTaskStackChanged() {
                    taskStateDirty.set(true);
                }

                @Override
                public void onTaskCreated(int taskId, ComponentName componentName) {
                    taskStateDirty.set(true);
                }

                @Override
                public void onTaskMovedToFront(ActivityManager.RunningTaskInfo taskInfo) {
                    taskStateDirty.set(true);
                }

                @Override
                public void onTaskDisplayChanged(int taskId, int newDisplayId) {
                    taskStateDirty.set(true);
                }

                @Override
                public void onTaskRemoved(int taskId) {
                    removedTaskIds.add(taskId);
                    taskStateDirty.set(true);
                }
            };

    private final ClipboardManager.OnPrimaryClipChangedListener
            clipboardChangedListener = this::primaryClipboardChanged;

    @Override
    public void onCreate() {
        super.onCreate();
        presentationByDisplayId.put(Display.DEFAULT_DISPLAY, 0L);
        displayByPresentationId.put(0L, Display.DEFAULT_DISPLAY);
        start(this);
    }

    static void ensureStarted(Context context) {
        Context application = context.getApplicationContext();
        if (application instanceof RuntimeBridgeApplication) {
            ((RuntimeBridgeApplication) application).start(application);
        }
    }

    private void start(Context context) {
        if (!STARTED.compareAndSet(false, true)) {
            return;
        }
        getSystemService(InputManager.class)
                .registerPointerIconChangedListener(
                        pointerIconChangedListener);
        ActivityTaskManager.getInstance()
                .registerTaskStackListener(taskStackListener);
        getSystemService(ClipboardManager.class)
                .addPrimaryClipChangedListener(clipboardChangedListener);
        IntentFilter packages = new IntentFilter();
        packages.addAction(Intent.ACTION_PACKAGE_ADDED);
        packages.addAction(Intent.ACTION_PACKAGE_CHANGED);
        packages.addAction(Intent.ACTION_PACKAGE_REMOVED);
        packages.addAction(Intent.ACTION_PACKAGE_REPLACED);
        packages.addDataScheme("package");
        registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context ignored, Intent intent) {
                String packageName = intent.getData() == null
                        ? null : intent.getData().getSchemeSpecificPart();
                if (packageName != null && !packageName.isEmpty()) {
                    dirtyPackages.add(packageName);
                }
            }
        }, packages, Context.RECEIVER_NOT_EXPORTED);
        IntentFilter suspension = new IntentFilter();
        suspension.addAction(Intent.ACTION_PACKAGES_SUSPENDED);
        suspension.addAction(Intent.ACTION_PACKAGES_UNSUSPENDED);
        registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context ignored, Intent intent) {
                String[] packageNames = intent.getStringArrayExtra(
                        Intent.EXTRA_CHANGED_PACKAGE_LIST);
                if (packageNames == null) {
                    return;
                }
                for (String packageName : packageNames) {
                    if (packageName != null && !packageName.isEmpty()) {
                        dirtyPackages.add(packageName);
                    }
                }
            }
        }, suspension, Context.RECEIVER_NOT_EXPORTED);
        Thread thread = new Thread(this::connectionLoop,
                "nucleus-runtime-bridge");
        thread.setDaemon(true);
        thread.start();
    }

    private void connectionLoop() {
        while (true) {
            closeApplicationPresentations();
            try (LocalSocket socket =
                         new LocalSocket(LocalSocket.SOCKET_SEQPACKET)) {
                socket.connect(new LocalSocketAddress(
                        SOCKET_PATH,
                        LocalSocketAddress.Namespace.FILESYSTEM));
                serve(socket);
            } catch (ErrnoException | IOException | JSONException
                    | RuntimeException error) {
                Log.w(TAG, "bridge connection failed", error);
            } finally {
                closeInputDevices();
                pendingLaunches.clear();
                closeApplicationPresentations();
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    private void closeInputDevices() {
        for (PresentationInputDevices devices
                : new ArrayList<>(inputDevicesByPresentation.values())) {
            try {
                devices.close();
            } catch (RuntimeException error) {
                Log.w(TAG, "closing Android virtual input failed", error);
            }
        }
        inputDevicesByPresentation.clear();
    }

    private void serve(LocalSocket socket)
            throws IOException, JSONException, ErrnoException {
        InputStream input = socket.getInputStream();
        OutputStream output = socket.getOutputStream();
        send(output, new JSONObject().put("kind", "bridgeHello"));
        JSONObject hello = receive(input);
        if (!"brokerHello".equals(hello.getString("kind"))) {
            throw new IOException("broker rejected bridge protocol");
        }
        String generation = hello.getString("generation");
        boolean inputAvailable = true;
        try {
            prepareInputDisplay(0);
            sendInputState(output, generation, true, null);
        } catch (RuntimeException error) {
            String description = describeFailure(error);
            Log.e(TAG, "native virtual input initialization failed: "
                    + description, error);
            sendInputState(output, generation, false, description);
            inputAvailable = false;
        }
        UserManager users = getSystemService(UserManager.class);
        long serial = users.getSerialNumberForUser(Process.myUserHandle());
        boolean unlocked = users.isUserUnlocked();
        sendRuntimeState(output, generation, unlocked, serial);
        boolean catalogPublished = false;
        if (unlocked) {
            sendActivitySnapshot(output, generation, serial);
            catalogPublished = true;
        }
        if (unlocked) {
            queueClipboardSnapshot();
        } else {
            queueClipboard(null);
        }
        long notificationRevision = -1;
        if (unlocked) {
            notificationRevision = sendNotificationSnapshot(
                    output, generation, serial);
        }

        StructPollfd descriptor = new StructPollfd();
        descriptor.fd = socket.getFileDescriptor();
        descriptor.events = (short) (OsConstants.POLLIN
                | OsConstants.POLLERR | OsConstants.POLLHUP);
        while (true) {
            descriptor.revents = 0;
            Os.poll(new StructPollfd[]{descriptor}, 250);
            if ((descriptor.revents
                    & (OsConstants.POLLERR | OsConstants.POLLHUP)) != 0) {
                throw new IOException("broker disconnected");
            }
            if ((descriptor.revents & OsConstants.POLLIN) != 0) {
                JSONObject command = receive(input);
                if (!generation.equals(
                                command.getString("generation"))) {
                    throw new IOException("invalid broker command");
                }
                String kind = command.getString("kind");
                try {
                    switch (kind) {
                    case "inputEvent":
                        if (!inputAvailable) {
                            break;
                        }
                        sendInputEvent(command.getJSONObject("inputEvent"));
                        break;
                    case "launchActivity":
                        beginActivityLaunch(
                                output,
                                generation,
                                command.getJSONObject("activityLaunch"));
                        break;
                    case "closePresentation":
                        closePresentationFromHost(
                                output,
                                generation,
                                command.getJSONObject("presentationClose")
                                        .getLong("presentationID"));
                        break;
                    case "setClipboard":
                        applyClipboardUpdate(
                                command.getJSONObject("clipboardUpdate"));
                        break;
                    case "dismissNotification":
                        dismissNotification(
                                command.getJSONObject("notificationCommand"));
                        break;
                    case "activateNotification":
                        activateNotification(
                                output,
                                generation,
                                command.getJSONObject("notificationCommand"));
                        break;
                    default:
                        throw new IOException(
                                "unsupported broker command " + kind);
                    }
                } catch (IOException | JSONException
                        | RuntimeException error) {
                    Log.w(TAG, "Android runtime command failed: " + kind,
                            error);
                }
            }
            boolean currentlyUnlocked = users.isUserUnlocked();
            if (currentlyUnlocked != catalogPublished) {
                if (currentlyUnlocked && !catalogPublished) {
                    sendRuntimeState(output, generation, true, serial);
                    sendActivitySnapshot(output, generation, serial);
                    catalogPublished = true;
                    dirtyPackages.clear();
                    queueClipboardSnapshot();
                    notificationRevision = sendNotificationSnapshot(
                            output, generation, serial);
                } else if (!currentlyUnlocked && catalogPublished) {
                    sendRuntimeState(output, generation, false, serial);
                    catalogPublished = false;
                    dirtyPackages.clear();
                    queueClipboard(null);
                }
            }
            if (catalogPublished) {
                for (String packageName : new ArrayList<>(dirtyPackages)) {
                    if (dirtyPackages.remove(packageName)) {
                        sendPackageActivitySnapshot(
                                output, generation, serial, packageName);
                    }
                }
            }
            sendTaskUpdates(output, generation);
            sendPendingPointerIcons(output, generation);
            sendPendingClipboard(output, generation);
            long currentNotificationRevision =
                    NucleusNotificationListenerService.revision();
            if (catalogPublished
                    && currentNotificationRevision != notificationRevision) {
                notificationRevision = sendNotificationSnapshot(
                        output, generation, serial);
            }
        }
    }

    private void primaryClipboardChanged() {
        if (!getSystemService(UserManager.class).isUserUnlocked()) {
            queueClipboard(null);
            return;
        }
        String text = readPlainTextClipboard();
        synchronized (clipboardLock) {
            if (awaitingShellClipboardCallback
                    && Objects.equals(expectedShellClipboardText, text)) {
                awaitingShellClipboardCallback = false;
                expectedShellClipboardText = null;
                return;
            }
            awaitingShellClipboardCallback = false;
            expectedShellClipboardText = null;
        }
        queueClipboard(text);
    }

    private void queueClipboardSnapshot() {
        queueClipboard(readPlainTextClipboard());
    }

    private void queueClipboard(String text) {
        if (text != null
                && text.getBytes(StandardCharsets.UTF_8).length > 128 * 1024) {
            text = null;
        }
        long generation = clipboardGeneration.incrementAndGet();
        if (generation <= 0) {
            throw new IllegalStateException(
                    "Android clipboard generation exhausted");
        }
        pendingClipboard.set(new ClipboardSnapshot(generation, text));
    }

    private String readPlainTextClipboard() {
        ClipboardManager clipboard = getSystemService(ClipboardManager.class);
        ClipData clip = clipboard.getPrimaryClip();
        if (clip == null || clip.getItemCount() == 0) {
            return null;
        }
        CharSequence text = clip.getItemAt(0).getText();
        return text == null ? null : text.toString();
    }

    private void applyClipboardUpdate(JSONObject update)
            throws JSONException, IOException {
        if (!getSystemService(UserManager.class).isUserUnlocked()) {
            throw new IOException("clipboard is unavailable while the user is locked");
        }
        if (!"shell".equals(update.getString("source"))) {
            throw new IOException("clipboard command has invalid source");
        }
        long generation = update.getLong("generation");
        String text = update.isNull("text") ? null : update.getString("text");
        if (generation <= 0
                || (text != null
                        && text.getBytes(StandardCharsets.UTF_8).length
                                > 128 * 1024)) {
            throw new IOException("clipboard command is invalid");
        }
        synchronized (clipboardLock) {
            if (generation <= lastShellClipboardGeneration) {
                return;
            }
            lastShellClipboardGeneration = generation;
            awaitingShellClipboardCallback = true;
            expectedShellClipboardText = text;
        }
        ClipboardManager clipboard = getSystemService(ClipboardManager.class);
        if (text == null) {
            clipboard.clearPrimaryClip();
        } else {
            clipboard.setPrimaryClip(
                    ClipData.newPlainText("Nucleus clipboard", text));
        }
    }

    private void sendPendingClipboard(
            OutputStream output,
            String generation) throws IOException, JSONException {
        ClipboardSnapshot snapshot = pendingClipboard.getAndSet(null);
        if (snapshot == null) {
            return;
        }
        JSONObject update = new JSONObject()
                .put("source", "android")
                .put("generation", snapshot.generation);
        if (snapshot.text == null) {
            update.put("text", JSONObject.NULL);
        } else {
            update.put("text", snapshot.text);
        }
        send(output, new JSONObject()
                .put("kind", "clipboardChanged")
                .put("generation", generation)
                .put("clipboardUpdate", update));
    }

    private long sendNotificationSnapshot(
            OutputStream output,
            String generation,
            long serial) throws IOException, JSONException {
        long revision = NucleusNotificationListenerService.revision();
        send(output, new JSONObject()
                .put("kind", "replaceNotifications")
                .put("generation", generation)
                .put("userUnlocked", true)
                .put("userSerial", serial)
                .put("notifications",
                        NucleusNotificationListenerService.snapshot()));
        return revision;
    }

    private void dismissNotification(JSONObject command)
            throws JSONException, IOException {
        String notificationID = command.getString("notificationID");
        if (!validField(notificationID, 4096)
                || !command.isNull("actionID")
                || !command.isNull("activationToken")) {
            throw new IOException("notification dismissal is invalid");
        }
        NucleusNotificationListenerService.dismiss(notificationID);
    }

    private void activateNotification(
            OutputStream output,
            String generation,
            JSONObject command)
            throws JSONException, IOException {
        String notificationID = command.getString("notificationID");
        String actionID = command.isNull("actionID")
                ? null : command.getString("actionID");
        String activationToken = command.isNull("activationToken")
                ? null : command.getString("activationToken");
        String requestId = command.getString("requestID");
        long presentationId = command.getLong("presentationID");
        if (!validField(notificationID, 4096)
                || (actionID != null && !validField(actionID, 1024))
                || (activationToken != null
                        && !validField(activationToken, 4096))
                || !validField(requestId, 128)
                || presentationId <= 0) {
            throw new IOException("notification activation is invalid");
        }
        if (!NucleusNotificationListenerService.presentsActivity(
                    notificationID, actionID)) {
            try {
                NucleusNotificationListenerService.activate(
                        notificationID, actionID, null);
                sendLaunchResult(
                        output,
                        generation,
                        requestId,
                        presentationId,
                        null,
                        null,
                        null,
                        "failed",
                        "Android notification action completed without a presentation");
            } catch (android.app.PendingIntent.CanceledException error) {
                throw new IOException("notification action was cancelled", error);
            }
            return;
        }
        int displayId;
        try {
            IDisplayManager displays = IDisplayManager.Stub.asInterface(
                    ServiceManager.getService(Context.DISPLAY_SERVICE));
            if (displays == null) {
                throw new IllegalStateException(
                        "Android display manager is unavailable");
            }
            displayId = displays.createNucleusPresentation(presentationId);
            activePresentations.add(presentationId);
            presentationByDisplayId.put(displayId, presentationId);
            displayByPresentationId.put(presentationId, displayId);
            pendingLaunches.put(
                    requestId,
                    new PendingLaunch(
                            requestId,
                            presentationId,
                            displayId,
                            SystemClock.elapsedRealtime()));
            ActivityOptions options = ActivityOptions.makeBasic();
            options.setLaunchDisplayId(displayId);
            NucleusNotificationListenerService.activate(
                    notificationID, actionID, options.toBundle());
            taskStateDirty.set(true);
        } catch (android.app.PendingIntent.CanceledException error) {
            pendingLaunches.remove(requestId);
            closeFrameworkPresentation(presentationId);
            throw new IOException("notification action was cancelled", error);
        } catch (Exception error) {
            pendingLaunches.remove(requestId);
            if (activePresentations.contains(presentationId)) {
                closeFrameworkPresentation(presentationId);
            }
            sendLaunchResult(
                    output,
                    generation,
                    requestId,
                    presentationId,
                    null,
                    null,
                    null,
                    "failed",
                    describeFailure(error));
        }
    }

    private static boolean validField(String value, int maximumBytes) {
        return value != null && !value.isEmpty() && !value.contains("\0")
                && value.getBytes(StandardCharsets.UTF_8).length <= maximumBytes;
    }

    private void beginActivityLaunch(
            OutputStream output,
            String generation,
            JSONObject request) throws IOException, JSONException {
        String requestId = request.getString("requestID");
        long presentationId = request.getLong("presentationID");
        try {
            if (presentationId <= 0) {
                throw new IllegalArgumentException(
                        "presentation identity must be positive");
            }
            String packageName = request.getString("packageName");
            String activityName = request.getString("activityName");
            ComponentName component = new ComponentName(
                    packageName, activityName);
            requireLaunchableActivity(component);
            ActivityManager.RunningTaskInfo existing = findManagedTask(component);
            if (existing != null) {
                long existingPresentation = presentationByDisplayId.get(existing.displayId);
                ActivityTaskManager.getService().moveTaskToFront(
                        null, getPackageName(), existing.taskId, 0, null);
                sendLaunchResult(
                        output,
                        generation,
                        requestId,
                        presentationId,
                        existingPresentation,
                        existing.displayId,
                        existing.taskId,
                        "activatedExistingPresentation",
                        null);
                return;
            }
            IDisplayManager displays = IDisplayManager.Stub.asInterface(
                    ServiceManager.getService(Context.DISPLAY_SERVICE));
            if (displays == null) {
                throw new IllegalStateException(
                        "Android display manager is unavailable");
            }
            int displayId = displays.createNucleusPresentation(
                    presentationId);
            activePresentations.add(presentationId);
            presentationByDisplayId.put(displayId, presentationId);
            displayByPresentationId.put(presentationId, displayId);
            PendingLaunch pending = new PendingLaunch(
                    requestId, presentationId, displayId, component);
            pendingLaunches.put(requestId, pending);
            try {
                Intent intent = new Intent(Intent.ACTION_MAIN)
                        .addCategory(Intent.CATEGORY_LAUNCHER)
                        .setComponent(component)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK
                                | Intent.FLAG_ACTIVITY_RESET_TASK_IF_NEEDED);
                ActivityOptions options = ActivityOptions.makeBasic();
                options.setLaunchDisplayId(displayId);
                startActivity(intent, options.toBundle());
                taskStateDirty.set(true);
            } catch (Exception error) {
                pendingLaunches.remove(requestId);
                closeFrameworkPresentation(presentationId);
                throw error;
            }
        } catch (Exception error) {
            sendLaunchResult(
                    output,
                    generation,
                    requestId,
                    presentationId,
                    null,
                    null,
                    null,
                    "failed",
                    describeFailure(error));
        }
    }

    private ActivityManager.RunningTaskInfo findManagedTask(ComponentName component) {
        for (ActivityManager.RunningTaskInfo task : getManagedTasks()) {
            if (component.equals(task.baseActivity)
                    || component.equals(task.topActivity)) {
                return task;
            }
        }
        return null;
    }

    private void sendTaskUpdates(OutputStream output, String generation)
            throws IOException, JSONException {
        boolean changed = taskStateDirty.getAndSet(false);
        Integer removedTaskId;
        while ((removedTaskId = removedTaskIds.poll()) != null) {
            removeTrackedTask(output, generation, removedTaskId);
        }
        if (changed) {
            List<ActivityManager.RunningTaskInfo> tasks = getManagedTasks();
            Set<Integer> currentTaskIds = new HashSet<>();
            for (ActivityManager.RunningTaskInfo task : tasks) {
                currentTaskIds.add(task.taskId);
                Long presentationId = presentationByDisplayId.get(task.displayId);
                Long trackedPresentation = presentationByTaskId.get(task.taskId);
                if (trackedPresentation != null
                        && !trackedPresentation.equals(presentationId)) {
                    removeTrackedTask(output, generation, task.taskId);
                }
                if (presentationId == null) {
                    continue;
                }
                trackTask(presentationId, task.taskId);
                ComponentName component = task.topActivity != null
                        ? task.topActivity : task.baseActivity;
                if (component == null) {
                    continue;
                }
                String signature = presentationId + ":" + task.displayId + ":"
                        + component.flattenToString();
                if (!signature.equals(publishedTasks.put(task.taskId, signature))) {
                    sendTaskChanged(output, generation, presentationId, task, component);
                }
                completePendingLaunches(
                        output, generation, presentationId, task);
            }
            for (int taskId : new ArrayList<>(presentationByTaskId.keySet())) {
                if (!currentTaskIds.contains(taskId)) {
                    removeTrackedTask(output, generation, taskId);
                }
            }
        }
        long now = SystemClock.elapsedRealtime();
        for (PendingLaunch pending : new ArrayList<>(pendingLaunches.values())) {
            if (now < pending.deadlineMillis
                    || pendingLaunches.remove(pending.requestId) == null) {
                continue;
            }
            closeFrameworkPresentation(pending.requestedPresentationId);
            sendLaunchResult(
                    output,
                    generation,
                    pending.requestId,
                    pending.requestedPresentationId,
                    null,
                    null,
                    null,
                    "failed",
                    "Android did not create the requested task");
        }
    }

    private List<ActivityManager.RunningTaskInfo> getManagedTasks() {
        ActivityTaskManager taskManager = ActivityTaskManager.getInstance();
        List<ActivityManager.RunningTaskInfo> tasks = new ArrayList<>();
        for (int displayId : new ArrayList<>(presentationByDisplayId.keySet())) {
            tasks.addAll(
                    taskManager.getTasks(
                            Integer.MAX_VALUE,
                            false,
                            false,
                            displayId));
        }
        return tasks;
    }

    private void completePendingLaunches(
            OutputStream output,
            String generation,
            long presentationId,
            ActivityManager.RunningTaskInfo task) throws IOException, JSONException {
        for (PendingLaunch pending : new ArrayList<>(pendingLaunches.values())) {
            ComponentName activity = task.topActivity != null
                    ? task.topActivity : task.baseActivity;
            boolean matches = pending.component != null
                    ? pending.component.equals(task.baseActivity)
                            || pending.component.equals(task.topActivity)
                    : activity != null
                            && task.lastActiveTime
                                    >= pending.minimumLastActiveTime;
            if (!matches
                    || (pending.component != null
                            && pending.displayId != task.displayId)
                    || pendingLaunches.remove(pending.requestId) == null) {
                continue;
            }
            if (presentationId != pending.requestedPresentationId) {
                closeFrameworkPresentation(pending.requestedPresentationId);
            }
            sendLaunchResult(
                    output,
                    generation,
                    pending.requestId,
                    pending.requestedPresentationId,
                    presentationId,
                    task.displayId,
                    task.taskId,
                    presentationId == pending.requestedPresentationId
                            ? "created" : "activatedExistingPresentation",
                    null);
        }
    }

    private void trackTask(long presentationId, int taskId) {
        presentationByTaskId.put(taskId, presentationId);
        taskIdsByPresentation
                .computeIfAbsent(presentationId, ignored -> new HashSet<>())
                .add(taskId);
    }

    private void removeTrackedTask(
            OutputStream output,
            String generation,
            int taskId) throws IOException, JSONException {
        Long presentationId = presentationByTaskId.remove(taskId);
        publishedTasks.remove(taskId);
        if (presentationId == null) {
            return;
        }
        Set<Integer> taskIds = taskIdsByPresentation.get(presentationId);
        if (taskIds != null) {
            taskIds.remove(taskId);
            if (!taskIds.isEmpty()) {
                return;
            }
            taskIdsByPresentation.remove(presentationId);
        }
        closeFrameworkPresentation(presentationId);
        send(output, new JSONObject()
                .put("kind", "taskVanished")
                .put("generation", generation)
                .put("vanishedTask", new JSONObject()
                        .put("presentationID", presentationId)
                        .put("taskID", taskId)));
    }

    private void sendTaskChanged(
            OutputStream output,
            String generation,
            long presentationId,
            ActivityManager.RunningTaskInfo task,
            ComponentName component) throws IOException, JSONException {
        send(output, new JSONObject()
                .put("kind", "taskChanged")
                .put("generation", generation)
                .put("taskState", new JSONObject()
                        .put("presentationID", presentationId)
                        .put("displayID", task.displayId)
                        .put("taskID", task.taskId)
                        .put("packageName", component.getPackageName())
                        .put("activityName", component.getClassName())));
    }

    private void sendLaunchResult(
            OutputStream output,
            String generation,
            String requestId,
            long requestedPresentationId,
            Long presentationId,
            Integer displayId,
            Integer taskId,
            String outcome,
            String failure) throws IOException, JSONException {
        JSONObject result = new JSONObject()
                .put("requestID", requestId)
                .put("requestedPresentationID", requestedPresentationId)
                .put("outcome", outcome);
        if (presentationId != null) {
            result.put("presentationID", presentationId);
        }
        if (displayId != null) {
            result.put("displayID", displayId);
        }
        if (taskId != null) {
            result.put("taskID", taskId);
        }
        if (failure != null) {
            result.put("failure", failure);
        }
        send(output, new JSONObject()
                .put("kind", "launchResult")
                .put("generation", generation)
                .put("activityLaunchResult", result));
    }

    private void requireLaunchableActivity(ComponentName requested) {
        LauncherApps launcherApps = getSystemService(LauncherApps.class);
        UserHandle user = Process.myUserHandle();
        for (LauncherActivityInfo activity
                : launcherApps.getActivityList(
                        requested.getPackageName(), user)) {
            if (activity.getComponentName().equals(requested)) {
                return;
            }
        }
        throw new IllegalArgumentException(
                "activity is not available to the current Android user");
    }

    private void closePresentation(long presentationId) {
        Set<Integer> taskIds = taskIdsByPresentation.remove(presentationId);
        if (taskIds != null) {
            for (int taskId : new ArrayList<>(taskIds)) {
                presentationByTaskId.remove(taskId);
                publishedTasks.remove(taskId);
                try {
                    ActivityTaskManager.getService().removeTask(taskId);
                } catch (RemoteException error) {
                    Log.w(TAG, "removing Android presentation task failed", error);
                }
            }
        }
        closeFrameworkPresentation(presentationId);
    }

    private void closePresentationFromHost(
            OutputStream output,
            String generation,
            long presentationId) throws IOException, JSONException {
        for (PendingLaunch pending : new ArrayList<>(pendingLaunches.values())) {
            if (pending.requestedPresentationId != presentationId
                    || pendingLaunches.remove(pending.requestId) == null) {
                continue;
            }
            sendLaunchResult(
                    output,
                    generation,
                    pending.requestId,
                    pending.requestedPresentationId,
                    null,
                    null,
                    null,
                    "failed",
                    "Host presentation closed during Android activity launch");
        }
        closePresentation(presentationId);
    }

    private void closeFrameworkPresentation(long presentationId) {
        PresentationInputDevices inputDevices =
                inputDevicesByPresentation.remove(presentationId);
        if (inputDevices != null) {
            inputDevices.close();
        }
        IDisplayManager displays = IDisplayManager.Stub.asInterface(
                ServiceManager.getService(Context.DISPLAY_SERVICE));
        if (displays == null) {
            throw new IllegalStateException(
                    "Android display manager is unavailable");
        }
        try {
            displays.removeNucleusPresentation(presentationId);
        } catch (RemoteException error) {
            throw error.rethrowFromSystemServer();
        }
        activePresentations.remove(presentationId);
        displayByPresentationId.remove(presentationId);
        presentationByDisplayId.values().removeIf(
                value -> value == presentationId);
    }

    private void closeApplicationPresentations() {
        if (activePresentations.isEmpty()) {
            return;
        }
        for (long presentationId
                : new ArrayList<>(activePresentations)) {
            try {
                closePresentation(presentationId);
            } catch (Exception error) {
                Log.w(TAG, "closing Android presentation failed", error);
            }
        }
    }

    private void sendPendingPointerIcons(
            OutputStream output, String generation)
            throws IOException, JSONException {
        for (Map.Entry<Integer, Integer> entry
                : pendingPointerIcons.entrySet()) {
            int displayId = entry.getKey();
            int pointerIconType = entry.getValue();
            if (!pendingPointerIcons.remove(
                    displayId, pointerIconType)) {
                continue;
            }
            send(output, new JSONObject()
                    .put("kind", "cursorShape")
                    .put("generation", generation)
                    .put("cursorShape", new JSONObject()
                            .put("displayID", displayId)
                            .put("pointerIconType", pointerIconType)));
        }
    }

    private void sendInputEvent(JSONObject payload)
            throws JSONException, IOException {
        String actionName = payload.getString("action");
        long presentationId = payload.getLong("presentationID");
        long configurationGeneration =
                payload.getLong("configurationGeneration");
        long eventTimeNanos =
                payload.getLong("eventTimeNanoseconds");
        if ("pointerLeave".equals(actionName)) {
            PresentationInputDevices devices = existingInputDevices(
                    presentationId, configurationGeneration);
            if (devices != null) {
                devices.releasePointer(eventTimeNanos);
            }
            return;
        }
        if ("keyboardFocus".equals(actionName)
                && !payload.getBoolean("focused")) {
            PresentationInputDevices devices = existingInputDevices(
                    presentationId, configurationGeneration);
            if (devices != null) {
                devices.releaseKeyboard(eventTimeNanos);
            }
            return;
        }
        if ("touchCancel".equals(actionName)) {
            PresentationInputDevices devices = existingInputDevices(
                    presentationId, configurationGeneration);
            if (devices != null) {
                devices.cancelTouches(eventTimeNanos);
            }
            return;
        }
        if ("configurationChanged".equals(actionName)) {
            PresentationInputDevices devices = existingInputDevices(
                    presentationId, configurationGeneration);
            if (devices != null) {
                devices.cancel(eventTimeNanos);
            }
            return;
        }
        PresentationInputDevices devices = inputDevices(
                presentationId, configurationGeneration);
        switch (actionName) {
            case "pointerEnter":
                devices.alignPointer(
                        (float) payload.getDouble("x"),
                        (float) payload.getDouble("y"),
                        eventTimeNanos);
                return;
            case "pointerMotion":
                devices.alignPointer(
                        (float) payload.getDouble("x"),
                        (float) payload.getDouble("y"),
                        eventTimeNanos);
                return;
            case "pointerButton":
                devices.alignPointer(
                        (float) payload.getDouble("x"),
                        (float) payload.getDouble("y"),
                        eventTimeNanos);
                int button = androidButton(payload.getInt("button"));
                boolean pressed = payload.getBoolean("pressed");
                if (pressed) {
                    focusPresentation(presentationId);
                }
                devices.mouse.sendButtonEvent(
                        new VirtualMouseButtonEvent.Builder()
                                .setButtonCode(button)
                                .setAction(pressed
                                        ? VirtualMouseButtonEvent.ACTION_BUTTON_PRESS
                                        : VirtualMouseButtonEvent.ACTION_BUTTON_RELEASE)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
                if (pressed) {
                    devices.pressedButtons.add(button);
                } else {
                    devices.pressedButtons.remove(button);
                }
                return;
            case "pointerScroll":
                devices.alignPointer(
                        (float) payload.getDouble("x"),
                        (float) payload.getDouble("y"),
                        eventTimeNanos);
                devices.mouse.sendScrollEvent(
                        new VirtualMouseScrollEvent.Builder()
                                .setXAxisMovement(clampScroll(
                                        -payload.optDouble("scrollX", 0)))
                                .setYAxisMovement(clampScroll(
                                        -payload.optDouble("scrollY", 0)))
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
                return;
            case "keyboardFocus":
                focusPresentation(presentationId);
                return;
            case "key":
                int keyCode = androidKeyCode(
                        payload.getInt("keyCode"));
                if (keyCode == KeyEvent.KEYCODE_UNKNOWN) {
                    Log.w(TAG, "ignoring unmapped Linux key code "
                            + payload.getInt("keyCode"));
                    return;
                }
                boolean keyPressed = payload.getBoolean("pressed");
                devices.keyboard.sendKeyEvent(
                        new VirtualKeyEvent.Builder()
                                .setKeyCode(keyCode)
                                .setAction(keyPressed
                                        ? VirtualKeyEvent.ACTION_DOWN
                                        : VirtualKeyEvent.ACTION_UP)
                                .setEventTimeNanos(eventTimeNanos)
                                .build());
                if (keyPressed) {
                    devices.pressedKeys.add(keyCode);
                } else {
                    devices.pressedKeys.remove(keyCode);
                }
                return;
            case "touchDown":
            case "touchMotion":
            case "touchUp":
                if ("touchDown".equals(actionName)) {
                    focusPresentation(presentationId);
                }
                sendTouch(devices, payload, actionName, eventTimeNanos);
                return;
            default:
                throw new IOException("unsupported input action");
        }
    }

    private PresentationInputDevices inputDevices(
            long presentationId,
            long configurationGeneration) throws IOException {
        PresentationInputDevices existing = existingInputDevices(
                presentationId, configurationGeneration);
        if (existing != null) {
            return existing;
        }
        Integer displayId = displayByPresentationId.get(presentationId);
        if (displayId == null) {
            throw new IOException("Android presentation is not active");
        }
        try {
            PresentationInputDevices created = new PresentationInputDevices(
                    presentationId, displayId, configurationGeneration);
            inputDevicesByPresentation.put(presentationId, created);
            return created;
        } catch (RuntimeException error) {
            throw new IOException("creating Android virtual input devices failed", error);
        }
    }

    private PresentationInputDevices existingInputDevices(
            long presentationId,
            long configurationGeneration) throws IOException {
        if (!displayByPresentationId.containsKey(presentationId)) {
            throw new IOException("Android presentation is not active");
        }
        PresentationInputDevices existing =
                inputDevicesByPresentation.get(presentationId);
        if (existing == null) {
            return null;
        }
        if (configurationGeneration < existing.configurationGeneration) {
            throw new IOException("Android input uses a stale configuration generation");
        }
        if (configurationGeneration > existing.configurationGeneration) {
            inputDevicesByPresentation.remove(presentationId);
            existing.retireForConfiguration();
            return null;
        }
        return existing;
    }

    private void sendTouch(
            PresentationInputDevices devices,
            JSONObject payload,
            String actionName,
            long eventTimeNanos) throws JSONException, IOException {
        int contactId = payload.getInt("contactID");
        float x = (float) payload.getDouble("x");
        float y = (float) payload.getDouble("y");
        int action;
        switch (actionName) {
            case "touchDown": action = VirtualTouchEvent.ACTION_DOWN; break;
            case "touchMotion": action = VirtualTouchEvent.ACTION_MOVE; break;
            case "touchUp": action = VirtualTouchEvent.ACTION_UP; break;
            default: throw new IOException("unsupported touch action");
        }
        devices.touchscreen.sendTouchEvent(
                new VirtualTouchEvent.Builder()
                        .setPointerId(contactId)
                        .setToolType(VirtualTouchEvent.TOOL_TYPE_FINGER)
                        .setAction(action)
                        .setX(x)
                        .setY(y)
                        .setPressure(action == VirtualTouchEvent.ACTION_UP ? 0 : 1)
                        .setEventTimeNanos(eventTimeNanos)
                        .build());
        if (action == VirtualTouchEvent.ACTION_UP) {
            devices.touches.remove(contactId);
        } else {
            devices.touches.put(contactId, new PointF(x, y));
        }
    }

    private void focusPresentation(long presentationId) throws IOException {
        Integer displayId = displayByPresentationId.get(presentationId);
        if (displayId == null) {
            return;
        }
        for (ActivityManager.RunningTaskInfo task : getManagedTasks()) {
            if (task.displayId != displayId) {
                continue;
            }
            try {
                ActivityTaskManager.getService().setFocusedTask(task.taskId);
            } catch (RemoteException error) {
                throw new IOException("focusing Android presentation failed", error);
            }
            return;
        }
    }

    private static float clampScroll(double value) {
        return (float) Math.max(-1, Math.min(1, value));
    }

    private static int androidButton(int linuxButton) throws IOException {
        switch (linuxButton) {
            case 0x110:
                return VirtualMouseButtonEvent.BUTTON_PRIMARY;
            case 0x111:
                return VirtualMouseButtonEvent.BUTTON_SECONDARY;
            case 0x112:
                return VirtualMouseButtonEvent.BUTTON_TERTIARY;
            case 0x113:
                return VirtualMouseButtonEvent.BUTTON_BACK;
            case 0x114:
                return VirtualMouseButtonEvent.BUTTON_FORWARD;
            default:
                throw new IOException("unsupported pointer button");
        }
    }

    private static int androidKeyCode(int linuxKeyCode) {
        switch (linuxKeyCode) {
            case 1: return KeyEvent.KEYCODE_ESCAPE;
            case 2: return KeyEvent.KEYCODE_1;
            case 3: return KeyEvent.KEYCODE_2;
            case 4: return KeyEvent.KEYCODE_3;
            case 5: return KeyEvent.KEYCODE_4;
            case 6: return KeyEvent.KEYCODE_5;
            case 7: return KeyEvent.KEYCODE_6;
            case 8: return KeyEvent.KEYCODE_7;
            case 9: return KeyEvent.KEYCODE_8;
            case 10: return KeyEvent.KEYCODE_9;
            case 11: return KeyEvent.KEYCODE_0;
            case 12: return KeyEvent.KEYCODE_MINUS;
            case 13: return KeyEvent.KEYCODE_EQUALS;
            case 14: return KeyEvent.KEYCODE_DEL;
            case 15: return KeyEvent.KEYCODE_TAB;
            case 16: return KeyEvent.KEYCODE_Q;
            case 17: return KeyEvent.KEYCODE_W;
            case 18: return KeyEvent.KEYCODE_E;
            case 19: return KeyEvent.KEYCODE_R;
            case 20: return KeyEvent.KEYCODE_T;
            case 21: return KeyEvent.KEYCODE_Y;
            case 22: return KeyEvent.KEYCODE_U;
            case 23: return KeyEvent.KEYCODE_I;
            case 24: return KeyEvent.KEYCODE_O;
            case 25: return KeyEvent.KEYCODE_P;
            case 26: return KeyEvent.KEYCODE_LEFT_BRACKET;
            case 27: return KeyEvent.KEYCODE_RIGHT_BRACKET;
            case 28: return KeyEvent.KEYCODE_ENTER;
            case 29: return KeyEvent.KEYCODE_CTRL_LEFT;
            case 30: return KeyEvent.KEYCODE_A;
            case 31: return KeyEvent.KEYCODE_S;
            case 32: return KeyEvent.KEYCODE_D;
            case 33: return KeyEvent.KEYCODE_F;
            case 34: return KeyEvent.KEYCODE_G;
            case 35: return KeyEvent.KEYCODE_H;
            case 36: return KeyEvent.KEYCODE_J;
            case 37: return KeyEvent.KEYCODE_K;
            case 38: return KeyEvent.KEYCODE_L;
            case 39: return KeyEvent.KEYCODE_SEMICOLON;
            case 40: return KeyEvent.KEYCODE_APOSTROPHE;
            case 41: return KeyEvent.KEYCODE_GRAVE;
            case 42: return KeyEvent.KEYCODE_SHIFT_LEFT;
            case 43: return KeyEvent.KEYCODE_BACKSLASH;
            case 44: return KeyEvent.KEYCODE_Z;
            case 45: return KeyEvent.KEYCODE_X;
            case 46: return KeyEvent.KEYCODE_C;
            case 47: return KeyEvent.KEYCODE_V;
            case 48: return KeyEvent.KEYCODE_B;
            case 49: return KeyEvent.KEYCODE_N;
            case 50: return KeyEvent.KEYCODE_M;
            case 51: return KeyEvent.KEYCODE_COMMA;
            case 52: return KeyEvent.KEYCODE_PERIOD;
            case 53: return KeyEvent.KEYCODE_SLASH;
            case 54: return KeyEvent.KEYCODE_SHIFT_RIGHT;
            case 55: return KeyEvent.KEYCODE_NUMPAD_MULTIPLY;
            case 56: return KeyEvent.KEYCODE_ALT_LEFT;
            case 57: return KeyEvent.KEYCODE_SPACE;
            case 58: return KeyEvent.KEYCODE_CAPS_LOCK;
            case 59: return KeyEvent.KEYCODE_F1;
            case 60: return KeyEvent.KEYCODE_F2;
            case 61: return KeyEvent.KEYCODE_F3;
            case 62: return KeyEvent.KEYCODE_F4;
            case 63: return KeyEvent.KEYCODE_F5;
            case 64: return KeyEvent.KEYCODE_F6;
            case 65: return KeyEvent.KEYCODE_F7;
            case 66: return KeyEvent.KEYCODE_F8;
            case 67: return KeyEvent.KEYCODE_F9;
            case 68: return KeyEvent.KEYCODE_F10;
            case 69: return KeyEvent.KEYCODE_NUM_LOCK;
            case 70: return KeyEvent.KEYCODE_SCROLL_LOCK;
            case 71: return KeyEvent.KEYCODE_NUMPAD_7;
            case 72: return KeyEvent.KEYCODE_NUMPAD_8;
            case 73: return KeyEvent.KEYCODE_NUMPAD_9;
            case 74: return KeyEvent.KEYCODE_NUMPAD_SUBTRACT;
            case 75: return KeyEvent.KEYCODE_NUMPAD_4;
            case 76: return KeyEvent.KEYCODE_NUMPAD_5;
            case 77: return KeyEvent.KEYCODE_NUMPAD_6;
            case 78: return KeyEvent.KEYCODE_NUMPAD_ADD;
            case 79: return KeyEvent.KEYCODE_NUMPAD_1;
            case 80: return KeyEvent.KEYCODE_NUMPAD_2;
            case 81: return KeyEvent.KEYCODE_NUMPAD_3;
            case 82: return KeyEvent.KEYCODE_NUMPAD_0;
            case 83: return KeyEvent.KEYCODE_NUMPAD_DOT;
            case 87: return KeyEvent.KEYCODE_F11;
            case 88: return KeyEvent.KEYCODE_F12;
            case 96: return KeyEvent.KEYCODE_NUMPAD_ENTER;
            case 97: return KeyEvent.KEYCODE_CTRL_RIGHT;
            case 98: return KeyEvent.KEYCODE_NUMPAD_DIVIDE;
            case 100: return KeyEvent.KEYCODE_ALT_RIGHT;
            case 102: return KeyEvent.KEYCODE_MOVE_HOME;
            case 103: return KeyEvent.KEYCODE_DPAD_UP;
            case 104: return KeyEvent.KEYCODE_PAGE_UP;
            case 105: return KeyEvent.KEYCODE_DPAD_LEFT;
            case 106: return KeyEvent.KEYCODE_DPAD_RIGHT;
            case 107: return KeyEvent.KEYCODE_MOVE_END;
            case 108: return KeyEvent.KEYCODE_DPAD_DOWN;
            case 109: return KeyEvent.KEYCODE_PAGE_DOWN;
            case 110: return KeyEvent.KEYCODE_INSERT;
            case 111: return KeyEvent.KEYCODE_FORWARD_DEL;
            case 113: return KeyEvent.KEYCODE_VOLUME_MUTE;
            case 114: return KeyEvent.KEYCODE_VOLUME_DOWN;
            case 115: return KeyEvent.KEYCODE_VOLUME_UP;
            case 119: return KeyEvent.KEYCODE_BREAK;
            case 125: return KeyEvent.KEYCODE_META_LEFT;
            case 126: return KeyEvent.KEYCODE_META_RIGHT;
            default: return KeyEvent.KEYCODE_UNKNOWN;
        }
    }

    private static void sendRuntimeState(
            OutputStream output,
            String generation,
            boolean unlocked,
            long serial) throws IOException, JSONException {
        send(output, new JSONObject()
                .put("kind", "runtimeState")
                .put("generation", generation)
                .put("userUnlocked", unlocked)
                .put("userSerial", serial));
    }

    private static void sendInputState(
            OutputStream output,
            String generation,
            boolean ready,
            String error) throws IOException, JSONException {
        JSONObject state = new JSONObject()
                .put("kind", "inputState")
                .put("generation", generation)
                .put("inputReady", ready);
        if (error != null) {
            state.put("inputError", error);
        }
        send(output, state);
    }

    private static String describeFailure(Throwable failure) {
        StringBuilder description = new StringBuilder();
        Throwable current = failure;
        while (current != null && description.length() < 16 * 1024) {
            if (description.length() > 0) {
                description.append(": ");
            }
            description.append(current.getClass().getName());
            String message = current.getMessage();
            if (message != null && !message.isEmpty()) {
                description.append(": ").append(message);
            }
            current = current.getCause();
        }
        return description.toString();
    }

    private void sendActivitySnapshot(
            OutputStream output,
            String generation,
            long serial) throws IOException, JSONException {
        JSONArray activities = collectActivities(output, generation, serial, null);
        send(output, new JSONObject()
                .put("kind", "replaceActivities")
                .put("generation", generation)
                .put("userUnlocked", true)
                .put("userSerial", serial)
                .put("activities", activities));
    }

    private void sendPackageActivitySnapshot(
            OutputStream output,
            String generation,
            long serial,
            String packageName) throws IOException, JSONException {
        JSONArray activities = collectActivities(
                output, generation, serial, packageName);
        send(output, new JSONObject()
                .put("kind", "replacePackageActivities")
                .put("generation", generation)
                .put("userUnlocked", true)
                .put("userSerial", serial)
                .put("packageName", packageName)
                .put("activities", activities));
    }

    private JSONArray collectActivities(
            OutputStream output,
            String generation,
            long serial,
            String packageName) throws IOException, JSONException {
        LauncherApps launcherApps = getSystemService(LauncherApps.class);
        PackageManager packageManager = getPackageManager();
        UserHandle user = Process.myUserHandle();
        List<LauncherActivityInfo> resolved = new ArrayList<>(
                launcherApps.getActivityList(packageName, user));
        resolved.sort(Comparator
                .comparing((LauncherActivityInfo value) ->
                        value.getComponentName().getPackageName())
                .thenComparing(value ->
                        value.getComponentName().getClassName()));
        JSONArray activities = new JSONArray();
        Set<String> publishedIcons = new java.util.HashSet<>();
        for (LauncherActivityInfo value : resolved) {
            String resolvedPackage = value.getComponentName().getPackageName();
            String activityName = value.getComponentName().getClassName();
            if (activityName.endsWith(".FallbackHome")) {
                continue;
            }
            ApplicationInfo application = value.getApplicationInfo();
            if (!application.enabled
                    || (application.flags & ApplicationInfo.FLAG_SUSPENDED) != 0) {
                continue;
            }
            try {
                ActivityInfo activity = packageManager.getActivityInfo(
                        value.getComponentName(),
                        PackageManager.MATCH_DIRECT_BOOT_AWARE
                                | PackageManager.MATCH_DIRECT_BOOT_UNAWARE);
                if (!activity.enabled || !activity.exported) {
                    continue;
                }
            } catch (PackageManager.NameNotFoundException error) {
                continue;
            }
            JSONObject record = new JSONObject()
                    .put("packageName", resolvedPackage)
                    .put("activityName", activityName)
                    .put("label", value.getLabel() == null
                            ? activityName : value.getLabel().toString());
            String category = applicationCategory(application.category);
            if (category != null) {
                record.put("categories", new JSONArray().put(category));
            }
            IconAsset icon = renderIcon(value);
            if (icon != null) {
                record.put("iconDigest", icon.digest);
                if (publishedIcons.add(icon.digest)) {
                    send(output, new JSONObject()
                            .put("kind", "iconAsset")
                            .put("generation", generation)
                            .put("userUnlocked", true)
                            .put("userSerial", serial)
                            .put("iconAsset", new JSONObject()
                                    .put("digest", icon.digest)
                                    .put("bytes", Base64.encodeToString(
                                            icon.bytes, Base64.NO_WRAP))));
                }
            }
            activities.put(record);
        }
        return activities;
    }

    private static String applicationCategory(int category) {
        switch (category) {
            case ApplicationInfo.CATEGORY_GAME: return "game";
            case ApplicationInfo.CATEGORY_AUDIO: return "audio";
            case ApplicationInfo.CATEGORY_VIDEO: return "video";
            case ApplicationInfo.CATEGORY_IMAGE: return "image";
            case ApplicationInfo.CATEGORY_SOCIAL: return "social";
            case ApplicationInfo.CATEGORY_NEWS: return "news";
            case ApplicationInfo.CATEGORY_MAPS: return "maps";
            case ApplicationInfo.CATEGORY_PRODUCTIVITY: return "productivity";
            case ApplicationInfo.CATEGORY_ACCESSIBILITY: return "accessibility";
            default: return null;
        }
    }

    private static IconAsset renderIcon(LauncherActivityInfo activity) {
        Drawable drawable = activity.getIcon(DisplayMetrics.DENSITY_XHIGH);
        if (drawable == null) {
            return null;
        }
        Bitmap bitmap = Bitmap.createBitmap(
                96, 96, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        drawable.setBounds(0, 0, bitmap.getWidth(), bitmap.getHeight());
        drawable.draw(canvas);
        ByteArrayOutputStream bytes = new ByteArrayOutputStream();
        if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, bytes)) {
            return null;
        }
        byte[] encoded = bytes.toByteArray();
        if (encoded.length == 0 || encoded.length > 128 * 1024) {
            return null;
        }
        try {
            byte[] digest = MessageDigest.getInstance("SHA-256").digest(encoded);
            StringBuilder hexadecimal = new StringBuilder(64);
            for (byte value : digest) {
                hexadecimal.append(String.format("%02x", value & 0xff));
            }
            return new IconAsset(hexadecimal.toString(), encoded);
        } catch (NoSuchAlgorithmException error) {
            throw new AssertionError("Android lacks SHA-256", error);
        }
    }

    private static final class IconAsset {
        final String digest;
        final byte[] bytes;

        IconAsset(String digest, byte[] bytes) {
            this.digest = digest;
            this.bytes = bytes;
        }
    }

    private static void send(OutputStream output, JSONObject message)
            throws IOException {
        byte[] bytes = message.toString().getBytes(StandardCharsets.UTF_8);
        if (bytes.length == 0 || bytes.length > MAXIMUM_PACKET_BYTES) {
            throw new IOException("bridge packet exceeds protocol bounds");
        }
        output.write(bytes);
        output.flush();
    }

    private static JSONObject receive(InputStream input)
            throws IOException, JSONException {
        byte[] bytes = new byte[MAXIMUM_PACKET_BYTES];
        int count = input.read(bytes);
        if (count <= 0) {
            throw new IOException("broker closed during handshake");
        }
        return new JSONObject(new String(
                bytes, 0, count, StandardCharsets.UTF_8));
    }
}
