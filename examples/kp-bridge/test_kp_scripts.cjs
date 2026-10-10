// 验证 KP 联动脚本在换用户、异步失序和注销失败时保持正确会话边界。
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

function runtime() {
    let now = 100000;
    let user = "张三";
    const storage = new Map();
    const requests = [];
    const urls = [];
    const logoffs = [];
    class Clock extends Date { static now() { return now; } }
    const context = vm.createContext({
        Date: Clock, Math, JSON, encodeURIComponent,
        console: { log() {} },
        window: { location: { host: "localhost:8080" } },
        sessionStorage: {
            getItem: key => storage.get(key) || null,
            setItem: (key, value) => storage.set(key, value),
            removeItem: key => storage.delete(key)
        },
        GetCurrentUser: () => user,
        KPBridgeIdentityProof: (binding, callback) => callback("fixture-proof"),
        WebContainer1: { setURL: url => urls.push(url) },
        httpRequestExec: (host, api, method, data, type, callback) => requests.push({ host, api, method, data, type, callback }),
        LogOff: callback => logoffs.push(callback)
    });
    return {
        context, requests, urls, logoffs,
        run(file) { vm.runInContext(fs.readFileSync(path.join(__dirname, file), "utf8"), context); },
        tick() { now += 2000; this.run("kp-page-timer.js"); },
        advance(ms) { now += ms; },
        user(name) { user = name; },
        state() { return JSON.parse(storage.get("universalHmi.kpBridge.v1") || "null"); },
        boot(request = requests.at(-1), ticket = "ticket-a") {
            request.callback({ ok: true, contextId: request.data.contextId, loginVersion: request.data.loginVersion, bridgeToken: "kp-token", ticket });
        }
    };
}

