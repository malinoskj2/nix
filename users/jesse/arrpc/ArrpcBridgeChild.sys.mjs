export class ArrpcBridgeChild extends JSWindowActorChild {
  handleEvent() {
    // The bridge reaches into Discord's webpack modules, so it runs with the page's principal and
    // without Xrays, as if it were a page script.
    const sandbox = Cu.Sandbox(this.contentWindow, {
      sandboxName: "arRPC bridge",
      sandboxPrototype: this.contentWindow,
      wantXrays: false,
    });
    Cu.evalInSandbox(BRIDGE, sandbox, "latest", "resource://arrpc-bridge/bridge.js", 1);
  }
}
