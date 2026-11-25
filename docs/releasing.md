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

The web changes landed in `1a1d56b`. The signed `v0.3.0` native bundles are available on [GitLab](https://gitlab.com/parlant-co/harness/-/releases/v0.3.0) and [GitHub](https://github.com/parlant/harness/releases/tag/v0.3.0). `hiness` ships the daemon and its Elixir API; the native bundles include the web and terminal clients.

1. Check the public listing with `mix hex.info hiness`. Authenticate as [`overbryd`](https://hex.pm/users/overbryd) with `mix hex.user auth`, then confirm the account with `mix hex.user whoami`.
2. Confirm the [tag pipeline](https://gitlab.com/parlant-co/harness/-/pipelines/3112547161) passed. From a clean checkout of `v0.3.0`, run `MIX_ENV=dev mix deps.get --check-locked` and `MIX_ENV=dev mix hex.publish` interactively. Choose **Yourself** if Hex prompts for an owner and enter your one-time code in the terminal. Verify [the package listing](https://hex.pm/packages/hiness) and [HexDocs](https://hexdocs.pm/hiness), then install `{:harness, "~> 0.3.0", hex: :hiness}` in a clean Mix project. If only the docs upload fails, retry with `MIX_ENV=dev mix hex.publish docs` from the same tag.
3. Publish `h_setup` separately. For its first release, run `MIX_ENV=docs mix deps.get --check-locked` and `MIX_ENV=docs mix hex.publish` from `installer/` at the same tag. Verify the [installer listing](https://hex.pm/packages/h_setup).

## Publish later versions from GitLab

Protect `v*` tags in GitLab before the next release, and configure a masked, protected `HEX_API_KEY` authorized to publish the package. Keep the core, installer, and client versions aligned with the tag. After the signed assets are public, update the [shared website release record](../websites/shared/data/releases.yml) and the download examples. The `release:hex` and `release:hex-installer` jobs are manual on protected version tags. Both wait for the Elixir tests and the Hex consumer smoke test. `release:hex` can run independently of the native release. `release:hex-installer` waits for native release publication and checks that a bundle signature was produced. Run only the job for the package that still needs publishing; leave the job unrun if that version was already published interactively.
