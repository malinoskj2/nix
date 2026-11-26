<script setup lang="ts">
defineProps<{ items: string[] }>();
</script>

<template>
  <ul>
    <li v-for="(item, i) in items" :key="i">{{ item }}</li>
  </ul>
</template>
