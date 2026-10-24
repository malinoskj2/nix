
Services.io
  .getProtocolHandler("resource")
  .QueryInterface(Ci.nsIResProtocolHandler)
  .setSubstitution("arrpc-bridge", Services.io.newURI("file://@bridge@/"));
ChromeUtils.registerWindowActor("ArrpcBridge", {
  child: {
    esModuleURI: "resource://arrpc-bridge/ArrpcBridgeChild.sys.mjs",
    events: { DOMContentLoaded: {} },
  },
  matches: ["https://discord.com/*", "https://canary.discord.com/*", "https://ptb.discord.com/*"],
  messageManagerGroups: ["browsers"],
  // Web content processes only run actors that opt in to them.
  safeForUntrustedWebProcess: true,
});
