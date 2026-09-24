{
  const { app, BrowserWindow } = require("electron");
  const fs = require("node:fs");
  const css = fs.readFileSync("@theme@/claude.css", "utf8");
  const shellCss = fs.readFileSync("@theme@/shell.css", "utf8");
  const codeThemeDark = fs.readFileSync("@theme@/code-theme-dark", "utf8");
  // The app reads its editor preferences once at load, so a changed one needs a reload.
  const pinCodeTheme = `(() => {
    const key = "epitaxy-editor-prefs";
    const prefs = JSON.parse(localStorage.getItem(key) ?? "null") ?? { state: {}, version: 0 };
    if (prefs.state?.codeThemeDark === ${JSON.stringify(codeThemeDark)}) return false;
    prefs.state = { ...prefs.state, codeThemeDark: ${JSON.stringify(codeThemeDark)} };
    localStorage.setItem(key, JSON.stringify(prefs));
    return true;
  })()`;
  // The page paints the title bar under the window controls. The app would tint them to match
  // a modal's scrim, which on a transparent color comes out opaque black.
  const setTitleBarOverlay = BrowserWindow.prototype.setTitleBarOverlay;
  BrowserWindow.prototype.setTitleBarOverlay = function (options) {
    return setTitleBarOverlay.call(this, { ...options, color: "#00000000" });
  };
  app.on("web-contents-created", (_, contents) => {
    let reloaded = false;
    // Inserted CSS lasts only for the current document, so reapply it after every load.
    contents.on("dom-ready", () => {
      if (contents.getURL().endsWith("/main_window/index.html")) contents.insertCSS(shellCss);
      if (!contents.getURL().startsWith("https://claude.ai/")) return;
      contents.insertCSS(css);
      contents.executeJavaScript(pinCodeTheme).then((changed) => {
        if (changed && !reloaded) {
          reloaded = true;
          contents.reload();
        }
      });
    });
  });
}
