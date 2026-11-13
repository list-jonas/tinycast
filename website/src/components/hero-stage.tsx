"use client";

import { Pause, Play } from "lucide-react";
import {
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  type CSSProperties,
  type KeyboardEvent,
} from "react";
import { demoClipboard, demoScenes } from "../data/demo";
import { PALETTE_HEIGHT, PALETTE_WIDTH, search } from "../lib/demo-search";
import { HeroPalette, type PaletteView } from "./hero-palette";

// The stage is drawn at one fixed size and scaled to fit, so the palette keeps
// the app's own point sizes at every width instead of reflowing into a mock.
const STAGE_WIDTH = 1120;
const STAGE_HEIGHT = 660;
// The whole desktop is shown, inside a gutter, down to MIN_FIT of its size.
// Below that the sides are cropped instead, so the palette stays legible.
const STAGE_GUTTER = 24;
const MIN_FIT = 0.8;
const CROPPED_WIDTH = PALETTE_WIDTH + 40;
const DECK_OVERLAP = 34;
const DECK_HEIGHT = 78;
const TOTAL_HEIGHT = STAGE_HEIGHT + DECK_HEIGHT - DECK_OVERLAP;

type DeckKey =
  "control" | "option" | "command" | "space" | "commandRight" | "optionRight";

const deck: { id: DeckKey; glyph: string; label: string; width: number }[] = [
  { id: "control", glyph: "⌃", label: "control", width: 66 },
  { id: "option", glyph: "⌥", label: "option", width: 66 },
  { id: "command", glyph: "⌘", label: "command", width: 84 },
  { id: "space", glyph: "", label: "", width: 268 },
  { id: "commandRight", glyph: "⌘", label: "command", width: 84 },
  { id: "optionRight", glyph: "⌥", label: "option", width: 66 },
];

const keyForEvent: Record<string, DeckKey> = {
  MetaLeft: "command",
  MetaRight: "commandRight",
  AltLeft: "option",
  AltRight: "optionRight",
  ControlLeft: "control",
  Space: "space",
};

class Stopped extends Error {}

/** Resolves after `ms` of time the stage was actually on screen. */
function makeClock(isPaused: () => boolean, signal: AbortSignal) {
  return (ms: number) =>
    new Promise<void>((resolve, reject) => {
      let left = ms;
      let last = performance.now();
      const tick = () => {
        if (signal.aborted) return reject(new Stopped());
        const now = performance.now();
        if (!isPaused()) left -= now - last;
        last = now;
        if (left <= 0) resolve();
        else setTimeout(tick, Math.min(left, 120));
      };
      setTimeout(tick, Math.min(ms, 120));
    });
}

// Tinycast's own menu bar glyph: the template thunder from MenuBarIcon.imageset.
function MenuBarMark() {
  return (
    <svg
      width="10"
      height="14"
      viewBox="4.6 1.7 14.8 20.6"
      fill="currentColor"
      aria-hidden="true"
    >
      <path d="M18.82 9.18A2 2 0 0 0 17 8h-1.81l1.33-3.26a2 2 0 0 0-.19-1.84 2.06 2.06 0 0 0-1.71-.9h-4.34a2 2 0 0 0-1.91 1.27l-3.23 8a2 2 0 0 0 .2 1.83 2.06 2.06 0 0 0 1.71.9h2.76L8 20.74a1 1 0 0 0 .5 1.15A1.1 1.1 0 0 0 9 22a1 1 0 0 0 .76-.35l8.8-10.37a2 2 0 0 0 .26-2.1" />
    </svg>
  );
}

// The SF Symbols macOS draws in its menu bar, rendered white from the system.
function MenuSymbol({ name, height }: { name: string; height: number }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src={`/menubar/${name}.png`}
      alt=""
      style={{ height }}
      className="w-auto"
    />
  );
}

function MenuBar() {
  return (
    <div
      aria-hidden="true"
      className="absolute inset-x-0 top-0 z-10 flex h-[30px] items-center justify-between px-4 text-[13px] font-medium text-white [text-shadow:0_0_6px_rgb(0_0_0/0.25)]"
    >
      <div className="flex items-center gap-[18px]">
        <span className="flex w-5 justify-center">
          <MenuSymbol name="apple.logo" height={15} />
        </span>
        <span className="font-bold">Finder</span>
        {["File", "Edit", "View", "Go", "Window", "Help"].map((item) => (
          <span key={item}>{item}</span>
        ))}
      </div>
      <div className="flex items-center gap-[18px]">
        <MenuBarMark />
        <MenuSymbol name="battery.100percent" height={12} />
        <MenuSymbol name="wifi" height={13} />
        <MenuSymbol name="magnifyingglass" height={14} />
        <MenuSymbol name="switch.2" height={14} />
        <span>Mon 9 Nov&nbsp;&nbsp;9:41</span>
      </div>
    </div>
  );
}

