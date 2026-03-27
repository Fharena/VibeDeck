import * as vscode from "vscode";
import {
  createBridgeExtensionController,
  type BridgeExtensionContextLike,
  type BridgeExtensionVscodeLike,
} from "./bridgeExtensionController.js";

const controller = createBridgeExtensionController({
  commands: vscode.commands as unknown as BridgeExtensionVscodeLike["commands"],
  window: vscode.window as unknown as BridgeExtensionVscodeLike["window"],
  workspace: vscode.workspace as unknown as BridgeExtensionVscodeLike["workspace"],
  env: vscode.env as unknown as BridgeExtensionVscodeLike["env"],
  statusBarAlignment: {
    left: vscode.StatusBarAlignment.Left,
  },
  viewColumn: {
    one: vscode.ViewColumn.One,
    beside: vscode.ViewColumn.Beside,
  },
});

export async function activate(context: vscode.ExtensionContext): Promise<void> {
  await controller.activate(context as unknown as BridgeExtensionContextLike);
}

export async function deactivate(): Promise<void> {
  await controller.deactivate();
}
