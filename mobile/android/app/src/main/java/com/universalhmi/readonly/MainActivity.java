package com.universalhmi.readonly;

import android.app.Activity;
import android.content.Intent;
import android.content.SharedPreferences;
import android.graphics.Color;
import android.net.Uri;
import android.os.Bundle;
import android.webkit.*;
import android.widget.*;
import android.view.View;
import java.io.*;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.util.Base64;

public final class MainActivity extends Activity {
    private DeviceKeys keys;
    private ReadonlyProxy proxy;
    private WebView viewer;
    private EditText address;
    private TextView status;
    private boolean wasViewing;
    private SharedPreferences settings;
    @Override public void onCreate(Bundle state) {
        super.onCreate(state); settings=getSharedPreferences("connection",MODE_PRIVATE);
        WebView.setWebContentsDebuggingEnabled(false);
        try { keys=new DeviceKeys(this); } catch(Exception e) { keys=null; }
        configuration();
    }
    private void configuration() {
        LinearLayout layout=new LinearLayout(this); layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(24,40,24,24);
        TextView title=new TextView(this); title.setText("Universal HMI · 只读端"); title.setTextSize(24); layout.addView(title);
        TextView notice=new TextView(this); notice.setText("只能查看 GIS、工艺画面、设备和历史。先导出本机公开授权资料，由本机管理员登记账号与证书，再导入服务器公开证书。私钥保留在手机。"); layout.addView(notice);
        address=new EditText(this); address.setSingleLine(true); address.setHint("https://固定IP:端口"); address.setText(settings.getString("origin","")); address.setInputType(android.text.InputType.TYPE_CLASS_TEXT|android.text.InputType.TYPE_TEXT_VARIATION_URI); layout.addView(address);
        button(layout,"导入服务器公开证书",v -> {
            Intent intent=new Intent(Intent.ACTION_OPEN_DOCUMENT); intent.setType("*/*"); intent.addCategory(Intent.CATEGORY_OPENABLE); startActivityForResult(intent,1);
        });
        button(layout,"导出本机公开授权资料",v -> {
            if (keys==null) { message("本机安全密钥不可用，无法导出或连接。"); return; }
            Intent intent=new Intent(Intent.ACTION_CREATE_DOCUMENT); intent.setType("text/plain"); intent.addCategory(Intent.CATEGORY_OPENABLE); intent.putExtra(Intent.EXTRA_TITLE,"HMI-mobile-public-enrollment.txt"); startActivityForResult(intent,2);
        });
        button(layout,"连接并查看",v -> connect());
        status=new TextView(this); status.setTextIsSelectable(true); layout.addView(status);
        try {
            String pin=settings.getString("server_leaf",null);
            status.setText((keys==null ? "本机安全密钥不可用。" : "本机公钥 SHA-256：\n"+keys.fingerprint())+"\n\n"+(pin==null ? "尚未导入服务器证书。" : "服务器证书 SHA-256：\n"+Certificates.fingerprint(Certificates.parse(Base64.getDecoder().decode(pin)).getEncoded()))+"\n\n地址可修改；远端连接直连，不使用系统代理。修改地址或证书后需要重新登录。");
        } catch(Exception e) { message("服务器证书无效，请重新导入。"); }
        ScrollView scroll=new ScrollView(this); scroll.setFillViewport(true); scroll.addView(layout); setContentView(scroll);
        // Edge-to-edge SDK 35 devices must keep controls outside system bars.
        applyInsets(scroll);
    }
    private void button(LinearLayout layout,String text,View.OnClickListener listener) { Button button=new Button(this); button.setText(text); button.setOnClickListener(listener); layout.addView(button); }
    private void message(String text) { if (status!=null) status.setText(text); }
    private void connect() {
        if (keys==null) { message("本机安全密钥不可用，连接已拒绝。"); return; }
        try {
            URI origin=Certificates.origin(address.getText().toString()); String pin=settings.getString("server_leaf",null);
            if (pin==null) { message("请先导入服务器公开证书并核对指纹。"); return; }
            if (!settings.edit().putString("origin",origin.toString()).commit()) throw new IOException();
            proxy=new ReadonlyProxy(origin,Certificates.parse(Base64.getDecoder().decode(pin)),keys);
            String local=proxy.origin;
            viewer=new WebView(this);
            CookieManager.getInstance().setAcceptCookie(true); CookieManager.getInstance().setAcceptThirdPartyCookies(viewer,false);
            viewer.clearCache(true); viewer.clearHistory(); viewer.getSettings().setJavaScriptEnabled(true); viewer.getSettings().setDomStorageEnabled(true);
            viewer.getSettings().setAllowFileAccess(false); viewer.getSettings().setAllowContentAccess(false);
            viewer.getSettings().setMixedContentMode(WebSettings.MIXED_CONTENT_NEVER_ALLOW); viewer.getSettings().setCacheMode(WebSettings.LOAD_NO_CACHE);
            viewer.getSettings().setSupportMultipleWindows(false); viewer.getSettings().setJavaScriptCanOpenWindowsAutomatically(false);
            viewer.setWebViewClient(new WebViewClient() {
                @Override public boolean shouldOverrideUrlLoading(WebView view,WebResourceRequest request) { return !sameOrigin(local,request.getUrl()); }
                @Override public WebResourceResponse shouldInterceptRequest(WebView view,WebResourceRequest request) {
                    if (!sameOrigin(local,request.getUrl()) && !request.getUrl().getScheme().equals("data") && !request.getUrl().getScheme().equals("blob")) return new WebResourceResponse("text/plain","UTF-8",new ByteArrayInputStream(new byte[0]));
                    return null;
                }
                @Override public void onReceivedSslError(WebView view,SslErrorHandler handler,android.net.http.SslError error) { handler.cancel(); }
                @Override public void onReceivedHttpError(WebView view,WebResourceRequest request,WebResourceResponse response) {
                    if (request.isForMainFrame()) Toast.makeText(MainActivity.this,"访问被拒绝，请核对地址、证书和设备授权。",Toast.LENGTH_LONG).show();
                }
            });
            LinearLayout shell=new LinearLayout(this); shell.setOrientation(LinearLayout.VERTICAL); shell.setBackgroundColor(Color.WHITE);
            button(shell,"退出查看 / 连接设置",v -> { stopViewer(); configuration(); }); shell.addView(viewer,new LinearLayout.LayoutParams(-1,0,1)); setContentView(shell);
            applyInsets(shell);
            wasViewing=true; viewer.loadUrl(proxy.startURL());
        } catch(Exception e) { stopViewer(); configuration(); message("连接配置无效：请核对 HTTPS 固定IP、服务器证书有效期、IP及指纹。未连接现场。"); }
    }
    private static boolean sameOrigin(String origin,Uri target) { return (target.getScheme()+"://"+target.getEncodedAuthority()).equals(origin); }
    @SuppressWarnings("deprecation")
    private static void applyInsets(View surface) {
        surface.setOnApplyWindowInsetsListener((view,insets) -> {
            if (android.os.Build.VERSION.SDK_INT>=30) {
                android.graphics.Insets bars=insets.getInsets(android.view.WindowInsets.Type.systemBars());
                view.setPadding(bars.left,bars.top,bars.right,bars.bottom);
            } else {
                view.setPadding(insets.getSystemWindowInsetLeft(),insets.getSystemWindowInsetTop(),insets.getSystemWindowInsetRight(),insets.getSystemWindowInsetBottom());
            }
            return insets;
        });
    }
    @Override protected void onActivityResult(int request,int result,Intent data) {
        super.onActivityResult(request,result,data);
        if (result!=RESULT_OK || data==null || data.getData()==null) return;
        try {
            if (request==1) {
                ByteArrayOutputStream bytes=new ByteArrayOutputStream();
                try(InputStream input=getContentResolver().openInputStream(data.getData())) {
                    if (input==null) throw new IOException(); byte[] buffer=new byte[4096]; int read;
                    while ((read=input.read(buffer))>=0) { bytes.write(buffer,0,read); if (bytes.size()>16384) throw new IOException(); }
                }
                java.security.cert.X509Certificate cert=Certificates.parse(bytes.toByteArray()); cert.checkValidity();
                if (!settings.edit().putString("server_leaf",Base64.getEncoder().encodeToString(cert.getEncoded())).commit()) throw new IOException(); configuration(); message("服务器公开证书已导入。请通过本机管理员核对 SHA-256：\n"+Certificates.fingerprint(cert.getEncoded()));
            } else if (request==2 && keys!=null) {
                try(OutputStream output=getContentResolver().openOutputStream(data.getData())) { if (output==null) throw new IOException(); output.write(keys.publicExport().getBytes(StandardCharsets.UTF_8)); }
                message("已导出 CSR、公钥指纹和公开客户端证书。请交给本机管理员登记、审批并绑定账号；文件不含私钥。");
            }
        } catch(Exception e) { message("文件处理失败，请检查文件格式和保存位置。未改变设备授权。"); }
    }
    private void stopViewer() {
        if (proxy!=null) { proxy.close(); proxy=null; }
        if (viewer!=null) { viewer.stopLoading(); viewer.loadUrl("about:blank"); viewer.clearCache(true); viewer.destroy(); viewer=null; }
        CookieManager.getInstance().removeAllCookies(null); WebStorage.getInstance().deleteAllData();
    }
    @Override protected void onStop() { super.onStop(); if (viewer!=null) { stopViewer(); wasViewing=true; } }
    @Override protected void onResume() { super.onResume(); if (wasViewing && viewer==null) { wasViewing=false; configuration(); } }
    @Override protected void onDestroy() { stopViewer(); super.onDestroy(); }
}
