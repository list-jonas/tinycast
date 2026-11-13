"use client";

import NextLink from "next/link";
import { useState, type ComponentProps } from "react";

type Props = Omit<ComponentProps<typeof NextLink>, "href"> & { href: string };

/**
 * Internal links, including in-page anchors. External URLs fall through to a
 * plain anchor with the usual rel guard.
 *
 * Internal routes prefetch on intent (hover, focus or touch) rather than on
 * sight: the nav is always on screen, and prefetching on sight pulled the docs
 * and checkout bundles into every visit to the marketing page.
 */
export function Link({
  href,
  onMouseEnter,
  onFocus,
  onTouchStart,
  ...props
}: Props) {
  const [isIntended, setIsIntended] = useState(false);

  if (/^(https?:|mailto:|#)/.test(href)) {
    const external = href.startsWith("http");
    return (
      <a
        href={href}
        {...(external ? { target: "_blank", rel: "noreferrer" } : {})}
        onMouseEnter={onMouseEnter}
        onFocus={onFocus}
        onTouchStart={onTouchStart}
        {...props}
      />
    );
  }

  return (
    <NextLink
      href={href}
      prefetch={isIntended ? null : false}
      onMouseEnter={(event) => {
        setIsIntended(true);
        onMouseEnter?.(event);
      }}
      onFocus={(event) => {
        setIsIntended(true);
        onFocus?.(event);
      }}
      onTouchStart={(event) => {
        setIsIntended(true);
        onTouchStart?.(event);
      }}
      {...props}
    />
  );
}
