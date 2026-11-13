import { site } from "../data/site";
import { supportHero } from "../data/support";
import { reveal } from "../lib/reveal";
import { Button } from "./ui/button";
import { GitHubLogo, SupportIcon } from "./ui/icon";
import { RevealWords } from "./ui/reveal-words";

// The bolt from the app icon, alone on a violet glow, so the page ends on the
// brand. Same thunder shape and the same deep-to-light violet as tinycast.icon.
function GlowingBolt() {
  return (
    <span className="relative mx-auto flex size-32 items-center justify-center sm:size-36">
      <span
        aria-hidden="true"
        className="mark-bloom pointer-events-none absolute -inset-32"
      />
      <svg
        viewBox="4.6 1.7 14.8 20.6"
        className="relative h-full w-auto drop-shadow-[0_14px_28px_rgb(110_40_255/0.45)]"
        aria-hidden="true"
      >
        <defs>
          <linearGradient id="support-bolt" x1="0" y1="0" x2="0.35" y2="1">
            <stop offset="0" stopColor="#7a35ff" />
            <stop offset="0.55" stopColor="#9a62ff" />
            <stop offset="1" stopColor="#c4a3ff" />
          </linearGradient>
        </defs>
        <path
          fill="url(#support-bolt) #863bff"
          d="M18.82 9.18A2 2 0 0 0 17 8h-1.81l1.33-3.26a2 2 0 0 0-.19-1.84 2.06 2.06 0 0 0-1.71-.9h-4.34a2 2 0 0 0-1.91 1.27l-3.23 8a2 2 0 0 0 .2 1.83 2.06 2.06 0 0 0 1.71.9h2.76L8 20.74a1 1 0 0 0 .5 1.15A1.1 1.1 0 0 0 9 22a1 1 0 0 0 .76-.35l8.8-10.37a2 2 0 0 0 .26-2.1"
        />
      </svg>
    </span>
  );
}

export function Support() {
  return (
    <section
      id="support"
      className="overflow-hidden px-4 pb-32 pt-28 text-center sm:px-10"
    >
      <div aria-hidden="true" {...reveal("content")}>
        <GlowingBolt />
      </div>
      <h2
        className="mx-auto mt-14 max-w-2xl text-closing"
        {...reveal("words", 1)}
      >
        <RevealWords text={supportHero.title} />
      </h2>
      <p
        className="mx-auto mt-4 max-w-lg text-pretty text-body-lg text-fg-muted"
        {...reveal("text", 2)}
      >
        {supportHero.intro}
      </p>
      <div
        className="mt-8 flex flex-wrap justify-center gap-3"
        {...reveal("content", 3)}
      >
        <Button href={site.support} size="lg">
          <SupportIcon size={18} />
          Support Tinycast
        </Button>
        <Button href={site.repo} variant="ghost" size="lg">
          <GitHubLogo size={16} />
          Star on GitHub
        </Button>
      </div>
    </section>
  );
}
