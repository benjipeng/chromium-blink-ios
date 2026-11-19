(async () => {
  const originEl = document.getElementById('origin');
  const runtimeIdEl = document.getElementById('runtime-id');
  const pingStatusEl = document.getElementById('ping-status');
  const markerEl = document.getElementById('module-marker');
  const bootCountEl = document.getElementById('boot-count');
  const echoNonceEl = document.getElementById('echo-nonce');
  const commandsEl = document.getElementById('commands');
  const lastCommandEl = document.getElementById('last-command');
  const repingBtn = document.getElementById('reping');

  originEl.textContent = window.location.origin;
  runtimeIdEl.textContent = chrome.runtime.id;

  async function runProbe() {
    const nonce = 'opt_' + (globalThis.crypto?.randomUUID?.() || (Date.now() + '_' + Math.random().toString(36).slice(2, 10)));
    try {
      const reply = await chrome.runtime.sendMessage({type: 'ios_probe_ping', nonce});
      if (!reply || reply.ok !== true || reply.echoNonce !== nonce) {
        pingStatusEl.textContent = 'error: ' + (reply?.error || 'unexpected reply');
      } else {
        pingStatusEl.textContent = 'ok';
        markerEl.textContent = reply.moduleMarker;
        bootCountEl.textContent = String(reply.bootCount);
        echoNonceEl.textContent = reply.echoNonce;
      }
      const cmds = await chrome.commands.getAll();
      commandsEl.textContent = JSON.stringify(cmds, null, 2);
      const stored = await chrome.storage.local.get('ios_probe_last_command');
      lastCommandEl.textContent = JSON.stringify(stored?.ios_probe_last_command || null, null, 2);
      console.info('WORKER_PROBE_OPTIONS_READY', JSON.stringify({
        origin: window.location.origin,
        runtimeId: chrome.runtime.id,
        pingOk: reply?.ok === true,
        bootCount: reply?.bootCount ?? null,
        commands: cmds,
        lastCommand: stored?.ios_probe_last_command || null,
      }));
    } catch (err) {
      pingStatusEl.textContent = 'error: ' + (err instanceof Error ? err.message : String(err));
      console.error('WORKER_PROBE_OPTIONS_ERROR', err);
    }
  }

  repingBtn.addEventListener('click', runProbe);
  await runProbe();
})();
