import assert from "node:assert/strict";
import http from "node:http";
import { readFile, mkdtemp, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createBridgeExtensionController } from "../dist/bridgeExtensionController.js";

const tempRoot = await mkdtemp(path.join(os.tmpdir(), "vibedeck-bootstrap-runtime-"));

try {
  const requestCounts = {};

  const agentPort = await reservePort();
  const agentBaseUrl = `http://127.0.0.1:${agentPort}`;
  const messages = { info: [], warn: [], error: [] };
  const commandRegistry = new Map();
  const configurationListeners = new Set();
  const statusBarItems = [];
  const panelMessages = [];
  let clipboardText = "";
  let agentServer;
  let agentStatus = {
    state: "stopped",
    launchMode: "binary",
    baseUrl: agentBaseUrl,
    command: "fake-local-agent",
    pid: 4242,
    repoRoot: tempRoot,
    outputTail: [],
  };

  const fakePanel = {
    title: "",
    webview: {
      html: "",
      onDidReceiveMessage() {
        return { dispose() {} };
      },
      async postMessage(message) {
        panelMessages.push(message);
        return true;
      },
    },
    reveal() {},
    onDidDispose() {
      return { dispose() {} };
    },
    dispose() {},
  };

  const configValues = new Map([
    ["vibedeckBridge.autoStart", true],
    ["vibedeckBridge.mode", "mock"],
    ["vibedeckBridge.commandProvider", "builtin_cursor_agent"],
    ["vibedeckBridge.tcpHost", "127.0.0.1"],
    ["vibedeckBridge.tcpPort", 0],
    ["vibedeckBridge.agent.autoStart", true],
    ["vibedeckBridge.agent.launchMode", "binary"],
    ["vibedeckBridge.agent.host", "127.0.0.1"],
    ["vibedeckBridge.agent.port", agentPort],
    ["vibedeckBridge.agent.repoRoot", tempRoot],
    ["vibedeckBridge.agent.binaryPath", process.execPath],
    ["vibedeckBridge.agent.args", []],
    ["vibedeckBridge.agent.extraEnv", []],
    ["vibedeckBridge.agent.runProfileFile", ""],
    ["vibedeckBridge.agent.signalingBaseUrl", "http://127.0.0.1:8081"],
    ["vibedeckBridge.agent.readyTimeoutMs", 10000],
    ["vibedeckBridge.agentBaseUrl", ""],
    ["vibedeckBridge.panelAutoRefreshMs", 60000],
  ]);

  const fakeVscode = {
    commands: {
      async executeCommand(command, ...args) {
        const handler = commandRegistry.get(command);
        if (!handler) {
          throw new Error("missing command: " + command);
        }
        return await handler(...args);
      },
      registerCommand(command, callback) {
        commandRegistry.set(command, callback);
        return {
          dispose() {
            commandRegistry.delete(command);
          },
        };
      },
      async getCommands() {
        return [...commandRegistry.keys()].sort();
      },
    },
    window: {
      activeTextEditor: undefined,
      async showTextDocument() {
        return undefined;
      },
      showInformationMessage(message) {
        messages.info.push(message);
        return message;
      },
      showWarningMessage(message) {
        messages.warn.push(message);
        return message;
      },
      showErrorMessage(message) {
        messages.error.push(message);
        return message;
      },
      createStatusBarItem() {
        const item = {
          text: "",
          tooltip: undefined,
          command: undefined,
          visible: false,
          show() {
            this.visible = true;
          },
          dispose() {
            this.visible = false;
          },
        };
        statusBarItems.push(item);
        return item;
      },
      createWebviewPanel() {
        return fakePanel;
      },
    },
    workspace: {
      textDocuments: [],
      workspaceFolders: [],
      async openTextDocument(openPath) {
        return {
          fileName: openPath,
          getText() {
            return "";
          },
        };
      },
      getConfiguration(section = "") {
        return {
          get(key, defaultValue) {
            const qualifiedKey = section ? `${section}.${key}` : key;
            return configValues.has(qualifiedKey) ? configValues.get(qualifiedKey) : defaultValue;
          },
        };
      },
      onDidChangeConfiguration(listener) {
        configurationListeners.add(listener);
        return {
          dispose() {
            configurationListeners.delete(listener);
          },
        };
      },
    },
    env: {
      clipboard: {
        async writeText(value) {
          clipboardText = value;
        },
      },
    },
    statusBarAlignment: { left: 1 },
    viewColumn: { one: 1 },
  };

  const fakeLocalAgent = {
    async start(settings, bridgeAddress) {
      if (!agentServer) {
        agentServer = http.createServer(async (req, res) => {
          const url = new URL(req.url || "/", "http://127.0.0.1");
          bumpRequestCount(requestCounts, url.pathname === "/healthz" ? "healthz" : routeKey(url.pathname));
          if (req.method === "GET" && url.pathname === "/healthz") {
            return json(res, 200, { status: "ok" });
          }
          if (req.method === "GET" && url.pathname === "/v1/agent/runtime/adapter") {
            return json(res, 200, {
              name: "bootstrap_smoke",
              mode: "bootstrap",
              ready: true,
              workspaceRoot: settings.repoRoot || tempRoot,
              binaryPath: process.execPath,
              notes: ["auto bootstrap"],
            });
          }
          if (req.method === "GET" && url.pathname === "/v1/agent/run-profiles") {
            return json(res, 200, { profiles: [] });
          }
          if (req.method === "GET" && url.pathname === "/v1/agent/threads") {
            return json(res, 200, { threads: [] });
          }
          return json(res, 404, { error: "not found" });
        });
        await new Promise((resolve) => agentServer.listen(settings.port, settings.host, resolve));
      }
      agentStatus = {
        state: "running",
        launchMode: settings.launchMode,
        baseUrl: `http://${settings.host}:${settings.port}`,
        command: `fake-local-agent bridge=${bridgeAddress}`,
        pid: 4242,
        repoRoot: settings.repoRoot,
        outputTail: [],
      };
      return { ...agentStatus, outputTail: [...agentStatus.outputTail] };
    },
    async stop() {
      if (agentServer) {
        await new Promise((resolve) => agentServer.close(resolve));
        agentServer = undefined;
      }
      agentStatus = {
        ...agentStatus,
        state: "stopped",
      };
    },
    status() {
      return { ...agentStatus, outputTail: [...agentStatus.outputTail] };
    },
    currentBaseUrl() {
      return agentStatus.baseUrl;
    },
  };

  const controller = createBridgeExtensionController(fakeVscode, {
    localAgent: fakeLocalAgent,
  });
  const context = { subscriptions: [] };

  try {
    await controller.activate(context);
    assert.match(statusBarItems[0]?.text ?? "", /\| agent/);

    await fakeVscode.commands.executeCommand("vibedeckBridge.copyAgentEnv");
    const addressMatch = clipboardText.match(/CURSOR_BRIDGE_TCP_ADDR = "([^"]+)"/);
    assert.ok(addressMatch, "bridge address should be copied to clipboard");
    const bridgeAddress = addressMatch[1];

    const bridgeName = await invokeBridgeJsonRpc(bridgeAddress, "name");
    assert.equal(bridgeName, "cursor-extension-bridge");

    await fakeVscode.commands.executeCommand("vibedeckBridge.openThreadPanel");
    await waitFor(() => panelMessages.length > 0, 5000);

    assert.ok((requestCounts.runtimeAdapter || 0) >= 1, "panel should call runtime adapter");
    assert.ok((requestCounts.runProfiles || 0) >= 1, "panel should call run profiles");
    assert.ok((requestCounts.threads || 0) >= 1, "panel should call threads");

    await fakeVscode.commands.executeCommand("vibedeckBridge.showStatus");
    const statusMessage = messages.info.at(-1) ?? messages.warn.at(-1) ?? messages.error.at(-1) ?? "";
    assert.match(statusMessage, /로컬 agent: 실행 중/);
    assert.match(statusMessage, new RegExp(`http://127\\.0\\.0\\.1:${agentPort}`));
    assert.match(statusMessage, /진단:/);

    console.log(
      JSON.stringify(
        {
          bridgeAddress,
          bridgeName,
          statusBarText: statusBarItems[0]?.text ?? "",
          requestCounts,
          statusMessage,
        },
        null,
        2,
      ),
    );
  } finally {
    await controller.deactivate();
    for (const disposable of [...context.subscriptions].reverse()) {
      disposable.dispose();
    }
    await fakeLocalAgent.stop();
  }
} finally {
  await rm(tempRoot, { recursive: true, force: true });
}

