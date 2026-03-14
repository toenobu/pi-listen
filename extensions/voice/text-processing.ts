/**
 * Voice text processing — command detection & shortcut expansion.
 * Extracted as a pure module for testability.
 *
 * Only includes actions that work via the extension API (editor text manipulation).
 * Pi doesn't expose APIs to trigger keybindings, slash commands, or submit messages.
 */

// ─── Voice Command Detection ─────────────────────────────────────────────

const VOICE_COMMAND_MAP: Record<string, string> = {
	// Editor text manipulation — these work because we have setEditorText/getEditorText
	"undo": "__UNDO__",
	"undo that": "__UNDO__",
	"clear": "__CLEAR__",
	"clear all": "__CLEAR__",
	"new line": "__NEWLINE__",
	"newline": "__NEWLINE__",
};

export interface VoiceCommandResult {
	isCommand: boolean;
	action?: string;
}

export function detectVoiceCommand(text: string): VoiceCommandResult {
	const lower = text.toLowerCase().trim().replace(/[.,!?]/g, "");

	const action = VOICE_COMMAND_MAP[lower];
	if (action) {
		return { isCommand: true, action };
	}

	return { isCommand: false };
}

// ─── Voice Shortcuts (inline replacements during dictation) ──────────────

export function processVoiceShortcuts(text: string): string {
	return text
		.replace(/\bnew line\b/gi, "\n")
		.replace(/\bnewline\b/gi, "\n")
		.replace(/\bperiod\b/gi, ".")
		.replace(/\bcomma\b/gi, ",")
		.replace(/\bquestion mark\b/gi, "?")
		.replace(/\bexclamation mark\b/gi, "!")
		.replace(/\bcolon\b/gi, ":")
		.replace(/\bsemicolon\b/gi, ";")
		.replace(/\bopen parenthesis\b/gi, "(")
		.replace(/\bclose parenthesis\b/gi, ")")
		.replace(/\bopen bracket\b/gi, "[")
		.replace(/\bclose bracket\b/gi, "]")
		.replace(/\bopen brace\b/gi, "{")
		.replace(/\bclose brace\b/gi, "}")
		.replace(/\bbackslash\b/gi, "\\")
		.replace(/\bforward slash\b/gi, "/")
		.replace(/\bhash\b/gi, "#")
		.replace(/\bat sign\b/gi, "@")
		.replace(/\bdollar sign\b/gi, "$")
		.replace(/\bampersand\b/gi, "&")
		.replace(/\bpercent\b/gi, "%")
		.replace(/\basterisk\b/gi, "*")
		.replace(/\btab\b/gi, "\t");
}
