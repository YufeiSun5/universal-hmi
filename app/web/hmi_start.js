// Public sign-in uses the same server contract without starting the renderer.
(() => {
  'use strict';
  const params = new URLSearchParams(location.search);
  let started = false;
  function startApp() {
    if (started) return;
    started = true;
    document.getElementById('hmi-signin')?.remove();
    document.getElementById('hmi-signin-style')?.remove();
    const script = document.createElement('script');
    script.src = 'flutter_bootstrap.js';
    script.async = true;
    script.onerror = () => {
      const message = document.createElement('p');
      message.textContent = '界面加载失败，请刷新页面重试。';
      document.body.append(message);
    };
    document.body.append(script);
  }
  // Preserve native Android startup and the existing local KP ticket bridge.
  if (params.get('client') === 'android' || location.pathname.startsWith('/kp/')) {
    startApp();
    return;
  }
  const headers = {'Content-Type': 'application/json'};
  if (params.get('embed') === 'kp') headers['X-HMI-Embed'] = 'kp';
  async function api(path, body) {
    const response = await fetch('/api/v1/auth/' + path, {
      method: body === undefined ? 'GET' : 'POST',
      headers, credentials: 'same-origin', cache: 'no-store',
      body: body === undefined ? undefined : JSON.stringify(body),
      signal: AbortSignal.timeout(15000),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(data.error?.message || '连接失败，请稍后重试');
    return data;
  }
  function signIn() {
    const style = document.createElement('style');
    style.id = 'hmi-signin-style';
    style.textContent = `
      body{margin:0;background:#eef1f5;color:#243449;font:15px/1.5 system-ui,"Microsoft YaHei",sans-serif}
      #hmi-signin{box-sizing:border-box;min-height:100dvh;display:grid;place-items:center;padding:24px}
      #hmi-signin form{box-sizing:border-box;width:100%;max-width:420px;padding:32px;background:#fff;border:1px solid #d6dee8;border-radius:12px;box-shadow:0 10px 36px #22334d12}
      #hmi-signin h1{font-size:24px;line-height:1.3;margin:0 0 8px}#hmi-signin p{margin:0 0 24px;color:#5c6b7c}
      #hmi-signin label{display:block;margin-top:18px}#hmi-signin input{box-sizing:border-box;display:block;width:100%;min-height:52px;margin-top:6px;padding:12px;border:1px solid #aab8c9;border-radius:6px;font:inherit;background:#fff;color:#243449}
      #hmi-signin button{min-height:44px;border:1px solid #aab8c9;border-radius:6px;padding:9px 14px;font:inherit;cursor:pointer;background:#f4f6f9;color:#243449}
      #hmi-signin button:disabled{opacity:.6;cursor:wait}#hmi-signin :focus-visible{outline:3px solid #72a7df;outline-offset:2px}
      #hmi-signin .captcha{display:flex;gap:12px;align-items:center;margin-top:10px;flex-wrap:wrap}#hmi-signin img{width:180px;height:60px;object-fit:contain;background:white}
      #hmi-signin .submit{width:100%;margin-top:20px;background:#255c96;border-color:#255c96;color:#fff}
      #hmi-signin .message{margin:16px 0 0;min-height:24px;color:#a03131;overflow-wrap:anywhere}
      @media(max-width:480px){#hmi-signin{padding:16px;align-items:start}#hmi-signin form{padding:24px}}
    `;
    document.head.append(style);
    const root = document.createElement('main');
    root.id = 'hmi-signin';
    root.innerHTML = `<form><h1>Universal HMI</h1><p>登录以查看已授权的站点与数据</p>
      <label>账号<input name="username" autocomplete="username" required maxlength="128"></label>
      <label>密码<input name="password" type="password" autocomplete="current-password" required maxlength="1024"></label>
      <label>图形验证码<input name="captcha" autocomplete="off" inputmode="numeric" required maxlength="5"></label>
      <div class="captcha"><img alt="图形验证码"><button type="button">换一张</button></div>
      <button class="submit" type="submit" disabled>登录</button><p class="message" role="status" aria-live="polite"></p></form>`;
    document.body.append(root);
    const form = root.querySelector('form'), message = root.querySelector('.message');
    const submit = root.querySelector('.submit'), refresh = root.querySelector('button[type=button]');
    let challenge = '', busy = false;
    async function captcha() {
      challenge = '';
      submit.disabled = true;
      refresh.disabled = true;
      form.elements.captcha.value = '';
      try {
        const data = await api('captcha');
        root.querySelector('img').src = 'data:image/png;base64,' + data.image_base64;
        challenge = data.id;
      } catch (error) { message.textContent = error.message; }
      finally { refresh.disabled = false; submit.disabled = !challenge || busy; }
    }
    refresh.onclick = () => { message.textContent = ''; void captcha(); };
    form.onsubmit = async event => {
      event.preventDefault();
      if (busy || !challenge) return;
      busy = true; submit.disabled = true; refresh.disabled = true;
      message.textContent = '正在验证…';
      const body = {username: form.elements.username.value.trim(), password: form.elements.password.value,
        captcha_id: challenge, captcha_answer: form.elements.captcha.value.trim()};
      try {
        const session = await api('login', body);
        form.elements.password.value = '';
        if (!session.authenticated) throw new Error('未建立登录会话，请重试');
        startApp();
      } catch (error) {
        form.elements.password.value = '';
        message.textContent = error.message;
        busy = false;
        await captcha();
      } finally { body.password = ''; }
    };
    void captcha();
  }
  // The server remains authoritative. The Flutter login remains the fallback
  // for local setup, legacy authentication and unsupported session endpoints.
  api('session').then(session => {
    if (session.enabled && session.captcha_required && !session.authenticated) signIn();
    else startApp();
  }).catch(startApp);
})();
