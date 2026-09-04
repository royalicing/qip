# Running Interactive Components In A Terminal

`qip tui` and `qipx tui` run an Interactive component and present the final
pipeline output as UTF-8 text. The host owns terminal mode, screen redraws,
timing, and key decoding. The component receives normal QIP key events and
cannot issue general terminal commands.

Run the component debugger with a multipart component and input:

```sh
qip tui \
  -F component=@components/text/wc.wasm \
  -F 'input=The quick brown fox jumps over the lazy dog' \
  components/interactive/wasm-debugger.wasm
```

The Node.js host uses the same arguments:

```sh
qipx tui \
  -F component=@components/text/wc.wasm \
  -F 'input=The quick brown fox jumps over the lazy dog' \
  components/interactive/wasm-debugger.wasm
```

Both commands retain one instance of the first component. They call its initial
Content render, deliver key events through timed updates, render accepted
changes, and honor later wake times returned by `finish_update`.

## Input And Components

Use `-i path` for one initial byte input. Use repeatable `-F` or `--form`
arguments to construct `multipart/form-data`. Terminal stdin carries key events,
so `-i -` and `-F name=@-` are not available in TUI mode.

Hosts can precede the command and apply to every missing component:

```sh
qipx qip.dev tui \
  -F component=@components/text/wc.wasm \
  interactive/wasm-debugger.wasm
```

The first stage must implement the Interactive contract and export
`key_event`. Later stages must be ordinary Content components. They transform
every rendered frame from left to right:

```sh
qip tui \
  -F component=@components/text/wc.wasm \
  components/interactive/wasm-debugger.wasm \
  components/text/strip-ansi-sgr.wasm
```

The final stage must produce UTF-8. Tile and Timed stages are not valid after
the first stage because the TUI host needs one finite text result for each
presentation.

Place `-u name=value` after the stage that receives it. If a stage exports
`uniform_set_columns` or `uniform_set_lines`, the host supplies the current
terminal width and height. An explicit `-u columns=...` or `-u lines=...`
value takes precedence. A resize updates the automatic values and redraws.

## Keyboard Mapping

The host decodes traditional terminal input into the X11 keysyms and modifier
flags used by the Interactive contract. It supports printable UTF-8, Tab,
Backspace, Enter, Escape, arrows, Home, End, Insert, Delete, Page Up, Page Down,
F1 through F12, and common Shift, Control, and Alt variants.

Each terminal key press becomes a key-down event followed immediately by its
key-up event in the same QIP update. Terminals do not normally report separate
press and release events, so a component must not depend on a key remaining
held between terminal updates.

The host reserves these terminal controls:

- `Ctrl-C` exits and restores the terminal.
- `Ctrl-Z` restores and suspends the process on Unix, then redraws after resume.
- `Ctrl-S` and `Ctrl-Q` are ignored so software flow-control bytes cannot reach
  the component.

Escape-prefixed input is ambiguous: for example, `Alt-[` begins with the same
bytes as an arrow key. The host waits 30 ms for the rest of a known sequence,
then treats an incomplete `Escape` prefix as an Alt key chord.

## Terminal Safety Boundary

The component does not control the cursor. On each presentation, the host moves
to the top-left, clears the previous frame, writes the validated new frame,
resets text styling, and clears the remaining screen. It uses the alternate
screen and restores the previous screen and input mode on exit.

A rendered frame can contain:

- valid UTF-8 printable text;
- line feed (`LF`);
- SGR reset, bold, dim, underline, standard 8-color foreground/background, and
  their bright variants.

The host rejects carriage return, Tab, Backspace, DEL, C1 controls, indexed or
true-color SGR, and every non-SGR escape sequence. This includes cursor
movement, OSC window-title and clipboard commands, DCS device commands, and
terminal queries. Post-processing components run before this check, so the
bytes written to the terminal always pass the same validation.

This boundary is narrower than a general terminal emulator. Use a native TUI
library or a browser host when an interface needs cursor placement, mouse input,
independent key-up events, terminal queries, or arbitrary color control.
