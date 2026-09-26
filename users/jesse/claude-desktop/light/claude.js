(() => {
  // The bar is dark glass, so it takes claude.ai's dark tokens: the design system's through its
  // dark scope, and the older ones through the page's theme attributes with the mode set to dark.
  // The title and the mode switcher are design-system roots of their own that pin light mode.
  const set = (el, key, value) => {
    if (value !== undefined && el.dataset[key] !== value) el.dataset[key] = value;
  };
  const scope = () => {
    const root = document.documentElement.dataset;
    for (const bar of document.querySelectorAll(".dframe-chrome-bar")) {
      if (!bar.classList.contains("cds-dark-scope")) bar.classList.add("cds-dark-scope");
      set(bar, "mode", "dark");
      set(bar, "theme", root.theme);
      set(bar, "colorVersion", root.colorVersion);
      for (const inner of bar.querySelectorAll(".cds-root[data-mode]")) set(inner, "mode", "dark");
    }
  };
  scope();
  new MutationObserver(scope).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributeFilter: ["class", "data-mode", "data-theme", "data-color-version"],
  });
})();
