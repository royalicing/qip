# qip

Run quarantined immutable portable WebAssembly modules from the web.

- **Quarantined** with sandbox isolated from the host.
- **Immutable** with SHA256 digest checked for integrity before execution.
- **Portable** WebAssembly modules that run identically on every platform.

## Install

```
brew install qip
```

## Usage

```bash
echo "abc" | piq run qip.dev@<hash>
# Returns CRC of "abc": 1200128334
cat README.md | piq run qip.dev@<hash>
piq get qip.dev@<hash> > crc32.wasm
cat README.md | piq run ./crc32.wasm
```

Pockets of determinism in a probabilistic, generative world.
