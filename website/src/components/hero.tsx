import { ArrowRight, Download } from "lucide-react";
import { brewInstallCommand, hero, site } from "../data/site";
import { latestVersion } from "../lib/version";
import { Badges } from "./badges";
import { HeroStage } from "./hero-stage";
import { Button } from "./ui/button";
import { CommandLine } from "./ui/command-line";
import { Link } from "./ui/link";
import { SwapWords } from "./ui/swap-words";

export async function Hero() {
  const version = await latestVersion();

  return (
    <section id="top" className="relative -mt-16 overflow-hidden">
      {/* The wallpaper's own colour, bled out behind the desktop as a glow. The
          section sits up under the sticky header, so the glow reaches behind it. */}
      <div
        aria-hidden="true"
        className="hero-aura pointer-events-none absolute inset-x-0 top-0 h-[1300px]"
      />

      <div className="relative mx-auto max-w-7xl px-4 pt-28 sm:px-10 sm:pt-36">
        <div className="mx-auto flex max-w-5xl flex-col items-start text-left sm:items-center sm:text-center">
          <Link
            href="/changelog"
            className="blur-in group inline-flex items-center gap-2 rounded-full py-1 pl-1 pr-3 text-caption text-fg-muted shadow-key transition-shadow hover:shadow-key-hover"
          >
            <span className="rounded-full bg-violet px-2 py-0.5 font-medium text-white">
              {version}
            </span>
            <span className="transition-colors group-hover:text-fg">
              See what&rsquo;s new
            </span>
            <ArrowRight
              size={12}
              className="transition-transform group-hover:translate-x-0.5"
            />
          </Link>

          <h1
            className="blur-settle mt-6 text-display sm:mt-8"
            style={{ animationDelay: "60ms" }}
          >
            <span className="sr-only">
              {`${hero.headline.swap[0]} ${hero.headline.rest} ${hero.headline.second}`}
            </span>
            {/* One line from tablet up, and on phones the swapping word gets a
                line of its own, so no swap ever changes the line count. */}
            <span aria-hidden="true" className="block sm:whitespace-nowrap">
              <span className="max-sm:block">
                <SwapWords words={hero.headline.swap} />
              </span>{" "}
              {hero.headline.rest}
            </span>
            <span
              aria-hidden="true"
              className="text-gradient block pb-[0.08em]"
            >
              {hero.headline.second}
            </span>
          </h1>

          <p
            className="blur-in mt-5 max-w-xl text-pretty text-body-lg text-fg-muted sm:mt-6 sm:text-subheading"
            style={{ animationDelay: "120ms" }}
          >
            {hero.sub}
          </p>

          <div
            className="blur-in mt-8 w-full sm:w-fit"
            style={{ animationDelay: "160ms" }}
          >
            <CommandLine command={brewInstallCommand} />
          </div>

          <div
            className="blur-in mt-3 flex w-full flex-col gap-2 sm:mt-5 sm:w-auto sm:flex-row sm:items-center sm:justify-center sm:gap-3"
            style={{ animationDelay: "200ms" }}
          >
            <Button
              href={`${site.repo}/releases/latest`}
              variant="action"
              size="lg"
              className="rounded-lg"
            >
              <Download size={17} />
              Download for Mac
            </Button>
            <Button href="/docs" variant="ghost" size="lg">
              Read the docs
              <ArrowRight size={16} />
            </Button>
          </div>
          <p
            className="blur-in mt-5 text-caption text-fg-subtle sm:mt-6"
            style={{ animationDelay: "240ms" }}
          >
            {site.platform} · Apple silicon &amp; Intel ·{" "}
            {hero.facts.join(" · ")}
          </p>
        </div>

        <div className="stage-rise -mx-4 mt-12 sm:-mx-10 sm:mt-16">
          <HeroStage />
        </div>
        <Badges className="mt-12 justify-center pb-12 sm:mt-16 sm:pb-16" />
      </div>
    </section>
  );
}
