// 为每次 KP 登录建立独立的 Web 联动会话。
(function () {
    var key = "universalHmi.kpBridge.v1";
    var previous = JSON.parse(sessionStorage.getItem(key) || "null");
    var stamp = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);

    // 已有承载页时立即移走旧用户页面；登录事件可能先于承载页创建。
    if (typeof WebContainer1 !== "undefined") {
        try {
            WebContainer1.setURL("about:blank");
        } catch (error) {
            console.log("KP 页面容器尚未就绪，承载页将重试清空");
        }
    }

    // 每次登录更换关联标识，使旧请求不能覆盖新用户的会话。
    sessionStorage.setItem(key, JSON.stringify({
        contextId: "kp-" + stamp,
        loginVersion: stamp,
        userName: GetCurrentUser(),
        bridgeToken: "",
        blanked: false,
        webLoaded: false,
        sequence: 0,
        pendingSince: 0,
        logoutRequested: false,
        logoutInFlight: false,
        logoutAttempts: 0,
        logoutAt: 0,
        stopped: false
    }));

    // 旧会话关闭采用独立凭据，失败时由后台心跳期限兜底。
    if (previous && previous.bridgeToken) {
        httpRequestExec("https://hmi.example.invalid", "/api/v1/kp/close", "post", {
            contextId: previous.contextId,
            loginVersion: previous.loginVersion,
            bridgeToken: previous.bridgeToken
        }, "JSON", function () {});
    }
}());
