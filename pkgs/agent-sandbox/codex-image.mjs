import { randomBytes } from "node:crypto";
import { copyFileSync, mkdirSync, mkdtempSync, readlinkSync, rmSync, statSync } from "node:fs";
import net from "node:net";
import { homedir } from "node:os";
import { basename, extname, join, resolve } from "node:path";
import { parseArgs } from "node:util";

const socketDir = process.env.AGENT_SANDBOX_CODEX_SOCKET_DIR ?? "/run/agent-sandbox-codex";
// The server runs in its own container with only the sandbox home mounted, so the turn's working
// directory and any input images must live under it.
const scratch = join(homedir(), ".cache", "codex-image");

const prompt = (description) =>
  `Use $imagegen to generate ${description}. Don't run shell commands. ` +
  "Reply with only the absolute path of each generated image, one per line.";

function fail(message) {
  throw new Error(message);
}

// Codex listens on a socket under its own /tmp and leaves a symlink at the listen path. The
// server's /tmp/codex-daemon-$UID is this directory, so the target's name resolves here.
function serverSocket() {
  const link = join(socketDir, "app-server.sock");
  try {
    const target = join(socketDir, basename(readlinkSync(link)));
    if (statSync(target).isSocket()) return target;
  } catch {}
  fail(`the shared Codex app-server isn't running (${link} has no socket)`);
}

// The app-server speaks JSON-RPC over WebSocket on its Unix socket. Node's WebSocket can't take a
// socket path, so this is the small client side of RFC 6455 that the protocol needs.
class Connection {
  constructor(path) {
    this.socket = net.connect(path);
    this.buffer = Buffer.alloc(0);
    this.fragments = [];
    this.queue = [];
    this.waiters = [];
    this.closed = null;
    this.handshake = new Promise((resolveHandshake, rejectHandshake) => {
      this.socket.once("connect", () => {
        const key = randomBytes(16).toString("base64");
        this.socket.write(
          "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" +
            `Sec-WebSocket-Key: ${key}\r\nSec-WebSocket-Version: 13\r\n\r\n`,
        );
      });
      this.socket.on("data", (chunk) => {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        if (this.upgraded) return this.parse();
        const end = this.buffer.indexOf("\r\n\r\n");
        if (end < 0) return;
        const head = this.buffer.subarray(0, end).toString();
        this.buffer = this.buffer.subarray(end + 4);
        if (!head.startsWith("HTTP/1.1 101")) return rejectHandshake(new Error(head.split("\r\n")[0]));
        this.upgraded = true;
        resolveHandshake();
        this.parse();
      });
      this.socket.on("error", (error) => {
        rejectHandshake(error);
        this.close(error.message);
      });
      this.socket.on("close", () => this.close("socket closed"));
    });
  }

  parse() {
    for (;;) {
      if (this.buffer.length < 2) return;
      const opcode = this.buffer[0] & 0x0f;
      const final = (this.buffer[0] & 0x80) !== 0;
      let length = this.buffer[1] & 0x7f;
      let offset = 2;
      if (length === 126) {
        if (this.buffer.length < 4) return;
        length = this.buffer.readUInt16BE(2);
        offset = 4;
      } else if (length === 127) {
        if (this.buffer.length < 10) return;
        length = Number(this.buffer.readBigUInt64BE(2));
        offset = 10;
      }
      if (this.buffer.length < offset + length) return;
      const payload = this.buffer.subarray(offset, offset + length);
      this.buffer = this.buffer.subarray(offset + length);
      if (opcode === 0x8) {
        this.close(`server closed the connection (${payload.length >= 2 ? payload.readUInt16BE(0) : "no code"})`);
      } else if (opcode === 0x9) {
        this.frame(0xa, payload);
      } else if (opcode === 0x0 || opcode === 0x1) {
        this.fragments.push(Buffer.from(payload));
        if (final) {
          const text = Buffer.concat(this.fragments).toString();
          this.fragments = [];
          this.deliver(JSON.parse(text));
        }
      }
    }
  }

  frame(opcode, payload) {
    const mask = randomBytes(4);
    const length = payload.length;
    const header =
      length < 126
        ? Buffer.from([0x80 | opcode, 0x80 | length])
        : length < 65536
          ? Buffer.from([0x80 | opcode, 0x80 | 126, length >> 8, length & 0xff])
          : Buffer.concat([Buffer.from([0x80 | opcode, 0x80 | 127]), bigLength(length)]);
    const masked = Buffer.alloc(length);
    for (let i = 0; i < length; i++) masked[i] = payload[i] ^ mask[i % 4];
    this.socket.write(Buffer.concat([header, mask, masked]));
  }

