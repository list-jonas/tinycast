// What the hero palette lists for a query, laid out row by row. Kept apart
// from the component so the stage can search without rendering.

import {
  demoFallbacks,
  demoSearchable,
  demoSections,
  type DemoRow,
} from "../data/demo";
import { calculate, type Answer } from "./demo-calc";

// The palette's geometry in px, shared by the layout and the sliding selection
// so the highlight lands on a row without measuring the DOM.
export const PALETTE_WIDTH = 700;
export const PALETTE_HEIGHT = 452;
export const SEARCH_HEIGHT = 58;
export const ROW_HEIGHT = 38;
export const HEADER_HEIGHT = 30;
export const ANSWER_HEIGHT = 116;
export const LIST_HEIGHT = PALETTE_HEIGHT - SEARCH_HEIGHT;

type Block =
  | { type: "header"; title: string; top: number; isFallback?: boolean }
  | { type: "answer"; answer: Answer; top: number; index: number }
  | {
      type: "row";
      row: DemoRow;
      top: number;
      index: number;
      shortcut?: string[];
    };

export type Results = { blocks: Block[]; count: number; height: number };

function score(row: DemoRow, query: string) {
  const title = row.title.toLowerCase();
  if (title.startsWith(query)) return 3;
  const words = `${title} ${row.keywords ?? ""}`.split(/\s+/);
  if (words.some((word) => word.startsWith(query))) return 2;
  return title.includes(query) ? 1 : 0;
}

/** Lays out what the palette shows for `query`: an answer or matches, then fallbacks. */
export function search(query: string): Results {
  const blocks: Block[] = [];
  let top = 4;
  let index = 0;
  const header = (title: string, isFallback = false) => {
    blocks.push({ type: "header", title, top, isFallback });
    top += HEADER_HEIGHT;
  };
  const addRow = (row: DemoRow, shortcut?: string[]) => {
    blocks.push({ type: "row", row, top, index: index++, shortcut });
    top += ROW_HEIGHT;
  };

  const trimmed = query.trim().toLowerCase();
  if (!trimmed) {
    for (const section of demoSections) {
      header(section.title);
      // Favorites trade their kind label for the ⌘1…⌘0 that opens them.
      section.rows.forEach((row, position) =>
        addRow(
          row,
          section.title === "Favorites"
            ? ["⌘", String(position + 1)]
            : undefined,
        ),
      );
    }
    return { blocks, count: index, height: top };
  }

  // An answer replaces the matches; with neither, the query falls back alone.
  const answer = calculate(query);
  const matches = answer
    ? []
    : demoSearchable
        .map((row) => ({ row, rank: score(row, trimmed) }))
        .filter(({ rank }) => rank > 0)
        .sort((a, b) => b.rank - a.rank);
  if (answer) {
    header("Calculator");
    blocks.push({ type: "answer", answer, top, index: index++ });
    top += ANSWER_HEIGHT;
  }
  if (matches.length) {
    header("Results");
    matches.forEach(({ row }) => addRow(row));
  } else {
    header(`Use “${query.trim()}” with…`, true);
    demoFallbacks.forEach((row) => addRow(row));
  }
  return { blocks, count: index, height: top };
}
