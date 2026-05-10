# Moon Phases

Controls:

- Left / Right: move day-by-day

Input is passed via a normal form input element:

<qip-play id="moon-phase-play">
  <input id="moon-phase-date" name="input" type="hidden" value="2026-05-31" />
  <source src="/modules/interactive/moon-phases.wasm" type="application/wasm" />
</qip-play>

<script>
  (function () {
    const el = document.querySelector("#moon-phase-play input[name=input]");
    el.value = new Date().toISOString().slice(0, 10);
  })();
</script>
