package vn.grandspeak.hospitality;

import android.Manifest;
import android.annotation.SuppressLint;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.SharedPreferences;
import android.content.pm.PackageManager;
import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.speech.RecognitionListener;
import android.speech.RecognizerIntent;
import android.speech.SpeechRecognizer;
import android.speech.tts.TextToSpeech;
import android.speech.tts.UtteranceProgressListener;
import android.view.Window;
import android.view.WindowManager;
import android.webkit.CookieManager;
import android.webkit.JavascriptInterface;
import android.webkit.JsPromptResult;
import android.webkit.JsResult;
import android.webkit.PermissionRequest;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.EditText;
import android.widget.Toast;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/**
 * Ứng dụng GrandSpeak Android Độc lập 100% (Standalone APK):
 * - Đóng gói toàn bộ dữ liệu Web + Resort 3D trong assets/web, phục vụ qua loopback cố định 127.0.0.1:34560 (không cần máy chủ ngoài).
 * - Nhận diện giọng nói tiếng Anh trực tiếp trên Micro điện thoại qua Android SpeechRecognizer.
 * - Phát âm chuẩn Anh – Mỹ / Anh – Anh / Tiếng Việt trực tiếp qua Android TextToSpeech.
 */
public class MainActivity extends Activity {
    private static final String PREFS = "grandspeak_native_prefs";
    private static final String KEY_STANDALONE_DB = "grandspeak.standaloneDB.v1";
    private static final String KEY_TOKEN = "academy.sessionToken";
    private static final String KEY_USER = "academy.cachedUserJSON";
    private static final int REQ_PERMS = 1001;
    private static final int REQ_FILE_CHOOSER = 1002;

    private WebView webView;
    private SharedPreferences prefs;
    private ValueCallback<Uri[]> filePathCallback;
    private PermissionRequest pendingWebPermission;
    private LocalAssetServer assetServer;
    private SpeechRecognizer speechRecognizer;
    private TextToSpeech tts;
    private boolean ttsReady = false;
    private int activeSpeechReqId = 0;

    @SuppressLint("SetJavaScriptEnabled")
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Window win = getWindow();
        win.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
        win.setStatusBarColor(Color.parseColor("#12211c"));
        win.setNavigationBarColor(Color.parseColor("#12211c"));

        prefs = getSharedPreferences(PREFS, MODE_PRIVATE);
        initTts();

        assetServer = new LocalAssetServer(getAssets());
        int port = assetServer.start();

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
        ws.setUserAgentString(ws.getUserAgentString() + " GrandSpeakAndroidStandalone/2.0");

        CookieManager.getInstance().setAcceptCookie(true);
        CookieManager.getInstance().setAcceptThirdPartyCookies(webView, true);

        webView.addJavascriptInterface(new NativeBridge(), "AndroidNative");

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public void onPageStarted(WebView view, String url, Bitmap favicon) {
                injectStandaloneBridgeScript();
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                injectStandaloneBridgeScript();
            }

