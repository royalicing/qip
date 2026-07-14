# A strict CSS selector tier for QIP

QIP's strict CSS tier should accept the selectors commonly used in ordinary application stylesheets while keeping parsing, matching, and CSS nesting within explicit memory and work limits. It is intended for static HTML analysis, including `html-wcag-contrast-aa`, rather than as a substitute for a browser's live CSS engine.

The tier must support ARIA attribute selectors. These are routine CSS, not an optional accessibility extension:

```css
[aria-label]
[aria-hidden="true"]
[aria-expanded="true"] > .disclosure-panel
[aria-labelledby~="checkout-heading"]
[role~="button"]:not([aria-disabled="true"])
```

The useful boundary is therefore not “simple selectors only.” It is a standards-based selector subset with bounded syntax, bounded document structures, and a deterministic matching budget.

## Proposed selector profile

The first version should support:

- Universal, type, ID, and class selectors.
- Compound selectors such as `button.primary[aria-pressed="true"]`.
- Descendant, child, adjacent-sibling, and general-sibling combinators.
- Attribute presence and all six value operators: `=`, `~=`, `|=`, `^=`, `$=`, and `*=`.
- Attribute selector `i` and `s` value-comparison flags.
- `:root`, `:empty`, `:first-child`, `:last-child`, and `:only-child`.
- Child and type-position pseudo-classes: `:nth-child()`, `:nth-last-child()`, `:nth-of-type()`, and `:nth-last-of-type()` with `odd`, `even`, or an `An+B` expression, plus their `first-`, `last-`, and `only-` forms.
- Static HTML form-state pseudo-classes: `:enabled`, `:disabled`, `:checked`, `:required`, and `:optional`.
- `:is()`, `:where()`, and `:not()`, including selector lists within their arguments.
- CSS nesting with `&`, provided the resolved selector remains inside this profile.
- CSS escapes, comments, quoted strings, and other tokenization required by CSS Syntax.

This covers selectors such as:

```css
:root
main .toolbar > button[aria-expanded="true"] + [role="menu"]
input[aria-invalid]:not([aria-invalid="false"])
:is(button, [role="button"])[aria-disabled="true"]
fieldset:disabled input:disabled
input[type="checkbox"]:required:not(:checked)

.card {
  & > :is(h2, h3) {
    color: CanvasText;
  }

  &[aria-current="page"] .label {
    font-weight: bold;
  }
}
```

Supporting these features does not require backtracking over every possible DOM path. A matcher can work right-to-left, scan ancestors or siblings once for each combinator, and represent selector lists and nesting as shared syntax trees rather than expanded strings.

## Initial exclusions

The first strict tier should reject these valid but more expensive or environment-dependent selectors:

- `:has()`. Matching can require a relative search below or around every candidate element. It also has unusually broad invalidation costs in a live document.
- The `of <selector-list>` clause in `:nth-child()` and `:nth-last-child()`. Plain `An+B` and the type-position pseudo-classes remain supported.
- Shadow DOM selectors and pseudo-elements, including `:host`, `::slotted()`, `::part()`, `::before`, and `::after`.
- Namespaced selectors. The initial input model is `text/html`, not XML namespace processing.
- Live-state pseudo-classes such as `:hover`, `:focus`, `:active`, and `:visited`.
- Layout- or browser-state-dependent selectors where a static HTML document cannot supply an authoritative result.

The supported form-state pseudo-classes must use the initial state produced by parsing the static HTML document. They are not aliases for attribute presence:

- `:disabled` and `:enabled` use HTML's actual-disabled rules, including disabled `fieldset`, `select`, and `optgroup` ancestry and the `legend` exception.
- `:checked` uses the checkedness of radio buttons and checkboxes and the selectedness of `option` elements.
- `:required` and `:optional` match only the form controls to which HTML's requiredness rules apply.
- `aria-disabled`, `aria-checked`, and `aria-required` do not affect these pseudo-classes. Authors can select those serialized accessibility states with attribute selectors.

