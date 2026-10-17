// Draws a ```circuit block (see Circuit.swift for the format) as an SVG schematic.
// Every two-terminal part is drawn along the x axis between -HALF and +HALF, then rotated
// and moved onto its grid segment, so each symbol is written once regardless of direction.

const GRID = 56;
const HALF = 18;
const PADDING = 24;
// Rough width of one character of 12 px label text, for sizing the drawing before it is on screen.
const CHARACTER_WIDTH = 6.8;
const LABEL_GAP = 26;
const SVG_NS = "http://www.w3.org/2000/svg";

// Symbol bodies, drawn from (-HALF, 0) to (HALF, 0). Lead-in wires are added around them.
const SYMBOLS = {
  resistor: () => path("M -18 0 L -15 -6 L -9 6 L -3 -6 L 3 6 L 9 -6 L 15 6 L 18 0"),
  capacitor: () => group(line(-18, 0, -3, 0), line(-3, -11, -3, 11), line(3, -11, 3, 11), line(3, 0, 18, 0)),
  inductor: () => path("M -18 0 a 4.5 4.5 0 0 1 9 0 a 4.5 4.5 0 0 1 9 0 a 4.5 4.5 0 0 1 9 0 a 4.5 4.5 0 0 1 9 0"),
  // The long plate is the + side, which is the `to` end.
  battery: () => group(line(-18, 0, -3, 0), line(-3, -6, -3, 6, 3), line(3, -12, 3, 12), line(3, 0, 18, 0), text(10, -14, "+")),
  voltage_source: () => group(line(-18, 0, -12, 0), circle(12), line(12, 0, 18, 0), text(5, 4, "+"), text(-8, 4, "−")),
  current_source: () => group(line(-18, 0, -12, 0), circle(12), line(-6, 0, 6, 0), path("M 2 -4 L 7 0 L 2 4"), line(12, 0, 18, 0)),
  diode: () => group(line(-18, 0, -7, 0), path("M -7 -8 L 7 0 L -7 8 Z", true), line(7, -8, 7, 8), line(7, 0, 18, 0)),
  switch: () => group(line(-18, 0, -9, 0), dot(-9, 0), line(-9, 0, 8, -10), dot(9, 0), line(9, 0, 18, 0)),
};

function renderCircuit(circuit) {
  if (!circuit || !Array.isArray(circuit.parts)) throw new Error("A circuit needs a parts list.");

  const points = circuit.parts.flatMap((part) => [part.from, part.to, part.at].filter(Boolean));
  const xs = points.map((point) => point[0]);
  const ys = points.map((point) => point[1]);
  const place = ([x, y]) => [x * GRID, y * GRID];
  const bounds = labelBounds(circuit.parts, place, {
    left: Math.min(...xs) * GRID, right: Math.max(...xs) * GRID,
    top: Math.min(...ys) * GRID, bottom: Math.max(...ys) * GRID,
  });
  const width = bounds.right - bounds.left + PADDING * 2;
  const height = bounds.bottom - bounds.top + PADDING * 2;

  const svg = document.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", `${bounds.left - PADDING} ${bounds.top - PADDING} ${width} ${height}`);
  svg.setAttribute("width", width);
  svg.setAttribute("height", height);
  svg.setAttribute("class", "schematic");
  svg.setAttribute("role", "img");
  svg.setAttribute("aria-label", circuit.title || "Circuit");

  for (const part of circuit.parts) {
    if (part.type === "ground" && part.at) {
      svg.appendChild(ground(place(part.at)));
    } else if (part.from && part.to) {
      svg.appendChild(twoTerminal(part, place(part.from), place(part.to)));
    }
  }
  for (const point of junctions(circuit.parts)) {
    svg.appendChild(dot(...place(point), 2.6));
  }
  for (const node of circuit.nodes || []) {
    const [x, y] = place(node.at);
    svg.appendChild(text(x + 6, y - 7, node.text, "node-label"));
  }
  return svg;
}