            @Override
            public boolean shouldOverrideUrlLoading(WebView view, WebResourceRequest request) {
                Uri uri = request.getUrl();
                String host = uri.getHost() != null ? uri.getHost().toLowerCase() : "";
                if ("127.0.0.1".equals(host) || "localhost".equals(host)) {
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
            public boolean onShowFileChooser(WebView wv, ValueCallback<Uri[]> cb, FileChooserParams params) {
                if (MainActivity.this.filePathCallback != null) {
                    MainActivity.this.filePathCallback.onReceiveValue(null);
                }
                MainActivity.this.filePathCallback = cb;
                try {
                    startActivityForResult(params.createIntent(), REQ_FILE_CHOOSER);
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
        webView.loadUrl("http://127.0.0.1:" + port + "/app");
    }

    private void initTts() {
        tts = new TextToSpeech(this, status -> {
            if (status == TextToSpeech.SUCCESS) {
                ttsReady = true;
                tts.setLanguage(Locale.US);
                tts.setOnUtteranceProgressListener(new UtteranceProgressListener() {
                    @Override
                    public void onStart(String utteranceId) {}

                    @Override
                    public void onDone(String utteranceId) {
                        notifyTtsEnd(utteranceId);
                    }

                    @Override
                    public void onError(String utteranceId) {
                        notifyTtsEnd(utteranceId);
                    }
                });
            }
        });
    }

    private void notifyTtsEnd(String utteranceId) {
        try {
            int id = Integer.parseInt(utteranceId.replace("utt_", ""));
            JSONObject ev = new JSONObject();
            ev.put("__gsNativeEvent", true);
            ev.put("kind", "ttsEnd");
            ev.put("id", id);
            emitToJs(ev);
        } catch (Exception ignored) {}
    }

    private void emitToJs(final JSONObject ev) {
        runOnUiThread(() -> {
            if (webView != null) {
                webView.evaluateJavascript("window.postMessage(" + ev.toString() + ", '*');", null);
            }
        });
    }

    private void requestRuntimePermissionsIfNeeded() {
        List<String> reqs = new ArrayList<>();
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            reqs.add(Manifest.permission.RECORD_AUDIO);
        }
        if (!reqs.isEmpty()) {
            requestPermissions(reqs.toArray(new String[0]), REQ_PERMS);
        }
    }

    private void injectStandaloneBridgeScript() {
        String dbJson = prefs.getString(KEY_STANDALONE_DB, "");
        String token = prefs.getString(KEY_TOKEN, "");
        String user = prefs.getString(KEY_USER, "");
        String js = "(function(){"
                + "if(window.__gsAndroidInjected)return;window.__gsAndroidInjected=true;"
                + "window.ACADEMY_NATIVE_SHELL=true;"
                + "window.ACADEMY_STANDALONE=true;"
                + "window.ACADEMY_NATIVE_SPEECH=true;"
                + "try{"
                + "var sdb=" + JSONObject.quote(dbJson) + ";"
                + "if(sdb && !localStorage.getItem('grandspeak_standalone_db_v1')){localStorage.setItem('grandspeak_standalone_db_v1',sdb);}"
                + "var nt=" + JSONObject.quote(token) + ";"
                + "var nu=" + JSONObject.quote(user) + ";"
                + "if(nt && !localStorage.getItem('academy_mobile_token_v1')){localStorage.setItem('academy_mobile_token_v1',nt);}"
                + "if(nu && !localStorage.getItem('academy_auth_user_v2')){localStorage.setItem('academy_auth_user_v2',nu);}"
                + "}catch(e){}"
                + "function sendNative(obj){try{window.AndroidNative.postMessage(JSON.stringify(obj));}catch(e){}}"
                + "window.addEventListener('message',function(ev){if(ev.data&&ev.data.__gsForwardNative){sendNative(ev.data.__gsForwardNative);}});"
                + "var ttsSeq=0,ttsMap={};"
                + "window.academyNativeSpeak=function(text,lang,rate,onStart,onEnd){"
                + "var id=++ttsSeq;ttsMap[id]=onEnd;if(typeof onStart==='function'){try{onStart();}catch(e){}}"
                + "sendNative({cmd:'speak',id:id,text:String(text||''),lang:String(lang||'en-US'),rate:Number(rate||1.0)});};"
                + "window.academyNativeStopSpeak=function(){sendNative({cmd:'stopSpeak'});};"
                + "if(window.speechSynthesis){"
                + "window.speechSynthesis.speak=function(u){if(!u||!u.text)return;window.academyNativeSpeak(u.text,u.lang||'en-US',u.rate||1.0,function(){if(u.onstart)u.onstart({});},function(){if(u.onend)u.onend({});});};"
                + "window.speechSynthesis.cancel=function(){window.academyNativeStopSpeak();};}"
                + "var srSeq=200,srMap={};"
                + "function AndroidSpeechRec(){this.lang='en-US';this.interimResults=false;this.continuous=false;this.maxAlternatives=1;this._l={};this._id=++srSeq;}"
                + "AndroidSpeechRec.prototype.addEventListener=function(t,f){(this._l[t]=this._l[t]||[]).push(f);};"
                + "AndroidSpeechRec.prototype.removeEventListener=function(t,f){if(this._l[t])this._l[t]=this._l[t].filter(function(x){return x!==f;});};"
                + "AndroidSpeechRec.prototype._emit=function(t,ev){if(typeof this['on'+t]==='function'){try{this['on'+t](ev);}catch(e){}}var a=this._l[t]||[];for(var i=0;i<a.length;i++){try{a[i](ev);}catch(e){}}};"
                + "AndroidSpeechRec.prototype.start=function(){srMap[this._id]=this;sendNative({cmd:'startSpeech',reqId:this._id,lang:this.lang||'en-US',interim:Boolean(this.interimResults)});var s=this;setTimeout(function(){s._emit('start',{type:'start'});},30);};"
                + "AndroidSpeechRec.prototype.stop=function(){sendNative({cmd:'stopSpeech',reqId:this._id});};"
                + "AndroidSpeechRec.prototype.abort=function(){sendNative({cmd:'stopSpeech',reqId:this._id});};"
                + "window.SpeechRecognition=AndroidSpeechRec;window.webkitSpeechRecognition=AndroidSpeechRec;"
                + "function installIntoIframes(){"
                + "var fs=document.querySelectorAll?document.querySelectorAll('iframe'):[];"
                + "for(var i=0;i<fs.length;i++){try{var cw=fs[i].contentWindow;if(cw&&!cw.__gsChildBridged){cw.__gsChildBridged=true;cw.ACADEMY_STANDALONE=true;cw.ACADEMY_NATIVE_SPEECH=true;cw.SpeechRecognition=AndroidSpeechRec;cw.webkitSpeechRecognition=AndroidSpeechRec;cw.academyNativeSpeak=window.academyNativeSpeak;cw.academyNativeStopSpeak=window.academyNativeStopSpeak;if(cw.speechSynthesis){cw.speechSynthesis.speak=window.speechSynthesis.speak;cw.speechSynthesis.cancel=window.speechSynthesis.cancel;}}}catch(e){}}"
                + "}"
                + "setInterval(installIntoIframes,800);"
                + "window.addEventListener('message',function(ev){var d=ev.data;if(!d||!d.__gsNativeEvent)return;"
                + "if(d.kind==='ttsEnd'){var fn=ttsMap[d.id];delete ttsMap[d.id];if(typeof fn==='function'){try{fn();}catch(e){}}}"
                + "else if(d.kind==='srResult'){var inst=srMap[d.reqId];if(!inst)return;if(!d.isFinal&&!inst.interimResults)return;"
                + "var item=[{transcript:d.transcript||'',confidence:0.95}];item.isFinal=Boolean(d.isFinal);var res=[item];res.resultIndex=0;"
                + "window.__lastLiveSpeechTranscript=d.transcript||'';inst._emit('result',{type:'result',resultIndex:0,results:res});}"
                + "else if(d.kind==='srError'){var ie=srMap[d.reqId];if(!ie)return;delete srMap[d.reqId];ie._emit('error',{type:'error',error:d.error||'no-speech'});ie._emit('end',{type:'end'});}"
                + "else if(d.kind==='srEnd'){var idn=srMap[d.reqId];if(!idn)return;delete srMap[d.reqId];idn._emit('end',{type:'end'});}"
                + "});"
                + "})();";
        webView.evaluateJavascript(js, null);
    }

    private void startAndroidSpeech(final int reqId, final String lang) {
        runOnUiThread(() -> {
            if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
                requestPermissions(new String[]{Manifest.permission.RECORD_AUDIO}, REQ_PERMS);
                sendSpeechError(reqId, "not-allowed");
                return;
            }
            stopAndroidSpeech(false);
            if (tts != null) tts.stop();
            activeSpeechReqId = reqId;
            try {
                speechRecognizer = SpeechRecognizer.createSpeechRecognizer(MainActivity.this);
                speechRecognizer.setRecognitionListener(new RecognitionListener() {
                    @Override public void onReadyForSpeech(Bundle params) {}
                    @Override public void onBeginningOfSpeech() {}
                    @Override public void onRmsChanged(float rmsdB) {}
                    @Override public void onBufferReceived(byte[] buffer) {}
                    @Override public void onEndOfSpeech() {}

                    @Override
                    public void onError(int error) {
                        if (activeSpeechReqId != reqId) return;
                        activeSpeechReqId = 0;
                        sendSpeechError(reqId, error == SpeechRecognizer.ERROR_INSUFFICIENT_PERMISSIONS ? "not-allowed" : "no-speech");
                    }

                    @Override
                    public void onResults(Bundle results) {
                        if (activeSpeechReqId != reqId) return;
                        ArrayList<String> matches = results.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                        String text = (matches != null && !matches.isEmpty()) ? matches.get(0) : "";
                        sendSpeechResult(reqId, text, true);
                        stopAndroidSpeech(true);
                    }

                    @Override
                    public void onPartialResults(Bundle partialResults) {
                        if (activeSpeechReqId != reqId) return;
                        ArrayList<String> matches = partialResults.getStringArrayList(SpeechRecognizer.RESULTS_RECOGNITION);
                        if (matches != null && !matches.isEmpty() && !matches.get(0).isEmpty()) {
                            sendSpeechResult(reqId, matches.get(0), false);
                        }
                    }

                    @Override public void onEvent(int eventType, Bundle params) {}
                });

                Intent intent = new Intent(RecognizerIntent.ACTION_RECOGNIZE_SPEECH);
                intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE_MODEL, RecognizerIntent.LANGUAGE_MODEL_FREE_FORM);
                intent.putExtra(RecognizerIntent.EXTRA_LANGUAGE, (lang == null || lang.isEmpty()) ? "en-US" : lang);
                intent.putExtra(RecognizerIntent.EXTRA_PARTIAL_RESULTS, true);
                intent.putExtra(RecognizerIntent.EXTRA_MAX_RESULTS, 1);
                speechRecognizer.startListening(intent);
            } catch (Exception e) {
                sendSpeechError(reqId, "audio-capture");
            }
        });
    }

