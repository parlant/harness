---
layout: page
lang: en
permalink: /performance/
title: Browsing 1,131 sessions in H
description: "Measure inbox latency with 1,131 sessions and resident memory before and after 55 idle sessions unload."
---

H is a local daemon for coding-agent sessions. Open the inbox in `hi` or `hiweb` to find a conversation while other sessions keep working. H lists the inbox from a catalog of summaries, so browsing it doesn't open every transcript.

In a local benchmark with 1,131 catalog rows, fetching the full session list took 44 to 50 ms at p95 with the imported histories unopened. Opening 55 of those histories raised the daemon's resident memory (RSS) from about 128 MiB to about 520 MiB. The inbox and the open sessions put different loads on the daemon.

* On this page
{:toc}

## Browse the catalog without opening sessions

H keeps session summaries in an in-memory index backed by a catalog file. The session list and the inbox's Server-Sent Events (SSE) feed read that index. The feed sends an initial snapshot, then streams changes as individual summaries change.

| Benchmark case | Catalog rows | Imported native sessions open | BEAM memory | Daemon RSS |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 83 | 0 | 52.7 MiB | 103.7 to 104.6 MiB |
| Add 993 read-only archive summaries | 1,076 | 0 | 57.5 MiB | 126.8 to 129.6 MiB |
| Add 55 native imports, leave them unopened | 1,131 | 0 | 57.6 MiB | 126.8 to 130.2 MiB |
| Open those 55 native imports | 1,131 | 55 | 442.2 to 443.8 MiB | 516.8 to 524.9 MiB |

BEAM memory is the runtime's own allocation total. RSS is the resident memory reported by the operating system for the daemon process. With the same 1,131 catalog rows, opening the 55 histories added about 390 MiB of RSS in this workload. Opening those sessions took about 6 ms at the median and 42 to 44 ms at p95, measured from the daemon's first session-detail call.

With all 55 histories open, the full list took 46 to 48 ms at p95. Requesting only unarchived summaries took about 4 to 5 ms at p95 across both 1,131-row cases. The full response weighed about 709 KiB; filtering it reduced the response to about 56 KiB. These are local API timings through receipt and JSON parsing. Browser rendering and terminal drawing have their own costs.

