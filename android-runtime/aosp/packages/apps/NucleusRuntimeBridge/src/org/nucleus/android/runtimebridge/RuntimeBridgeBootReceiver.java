package org.nucleus.android.runtimebridge;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class RuntimeBridgeBootReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        RuntimeBridgeApplication.ensureStarted(context);
    }
}
