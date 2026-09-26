(() => {
  // The bar is dark glass, so it takes claude.ai's dark tokens: the design system's through its
  // dark scope, and the older ones through the page's theme attributes with the mode set to dark.
  // The title and the mode switcher are design-system roots of their own that pin light mode.
  const bars = ".dframe-chrome-bar";
  const attributeFilter = ["data-mode", "data-theme", "data-color-version"];
  const watched = new WeakSet();
  const set = (el, key, value) => {
    if (value !== undefined && el.dataset[key] !== value) el.dataset[key] = value;
  };
  const scope = (bar) => {
    const root = document.documentElement.dataset;
    if (!bar.classList.contains("cds-dark-scope")) bar.classList.add("cds-dark-scope");
    set(bar, "mode", "dark");
    set(bar, "theme", root.theme);
    set(bar, "colorVersion", root.colorVersion);
    for (const inner of bar.querySelectorAll(".cds-root[data-mode]")) set(inner, "mode", "dark");
    if (watched.has(bar)) return;
    watched.add(bar);
    new MutationObserver(() => scope(bar)).observe(bar, {
      subtree: true,
      childList: true,
      attributeFilter: ["class", ...attributeFilter],
    });
  };
  const scopeAll = () => {
    for (const bar of document.querySelectorAll(bars)) scope(bar);
  };
  scopeAll();
  new MutationObserver(scopeAll).observe(document.documentElement, { attributeFilter });
  // Streaming a reply mutates the page nonstop, so only rescan when a bar itself appears.
  new MutationObserver((records) => {
    const added = records.some(({ type, target, addedNodes }) =>
      type === "attributes"
        ? !watched.has(target) && target.matches(bars)
        : [...addedNodes].some((node) => node.matches?.(bars) || node.querySelector?.(bars)),
    );
    if (added) scopeAll();
  }).observe(document.documentElement, {
    subtree: true,
    childList: true,
    attributeFilter: ["class"],
  });
})();
