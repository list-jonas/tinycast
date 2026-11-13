import { BookOpen, Star } from "lucide-react";
import { nav, site } from "../data/site";
import { starCount } from "../lib/version";
import { DiscordLogo, GitHubLogo, Logo, SupportIcon } from "./ui/icon";
import { LiquidGlass } from "./ui/liquid-glass";
import { Link } from "./ui/link";
import { ThemeSwitch } from "./ui/theme-toggle";

const iconButtonClass =
  "flex size-8 items-center justify-center rounded-full text-fg-muted transition-colors hover:bg-tint/5 hover:text-fg";

// A floating pill of glass that the page scrolls under. Phones get icons
// instead of a menu: the section links are a scroll away, and a drawer is one
// more thing to open.
export async function Nav() {
  const stars = await starCount();

  return (
    <>
      {/* The first stop for a keyboard: straight past the nav to the page. */}
      <a href="#main" className="skip-link">
        Skip to content
      </a>
      <header className="pointer-events-none sticky top-0 z-50 px-3 pt-3 sm:px-6">
        <LiquidGlass
          radius={26}
          bezel={14}
          refraction={22}
          blur={10}
          className="nav-glass pointer-events-auto mx-auto h-[52px] max-w-5xl"
        >
          <div className="flex h-full items-center gap-6 pl-4 pr-2">
            <Link href="/" className="flex items-center gap-2">
              <Logo size={24} />
              <span className="text-body font-semibold tracking-[-0.02em] text-fg">
                {site.name}
              </span>
            </Link>

            <nav
              aria-label="Sections"
              className="hidden items-center gap-5 md:flex"
            >
              {nav.map((item) => (
                <Link
                  key={item.label}
                  href={item.href}
                  className="text-small text-fg-muted transition-colors hover:text-fg"
                >
                  {item.label}
                </Link>
              ))}
            </nav>

            <div className="ml-auto flex items-center gap-1">
              <Link
                href={site.support}
                aria-label="Support Tinycast"
                title="Support Tinycast"
                className="flex h-8 items-center gap-1.5 rounded-full px-2 text-small text-fg-muted transition-colors hover:bg-tint/5 hover:text-fg sm:px-2.5"
              >
                <SupportIcon size={17} className="text-violet-bright" />
                <span className="hidden sm:inline">Support</span>
              </Link>
              <Link
                href="/docs"
                aria-label="Documentation"
                className={`${iconButtonClass} md:hidden`}
              >
                <BookOpen size={16} />
              </Link>
              <a
                href={site.repo}
                target="_blank"
                rel="noreferrer"
                aria-label={
                  stars ? `${stars} stars on GitHub` : "View source on GitHub"
                }
                title="View source on GitHub"
                className={
                  stars
                    ? "flex h-8 items-center gap-1.5 rounded-full px-2.5 text-fg-muted transition-colors hover:bg-tint/5 hover:text-fg"
                    : iconButtonClass
                }
              >
                <GitHubLogo size={16} />
                {stars && (
                  <span className="inline-flex items-center gap-1 font-mono text-caption max-[420px]:hidden">
                    <Star size={12} aria-hidden="true" />
                    {stars}
                  </span>
                )}
              </a>
              <a
                href={site.community.discord}
                target="_blank"
                rel="noreferrer"
                aria-label="Join the Discord"
                title="Join the Discord"
                className={`${iconButtonClass} max-sm:hidden`}
              >
                <DiscordLogo size={16} />
              </a>
              <ThemeSwitch />
            </div>
          </div>
        </LiquidGlass>
      </header>
    </>
  );
}