    private void sendSpeechResult(int reqId, String transcript, boolean isFinal) {
        try {
            JSONObject ev = new JSONObject();
            ev.put("__gsNativeEvent", true);
            ev.put("kind", "srResult");
            ev.put("reqId", reqId);
            ev.put("transcript", transcript);
            ev.put("isFinal", isFinal);
            emitToJs(ev);
        } catch (Exception ignored) {}
    }

    private void sendSpeechError(int reqId, String code) {
        try {
            JSONObject ev = new JSONObject();
            ev.put("__gsNativeEvent", true);
            ev.put("kind", "srError");
            ev.put("reqId", reqId);
            ev.put("error", code);
            emitToJs(ev);
        } catch (Exception ignored) {}
    }

    private void stopAndroidSpeech(final boolean notifyEnd) {
        runOnUiThread(() -> {
            int ended = activeSpeechReqId;
            activeSpeechReqId = 0;
            if (speechRecognizer != null) {
                try {
                    speechRecognizer.stopListening();
                    speechRecognizer.destroy();
                } catch (Exception ignored) {}
                speechRecognizer = null;
            }
            if (notifyEnd && ended > 0) {
                try {
                    JSONObject ev = new JSONObject();
                    ev.put("__gsNativeEvent", true);
                    ev.put("kind", "srEnd");
                    ev.put("reqId", ended);
                    emitToJs(ev);
                } catch (Exception ignored) {}
            }
        });
    }

