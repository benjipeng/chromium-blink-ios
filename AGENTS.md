# Curium repository instructions

Curium (`com.appautomaton.curium`) is a native iOS browser. Work on `main`: GitHub Actions builds Chromium Blink, jitless V8, and Manifest V3 extensions through Stages 0–4; Xcode 27.2 builds the Liquid Glass shell in `Curium/` and `Curium.xcodeproj`. The shell uses the `EngineContract/` ABI and the generated `Vendor/CuriumEngine/` handoff.

## CI efficiency and cache reuse

- Keep the 18 compile partitions and their `ccache` buckets stable. Never edit `patches/`, `args/`, `version.lock`, or the `COMMON` scripts in `scripts/plan_pipeline.py` piecemeal. Leave all keyed inputs unchanged during local Swift UI work so every GHCR checkpoint remains reusable.
- Batch engine changes into one wave. The next wave combines `staging/patches/0087`, the headless `CrIOSBrowserHostV1` bridge (0088), and Chromium M160 (`160.0.8171.0`). Verify the candidate with `graph-diagnose.yml` before commissioning a full build.
- Build and link Chromium only in Actions. Use small patch excerpts, build graphs, and native diagnostic helpers for local investigation; never check out upstream Chromium locally.

Use `Kernel.lock` as the engine provenance record. Assemble through `scripts/sync_curium_engine.py` and check it offline with `--status`; reserve `--skip-sha256` for an explicit local test IPA. Keep generated Vendor files out of Git. For legacy IPA diagnostics, use a disposable copy on the iPhone Duo simulator. Preserve existing installs and leave physical devices untouched.

See the [repository guide](README.md) for setup and [checkpoints](README.md#checkpoints-and-resumption), the [engine contract](EngineContract/README.md) for the ABI, and the [simulator guide](docs/simulator.md) for standalone Chromium IPA diagnostics.
