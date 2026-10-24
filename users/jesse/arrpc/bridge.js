class ReconnectingSocket {
  constructor(url) {
    this.url = url;
    this.retries = [];
    this.connect();
  }

  connect() {
    const socket = new WebSocket(this.url);
    socket.onmessage = (event) => this.deliver(event);
    socket.onclose = () => setTimeout(() => this.connect(), 5000);
  }

  // arRPC replays its last activity as soon as the page connects, often before Discord has loaded
  // the modules the bridge dispatches through, so each activity is delivered again shortly after.
  deliver(event) {
    this.retries.forEach(clearTimeout);
    this.onmessage?.(event);
    this.retries = [3000, 15000].map((delay) => setTimeout(() => this.onmessage?.(event), delay));
  }
}

((WebSocket) => {
@bridgeMod@
})(ReconnectingSocket);
