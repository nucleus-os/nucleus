package org.nucleus.android.runtimebridge;

import android.app.Notification;
import android.app.PendingIntent;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageManager;
import android.os.Bundle;
import android.service.notification.NotificationListenerService;
import android.service.notification.StatusBarNotification;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.util.Arrays;
import java.util.Comparator;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

public final class NucleusNotificationListenerService
        extends NotificationListenerService {
    private static final int MAXIMUM_SNAPSHOT_BYTES = 240 * 1024;
    private static final int MAXIMUM_NOTIFICATIONS = 256;
    private static final AtomicReference<NucleusNotificationListenerService> ACTIVE =
            new AtomicReference<>();
    private static final AtomicLong REVISION = new AtomicLong();

    @Override
    public void onListenerConnected() {
        ACTIVE.set(this);
        advanceRevision();
    }

    @Override
    public void onListenerDisconnected() {
        ACTIVE.compareAndSet(this, null);
        advanceRevision();
    }

    @Override
    public void onNotificationPosted(StatusBarNotification notification) {
        advanceRevision();
    }

    @Override
    public void onNotificationRemoved(StatusBarNotification notification) {
        advanceRevision();
    }

    static long revision() {
        return REVISION.get();
    }

    static JSONArray snapshot() throws JSONException {
        NucleusNotificationListenerService service = ACTIVE.get();
        JSONArray result = new JSONArray();
        if (service == null) {
            return result;
        }
        StatusBarNotification[] active = service.getActiveNotifications();
        Arrays.sort(active, Comparator.comparing(StatusBarNotification::getKey));
        int encodedBytes = 2;
        for (StatusBarNotification notification : active) {
            JSONObject mapped = service.map(notification);
            if (mapped != null) {
                int itemBytes = mapped.toString()
                        .getBytes(java.nio.charset.StandardCharsets.UTF_8).length;
                int separatorBytes = result.length() == 0 ? 0 : 1;
                if (result.length() >= MAXIMUM_NOTIFICATIONS
                        || encodedBytes + separatorBytes + itemBytes
                                > MAXIMUM_SNAPSHOT_BYTES) {
                    break;
                }
                result.put(mapped);
                encodedBytes += separatorBytes + itemBytes;
            }
        }
        return result;
    }

    static void dismiss(String notificationID) {
        NucleusNotificationListenerService service = ACTIVE.get();
        if (service != null) {
            service.cancelNotification(notificationID);
        }
    }

    static boolean presentsActivity(String notificationID, String actionID) {
        PendingIntent intent = pendingIntent(notificationID, actionID);
        return intent != null && intent.isActivity();
    }

    static void activate(
            String notificationID,
            String actionID,
            Bundle options)
            throws PendingIntent.CanceledException {
        PendingIntent intent = pendingIntent(notificationID, actionID);
        if (intent != null) {
            intent.send(options);
        }
    }

    private static PendingIntent pendingIntent(
            String notificationID,
            String actionID) {
        StatusBarNotification status = notification(notificationID);
        if (status == null) {
            return null;
        }
        Notification notification = status.getNotification();
        return actionID == null
                ? notification.contentIntent
                : actionIntent(notification, actionID);
    }

    private static StatusBarNotification notification(String notificationID) {
        NucleusNotificationListenerService service = ACTIVE.get();
        if (service == null) {
            return null;
        }
        for (StatusBarNotification status : service.getActiveNotifications()) {
            if (status.getKey().equals(notificationID)) {
                return status;
            }
        }
        return null;
    }

    private static PendingIntent actionIntent(
            Notification notification,
            String actionID) {
        if (notification.actions == null || !actionID.startsWith("action:")) {
            return null;
        }
        final int index;
        try {
            index = Integer.parseInt(actionID.substring("action:".length()));
        } catch (NumberFormatException error) {
            return null;
        }
        return index >= 0 && index < notification.actions.length
                ? notification.actions[index].actionIntent : null;
    }

    private JSONObject map(StatusBarNotification status) throws JSONException {
        String key = status.getKey();
        String packageName = status.getPackageName();
        if (!valid(key, 4096) || !valid(packageName, 4096)) {
            return null;
        }
        Notification notification = status.getNotification();
        Bundle extras = notification.extras;
        String title = text(extras.getCharSequence(Notification.EXTRA_TITLE), 16 * 1024);
        String body = text(
                extras.getCharSequence(Notification.EXTRA_BIG_TEXT) != null
                        ? extras.getCharSequence(Notification.EXTRA_BIG_TEXT)
                        : extras.getCharSequence(Notification.EXTRA_TEXT),
                64 * 1024);
        String applicationName = applicationName(packageName);
        JSONObject result = new JSONObject()
                .put("id", key)
                .put("packageName", packageName)
                .put("applicationName", applicationName)
                .put("title", title)
                .put("body", body)
                .put("urgency", urgency(notification))
                .put("hasDefaultAction", notification.contentIntent != null);
        int progressMaximum = extras.getInt(Notification.EXTRA_PROGRESS_MAX, 0);
        int progress = extras.getInt(Notification.EXTRA_PROGRESS, 0);
        if (progressMaximum > 0 && progress >= 0 && progress <= progressMaximum) {
            result.put("progress", new JSONObject()
                    .put("value", progress)
                    .put("total", progressMaximum));
        }
        JSONArray actions = new JSONArray();
        if (notification.actions != null) {
            for (int index = 0; index < Math.min(16, notification.actions.length); index++) {
                Notification.Action action = notification.actions[index];
                if (action.actionIntent == null || action.title == null) {
                    continue;
                }
                actions.put(new JSONObject()
                        .put("id", "action:" + index)
                        .put("title", text(action.title, 4096)));
            }
        }
        result.put("actions", actions);
        return result;
    }

    private String applicationName(String packageName) {
        PackageManager packages = getPackageManager();
        try {
            ApplicationInfo application = packages.getApplicationInfo(packageName, 0);
            return text(packages.getApplicationLabel(application), 4096);
        } catch (PackageManager.NameNotFoundException error) {
            return packageName;
        }
    }

    private static String urgency(Notification notification) {
        if (notification.priority >= Notification.PRIORITY_HIGH) {
            return "critical";
        }
        if (notification.priority <= Notification.PRIORITY_LOW) {
            return "low";
        }
        return "normal";
    }

    private static String text(CharSequence value, int maximumBytes) {
        if (value == null) {
            return "";
        }
        String source = value.toString();
        StringBuilder result = new StringBuilder(source.length());
        int bytes = 0;
        for (int offset = 0; offset < source.length();) {
            int codePoint = source.codePointAt(offset);
            offset += Character.charCount(codePoint);
            if (codePoint == 0) {
                continue;
            }
            int encodedBytes = codePoint <= 0x7f ? 1
                    : codePoint <= 0x7ff ? 2
                    : codePoint <= 0xffff ? 3 : 4;
            if (bytes + encodedBytes > maximumBytes) {
                break;
            }
            result.appendCodePoint(codePoint);
            bytes += encodedBytes;
        }
        return result.toString();
    }

    private static boolean valid(String value, int maximumBytes) {
        return value != null && !value.isEmpty() && !value.contains("\0")
                && value.getBytes(java.nio.charset.StandardCharsets.UTF_8).length
                        <= maximumBytes;
    }

    private static void advanceRevision() {
        long revision = REVISION.incrementAndGet();
        if (revision <= 0) {
            throw new IllegalStateException("notification revision exhausted");
        }
    }
}
