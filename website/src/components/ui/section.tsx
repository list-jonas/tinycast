import type { ReactNode } from "react";
import { reveal } from "../../lib/reveal";
import { RevealWords } from "./reveal-words";

type SectionProps = {
  id: string;
  label: string;
  title: string;
  intro?: ReactNode;
  children: ReactNode;
};

export function Section({ id, label, title, intro, children }: SectionProps) {
  return (
    <section id={id} className="relative">
      <div className="px-4 py-20 sm:px-10 sm:py-28">
        <div className="max-w-2xl">
          <p className="text-small font-medium text-accent" {...reveal("text")}>
            {label}
          </p>
          <h2 className="mt-3 text-heading" {...reveal("words", 1)}>
            <RevealWords text={title} />
          </h2>
          {intro && (
            <p
              className="mt-5 max-w-xl text-pretty text-body-lg text-fg-muted"
              {...reveal("text", 2)}
            >
              {intro}
            </p>
          )}
        </div>
        <div className="mt-14" {...reveal("content", 3)}>
          {children}
        </div>
      </div>
    </section>
  );
}
