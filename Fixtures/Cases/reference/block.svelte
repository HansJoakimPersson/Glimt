{#each items as item, i}
  <li>{i}: {item.name}</li>
{:else}
  <p>Tom lista</p>
{/each}
