// 在 KP 退出登录时关闭对应的 Web 会话。
(function () {
    var key = "universalHmi.kpBridge.v1";
    var state = JSON.parse(sessionStorage.getItem(key) || "null");
    // 先移除关联状态，使退出前尚未返回的请求不能重新打开业务网页。
    sessionStorage.removeItem(key);
    WebContainer1.setURL("about:blank");
    if (state && state.bridgeToken) {
        httpRequestExec("https://hmi.example.invalid", "/api/v1/kp/close", "post", {
            contextId: state.contextId,
            loginVersion: state.loginVersion,
            bridgeToken: state.bridgeToken
        }, "JSON", function () {});
    }
}());