function KeyboardDeck({
  pressed,
  onPress,
}: {
  pressed: ReadonlySet<DeckKey>;
  onPress: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onPress}
      aria-label="Replay the ⌘ Space shortcut"
      className="keyboard-deck absolute left-1/2 flex -translate-x-1/2 items-center gap-[7px] rounded-[20px] p-[12px]"
      style={{ top: STAGE_HEIGHT - DECK_OVERLAP, height: DECK_HEIGHT }}
    >
      {deck.map((key) => (
        <span
          aria-hidden="true"
          key={key.id}
          data-pressed={pressed.has(key.id) || undefined}
          className="deck-key relative h-full rounded-[10px]"
          style={{ width: key.width }}
        >
          <span className="absolute right-2 top-1.5 text-[13px]">
            {key.glyph}
          </span>
          <span className="absolute bottom-1.5 left-2 text-[10px] tracking-wide">
            {key.label}
          </span>
        </span>
      ))}
    </button>
  );
}

/**
 * The hero's desktop: a wallpaper, the menu bar, and the palette, opened by a
 * ⌘ Space pressed on the keyboard below. It plays a short script until the
 * visitor clicks in and types for themselves.
 */
export function HeroStage() {
  const frame = useRef<HTMLDivElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const autoplay = useRef<AbortController | null>(null);
  const [scale, setScale] = useState<number | null>(null);
  const [isOpen, setIsOpen] = useState(true);
  const [query, setQuery] = useState("");
  const [selected, setSelected] = useState(0);
  const [pressed, setPressed] = useState<ReadonlySet<DeckKey>>(new Set());
  const [isFiring, setIsFiring] = useState(false);
  const [isLive, setIsLive] = useState(false);
  const [isAutoplaying, setIsAutoplaying] = useState(false);
  const [isPaused, setIsPaused] = useState(false);
  const paused = useRef(false);
  const hintId = useId();
  const [view, setView] = useState<PaletteView>("search");
  const results = search(view === "search" ? query : "");
  const needle = query.trim().toLowerCase();
  const clipboard =
    view === "clipboard"
      ? demoClipboard.filter((entry) =>
          entry.label.toLowerCase().includes(needle),
        )
      : [];
  const count = view === "clipboard" ? clipboard.length : results.count;

  useLayoutEffect(() => {
    const element = frame.current;
    if (!element) return;
    const observer = new ResizeObserver(([entry]) => {
      const width = entry.contentRect.width;
      const fit = (width - 2 * STAGE_GUTTER) / STAGE_WIDTH;
      setScale(Math.min(1, fit >= MIN_FIT ? fit : width / CROPPED_WIDTH));
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, []);

  useEffect(() => {
    const element = frame.current;
    if (!element || matchMedia("(prefers-reduced-motion: reduce)").matches)
      return;
    const controller = new AbortController();
    autoplay.current = controller;
    let isVisible = true;
    const observer = new IntersectionObserver(([entry]) => {
      isVisible = entry.isIntersecting;
    });
    observer.observe(element);
    const wait = makeClock(
      () => !isVisible || document.hidden || paused.current,
      controller.signal,
    );
    setIsAutoplaying(true);
    const jitter = (base: number, spread: number) =>
      base + Math.random() * spread;

    const type = async (text: string) => {
      for (let i = 1; i <= text.length; i++) {
        setQuery(text.slice(0, i));
        setSelected(0);
        await wait(jitter(55, 75));
      }
    };
    const erase = async (text: string) => {
      for (let i = text.length - 1; i >= 0; i--) {
        setQuery(text.slice(0, i));
        await wait(22);
      }
      setSelected(0);
    };
    const fire = async () => {
      setIsFiring(true);
      await wait(260);
      setIsFiring(false);
      await wait(240);
    };
    const summon = async () => {
      setPressed(new Set(["command"]));
      await wait(240);
      setPressed(new Set(["command", "space"]));
      await wait(110);
      setIsOpen(true);
      await wait(200);
      setPressed(new Set());
    };

    const run = async () => {
      setIsOpen(false);
      await wait(1300);
      for (;;) {
        await summon();
        await wait(500);
        for (const scene of demoScenes) {
          await type(scene.query);
          await wait(scene.query ? 1100 : 700);
          for (let step = 1; step <= (scene.select ?? 0); step++) {
            setSelected(step);
            await wait(380);
          }
          await wait(scene.opens ? 500 : 1300);
          await fire();
          if (scene.opens) {
            setView(scene.opens);
            setQuery("");
            setSelected(0);
            for (let step = 1; step <= 3; step++) {
              await wait(1200);
              setSelected(step);
            }
            await wait(1600);
            setView("search");
            setQuery(scene.query);
            setSelected(0);
            await wait(500);
          }
          await erase(scene.query);
          await wait(260);
        }
        setIsOpen(false);
        await wait(1600);
      }
    };
    run().catch((error) => {
      if (!(error instanceof Stopped)) throw error;
    });

    return () => {
      controller.abort();
      observer.disconnect();
    };
  }, []);

  const takeOver = () => {
    if (isLive) return;
    autoplay.current?.abort();
    setIsAutoplaying(false);
    setIsLive(true);
    setIsOpen(true);
    setIsFiring(false);
    setPressed(new Set());
    setQuery("");
    setSelected(0);
    setView("search");
  };

  const onKeyDown = (event: KeyboardEvent<HTMLInputElement>) => {
    const key = keyForEvent[event.code];
    if (key && key !== "space") setPressed((keys) => new Set(keys).add(key));
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setSelected((index) => (index + step + count) % Math.max(count, 1));
    } else if (event.key === "Enter") {
      setIsFiring(true);
      setTimeout(() => setIsFiring(false), 260);
      const chosen = results.blocks.find(
        (block) => block.type === "row" && block.index === selected,
      );
      if (
        view === "search" &&
        chosen?.type === "row" &&
        chosen.row.glyph === "clipboard"
      ) {
        setTimeout(() => {
          setView("clipboard");
          setQuery("");
          setSelected(0);
        }, 260);
      }
    } else if (event.key === "Escape") {
      if (query) setQuery("");
      else if (view === "clipboard") {
        setView("search");
        setSelected(0);
      } else input.current?.blur();
    }
  };

  // Mirrors the visitor's own modifier keys onto the deck while they type.
  useEffect(() => {
    if (!isLive) return;
    const release = (event: globalThis.KeyboardEvent) => {
      const key = keyForEvent[event.code];
      if (key)
        setPressed((keys) => {
          const next = new Set(keys);
          next.delete(key);
          return next;
        });
    };
    const clear = () => setPressed(new Set());
    addEventListener("keyup", release);
    addEventListener("blur", clear);
    return () => {
      removeEventListener("keyup", release);
      removeEventListener("blur", clear);
    };
  }, [isLive]);

  // WCAG 2.2.2: a demo that loops for good needs a way to stop it.
  const togglePause = () => {
    paused.current = !paused.current;
    setIsPaused(paused.current);
  };

  // Spoken only once the visitor is driving: the autoplay would talk over everything.
  const chosen = results.blocks.find(
    (block) => block.type !== "header" && block.index === selected,
  );
  const announcement = !isLive
    ? ""
    : view === "clipboard"
      ? `${clipboard.length} clipboard entries. ${clipboard[selected]?.label ?? ""}`
      : chosen?.type === "answer"
        ? `${chosen.answer.input} equals ${chosen.answer.result}`
        : `${results.count} ${results.count === 1 ? "result" : "results"}. ${chosen?.type === "row" ? chosen.row.title : ""}`;

  const replay = () => {
    takeOver();
    setPressed(new Set(["command", "space"]));
    setIsOpen(false);
    setTimeout(() => {
      setIsOpen(true);
      setPressed(new Set());
      input.current?.focus();
    }, 260);
  };

  return (
    <div ref={frame} className="relative w-full [overflow-x:clip]">
      <div
        className="hero-stage-box relative mx-auto"
        style={
          {
            "--stage-scale": scale ?? undefined,
            height: `calc(${TOTAL_HEIGHT}px * var(--stage-scale))`,
          } as CSSProperties
        }
      >
        <div
          className="absolute left-1/2 top-0 origin-top"
          style={{
            width: STAGE_WIDTH,
            height: TOTAL_HEIGHT,
            transform: "translateX(-50%) scale(var(--stage-scale))",
          }}
        >
          <div
            className="hero-desktop absolute inset-x-0 top-0 overflow-hidden rounded-[22px]"
            style={{ height: STAGE_HEIGHT }}
          >
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src="/wallpaper.webp"
              alt=""
              width={2400}
              height={1500}
              fetchPriority="high"
              decoding="async"
              className="absolute inset-0 size-full object-cover"
            />
            <MenuBar />
            <div
              data-open={isOpen || undefined}
              className="palette-pop absolute left-1/2"
              style={{
                top: 104,
                marginLeft: -PALETTE_WIDTH / 2,
                height: PALETTE_HEIGHT,
              }}
              onPointerDown={takeOver}
            >
              <HeroPalette
                view={view}
                clipboard={clipboard}
                query={query}
                selected={Math.min(selected, Math.max(count - 1, 0))}
                results={results}
                isFiring={isFiring}
                inputRef={input}
                onQuery={(value) => {
                  takeOver();
                  setQuery(value);
                  setSelected(0);
                }}
                onKeyDown={onKeyDown}
                onFocus={takeOver}
                describedBy={hintId}
              />
            </div>
          </div>
          <KeyboardDeck pressed={pressed} onPress={replay} />
        </div>
      </div>
      <p id={hintId} className="sr-only">
        A live demo of the Tinycast palette. Type to search, use the arrow keys
        to move the selection, Return to run it and Escape to clear.
      </p>
      <p role="status" className="sr-only">
        {announcement}
      </p>
      {isAutoplaying && (
        <div className="mt-3 flex justify-center">
          <button
            type="button"
            onClick={togglePause}
            className="inline-flex h-8 items-center gap-1.5 rounded-full px-3 text-caption text-fg-subtle transition-colors hover:bg-tint/5 hover:text-fg"
          >
            {isPaused ? (
              <Play size={12} aria-hidden="true" />
            ) : (
              <Pause size={12} aria-hidden="true" />
            )}
            {isPaused ? "Play demo" : "Pause demo"}
          </button>
        </div>
      )}
    </div>
  );
}
