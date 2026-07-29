package org.nucleus.android.runtimebridge;

import android.app.Application;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Process;
import android.os.UserManager;
import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructPollfd;
import android.util.Log;

import org.json.JSONException;
import org.json.JSONObject;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

public final class RuntimeBridgeApplication extends Application {
    private static final String TAG = "NucleusRuntimeBridge";
    private static final String SOCKET_PATH =
            "/dev/nucleus-runtime/broker.sock";
    private static final int PROTOCOL_VERSION = 1;
    private static final int MAXIMUM_PACKET_BYTES = 256 * 1024;
    private static final AtomicBoolean STARTED = new AtomicBoolean();

    private final AtomicBoolean unlockObserved = new AtomicBoolean();

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
        IntentFilter filter = new IntentFilter(Intent.ACTION_USER_UNLOCKED);
        registerReceiver(new BroadcastReceiver() {
            @Override
            public void onReceive(Context ignored, Intent intent) {
                unlockObserved.set(true);
            }
        }, filter, Context.RECEIVER_NOT_EXPORTED);
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
            } catch (ErrnoException | IOException | JSONException error) {
                Log.w(TAG, "bridge connection failed", error);
            }
            try {
                Thread.sleep(500);
            } catch (InterruptedException error) {
                Thread.currentThread().interrupt();
                return;
            }
        }
    }

    private void serve(LocalSocket socket)
            throws IOException, JSONException, ErrnoException {
        InputStream input = socket.getInputStream();
        OutputStream output = socket.getOutputStream();
        send(output, new JSONObject()
                .put("protocolVersion", PROTOCOL_VERSION)
                .put("kind", "bridgeHello"));
        JSONObject hello = receive(input);
        if (hello.getInt("protocolVersion") != PROTOCOL_VERSION
                || !"brokerHello".equals(hello.getString("kind"))) {
            throw new IOException("broker rejected bridge protocol");
        }
        String generation = hello.getString("generation");
        UserManager users = getSystemService(UserManager.class);
        long serial = users.getSerialNumberForUser(Process.myUserHandle());
        boolean unlocked = users.isUserUnlocked();
        sendRuntimeState(output, generation, unlocked, serial);
        boolean snapshotSent = false;
        if (unlocked) {
            sendEmptySnapshot(output, generation, serial);
            snapshotSent = true;
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
                throw new IOException("unexpected broker packet");
            }
            if (!snapshotSent
                    && (unlockObserved.get() || users.isUserUnlocked())) {
                sendRuntimeState(output, generation, true, serial);
                sendEmptySnapshot(output, generation, serial);
                snapshotSent = true;
            }
        }
    }

    private static void sendRuntimeState(
            OutputStream output,
            String generation,
            boolean unlocked,
            long serial) throws IOException, JSONException {
        send(output, new JSONObject()
                .put("protocolVersion", PROTOCOL_VERSION)
                .put("kind", "runtimeState")
                .put("generation", generation)
                .put("userUnlocked", unlocked)
                .put("userSerial", serial));
    }

    private static void sendEmptySnapshot(
            OutputStream output,
            String generation,
            long serial) throws IOException, JSONException {
        send(output, new JSONObject()
                .put("protocolVersion", PROTOCOL_VERSION)
                .put("kind", "replaceActivities")
                .put("generation", generation)
                .put("userUnlocked", true)
                .put("userSerial", serial)
                .put("activities", new org.json.JSONArray()));
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
