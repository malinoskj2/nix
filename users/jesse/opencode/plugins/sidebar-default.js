export default {
  id: "sidebar-default",
  tui: async (api) => {
    api.kv.set("sidebar", "hide")
  },
}