The matcher does not model later changes from scripts or user interaction. Other form pseudo-classes, including validity, indeterminate, default, placeholder, and user-interaction states, remain outside the first version until their complete HTML state models are implemented.

These exclusions are profile decisions, not claims that the selectors are unsafe CSS. A future tier can add a feature when it has a bounded matching strategy and enough document state to implement the specified semantics.

## ARIA and case sensitivity

ARIA attributes use ordinary CSS attribute-selector rules.

In an HTML document, attribute names are ASCII case-insensitive, so `[ARIA-EXPANDED]` and `[aria-expanded]` address the same attribute. Attribute values do not inherit ARIA's semantic parsing rules during CSS matching. Unless HTML defines a value as ASCII case-insensitive or the selector supplies the `i` flag, value comparison is case-sensitive.

For example:

```css
[aria-expanded="true"]  /* does not match aria-expanded="TRUE" by default */
[aria-expanded="true" i] /* does */
```

The same principle applies to `role`. The selector engine compares the source attribute value according to CSS and HTML selector rules; it must not canonicalize roles or ARIA states before matching. Token matching remains available where the attribute is a whitespace-separated list:

```css
[role~="button"]
[aria-labelledby~="billing-heading"]
```

ID and class matching should use no-quirks HTML behavior and remain case-sensitive. The static analyzer should reject quirks-mode documents if it cannot reproduce the quirks-mode class matching rules.

This separation is important: ARIA determines the accessibility meaning of an attribute, while Selectors and the host language determine whether a CSS selector matches its serialized value.

## Bounded parsing and matching

Passing `wasm-bounded-loops` proves that individual loops have finite bounds. It does not by itself prevent several bounded loops from multiplying into an impractical amount of work. The CSS tier therefore needs both structural limits and a global work counter.

Suggested initial limits are:

| Resource | Limit |
| --- | ---: |
| Input HTML, including embedded CSS | 1 MiB |
| Elements | 16,384 |
| DOM depth | 128 |
| Attributes per element | 64 |
| Style rules | 2,048 |
| Selector bytes per rule | 2,048 |
| Compounds in one complex selector | 16 |
| Alternatives in one selector list | 64 |
| `:is()`, `:where()`, and `:not()` nesting depth | 8 |
| CSS rule nesting depth | 8 |
| `&` occurrences in one nested selector | 4 |

The 1 MiB input cap already limits total attribute and identifier storage. Attribute values should therefore remain slices into the input rather than being copied into fixed-size buffers or truncated. This avoids an arbitrary limit that would be especially surprising for `aria-label` and ID-reference attributes.

The numeric limits are a proposed starting point, not magic constants. They should be benchmarked against representative documents before becoming a versioned contract.

### Work accounting

Every operation that can occur inside a data-dependent loop should spend from one shared selector-work budget. At minimum, charge for:

- each candidate element and rule pair considered;
- each selector-list branch entered;
- each simple selector tested;
- each ancestor or sibling traversed;
- each attribute or token examined; and
- each byte compared or scanned by attribute value operators.

Charging compared bytes matters for `[attr*="value"]`: bounding the number of selectors and attributes is insufficient if a matcher can repeatedly scan long values.

An implementation can optimize candidate selection with indexes for IDs, classes, types, and attribute names, but correctness and termination must not depend on those indexes. The work counter supplies the hard execution bound even for an adversarial document. Exceeding it rejects the analysis; it must never produce a partial result.

The initial work-budget value should be set with `qip bench` using ordinary pages and adversarial cases, then recorded as part of the tier version. QIP's WASM instruction limit remains a final host-side backstop.

## CSS nesting without selector explosion

CSS nesting must not be implemented by repeatedly generating a Cartesian product of parent and child selector strings. A parent list with `m` alternatives across `k` nesting levels can otherwise materialize roughly `m^k` selectors before matching begins.

Instead, parse nesting into a shared selector graph:

