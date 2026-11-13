"use client";

import {
  ArrowRight,
  BookOpen,
  CalendarDays,
  ChevronDown,
  ChevronLeft,
  List,
  ClipboardCopy,
  Diff,
  FileSearch,
  Lock,
  Maximize2,
  NotebookPen,
  PanelLeft,
  Search,
  Settings,
  Smile,
  Sparkles,
  SquareTerminal,
} from "lucide-react";
import type { ComponentType, KeyboardEvent, Ref } from "react";
import {
  demoClipboardPlaceholder,
  demoPasteAction,
  demoPlaceholder,
  type ClipboardEntry,
  type DemoGlyph,
  type DemoRow,
} from "../data/demo";
import { cn } from "../lib/cn";
import type { Answer } from "../lib/demo-calc";
import {
  ANSWER_HEIGHT,
  HEADER_HEIGHT,
  LIST_HEIGHT,
  PALETTE_HEIGHT,
  PALETTE_WIDTH,
  ROW_HEIGHT,
  SEARCH_HEIGHT,
  type Results,
} from "../lib/demo-search";
import { ClipboardScreen } from "./hero-clipboard";
import { LiquidGlass } from "./ui/liquid-glass";

// Lucide's nearest match to the SF Symbol the app draws for each command.
const glyphs: Record<
  DemoGlyph,
  ComponentType<{ size?: number; strokeWidth?: number }>
> = {
  clipboard: ClipboardCopy,
  calculator: Diff,
  emoji: Smile,
  note: NotebookPen,
  window: PanelLeft,
  maximize: Maximize2,
  sparkles: Sparkles,
  files: FileSearch,
  calendar: CalendarDays,
  lock: Lock,
  terminal: SquareTerminal,
  book: BookOpen,
};

// The rows the floating footer leaves uncovered.
const VISIBLE_LIST = LIST_HEIGHT - 64;

function Keycap({ children }: { children: string }) {
  return (
    <span className="inline-flex h-[18px] min-w-[18px] items-center justify-center rounded-[5px] border border-(--glass-key-border) px-1 text-demo-key font-medium text-(--glass-fg-muted)">
      {children}
    </span>
  );
}

function MenuGlyph() {
  return (
    <span className="flex flex-col items-start gap-[3px]">
      <span className="h-[1.5px] w-3.5 rounded-full bg-current" />
      <span className="h-[1.5px] w-2 rounded-full bg-current" />
    </span>
  );
}

// An application draws its own icon, margin and shadow included, across the
// whole 26px slot. A command's symbol sits on a 22px neutral tile, the inset
// the app gives it so both kinds line up.
function RowIcon({ row }: { row: DemoRow }) {
  if (row.image) {
    return (
      <span className="relative size-[26px] shrink-0">
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={row.image}
          alt=""
          width={26}
          height={26}
          decoding="async"
          className="size-full"
        />
        {row.isRunning && (
          <span className="absolute -bottom-[3px] left-1/2 size-[3px] -translate-x-1/2 rounded-full bg-(--glass-fg-muted)" />
        )}
      </span>
    );
  }
  const Glyph = glyphs[row.glyph ?? "sparkles"];
  return (
    <span className="flex size-[26px] shrink-0 items-center justify-center">
      <span className="flex size-[22px] items-center justify-center rounded-[6px] bg-(--glass-tile) text-(--glass-glyph)">
        <Glyph size={13} strokeWidth={2} />
      </span>
    </span>
  );
}

// Operators sit back in the muted ink, so the numbers carry the expression.
function Expression({ text }: { text: string }) {
  return text.split(/([÷×−+^]|\b(?:in|to)\b)/).map((part, index) =>
    index % 2 ? (
      <span key={index} className="text-(--glass-fg-muted)">
        {part}
      </span>
    ) : (
      part
    ),
  );
}

function AnswerSide({ value, label }: { value: string; label: string }) {
  return (
    <div className="flex min-w-0 flex-col items-center gap-2">
      <p className="max-w-full truncate text-[22px] font-semibold tracking-tight text-(--glass-fg)">
        <Expression text={value} />
      </p>
      <span className="rounded-[5px] bg-(--glass-key) px-1.5 py-px text-demo-section font-medium text-(--glass-fg-muted)">
        {label}
      </span>
    </div>
  );
}

