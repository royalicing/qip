# Running QIP In Python

Python can run a QIP component with the Wasmtime package and a small wrapper around the QIP memory contract. The app loads the `.wasm` file from disk, writes UTF-8 input into its memory, calls `render`, and copies the UTF-8 output back into Python.

QIP uses *component* to mean a small unit that follows a QIP contract. A QIP component is currently a [WebAssembly Core module](https://webassembly.github.io/spec/core/), not a [WebAssembly Component Model](https://component-model.bytecodealliance.org/) component. Use Wasmtime's `Module` and `Instance` APIs, not `wasmtime.component.Component`. QIP components also have no WASI imports, so this example does not configure WASI or expose host capabilities.

## Install Wasmtime

Create a virtual environment and install the [Wasmtime Python package](https://github.com/bytecodealliance/wasmtime-py):

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install wasmtime
```

Wasmtime publishes frequent major versions. Once the example works in your app, record the tested version in your lock file or dependency constraints.

Put the downloaded component next to the Python script:

```text
markdown-example/
├── gfm-commonmark.0.31.2.wasm
└── markdown.py
```

## Render Markdown

```python
from pathlib import Path

from wasmtime import Instance, Module, Store


wasm_path = Path(__file__).with_name("gfm-commonmark.0.31.2.wasm")

store = Store()
module = Module.from_file(store.engine, wasm_path)
instance = Instance(store, module, [])
exports = instance.exports(store)

memory = exports["memory"]
input_ptr = exports["input_ptr"]
input_cap = exports["input_utf8_cap"]
output_ptr = exports["output_ptr"]
output_cap = exports["output_utf8_cap"]
render = exports["render"]


def memory_range(pointer: int, size: int, label: str) -> tuple[int, int]:
    end = pointer + size
    if pointer < 0 or size < 0 or end > memory.data_len(store):
        raise ValueError(f"{label} is outside component memory")
    return pointer, end


def markdown_to_html(markdown: str) -> str:
    source = markdown.encode("utf-8")

    capacity = input_cap(store)
    if len(source) > capacity:
        raise ValueError(
            f"Markdown input exceeds component capacity: {len(source)} > {capacity}"
        )

    start, _ = memory_range(input_ptr(store), len(source), "Input")
    memory.write(store, source, start)

    size = render(store, len(source))
    capacity = output_cap(store)
    if size < 0 or size > capacity:
        raise ValueError(
            f"Component returned an invalid output size: {size}, capacity {capacity}"
        )

    start, end = memory_range(output_ptr(store), size, "Output")
    result = memory.read(store, start, end)
    return bytes(result).decode("utf-8")


markdown = """# Project status

| Feature | Status |
| --- | --- |
| Python host | Ready |

- [x] Load the component from disk
- [x] Render **GFM**
"""

print(markdown_to_html(markdown))
```

Run it with:

```bash
python markdown.py
```

The output is HTML:

```html
<h1>Project status</h1>
<table>
<thead>
<tr>
<th>Feature</th>
<th>Status</th>
</tr>
</thead>
<tbody>
<tr>
<td>Python host</td>
<td>Ready</td>
</tr>
</tbody>
</table>
<ul>
<li><input checked="" disabled="" type="checkbox"> Load the component from disk</li>
<li><input checked="" disabled="" type="checkbox"> Render <strong>GFM</strong></li>
</ul>
```

## How The Boundary Maps To Python

The loader is runtime-specific; the QIP calls are not:

1. `Module.from_file` compiles the WebAssembly Core module from local bytes.
2. `Instance(store, module, [])` instantiates it with no imports.
3. Python encodes the Markdown as UTF-8 and checks `input_utf8_cap()`.
4. `memory.write` copies those bytes to `input_ptr()`.
5. `render(input_size)` returns the number of output bytes.
6. Python checks `output_utf8_cap()`, copies from `output_ptr()`, and decodes UTF-8.

The capacity checks enforce the QIP contract. The `memory_range` check also rejects negative pointers and out-of-bounds slices before they reach Wasmtime's Python memory API, where negative offsets and clipped reads otherwise follow Python slice conventions.

## Traps And Reuse

If `render` traps, Wasmtime raises an exception. Treat that render as failed and do not read the output buffer; it may contain stale or partial bytes.

The example compiles and instantiates the component once, then reuses it. That avoids repeated compilation, but the instance owns mutable memory. Do not let concurrent requests write to the same instance. Serialize access with a lock, or give each worker or concurrent request its own instance. A compiled module can be reused when creating those instances.

## When To Use Something Else

Keep ordinary Python code in charge of database access, HTTP calls, authentication, logging, and application workflow. QIP fits the deterministic Markdown-to-HTML step. If the transform needs Python objects, callbacks, or ambient host services throughout its execution, a normal Python library will usually be simpler.
