import { ArrowUpRight } from "lucide-react";
import { coreFeatures, moreFeatures, type Feature } from "../data/features";
import { cn } from "../lib/cn";
import { FeaturePreviewArt } from "./feature-previews";
import { Button } from "./ui/button";
import { featureIcons } from "./ui/feature-icons";
import { Link } from "./ui/link";
import { Section } from "./ui/section";

function FeatureCard({ title, body, href, preview, isWide }: Feature) {
  return (
    <Link
      href={href}
      data-spotlight
      className={cn(
        "card group flex min-w-0 flex-col p-2",
        isWide && "sm:col-span-2",
      )}
    >
      {/* Decorative: the title and body below say the same thing in words. */}
      <div
        aria-hidden="true"
        className="card-well h-48 overflow-hidden rounded-[18px] p-4 transition-transform duration-500 ease-(--ease-settle) group-hover:scale-[1.012]"
      >
        <FeaturePreviewArt preview={preview} />
      </div>
      <div className="px-3 pb-3 pt-5">
        <h3 className="flex items-center gap-1 text-body font-semibold tracking-[-0.01em] text-fg">
          {title}
          <ArrowUpRight
            size={15}
            aria-hidden="true"
            className="-translate-x-1 text-fg-subtle opacity-0 transition-all duration-300 group-hover:translate-x-0 group-hover:opacity-100"
          />
        </h3>
        <p className="mt-1.5 text-small text-fg-muted">{body}</p>
      </div>
    </Link>
  );
}

export function Features() {
  return (
    <Section
      id="features"
      label="Features"
      title="One palette for the things you do all day."
      intro="Most features are off until you turn them on, so Tinycast only runs what you use."
    >
      <div className="grid grid-cols-[minmax(0,1fr)] gap-4 sm:grid-cols-2 lg:grid-cols-4">
        {coreFeatures.map((feature) => (
          <FeatureCard key={feature.title} {...feature} />
        ))}
      </div>

      <div className="card mt-4 p-5 sm:p-7" data-spotlight>
        <div className="flex flex-wrap items-center justify-between gap-4">
          <h3 className="text-body font-medium text-fg">Also included</h3>
          <Button href="/docs" variant="outline">
            Browse the docs
          </Button>
        </div>
        <ul className="mt-4 flex flex-wrap gap-2">
          {moreFeatures.map(({ icon, title, href }) => {
            const Icon = featureIcons[icon];
            return (
              <li key={title}>
                <Link
                  href={href}
                  className="inline-flex items-center gap-1.5 rounded-full px-3 py-1.5 text-small text-fg-muted shadow-key transition-[color,box-shadow] hover:text-fg hover:shadow-key-hover"
                >
                  <Icon
                    size={13}
                    strokeWidth={2}
                    className="text-violet-bright"
                    aria-hidden="true"
                  />
                  {title}
                </Link>
              </li>
            );
          })}
        </ul>
      </div>
    </Section>
  );
}
