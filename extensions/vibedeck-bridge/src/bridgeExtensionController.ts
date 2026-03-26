import {
  MockCursorBridge,
  createCursorExtensionBridge,
  createCursorExtensionRuntime,
  createVSCodeCursorHost,
  defaultCursorBridgeCommands,
  serveSocketBridge,
  type CursorBridgeCommands,
  type CursorExtensionRuntime,
  type DisposableLike,
  type SocketBridgeServer,
  type VSCodeExtensionLike,
  type VSCodeLike,
} from "@vibedeck/cursor-bridge";
import {
  createCursorAgentCommandAdapter,
  type CursorAgentCommandAdapterConfig,
} from "./cursorAgentCommandAdapter.js";
import {
  createLocalAgentController,
  readLocalAgentSettings,
  type LocalAgentController,
  type LocalAgentSettings,
  type LocalAgentStatus,
} from "./localAgentController.js";
import {
  createThreadPanelController,
  type ThreadPanelController,
  type ThreadPanelWebviewPanelLike,
} from "./threadPanelController.js";
import {
  createMobileBootstrapController,
  type MobileBootstrapController,
} from "./mobileBootstrapController.js";
import {
  formatCursorChatObservabilityReport,
  probeCursorChatObservability,
} from "./cursorChatProbe.js";
import {
  formatCursorPromptSubmitReport,
  probeCursorPromptSubmitPath,
} from "./cursorPromptSubmitProbe.js";
import {
  submitCursorNativePrompt,
  type CursorNativePromptSubmitResult,
} from "./cursorNativePromptSubmit.js";
import {
  formatCursorChatStorageReport,
  probeCursorChatStorage,
} from "./cursorChatStorageProbe.js";
import {
  createCursorChatLinkTracker,
  formatCursorChatLinkTrackerReport,
  type CursorChatLinkTracker,
} from "./cursorChatLinkTracker.js";
import {
  createCursorChatTimelineMirror,
  type CursorChatTimelineMirror,
} from "./cursorChatTimelineMirror.js";

type BridgeMode = "command" | "mock";
type CommandProviderMode = "builtin_cursor_agent" | "external";
type CommandKey = keyof CursorBridgeCommands;

const REQUIRED_COMMAND_KEYS = [
  "submitTask",
  "getPatch",
  "applyPatch",
  "runProfile",
  "getRunResult",
] as const satisfies readonly CommandKey[];

const OPTIONAL_COMMAND_KEYS = [
  "openLocation",
  "getWorkspaceMetadata",
  "getLatestTerminalError",
] as const satisfies readonly CommandKey[];

export interface BridgeExtensionContextLike {
  subscriptions: DisposableLike[];
}

export interface BridgeExtensionStatusBarItemLike extends DisposableLike {
  text: string;
  tooltip?: string;
  command?: string;
  show(): void;
}

export interface BridgeExtensionConfigurationLike {
  get<T>(key: string, defaultValue?: T): T;
}

export interface BridgeExtensionConfigurationChangeEventLike {
  affectsConfiguration(section: string): boolean;
}

export interface BridgeExtensionCommandsLike {
  executeCommand<T = unknown>(command: string, ...args: unknown[]): Promise<T>;
  registerCommand(command: string, callback: (...args: unknown[]) => unknown): DisposableLike;
  getCommands(filterInternal?: boolean): Promise<string[]>;
}

export interface BridgeExtensionWindowLike {
  activeTextEditor?: VSCodeLike["window"]["activeTextEditor"];
  showTextDocument: VSCodeLike["window"]["showTextDocument"];
  showInformationMessage(message: string): unknown;
  showWarningMessage(message: string): unknown;
  showErrorMessage(message: string): unknown;
  showInputBox?(options?: {
    prompt?: string;
    placeHolder?: string;
    value?: string;
  }): Promise<string | undefined> | Thenable<string | undefined>;
  createStatusBarItem(alignment: number, priority?: number): BridgeExtensionStatusBarItemLike;
  createWebviewPanel(
    viewType: string,
    title: string,
    column: number,
    options: { enableScripts: boolean; retainContextWhenHidden?: boolean },
  ): ThreadPanelWebviewPanelLike;
}

export interface BridgeExtensionWorkspaceFolderLike {
  uri: {
    fsPath: string;
  };
}

export interface BridgeExtensionWorkspaceLike {
  textDocuments?: VSCodeLike["workspace"]["textDocuments"];
  openTextDocument: VSCodeLike["workspace"]["openTextDocument"];
  getConfiguration(section?: string): BridgeExtensionConfigurationLike;
  onDidChangeConfiguration(
    listener: (event: BridgeExtensionConfigurationChangeEventLike) => unknown,
  ): DisposableLike;
  workspaceFolders?: BridgeExtensionWorkspaceFolderLike[];
}

export interface BridgeExtensionEnvLike {
  clipboard: {
    writeText(text: string): Promise<void>;
    readText?(): Promise<string>;
  };
}

export interface BridgeExtensionVscodeLike {
  commands: BridgeExtensionCommandsLike;
  window: BridgeExtensionWindowLike;
  workspace: BridgeExtensionWorkspaceLike;
  env: BridgeExtensionEnvLike;
  statusBarAlignment: {
    left: number;
  };
  viewColumn: {
    one: number;
  };
}

interface BridgeSettings {
  autoStart: boolean;
  mode: BridgeMode;
  commandProvider: CommandProviderMode;
  tcpHost: string;
  tcpPort: number;
  commands: Partial<CursorBridgeCommands>;
  cursorAgent: CursorAgentCommandAdapterConfig;
  agent: LocalAgentSettings;
}

interface ActiveBridge {
  server: SocketBridgeServer;
  runtime?: CursorExtensionRuntime;
  mode: BridgeMode;
  providerMode?: CommandProviderMode;
  address: string;
  settings: BridgeSettings;
  diagnostics?: BridgeCommandDiagnostics;
}

interface BridgeCommandBinding {
  key: CommandKey;
  commandId: string;
}

interface BridgeCommandDiagnostics {
  checkedAt: string;
  availableCount: number;
  required: BridgeCommandBinding[];
  optional: BridgeCommandBinding[];
  missingRequired: BridgeCommandBinding[];
  missingOptional: BridgeCommandBinding[];
}

