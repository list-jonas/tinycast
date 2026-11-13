import { shortcutRows } from "../data/shortcuts";
import { Link } from "./ui/link";
import { Section } from "./ui/section";

export function Keyboard() {
  return (
    <Section
      id="keyboard"
      label="Keyboard"
      title="Built for the keyboard."
      intro="Choose one shortcut to open the palette. Everything else has a key, and shortcuts follow key position, so they work with any keyboard layout."
    >
      <dl className="grid grid-cols-2 gap-4 lg:grid-cols-4">
        {shortcutRows.map((row) => (
          <div
            key={row.does}
            data-spotlight
            className="card group flex flex-col gap-5 p-5"
          >
            <dt className="flex gap-1.5">
              {row.keys.map((key) => (
                <kbd
                  key={key}
                  className="deck-key flex h-11 min-w-11 items-center justify-center rounded-[10px] px-3 text-small font-medium group-hover:translate-y-0.5"
                >
                  {key}
                </kbd>
              ))}
            </dt>
            <dd className="text-small text-fg-muted">{row.does}</dd>
          </div>
        ))}
      </dl>
      <p className="mt-6 text-small text-fg-muted">
        Every other key, one table per screen, is in{" "}
        <Link
          href="/docs/reference/shortcuts"
          className="text-fg underline decoration-border-strong underline-offset-4 transition-colors hover:decoration-violet-bright"
        >
          Keyboard shortcuts
        </Link>
        .
      </p>
    </Section>
  );
}
