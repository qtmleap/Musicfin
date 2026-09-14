// Palette entries for the agent tasks.
//
// VS Code will not put a task in the command palette on its own: everything in
// tasks.json is reachable only through "Tasks: Run Task", and the request to
// change that (microsoft/vscode#101761) is still open. This extension exists
// solely to close that gap, so it contributes commands and nothing else.
//
// Each command runs the task of the same name rather than shelling out itself.
// tasks.json stays the one place that says what starting or restarting the
// agents means, and this file stays a list of names.

const vscode = require("vscode");

const COMMANDS = [
	["agents.start", "start-agents"],
	["agents.restart", "restart-agents"],
	["agents.attach", "attach-agents"],
];

async function runTask(name) {
	// fetchTasks reads every provider, so `name` is matched against the task's
	// label. A workspace without that label is not an error worth a modal: this
	// extension is installed per machine and follows the user into repositories
	// that have no scripts/agents at all.
	const tasks = await vscode.tasks.fetchTasks();
	const task = tasks.find((t) => t.name === name);
	if (!task) {
		vscode.window.showWarningMessage(
			`No task named "${name}" in this workspace.`,
		);
		return;
	}
	await vscode.tasks.executeTask(task);
}

function activate(context) {
	for (const [command, task] of COMMANDS) {
		context.subscriptions.push(
			vscode.commands.registerCommand(command, () => runTask(task)),
		);
	}
}

function deactivate() {}

module.exports = { activate, deactivate };