function twoTerminal(part, [x1, y1], [x2, y2]) {
  const length = Math.hypot(x2 - x1, y2 - y1);
  const angle = Math.atan2(y2 - y1, x2 - x1) * 180 / Math.PI;
  const midX = (x1 + x2) / 2, midY = (y1 + y2) / 2;
  const drawn = group();

  if (part.type === "wire" || !SYMBOLS[part.type]) {
    drawn.appendChild(line(x1, y1, x2, y2));
    return drawn;
  }

  const body = group(line(-length / 2, 0, -HALF, 0), SYMBOLS[part.type](), line(HALF, 0, length / 2, 0));
  body.setAttribute("transform", `translate(${midX} ${midY}) rotate(${angle})`);
  // Symbol text such as + and − stays upright whichever way the part points.
  for (const label of body.querySelectorAll("text")) {
    const [lx, ly] = [Number(label.getAttribute("x")), Number(label.getAttribute("y"))];
    label.setAttribute("transform", `rotate(${-angle} ${lx} ${ly})`);
  }
  drawn.appendChild(body);
  drawn.appendChild(partLabel(part, midX, midY, Math.abs(y2 - y1) > Math.abs(x2 - x1)));
  return drawn;
}

function labelLines(part) {
  return [[part.name, part.value].filter(Boolean).join(" "), part.note].filter(Boolean);
}

// Grows the wiring's bounds to take in every label, so none is cut off at the edge.
function labelBounds(parts, place, bounds) {
  for (const part of parts) {
    if (!part.from || !part.to || part.type === "wire") continue;
    const [x1, y1] = place(part.from), [x2, y2] = place(part.to);
    const lines = labelLines(part);
    const textWidth = Math.max(0, ...lines.map((content) => content.length * CHARACTER_WIDTH));
    const x = (x1 + x2) / 2, y = (y1 + y2) / 2;
    if (Math.abs(y2 - y1) > Math.abs(x2 - x1)) {
      bounds.right = Math.max(bounds.right, x + 20 + textWidth);
    } else {
      bounds.left = Math.min(bounds.left, x - textWidth / 2);
      bounds.right = Math.max(bounds.right, x + textWidth / 2);
      bounds.top = Math.min(bounds.top, y - LABEL_GAP - lines.length * 14);
    }
  }
  return bounds;
}

// Labels sit above horizontal parts and to the right of vertical ones, never rotated.
function partLabel(part, x, y, isVertical) {
  const lines = labelLines(part);
  const label = document.createElementNS(SVG_NS, "text");
  label.setAttribute("class", "part-label");
  label.setAttribute("text-anchor", isVertical ? "start" : "middle");
  lines.forEach((content, index) => {
    const span = document.createElementNS(SVG_NS, "tspan");
    span.setAttribute("x", isVertical ? x + 20 : x);
    span.setAttribute("y", isVertical ? y - 4 + index * 14 - (lines.length - 1) * 7 : y - LABEL_GAP - (lines.length - 1 - index) * 14);
    span.textContent = content;
    label.appendChild(span);
  });
  return label;
}

function ground([x, y]) {
  return group(line(x, y, x, y + 10), line(x - 11, y + 10, x + 11, y + 10), line(x - 7, y + 14, x + 7, y + 14), line(x - 3, y + 18, x + 3, y + 18));
}

// A dot wherever three or more terminals meet, as on a hand-drawn schematic.
function junctions(parts) {
  const counts = new Map();
  for (const part of parts) {
    for (const point of [part.from, part.to]) {
      if (!point) continue;
      const key = point.join(",");
      counts.set(key, (counts.get(key) || 0) + 1);
    }
  }
  return [...counts].filter(([, count]) => count >= 3).map(([key]) => key.split(",").map(Number));
}

// * ====================================================================
// * === svg helpers
// * ====================================================================

function group(...children) {
  const element = document.createElementNS(SVG_NS, "g");
  children.forEach((child) => element.appendChild(child));
  return element;
}

function line(x1, y1, x2, y2, strokeWidth) {
  const element = document.createElementNS(SVG_NS, "line");
  Object.entries({ x1, y1, x2, y2 }).forEach(([name, value]) => element.setAttribute(name, value));
  if (strokeWidth) element.setAttribute("stroke-width", strokeWidth);
  return element;
}

function path(d, filled) {
  const element = document.createElementNS(SVG_NS, "path");
  element.setAttribute("d", d);
  if (filled) element.setAttribute("class", "filled");
  return element;
}

function circle(radius) {
  const element = document.createElementNS(SVG_NS, "circle");
  element.setAttribute("r", radius);
  return element;
}

function dot(x, y, radius = 1.8) {
  const element = document.createElementNS(SVG_NS, "circle");
  Object.entries({ cx: x, cy: y, r: radius, class: "filled" }).forEach(([name, value]) => element.setAttribute(name, value));
  return element;
}

function text(x, y, content, className = "symbol-label") {
  const element = document.createElementNS(SVG_NS, "text");
  Object.entries({ x, y, class: className, "text-anchor": "middle" }).forEach(([name, value]) => element.setAttribute(name, value));
  element.textContent = content;
  return element;
}
