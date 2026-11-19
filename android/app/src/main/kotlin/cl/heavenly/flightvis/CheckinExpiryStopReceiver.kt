package cl.heavenly.flightvis

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log
import org.traccar.client.sharedTracker

/// Stops the native tracker when check-in expires while the Flutter UI is gone.
class CheckinExpiryStopReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent?) {
        try {
            sharedTracker()?.stop()
        } catch (e: Exception) {
            Log.w(TAG, "check-in expiry stop failed", e)
        }
    }

    companion object {
        const val ACTION_STOP = "cl.heavenly.flightvis.action.CHECKIN_EXPIRED_STOP"
        private const val TAG = "CheckinExpiryStop"
    }
}