// The answer is the selection's own surface: lit when chosen, a faint well when not.
function AnswerCard({
  answer,
  isSelected,
}: {
  answer: Answer;
  isSelected: boolean;
}) {
  return (
    <div
      className={cn(
        "grid h-[106px] grid-cols-[1fr_auto_1fr] items-center rounded-[12px] px-6 transition-colors duration-200",
        isSelected ? "bg-(--glass-selection)" : "bg-(--glass-well)",
      )}
    >
      <AnswerSide value={answer.input} label={answer.inputLabel} />
      <ArrowRight size={16} className="text-(--glass-fg-faint)" />
      <AnswerSide value={answer.result} label={answer.resultLabel} />
    </div>
  );
}

export type PaletteView = "search" | "clipboard";

type HeroPaletteProps = {
  view: PaletteView;
  clipboard: ClipboardEntry[];
  query: string;
  selected: number;
  results: Results;
  /** True for a moment after return, to flash the chosen row. */
  isFiring: boolean;
  inputRef: Ref<HTMLInputElement>;
  onQuery: (query: string) => void;
  onKeyDown: (event: KeyboardEvent<HTMLInputElement>) => void;
  onFocus: () => void;
  /** The visually hidden instructions the input points screen readers to. */
  describedBy: string;
};

// The palette as the app draws it. No rule anywhere inside: the real window
// separates its search field, list and action bar with spacing alone, and a
// hairline is the one thing that makes a mock read as a web card.
export function HeroPalette({
  view,
  clipboard,
  query,
  selected,
  results,
  isFiring,
  inputRef,
  onQuery,
  onKeyDown,
  onFocus,
  describedBy,
}: HeroPaletteProps) {
  const chosen = results.blocks.find(
    (block) => block.type !== "header" && block.index === selected,
  );
  const highlightTop = chosen?.top ?? 0;
  const highlightHeight = chosen?.type === "answer" ? 0 : ROW_HEIGHT;
  const shift = Math.max(
    0,
    Math.min(
      highlightTop +
        (chosen?.type === "answer" ? ANSWER_HEIGHT : ROW_HEIGHT) -
        VISIBLE_LIST,
      results.height - VISIBLE_LIST,
    ),
  );
  const isClipboard = view === "clipboard";
  const action = isClipboard
    ? demoPasteAction
    : chosen?.type === "answer"
      ? "Copy Answer"
      : chosen?.type === "row"
        ? (chosen.row.action ?? "Open")
        : "Open";

  return (
    <LiquidGlass
      radius={26}
      bezel={24}
      refraction={28}
      blur={70}
      className="glass-palette text-left"
      style={{ width: PALETTE_WIDTH, height: PALETTE_HEIGHT }}
    >
      {/* The glyph's left edge lines up with the row icons below it. */}
      <label
        className="relative flex items-center gap-2.5 px-4"
        style={{ height: SEARCH_HEIGHT }}
      >
        {isClipboard ? (
          <ChevronLeft
            size={22}
            strokeWidth={2}
            className="shrink-0 text-(--glass-fg-muted)"
          />
        ) : (
          <Search
            size={21}
            strokeWidth={1.9}
            className="shrink-0 text-(--glass-fg-muted)"
          />
        )}
        <input
          ref={inputRef}
          value={query}
          onChange={(event) => onQuery(event.target.value)}
          onKeyDown={onKeyDown}
          onFocus={onFocus}
          placeholder={isClipboard ? demoClipboardPlaceholder : demoPlaceholder}
          aria-label="Try the Tinycast palette"
          aria-describedby={describedBy}
          spellCheck={false}
          autoComplete="off"
          className="demo-input min-w-0 flex-1 bg-transparent text-demo-query text-(--glass-fg) caret-violet-bright outline-none placeholder:text-(--glass-fg-faint)"
        />
        {isClipboard ? (
          <span
            aria-hidden="true"
            className="flex shrink-0 items-center gap-1.5 text-demo-callout font-medium text-(--glass-fg-muted)"
          >
            <List size={14} />
            All Types
            <ChevronDown size={13} />
          </span>
        ) : (
          <span
            aria-hidden="true"
            className="flex shrink-0 items-center gap-1.5 text-demo-callout font-medium text-(--glass-fg-muted)"
          >
            Quick AI
            <Keycap>⇥</Keycap>
          </span>
        )}
      </label>

      {/* The last row sits on the footer's line, dissolving under its
          floating controls the way an overflowing list does in the app. */}
      {isClipboard ? (
        <div aria-hidden="true">
          <ClipboardScreen
            entries={clipboard}
            selected={selected}
            isFiring={isFiring}
          />
        </div>
      ) : (
        <div
          aria-hidden="true"
          className="glass-dissolve relative overflow-hidden"
          style={{ height: LIST_HEIGHT }}
        >
          <div
            className="demo-list relative px-2"
            style={{ transform: `translateY(${-shift}px)` }}
          >
            <span
              aria-hidden="true"
              className={cn(
                "demo-highlight absolute inset-x-2 rounded-[10px] bg-(--glass-selection)",
                isFiring && "demo-highlight-fire",
              )}
              style={{
                height: highlightHeight,
                transform: `translateY(${highlightTop}px)`,
                opacity: highlightHeight ? 1 : 0,
              }}
            />
            <div style={{ height: results.height }} className="relative">
              {results.blocks.map((block) => {
                if (block.type === "header") {
                  return (
                    <p
                      key={`h-${block.top}`}
                      className="absolute inset-x-0 flex items-end px-2 pb-1.5 text-demo-section font-semibold text-(--glass-fg-muted)"
                      style={{ top: block.top, height: HEADER_HEIGHT }}
                    >
                      <span className="truncate">{block.title}</span>
                      {block.isFallback && (
                        <Settings
                          size={11}
                          strokeWidth={2.2}
                          className="mb-px ml-1.5 shrink-0"
                        />
                      )}
                    </p>
                  );
                }
                if (block.type === "answer") {
                  return (
                    <div
                      key="answer"
                      className="absolute inset-x-0"
                      style={{ top: block.top, height: ANSWER_HEIGHT - 10 }}
                    >
                      <AnswerCard
                        answer={block.answer}
                        isSelected={block.index === selected}
                      />
                    </div>
                  );
                }
                const { row, shortcut } = block;
                return (
                  <div
                    key={row.title}
                    className="demo-row absolute inset-x-0 flex items-center gap-2.5 px-2"
                    style={{ top: block.top, height: ROW_HEIGHT }}
                  >
                    <RowIcon row={row} />
                    <span className="min-w-0 truncate text-demo-row font-medium text-(--glass-fg)">
                      {row.title}
                    </span>
                    {row.hotkey && (
                      <span className="flex shrink-0 gap-0.5">
                        {row.hotkey.map((key) => (
                          <Keycap key={key}>{key}</Keycap>
                        ))}
                      </span>
                    )}
                    {shortcut ? (
                      <span className="ml-auto flex shrink-0 gap-0.5">
                        {shortcut.map((key) => (
                          <Keycap key={key}>{key}</Keycap>
                        ))}
                      </span>
                    ) : (
                      <span className="ml-auto shrink-0 text-demo-callout text-(--glass-fg-muted)">
                        {row.kind}
                      </span>
                    )}
                  </div>
                );
              })}
              {results.count === 0 && (
                <p className="absolute inset-x-0 top-16 text-center text-demo-row text-(--glass-fg-muted)">
                  No results. Press <Keycap>⇥</Keycap> to ask Quick AI.
                </p>
              )}
            </div>
          </div>
        </div>
      )}

      <div
        aria-hidden="true"
        className="demo-footer absolute inset-x-0 bottom-0 flex h-[56px] items-center justify-between px-2.5"
      >
        <LiquidGlass
          radius={20}
          bezel={9}
          refraction={10}
          blur={14}
          className="glass-control size-10"
        >
          <span className="relative flex size-full items-center justify-center text-(--glass-fg-muted)">
            <MenuGlyph />
          </span>
        </LiquidGlass>
        <LiquidGlass
          radius={20}
          bezel={9}
          refraction={10}
          blur={14}
          className="glass-control h-10"
        >
          <span className="relative flex h-full items-center gap-0.5 px-1 text-demo-callout font-medium">
            <span className="flex h-8 items-center gap-1.5 px-2.5 text-(--glass-fg)">
              <span key={action} className="demo-action">
                {action}
              </span>
              <Keycap>↵</Keycap>
            </span>
            <span className="flex h-8 items-center gap-1.5 px-2.5 text-(--glass-fg)">
              Actions
              <span className="flex gap-0.5">
                <Keycap>⌘</Keycap>
                <Keycap>K</Keycap>
              </span>
            </span>
          </span>
        </LiquidGlass>
      </div>
    </LiquidGlass>
  );
}
