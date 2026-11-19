// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

(() => {
  const id = globalThis.chrome?.runtime?.id;
  if (!id || chrome.runtime.getManifest().name !== 'Chromium iOS Worker Probe') {
    throw new Error('Chromium worker probe extension bindings or manifest are unavailable.');
  }
  const badge = document.createElement('div');
  badge.id = 'ios-blink-worker-probe';
  badge.dataset.extensionId = id;
  badge.dataset.swStatus = 'pending';
  badge.textContent = 'Worker probe · ' + id.slice(0, 8);
  badge.style.cssText =
      'position:fixed;bottom:12px;left:12px;z-index:2147483647;' +
      'padding:8px 12px;background:#1e3a8a;color:white;' +
      'font:12px system-ui;border-radius:6px;pointer-events:none';
  (document.body || document.documentElement).appendChild(badge);

  const nonce = 'probe_' + (globalThis.crypto?.randomUUID?.() || (Date.now() + '_' + Math.random().toString(36).slice(2, 10)));
  try {
    chrome.runtime.sendMessage({type: 'ios_probe_ping', nonce}, (reply) => {
      const lastErr = chrome.runtime.lastError;
      if (lastErr) {
        const msg = lastErr.message || String(lastErr);
        badge.dataset.swStatus = 'error';
        badge.dataset.swError = msg;
        document.documentElement.dataset.iosBlinkExtensionSw = 'error:' + msg;
        console.error('CHROMIUM_IOS_EXTENSION_SW_ERROR', id, msg);
        return;
      }
      if (!reply || reply.ok !== true || reply.runtimeId !== id ||
          reply.moduleMarker !== 'ios_probe_sw_module_v1' ||
          reply.echoNonce !== nonce || typeof reply.bootCount !== 'number') {
        const msg = reply?.error || 'unexpected SW reply payload';
        badge.dataset.swStatus = 'error';
        badge.dataset.swError = msg;
        document.documentElement.dataset.iosBlinkExtensionSw = 'error:' + msg;
        console.error('CHROMIUM_IOS_EXTENSION_SW_ERROR', id, msg);
        return;
      }
      badge.dataset.swStatus = 'ok';
      badge.dataset.swModuleMarker = reply.moduleMarker;
      badge.dataset.swBootCount = String(reply.bootCount);
      badge.dataset.swEchoNonce = reply.echoNonce;
      document.documentElement.dataset.iosBlinkExtensionSw =
          'ok:' + reply.moduleMarker + ':' + reply.bootCount;
      badge.textContent =
          'Worker probe · ' + id.slice(0, 8) + ' · SW #' + reply.bootCount;
      console.info(
          'CHROMIUM_IOS_EXTENSION_SW_ROUNDTRIP',
          id,
          reply.moduleMarker,
          reply.bootCount,
          reply.echoNonce);
    });
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    badge.dataset.swStatus = 'error';
    badge.dataset.swError = msg;
    document.documentElement.dataset.iosBlinkExtensionSw = 'error:' + msg;
    console.error('CHROMIUM_IOS_EXTENSION_SW_ERROR', id, msg);
  }
})();