    @Override
    public void onRequestPermissionsResult(int requestCode, String[] permissions, int[] grantResults) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults);
        if (requestCode == REQ_PERMS && pendingWebPermission != null) {
            boolean granted = grantResults.length > 0 && grantResults[0] == PackageManager.PERMISSION_GRANTED;
            if (granted) pendingWebPermission.grant(pendingWebPermission.getResources());
            else pendingWebPermission.deny();
            pendingWebPermission = null;
        }
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode == REQ_FILE_CHOOSER && filePathCallback != null) {
            Uri[] res = null;
            if (resultCode == RESULT_OK && data != null && data.getDataString() != null) {
                res = new Uri[]{Uri.parse(data.getDataString())};
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

    @Override
    protected void onDestroy() {
        stopAndroidSpeech(false);
        if (tts != null) {
            tts.stop();
            tts.shutdown();
        }
        if (assetServer != null) assetServer.stop();
        super.onDestroy();
    }

    private class NativeBridge {
        @JavascriptInterface
        public void postMessage(String raw) {
            if (raw == null) return;
            String msg = raw.trim();
            if ("clearSession".equals(msg)) {
                prefs.edit().remove(KEY_TOKEN).remove(KEY_USER).apply();
                return;
            }
            if (!msg.startsWith("{")) return;
            try {
                JSONObject obj = new JSONObject(msg);
                String cmd = obj.optString("cmd", "");
                if ("saveStandaloneDB".equals(cmd)) {
                    String dbJson = obj.optString("dbJson", "");
                    if (!dbJson.isEmpty()) prefs.edit().putString(KEY_STANDALONE_DB, dbJson).apply();
                } else if ("saveSession".equals(cmd)) {
                    SharedPreferences.Editor ed = prefs.edit();
                    String tk = obj.optString("token", "");
                    String uj = obj.optString("userJson", "");
                    if (!tk.isEmpty()) ed.putString(KEY_TOKEN, tk);
                    if (!uj.isEmpty()) ed.putString(KEY_USER, uj);
                    ed.apply();
                } else if ("clearSession".equals(cmd)) {
                    prefs.edit().remove(KEY_TOKEN).remove(KEY_USER).apply();
                } else if ("speak".equals(cmd)) {
                    int id = obj.optInt("id", 1);
                    String text = obj.optString("text", "");
                    String lang = obj.optString("lang", "en-US");
                    double rate = obj.optDouble("rate", 1.0);
                    if (ttsReady && tts != null && !text.isEmpty()) {
                        Locale loc = lang.toLowerCase().startsWith("vi")
                                ? new Locale("vi", "VN")
                                : lang.toLowerCase().contains("gb") ? Locale.UK : Locale.US;
                        tts.setLanguage(loc);
                        tts.setSpeechRate((float) Math.max(0.5, Math.min(2.0, rate)));
                        tts.speak(text, TextToSpeech.QUEUE_FLUSH, null, "utt_" + id);
                    } else {
                        notifyTtsEnd("utt_" + id);
                    }
                } else if ("stopSpeak".equals(cmd)) {
                    if (tts != null) tts.stop();
                } else if ("startSpeech".equals(cmd)) {
                    int reqId = obj.optInt("reqId", 1);
                    String lang = obj.optString("lang", "en-US");
                    startAndroidSpeech(reqId, lang);
                } else if ("stopSpeech".equals(cmd)) {
                    stopAndroidSpeech(true);
                }
            } catch (Exception ignored) {}
        }
    }

    private static class LocalAssetServer {
        private final AssetManager assets;
        private ServerSocket serverSocket;
        private volatile boolean running = false;

        LocalAssetServer(AssetManager assets) {
            this.assets = assets;
        }

        int start() {
            int[] ports = new int[]{34560, 34561, 34562, 0};
            for (int p : ports) {
                try {
                    ServerSocket ss = new ServerSocket();
                    ss.setReuseAddress(true);
                    ss.bind(new InetSocketAddress("127.0.0.1", p), 64);
                    this.serverSocket = ss;
                    this.running = true;
                    Thread t = new Thread(this::acceptLoop, "GrandSpeakAssetServer");
                    t.setDaemon(true);
                    t.start();
                    return ss.getLocalPort();
                } catch (Exception ignored) {}
            }
            return 34560;
        }

        void stop() {
            running = false;
            try {
                if (serverSocket != null) serverSocket.close();
            } catch (Exception ignored) {}
        }

        private void acceptLoop() {
            while (running && serverSocket != null && !serverSocket.isClosed()) {
                try {
                    final Socket client = serverSocket.accept();
                    Thread worker = new Thread(() -> handleClient(client));
                    worker.setDaemon(true);
                    worker.start();
                } catch (Exception ignored) {}
            }
        }

        private String mapAssetPath(String rawUri) {
            String pathOnly = rawUri.split("\\?", 2)[0];
            try {
                pathOnly = URLDecoder.decode(pathOnly, "UTF-8");
            } catch (Exception ignored) {}
            while (pathOnly.startsWith("/")) pathOnly = pathOnly.substring(1);
            while (pathOnly.endsWith("/")) pathOnly = pathOnly.substring(0, pathOnly.length() - 1);

            if (pathOnly.isEmpty() || "app".equals(pathOnly)) return "web/app.html";
            if ("landing".equals(pathOnly)) return "web/index.html";
            if ("resort".equals(pathOnly) || "city".equals(pathOnly)
                    || "flashcard/city".equals(pathOnly) || "flashcard/resort".equals(pathOnly)) {
                return "web/resort/resort.html";
            }
            if ("places".equals(pathOnly) || "flashcard/places".equals(pathOnly)) {
                return "web/places/places.html";
            }
            if ("room".equals(pathOnly) || "flashcard/room".equals(pathOnly)) {
                return "web/room/room.html";
            }
            if (pathOnly.contains("..")) return "web/app.html";
            return "web/" + pathOnly;
        }

        private String mimeType(String path) {
            String lower = path.toLowerCase();
            if (lower.endsWith(".html")) return "text/html; charset=utf-8";
            if (lower.endsWith(".js") || lower.endsWith(".mjs")) return "application/javascript; charset=utf-8";
            if (lower.endsWith(".css")) return "text/css; charset=utf-8";
            if (lower.endsWith(".json")) return "application/json; charset=utf-8";
            if (lower.endsWith(".png")) return "image/png";
            if (lower.endsWith(".jpg") || lower.endsWith(".jpeg")) return "image/jpeg";
            if (lower.endsWith(".webp")) return "image/webp";
            if (lower.endsWith(".svg")) return "image/svg+xml";
            if (lower.endsWith(".ico")) return "image/x-icon";
            if (lower.endsWith(".woff")) return "font/woff";
            if (lower.endsWith(".woff2")) return "font/woff2";
            return "application/octet-stream";
        }

        private void handleClient(Socket socket) {
            try (Socket s = socket;
                 BufferedReader reader = new BufferedReader(new InputStreamReader(s.getInputStream(), StandardCharsets.UTF_8));
                 OutputStream out = s.getOutputStream()) {
                String line = reader.readLine();
                if (line == null || line.isEmpty()) return;
                String[] parts = line.split(" ");
                if (parts.length < 2) return;
                String method = parts[0].toUpperCase();
                String assetPath = mapAssetPath(parts[1]);

                byte[] body;
                try (InputStream in = assets.open(assetPath)) {
                    ByteArrayOutputStream bos = new ByteArrayOutputStream();
                    byte[] buf = new byte[16384];
                    int r;
                    while ((r = in.read(buf)) != -1) bos.write(buf, 0, r);
                    body = bos.toByteArray();
                } catch (Exception notFound) {
                    out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".getBytes(StandardCharsets.UTF_8));
                    out.flush();
                    return;
                }

                String headers = "HTTP/1.1 200 OK\r\n"
                        + "Content-Type: " + mimeType(assetPath) + "\r\n"
                        + "Content-Length: " + body.length + "\r\n"
                        + "Cache-Control: no-cache\r\n"
                        + "Connection: close\r\n\r\n";
                out.write(headers.getBytes(StandardCharsets.UTF_8));
                if (!"HEAD".equals(method)) {
                    out.write(body);
                }
                out.flush();
            } catch (Exception ignored) {}
        }
    }
}
