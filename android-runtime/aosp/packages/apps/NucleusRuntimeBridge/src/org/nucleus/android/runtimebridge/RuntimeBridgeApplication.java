package org.nucleus.android.runtimebridge;

import android.app.Application;
import android.content.BroadcastReceiver;
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
import android.graphics.drawable.Drawable;
import android.hardware.input.InputManager;
import android.hardware.input.IPointerIconChangedListener;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.view.InputDevice;
import android.os.Process;
import android.os.UserHandle;
import android.os.UserManager;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.util.Log;
import android.util.Base64;
import android.util.DisplayMetrics;
import android.view.KeyCharacterMap;
import android.view.KeyEvent;
import android.view.MotionEvent;

import org.json.JSONException;
import org.json.JSONArray;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.ConcurrentHashMap;

public final class RuntimeBridgeApplication extends Application {
    private static final String TAG = "NucleusRuntimeBridge";
    private static final String SOCKET_PATH =
            "/dev/nucleus-runtime/broker.sock";
    private static final int MAXIMUM_PACKET_BYTES = 256 * 1024;
    private static final AtomicBoolean STARTED = new AtomicBoolean();

    private final Set<String> dirtyPackages =
            ConcurrentHashMap.newKeySet();
    private final Map<Integer, Integer> pointerButtonStates =
            new HashMap<>();
    private final Map<Integer, Long> pointerDownTimesMillis =
            new HashMap<>();
    private final Map<Integer, Boolean> preparedInputDisplays =
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

