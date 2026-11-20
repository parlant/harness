# Interactive terminal: paged streaming gate

Tested release `hi` (source `363fdd9`) on ms1, Apple M2 Ultra, 128 GiB, macOS 15.8.1 arm64, rustc/cargo 1.100.0. Test terminal: 100×30 Unix PTY, concurrent fake daemon on a disposable Unix socket. No paid provider. This measures key write to decoded terminal cells, not time to photons, SSH network latency, or IME pre-edit.

A 10,000-entry alternating user/Markdown assistant trace starts with a 50-entry snapshot and streams incremental updates every 25 ms. Fetch 198 older pages of 50 (9,900 older entries); keep typing between fetches, then switch to latest and keep typing during the stream. Small control: 20 entries, no older pages. The p95s below are from one run. Each large case had 396 paging keystrokes, 198 page requests and 60 steady streaming keystrokes.

| Entries | Mode | Editing while paging p95 | Enter-to-older-page p95 | Editing at live tail p95 | Paging peak child RSS |
|---:|---|---:|---:|---:|---:|
| 10,000 | fullscreen | 1.53 ms | 20.00 ms | 1.96 ms | 23.5 MiB |
| 10,000 | regular | 0.37 ms | 21.99 ms | 1.67 ms | 23.9 MiB |
| 20 | fullscreen | 1.19 ms | — | 1.27 ms | 19.0 MiB |
| 20 | regular | 0.96 ms | — | 1.24 ms | 19.3 MiB |

Both modes beat the 50 ms key-to-paint target on this trace. This is observed RSS, **not** a hard byte ceiling. `hi` replaces the historical page, retains at most 256 live entries, and separately bounds the SSE delivery queue (256 items / 16 MiB). Entry count is not a byte limit: large entries and an ever-growing live message may cost more. Tool and shell text output is clipped before terminal wrapping (1 KiB of source text per line, up to 200 lines when expanded). These display limits do not change stored results. In particular, do not infer a memory guarantee for an unbounded provider stream from these figures.

Reproduce from the repo root using the release binary and the same workload:

```sh
cargo build --release --locked --manifest-path clients/tui/Cargo.toml --bin hi
python3 clients/tui/tests/perf_trace.py --hi-bin "$PWD/clients/tui/target/release/hi" \
  --pages 198 --keys-per-page 2 --stream-interval-ms 25 --json-out /tmp/hi-gate.json
```
