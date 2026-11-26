import { createRouter, createWebHistory } from "vue-router";
import ItemList from "./ItemList.vue";

export const router = createRouter({
  history: createWebHistory(),
  routes: [{ path: "/", component: ItemList }],
});
