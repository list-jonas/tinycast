// The hero's recreated palette. Labels copy the real app's strings (the action
// bar, section titles, placeholders). Applications show their own macOS icons,
// from public/app-icons; Tinycast's commands show the SF Symbol the app draws
// for each, on the same neutral tile.

export type DemoGlyph =
  | "clipboard"
  | "calculator"
  | "emoji"
  | "note"
  | "window"
  | "maximize"
  | "sparkles"
  | "files"
  | "calendar"
  | "lock"
  | "terminal"
  | "book";

export type DemoRow = {
  title: string;
  kind: string;
  /** An application's icon, served from public/app-icons. */
  image?: string;
  /** A command's symbol, drawn on a neutral tile as the app does. */
  glyph?: DemoGlyph;
  /** The row's bound hotkey, drawn as keycaps beside its title. */
  hotkey?: string[];
  /** Draws the running dot under the icon, as the launcher does for open apps. */
  isRunning?: boolean;
  /** Extra words the search matches on, as the app's own aliases do. */
  keywords?: string;
  /** The primary action's label in the action bar. */
  action?: string;
};

export type DemoSection = {
  title: string;
  rows: DemoRow[];
};

export const demoPlaceholder = "Search for apps and commands…";
export const demoAction = "Open Application";
export const demoRunAction = "Run Command";

const app = (
  title: string,
  icon: string,
  extra: Partial<DemoRow> = {},
): DemoRow => ({
  title,
  kind: "Application",
  image: `/app-icons/${icon}.webp`,
  action: demoAction,
  ...extra,
});

const command = (row: Omit<DemoRow, "action">): DemoRow => ({
  action: demoRunAction,
  ...row,
});

const rows = {
  terminal: app("Terminal", "terminal", {
    hotkey: ["⌥", "⌘", "T"],
    isRunning: true,
    keywords: "shell console",
  }),
  xcode: app("Xcode", "xcode"),
  safari: app("Safari", "safari", { keywords: "web browser", isRunning: true }),
  brave: app("Brave Browser", "brave", { keywords: "web" }),
  obsidian: app("Obsidian", "obsidian", { keywords: "notes markdown" }),
  music: app("Music", "music", { keywords: "songs" }),
  orbstack: app("OrbStack", "orbstack", { keywords: "docker" }),
  zed: app("Zed", "zed", { keywords: "editor code" }),
  notes: app("Notes", "notes"),
  calendarApp: app("Calendar", "calendar"),
  settings: app("System Settings", "system-settings", {
    keywords: "preferences",
  }),
  clipboard: command({
    title: "Clipboard History",
    kind: "Command",
    glyph: "clipboard",
    hotkey: ["⌥", "⌘", "C"],
    keywords: "paste copy",
  }),
  calculator: command({
    title: "Calculator History",
    kind: "Command",
    glyph: "calculator",
    keywords: "math convert",
  }),
  emoji: command({
    title: "Search Emoji",
    kind: "Command",
    glyph: "emoji",
    keywords: "smiley",
  }),
  note: command({
    title: "Create Note",
    kind: "Command",
    glyph: "note",
    keywords: "notes scratch",
  }),
  leftHalf: command({
    title: "Left Half",
    kind: "Window Command",
    glyph: "window",
    hotkey: ["⌃", "⌥", "←"],
    keywords: "window resize",
  }),
  maximize: command({
    title: "Maximize",
    kind: "Window Command",
    glyph: "maximize",
    keywords: "window full",
  }),
  aiChat: command({
    title: "AI Chat",
    kind: "Command",
    glyph: "sparkles",
    keywords: "ask claude",
  }),
  files: command({
    title: "Search Files",
    kind: "Command",
    glyph: "files",
    keywords: "finder documents",
  }),
  calendar: command({
    title: "My Schedule",
    kind: "Command",
    glyph: "calendar",
    keywords: "meetings events",
  }),
  lock: command({
    title: "Lock Screen",
    kind: "System Action",
    glyph: "lock",
  }),
} satisfies Record<string, DemoRow>;

// What the palette lists before anything is typed, as the app's root search does.
export const demoSections: DemoSection[] = [
  { title: "Favorites", rows: [rows.terminal, rows.xcode] },
  {
    title: "Suggestions",
    rows: [rows.clipboard, rows.safari, rows.files, rows.obsidian],
  },
  {
    title: "Applications",
    rows: [rows.music, rows.orbstack, rows.zed],
  },
];

// The commands offered to take the query itself, under the fallback header.
export const demoFallbacks: DemoRow[] = [
  command({ title: "Quick AI", kind: "Command", glyph: "sparkles" }),
  command({ title: "Search Files", kind: "Command", glyph: "files" }),
  command({ title: "Run Shell Command", kind: "Command", glyph: "terminal" }),
  command({ title: "Define Word", kind: "Command", glyph: "book" }),
];

// Everything a typed query searches, in ranking order for ties.
export const demoSearchable: DemoRow[] = Object.values(rows);

// The autoplay script: each scene types its query, walks the selection down
// `select` rows, holds, then clears. A scene that `opens` a screen runs the top
// result into it and browses there first. Calculations are answered live.
export type DemoScene = { query: string; select?: number; opens?: "clipboard" };

export const demoScenes: DemoScene[] = [
  { query: "", select: 2 },
  { query: "56 km in mi" },
  { query: "clip", opens: "clipboard" },
  { query: "left" },
  { query: "(1280 - 64) / 4" },
  { query: "time in tokyo" },
  { query: "ob", select: 1 },
];

export type ClipboardEntry = {
  label: string;
  /** What the entry is, which decides its thumbnail and preview. */
  content:
    | { type: "image"; src: string; dimensions: string }
    | { type: "color"; hex: string }
    | { type: "link"; url: string }
    | { type: "text"; text: string };
  source: { name: string; icon: string };
  size: string;
  copied: string;
};

// Clipboard History's screen, filled with things this page itself would put
// there. Labels and the information rows copy the app's own.
export const demoClipboard: ClipboardEntry[] = [
  {
    label: "Image",
    content: { type: "image", src: "/wallpaper.webp", dimensions: "2400×1500" },
    source: { name: "Safari", icon: "/app-icons/safari.webp" },
    size: "312 kB",
    copied: "Today at 9:41",
  },
  {
    label: "#863BFF",
    content: { type: "color", hex: "#863BFF" },
    source: { name: "Xcode", icon: "/app-icons/xcode.webp" },
    size: "7 bytes",
    copied: "Today at 9:38",
  },
  {
    label: "https://tinycast.dev",
    content: { type: "link", url: "https://tinycast.dev" },
    source: { name: "Safari", icon: "/app-icons/safari.webp" },
    size: "20 bytes",
    copied: "Today at 9:36",
  },
  {
    label: "brew install --cask tinycast",
    content: { type: "text", text: "brew install --cask tinycast" },
    source: { name: "Terminal", icon: "/app-icons/terminal.webp" },
    size: "28 bytes",
    copied: "Today at 9:30",
  },
  {
    label: "Image",
    content: {
      type: "image",
      src: "/clipboard-sample.webp",
      dimensions: "3359×2171",
    },
    source: { name: "Notes", icon: "/app-icons/notes.webp" },
    size: "824 kB",
    copied: "Today at 9:12",
  },
  {
    label: "Ship the new hero on Friday",
    content: { type: "text", text: "Ship the new hero on Friday" },
    source: { name: "Notes", icon: "/app-icons/notes.webp" },
    size: "27 bytes",
    copied: "Today at 8:57",
  },
];

export const demoClipboardPlaceholder = "Type to filter entries…";
export const demoPasteAction = "Paste to Finder";
