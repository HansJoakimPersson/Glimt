<script>
  let count = $state(0);
</script>

<svelte:head>
  <title>Counter</title>
</svelte:head>

<button onclick={() => count++}>
  Count: {count}
</button>

<style>
  button { color: rebeccapurple; }
</style>
