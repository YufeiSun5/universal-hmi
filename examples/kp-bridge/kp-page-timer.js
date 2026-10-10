// 让 KP 登录用户进入自己的 Web，并根据 Web 的退出请求注销 KP。
(function () {
    var base = "https://hmi.example.invalid";
    var key = "universalHmi.kpBridge.v1";
    var requestTimeout = 8000;
    var currentUser = GetCurrentUser();
    var state = JSON.parse(sessionStorage.getItem(key) || "null");
    var now = Date.now();

    function save(value) {
        sessionStorage.setItem(key, JSON.stringify(value));
    }

    function createState(userName) {
        var stamp = Date.now().toString(36) + "-" + Math.random().toString(36).slice(2);
        return {
            contextId: "kp-" + stamp, loginVersion: stamp, userName: userName,
            bridgeToken: "", blanked: false, webLoaded: false,
            sequence: 0, pendingSince: 0, logoutRequested: false,
            logoutInFlight: false, logoutAttempts: 0, logoutAt: 0, stopped: false
        };
    }

    function identity(value) {
        return {
            contextId: value.contextId,
            loginVersion: value.loginVersion,
            bridgeToken: value.bridgeToken
        };
    }

    function close(value) {
        if (value && value.bridgeToken) {
            httpRequestExec(base, "/api/v1/kp/close", "post", identity(value), "JSON", function () {});
        }
    }

    function loadWeb(value) {
        WebContainer1.setURL(base + "/kp/#ticket=" + encodeURIComponent(value.ticket));
        value.webLoaded = true;
        value.ticket = "";
        save(value);
    }

    if (!currentUser) {
        WebContainer1.setURL("about:blank");
        sessionStorage.removeItem(key);
        close(state);
        return;
    }

    // 用户变化时先移走旧页面，再创建新的关联标识与票据。
    if (!state || state.userName !== currentUser) {
        close(state);
        state = createState(currentUser);
        save(state);
    }
    if (state.stopped) {
        return;
    }
    if (!state.blanked) {
        WebContainer1.setURL("about:blank");
        state.blanked = true;
        save(state);
    }
    if (state.bridgeToken && !state.webLoaded && state.ticket) {
        loadWeb(state);
    }

    function live(allowLoggedOut) {
        var value = JSON.parse(sessionStorage.getItem(key) || "null");
        if (!value || value.contextId !== state.contextId ||
                value.loginVersion !== state.loginVersion || (GetCurrentUser() !== state.userName && !(allowLoggedOut && !GetCurrentUser()))) {
            return null;
        }
        return value;
    }

    function request(path, payload, completed) {
        state.sequence += 1;
        state.pendingSince = Date.now();
        save(state);
        var sequence = state.sequence;
        try {
            httpRequestExec(base, path, "post", payload, "JSON", function (result) {
                var active = live();
                // 只接收本次登录和最新请求的结果，超时重试后的旧回调也会被丢弃。
                if (!active || active.stopped || active.sequence !== sequence || !active.pendingSince) {
                    return;
                }
                active.pendingSince = 0;
                save(active);
                try {
                    if (typeof result === "string") {
                        result = JSON.parse(result);
                    }
                    completed(active, result);
                } catch (error) {
                    console.log("KP Web 联动响应处理失败", String(error));
                }
            });
        } catch (error) {
            var active = live();
            if (active && active.sequence === sequence) {
                active.pendingSince = 0;
                save(active);
            }
            console.log("KP Web 联动请求失败", String(error));
        }
    }

    function logoff() {
        if (state.logoutAttempts >= 3 || (state.logoutAt && now - state.logoutAt < requestTimeout)) {
            return;
        }
        state.logoutInFlight = true;
        state.logoutAttempts += 1;
        state.logoutAt = now;
        save(state);
        var attempt = state.logoutAttempts;
        try {
            LogOff(function (result) {
                var active = live(true);
                if (!active || active.logoutAttempts !== attempt || active.stopped) {
                    return;
                }
                active.logoutInFlight = false;
                // 只有明确成功才报告成功；未知回调格式按失败处理并保留退出状态。
                active.stopped = result === true;
                save(active);
                var payload = identity(active);
                payload.success = result === true;
                httpRequestExec(base, "/api/v1/kp/logoff-result", "post", payload, "JSON", function () {});
                if (result !== true) {
                    console.log("KP 注销未确认成功，业务保持关闭");
                }
            });
        } catch (error) {
            state.logoutInFlight = false;
            save(state);
            console.log("KP 注销调用失败", String(error));
        }
    }

    if (state.logoutRequested) {
        // 回调失联时仅有限重试，避免对同一会话持续重复注销。
        if (state.logoutInFlight && now - state.logoutAt < requestTimeout) {
            return;
        }
        logoff();
        return;
    }
    if (state.pendingSince && now - state.pendingSince < requestTimeout) {
        return;
    }

    if (!state.bridgeToken) {
        // 集成方提供的异步接口，不是 KP 内置函数。必须返回真实登录的可信凭据。
        if (typeof KPBridgeIdentityProof !== "function") {
            state.stopped = true;
            save(state);
            console.log("请先对接 KPBridgeIdentityProof 身份凭据接口");
            return;
        }
        state.sequence += 1;
        state.pendingSince = Date.now();
        save(state);
        var proofSequence = state.sequence;
        try {
            KPBridgeIdentityProof({ sourceId: "kingportal-site", contextId: state.contextId,
                loginVersion: state.loginVersion, userName: state.userName }, function (proof) {
                var active = live();
                if (!active || active.stopped || active.sequence !== proofSequence || !active.pendingSince) { return; }
                active.pendingSince = 0;
                save(active);
                if (typeof proof !== "string" || !proof) {
                    console.log("未取得可信 KP 身份凭据");
                    return;
                }
                state = active;
                request("/api/v1/kp/bootstrap", {
                    contextId: active.contextId, loginVersion: active.loginVersion,
                    userName: active.userName, identityProof: proof,
                    kpHost: typeof window !== "undefined" ? window.location.host : ""
                }, function (current, result) {
                    if (!result || !result.ok || result.contextId !== current.contextId ||
                            result.loginVersion !== current.loginVersion ||
                            typeof result.bridgeToken !== "string" || !result.bridgeToken ||
                            typeof result.ticket !== "string" || !result.ticket) {
                        console.log("KP Web 会话建立失败");
                        return;
                    }
                    current.bridgeToken = result.bridgeToken;
                    current.ticket = result.ticket;
                    save(current);
                    loadWeb(current);
                });
            });
        } catch (error) {
            var active = live();
            if (active && active.sequence === proofSequence) { active.pendingSince = 0; save(active); }
            console.log("KP 身份凭据获取失败");
        }
        return;
    }

    request("/api/v1/kp/poll", identity(state), function (active, result) {
        if (!result || !result.ok) {
            // 后端重启/会话清理后，仍需重新取得凭据；退出中的会话不得自动重连。
            if (result && result.error && result.error.code === "invalid_bridge_token" && !active.logoutRequested) {
                WebContainer1.setURL("about:blank");
                save(createState(active.userName));
            }
            return;
        }
        if (result.contextId !== active.contextId || result.loginVersion !== active.loginVersion) {
            return;
        }
        if (result.command === "closed") {
            WebContainer1.setURL("about:blank");
            active.stopped = true;
            save(active);
            return;
        }
        if (result.command === "rebootstrap" && !active.logoutRequested) {
            WebContainer1.setURL("about:blank");
            save(createState(active.userName));
            return;
        }
        if (result.command === "logout") {
            WebContainer1.setURL("about:blank");
            active.logoutRequested = true;
            save(active);
            state = active;
            now = Date.now();
            logoff();
        }
    });
}());
