# piq

Run portable modules in isolation with strict quotas.

----

- **Portable** WebAssembly modules that run identically on every platform.
- **Isolated** sandbox with explicit input and output.
- **Integrity** with required SHA256 digests used for verifying before execution.
- **Immutable**, same SHA256 means same module.
- Strict **quotas** of maximum computational fuel & memory usage.
