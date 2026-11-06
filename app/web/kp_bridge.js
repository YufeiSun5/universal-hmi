// Loaded once by the KP picture-opening script. All credentials stay in memory
// and POST bodies. Production verifies KP; explicit trials use a fixed-account capability.
(function () {
  'use strict';
  if (window.HMIKP?.version === 3) return;
  if (window.HMIKP?.close) window.HMIKP.close();
  let active;
  const random = () => Array.from(crypto.getRandomValues(new Uint8Array(16)), n => n.toString(16).padStart(2, '0')).join('');
  async function post(base, path, body) {
    // KP httpRequestExec proxies through the KP server, which has a different
    // TLS trust store and cannot present this browser's approved device cert.
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
      const response = await fetch(base + path, {
        method:'POST', mode:'cors', credentials:'include', redirect:'error',
        cache:'no-store', headers:{'Content-Type':'application/json'},
        body:JSON.stringify(body), signal:controller.signal
      });
      try { return await response.json(); }
      catch (_) { throw new Error('invalid_response'); }
    } catch (error) {
      if (controller.signal.aborted) throw new Error('request_timeout');
      if (error.message === 'invalid_response') throw error;
      throw new Error('transport_failed');
    } finally { clearTimeout(timer); }
  }
  const channel = s => ({contextId:s.contextId, loginVersion:s.loginVersion, bridgeToken:s.bridgeToken});
  function close() {
    const s = active;
    active = null;
    if (!s) return;
    clearTimeout(s.timer);
    if (s.bridgeToken) void post(s.base, '/api/v1/kp/close', channel(s)).catch(() => {});
  }
  function open(base, container, getUser, trialKey) {
    const url = new URL(base);
    if (url.protocol !== 'https:' || url.origin !== base) throw new Error('请使用监控系统完整 HTTPS 地址，不带末尾斜杠');
    close();
    const s = {base, container, getUser, contextId:random(), loginVersion:random(), bridgeToken:'', user:'', timer:0, failed:false, logout:false, logoffAttempts:0};
    active = s;
    container.setURL(base + '/kp/kp-loading.html');
    const current = () => active === s;
    function fallback(code) {
      const known = ['kp_disabled','kp_configuration_error','origin_rejected','user_not_provisioned','identity_proof_required','identity_not_verified','identity_mismatch','identity_verifier_unavailable','identity_verifier_bad_response','identity_required','public_ip_denied','public_device_denied','bridge_reconfigured','request_timeout','transport_failed','invalid_response'];
      const reason = known.includes(code) ? '#' + code : '';
      if (current()) { container.setURL(base + '/kp/kp-fallback.html' + reason); close(); }
    }
    async function tick() {
      if (!current()) return;
      try {
        const user = String(getUser() || '');
        const proof = trialKey || sessionStorage.getItem('WellinUserToken') || '';
        if (s.user && user !== s.user) { open(base, container, getUser, trialKey); return; }
        if (!user || !proof) { fallback('identity_proof_required'); return; }
        s.user = user;
        if (!s.bridgeToken) {
          const reply = await post(base, '/api/v1/kp/bootstrap', {contextId:s.contextId, loginVersion:s.loginVersion, userName:user, identityProof:proof, kpHost:location.host});
          if (!current()) { if(reply?.bridgeToken) void post(base,'/api/v1/kp/close',channel(reply)).catch(()=>{}); return; }
          if (String(getUser() || '') !== user) { if(reply?.bridgeToken) void post(base,'/api/v1/kp/close',channel(reply)).catch(()=>{}); open(base,container,getUser,trialKey); return; }
          if (!reply?.ok || reply.contextId !== s.contextId || reply.loginVersion !== s.loginVersion || !/^[A-Za-z0-9_-]{43}$/.test(reply.bridgeToken || '') || !/^[A-Za-z0-9_-]{43}$/.test(reply.ticket || '')) { fallback(reply?.error?.code); return; }
          s.bridgeToken = reply.bridgeToken;
          s.failed = false;
          container.setURL(base + '/kp/#ticket=' + encodeURIComponent(reply.ticket));
        } else {
          const reply = await post(base, '/api/v1/kp/poll', {...channel(s), identityProof:proof});
          if (!current()) return;
          if (String(getUser() || '') !== user) { open(base,container,getUser,trialKey); return; }
          if (reply?.ok && (reply.contextId !== s.contextId || reply.loginVersion !== s.loginVersion)) return;
          if (reply?.command === 'logout') {
            if (trialKey) { fallback(); return; }
            s.logout = true;
            container.setURL(base + '/kp/kp-fallback.html');
            if (s.logoffAttempts < 3) {
              s.logoffAttempts++;
              LogOff(result => {
                // Never act on a new account after an old LogOff callback.
                if (!current() || (getUser() && getUser() !== s.user)) return;
                void post(base, '/api/v1/kp/logoff-result', {...channel(s), success:result === true}).catch(()=>{});
                if (result === true) close();
              });
            }
          } else if (reply?.command === 'closed') { fallback(); }
          else if (!s.logout && (reply?.command === 'rebootstrap' || reply?.error?.code === 'invalid_bridge_token')) { open(base,container,getUser,trialKey); return; }
          else if (!reply?.ok && ['identity_proof_required','identity_not_verified','identity_mismatch','kp_disabled','kp_configuration_error','public_ip_denied','public_device_denied','bridge_reconfigured'].includes(reply?.error?.code)) { fallback(reply.error.code); }
        }
      } catch (error) { if (!s.bridgeToken) fallback(error.message); }
      finally { if(current()) s.timer = setTimeout(tick,5000); }
    }
    void tick();
  }
  function openTrial(base, container, capability) {
    if (!/^[A-Za-z0-9_-]{43}$/.test(capability || '')) throw new Error('请应用联调配置并复制最新脚本');
    open(base, container, () => 'KP联调', capability);
  }
  window.HMIKP = {version:3,open,openTrial,close};
  window.addEventListener('pagehide',close);
})();
