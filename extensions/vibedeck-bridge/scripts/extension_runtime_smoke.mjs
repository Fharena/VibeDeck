import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { createBridgeExtensionController } from "../dist/bridgeExtensionController.js";

const tempRoot = await mkdtemp(path.join(os.tmpdir(), "vibedeck-extension-runtime-"));

try {
  const workspaceRoot = path.join(tempRoot, "workspace");
  await seedGitWorkspace(workspaceRoot);

  const fakeAgentPath = path.join(tempRoot, "fake-cursor-agent.mjs");
  await writeFile(
    fakeAgentPath,
    [
      'import { readFileSync, writeFileSync } from "node:fs";',
      'import path from "node:path";',
      'const secret = readFileSync(path.join(process.cwd(), ".env.local"), "utf8").trim();',
      'writeFileSync(path.join(process.cwd(), "notes.txt"), `base\\n${secret}\\n`, "utf8");',
      'process.stdout.write(JSON.stringify({ summary: "updated notes.txt through extension runtime" }));',
    ].join("\n"),
    "utf8",
  );

  const messages = {
    info: [],
    warn: [],
    error: [],
  };
  const commandRegistry = new Map();
  const configurationListeners = new Set();
  const statusBarItems = [];
  let clipboardText = "";

  const configValues = new Map([
    ["vibedeckBridge.autoStart", true],
    ["vibedeckBridge.mode", "command"],
    ["vibedeckBridge.commandProvider", "builtin_cursor_agent"],
    ["vibedeckBridge.tcpHost", "127.0.0.1"],
    ["vibedeckBridge.tcpPort", 0],
    ["vibedeckBridge.cursorAgent.workspaceRoot", workspaceRoot],
    ["vibedeckBridge.cursorAgent.gitBin", "git"],
    ["vibedeckBridge.cursorAgent.bin", process.execPath],
    ["vibedeckBridge.cursorAgent.extraArgs", [fakeAgentPath]],
    ["vibedeckBridge.cursorAgent.extraEnv", []],
    ["vibedeckBridge.cursorAgent.syncIgnoredPaths", [".env.local"]],
    ["vibedeckBridge.cursorAgent.trustWorkspace", false],
    ["vibedeckBridge.cursorAgent.model", ""],
    ["vibedeckBridge.cursorAgent.useWsl", false],
    ["vibedeckBridge.cursorAgent.promptTimeoutMs", 30000],
    ["vibedeckBridge.cursorAgent.runTimeoutMs", 30000],
  ]);

  const document = {
    fileName: path.join(workspaceRoot, "notes.txt"),
    isDirty: true,
    getText() {
      return "base";
    },
  };

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
      activeTextEditor: {
        document,
        selection: null,
      },
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
      createStatusBarItem(_alignment, _priority) {
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
    },
    workspace: {
      textDocuments: [document],
      workspaceFolders: [{ uri: { fsPath: workspaceRoot } }],
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
    statusBarAlignment: {
      left: 1,
    },
  };

  const controller = createBridgeExtensionController(fakeVscode);
  const context = {
    subscriptions: [],
  };

  try {
    await controller.activate(context);

    await fakeVscode.commands.executeCommand("vibedeckBridge.validateCommands");
    const validateMessage = messages.info.at(-1) ?? messages.warn.at(-1) ?? messages.error.at(-1) ?? "";
    assert.match(validateMessage, /필수 명령 준비: 5\/5/);
    assert.match(validateMessage, /진단:/);

    await fakeVscode.commands.executeCommand("vibedeckBridge.copyAgentEnv");
    const addressMatch = clipboardText.match(/CURSOR_BRIDGE_TCP_ADDR = "([^"]+)"/);
    assert.ok(addressMatch, "bridge address should be copied to clipboard");
    const bridgeAddress = addressMatch[1];

    await fakeVscode.commands.executeCommand("vibedeckBridge.copySmokeCommand");
    assert.equal(
      clipboardText,
      "npm --prefix extensions/vibedeck-bridge run smoke:extension",
    );

    const bridgeName = await invokeBridgeJsonRpc(bridgeAddress, "name");
    assert.equal(bridgeName, "cursor-extension-bridge");

    const capabilities = await invokeBridgeJsonRpc(bridgeAddress, "capabilities");
    assert.equal(capabilities.supportsStructuredPatch, true);

    const task = await invokeBridgeJsonRpc(bridgeAddress, "submitTask", {
      prompt: "Modify only notes.txt. Make the final contents exactly two lines: base and ignored-secret.",
      template: "smoke",
      context: {
        changedFiles: [],
      },
    });
    assert.ok(task.taskId, "task id should be returned");

    const patch = await invokeBridgeJsonRpc(bridgeAddress, "getPatch", {
      taskId: task.taskId,
    });
    assert.ok(patch, "patch should be returned");
    assert.equal(patch.files.length, 1);
    assert.equal(patch.files[0].path, "notes.txt");
    assert.match(patch.files[0].hunks[0].diff, /ignored-secret/);

    const applyResult = await invokeBridgeJsonRpc(bridgeAddress, "applyPatch", {
      taskId: task.taskId,
      mode: "all",
    });
    assert.equal(applyResult.status, "success");

    const run = await invokeBridgeJsonRpc(bridgeAddress, "runProfile", {
      taskId: task.taskId,
      jobId: "job_smoke",
      profileId: "smoke",
      command: "git diff -- notes.txt",
    });
    const runResult = await invokeBridgeJsonRpc(bridgeAddress, "getRunResult", {
      runId: run.runId,
    });
    assert.equal(runResult.status, "passed");

    const contextResult = await invokeBridgeJsonRpc(bridgeAddress, "getContext", {
      options: {
        includeActiveFile: false,
        includeSelection: false,
        includeLatestError: true,
        includeWorkspaceSummary: true,
      },
    });
    assert.equal(contextResult.lastRunProfile, "smoke");
    assert.equal(contextResult.lastRunStatus, "passed");

    const notesContent = await readFile(path.join(workspaceRoot, "notes.txt"), "utf8");
    assert.equal(notesContent.trim(), "base\nignored-secret");

    console.log(
      JSON.stringify(
        {
          bridgeAddress,
          bridgeName,
          patchSummary: patch.summary,
          patchFiles: patch.files.map((file) => file.path),
          applyStatus: applyResult.status,
          runStatus: runResult.status,
          validateMessage,
          statusBarText: statusBarItems[0]?.text ?? "",
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
  }
} finally {
  await rm(tempRoot, { recursive: true, force: true });
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

async function seedGitWorkspace(workspaceRoot) {
  await mkdir(workspaceRoot, { recursive: true });
  runGit(workspaceRoot, ["init"]);
  runGit(workspaceRoot, ["config", "user.name", "VibeDeck Smoke"]);
  runGit(workspaceRoot, ["config", "user.email", "vibedeck-smoke@example.local"]);
  await writeFile(path.join(workspaceRoot, ".gitignore"), ".env.local\n", "utf8");
  await writeFile(path.join(workspaceRoot, "notes.txt"), "base\n", "utf8");
  await writeFile(path.join(workspaceRoot, ".env.local"), "ignored-secret\n", "utf8");
  runGit(workspaceRoot, ["add", "-A"]);
  runGit(workspaceRoot, ["commit", "-m", "base"]);
}

function runGit(cwd, args) {
  const result = spawnSync("git", args, {
    cwd,
    encoding: "utf8",
    windowsHide: true,
  });
  if (result.error) {
    throw result.error;
  }
  if (result.status !== 0) {
    throw new Error(
      ["git " + args.join(" ") + " failed", result.stdout, result.stderr]
        .filter(Boolean)
        .join("\n") || "git failed",
    );
  }
}
