package com.hdzstudio.remote;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.ServiceInfo;
import android.os.Build;
import android.os.IBinder;

import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;

/**
 * Sigue el proceso del PC con la app en segundo plano. Con la app delante no consulta nada
 * (la web ya lo hace): el servidor del PC atiende las peticiones de una en una.
 */
public class MonitorService extends Service {
    private static final String CHANNEL_PROGRESS = "progreso";
    private static final String CHANNEL_DONE = "terminado";
    private static final int ID_PROGRESS = 1;
    private static final int ID_DONE = 2;
    private static final long POLL_MS = 5000;
    private static final int MAX_FAILURES = 24; // unos 2 minutos sin PC

    private Thread worker;

    @Override
    public void onCreate() {
        super.onCreate();
        NotificationManager manager = getSystemService(NotificationManager.class);
        NotificationChannel progress = new NotificationChannel(CHANNEL_PROGRESS, "Progreso", NotificationManager.IMPORTANCE_LOW);
        NotificationChannel done = new NotificationChannel(CHANNEL_DONE, "Proceso terminado", NotificationManager.IMPORTANCE_DEFAULT);
        manager.createNotificationChannel(progress);
        manager.createNotificationChannel(done);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        Notification first = progressNotification("Conectado con tu PC", "", -1);
        if (Build.VERSION.SDK_INT >= 29) startForeground(ID_PROGRESS, first, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC);
        else startForeground(ID_PROGRESS, first);
        if (worker == null || !worker.isAlive()) {
            worker = new Thread(this::loop, "hdz-monitor");
            worker.start();
        }
        return START_NOT_STICKY;
    }

    private void loop() {
        boolean wasActive = false;
        int failures = 0;
        String lastLabel = "";
        try {
            while (!Thread.currentThread().isInterrupted()) {
                Thread.sleep(POLL_MS);
                if (MainActivity.visible) {
                    // Al volver a segundo plano se parte de una lectura nueva, sin avisos falsos.
                    wasActive = false;
                    failures = 0;
                    continue;
                }
                JSONObject state;
                try {
                    state = fetchState();
                } catch (Unauthorized e) {
                    getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE).edit().remove(MainActivity.KEY_TOKEN).apply();
                    break;
                } catch (IOException | JSONException e) {
                    if (++failures >= MAX_FAILURES) break;
                    continue;
                }
                failures = 0;
                JSONObject data = state.optJSONObject("data");
                if (data == null) continue;
                JSONObject montaje = data.optJSONObject("montaje");
                JSONArray tareas = data.optJSONArray("tareas");
                boolean mounting = montaje != null && montaje.optBoolean("activo");
                boolean tasks = tareas != null && tareas.length() > 0;
                if (mounting) {
                    lastLabel = "Proceso terminado";
                    int queued = montaje.optInt("enCola");
                    String phase = montaje.optString("fase") + (queued > 0 ? " · " + queued + " en cola" : "");
                    show(progressNotification("Procesando", phase, montaje.optInt("pct")));
                } else if (tasks) {
                    JSONObject task = tareas.optJSONObject(0);
                    String title = task == null ? "Tarea en curso" : task.optString("titulo", "Tarea en curso");
                    lastLabel = title + ": terminado";
                    show(progressNotification(title, task == null ? "" : task.optString("fase"), task == null ? -1 : task.optInt("pct")));
                } else {
                    if (wasActive) notifyDone(lastLabel, data.optJSONObject("montaje") != null ? data.optJSONObject("montaje").optString("fase") : "");
                    break; // Sin trabajo y con la app cerrada no hay nada que seguir.
                }
                wasActive = true;
            }
        } catch (InterruptedException ignored) {
            return;
        }
        stopForeground(STOP_FOREGROUND_REMOVE);
        stopSelf();
    }

    private static final class Unauthorized extends Exception { }

    private JSONObject fetchState() throws IOException, JSONException, Unauthorized {
        SharedPreferences prefs = getSharedPreferences(MainActivity.PREFS, MODE_PRIVATE);
        String url = prefs.getString(MainActivity.KEY_URL, "");
        String token = prefs.getString(MainActivity.KEY_TOKEN, "");
        if (url.isEmpty() || token.isEmpty()) throw new Unauthorized();
        HttpURLConnection connection = (HttpURLConnection) new URL(url + "/api/state").openConnection();
        try {
            connection.setConnectTimeout(5000);
            connection.setReadTimeout(15000);
            connection.setRequestProperty("X-HDZ-Panel", token);
            int code = connection.getResponseCode();
            if (code == 401) throw new Unauthorized();
            if (code != 200) throw new IOException("HTTP " + code);
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            byte[] buffer = new byte[16384];
            try (InputStream in = connection.getInputStream()) {
                int read;
                while ((read = in.read(buffer)) > 0) body.write(buffer, 0, read);
            }
            return new JSONObject(new String(body.toByteArray(), StandardCharsets.UTF_8));
        } finally {
            connection.disconnect();
        }
    }

    private PendingIntent openApp() {
        Intent open = new Intent(this, MainActivity.class).setFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP);
        return PendingIntent.getActivity(this, 0, open, PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT);
    }

    private Notification progressNotification(String title, String text, int percent) {
        Notification.Builder builder = new Notification.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title)
            .setContentText(text)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(openApp());
        if (percent >= 0) builder.setProgress(100, Math.min(100, percent), false);
        return builder.build();
    }

    private void show(Notification notification) {
        getSystemService(NotificationManager.class).notify(ID_PROGRESS, notification);
    }

    private void notifyDone(String title, String text) {
        Notification done = new Notification.Builder(this, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(title.isEmpty() ? "Proceso terminado" : title)
            .setContentText(text)
            .setAutoCancel(true)
            .setContentIntent(openApp())
            .build();
        getSystemService(NotificationManager.class).notify(ID_DONE, done);
    }

    // Android 15 limita este tipo de servicio a 6 horas diarias.
    @Override
    public void onTimeout(int startId, int reason) {
        stopSelf();
    }

    @Override
    public void onDestroy() {
        if (worker != null) worker.interrupt();
        super.onDestroy();
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }
}
