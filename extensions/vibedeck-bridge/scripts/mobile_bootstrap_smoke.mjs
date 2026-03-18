import assert from "node:assert/strict";

import {
  createMobileBootstrapController,
  buildMobileBootstrapLink,
  rewriteBootstrapBaseUrl,
} from "../dist/mobileBootstrapController.js";

const clipboard = { value: "" };
const postedMessages = [];
let ensureAgentReadyCount = 0;

const panel = {
  title: "",
  webview: {
    html: "",
    onDidReceiveMessage() {
      return { dispose() {} };
    },
    async postMessage(message) {
      postedMessages.push(message);
      return true;
    },
  },
  reveal() {},
  onDidDispose() {
    return { dispose() {} };
  },
  dispose() {},
};

const controller = createMobileBootstrapController(
  {
    workspace: {
      getConfiguration() {
        return {
          get(key, defaultValue) {
            const values = {
              "agentBaseUrl": "",
              "agent.host": "127.0.0.1",
              "agent.port": 8080,
              "agent.signalingBaseUrl": "http://127.0.0.1:8081",
              "mobileBootstrap.hostOverride": "",
              "mobileBootstrap.scheme": "vibedeck",
            };
            return key in values ? values[key] : defaultValue;
          },
        };
      },
    },
    window: {
      createWebviewPanel() {
        return panel;
      },
      showInformationMessage() {},
      showWarningMessage() {},
      showErrorMessage(message) {
        throw new Error(String(message));
      },
    },
    env: {
      clipboard: {
        async writeText(value) {
          clipboard.value = value;
        },
      },
    },
    viewColumn: { one: 1 },
  },
  {
    api: {
      async runtimeAdapter() {
        throw new Error("unused");
      },
      async bootstrap() {
        return {
          agentBaseUrl: "http://127.0.0.1:8080",
          signalingBaseUrl: "http://127.0.0.1:8081",
          workspaceRoot: "C:/demo/workspace",
          currentThreadId: "thread-qr-1",
          adapter: {
            name: "cursor-agent-cli",
            mode: "cursor_agent_cli",
            provider: "cursor",
            ready: true,
          },
          recentThreads: [],
        };
      },
      async runProfiles() {
        throw new Error("unused");
      },
      async threads() {
        throw new Error("unused");
      },
      async threadDetail() {
        throw new Error("unused");
      },
      async sendEnvelope() {
        throw new Error("unused");
      },
    },
    resolveLanHost() {
      return "192.168.0.24";
    },
    async ensureAgentReady() {
      ensureAgentReadyCount += 1;
    },
    async renderQRCodeSvg(value) {
      return `<svg data-value="${value}"></svg>`;
    },
  },
);

await controller.copyLink();
assert.equal(
  clipboard.value,
  "vibedeck://bootstrap?agent=http%3A%2F%2F192.168.0.24%3A8080&signaling=http%3A%2F%2F192.168.0.24%3A8081&thread=thread-qr-1",
);

await controller.openOrReveal();
assert.match(panel.webview.html, /VibeDeck Mobile Bootstrap/);
assert.equal(postedMessages.at(-1)?.type, "state");
assert.equal(postedMessages.at(-1)?.state.publicAgentBaseUrl, "http://192.168.0.24:8080");
assert.equal(postedMessages.at(-1)?.state.currentThreadId, "thread-qr-1");
assert.match(postedMessages.at(-1)?.state.qrSvg, /svg/);
assert.match(postedMessages.at(-1)?.state.warning, /0\.0\.0\.0/);
assert.equal(ensureAgentReadyCount, 2);

assert.equal(
  buildMobileBootstrapLink({
    scheme: "vibedeck",
    agentBaseUrl: "http://192.168.0.24:8080",
    signalingBaseUrl: "http://192.168.0.24:8081",
    threadId: "thread-qr-1",
  }),
  clipboard.value,
);
assert.equal(
  rewriteBootstrapBaseUrl("http://127.0.0.1:8080", "192.168.0.24"),
  "http://192.168.0.24:8080",
);

console.log("mobile bootstrap smoke ok");
