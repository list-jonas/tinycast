"use client";

import {
  useEffect,
  useId,
  useRef,
  useState,
  type CSSProperties,
  type ReactNode,
} from "react";
import { cn } from "../../lib/cn";

type LiquidGlassProps = {
  /** Corner radius in px; the refraction map is drawn for exactly this shape. */
  radius: number;
  /** How far in from the edge the glass bends light, in px. */
  bezel?: number;
  /** Peak displacement at the rim, in px. */
  refraction?: number;
  /** Frost behind the lens, in px. */
  blur?: number;
  className?: string;
  style?: CSSProperties;
  children?: ReactNode;
};

type Lens = { url: string; width: number; height: number };

// Only Chromium resolves an SVG filter inside backdrop-filter. Everything else
// keeps the frosted fallback in CSS, which is still the material, minus the bend.
function canRefract() {
  return typeof navigator !== "undefined" && "userAgentData" in navigator;
}

// A displacement map for a rounded rectangle: red and green carry the x and y
// offset, so each rim pixel samples the backdrop further in, like a convex lens.
function drawLens(
  width: number,
  height: number,
  radius: number,
  bezel: number,
) {
  const scale = 0.5;
  const w = Math.max(1, Math.round(width * scale));
  const h = Math.max(1, Math.round(height * scale));
  const r = Math.min(radius, width / 2, height / 2);
  const canvas = document.createElement("canvas");
  canvas.width = w;
  canvas.height = h;
  const context = canvas.getContext("2d");
  if (!context) return null;
  const image = context.createImageData(w, h);
  const halfW = width / 2;
  const halfH = height / 2;

  const distance = (x: number, y: number) => {
    const qx = Math.abs(x - halfW) - (halfW - r);
    const qy = Math.abs(y - halfH) - (halfH - r);
    const outside = Math.hypot(Math.max(qx, 0), Math.max(qy, 0));
    return outside + Math.min(Math.max(qx, qy), 0) - r;
  };

  for (let py = 0; py < h; py++) {
    for (let px = 0; px < w; px++) {
      const x = (px + 0.5) / scale;
      const y = (py + 0.5) / scale;
      const depth = -distance(x, y);
      let dx = 0;
      let dy = 0;
      if (depth < bezel) {
        const t = 1 - Math.max(depth, 0) / bezel;
        // A circular profile: flat in the middle, steepest right at the rim.
        const strength = 1 - Math.sqrt(1 - t * t);
        const nx = distance(x + 1, y) - distance(x - 1, y);
        const ny = distance(x, y + 1) - distance(x, y - 1);
        const length = Math.hypot(nx, ny) || 1;
        dx = (-nx / length) * strength;
        dy = (-ny / length) * strength;
      }
      const i = (py * w + px) * 4;
      image.data[i] = 128 + dx * 127;
      image.data[i + 1] = 128 + dy * 127;
      image.data[i + 2] = 128;
      image.data[i + 3] = 255;
    }
  }
  context.putImageData(image, 0, 0);
  return canvas.toDataURL();
}

/**
 * A surface of Liquid Glass: it frosts and saturates what is behind it, bends
 * that backdrop at its rim, and catches light along its edge. Children sit on
 * top of the material. Size and shape come from `className`.
 */
export function LiquidGlass({
  radius,
  bezel = 22,
  refraction = 48,
  blur = 14,
  className,
  style,
  children,
}: LiquidGlassProps) {
  const host = useRef<HTMLDivElement>(null);
  const filterId = `lg${useId().replace(/[^a-zA-Z0-9]/g, "")}`;
  const [lens, setLens] = useState<Lens | null>(null);

  useEffect(() => {
    const element = host.current;
    if (!element || !canRefract()) return;
    let frame = 0;
    const measure = () => {
      cancelAnimationFrame(frame);
      frame = requestAnimationFrame(() => {
        const width = Math.round(element.offsetWidth);
        const height = Math.round(element.offsetHeight);
        if (!width || !height) return;
        setLens((current) => {
          if (current?.width === width && current.height === height)
            return current;
          const url = drawLens(width, height, radius, bezel);
          return url ? { url, width, height } : null;
        });
      });
    };
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => {
      observer.disconnect();
      cancelAnimationFrame(frame);
    };
  }, [radius, bezel]);

  // Chromium skips a blur inside the referenced filter, so the frost runs first in CSS.
  const refracted: CSSProperties | undefined = lens
    ? {
        backdropFilter: `blur(${blur}px) url(#${filterId}) saturate(var(--glass-saturate, 1.7))`,
        WebkitBackdropFilter: `blur(${blur}px) url(#${filterId}) saturate(var(--glass-saturate, 1.7))`,
      }
    : undefined;

  return (
    <div
      ref={host}
      className={cn("liquid-glass", className)}
      style={{ borderRadius: radius, ...style }}
    >
      <span
        aria-hidden="true"
        className="liquid-glass-material"
        style={{ "--lg-blur": `${blur}px`, ...refracted } as CSSProperties}
      />
      {lens && (
        <svg aria-hidden="true" className="absolute size-0" focusable="false">
          <filter
            id={filterId}
            x="0"
            y="0"
            width={lens.width}
            height={lens.height}
            filterUnits="userSpaceOnUse"
            primitiveUnits="userSpaceOnUse"
            colorInterpolationFilters="sRGB"
          >
            <feImage
              href={lens.url}
              x="0"
              y="0"
              width={lens.width}
              height={lens.height}
              preserveAspectRatio="none"
              result="lens"
            />
            <feDisplacementMap
              in="SourceGraphic"
              in2="lens"
              scale={refraction}
              xChannelSelector="R"
              yChannelSelector="G"
            />
          </filter>
        </svg>
      )}
      {/* Its own layer: Chromium composites the refracting backdrop above
          plain siblings, which would otherwise hide the content under it. */}
      <div className="liquid-glass-content">{children}</div>
      <span aria-hidden="true" className="liquid-glass-rim" />
    </div>
  );
}