    @Override
    public void onCreate() {
        super.onCreate();
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
                restoreAndroidPointerIcons();
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    private void restoreAndroidPointerIcons() {
        InputManager inputManager = getSystemService(InputManager.class);
        for (int displayId : preparedInputDisplays.keySet()) {
            try {
                inputManager.setPointerIconVisible(true, displayId);
            } catch (RuntimeException error) {
                Log.w(TAG, "restoring Android pointer icon failed for display "
                        + displayId, error);
            }
        }
        preparedInputDisplays.clear();
        pointerButtonStates.clear();
        pointerDownTimesMillis.clear();
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
                } else if (!currentlyUnlocked && catalogPublished) {
                    sendRuntimeState(output, generation, false, serial);
                    catalogPublished = false;
                    dirtyPackages.clear();
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
            sendPendingPointerIcons(output, generation);
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
        int displayId = payload.getInt("displayID");
        long eventTimeNanos =
                payload.getLong("eventTimeNanoseconds");
        switch (actionName) {
            case "pointerMotion":
                injectPointerMotion(payload, displayId, eventTimeNanos);
                return;
            case "pointerButton":
                injectPointerButton(payload, displayId, eventTimeNanos);
                return;
            case "pointerScroll":
                injectPointerScroll(payload, displayId, eventTimeNanos);
                return;
            case "key":
                int keyCode = androidKeyCode(
                        payload.getInt("keyCode"));
                if (keyCode == KeyEvent.KEYCODE_UNKNOWN) {
                    Log.w(TAG, "ignoring unmapped Linux key code "
                            + payload.getInt("keyCode"));
                    return;
                }
                injectKey(displayId, eventTimeNanos, keyCode,
                        payload.getBoolean("pressed"));
                return;
            default:
                throw new IOException("unsupported input action");
        }
    }

    private void prepareInputDisplay(int displayId) {
        if (preparedInputDisplays.putIfAbsent(displayId, true) != null) {
            return;
        }
        try {
            getSystemService(InputManager.class)
                    .setPointerIconVisible(false, displayId);
            Log.i(TAG, "prepared display-targeted native input for display "
                    + displayId);
        } catch (RuntimeException error) {
            preparedInputDisplays.remove(displayId);
            throw error;
        }
    }

    private void injectPointerMotion(
            JSONObject payload, int displayId, long eventTimeNanos)
            throws JSONException, IOException {
        int buttons = pointerButtonStates.getOrDefault(displayId, 0);
        injectMotion(payload, displayId, eventTimeNanos,
                buttons == 0 ? MotionEvent.ACTION_HOVER_MOVE
                        : MotionEvent.ACTION_MOVE,
                0, buttons, 0, 0);
    }

    private void injectPointerButton(
            JSONObject payload, int displayId, long eventTimeNanos)
            throws JSONException, IOException {
        int button = androidButton(payload.getInt("button"));
        boolean pressed = payload.getBoolean("pressed");
        int previous = pointerButtonStates.getOrDefault(displayId, 0);
        int buttons = pressed ? previous | button : previous & ~button;
        long eventTimeMillis = eventTimeNanos / 1_000_000;
        if (pressed && previous == 0) {
            pointerDownTimesMillis.put(displayId, eventTimeMillis);
            injectMotion(payload, displayId, eventTimeNanos,
                    MotionEvent.ACTION_DOWN, 0, buttons, 0, 0);
        }
        injectMotion(payload, displayId, eventTimeNanos,
                pressed ? MotionEvent.ACTION_BUTTON_PRESS
                        : MotionEvent.ACTION_BUTTON_RELEASE,
                button, buttons, 0, 0);
        if (!pressed && buttons == 0) {
            injectMotion(payload, displayId, eventTimeNanos,
                    MotionEvent.ACTION_UP, 0, 0, 0, 0);
            pointerDownTimesMillis.remove(displayId);
        }
        pointerButtonStates.put(displayId, buttons);
    }

    private void injectPointerScroll(
            JSONObject payload, int displayId, long eventTimeNanos)
            throws JSONException, IOException {
        injectMotion(payload, displayId, eventTimeNanos,
                MotionEvent.ACTION_SCROLL, 0,
                pointerButtonStates.getOrDefault(displayId, 0),
                (float) -payload.optDouble("scrollX", 0),
                (float) -payload.optDouble("scrollY", 0));
    }

    private void injectMotion(
            JSONObject payload,
            int displayId,
            long eventTimeNanos,
            int action,
            int actionButton,
            int buttonState,
            float horizontalScroll,
            float verticalScroll) throws JSONException, IOException {
        prepareInputDisplay(displayId);
        long eventTimeMillis = eventTimeNanos / 1_000_000;
        long downTimeMillis = pointerDownTimesMillis.getOrDefault(
                displayId, eventTimeMillis);
        MotionEvent.PointerProperties properties =
                new MotionEvent.PointerProperties();
        properties.id = 0;
        properties.toolType = MotionEvent.TOOL_TYPE_MOUSE;
        MotionEvent.PointerCoords coordinates =
                new MotionEvent.PointerCoords();
        coordinates.x = (float) payload.getDouble("x");
        coordinates.y = (float) payload.getDouble("y");
        coordinates.pressure = buttonState == 0 ? 0 : 1;
        coordinates.size = 1;
        coordinates.setAxisValue(
                MotionEvent.AXIS_HSCROLL, horizontalScroll);
        coordinates.setAxisValue(
                MotionEvent.AXIS_VSCROLL, verticalScroll);
        MotionEvent event = MotionEvent.obtain(
                downTimeMillis,
                eventTimeMillis,
                action,
                1,
                new MotionEvent.PointerProperties[]{properties},
                new MotionEvent.PointerCoords[]{coordinates},
                0,
                buttonState,
                1,
                1,
                0,
                0,
                InputDevice.SOURCE_MOUSE,
                displayId,
                0);
        event.setActionButton(actionButton);
        try {
            inject(event);
        } finally {
            event.recycle();
        }
    }

    private void injectKey(
            int displayId,
            long eventTimeNanos,
            int keyCode,
            boolean pressed) throws IOException {
        prepareInputDisplay(displayId);
        long eventTimeMillis = eventTimeNanos / 1_000_000;
        KeyEvent event = new KeyEvent(
                eventTimeMillis,
                eventTimeMillis,
                pressed ? KeyEvent.ACTION_DOWN : KeyEvent.ACTION_UP,
                keyCode,
                0,
                0,
                KeyCharacterMap.VIRTUAL_KEYBOARD,
                0,
                0,
                InputDevice.SOURCE_KEYBOARD);
        event.setDisplayId(displayId);
        inject(event);
    }

    private void inject(android.view.InputEvent event) throws IOException {
        if (!getSystemService(InputManager.class).injectInputEvent(
                event, InputManager.INJECT_INPUT_EVENT_MODE_ASYNC)) {
            throw new IOException("Android rejected input injection");
        }
    }

    private static int androidButton(int linuxButton) throws IOException {
        switch (linuxButton) {
            case 0x110:
                return MotionEvent.BUTTON_PRIMARY;
            case 0x111:
                return MotionEvent.BUTTON_SECONDARY;
            case 0x112:
                return MotionEvent.BUTTON_TERTIARY;
            case 0x113:
                return MotionEvent.BUTTON_BACK;
            case 0x114:
                return MotionEvent.BUTTON_FORWARD;
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
