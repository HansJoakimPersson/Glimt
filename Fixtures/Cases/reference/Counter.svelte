<script>
  let count = 0;
  // Svelte
  function increment() { count += 1; }
</script>

<button on:click={increment}>Klick {count}</button>

<style>
  button { color: steelblue; }
</style>
