<template>
  <main class="preview">
    <h1>{{ title }}</h1>
    <button @click="count++">Count: {{ count }}</button>
  </main>
</template>

<script setup lang="ts">
import { ref } from 'vue';

const title = 'Glimt preview';
const count = ref(0);
</script>

<style scoped>
.preview { color: #2563eb; }
</style>
