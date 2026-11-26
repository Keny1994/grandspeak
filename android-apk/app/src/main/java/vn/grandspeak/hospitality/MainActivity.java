package vn.grandspeak.hospitality;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.text.InputType;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.Toast;

import org.json.JSONObject;

import java.util.ArrayList;
import java.util.List;

public class MainActivity extends Activity {
    private static final String PREFS = "grandspeak_native_prefs";
    private static final String KEY_SERVER = "academy.serverURL";
    private static final String KEY_TOKEN = "academy.sessionToken";
    private static final String KEY_USER = "academy.cachedUserJSON";
    private static final int REQ_PERMS = 1001;
    private static final int REQ_FILE_CHOOSER = 1002;

    private WebView webView;
    private SharedPreferences prefs;
    private ValueCallback<Uri[]> filePathCallback;
    private PermissionRequest pendingWebPermission;
    private boolean showingOffline = false;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Window win = getWindow();
        win.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        win.setStatusBarColor(Color.parseColor("#12211c"));
        win.setNavigationBarColor(Color.parseColor("#12211c"));

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);

        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#181c22"));
        WebSettings ws = webView.getSettings();
        ws.setJavaScriptEnabled(true);
        ws.setDomStorageEnabled(true);
        ws.setDatabaseEnabled(true);
        ws.setMediaPlaybackRequiresUserGesture(false);
        ws.setAllowFileAccess(true);
        ws.setSupportMultipleWindows(false);
        ws.setMixedContentMode(WebSettings.MIXED_CONTENT_COMPATIBILITY_MODE);
        ws.setUserAgentString(ws.getUserAgentString() + " GrandSpeakAndroid/1.0");

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.addJavascriptInterface(new NativeBridge(), "AndroidNative");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageStarted(WebView view, String url, Bitmap favicon) {
                injectNativeSessionScript();
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                injectNativeSessionScript();
            }

            @Override
            public void onReceivedError(WebView view, WebResourceRequest request, WebResourceError error) {
                if (request != null && request.isForMainFrame()) {
                    String desc = error != null && error.getDescription() != null
                            ? error.getDescription().toString()
                            : "Lỗi kết nối mạng";
                    showOfflinePage(desc);
                }
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String scheme = uri.getScheme() != null ? uri.getScheme().toLowerCase() : "";
                if ("http".equals(scheme) || "https".equals(scheme)) {
                    String base = prefs.getString(KEY_SERVER, "");
                    Uri baseUri = base != null && !base.isEmpty() ? Uri.parse(base) : null;
                    if (baseUri != null && uri.getHost() != null && !uri.getHost().equalsIgnoreCase(baseUri.getHost())) {
                        startActivity(new Intent(Intent.ACTION_VIEW, uri));
                        return true;
                    }
                    return false;
                }
                try {
                    startActivity(new Intent(Intent.ACTION_VIEW, uri));
                } catch (Exception ignored) {}
                return true;
            }
        });

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public void onPermissionRequest(final PermissionRequest request) {
                runOnUiThread(() -> {
                    List<String> needed = new ArrayList<>();
                    for (String res : request.getResources()) {
                        if (PermissionRequest.RESOURCE_AUDIO_CAPTURE.equals(res)
                                && checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                            needed.add(Manifest.permission.RECORD_AUDIO);
                        }
                        if (PermissionRequest.RESOURCE_VIDEO_CAPTURE.equals(res)
                                && checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
                            needed.add(Manifest.permission.CAMERA);
                        }
                    }
                    if (!needed.isEmpty()) {
                        pendingWebPermission = request;
                        requestPermissions(needed.toArray(new String[0]), REQ_PERMS);
                    } else {
                        request.grant(request.getResources());
                    }
                });
            }

            @Override
            public boolean onShowFileChooser(WebView webView, ValueCallback<Uri[]> filePathCallback, FileChooserParams fileChooserParams) {
                if (MainActivity.this.filePathCallback != null) {
                    MainActivity.this.filePathCallback.onReceiveValue(null);
                }
                MainActivity.this.filePathCallback = filePathCallback;
                try {
                    Intent intent = fileChooserParams.createIntent();
                    startActivityForResult(intent, REQ_FILE_CHOOSER);
                } catch (Exception e) {
                    MainActivity.this.filePathCallback = null;
                    Toast.makeText(MainActivity.this, "Không thể mở bộ chọn tệp.", Toast.LENGTH_SHORT).show();
                    return false;
                }
                return true;
            }

            @Override
            public boolean onJsAlert(WebView view, String url, String message, JsResult result) {
                new AlertDialog.Builder(MainActivity.this)
                        .setMessage(message)
                        .setPositiveButton("OK", (d, w) -> result.confirm())
                        .setOnCancelListener(d -> result.cancel())
                        .show();
                return true;
            }

            @Override
            public boolean onJsConfirm(WebView view, String url, String message, JsResult result) {
                new AlertDialog.Builder(MainActivity.this)
                        .setMessage(message)
                        .setPositiveButton("Đồng ý", (d, w) -> result.confirm())
                        .setNegativeButton("Hủy", (d, w) -> result.cancel())
                        .setOnCancelListener(d -> result.cancel())
                        .show();
                return true;
            }

            @Override
            public boolean onJsPrompt(WebView view, String url, String message, String defaultValue, JsPromptResult result) {
                final EditText input = new EditText(MainActivity.this);
                input.setText(defaultValue);
                new AlertDialog.Builder(MainActivity.this)
                        .setMessage(message)
                        .setView(input)
                        .setPositiveButton("OK", (d, w) -> result.confirm(input.getText().toString()))
                        .setNegativeButton("Hủy", (d, w) -> result.cancel())
                        .setOnCancelListener(d -> result.cancel())
                        .show();
                return true;
            }
        });

        setContentView(webView);
        requestRuntimePermissionsIfNeeded();
        loadServer();
    }

    private void requestRuntimePermissionsIfNeeded() {
        List<String> reqs = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            reqs.add(Manifest.permission.RECORD_AUDIO);
        }
        if (checkSelfPermission(Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            reqs.add(Manifest.permission.CAMERA);
        }
        if (!reqs.isEmpty()) {
            requestPermissions(reqs.toArray(new String[0]), REQ_PERMS);
        }
    }

    private void injectNativeSessionScript() {
        if (showingOffline) return;
        String token = prefs.getString(KEY_TOKEN, "");
        String user = prefs.getString(KEY_USER, "");
        String server = prefs.getString(KEY_SERVER, "");
        String js = "(function(){"
                + "window.ACADEMY_NATIVE_SHELL=true;"
                + "window.ACADEMY_NATIVE_SERVER=" + JSONObject.quote(server) + ";"
                + "try{"
                + "var nt=" + JSONObject.quote(token) + ";"
                + "var nu=" + JSONObject.quote(user) + ";"
                + "if(nt && /^[a-f0-9]{64}$/i.test(nt) && !localStorage.getItem('academy_mobile_token_v1')){localStorage.setItem('academy_mobile_token_v1',nt);}"
                + "if(nu && !localStorage.getItem('academy_auth_user_v2')){localStorage.setItem('academy_auth_user_v2',nu);}"
                + "}catch(e){}"
                + "})();";
        webView.evaluateJavascript(js, null);
    }

    private boolean isPrivateOrLocalHost(String host) {
        String h = host.toLowerCase();
        if ("localhost".equals(h) || "127.0.0.1".equals(h) || "::1".equals(h) || h.endsWith(".local")) return true;
        if (h.startsWith("192.168.") || h.startsWith("10.")) return true;
        if (h.startsWith("172.")) {
            String[] parts = h.split("\\.");
            if (parts.length >= 2) {
                try {
                    int s = Integer.parseInt(parts[1]);
                    if (s >= 16 && s <= 31) return true;
                } catch (NumberFormatException ignored) {}
            }
        }
        return false;
    }

    private String normalizeServerUrl(String raw) {
        String text = raw == null ? "" : raw.trim();
        if (text.isEmpty()) return null;
        String lower = text.toLowerCase();
        if (!lower.startsWith("http://") && !lower.startsWith("https://")) {
            String hostPart = text.split("/", 2)[0];
            String hostOnly = hostPart.split(":", 2)[0];
            text = (isPrivateOrLocalHost(hostOnly) ? "http://" : "https://") + text;
        }
        while (text.endsWith("/")) {
            text = text.substring(0, text.length() - 1);
        }
        if (text.toLowerCase().endsWith("/app")) {
            text = text.substring(0, text.length() - 4);
        }
        try {
            Uri u = Uri.parse(text);
            if (u.getHost() == null || u.getHost().isEmpty()) return null;
            return text;
        } catch (Exception e) {
            return null;
        }
    }

    private void loadServer() {
        String base = prefs.getString(KEY_SERVER, "");
        if (base == null || base.isEmpty()) {
            promptForServer("Nhập địa chỉ máy chủ GrandSpeak (ví dụ https://grandspeak.ten-mien.vn hoặc http://192.168.1.10:3456)");
            return;
        }
        showingOffline = false;
        webView.loadUrl(base + "/app");
    }

    private void promptForServer(String msg) {
        runOnUiThread(() -> {
            final EditText input = new EditText(this);
            input.setInputType(InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI);
            input.setHint("https://grandspeak.ten-mien.vn");
            input.setText(prefs.getString(KEY_SERVER, ""));

            AlertDialog.Builder b = new AlertDialog.Builder(this)
                    .setTitle("Máy chủ GrandSpeak")
                    .setMessage(msg)
                    .setView(input)
                    .setCancelable(false)
                    .setPositiveButton("Kết nối", (d, w) -> {
                        String norm = normalizeServerUrl(input.getText().toString());
                        if (norm != null) {
                            String old = prefs.getString(KEY_SERVER, "");
                            SharedPreferences.Editor ed = prefs.edit();
                            if (old != null && !old.isEmpty() && !old.equals(norm)) {
                                ed.remove(KEY_TOKEN).remove(KEY_USER);
                            }
                            ed.putString(KEY_SERVER, norm).apply();
                            loadServer();
                        } else {
                            promptForServer("Địa chỉ chưa hợp lệ. Ví dụ: https://ten-mien.vn hoặc http://192.168.1.10:3456");
                        }
                    });
            String existing = prefs.getString(KEY_SERVER, "");
            if (existing != null && !existing.isEmpty()) {
                b.setNegativeButton("Hủy", null);
            }
            b.show();
        });
    }

    private String escHtml(String s) {
        if (s == null) return "";
        return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;");
    }

    private void showOfflinePage(String detail) {
        showingOffline = true;
        String srv = escHtml(prefs.getString(KEY_SERVER, "chưa cấu hình"));
        String reason = escHtml(detail);
        String html = "<!doctype html><html lang='vi'><head><meta charset='utf-8'>"
                + "<meta name='viewport' content='width=device-width,initial-scale=1'>"
                + "<style>html,body{margin:0;height:100%;background:#181c22;color:#f7f3e8;font-family:sans-serif}"
                + ".wrap{min-height:100%;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:28px;text-align:center;box-sizing:border-box}"
                + ".crest{width:76px;height:76px;border-radius:20px;background:linear-gradient(135deg,#f3d282,#b98728);display:flex;align-items:center;justify-content:center;font-size:34px;font-weight:800;color:#181c22;margin-bottom:16px}"
                + "code{background:rgba(255,255,255,.12);padding:3px 8px;border-radius:6px;word-break:break-all}"
                + "button{margin:12px 6px 0;padding:12px 20px;border-radius:12px;border:0;font-size:14px;font-weight:700}"
                + ".gold{background:linear-gradient(135deg,#f3d282,#c99a3b);color:#181c22}"
                + ".ghost{background:rgba(255,255,255,.14);color:#fff}</style></head><body><div class='wrap'>"
                + "<div class='crest'>G</div>"
                + "<h1>Không kết nối được GrandSpeak</h1>"
                + "<p>Kiểm tra Wi-Fi/4G và đảm bảo máy chủ đang chạy.</p>"
                + "<p>Máy chủ: <code>" + srv + "</code></p>"
                + "<small style='color:#9aa6b8'>" + reason + "</small><div>"
                + "<button class='gold' onclick=\"AndroidNative.postMessage('retry')\">Thử kết nối lại</button>"
                + "<button class='ghost' onclick=\"AndroidNative.postMessage('change')\">Đổi địa chỉ máy chủ</button>"
                + "</div></div></body></html>";
        webView.loadDataWithBaseURL(null, html, "text/html", "utf-8", null);
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_PERMS && pendingWebPermission != null) {
            boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            if (granted) {
                pendingWebPermission.grant(pendingWebPermission.getResources());
            } else {
                pendingWebPermission.deny();
            }
            pendingWebPermission = null;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_FILE_CHOOSER && filePathCallback != null) {
            Uri[] res = null;
            if (resultCode == RESULT_OK && data != null) {
                String dataString = data.getDataString();
                if (dataString != null) res = new Uri[]{Uri.parse(dataString)};
            }
            filePathCallback.onReceiveValue(res);
            filePathCallback = null;
        }
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }

    private class NativeBridge {
        @JavascriptInterface
        public void postMessage(String raw) {
            if (raw == null) return;
            String msg = raw.trim();
            if (msg.startsWith("{")) {
                try {
                    JSONObject obj = new JSONObject(msg);
                    String cmd = obj.optString("cmd", "");
                    if ("saveSession".equals(cmd)) {
                        SharedPreferences.Editor ed = prefs.edit();
                        String tk = obj.optString("token", "");
                        String uj = obj.optString("userJson", "");
                        if (!tk.isEmpty()) ed.putString(KEY_TOKEN, tk);
                        if (!uj.isEmpty()) ed.putString(KEY_USER, uj);
                        ed.apply();
                    } else if ("clearSession".equals(cmd)) {
                        prefs.edit().remove(KEY_TOKEN).remove(KEY_USER).apply();
                    }
                } catch (Exception ignored) {}
                return;
            }
            if ("retry".equals(msg)) {
                runOnUiThread(MainActivity.this::loadServer);
            } else if ("change".equals(msg)) {
                promptForServer("Nhập địa chỉ máy chủ GrandSpeak mới:");
            } else if ("clearSession".equals(msg)) {
                prefs.edit().remove(KEY_TOKEN).remove(KEY_USER).apply();
            }
        }
    }
}