- A nested selector's `&` node refers to its parent selector list.
- Parent alternatives are visited lazily during matching.
- Each visited alternative spends selector work.
- The graph is acyclic because rule nesting has a fixed depth and parent references only point outward.
- Specificity is calculated from the graph according to CSS Nesting and Selectors rules, without textual expansion.

This preserves useful nesting, including selector lists, while bounding both retained syntax and evaluated alternatives.

## Parsing and failure behavior

The tier needs to distinguish malformed CSS from valid CSS outside the strict profile:

1. **Invalid CSS** follows the relevant CSS error-recovery rule. An invalid selector normally causes its style rule to be discarded; forgiving selector lists such as `:is()` follow their specified recovery behavior.
2. **Valid but unsupported CSS** rejects the document as outside the strict tier. Silently ignoring `:has()` or a state pseudo-class could make a contrast checker report a false pass.
3. **A structural or work limit is exceeded** rejects the document with the name of the exhausted limit.
4. **A supported document has a WCAG failure** uses the component's normal validation failure path.

The parser should use standards-correct CSS tokenization rather than scanning punctuation directly. Brackets, escapes, comments, strings, and functional pseudo-classes make byte-oriented splitting unreliable.

Diagnostics should include the rule offset and unsupported feature where possible:

```text
strict CSS tier rejected rule at byte 1842: :has() is outside css-strict-v1
```

For QIP content components, rejection may ultimately be represented by a trap, but a diagnostic output or host-visible error code is preferable when the ABI permits it.

## Cascade boundary

A selector profile is only one part of a correct contrast calculation. `html-wcag-contrast-aa` must also define which stylesheet and cascade features it understands. External stylesheets, media and container queries, cascade layers, custom properties, inheritance, generated content, and browser defaults can change the computed colors even when every selector is supported.

The component should reject any relevant stylesheet construct it cannot evaluate. It should not treat unsupported rules as if they did not exist. An initial static environment can reasonably support embedded `<style>` rules and `style` attributes, use a declared viewport and media state, and reject external or environment-dependent CSS.

That boundary should be documented separately from `css-strict-v1` so the selector engine can be reused by validators that do not need a complete cascade.

## Verification requirements

An implementation of `css-strict-v1` should:

- pass `wasm-strict-profile` and `wasm-bounded-loops`;
- avoid recursion in tokenization, parsing, nesting resolution, and matching;
- use fixed-capacity stacks or arenas checked before every append;
- enforce all structural limits before accessing their bounded storage;
- decrement the work counter before each data-dependent matching step; and
- include adversarial tests for deep descendants, long sibling lists, substring attributes, nested selector lists, escaped identifiers, and nested rules with many alternatives.

Conformance tests should cover HTML selector case sensitivity, ARIA examples, inherited disabledness, the disabled `fieldset` first-`legend` exception, checkbox and radio checkedness, option selectedness, and requiredness explicitly. They should verify rejection as well as successful matching, since a false “unsupported rule was ignored” result is more dangerous for a validator than a clear refusal to analyze the document.

## When not to use this tier

Use a browser engine when the result depends on live DOM mutation, Shadow DOM, user interaction, external network-loaded styles, layout, generated content, container queries, or selectors outside the profile. A browser is also the right choice when exact parity with a particular browser version is the product requirement.

The strict tier is for deterministic processing of bounded, static input. It buys auditability and predictable execution by rejecting documents whose CSS environment it cannot faithfully model.

## Specification references

- [Selectors Level 4](https://www.w3.org/TR/selectors-4/)
- [CSS Syntax Module Level 3](https://www.w3.org/TR/css-syntax-3/)
- [CSS Nesting Module Level 1](https://www.w3.org/TR/css-nesting-1/)
- [HTML: case-sensitivity of selectors](https://html.spec.whatwg.org/multipage/semantics-other.html#case-sensitivity-of-selectors)
- [WAI-ARIA](https://www.w3.org/TR/wai-aria-1.2/)
