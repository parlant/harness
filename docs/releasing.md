# Release `hiness` on Hex

`hiness` is the core Elixir package. Its OTP application and configuration key remain `:harness`. The terminal and browser clients ship in the native bundles. `h_setup` is a separate Hex package for installing those signed bundles.

## Check the release candidate

Use Elixir 1.20, Erlang/OTP 29, and Hex 2.7 or newer. Run from the repository root:

```sh
mix deps.get --check-locked
mix format --check-formatted
mix compile --warnings-as-errors
mix test
mix docs --warnings-as-errors
mix hex.audit
mix hex.publish --dry-run --yes
elixir scripts/ci/smoke-hex.exs
```

Use `MIX_ENV=dev` for the HexDocs and publish commands. On macOS, set `MIX_BUILD_PATH` to a unique directory under `/private/tmp` when testing alongside an existing checkout build.

The smoke test builds the Hex tarball, serves it from a disposable signed registry on loopback, and installs it into a fresh Mix project with `hex: :hiness` on the `:harness` dependency. It resolves and audits consumer dependencies without the source checkout's lockfile, then boots the embedded daemon against a disposable store without API listeners or model requests. To inspect the package contents, run `mix hex.build --unpack --output /path/to/new-directory`.

## Publish the first version (`v0.3.0`)

Wait for the pending web-client changes to land on `main` before tagging. `hiness` ships only the daemon; the native bundles built from the same tag will include the web-client changes.

1. Check the public listing with `mix hex.info hiness`. Authenticate as [`overbryd`](https://hex.pm/users/overbryd) with `mix hex.user auth`, then confirm the account with `mix hex.user whoami`.
2. Merge the reviewed candidate and tag that commit with the version in `mix.exs` (for the first candidate, `v0.3.0`). The installer and client versions must match the tag. Protect `v*` tags in GitLab before pushing a release tag. Verify the source tag is available on the GitHub mirror so HexDocs source links resolve there.
3. Confirm the tag pipeline passed the Elixir tests and the Hex consumer smoke test. From a clean checkout of that tag, run `MIX_ENV=dev mix deps.get --check-locked` and `MIX_ENV=dev mix hex.publish` interactively. Choose **Yourself** if Hex prompts for an owner so the package belongs to `overbryd`. Verify [the package listing](https://hex.pm/packages/hiness) and [HexDocs](https://hexdocs.pm/hiness), then install the published dependency in a clean Mix project with `{:harness, "~> 0.3.0", hex: :hiness}`. If only the docs upload fails, retry with `MIX_ENV=dev mix hex.publish docs` from the same tag.
4. Publish `h_setup` separately only after a signed native release is available. For its first release, run `MIX_ENV=docs mix deps.get --check-locked` and `MIX_ENV=docs mix hex.publish` from `installer/` at the same tag. Verify the [installer listing](https://hex.pm/packages/h_setup).
5. Once the signed assets are public, update the [shared website release record](../websites/shared/data/releases.yml) and the download examples on [hiness.dev](../websites/hiness.dev/index.md) and [hiness.app](../websites/hiness.app/index.md). List only assets that were published; `v0.2.0` was not released.

## Publish later versions from GitLab

Configure a masked, protected `HEX_API_KEY` authorized to publish the package. The `release:hex` and `release:hex-installer` jobs are manual on protected version tags. Both wait for the Elixir tests and the Hex consumer smoke test. `release:hex` can run independently of the native release. `release:hex-installer` waits for native release publication and checks that a bundle signature was produced. Run only the job for the package that still needs publishing; leave the job unrun if that version was already published interactively.
