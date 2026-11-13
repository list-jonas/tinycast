"use client";

import { Play } from "lucide-react";
import dynamic from "next/dynamic";
import Image from "next/image";
import { useEffect, useState } from "react";
import type { Slide } from "yet-another-react-lightbox";
import { galleryItems, type GalleryItem } from "../data/gallery";
import { Section } from "./ui/section";

// The lightbox is ~30 KB gzipped and does nothing until a tile is clicked.
const GalleryLightbox = dynamic(() => import("./gallery-lightbox"));

// The grid thumbnail: an explicit thumb, else a video's poster, else the image.
const tileImage = (item: GalleryItem) =>
  item.thumb ?? (item.type === "video" ? (item.poster ?? item.src) : item.src);

// One gallery item → one lightbox slide. Images carry title/description for the
// Captions plugin; videos use the Video plugin's `sources` shape.
function toSlide(item: GalleryItem): Slide {
  if (item.type === "video") {
    return {
      type: "video",
      poster: item.poster,
      width: item.width,
      height: item.height,
      title: item.title,
      description: item.caption,
      sources: [{ src: item.src, type: "video/mp4" }],
    };
  }
  return {
    src: item.src,
    title: item.title,
    description: item.caption,
    width: item.width,
    height: item.height,
  };
}

export function Gallery() {
  const [index, setIndex] = useState(-1);
  // Once opened, keep it mounted so closing and reopening costs no fetch.
  const [everOpened, setEverOpened] = useState(false);

  function open(i: number) {
    setEverOpened(true);
    setIndex(i);
  }

  // Lock scroll ourselves instead of via the lightbox's own module: it pads the
  // scrollbar width onto <body> and every fixed element (the scroll-top button
  // included, shifting its arrow). `scrollbar-gutter: stable` already reserves
  // that space, so a plain overflow:hidden lock changes no widths — no shift.
  useEffect(() => {
    if (index < 0) return;
    const html = document.documentElement;
    const previous = html.style.overflow;
    html.style.overflow = "hidden";
    return () => {
      html.style.overflow = previous;
    };
  }, [index]);

  return (
    <Section
      id="gallery"
      label="In action"
      title="Straight from the app."
      intro="The palette at the top of this page is a recreation. These screenshots and videos come from Tinycast itself. Click to enlarge an image or play a video."
    >
      <div className="card">
        <div className="grid gap-x-3 gap-y-5 p-3 sm:grid-cols-2 lg:grid-cols-4">
          {galleryItems.map((item, i) => {
            return (
              <button
                key={`${item.title}-${i}`}
                type="button"
                onClick={() => open(i)}
                className="group flex flex-col gap-2 text-left"
              >
                <figure className="relative aspect-video w-full overflow-hidden rounded-[14px] ring-1 ring-tint/8 transition-shadow duration-300 group-hover:ring-violet-bright/60">
                  <Image
                    src={tileImage(item)}
                    alt={item.title}
                    fill
                    sizes="(min-width: 1024px) 25vw, (min-width: 640px) 45vw, 90vw"
                    className="object-cover transition-transform duration-500 ease-(--ease-settle) group-hover:scale-[1.04]"
                  />
                  {item.type === "video" && (
                    <span className="absolute inset-0 flex items-center justify-center">
                      <span className="flex size-14 items-center justify-center rounded-full bg-black/35 text-white ring-1 ring-white/30 backdrop-blur-md transition-transform duration-300 group-hover:scale-110">
                        <Play size={24} fill="currentColor" />
                      </span>
                    </span>
                  )}
                </figure>
                <div className="px-1">
                  <h3 className="text-small font-medium text-fg">
                    {item.title}
                  </h3>
                  <p className="text-small text-fg-muted">{item.caption}</p>
                </div>
              </button>
            );
          })}
        </div>
      </div>

      {everOpened && (
        <GalleryLightbox
          index={index}
          slides={galleryItems.map(toSlide)}
          close={() => setIndex(-1)}
        />
      )}
    </Section>
  );
}
