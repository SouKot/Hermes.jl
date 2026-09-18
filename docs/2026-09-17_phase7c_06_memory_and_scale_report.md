# Phase 7C-06 Memory and Scale Report

## Purpose

Measure the current generic Protocol/StateStore path against the packed-array and MultiMesh representation intended for large live scenes.

## 500K Results

| Representation | Peak RSS | Frame p50 | Frame p99 | Notes |
|---|---:|---:|---:|---|
| Generic dictionaries + MessagePack + deep copies | 6,369,472 KB (~6.08 GiB) | N/A | N/A | Current synthetic state-store stress path |
| Packed positions/colors, 10K visibility submission | 113,544 KB (~111 MiB) | 0.282 ms | 0.303 ms | Data-path benchmark |
| MultiMeshInstance2D, 500K instances | 102,428 KB (~100 MiB) | 6.899 ms | 6.914 ms | Headless instanced-renderer smoke test |
| Compact binary positions + packed StateStore + MultiMesh submission | 239,056 KB (~234 MiB) | 0.003 ms submission p99 | 1.621 ms decode p99; 182.435 ms state p99 | End-to-end compact protocol path |

The generic path is approximately 56x higher RSS than the isolated packed benchmark and approximately 26.6x higher RSS than the end-to-end compact protocol path.

## Interpretation

The 6.3 GB value is a real peak for the current generic benchmark, caused by simultaneous original, encoded, decoded, indexed, and deep-copied Dictionary graphs. It is not an acceptable target for a 500K live client.

The packed and MultiMesh results demonstrate that the renderer data itself fits near 100-120 MiB. The end-to-end compact protocol path measured approximately 234 MiB RSS, because it also includes the MessagePack buffer, decoded binary payload, state-store arrays, Godot runtime, and benchmark overhead.

## Important Boundary

The current production viewport still consumes Dictionary-based `render_state` data. The packed/MultiMesh measurements prove the replacement architecture, but they are not yet proof that the complete GUI has migrated to it.

The packed arrays and MultiMesh layer are now integrated into the large-entity `StateStore`/`ViewportController` path. Before claiming full 500K live acceptance, run the compact binary-position format through the connected Julia fixture and measure a real GUI process with the same payload shape.
