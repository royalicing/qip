# Unique Accessible Name Validator

`html-accessible-name-unique-validator.wasm` computes the accessible names of
exposed HTML accessibility nodes and traps when the same non-empty name occurs
more than once. On success it returns the input unchanged and aliases the input
buffer through `output_ptr()`.

The calculation is shared with `html-to-accessibility-tree.wasm`. It follows
the Accessible Name and Description Computation precedence for
`aria-labelledby`, `aria-label`, native HTML labels and text alternatives,
name-from-content roles, and `title`. It handles native sources including
`label`, `alt`, input values and defaults, `legend`, `caption`, and
`placeholder`, and excludes `hidden` and `aria-hidden="true"` subtrees unless
their text is reached through a naming reference.

```bash
printf '%s' '<button>Save</button><button>Cancel</button>' \
  | qip run components/text/html/html-accessible-name-unique-validator.wasm
```

This stricter project policy is not an ARIA conformance requirement. Repeated
names can be valid when surrounding context distinguishes the controls, but
this validator deliberately rejects them so each exposed named object is
unambiguous without that context.

The component does not execute CSS or JavaScript. CSS-generated text and
computed-style hiding therefore require a browser-level accessibility test;
static `hidden` and `aria-hidden` markup is handled directly. ID matching for
`aria-labelledby` uses literal UTF-8 attribute bytes rather than normalizing
character references.