export interface BridgeExtensionController {
  activate(context: BridgeExtensionContextLike): Promise<void>;
  deactivate(): Promise<void>;
}

export interface BridgeExtensionControllerDependencies {
  localAgent?: LocalAgentController;
}

interface CursorPromptSubmitRequest {
  readonly prompt: string;
  readonly threadId: string;
}

export interface CursorPromptSubmitCommandResult extends CursorNativePromptSubmitResult {
  readonly threadId?: string;
  readonly linkState?: "linked" | "pending" | "skipped";
  readonly composerId?: string;
}

export function createBridgeExtensionController(
  vscodeLike: BridgeExtensionVscodeLike,
  dependencies: BridgeExtensionControllerDependencies = {},
): BridgeExtensionController {
  return new DefaultBridgeExtensionController(vscodeLike, dependencies);
}

class DefaultBridgeExtensionController implements BridgeExtensionController {
  private readonly vscode: BridgeExtensionVscodeLike;
  private readonly localAgent: LocalAgentController;
  private readonly threadPanel: ThreadPanelController;
  private readonly mobileBootstrap: MobileBootstrapController;
  private readonly cursorChatLinks: CursorChatLinkTracker;
  private readonly cursorChatTimelineMirror: CursorChatTimelineMirror;
  private activeBridge: ActiveBridge | undefined;
  private statusBarItem: BridgeExtensionStatusBarItemLike | undefined;
  private lastBridgeError: string | undefined;

  constructor(
    vscodeLike: BridgeExtensionVscodeLike,
    dependencies: BridgeExtensionControllerDependencies,
  ) {
    this.vscode = vscodeLike;
    this.localAgent =
      dependencies.localAgent ??
      createLocalAgentController({
        onStateChange: () => {
          this.updateStatusBar();
          void this.threadPanel.refreshIfOpen();
        },
      });
    this.threadPanel = createThreadPanelController(this.vscode);
    this.mobileBootstrap = createMobileBootstrapController(this.vscode, {
      ensureAgentReady: async () => {
        await this.ensureAgentReadyForBootstrap();
      },
    });
    this.cursorChatLinks = createCursorChatLinkTracker();
    this.cursorChatTimelineMirror = createCursorChatTimelineMirror({
      tracker: this.cursorChatLinks,
      getAgentBaseUrl: () => readBridgeAgentBaseUrl(this.vscode.workspace),
    });
  }

