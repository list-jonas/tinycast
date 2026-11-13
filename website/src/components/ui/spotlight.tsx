"use client";

import { useEffect } from "react";

/**
 * Feeds the pointer's position to every `[data-spotlight]` card it passes over,
 * as `--mx` and `--my`, so a card's glow can follow it from CSS alone. One
 * listener for the page, and nothing at all on touch screens.
 */
export function Spotlight() {
  useEffect(() => {
    if (!matchMedia("(hover: hover)").matches) return;
    let frame = 0;
    const move = (event: PointerEvent) => {
      const card =
        event.target instanceof Element
          ? event.target.closest<HTMLElement>("[data-spotlight]")
          : null;
      if (!card) return;
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const box = card.getBoundingClientRect();
        card.style.setProperty("--mx", `${event.clientX - box.left}px`);
        card.style.setProperty("--my", `${event.clientY - box.top}px`);
      });
    };
    document.addEventListener("pointermove", move, { passive: true });
    return () => {
      document.removeEventListener("pointermove", move);
      cancelAnimationFrame(frame);
    };
  }, []);

  return null;
}
