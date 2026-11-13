// Drives the "Tinycast in action" gallery + lightbox. Each item is a tile in
// the grid and a slide in the lightbox. Stills are WebP: an 800px `thumb` for
// the grid and a 2400px `src` or `poster` for the lightbox. `src`/`thumb`/`poster` are URLs as
// rendered — root-absolute for `public/`, absolute for anything on R2.
// `width`/`height` are the media's real pixel size (used for lightbox aspect);
// the grid tile is always 16:9.

import { site } from "./site";

export type GalleryItem = {
  type: "image" | "video";
  // Full-size media shown in the lightbox (image src, or video file for clips).
  src: string;
  // Grid thumbnail; falls back to `poster` (video) or `src` (image).
  thumb?: string;
  // Poster frame for video tiles/slides.
  poster?: string;
  title: string;
  caption: string;
  width: number;
  height: number;
};

export const galleryItems: GalleryItem[] = [
  {
    type: "video",
    src: `${site.cdn}/calculator.mp4`,
    poster: "/gallery/calculator.webp",
    thumb: "/gallery/calculator-thumb.webp",
    title: "Inline calculator",
    caption: "Answers math and converts units and currencies as you type.",
    width: 1728,
    height: 1118,
  },
  {
    type: "image",
    src: "/gallery/clipboard-history.webp",
    thumb: "/gallery/clipboard-history-thumb.webp",
    title: "Clipboard history",
    caption:
      "Search the text and images you've copied. History is stored only on your Mac.",
    width: 2400,
    height: 1551,
  },
  {
    type: "video",
    src: `${site.cdn}/dictation.mp4`,
    poster: "/gallery/dictation.webp",
    thumb: "/gallery/dictation-thumb.webp",
    title: "Dictation",
    caption:
      "Turn your voice into text in any app. Fast, private and fully on-device.",
    width: 1728,
    height: 1118,
  },
  {
    type: "video",
    src: `${site.cdn}/emoji-and-symbols.mp4`,
    poster: "/gallery/emoji-and-symbols.webp",
    thumb: "/gallery/emoji-and-symbols-thumb.webp",
    title: "Emoji & symbols",
    caption: "Search every emoji. The ones you use most show up first.",
    width: 1728,
    height: 1118,
  },
  {
    type: "video",
    src: `${site.cdn}/notes.mp4`,
    poster: "/gallery/notes.webp",
    thumb: "/gallery/notes-thumb.webp",
    title: "Notes",
    caption:
      "Capture ideas in Markdown. Keep your notes close, without breaking your flow.",
    width: 1728,
    height: 1118,
  },
  {
    type: "video",
    src: `${site.cdn}/quick-ai.mp4`,
    poster: "/gallery/quick-ai.webp",
    thumb: "/gallery/quick-ai-thumb.webp",
    title: "Quick AI",
    caption:
      "Ask your favorite AI. Get quick answers or open a full chat with history.",
    width: 1728,
    height: 1118,
  },
  {
    type: "video",
    src: `${site.cdn}/quick-actions.mp4`,
    poster: "/gallery/quick-actions.webp",
    thumb: "/gallery/quick-actions-thumb.webp",
    title: "Quick Actions",
    caption:
      "Rewrite, translate, summarize and more with AI. Create your own custom actions.",
    width: 1728,
    height: 1118,
  },
  {
    type: "image",
    src: "/gallery/activity-monitor.webp",
    thumb: "/gallery/activity-monitor-thumb.webp",
    title: "Light on memory",
    caption: "Stays under 100 MB of memory, no matter how long it runs.",
    width: 2400,
    height: 1551,
  },
];