  async activate(context: BridgeExtensionContextLike): Promise<void> {
    this.statusBarItem = this.vscode.window.createStatusBarItem(
      this.vscode.statusBarAlignment.left,
      100,
    );
    this.statusBarItem.command = "vibedeckBridge.showStatus";
    context.subscriptions.push(this.statusBarItem);

    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.startServer", async () => {
        await this.startServer(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.stopServer", async () => {
        await this.stopServer(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.startAgent", async () => {
        await this.startAgent(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.stopAgent", async () => {
        await this.stopAgent(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.restartAgent", async () => {
        await this.restartAgent(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.showStatus", async () => {
        await this.showBridgeStatus();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.validateCommands", async () => {
        await this.validateCommands(true);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.copyAgentEnv", async () => {
        await this.copyAgentEnv();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.copySmokeCommand", async () => {
        await this.copySmokeCommand();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.openThreadPanel", async () => {
        await this.threadPanel.openOrReveal();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.openThreadPanelInEditor", async () => {
        await this.threadPanel.openInEditor();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.openThreadPanelInSidebar", async () => {
        await this.threadPanel.openInSidebar();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.openMobileBootstrap", async () => {
        await this.mobileBootstrap.openOrReveal();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.copyMobileBootstrap", async () => {
        await this.mobileBootstrap.copyLink();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.probeCursorChat", async () => {
        return await this.probeCursorChat();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.probeCursorPromptSubmit", async () => {
        return await this.probeCursorPromptSubmit();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.submitCursorPrompt", async (...args) => {
        return await this.submitCursorPromptCommand(args[0]);
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.probeCursorChatStorage", async () => {
        return await this.probeCursorChatStorage();
      }),
    );
    context.subscriptions.push(
      this.vscode.commands.registerCommand("vibedeckBridge.inspectCursorChatLinks", async () => {
        return await this.inspectCursorChatLinks();
      }),
    );
    context.subscriptions.push(
      this.vscode.workspace.onDidChangeConfiguration((event) => {
        if (!event.affectsConfiguration("vibedeckBridge")) {
          return;
        }
        void this.restartServer();
        void this.threadPanel.refreshIfOpen();
      }),
    );

    this.updateStatusBar();

    if (this.readSettings().autoStart) {
      await this.startServer(false);
    }
  }

  async deactivate(): Promise<void> {
    this.cursorChatTimelineMirror.dispose();
    this.cursorChatLinks.dispose();
    this.mobileBootstrap.dispose();
    this.threadPanel.dispose();
    await this.stopServer(false);
  }

  private async startServer(showMessage: boolean): Promise<void> {
    await this.stopServer(false);

    const settings = this.readSettings();
    this.lastBridgeError = undefined;
    try {
      let startedBridge: ActiveBridge;

      if (settings.mode === "mock") {
        const runtime = createCursorExtensionRuntime({
          vscode: this.asExtensionRuntimeVSCode(),
          adapter: new MockCursorBridge(),
        });
        const server = await serveSocketBridge(runtime.bridge, {
          host: settings.tcpHost,
          port: settings.tcpPort,
        });
        startedBridge = {
          server,
          runtime,
          mode: settings.mode,
          address: server.address,
          settings,
        };
      } else {
        let runtime: CursorExtensionRuntime | undefined;
        try {
          if (settings.commandProvider === "builtin_cursor_agent") {
            runtime = await this.createBuiltinCommandRuntime(settings);
          }

          const diagnostics = await this.validateCommandModeSettings(settings);
          if (diagnostics.missingRequired.length > 0) {
            throw new Error(
              `missing required commands: ${formatCommandBindings(diagnostics.missingRequired)}`,
            );
          }

          const bridge = createCursorExtensionBridge({
            host: createVSCodeCursorHost(this.asHostVSCode()),
            commands: settings.commands,
          });
          const server = await serveSocketBridge(bridge, {
            host: settings.tcpHost,
            port: settings.tcpPort,
          });
          startedBridge = {
            server,
            runtime,
            mode: settings.mode,
            providerMode: settings.commandProvider,
            address: server.address,
            settings,
            diagnostics,
          };
        } catch (error) {
          runtime?.dispose();
          throw error;
        }
      }

      this.activeBridge = startedBridge;
      if (startedBridge.settings.agent.autoStart) {
        await this.localAgent.start(startedBridge.settings.agent, startedBridge.address);
      }
      this.updateStatusBar();
      if (showMessage) {
        await this.showStartedMessage(startedBridge);
      } else if (
        startedBridge.diagnostics &&
        startedBridge.diagnostics.missingOptional.length > 0
      ) {
        void this.vscode.window.showWarningMessage(this.describeBridgeStatus(startedBridge));
      }
    } catch (error) {
      this.activeBridge = undefined;
      const message = error instanceof Error ? error.message : String(error);
      this.lastBridgeError = message;
      this.updateStatusBar();
      void this.vscode.window.showErrorMessage(`VibeDeck bridge start failed: ${message}`);
    }
  }

  private async stopServer(showMessage: boolean): Promise<void> {
    const bridge = this.activeBridge;
    this.activeBridge = undefined;
    this.lastBridgeError = undefined;

    await this.localAgent.stop();

    if (bridge?.runtime) {
      bridge.runtime.dispose();
    }
    if (bridge?.server) {
      await bridge.server.close();
    }

    this.updateStatusBar();
    if (showMessage && bridge) {
      void this.vscode.window.showInformationMessage("VibeDeck bridge stopped");
    }
  }

  private async restartServer(): Promise<void> {
    if (!this.readSettings().autoStart) {
      await this.stopServer(false);
      return;
    }
    await this.startServer(false);
  }

  private async startAgent(showMessage: boolean): Promise<void> {
    if (!this.activeBridge) {
      await this.startServer(false);
    }
    if (!this.activeBridge) {
      return;
    }

    const status = await this.localAgent.start(this.readSettings().agent, this.activeBridge.address);
    this.updateStatusBar();
    if (showMessage) {
      this.showAgentStatusMessage(status);
    }
  }

  private async stopAgent(showMessage: boolean): Promise<void> {
    await this.localAgent.stop();
    this.updateStatusBar();
    if (showMessage) {
      void this.vscode.window.showInformationMessage("VibeDeck local agent stopped");
    }
  }

  private async restartAgent(showMessage: boolean): Promise<void> {
    if (!this.activeBridge) {
      await this.startServer(false);
    }
    if (!this.activeBridge) {
      return;
    }

    const status = await this.localAgent.start(this.readSettings().agent, this.activeBridge.address);
    this.updateStatusBar();
    if (showMessage) {
      this.showAgentStatusMessage(status);
    }
  }

  private async ensureAgentReadyForBootstrap(): Promise<void> {
    if (!this.activeBridge) {
      await this.startServer(false);
    }
    if (!this.activeBridge) {
      return;
    }

    const status = this.localAgent.status();
    if (status.state === "running" || status.state === "starting") {
      return;
    }

    await this.localAgent.start(this.readSettings().agent, this.activeBridge.address);
    this.updateStatusBar();
  }

  private showAgentStatusMessage(status: LocalAgentStatus): void {
    const message = describeAgentStatus(status);
    if (status.state === "running") {
      void this.vscode.window.showInformationMessage(message);
      return;
    }
    if (status.state === "starting") {
      void this.vscode.window.showWarningMessage(message);
      return;
    }
    if (status.state === "error") {
      void this.vscode.window.showErrorMessage(message);
      return;
    }
    void this.vscode.window.showWarningMessage(message);
  }

  private updateStatusBar(): void {
    if (!this.statusBarItem) {
      return;
    }

    const agentStatus = this.localAgent.status();

    if (!this.activeBridge) {
      if (this.lastBridgeError) {
        this.statusBarItem.text = "VibeDeck: issue";
        this.statusBarItem.tooltip = `VibeDeck bridge stopped\nlast error: ${this.lastBridgeError}`;
      } else if (agentStatus.state === "error") {
        this.statusBarItem.text = "VibeDeck: agent!";
        this.statusBarItem.tooltip = describeAgentStatus(agentStatus);
      } else {
        this.statusBarItem.text = "VibeDeck: stopped";
        this.statusBarItem.tooltip = "VibeDeck localhost bridge is stopped";
      }
      this.statusBarItem.show();
      return;
    }

    let suffix = "";
    if (agentStatus.state === "running") {
      suffix = " | agent";
    } else if (agentStatus.state === "starting") {
      suffix = " | boot";
    } else if (agentStatus.state === "error") {
      suffix = " | agent!";
    }

    this.statusBarItem.text =
      `VibeDeck: ${this.activeBridge.address}${suffix}` +
      (this.activeBridge.diagnostics?.missingOptional.length ? " !" : "");
    this.statusBarItem.tooltip = this.describeBridgeStatus(this.activeBridge);
    this.statusBarItem.show();
  }

  private currentStatusMessage(): string {
    const settings = this.readSettings();
    const address = resolveAddress(settings);
    const agentStatus = this.localAgent.status();

    if (!this.activeBridge) {
      return formatBridgeStatusReport({
        connected: false,
        address,
        mode: settings.mode,
        settings,
        agentStatus,
        lastError: this.lastBridgeError,
      });
    }

    return this.describeBridgeStatus(this.activeBridge);
  }

  private readSettings(): BridgeSettings {
    const config = this.vscode.workspace.getConfiguration("vibedeckBridge");
    const modeValue = config.get<string>("mode") === "mock" ? "mock" : "command";
    const providerValue =
      config.get<string>("commandProvider") === "external"
        ? "external"
        : "builtin_cursor_agent";
    const agentSettings = readLocalAgentSettings(config);
    return {
      autoStart: config.get<boolean>("autoStart", true),
      mode: modeValue,
      commandProvider: providerValue,
      tcpHost: config.get<string>("tcpHost", "127.0.0.1").trim() || "127.0.0.1",
      tcpPort: normalizePort(config.get<number>("tcpPort", 7797)),
      commands: readCommandSettings(config),
      cursorAgent: readCursorAgentSettings(
        config,
        this.vscode.workspace.workspaceFolders,
        agentSettings,
      ),
      agent: agentSettings,
    };
  }

  private asExtensionRuntimeVSCode(): VSCodeExtensionLike {
    return this.vscode as unknown as VSCodeExtensionLike;
  }

  private asHostVSCode(): VSCodeLike {
    return this.vscode as unknown as VSCodeLike;
  }

  private async createBuiltinCommandRuntime(
    settings: BridgeSettings,
  ): Promise<CursorExtensionRuntime> {
    if (!settings.cursorAgent.workspaceRoot?.trim()) {
      throw new Error(
        "workspace root is not configured. Open the project folder or set vibedeckBridge.cursorAgent.workspaceRoot.",
      );
    }

    const adapter = await createCursorAgentCommandAdapter(settings.cursorAgent);
    return createCursorExtensionRuntime({
      vscode: this.asExtensionRuntimeVSCode(),
      adapter,
      commands: settings.commands,
    });
  }

  private async showBridgeStatus(): Promise<void> {
    const message = this.currentStatusMessage();
    const agentStatus = this.localAgent.status();
    if (this.activeBridge?.diagnostics?.missingOptional.length || this.lastBridgeError || agentStatus.state === "error") {
      void this.vscode.window.showWarningMessage(message);
      return;
    }

    void this.vscode.window.showInformationMessage(message);
  }

  private async probeCursorChat(): Promise<string> {
    const report = await probeCursorChatObservability(this.vscode as Parameters<typeof probeCursorChatObservability>[0]);
    const message = formatCursorChatObservabilityReport(report);
    await this.vscode.env.clipboard.writeText(message);

    const summary =
      "VibeDeck Cursor \uCC44\uD305 \uC9C4\uB2E8\uC744 \uB9C8\uCCE4\uC2B5\uB2C8\uB2E4. " +
      report.conclusions.summary +
      " \uC790\uC138\uD55C \uACB0\uACFC\uB97C \uD074\uB9BD\uBCF4\uB4DC\uC5D0 \uBCF5\uC0AC\uD588\uC2B5\uB2C8\uB2E4.";
    if (report.conclusions.canInspectNativeTranscript) {
      void this.vscode.window.showInformationMessage(summary);
    } else {
      void this.vscode.window.showWarningMessage(summary);
    }

    return message;
  }

  private async probeCursorPromptSubmit(): Promise<string> {
    const report = await probeCursorPromptSubmitPath(this.vscode as Parameters<typeof probeCursorPromptSubmitPath>[0]);
    const message = formatCursorPromptSubmitReport(report);
    await this.vscode.env.clipboard.writeText(message);

    const summary =
      "VibeDeck Cursor 프롬프트 전송 경로 진단을 마쳤습니다. " +
      report.recommendedStrategy.summary +
      " 자세한 결과를 클립보드에 복사했습니다.";
    if (report.recommendedStrategy.canAutomateSubmit) {
      void this.vscode.window.showInformationMessage(summary);
    } else {
      void this.vscode.window.showWarningMessage(summary);
    }

    return message;
  }

  private async submitCursorPromptCommand(
    promptArg: unknown,
  ): Promise<CursorPromptSubmitCommandResult | undefined> {
    const request = await this.resolveCursorPromptRequest(promptArg);
    if (!request) {
      return undefined;
    }

    const submittedAt = new Date().toISOString();
    const result = await submitCursorNativePrompt(
      this.vscode as Parameters<typeof submitCursorNativePrompt>[0],
      request.prompt,
    );

    let linkState: CursorPromptSubmitCommandResult["linkState"] = "skipped";
    let composerId: string | undefined;

    if (
      request.threadId &&
      (result.status === "submitted" || result.status === "draft_inserted")
    ) {
      const snapshot = await this.cursorChatLinks.notePromptSubmission({
        threadId: request.threadId,
        prompt: request.prompt,
        submitStatus: result.status,
        strategyKind: result.strategyKind,
        submittedAt,
      });
      const linked = snapshot.linkedThreads.find(
        (item) => item.threadId === request.threadId,
      );
      if (linked) {
        linkState = "linked";
        composerId = linked.composerId;
      } else {
        linkState = "pending";
      }
      await this.cursorChatTimelineMirror.refreshNow();
    }

    let summary = "VibeDeck Cursor 기본 채팅으로 프롬프트 제출을 시도했습니다. " + result.summary;
    if (request.threadId && linkState === "linked" && composerId) {
      summary += ` thread ${request.threadId}를 composer ${composerId}와 연결했습니다.`;
    } else if (request.threadId && linkState === "pending") {
      summary += ` thread ${request.threadId}는 아직 연결 대기 중이며 storage poller가 계속 확인합니다.`;
    }

    if (result.status === "submitted" && linkState !== "pending") {
      void this.vscode.window.showInformationMessage(summary);
    } else {
      void this.vscode.window.showWarningMessage(summary);
    }

    return {
      ...result,
      threadId: request.threadId || undefined,
      linkState,
      composerId,
    };
  }

  private async resolveCursorPromptRequest(
    promptArg: unknown,
  ): Promise<CursorPromptSubmitRequest | undefined> {
    const fromArg = this.readPromptSubmitArgument(promptArg);
    if (fromArg) {
      return fromArg;
    }

    if (!this.vscode.window.showInputBox) {
      void this.vscode.window.showWarningMessage(
        "Cursor 기본 채팅으로 보낼 프롬프트 문자열이 필요합니다.",
      );
      return undefined;
    }

    const value = await this.vscode.window.showInputBox({
      prompt: "Cursor 기본 채팅으로 보낼 프롬프트를 입력하세요",
      placeHolder: "예: auth 실패 원인을 설명하고 수정 방향을 제안해줘",
    });
    const normalized = value?.trim() ?? "";
    if (!normalized) {
      return undefined;
    }
    return {
      prompt: normalized,
      threadId: "",
    };
  }

  private readPromptSubmitArgument(
    promptArg: unknown,
  ): CursorPromptSubmitRequest | undefined {
    if (typeof promptArg === "string" && promptArg.trim()) {
      return {
        prompt: promptArg.trim(),
        threadId: "",
      };
    }

    if (!promptArg || typeof promptArg !== "object") {
      return undefined;
    }

    const record = promptArg as Record<string, unknown>;
    const prompt = typeof record.prompt === "string" ? record.prompt.trim() : "";
    if (!prompt) {
      return undefined;
    }
    const threadId =
      typeof record.threadId === "string" && record.threadId.trim()
        ? record.threadId.trim()
        : typeof record.sessionId === "string" && record.sessionId.trim()
          ? record.sessionId.trim()
          : "";
    return {
      prompt,
      threadId,
    };
  }

  private async inspectCursorChatLinks(): Promise<string> {
    const snapshot = await this.cursorChatLinks.refreshNow();
    const message = formatCursorChatLinkTrackerReport(snapshot);
    await this.vscode.env.clipboard.writeText(message);

    let summary = "VibeDeck Cursor 채팅 연결 상태를 진단했고 자세한 결과를 클립보드에 복사했습니다.";
    if (snapshot.linkedThreads.length > 0) {
      summary += ` 현재 ${snapshot.linkedThreads.length}개 thread가 composer와 연결되어 있습니다.`;
      void this.vscode.window.showInformationMessage(summary);
    } else if (snapshot.pendingSubmissions.length > 0) {
      summary += ` 아직 연결 대기 중인 제출이 ${snapshot.pendingSubmissions.length}개 있습니다.`;
      void this.vscode.window.showWarningMessage(summary);
    } else if (snapshot.lastError) {
      summary += ` 마지막 오류: ${snapshot.lastError}`;
      void this.vscode.window.showWarningMessage(summary);
    } else {
      void this.vscode.window.showInformationMessage(summary);
    }

    return message;
  }

  private async probeCursorChatStorage(): Promise<string> {
    const report = await probeCursorChatStorage();
    const message = formatCursorChatStorageReport(report);
    await this.vscode.env.clipboard.writeText(message);

    const summary =
      "VibeDeck Cursor \uCC44\uD305 \uC800\uC7A5\uC18C \uC9C4\uB2E8\uC744 \uB9C8\uCCE4\uC2B5\uB2C8\uB2E4. " +
      report.conclusions.summary +
      " \uC790\uC138\uD55C \uACB0\uACFC\uB97C \uD074\uB9BD\uBCF4\uB4DC\uC5D0 \uBCF5\uC0AC\uD588\uC2B5\uB2C8\uB2E4.";
    if (report.conclusions.canReadStorage) {
      void this.vscode.window.showInformationMessage(summary);
    } else {
      void this.vscode.window.showWarningMessage(summary);
    }

    return message;
  }

  private async validateCommands(
    showMessage: boolean,
  ): Promise<BridgeCommandDiagnostics | undefined> {
    const settings = this.readSettings();
    if (settings.mode !== "command") {
      if (showMessage) {
        void this.vscode.window.showInformationMessage(
          "VibeDeck bridge is in mock mode. Command validation is skipped.",
        );
      }
      return undefined;
    }

    const diagnostics = await this.validateCommandModeSettings(settings);
    if (showMessage) {
      const message = describeCommandDiagnostics(settings, diagnostics);
      if (diagnostics.missingRequired.length > 0) {
        void this.vscode.window.showErrorMessage(message);
      } else if (diagnostics.missingOptional.length > 0) {
        void this.vscode.window.showWarningMessage(message);
      } else {
        void this.vscode.window.showInformationMessage(message);
      }
    }

    return diagnostics;
  }

  private async copyAgentEnv(): Promise<void> {
    const settings = this.activeBridge?.settings ?? this.readSettings();
    const address = this.activeBridge?.address ?? resolveAddress(settings);
    const command = buildAgentEnvCommand(address);
    await this.vscode.env.clipboard.writeText(command);
    void this.vscode.window.showInformationMessage(`Copied agent env: ${command}`);
  }

  private async copySmokeCommand(): Promise<void> {
    const settings = this.activeBridge?.settings ?? this.readSettings();
    const address = this.activeBridge?.address ?? resolveAddress(settings);
    const command = buildSmokeCommand(settings, address);
    if (!command) {
      void this.vscode.window.showWarningMessage(
        "Smoke command is not available for the current provider.",
      );
      return;
    }
    await this.vscode.env.clipboard.writeText(command);
    void this.vscode.window.showInformationMessage(`Copied smoke command: ${command}`);
  }

  private async showStartedMessage(bridge: ActiveBridge): Promise<void> {
    const message = this.describeBridgeStatus(bridge);
    const agentStatus = this.localAgent.status();
    if (agentStatus.state === "error") {
      void this.vscode.window.showWarningMessage(message);
      return;
    }
    if (bridge.diagnostics?.missingOptional.length) {
      void this.vscode.window.showWarningMessage(message);
      return;
    }

    void this.vscode.window.showInformationMessage(message);
  }

  private async validateCommandModeSettings(
    settings: BridgeSettings,
  ): Promise<BridgeCommandDiagnostics> {
    const availableCommands = new Set(await this.vscode.commands.getCommands(true));
    const resolvedCommands = resolveCommands(settings.commands);
    const required = collectCommandBindings(resolvedCommands, REQUIRED_COMMAND_KEYS);
    const optional = collectCommandBindings(resolvedCommands, OPTIONAL_COMMAND_KEYS);

    return {
      checkedAt: new Date().toISOString(),
      availableCount: availableCommands.size,
      required,
      optional,
      missingRequired: required.filter((binding) => !availableCommands.has(binding.commandId)),
      missingOptional: optional.filter((binding) => !availableCommands.has(binding.commandId)),
    };
  }

  private describeBridgeStatus(bridge: ActiveBridge): string {
    return formatBridgeStatusReport({
      connected: true,
      address: bridge.address,
      mode: bridge.mode,
      settings: bridge.settings,
      agentStatus: this.localAgent.status(),
      diagnostics: bridge.diagnostics,
    });
  }
}

function readCommandSettings(
  config: BridgeExtensionConfigurationLike,
): Partial<CursorBridgeCommands> {
  const commands: Partial<CursorBridgeCommands> = {};
  setOptionalCommand(commands, "submitTask", readOptionalCommand(config, "commands.submitTask"));
  setOptionalCommand(commands, "getPatch", readOptionalCommand(config, "commands.getPatch"));
  setOptionalCommand(commands, "applyPatch", readOptionalCommand(config, "commands.applyPatch"));
  setOptionalCommand(commands, "runProfile", readOptionalCommand(config, "commands.runProfile"));
  setOptionalCommand(commands, "getRunResult", readOptionalCommand(config, "commands.getRunResult"));
  setOptionalCommand(commands, "openLocation", readOptionalCommand(config, "commands.openLocation"));
  setOptionalCommand(commands, "getWorkspaceMetadata", readOptionalCommand(config, "commands.getWorkspaceMetadata"));
  setOptionalCommand(commands, "getLatestTerminalError", readOptionalCommand(config, "commands.getLatestTerminalError"));
  return commands;
}

function readCursorAgentSettings(
  config: BridgeExtensionConfigurationLike,
  workspaceFolders?: BridgeExtensionWorkspaceFolderLike[],
  agentSettings?: LocalAgentSettings,
): CursorAgentCommandAdapterConfig {
  const workspaceRoot =
    readOptionalCommand(config, "cursorAgent.workspaceRoot") ?? workspaceFolders?.[0]?.uri.fsPath;
  const extraArgs = readStringArray(config, "cursorAgent.extraArgs");
  const trustWorkspace = config.get<boolean>("cursorAgent.trustWorkspace", true);
  const model = (config.get<string>("cursorAgent.model", "auto") ?? "auto").trim();
  const fallbackPromptTimeoutMs =
    agentSettings?.controlTimeoutPromptSubmitMs ?? 300000;
  const fallbackRunTimeoutMs =
    agentSettings?.controlTimeoutRunProfileMs ?? 300000;
  return {
    workspaceRoot,
    tempRoot: readOptionalCommand(config, "cursorAgent.tempRoot"),
    gitBin: readOptionalCommand(config, "cursorAgent.gitBin") ?? "git",
    cursorAgentBin: readOptionalCommand(config, "cursorAgent.bin") ?? "cursor-agent",
    cursorAgentArgs: ensureCursorAgentModelArg(
      ensureCursorAgentTrustFlag(ensureCursorAgentHeadlessArgs(extraArgs), trustWorkspace),
      model,
    ),
    cursorAgentEnv: readStringArray(config, "cursorAgent.extraEnv"),
    syncIgnoredPaths: readStringArray(config, "cursorAgent.syncIgnoredPaths"),
    useWsl: config.get<boolean>("cursorAgent.useWsl", false),
    wslDistro: readOptionalCommand(config, "cursorAgent.wslDistro"),
    promptTimeoutMs: normalizeOptionalDuration(
      config.get<number>("cursorAgent.promptTimeoutMs", 0),
      fallbackPromptTimeoutMs,
    ),
    runTimeoutMs: normalizeOptionalDuration(
      config.get<number>("cursorAgent.runTimeoutMs", 0),
      fallbackRunTimeoutMs,
    ),
  };
}

function setOptionalCommand(
  commands: Partial<CursorBridgeCommands>,
  key: keyof CursorBridgeCommands,
  value: string | undefined,
): void {
  if (!value) {
    return;
  }
  commands[key] = value;
}

function readOptionalCommand(
  config: BridgeExtensionConfigurationLike,
  key: string,
): string | undefined {
  const value = config.get<string | undefined>(key)?.trim();
  if (!value) {
    return undefined;
  }
  return value;
}

function readStringArray(config: BridgeExtensionConfigurationLike, key: string): string[] {
  const value = config.get<unknown[]>(key, []);
  if (!Array.isArray(value)) {
    return [];
  }
  return value.filter((item): item is string => typeof item === "string" && item.trim().length > 0);
}

function describeCommandDiagnostics(
  settings: BridgeSettings,
  diagnostics: BridgeCommandDiagnostics,
): string {
  const address = resolveAddress(settings);
  const agentStatus: LocalAgentStatus = {
    state: "stopped",
    launchMode: settings.agent.launchMode,
    baseUrl: toAgentBaseUrl(settings.agent),
    command: settings.agent.launchMode,
    repoRoot: settings.agent.repoRoot,
    outputTail: [],
  };
  const lines = [
    `VibeDeck 명령 진단: ${address}`,
    `명령 공급자: ${describeProvider(settings)}`,
    `등록된 명령 수: ${diagnostics.availableCount}`,
    `필수 명령 준비: ${diagnostics.required.length - diagnostics.missingRequired.length}/${diagnostics.required.length}`,
    describeProviderTimeouts(settings),
    describeAgentStatus(agentStatus),
    describeAgentControlTimeouts(settings.agent),
  ];

  const smokeCommand = buildSmokeCommand(settings, address);

  if (diagnostics.optional.length > 0) {
    lines.push(
      `선택 명령 준비: ${diagnostics.optional.length - diagnostics.missingOptional.length}/${diagnostics.optional.length}`,
    );
  }

  if (diagnostics.missingRequired.length > 0) {
    lines.push(`누락된 필수 명령: ${formatCommandBindings(diagnostics.missingRequired)}`);
  }

  if (diagnostics.missingOptional.length > 0) {
    lines.push(`누락된 선택 명령: ${formatCommandBindings(diagnostics.missingOptional)}`);
  }

  const guidance = collectSetupGuidance({
    connected: false,
    settings,
    agentStatus,
    diagnostics,
  });
  if (guidance.length > 0) {
    lines.push("권장 조치:");
    lines.push(...guidance.map((item) => `- ${item}`));
  }

  lines.push("빠른 확인:");
  lines.push(`- 진단: ${buildDoctorCommand()}`);
  lines.push(`- 환경 변수: ${buildAgentEnvCommand(address)}`);
  if (smokeCommand) {
    lines.push(`- 스모크: ${smokeCommand}`);
  }

  lines.push(`확인 시각: ${diagnostics.checkedAt}`);
  return lines.join("\n");
}

function describeProvider(settings: BridgeSettings): string {
  if (settings.mode === "mock") {
    return "mock 런타임";
  }
  if (settings.commandProvider === "external") {
    return "외부 명령 레지스트리";
  }
  return settings.cursorAgent.useWsl
    ? `내장 cursor-agent (WSL${settings.cursorAgent.wslDistro ? `: ${settings.cursorAgent.wslDistro}` : ""})`
    : "내장 cursor-agent";
}

function describeAgentStatus(status: LocalAgentStatus): string {
  const lines = [
    `로컬 agent: ${describeAgentRuntimeState(status.state)} (${status.baseUrl})`,
    `agent 실행 방식: ${status.launchMode}`,
    `agent 명령: ${status.command}`,
  ];
  if (status.repoRoot) {
    lines.push(`agent 저장소 루트: ${status.repoRoot}`);
  }
  if (status.pid) {
    lines.push(`agent PID: ${status.pid}`);
  }
  if (status.lastError) {
    lines.push(`agent 최근 오류: ${status.lastError}`);
  }
  if (status.outputTail.length > 0) {
    lines.push(`agent 출력: ${status.outputTail.join(" | ")}`);
  }
  return lines.join("\n");
}

function describeProviderTimeouts(settings: BridgeSettings): string {
  if (settings.mode !== "command" || settings.commandProvider !== "builtin_cursor_agent") {
    return "provider timeout: -";
  }
  return `provider timeout: prompt ${formatDurationMs(settings.cursorAgent.promptTimeoutMs)} / run ${formatDurationMs(settings.cursorAgent.runTimeoutMs)}`;
}

function describeAgentControlTimeouts(settings: LocalAgentSettings): string {
  return `agent 제어 timeout: 기본 ${formatDurationMs(settings.controlTimeoutDefaultMs)} / prompt ${formatDurationMs(settings.controlTimeoutPromptSubmitMs)} / patch ${formatDurationMs(settings.controlTimeoutPatchApplyMs)} / run ${formatDurationMs(settings.controlTimeoutRunProfileMs)}`;
}

function describeAgentRuntimeState(state: LocalAgentStatus["state"]): string {
  switch (state) {
    case "running":
      return "실행 중";
    case "starting":
      return "시작 중";
    case "error":
      return "오류";
    default:
      return "중지됨";
  }
}

function toAgentBaseUrl(settings: LocalAgentSettings): string {
  const host = settings.host === "0.0.0.0" || settings.host === "::" ? "127.0.0.1" : settings.host;
  return `http://${host}:${settings.port}`;
}

function formatDurationMs(value: number): string {
  const normalized = Math.max(0, Math.trunc(value));
  if (normalized === 0) {
    return "0ms";
  }
  if (normalized % 60000 === 0) {
    return `${normalized / 60000}분`;
  }
  if (normalized % 1000 === 0) {
    return `${normalized / 1000}초`;
  }
  return `${normalized}ms`;
}

function resolveCommands(commands: Partial<CursorBridgeCommands>): CursorBridgeCommands {
  return {
    ...defaultCursorBridgeCommands,
    ...commands,
  };
}

function collectCommandBindings(
  commands: CursorBridgeCommands,
  keys: readonly CommandKey[],
): BridgeCommandBinding[] {
  const bindings: BridgeCommandBinding[] = [];
  for (const key of keys) {
    const commandId = commands[key];
    if (typeof commandId !== "string" || commandId.length === 0) {
      continue;
    }

    bindings.push({ key, commandId });
  }

  return bindings;
}

function formatCommandBindings(bindings: BridgeCommandBinding[]): string {
  return bindings.map((binding) => `${binding.key}=${binding.commandId}`).join(", ");
}

function resolveAddress(settings: BridgeSettings): string {
  return `${settings.tcpHost}:${settings.tcpPort}`;
}

function readBridgeAgentBaseUrl(workspace: BridgeExtensionWorkspaceLike): string {
  const config = workspace.getConfiguration("vibedeckBridge");
  const configured = textValue(config.get<string>("agentBaseUrl", "")).trim();
  if (configured) {
    return configured;
  }
  const host = textValue(config.get<string>("agent.host", "127.0.0.1")).trim() || "127.0.0.1";
  const port = normalizePort(config.get<number>("agent.port", 8080));
  return normalizeAgentBaseUrl(host, port || 8080);
}

function normalizeAgentBaseUrl(host: string, port: number): string {
  return `http://${host}:${port}`;
}

function textValue(value: unknown): string {
  if (typeof value !== "string") {
    return "";
  }
  return value;
}

function buildAgentEnvCommand(address: string): string {
  return `$env:CURSOR_BRIDGE_TCP_ADDR = "${address}"`;
}

function buildDoctorCommand(): string {
  return "powershell -ExecutionPolicy Bypass -File .\\scripts\\vibedeck_doctor.ps1";
}

function buildSmokeCommand(settings: BridgeSettings, address: string): string | undefined {
  if (settings.mode === "mock") {
    return `powershell -ExecutionPolicy Bypass -File .\\scripts\\extension_host_smoke.ps1 -BridgeAddress "${address}"`;
  }
  if (settings.commandProvider === "builtin_cursor_agent") {
    return "npm --prefix extensions/vibedeck-bridge run smoke:extension";
  }
  return undefined;
}

function normalizePort(value: number): number {
  if (!Number.isFinite(value) || value < 0 || value > 65535) {
    return 7797;
  }
  return Math.trunc(value);
}

function normalizeDuration(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value < 1000) {
    return fallback;
  }
  return Math.trunc(value);
}

function normalizeOptionalDuration(value: number, fallback: number): number {
  if (!Number.isFinite(value) || value <= 0) {
    return fallback;
  }
  return normalizeDuration(value, fallback);
}

function ensureCursorAgentHeadlessArgs(args: string[]): string[] {
  const next = [...args];
  if (!next.includes("--print")) {
    next.push("--print");
  }
  if (!next.includes("--output-format")) {
    next.push("--output-format", "json");
  }
  return next;
}

function ensureCursorAgentTrustFlag(args: string[], enabled: boolean): string[] {
  if (!enabled || args.includes("--trust")) {
    return args;
  }
  return [...args, "--trust"];
}

function ensureCursorAgentModelArg(args: string[], model: string): string[] {
  const trimmedModel = model.trim();
  if (!trimmedModel || args.includes("--model")) {
    return args;
  }
  return [...args, "--model", trimmedModel];
}

function formatBridgeStatusReport(options: {
  connected: boolean;
  address: string;
  mode: BridgeMode;
  settings: BridgeSettings;
  agentStatus: LocalAgentStatus;
  diagnostics?: BridgeCommandDiagnostics;
  lastError?: string;
}): string {
  const lines = [
    `VibeDeck 브리지: ${options.connected ? "실행 중" : "중지됨"} (${options.mode})`,
    `브리지 주소: ${options.address}`,
    `명령 공급자: ${describeProvider(options.settings)}`,
    describeProviderTimeouts(options.settings),
    describeAgentStatus(options.agentStatus),
    describeAgentControlTimeouts(options.settings.agent),
  ];

  if (options.lastError) {
    lines.push(`최근 오류: ${options.lastError}`);
  }

  if (options.diagnostics) {
    lines.push(
      `필수 명령 준비: ${options.diagnostics.required.length - options.diagnostics.missingRequired.length}/${options.diagnostics.required.length}`,
    );

    if (options.diagnostics.optional.length > 0) {
      lines.push(
        `선택 명령 준비: ${options.diagnostics.optional.length - options.diagnostics.missingOptional.length}/${options.diagnostics.optional.length}`,
      );
    }

    if (options.diagnostics.missingRequired.length > 0) {
      lines.push(`누락된 필수 명령: ${formatCommandBindings(options.diagnostics.missingRequired)}`);
    }

    if (options.diagnostics.missingOptional.length > 0) {
      lines.push(`누락된 선택 명령: ${formatCommandBindings(options.diagnostics.missingOptional)}`);
    }
  }

  const guidance = collectSetupGuidance(options);
  if (guidance.length > 0) {
    lines.push("권장 조치:");
    lines.push(...guidance.map((item) => `- ${item}`));
  }

  lines.push("빠른 확인:");
  lines.push(`- 진단: ${buildDoctorCommand()}`);
  lines.push(`- 환경 변수: ${buildAgentEnvCommand(options.address)}`);
  const smokeCommand = buildSmokeCommand(options.settings, options.address);
  if (smokeCommand) {
    lines.push(`- 스모크: ${smokeCommand}`);
  }

  return lines.join("\n");
}

function collectSetupGuidance(options: {
  connected: boolean;
  settings: BridgeSettings;
  agentStatus: LocalAgentStatus;
  diagnostics?: BridgeCommandDiagnostics;
  lastError?: string;
}): string[] {
  const actions: string[] = [];
  const issueText = [
    options.lastError,
    options.agentStatus.lastError,
    ...options.agentStatus.outputTail,
  ]
    .filter((value): value is string => typeof value === "string" && value.trim().length > 0)
    .join("\n")
    .toLowerCase();

  const addAction = (message: string): void => {
    if (!actions.includes(message)) {
      actions.push(message);
    }
  };

  if (
    options.settings.mode === "command" &&
    options.settings.commandProvider === "builtin_cursor_agent" &&
    !options.settings.cursorAgent.workspaceRoot?.trim()
  ) {
    addAction("프로젝트 폴더를 열거나 `vibedeckBridge.cursorAgent.workspaceRoot`를 설정하세요.");
  }

  if (!options.connected && options.agentStatus.launchMode === "manual") {
    addAction(
      "로컬 agent 자동 실행을 쓰려면 VibeDeck 저장소를 작업 폴더로 열고 `vibedeck_doctor.ps1`로 상태를 확인하세요. 별도 실행 파일을 쓸 때는 `vibedeckBridge.agent.launchMode=binary`와 `vibedeckBridge.agent.binaryPath`를 설정하세요.",
    );
  }

  if (issueText.includes("workspace root is not configured")) {
    addAction("현재 워크스페이스가 비어 있습니다. 프로젝트 폴더를 연 뒤 다시 시작하세요.");
  }

  if (issueText.includes("agent repo root is required for go_run mode")) {
    addAction("`vibedeckBridge.agent.repoRoot`를 VibeDeck 저장소 루트로 지정하거나, 저장소 폴더를 그대로 열어 다시 시도하세요.");
  }

  if (issueText.includes("agent binary path is required for binary mode")) {
    addAction("`vibedeckBridge.agent.binaryPath`에 agent 실행 파일 경로를 설정하세요.");
  }

  if (issueText.includes("manual mode cannot be launched")) {
    addAction("`vibedeckBridge.agent.launchMode`를 `go_run` 또는 `binary`로 바꾸세요.");
  }

  if (issueText.includes("authentication required") || issueText.includes("agent login")) {
    if (options.settings.cursorAgent.useWsl) {
      addAction(
        `WSL 안에서 \`cursor-agent login\`을 먼저 실행하세요${options.settings.cursorAgent.wslDistro ? ` (${options.settings.cursorAgent.wslDistro})` : ""}.`,
      );
    } else {
      addAction("`cursor-agent login`을 먼저 실행하거나 `CURSOR_API_KEY` 환경 변수를 설정하세요.");
    }
  }

  if (issueText.includes("trust")) {
    addAction("작업공간 신뢰가 필요하면 `vibedeckBridge.cursorAgent.trustWorkspace=true`로 두고 다시 시도하세요.");
  }

  if (
    issueText.includes("free plans can only use auto") ||
    issueText.includes("named models unavailable")
  ) {
    addAction("무료 플랜에서는 `vibedeckBridge.cursorAgent.model=auto`를 사용하세요.");
  }

  if (options.diagnostics?.missingRequired.length) {
    addAction("필수 브리지 명령이 누락되었습니다. extension host를 다시 시작하거나 브리지 확장 빌드를 다시 확인하세요.");
  }

  if (options.diagnostics?.missingOptional.length) {
    addAction("선택 명령이 일부 빠져 있습니다. 패널이나 파일/터미널 표면이 비어 보이면 확장 빌드와 명령 등록 상태를 다시 확인하세요.");
  }

  if (options.agentStatus.state === "error" && actions.length === 0) {
    addAction("아래 진단 명령으로 PC 환경을 점검한 뒤 extension을 다시 시작하세요.");
  }

  return actions;
}