function bumpRequestCount(target, key) {
  target[key] = (target[key] || 0) + 1;
}

function routeKey(pathname) {
  if (pathname === "/v1/agent/runtime/adapter") return "runtimeAdapter";
  if (pathname === "/v1/agent/run-profiles") return "runProfiles";
  if (pathname === "/v1/agent/threads") return "threads";
  return "other";
}

function json(res, statusCode, body) {
  res.statusCode = statusCode;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

async function invokeBridgeJsonRpc(address, method, params) {
  const separator = address.lastIndexOf(":");
  const host = address.slice(0, separator);
  const port = Number.parseInt(address.slice(separator + 1), 10);
  if (!host || !Number.isInteger(port)) {
    throw new Error("invalid bridge address: " + address);
  }

  return await new Promise((resolve, reject) => {
    const socket = net.createConnection({ host, port }, () => {
      const request = {
        id: "bridge-" + Math.random().toString(16).slice(2),
        method,
      };
      if (params !== undefined) {
        request.params = params;
      }
      socket.write(JSON.stringify(request) + "\n");
    });

    socket.setEncoding("utf8");
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk;
      const newlineIndex = buffer.indexOf("\n");
      if (newlineIndex < 0) {
        return;
      }
      const line = buffer.slice(0, newlineIndex).trim();
      socket.end();
      if (!line) {
        reject(new Error("empty bridge response"));
        return;
      }
      const response = JSON.parse(line);
      if (response.error?.message) {
        reject(new Error(response.error.message));
        return;
      }
      resolve(response.result);
    });
    socket.on("error", (error) => {
      reject(error);
    });
  });
}

async function reservePort() {
  return await new Promise((resolve, reject) => {
    const server = net.createServer();
    server.listen(0, "127.0.0.1", () => {
      const address = server.address();
      if (!address || typeof address === "string") {
        reject(new Error("failed to reserve port"));
        return;
      }
      const port = address.port;
      server.close((error) => {
        if (error) {
          reject(error);
          return;
        }
        resolve(port);
      });
    });
    server.on("error", reject);
  });
}

function tick() {
  return new Promise((resolve) => setTimeout(resolve, 20));
}

async function waitFor(predicate, timeoutMs = 5000) {
  const startedAt = Date.now();
  while (Date.now() - startedAt < timeoutMs) {
    if (predicate()) {
      return;
    }
    await tick();
  }
  throw new Error("waitFor timeout");
}
