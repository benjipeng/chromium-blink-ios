// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

export const SW_MODULE_MARKER = 'ios_probe_sw_module_v1';
export const STORAGE_KEY = 'ios_probe_sw_state';
export const COMMAND_LOG_KEY = 'ios_probe_last_command';

export function buildStoragePayload(previousCount) {
  const nextCount =
      typeof previousCount === 'number' && Number.isFinite(previousCount)
          ? previousCount + 1
          : 1;
  return {
    bootCount: nextCount,
    moduleMarker: SW_MODULE_MARKER,
  };
}
