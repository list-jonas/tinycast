import { FileText, Link2 } from "lucide-react";
import type { ClipboardEntry } from "../data/demo";
import { cn } from "../lib/cn";
import { HEADER_HEIGHT, LIST_HEIGHT, ROW_HEIGHT } from "../lib/demo-search";

const LIST_WIDTH = 286;
const PREVIEW_HEIGHT = 150;

function Thumbnail({ entry }: { entry: ClipboardEntry }) {
  const { content } = entry;
  if (content.type === "image") {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={content.src}
        alt=""
        width={26}
        height={26}
        decoding="async"
        className="size-[26px] shrink-0 rounded-[6px] object-cover shadow-[0_0_0_0.5px_rgb(0_0_0/0.2)]"
      />
    );
  }
  if (content.type === "color") {
    return (
      <span
        className="size-[26px] shrink-0 rounded-[6px] shadow-[inset_0_0_0_0.5px_rgb(255_255_255/0.25)]"
        style={{ background: content.hex }}
      />
    );
  }
  const Icon = content.type === "link" ? Link2 : FileText;
  return (
    <span className="flex size-[26px] shrink-0 items-center justify-center rounded-[6px] bg-(--glass-tile) text-(--glass-glyph)">
      <Icon size={13} strokeWidth={2} />
    </span>
  );
}

function Preview({ entry }: { entry: ClipboardEntry }) {
  const { content } = entry;
  if (content.type === "image") {
    return (
      // eslint-disable-next-line @next/next/no-img-element
      <img
        src={content.src}
        alt=""
        decoding="async"
        className="max-h-full max-w-full rounded-[10px] object-contain shadow-[0_0_0_0.5px_rgb(0_0_0/0.2),0_6px_18px_-6px_rgb(0_0_0/0.4)]"
      />
    );
  }
  if (content.type === "color") {
    return (
      <span
        className="size-full rounded-[12px] shadow-[inset_0_0_0_0.5px_rgb(255_255_255/0.25)]"
        style={{ background: content.hex }}
      />
    );
  }
  return (
    <p
      className={cn(
        "line-clamp-4 px-4 text-center text-[15px] leading-snug text-(--glass-fg)",
        content.type === "link" ? "font-medium" : "font-mono text-[13px]",
      )}
    >
      {content.type === "link" ? content.url : content.text}
    </p>
  );
}

function InfoRow({
  label,
  children,
}: {
  label: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex h-[28px] items-center justify-between border-t border-(--glass-hairline) text-demo-row">
      <span className="text-(--glass-fg-muted)">{label}</span>
      <span className="flex items-center gap-1.5 text-(--glass-fg)">
        {children}
      </span>
    </div>
  );
}

/**
 * Clipboard History's screen: entries on the left with a sliding selection, the
 * selected one previewed on the right above its information rows.
 */
export function ClipboardScreen({
  entries,
  selected,
  isFiring,
}: {
  entries: ClipboardEntry[];
  selected: number;
  isFiring: boolean;
}) {
  const entry = entries[selected];
  const { content } = entry ?? {};
  return (
    <div className="relative flex" style={{ height: LIST_HEIGHT }}>
      <div
        className="glass-dissolve relative shrink-0 px-2"
        style={{ width: LIST_WIDTH }}
      >
        <p
          className="flex items-end px-2 pb-1.5 text-demo-section font-semibold text-(--glass-fg-muted)"
          style={{ height: HEADER_HEIGHT }}
        >
          Today
        </p>
        <div className="relative">
          <span
            aria-hidden="true"
            className={cn(
              "demo-highlight absolute inset-x-0 rounded-[10px] bg-(--glass-selection)",
              isFiring && "demo-highlight-fire",
            )}
            style={{
              height: ROW_HEIGHT,
              transform: `translateY(${selected * ROW_HEIGHT}px)`,
              opacity: entry ? 1 : 0,
            }}
          />
          {entries.map((item, index) => (
            <div
              key={`${item.label}-${index}`}
              className="relative flex items-center gap-2.5 px-2"
              style={{ height: ROW_HEIGHT }}
            >
              <Thumbnail entry={item} />
              <span className="min-w-0 truncate text-demo-row font-medium text-(--glass-fg)">
                {item.label}
              </span>
            </div>
          ))}
          {entries.length === 0 && (
            <p className="px-2 pt-4 text-demo-row text-(--glass-fg-muted)">
              No entries
            </p>
          )}
        </div>
      </div>

      <span
        aria-hidden="true"
        className="absolute bottom-16 top-1 w-px bg-(--glass-hairline)"
        style={{ left: LIST_WIDTH }}
      />

      {entry && content && (
        <div key={selected} className="demo-preview min-w-0 flex-1 px-4 pt-1">
          <div
            className="flex items-center justify-center"
            style={{ height: PREVIEW_HEIGHT }}
          >
            <Preview entry={entry} />
          </div>
          <p className="pb-1.5 pt-3 text-demo-section font-semibold text-(--glass-fg-muted)">
            Information
          </p>
          <InfoRow label="Source">
            {/* eslint-disable-next-line @next/next/no-img-element */}
            <img
              src={entry.source.icon}
              alt=""
              width={18}
              height={18}
              className="size-[18px]"
            />
            {entry.source.name}
          </InfoRow>
          <InfoRow label="Type">
            {
              { image: "Image", color: "Color", link: "Link", text: "Text" }[
                content.type
              ]
            }
          </InfoRow>
          {content.type === "image" ? (
            <InfoRow label="Dimensions">{content.dimensions}</InfoRow>
          ) : (
            <InfoRow label="Characters">{entry.label.length}</InfoRow>
          )}
          <InfoRow label="Size">{entry.size}</InfoRow>
          <InfoRow label="Copied">{entry.copied}</InfoRow>
        </div>
      )}
    </div>
  );
}
