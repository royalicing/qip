#!/bin/sh
set -eu

qip_bin=${QIP_BIN:-./qip}
cc_bin=${CC:-cc}
translator=components/application/wasm/qip-component-to-c.wasm
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/qip-component-to-c.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT HUP INT TERM

translate_and_compile() {
    module=$1
    stem=$2
    header="$tmp_dir/$stem.h"
    executable="$tmp_dir/$stem"

    "$qip_bin" run -i "$module" -o "$header" "$translator"
    "$cc_bin" -std=c11 -O2 -Wall -Wextra -Werror \
        "-DQIP_WASM_GENERATED_HEADER=\"$header\"" \
        test/qip-component-to-c-runner.c -lm -o "$executable"
}

compare_output() {
    module=$1
    stem=$2
    input=$3

    "$qip_bin" run -i "$input" -o "$tmp_dir/$stem.qip" "$module"
    "$tmp_dir/$stem" < "$input" > "$tmp_dir/$stem.native"
    cmp "$tmp_dir/$stem.qip" "$tmp_dir/$stem.native"
}

printf '%s' '<a&"' > "$tmp_dir/html.txt"
printf '%s' '{"name":"QIP","values":[1,true,null]}' > "$tmp_dir/data.json"
printf '# Heading\n\nHello *world*.\n' > "$tmp_dir/commonmark.md"

translate_and_compile components/utf8/hello.wasm hello
translate_and_compile components/text/html/html-escape.wasm html-escape
translate_and_compile components/text/json/json-prettify.wasm json-prettify
translate_and_compile components/image/png/png-to-bmp-bgra32.wasm png-to-bmp
translate_and_compile components/image/bmp/bmp-to-png.wasm bmp-to-png
translate_and_compile components/image/svg+xml/svg-rasterize.wasm svg-rasterize
translate_and_compile components/application/x-tar/tar-to-zip.wasm tar-to-zip
translate_and_compile components/application/wasm/wasm-counts.wasm wasm-counts
translate_and_compile components/text/markdown/commonmark.0.31.2.wasm commonmark

compare_output components/utf8/hello.wasm hello "$tmp_dir/html.txt"
compare_output components/text/html/html-escape.wasm html-escape "$tmp_dir/html.txt"
compare_output components/text/json/json-prettify.wasm json-prettify "$tmp_dir/data.json"
compare_output components/image/png/png-to-bmp-bgra32.wasm png-to-bmp site-static/_og/index.png
compare_output components/image/svg+xml/svg-rasterize.wasm svg-rasterize qip-logo.svg

"$qip_bin" run -i site-static/_og/index.png -o "$tmp_dir/image.bmp" \
    components/image/png/png-to-bmp-bgra32.wasm
compare_output components/image/bmp/bmp-to-png.wasm bmp-to-png "$tmp_dir/image.bmp"

tar -cf "$tmp_dir/input.tar" docs/formats.md
compare_output components/application/x-tar/tar-to-zip.wasm tar-to-zip "$tmp_dir/input.tar"
compare_output components/application/wasm/wasm-counts.wasm wasm-counts components/utf8/hello.wasm
compare_output components/text/markdown/commonmark.0.31.2.wasm commonmark "$tmp_dir/commonmark.md"

a_prefix=$(sed -n 's/^typedef struct \(qip_wasm_[0-9a-f]*\)_instance.*/\1/p' "$tmp_dir/hello.h")
b_prefix=$(sed -n 's/^typedef struct \(qip_wasm_[0-9a-f]*\)_instance.*/\1/p' "$tmp_dir/html-escape.h")
"$cc_bin" -std=c11 -O2 -Wall -Wextra -Werror \
    "-DQIP_WASM_GENERATED_HEADER_A=\"$tmp_dir/hello.h\"" \
    "-DQIP_WASM_GENERATED_HEADER_B=\"$tmp_dir/html-escape.h\"" \
    "-DQIP_A_INSTANCE=${a_prefix}_instance" \
    "-DQIP_A_INIT=${a_prefix}_init" \
    "-DQIP_A_RENDER=${a_prefix}_render" \
    "-DQIP_A_MEMORY_SIZE=${a_prefix}_MEMORY_SIZE" \
    "-DQIP_A_INPUT_OFFSET=${a_prefix}_INPUT_OFFSET" \
    "-DQIP_A_INPUT_CAPACITY=${a_prefix}_INPUT_CAPACITY" \
    "-DQIP_A_STALE_INSTANCE=${a_prefix}_STALE_INSTANCE" \
    "-DQIP_B_INSTANCE=${b_prefix}_instance" \
    "-DQIP_B_INIT=${b_prefix}_init" \
    "-DQIP_B_RENDER=${b_prefix}_render" \
    "-DQIP_B_MEMORY_SIZE=${b_prefix}_MEMORY_SIZE" \
    "-DQIP_B_INPUT_OFFSET=${b_prefix}_INPUT_OFFSET" \
    "-DQIP_B_INPUT_CAPACITY=${b_prefix}_INPUT_CAPACITY" \
    test/qip-component-to-c-bundle.c -lm -o "$tmp_dir/bundle"
"$tmp_dir/bundle"

"$qip_bin" run -i test/fixtures/qip-component-to-c-traps.wasm \
    -o "$tmp_dir/traps.h" "$translator"
for dirty_tracking in 0 1; do
    "$cc_bin" -std=c11 -O2 -Wall -Wextra -Werror \
        "-DQIP_WASM_DIRTY_TRACKING=$dirty_tracking" \
        "-DQIP_WASM_GENERATED_HEADER=\"$tmp_dir/traps.h\"" \
        test/qip-component-to-c-traps.c -lm -o "$tmp_dir/traps-$dirty_tracking"
    "$tmp_dir/traps-$dirty_tracking"
done

echo "qip-component-to-c native parity tests passed"
