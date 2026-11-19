// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import {
  COMMAND_LOG_KEY,
  STORAGE_KEY,
  SW_MODULE_MARKER,
  buildStoragePayload,
} from './sw_helper.js';

let initState = null;
let initError = null;

// Register listeners synchronously at module top level so MV3 service worker
// wakeups dispatch incoming messages and commands while initPromise settles.
chrome.commands.onCommand.addListener((command, tab) => {
  const record = {
    command,
    tab: tab || null,
    receivedAt: Date.now(),
  };
  chrome.storage.local.set({[COMMAND_LOG_KEY]: record}).catch(() => {});
  console.info('CHROMIUM_IOS_WORKER_PROBE_COMMAND', chrome.runtime.id, command);
});

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message || typeof message.type !== 'string') {
    return false;
  }

  if (message.type === 'ios_probe_get_commands') {
    (async () => {
      await initPromise;
      const commands = await chrome.commands.getAll();
      const stored = await chrome.storage.local.get(COMMAND_LOG_KEY);
      sendResponse({
        ok: true,
        runtimeId: chrome.runtime.id,
        commands,
        lastCommand: stored?.[COMMAND_LOG_KEY] || null,
      });
    })().catch((err) => {
      sendResponse({
        ok: false,
        error: err instanceof Error ? err.message : String(err),
      });
    });
    return true;
  }

  if (message.type !== 'ios_probe_ping') {
    return false;
  }

  (async () => {
    await initPromise;
    if (initError || !initState) {
      sendResponse({
        ok: false,
        error: initError || 'SW initialization produced no state',
      });
      return;
    }
    const probeNonce =
        typeof message.nonce === 'string' && message.nonce.length > 0
            ? message.nonce
            : 'default_' + Math.random().toString(36).slice(2, 10);
    const roundtripKey = 'ios_probe_ping_' + probeNonce;
    try {
      await chrome.storage.local.set({
        [roundtripKey]: {nonce: probeNonce, moduleMarker: SW_MODULE_MARKER},
      });
      const readback =
          await chrome.storage.local.get([STORAGE_KEY, roundtripKey]);
      const pingBack = readback?.[roundtripKey];
      const stateBack = readback?.[STORAGE_KEY];
      if (!pingBack || pingBack.nonce !== probeNonce ||
          pingBack.moduleMarker !== SW_MODULE_MARKER ||
          !stateBack || stateBack.moduleMarker !== SW_MODULE_MARKER) {
        sendResponse({
          ok: false,
          error: 'storage.local message roundtrip verification failed',
        });
        return;
      }
      sendResponse({
        ok: true,
        runtimeId: chrome.runtime.id,
        moduleMarker: SW_MODULE_MARKER,
        bootCount: stateBack.bootCount,
        echoNonce: pingBack.nonce,
        senderUrl: sender?.url || null,
      });
    } finally {
      await chrome.storage.local.remove(roundtripKey).catch(() => {});
    }
  })().catch((err) => {
    sendResponse({
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    });
  });
  return true;
});

const initPromise = (async () => {
  try {
    const existing = await chrome.storage.local.get(STORAGE_KEY);
    const payload = buildStoragePayload(existing?.[STORAGE_KEY]?.bootCount);
    await chrome.storage.local.set({[STORAGE_KEY]: payload});
    const verified = await chrome.storage.local.get(STORAGE_KEY);
    const roundtrip = verified?.[STORAGE_KEY];
    if (!roundtrip || roundtrip.moduleMarker !== SW_MODULE_MARKER ||
        roundtrip.bootCount !== payload.bootCount) {
      throw new Error('storage.local verification mismatch after set/get');
    }
    initState = roundtrip;
    console.info(
        'CHROMIUM_IOS_EXTENSION_SW_READY',
        chrome.runtime.id,
        SW_MODULE_MARKER,
        roundtrip.bootCount);
  } catch (err) {
    initError = err instanceof Error ? err.message : String(err);
    console.error('CHROMIUM_IOS_EXTENSION_SW_INIT_ERROR', initError);
  }
})();