const tests = {
    "再次登录立即移走旧用户画面": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot();
        assert.match(r.urls.at(-1), /ticket=/);
        r.user("李四"); r.run("kp-login.js");
        assert.equal(r.urls.at(-1), "about:blank");
        assert.equal(r.state().userName, "李四");
    },
    "登录事件先于容器创建仍能记录新代次": () => {
        const r = runtime(); delete r.context.WebContainer1;
        r.run("kp-login.js"); assert.equal(r.state().userName, "张三");
        const early = runtime();
        early.context.WebContainer1.setURL = () => { throw new Error("not ready"); };
        early.run("kp-login.js"); assert.equal(early.state().userName, "张三");
    },
    "缺失凭据接口不会按用户名进入": () => {
        const r = runtime(); delete r.context.KPBridgeIdentityProof;
        r.run("kp-login.js"); r.tick();
        assert.equal(r.requests.length, 0); assert.equal(r.state().stopped, true);
    },
    "异步凭据旧回调不能登录新用户": () => {
        const r = runtime(); const proofs = [];
        r.context.KPBridgeIdentityProof = (binding, callback) => proofs.push(callback);
        r.run("kp-login.js"); r.tick(); r.user("李四"); r.tick();
        proofs[0]("old-proof"); assert.equal(r.requests.length, 0);
        proofs[1]("new-proof"); assert.equal(r.requests.at(-1).data.identityProof, "new-proof");
    },
    "关闭指令不会重新打开同账号业务": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot(); r.tick();
        const poll = r.requests.at(-1);
        poll.callback({ ok: true, contextId: poll.data.contextId, loginVersion: poll.data.loginVersion, command: "closed" });
        r.tick(); assert.equal(r.state().stopped, true); assert.equal(r.urls.at(-1), "about:blank");
    },
    "租约过期重建需新凭据和新代次": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot(); r.tick();
        const poll = r.requests.at(-1); const version = r.state().loginVersion;
        poll.callback({ ok: true, contextId: poll.data.contextId, loginVersion: poll.data.loginVersion, command: "rebootstrap" });
        r.tick(); assert.notEqual(r.state().loginVersion, version); assert.equal(r.requests.at(-1).data.identityProof, "fixture-proof");
    },
    "同账号两个终端的状态和退出独立": () => {
        const a = runtime(), b = runtime();
        for (const r of [a,b]) { r.run("kp-login.js"); r.tick(); r.boot(); r.tick(); }
        assert.notEqual(a.state().contextId, b.state().contextId);
        const p = a.requests.at(-1);
        p.callback({ ok:true, contextId:p.data.contextId, loginVersion:p.data.loginVersion, command:"logout" });
        assert.equal(a.logoffs.length, 1); assert.equal(b.logoffs.length, 0); assert.equal(b.state().logoutRequested, false);
    },
    "登录加载 Web，Web 指令触发注销": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot();
        assert.match(r.urls.at(-1), /\/kp\/#ticket=ticket-a$/);
        assert.equal(r.requests[0].data.identityProof, "fixture-proof");
        r.tick(); const poll = r.requests.at(-1);
        poll.callback({ ok: true, contextId: poll.data.contextId, loginVersion: poll.data.loginVersion, command: "logout" });
        assert.equal(r.logoffs.length, 1);
        r.user(""); r.logoffs[0](true);
        assert.equal(r.state().stopped, true);
        assert.equal(r.requests.at(-1).api, "/api/v1/kp/logoff-result");
        assert.equal(r.requests.at(-1).data.success, true);
    },
    "换用户后丢弃旧登录回调": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); const old = r.requests.at(-1);
        r.user("李四"); r.boot(old);
        assert.equal(r.urls.filter(url => url.includes("ticket=")).length, 0);
        r.tick(); assert.equal(r.requests.at(-1).data.userName, "李四");
        r.boot(); assert.equal(r.state().userName, "李四");
    },
    "同名用户重新登录也更换登录代次": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); const old = r.requests.at(-1);
        const oldVersion = r.state().loginVersion;
        r.advance(1); r.run("kp-login.js"); r.boot(old);
        assert.notEqual(r.state().loginVersion, oldVersion);
        assert.equal(r.state().bridgeToken, "");
    },
    "超时重试不会接收更早的响应": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); const old = r.requests.at(-1);
        r.advance(8000); r.tick(); const latest = r.requests.at(-1);
        r.boot(old, "old-ticket"); assert.equal(r.state().bridgeToken, "");
        r.boot(latest, "latest-ticket"); assert.match(r.urls.at(-1), /latest-ticket$/);
    },
    "注销失败只有限重试且不恢复业务": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot(); r.tick();
        const poll = r.requests.at(-1);
        poll.callback({ ok: true, contextId: poll.data.contextId, loginVersion: poll.data.loginVersion, command: "logout" });
        r.logoffs[0](false);
        r.advance(8000); r.tick(); r.logoffs[1](false);
        r.advance(8000); r.tick(); r.logoffs[2](false);
        r.advance(8000); r.tick(); assert.equal(r.logoffs.length, 3);
        assert.equal(r.state().logoutRequested, true);
        assert.equal(r.state().stopped, false);
    },
    "关闭时清理存储，晚到响应不能打开页面": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); const old = r.requests.at(-1);
        r.run("kp-close.js"); r.boot(old);
        assert.equal(r.state(), null);
        assert.equal(r.urls.filter(url => url.includes("ticket=")).length, 0);
    },
    "缺少票据的响应不产生可用登录": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); const request = r.requests.at(-1);
        request.callback({ ok: true, contextId: request.data.contextId, loginVersion: request.data.loginVersion });
        assert.equal(r.state().bridgeToken, "");
    },
    "网页加载失败仍可重试相同票据": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick();
        r.context.WebContainer1.setURL = () => { throw new Error("not ready"); };
        r.boot(); assert.equal(r.state().webLoaded, false);
        r.context.WebContainer1.setURL = url => r.urls.push(url);
        r.tick(); assert.equal(r.state().webLoaded, true);
    },
    "旧会话的退出指令不能传给新用户": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.boot(); r.tick();
        const old = r.requests.at(-1); r.user("李四"); r.tick();
        old.callback({ ok: true, contextId: old.data.contextId, loginVersion: old.data.loginVersion, command: "logout" });
        assert.equal(r.logoffs.length, 0);
        assert.equal(r.state().userName, "李四");
    },
    "回调缺失不会无限阻塞后续请求": () => {
        const r = runtime(); r.run("kp-login.js"); r.tick(); r.advance(8000); r.tick();
        assert.equal(r.requests.length, 2);
    }
};
for (const [name, run] of Object.entries(tests)) {
    run(); console.log("PASS " + name);
}
console.log(Object.keys(tests).length + " 项脚本模拟测试通过");
