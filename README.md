# ParakeetDiar

Elixir bindings for [parakeet.cpp](https://github.com/mudler/parakeet.cpp) live
speaker diarization. An Erlang NIF (`c_src/parakeet_diar_nif.c`) wraps
parakeet.cpp's `libparakeet.so`; `ParakeetDiar` is the public API.

Supported platform: x86_64 Linux (glibc 2.35+, e.g. Ubuntu 22.04), OTP 28.

## Installation

```elixir
def deps do
  [
    {:parakeet_diar, github: "Quickom2023/parakeet-diar", ref: "<commit>"}
  ]
end
```

`<commit>` is one with the release's checksums in `checksum.exs` — the commit
after the release tag, which adds them (see "Cutting a release"); the tag's own
commit has none, and elixir_make downloads nothing it has no checksum for.
`mix deps.get && mix compile` downloads the precompiled NIF of the version in
`mix.exs`. The
bundle contains `priv/parakeet_diar_nif.so` and the CPU build of
`libparakeet.so` with its ggml libraries in `priv/lib/`, so no parakeet.cpp
build is needed.

On a GPU box, point `LD_LIBRARY_PATH` at a CUDA build of the same parakeet.cpp
commit (`5c9b0fb`). The loader searches `LD_LIBRARY_PATH` before the NIF's
RUNPATH, so the CUDA `libparakeet.so` is used there.

## Building from source

Set `PARAKEET_DIAR_BUILD=true` to skip the download and compile locally:

```sh
PARAKEET_DIAR_BUILD=true \
PARAKEET_DIR=/path/to/parakeet.cpp \
PARAKEET_LIB_DIR=/path/to/parakeet.cpp/build-shared \
mix compile
```

`PARAKEET_LIB_DIR` must hold a built `libparakeet.so`, and its ggml libraries
must be in `PARAKEET_GGML_DIR` (default `$PARAKEET_LIB_DIR/third_party/ggml/src`).
Bundling needs `patchelf` (`sudo apt-get install patchelf`).

## Cutting a release

1. Bump `@version` in `mix.exs`, commit, and push a tag `vX.Y.Z`.
2. Wait for the `precompile` workflow to attach the tarballs to the release.
3. Run `mix elixir_make.checksum --all --ignore-unavailable`, commit the
   updated `checksum.exs` and push: that commit is the one to depend on.

Testing needs the model and fixtures from parakeet.cpp. Their paths default to
`../parakeet.cpp/`; override them with `PARAKEET_TEST_MODEL` and
`PARAKEET_TEST_WAV`.
