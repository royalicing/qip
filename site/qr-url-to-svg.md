<title>URL to QR SVG</title>

# URL to QR SVG

Type or paste a URL and the preview updates immediately.

<form aria-labelledby="form-qr-url-heading">
    <h3 id="form-qr-url-heading">Live preview (url-to-qr-svg.wasm in browser)</h3>
    <qip-preview>
        <source src="/modules/text/uri-list/url-to-qr-svg.wasm" type="application/wasm" />
        <label>
            URL
            <input
                type="url"
                name="input"
                value="https://example.com/docs/how-it-works"
                placeholder="https://example.com"
                spellcheck="false"
                style="width: min(48rem, 95vw);"
            />
        </label>
        <output name="output"></output>
    </qip-preview>
</form>

## CLI equivalent

```bash
echo "https://example.com/docs/how-it-works" \
| qip run modules/text/uri-list/url-to-qr-svg.wasm \
> qr.svg
```

This module expects `text/uri-list` and outputs `image/svg+xml`.
