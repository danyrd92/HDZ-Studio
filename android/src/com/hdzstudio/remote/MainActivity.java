package com.hdzstudio.remote;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Base64;
import android.view.Gravity;
import android.view.View;
import android.view.WindowInsets;
import android.view.inputmethod.EditorInfo;
import android.webkit.JavascriptInterface;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Button;
import android.widget.EditText;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import android.widget.Toast;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.net.NetworkInterface;
import java.net.Socket;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.ExecutorCompletionService;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

/**
 * Carcasa Android de la web de control remoto. La interfaz la sirve el propio PC, así que cada
 * versión nueva de HDZ Studio llega a la app sin reinstalarla. Lo nativo es lo que un navegador
 * no hace: encontrar el PC, guardar los .torrent y avisar con la app cerrada.
 */
public class MainActivity extends Activity {
    static final String PREFS = "hdz";
    static final String KEY_URL = "url";
    static final String KEY_TOKEN = "token";
    private static final int DEFAULT_PORT = 8787;
    private static final int BG = Color.rgb(15, 17, 21);
    private static final int TEXT = Color.rgb(233, 236, 241);
    private static final int SUB = Color.rgb(154, 163, 175);

    static volatile boolean visible = false;

    private final Handler ui = new Handler(Looper.getMainLooper());
    private SharedPreferences prefs;
    private FrameLayout root;
    private WebView web;
    private String origin = "";
    private TextView setupStatus;
    private EditText setupInput;
    private volatile boolean searching = false;

    private static final String DOWNLOAD_HOOK =
        "(function(){if(window.__hdzHook)return;window.__hdzHook=1;"
        + "document.addEventListener('click',function(e){"
        + "var a=e.target&&e.target.closest&&e.target.closest('a[download][href^=\"blob:\"]');if(!a)return;"
        + "e.preventDefault();e.stopImmediatePropagation();var n=a.download;"
        + "fetch(a.href).then(function(r){return r.blob()}).then(function(b){var f=new FileReader();"
        + "f.onload=function(){HDZAndroid.saveFile(n,String(f.result).split(',')[1])};f.readAsDataURL(b)})"
        + ".catch(function(){HDZAndroid.saveFailed()});},true);})();";

