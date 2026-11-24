<template>
  <button @click="count++">Klick {{ count }}</button>
</template>

<script setup>
import { ref } from "vue";
// Vue
const count = ref(0);
</script>
