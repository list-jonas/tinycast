// The hero palette's calculator: arithmetic and a handful of unit conversions,
// parsed by hand so nothing a visitor types is ever evaluated as code.

type Unit = { name: string; dimension: string; factor: number };

const units: Record<string, Unit> = {
  mm: { name: "Millimeters", dimension: "length", factor: 0.001 },
  cm: { name: "Centimeters", dimension: "length", factor: 0.01 },
  m: { name: "Meters", dimension: "length", factor: 1 },
  km: { name: "Kilometers", dimension: "length", factor: 1000 },
  in: { name: "Inches", dimension: "length", factor: 0.0254 },
  ft: { name: "Feet", dimension: "length", factor: 0.3048 },
  mi: { name: "Miles", dimension: "length", factor: 1609.344 },
  g: { name: "Grams", dimension: "mass", factor: 1 },
  kg: { name: "Kilograms", dimension: "mass", factor: 1000 },
  lb: { name: "Pounds", dimension: "mass", factor: 453.59237 },
  oz: { name: "Ounces", dimension: "mass", factor: 28.349523 },
  s: { name: "Seconds", dimension: "time", factor: 1 },
  min: { name: "Minutes", dimension: "time", factor: 60 },
  h: { name: "Hours", dimension: "time", factor: 3600 },
  d: { name: "Days", dimension: "time", factor: 86400 },
  kb: { name: "Kilobytes", dimension: "data", factor: 1e3 },
  mb: { name: "Megabytes", dimension: "data", factor: 1e6 },
  gb: { name: "Gigabytes", dimension: "data", factor: 1e9 },
};

export type Answer = {
  input: string;
  inputLabel: string;
  result: string;
  resultLabel: string;
};

const format = (value: number) =>
  Number.isInteger(value)
    ? value.toLocaleString("en-US")
    : value.toLocaleString("en-US", { maximumFractionDigits: 3 });

// Recursive descent over + - * / ^ and parentheses. Returns null on anything else.
function evaluate(source: string): number | null {
  const text = source.replace(/\s+/g, "").replace(/×/g, "*").replace(/÷/g, "/");
  let position = 0;

  const peek = () => text[position];
  const number = (): number | null => {
    const match = /^\d*\.?\d+/.exec(text.slice(position));
    if (!match) return null;
    position += match[0].length;
    return Number(match[0]);
  };
  const atom = (): number | null => {
    if (peek() === "-") {
      position++;
      const value = atom();
      return value === null ? null : -value;
    }
    if (peek() === "(") {
      position++;
      const value = sum();
      if (peek() !== ")") return null;
      position++;
      return value;
    }
    return number();
  };
  const power = (): number | null => {
    const base = atom();
    if (base === null || peek() !== "^") return base;
    position++;
    const exponent = power();
    return exponent === null ? null : base ** exponent;
  };
  const product = (): number | null => {
    let value = power();
    while (value !== null && (peek() === "*" || peek() === "/")) {
      const operator = text[position++];
      const right = power();
      if (right === null) return null;
      value = operator === "*" ? value * right : value / right;
    }
    return value;
  };
  const sum = (): number | null => {
    let value = product();
    while (value !== null && (peek() === "+" || peek() === "-")) {
      const operator = text[position++];
      const right = product();
      if (right === null) return null;
      value = operator === "+" ? value + right : value - right;
    }
    return value;
  };

  const value = sum();
  return value !== null && position === text.length && Number.isFinite(value)
    ? value
    : null;
}

const cities: Record<string, { name: string; zone: string }> = {
  nyc: { name: "New York", zone: "America/New_York" },
  "new york": { name: "New York", zone: "America/New_York" },
  sf: { name: "San Francisco", zone: "America/Los_Angeles" },
  "san francisco": { name: "San Francisco", zone: "America/Los_Angeles" },
  london: { name: "London", zone: "Europe/London" },
  berlin: { name: "Berlin", zone: "Europe/Berlin" },
  paris: { name: "Paris", zone: "Europe/Paris" },
  tokyo: { name: "Tokyo", zone: "Asia/Tokyo" },
  sydney: { name: "Sydney", zone: "Australia/Sydney" },
};

const clock = (date: Date, zone?: string) =>
  date.toLocaleTimeString("en-GB", {
    hour: "2-digit",
    minute: "2-digit",
    timeZone: zone,
  });

// The visitor's own city, read off their zone the way the app names it.
const localCity = () =>
  Intl.DateTimeFormat()
    .resolvedOptions()
    .timeZone.split("/")
    .pop()
    ?.replaceAll("_", " ") ?? "Local";

// The app's typographic operators: ÷ × and a true minus.
const typeset = (text: string) =>
  text
    .trim()
    .replace(/\//g, "÷")
    .replace(/\*/g, "×")
    .replace(/(?<=[\d)\s])-/g, "−");

export function calculate(query: string, now = new Date()): Answer | null {
  const time = /^\s*time\s+in\s+([a-z ]+?)\s*(?:\+\s*(\d+)\s*h)?\s*$/i.exec(
    query,
  );
  if (time) {
    const city = cities[time[1].toLowerCase()];
    if (!city) return null;
    const at = new Date(now.getTime() + Number(time[2] ?? 0) * 3_600_000);
    return {
      input: clock(at),
      inputLabel: localCity(),
      result: clock(at, city.zone),
      resultLabel: city.name,
    };
  }
  const conversion =
    /^\s*(\d*\.?\d+)\s*([a-z]+)\s+(?:in|to)\s+([a-z]+)\s*$/i.exec(query);
  if (conversion) {
    const [, amount, fromKey, toKey] = conversion;
    const from = units[fromKey.toLowerCase()];
    const to = units[toKey.toLowerCase()];
    if (!from || !to || from.dimension !== to.dimension) return null;
    const value = (Number(amount) * from.factor) / to.factor;
    return {
      input: typeset(query),
      inputLabel: "Expression",
      result: `${format(value)} ${toKey.toLowerCase()}`,
      resultLabel: to.name,
    };
  }
  // A bare number is a search, not a sum.
  if (!/[+\-*/^×÷]/.test(query)) return null;
  const value = evaluate(query);
  if (value === null) return null;
  return {
    input: typeset(query),
    inputLabel: "Expression",
    result: format(value),
    resultLabel: "Result",
  };
}