  send(message) {
    this.frame(0x1, Buffer.from(JSON.stringify(message)));
  }

  deliver(message) {
    const waiter = this.waiters.shift();
    if (waiter) waiter.resolve(message);
    else this.queue.push(message);
  }

  close(reason) {
    if (this.closed) return;
    this.closed = reason;
    for (const waiter of this.waiters.splice(0)) waiter.reject(new Error(reason));
    this.socket.destroy();
  }

  next() {
    if (this.queue.length) return Promise.resolve(this.queue.shift());
    if (this.closed) return Promise.reject(new Error(this.closed));
    return new Promise((resolveNext, rejectNext) => this.waiters.push({ resolve: resolveNext, reject: rejectNext }));
  }
}

function bigLength(length) {
  const buffer = Buffer.alloc(8);
  buffer.writeBigUInt64BE(BigInt(length));
  return buffer;
}

class Client {
  constructor(connection) {
    this.connection = connection;
    this.nextId = 0;
  }

  async request(method, params) {
    const id = ++this.nextId;
    this.connection.send({ jsonrpc: "2.0", id, method, params });
    for (;;) {
      const message = await this.connection.next();
      if (message.id === id && !("method" in message)) {
        if (message.error) fail(`${method} failed: ${JSON.stringify(message.error)}`);
        return message.result;
      }
      this.answer(message);
    }
  }

  // Image generation needs no approvals; refuse anything that asks for one.
  answer(message) {
    if ("id" in message && "method" in message) {
      this.connection.send({
        jsonrpc: "2.0",
        id: message.id,
        error: { code: -32601, message: "codex-image does not answer server requests" },
      });
    }
  }
}

async function main() {
  const { values, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      image: { type: "string", short: "i", multiple: true, default: [] },
      model: { type: "string", short: "m", default: "gpt-6.2-sol" },
      effort: { type: "string", default: "medium" },
      help: { type: "boolean", short: "h" },
    },
  });
  if (values.help || positionals.length !== 1) {
    console.error("usage: codex-image [-i image[,image...]]... [-m model] [--effort effort] <description>");
    process.exit(values.help ? 0 : 2);
  }

  const socketPath = serverSocket();
  mkdirSync(scratch, { recursive: true });
  const work = mkdtempSync(join(scratch, "run-"));
  try {
    const input = [{ type: "text", text: prompt(positionals[0]), text_elements: [] }];
    values.image
      .flatMap((arg) => arg.split(","))
      .filter(Boolean)
      .forEach((image, index) => {
        const source = resolve(image);
        const copy = join(work, `input-${index}${extname(source)}`);
        copyFileSync(source, copy);
        input.push({ type: "localImage", path: copy });
      });

    const connection = new Connection(socketPath);
    await connection.handshake.catch((error) => fail(`couldn't connect to the shared app-server: ${error.message}`));
    const client = new Client(connection);
    await client.request("initialize", { clientInfo: { name: "codex-image", version: "1" } });
    connection.send({ jsonrpc: "2.0", method: "initialized" });
    const { thread } = await client.request("thread/start", {
      model: values.model,
      cwd: work,
      sandbox: "read-only",
      approvalPolicy: "never",
      ephemeral: true,
    });
    await client.request("turn/start", { threadId: thread.id, input, effort: values.effort });

    const paths = [];
    let reply = "";
    for (;;) {
      const message = await connection.next().catch((error) => fail(`lost the shared app-server: ${error.message}`));
      const { method, params = {} } = message;
      if (params.threadId && params.threadId !== thread.id) continue;
      if (method === "item/completed") {
        const { item } = params;
        if (item.type === "imageGeneration") {
          if (item.savedPath) paths.push(item.savedPath);
          else if (item.failure) console.error(`codex-image: generation failed: ${JSON.stringify(item.failure)}`);
        } else if (item.type === "agentMessage") {
          reply = item.text ?? "";
        }
      } else if (method === "turn/completed") {
        const { turn } = params;
        if (turn.status !== "completed") fail(`turn ${turn.status}: ${JSON.stringify(turn.error)}`);
        break;
      } else {
        client.answer(message);
      }
    }
    connection.close("done");

    if (!paths.length) fail(`no image was generated. Codex replied:\n${reply}`);
    console.log(paths.join("\n"));
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}

try {
  await main();
} catch (error) {
  console.error(`codex-image: ${error.message}`);
  process.exitCode = 1;
}