    // La app ya aparta la web de las barras del sistema; sin esto la web reservaría ese hueco otra vez.
    private static final String SAFE_AREA_FIX =
        "(function(){if(document.getElementById('hdzSafeArea'))return;var s=document.createElement('style');"
        + "s.id='hdzSafeArea';s.textContent=':root{--safe-t:0px!important;--safe-b:0px!important}';"
        + "(document.head||document.documentElement).appendChild(s);})();";

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        root = new FrameLayout(this);
        root.setBackgroundColor(BG);
        // Android 15 dibuja bajo las barras del sistema: el relleno evita que tapen la interfaz y el teclado.
        root.setOnApplyWindowInsetsListener((view, insets) -> {
            if (Build.VERSION.SDK_INT >= 30) {
                android.graphics.Insets bars = insets.getInsets(WindowInsets.Type.systemBars() | WindowInsets.Type.ime());
                view.setPadding(bars.left, bars.top, bars.right, bars.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(), insets.getSystemWindowInsetTop(),
                    insets.getSystemWindowInsetRight(), insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
        setContentView(root);
        String saved = prefs.getString(KEY_URL, "");
        if (saved.isEmpty()) showSetup("", "Busca tu PC en la red o escribe su dirección.");
        else showWeb(saved);
        if (Build.VERSION.SDK_INT >= 33 && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
            requestPermissions(new String[]{Manifest.permission.POST_NOTIFICATIONS}, 1);
        }
    }

    @Override
    protected void onResume() {
        super.onResume();
        visible = true;
        startMonitor();
    }

    @Override
    protected void onStop() {
        visible = false;
        super.onStop();
    }

    @Override
    protected void onDestroy() {
        destroyWeb();
        super.onDestroy();
    }

    private void startMonitor() {
        if (prefs.getString(KEY_URL, "").isEmpty() || prefs.getString(KEY_TOKEN, "").isEmpty()) return;
        try {
            startForegroundService(new Intent(this, MonitorService.class));
        } catch (RuntimeException ignored) {
            // Sin aviso en segundo plano la app sigue siendo utilizable.
        }
    }

    @Override
    public void onBackPressed() {
        if (web == null) {
            super.onBackPressed();
            return;
        }
        new AlertDialog.Builder(this)
            .setTitle("HDZ Studio")
            .setItems(new CharSequence[]{"Salir", "Recargar", "Cambiar de PC"}, (d, which) -> {
                if (which == 0) moveTaskToBack(true);
                else if (which == 1) web.reload();
                else showSetup(prefs.getString(KEY_URL, ""), "Busca tu PC en la red o escribe su dirección.");
            })
            .show();
    }

    // ---------- Pantalla de conexión ----------

    private void showSetup(String address, String message) {
        destroyWeb();
        root.removeAllViews();
        int pad = dp(24);
        LinearLayout box = new LinearLayout(this);
        box.setOrientation(LinearLayout.VERTICAL);
        box.setGravity(Gravity.CENTER_VERTICAL);
        box.setPadding(pad, pad, pad, pad);

        TextView title = new TextView(this);
        title.setText("Conectar con HDZ Studio");
        title.setTextColor(TEXT);
        title.setTextSize(24);
        box.addView(title);

        TextView help = new TextView(this);
        help.setText("Activa «Control remoto» en HDZ Studio › Ajustes, con el móvil en la misma red que el PC.");
        help.setTextColor(SUB);
        help.setTextSize(15);
        help.setPadding(0, dp(8), 0, dp(18));
        box.addView(help);

        setupInput = new EditText(this);
        setupInput.setHint("192.168.1.48:8787");
        setupInput.setHintTextColor(SUB);
        setupInput.setTextColor(TEXT);
        setupInput.setSingleLine(true);
        setupInput.setInputType(EditorInfo.TYPE_CLASS_TEXT | EditorInfo.TYPE_TEXT_VARIATION_URI);
        setupInput.setText(address.replaceFirst("^http://", ""));
        box.addView(setupInput);

        Button connect = new Button(this);
        connect.setText("Conectar");
        connect.setOnClickListener(v -> connectManual());
        box.addView(connect);

        Button search = new Button(this);
        search.setText("Buscar mi PC en la red");
        search.setOnClickListener(v -> searchNetwork());
        box.addView(search);

        setupStatus = new TextView(this);
        setupStatus.setText(message);
        setupStatus.setTextColor(SUB);
        setupStatus.setTextSize(15);
        setupStatus.setPadding(0, dp(16), 0, 0);
        box.addView(setupStatus);
        root.addView(box);
    }

    private void connectManual() {
        final String url = normalize(setupInput.getText().toString());
        if (url == null) {
            setupStatus.setText("Escribe la dirección que muestra el PC, por ejemplo 192.168.1.48:8787.");
            return;
        }
        setupStatus.setText("Conectando…");
        new Thread(() -> {
            final boolean ok = isHdz(url, 4000);
            ui.post(() -> {
                if (ok) connected(url);
                else if (setupStatus != null) setupStatus.setText("No responde HDZ Studio en esa dirección. Comprueba que el programa está abierto y el control remoto activado.");
            });
        }).start();
    }

    static String normalize(String raw) {
        String text = raw == null ? "" : raw.trim();
        if (text.isEmpty()) return null;
        text = text.replaceFirst("^(?i)https?://", "").replaceFirst("/.*$", "");
        if (!text.matches("[A-Za-z0-9.\\-]+(:\\d{1,5})?")) return null;
        if (!text.contains(":")) text += ":" + DEFAULT_PORT;
        return "http://" + text;
    }

    private void connected(String url) {
        prefs.edit().putString(KEY_URL, url).apply();
        showWeb(url);
        startMonitor();
    }

    private void searchNetwork() {
        if (searching) return;
        searching = true;
        setupStatus.setText("Buscando HDZ Studio en tu red…");
        new Thread(() -> {
            final String found = scan();
            searching = false;
            ui.post(() -> {
                if (found != null) connected(found);
                else if (setupStatus != null) setupStatus.setText("No lo he encontrado. Comprueba que el programa está abierto, o escribe la dirección que aparece en Ajustes › Control remoto.");
            });
        }).start();
    }

    /** Prueba el puerto del programa en cada dirección de las redes /24 del móvil. */
    private String scan() {
        List<String> prefixes = new ArrayList<>();
        try {
            for (NetworkInterface nic : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!nic.isUp() || nic.isLoopback()) continue;
                for (InetAddress address : Collections.list(nic.getInetAddresses())) {
                    if (address instanceof Inet4Address && address.isSiteLocalAddress()) {
                        String ip = address.getHostAddress();
                        String prefix = ip.substring(0, ip.lastIndexOf('.') + 1);
                        if (!prefixes.contains(prefix)) prefixes.add(prefix);
                    }
                }
            }
        } catch (IOException e) {
            return null;
        }
        ExecutorService pool = Executors.newFixedThreadPool(40);
        try {
            ExecutorCompletionService<String> done = new ExecutorCompletionService<>(pool);
            int total = 0;
            for (String prefix : prefixes) {
                for (int i = 1; i < 255; i++) {
                    final String host = prefix + i;
                    done.submit(() -> {
                        try (Socket socket = new Socket()) {
                            socket.connect(new InetSocketAddress(host, DEFAULT_PORT), 500);
                        } catch (IOException e) {
                            return null;
                        }
                        String url = "http://" + host + ":" + DEFAULT_PORT;
                        return isHdz(url, 3000) ? url : null;
                    });
                    total++;
                }
            }
            for (int i = 0; i < total; i++) {
                String result = done.take().get();
                if (result != null) return result;
            }
        } catch (Exception ignored) {
            // Se informa como «no encontrado».
        } finally {
            pool.shutdownNow();
        }
        return null;
    }

    private static boolean isHdz(String url, int timeout) {
        HttpURLConnection connection = null;
        try {
            connection = (HttpURLConnection) new URL(url + "/").openConnection();
            connection.setConnectTimeout(timeout);
            connection.setReadTimeout(timeout);
            if (connection.getResponseCode() != 200) return false;
            byte[] buffer = new byte[4096];
            try (InputStream in = connection.getInputStream()) {
                int total = 0, read;
                while (total < buffer.length && (read = in.read(buffer, total, buffer.length - total)) > 0) total += read;
                return new String(buffer, 0, total, StandardCharsets.UTF_8).contains("HDZ Studio");
            }
        } catch (IOException e) {
            return false;
        } finally {
            if (connection != null) connection.disconnect();
        }
    }

    // ---------- Interfaz web ----------

    private void showWeb(String url) {
        setupStatus = null;
        setupInput = null;
        destroyWeb();
        root.removeAllViews();
        Uri parsed = Uri.parse(url);
        origin = parsed.getScheme() + "://" + parsed.getAuthority();
        web = new WebView(this);
        web.setBackgroundColor(BG);
        WebSettings settings = web.getSettings();
        settings.setJavaScriptEnabled(true);
        settings.setDomStorageEnabled(true);
        settings.setTextZoom(100);
        web.addJavascriptInterface(new Bridge(), "HDZAndroid");
        web.setWebChromeClient(new WebChromeClient());
        web.setWebViewClient(new WebViewClient() {
            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri target = request.getUrl();
                if (origin.equals(target.getScheme() + "://" + target.getAuthority())) return false;
                // La página del tracker y demás enlaces externos van al navegador; así el puente
                // nativo solo existe en páginas servidas por el PC emparejado.
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, target));
                } catch (RuntimeException e) {
                    toast("No hay ninguna app para abrir ese enlace.");
                }
                return true;
            }

            @Override
            public void onPageCommitVisible(WebView view, String page) {
                view.evaluateJavascript(SAFE_AREA_FIX, null);
            }

            @Override
            public void onPageFinished(WebView view, String page) {
                view.evaluateJavascript(SAFE_AREA_FIX, null);
                view.evaluateJavascript(DOWNLOAD_HOOK, null);
                view.evaluateJavascript("localStorage.getItem('hdz_panel_token')", value -> rememberToken(value));
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request.isForMainFrame()) {
                    showSetup(prefs.getString(KEY_URL, ""), "No se pudo conectar con el PC. Comprueba que HDZ Studio está abierto y que estás en la misma red.");
                }
            }
        });
        root.addView(web);
        web.loadUrl(url + "/");
    }

    private void rememberToken(String json) {
        String token = json == null ? "" : json.replace("\"", "");
        if (!token.matches("[0-9a-f]{64}")) return;
        if (!token.equals(prefs.getString(KEY_TOKEN, ""))) {
            prefs.edit().putString(KEY_TOKEN, token).apply();
            if (visible) startMonitor();
        }
    }

    private void destroyWeb() {
        if (web == null) return;
        root.removeView(web);
        web.destroy();
        web = null;
    }

    private void toast(String message) {
        Toast.makeText(this, message, Toast.LENGTH_LONG).show();
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    /** Puente mínimo: lo único que la web puede pedir es guardar un .torrent en Descargas. */
    private final class Bridge {
        @JavascriptInterface
        public void saveFile(String name, String base64) {
            String clean = name == null ? "" : name.replaceAll("[\\\\/:*?\"<>|\\p{Cntrl}]", "_").trim();
            if (!clean.toLowerCase(java.util.Locale.ROOT).endsWith(".torrent") || base64 == null) {
                saveFailed();
                return;
            }
            try {
                byte[] data = Base64.decode(base64, Base64.DEFAULT);
                ContentResolver resolver = getContentResolver();
                ContentValues values = new ContentValues();
                values.put(MediaStore.Downloads.DISPLAY_NAME, clean);
                values.put(MediaStore.Downloads.MIME_TYPE, "application/x-bittorrent");
                Uri item = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                if (item == null) throw new IOException("sin destino");
                try (OutputStream out = resolver.openOutputStream(item)) {
                    if (out == null) throw new IOException("sin destino");
                    out.write(data);
                }
                ui.post(() -> toast("Guardado en Descargas: " + clean));
            } catch (IOException | RuntimeException e) {
                saveFailed();
            }
        }

        @JavascriptInterface
        public void saveFailed() {
            ui.post(() -> toast("No se pudo guardar el torrent."));
        }
    }
}
