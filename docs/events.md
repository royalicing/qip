# Events

This page documents the event codes used by qip interactive modules.

The ABI follows a small subset inspired by the Remote Framebuffer Protocol ([RFC 6143](https://datatracker.ietf.org/doc/html/rfc6143)):

- keyboard uses X11 keysyms (same model as RFB `KeyEvent`)
- pointer uses an RFB-style button bitmask plus pixel coordinates

## Keyboard: `key_event(x11_key, flags)`

- `x11_key` is an X11 keysym integer.
- `flags` is a bitfield:
  - bit `0`: down (`1`) / up (`0`)
  - bit `1`: repeat
  - bit `2`: shift
  - bit `3`: ctrl
  - bit `4`: alt
  - bit `5`: meta

Common keysyms:

- Left arrow: `0xFF51`
- Up arrow: `0xFF52`
- Right arrow: `0xFF53`
- Down arrow: `0xFF54`
- Escape: `0xFF1B`
- Enter: `0xFF0D`
- Tab: `0xFF09`
- Backspace: `0xFF08`
- Space: `0x0020`

For printable keys, pass Unicode/ASCII code points as keysyms (for example `A` is `0x41`, `a` is `0x61`).

## Pointer: `pointer_event(button_mask, x_px, y_px)`

- `button_mask` is a bitfield.
- `x_px`, `y_px` are integer pixel coordinates in render space.

Supported button bits:

- bit `0` (`1`): primary / button 1
- bit `1` (`2`): middle / button 2
- bit `2` (`4`): secondary / button 3
- bit `3` (`8`): back / button 4
- bit `4` (`16`): forward / button 5

This maps cleanly from DOM pointer `buttons` and keeps compatibility with RFB-style pointer state updates.

## Notes

- qip uses function calls for events instead of a binary packet stream.
- The event code choices are compatible with the RFB/X11 model, while keeping the wasm ABI minimal.

Reference:

- RFC 6143 (RFB 3.8), `KeyEvent` and `PointerEvent`: <https://www.rfc-editor.org/rfc/rfc6143>