[Inspect how H stores sessions and serves the catalog](/docs/architecture/#storage-and-recovery).

## Measure a local turn with a fake provider

The probe ran a turn that read one small file and returned a short answer. A fake provider requested the read and supplied the answer, so the timings cover H's command handling, tool dispatch and commits without model or network latency.

| Benchmark case | Submit acknowledgement p95 | Submit to committed answer p95 |
| --- | ---: | ---: |
| Baseline | 2.6 to 2.7 ms | 10.3 to 15.1 ms |
| Add archive summaries | 8.6 to 13.6 ms | 27.2 to 31.3 ms |
| Native imports unopened | 9.4 to 10.9 ms | 28.2 to 31.2 ms |
| Native imports open | 9.7 to 9.9 ms | 31.4 to 34.4 ms |

The catalog grew, and the turn took longer even with the imported sessions unopened. The read tool itself reported at most 1 ms at its millisecond resolution. In a separate probe, the median call that changed runtime status in the catalog rose from 0.9 to 1.4 ms across baseline runs to 6.4 to 6.6 ms across the two 1,131-row cases. H rewrites the catalog file when that status changes. The status probe measures one part of the turn; it does not assign all of the extra time to catalog writes.

## Reclaim memory after five quiet minutes

H unloads idle local file-backed sessions after five minutes without requests or unfinished work. Their history stays on disk and their summaries stay in the inbox. Open a session or send it a command to load it again. An open event stream can receive updates from the reopened session on the same connection. Queued work, tool or model calls, and sleeping retries keep a session loaded.

A separate run measured automatic unloading with 55 generated histories and 201.5 MiB of commit logs. The sessions all unloaded within 58 ms of reaching five minutes of inactivity in that run, measured by the arrival of coordinator exit notifications.

| Checkpoint | Loaded sessions | BEAM memory | Resident memory |
| --- | ---: | ---: | ---: |
| Before opening the histories | 0 | 56.5 MiB | 115.9 MiB |
| All histories open | 55 | 273.3 MiB | 325.2 MiB |
| All histories unloaded | 0 | 62.3 MiB | 226.0 MiB |
| Five seconds after unload | 0 | 62.4 MiB | 179.4 MiB |

Five seconds after unload, the daemon used **146 MiB less resident memory** and **211 MiB less BEAM memory** than when all 55 histories were open. The operating system's resident memory figure did not return to its pre-open value. The probe ran without forced garbage collection.

| First operation on an unloaded session | Median | p95 | Already loaded, p95 |
| --- | ---: | ---: | ---: |
| Read the newest entry (27 sessions) | 2.6 ms | 12.5 ms | 0.06 ms |
| Write and sync a note (28 sessions) | 2.9 ms | 13.4 ms | 0.62 ms |

These are in-process calls on a machine with warm filesystem caches, separate from the HTTP inbox timings. Larger histories or slower storage can take longer to load. A transport integration test kept one HTTP event stream open through an unload and checked that the next commit arrived with the prior cursor, even after another conversation in the session advanced.

## Check how the benchmark was run

The controlled comparison used an installed macOS release with a fresh BEAM process and disposable file store for each run. Each store started from one of the four catalog fixtures in the table. The read-only archives in this comparison supplied catalog rows only. The 55 resumable imports used native file storage when opened. The unopened case kept the same catalog rows without opening their stores. Here, *unopened* describes the session coordinator, not the operating system's disk cache.

- **Measure memory.** Record BEAM memory and process count after the load phase and an explicit garbage-collection pass. Sample RSS at readiness, after creating the small benchmark session and before request sampling. The first three cases had 431 BEAM processes at the memory checkpoint; the case with 55 sessions open had 651. Catalog ETS storage grew from about 0.07 MiB at baseline to 1.11 MiB with 1,131 rows. BEAM binary memory grew from about 1 MiB with the imports unopened to about 312 MiB with all 55 open.
- **Time local requests.** Use authenticated HTTP over a Unix socket and a fresh connection for each request. Shuffle the full list, the list filtered to unarchived sessions, and the detail request for the already-open benchmark session in each of 48 rounds. Drop the first eight rounds. The detail response was 523 bytes and stayed below 0.6 ms at p95 across all cases.
- **Time the turn and the catalog write separately.** Run 60 serial submissions per case, each with one successful `read` and a fake final answer. Time command return and the matching settlement signal from the same start point. Then time 30 separate catalog updates that alternate the benchmark session between running and idle.
- **Compare three runs per case.** Vary the case order across runs. Tables show the span of per-run results, rounded for readability. Each p95 uses the nearest-rank sample within its run. This is a single-host, serial workload.

### Measure automatic unloading separately

The timeout run used macOS 15.8.1 on an Apple M2 Ultra with 128 GiB RAM, Elixir 1.20.5 and OTP 29. It generated 160 alternating user and assistant entries per session. The fresh measurement VM used file storage and a fake provider, with zero provider requests. It recorded BEAM memory with `:erlang.memory/0` and reported RSS from `ps`. The first-read and first-write cohorts were disjoint, so both began from unloaded coordinators. The second run used a six-second override to exercise the same policy: all 55 unloaded and RSS fell from 327.0 to 183.4 MiB at the five-second mark. These runs used a generated dataset, separate from the imported histories in the preceding comparison.

### Check live inbox and history reads

A separate read-only API spot check on a running daemon measured the same catalog size. The initial inbox SSE snapshot held 1,131 rows, weighed about 709 KiB, and took 48.39 ms at the median and 54.00 ms at p95. The HTTP check warmed up each endpoint three times, then sampled each 25 times in shuffled order. For the history probes, it read the newest 50 entries from the median-size and largest source logs in each import group. The response sizes are approximate.

| Local API read | Response | Median | p95 | Max |
| --- | ---: | ---: | ---: | ---: |
| Full session list | 709 KiB | 46.97 ms | 50.96 ms | 52.47 ms |
| Unarchived session list | 56 KiB | 6.10 ms | 14.22 ms | 16.35 ms |
| Read-only archive index | 208 KiB | 5.14 ms | 9.01 ms | 13.80 ms |
| Open native history, median-size source | 346 KiB | 4.40 ms | 12.07 ms | 12.36 ms |
| Open native history, largest source | 8.46 MiB | 51.01 ms | 58.06 ms | 63.41 ms |
| Read-only archive history, median-size source | 183 KiB | 4.99 ms | 13.20 ms | 13.33 ms |
| Read-only archive history, largest source | 4.32 MiB | 33.17 ms | 36.04 ms | 40.16 ms |

A fixed entry count can still produce a large response when a transcript contains large tool results or other large entries. In this sample, 50 entries yielded anywhere from about 183 KiB to 8.46 MiB across the selected histories.

### Separate context preparation from inference

An offline probe opened the 55 native stores read-only. Their commit logs totaled about 202 MiB. A file-store open took 3.63 ms at the median and 38.37 ms at p95 across the 55 stores. The probe then paged the full history in batches of 200 and built the provider message list. After one warm-up, it timed that scan and projection seven times per history. Across the per-history medians, the median was 0.116 ms and p95 was 2.322 ms. The projected message lists encoded to a median of about 420 KiB of JSON and a maximum of 27.3 MiB. These numbers describe local preparation and message size; the probe made no inference requests and measured neither provider acceptance nor time to first token.

---

## Repository handoff (omit from the website)

- Suggested destination: `/performance/`. Copy everything above this divider into the redesigned site's article layout and include the route in the sitemap and both LLM indexes. Publish with a release that includes automatic unloading; point to the exact source revision when available.
- Features, under **Responsive, synchronized clients**: [See how H browses 1,131 sessions](/performance/).
- Home selling point, under **Lean core**: [Compare memory with sessions open and unopened](/performance/#browse-the-catalog-without-opening-sessions).
- Idle memory: [See what H reclaims after five quiet minutes](/performance/#reclaim-memory-after-five-quiet-minutes).
- Source notes: use the three completed repeats per case in `bench-v2.log` and the matching result summaries. The earlier pilot is excluded; its driver hit a race while reading a result file. The repeat harness published result files by atomic rename. The separate spot checks are from `live.log`, `live-sse.log`, and `context.json`. The live daemon sampled 1,274 to 1,281 MiB RSS during the HTTP spot check; it ran a different workload from the isolated release probe. The saved output does not pin the exact release revision, hardware model, or runtime version. Use a version-pinned release and a generated fixture for the next public reproduction.
- Post-feature acceptance output: `default/result.json` and `short/result.json` (fixture manifests and per-session samples in the isolated benchmark output). The benchmark itself tested PubSub continuity; the Phoenix-independent HTTP/SSE integration test and the running, retrying, workspace-wait and subagent lifecycle tests cover behavior separately.

### Reproduce automatic unloading

Run the [synthetic probe](../../scripts/benchmarks/idle_unload.exs) from the repository root on macOS. It starts only the session runtime and catalog in a disposable directory. Use a fresh directory for each policy.

```sh
export MIX_BUILD_PATH="$(mktemp -d /private/tmp/h-idle-build.XXXXXX)"
run="$(mktemp -d /private/tmp/h-idle-bench.XXXXXX)"
mix run --no-start scripts/benchmarks/idle_unload.exs seed "$run"
mix run --no-start scripts/benchmarks/idle_unload.exs measure "$run" default
```

Pass `6000` instead of `default` to measure with a six-second timeout. See the recorded [default](benchmarks/idle-unload/default.json) and [six-second](benchmarks/idle-unload/short.json) samples.

### Controlled catalog reads by case

The timing columns are the ranges of the three per-run p95s, in milliseconds. Payload sizes are exact response-body bytes.

| Case | Full p95 | Full bytes | Unarchived p95 | Unarchived bytes | Session detail p95 |
| --- | ---: | ---: | ---: | ---: | ---: |
| Baseline | 3.077 to 3.417 | 47,850 | 1.297 to 1.676 | 22,763 | 0.340 to 0.362 |
| Archive summaries | 41.401 to 46.038 | 691,177 | 2.595 to 2.848 | 22,763 | 0.481 to 0.597 |
| Native imports unopened | 44.212 to 49.870 | 726,243 | 4.644 to 5.292 | 57,829 | 0.499 to 0.538 |
| Native imports open | 45.832 to 47.815 | 726,188 | 4.439 to 5.051 | 57,774 | 0.466 to 0.538 |
