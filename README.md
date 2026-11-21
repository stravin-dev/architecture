# Stravin Architecture

System architecture, design specs, RFCs, and ADRs for the Stravin platform, published as a static documentation site with [Zensical](https://zensical.org/).

## Prerequisites

Tool versions are pinned in `.tool-versions` and managed via [asdf](https://asdf-vm.com/):

```sh
asdf install
```

## Development

```sh
make install   # Sync Python dependencies with uv
make serve     # Preview the site locally with live reload
make build     # Build the static site strictly (fails on warnings)
make check     # Run strict build and pre-commit hooks
make clean     # Remove generated site/ and .cache/ directories
```

If running outside an asdf-activated shell, prefix commands with `asdf exec` (for example, `asdf exec make build`).
