// engslides.js: engineering block-diagram helpers for pptxgenjs.
// One drawing per slide, LAYOUT_WIDE (13.33 x 7.5 in), coordinates in inches.
// Every helper draws the pptx shape and records the same primitive for writeSvg(), which
// writes one SVG per sheet (1 SVG unit = 1 pt). tools/render_svg.ps1 rasterizes the SVGs
// with headless Chrome on hosts without LibreOffice; tools/render.ps1 renders the .pptx.
const fs = require("fs");
const path = require("path");
const pptxgen = require("pptxgenjs");

const FONT = "Arial";
const BLACK = "000000";
// Classification fills. A drawing that uses them defines their meaning in a legend
// on the same sheet (for example white = reuse as-is, gray = modified, yellow = new).
const FILL = { white: "FFFFFF", gray: "E7E6E6", yellow: "FFF2CC", blue: "DDEBF7" };

function newDeck(title, author) {
  const pres = new pptxgen();
  pres.layout = "LAYOUT_WIDE";
  pres.title = title;
  if (author) pres.author = author;
  const add = pres.addSlide.bind(pres);
  pres._sheets = [];
  pres.addSlide = (...a) => {
    const s = add(...a);
    s._svg = [];
    pres._sheets.push(s);
    return s;
  };
  return pres;
}

function helpers(pres) {
  // Block: bold title line plus optional detail lines, black outline.
  function box(s, x, y, w, h, title, lines = [], fill = FILL.white) {
    const runs = [{ text: title, options: { bold: true, fontSize: 9.5, breakLine: lines.length > 0 } }];
    lines.forEach((t, i) => runs.push({ text: t, options: { fontSize: 8, breakLine: i < lines.length - 1 } }));
    s.addText(runs, {
      shape: pres.shapes.RECTANGLE, x, y, w, h,
      fill: { color: fill }, line: { color: BLACK, width: 0.75 },
      fontFace: FONT, color: BLACK, align: "center", valign: "middle",
      margin: 2, objectName: title,
    });
    s._svg.push({ k: "box", x, y, w, h, title, lines, fill });
  }

  // Boundary (chip, board, software layer): dashed outline, label top-left inside.
  function container(s, x, y, w, h, label) {
    s.addShape(pres.shapes.RECTANGLE, {
      x, y, w, h, fill: { type: "none" },
      line: { color: BLACK, width: 0.75, dashType: "dash" },
    });
    s.addText(label, {
      x: x + 0.08, y: y + 0.04, w: 4, h: 0.22, isTextBox: true,
      fontFace: FONT, fontSize: 9, bold: true, color: BLACK, margin: 0, valign: "top",
    });
    s._svg.push({ k: "container", x, y, w, h, label });
  }

  // Straight horizontal or vertical connector from (x1,y1) to (x2,y2).
  // end: arrowhead at (x2,y2); start: arrowhead at (x1,y1); dash: "dash" for control/config paths.
  // Route an L-shaped path as two wire() calls.
  function wire(s, x1, y1, x2, y2, { start = false, end = true, dash } = {}) {
    const opts = {
      x: Math.min(x1, x2), y: Math.min(y1, y2),
      w: Math.abs(x2 - x1), h: Math.abs(y2 - y1),
      line: { color: BLACK, width: 0.75 },
    };
    if (dash) opts.line.dashType = dash;
    if (start) opts.line.beginArrowType = "triangle";
    if (end) opts.line.endArrowType = "triangle";
    if (x2 < x1) opts.flipH = true;
    if (y2 < y1) opts.flipV = true;
    s.addShape(pres.shapes.LINE, opts);
    s._svg.push({ k: "wire", x1, y1, x2, y2, start, end, dash });
  }

  // Signal or connector label; place it 0.2 in above a horizontal wire.
  function label(s, x, y, w, text, size = 7.5, align = "left") {
    s.addText(text, {
      x, y, w, h: 0.18, isTextBox: true, fontFace: FONT, fontSize: size,
      color: BLACK, margin: 0, align, valign: "bottom",
    });
    s._svg.push({ k: "label", x, y, w, text, size, align });
  }

  // Numbered notes block.
  function notes(s, x, y, w, h, items) {
    const runs = [{ text: "NOTES:", options: { bold: true, breakLine: true } }];
    items.forEach((t, i) => runs.push({ text: `${i + 1}. ${t}`, options: { breakLine: i < items.length - 1 } }));
    s.addText(runs, {
      x, y, w, h, isTextBox: true, fontFace: FONT, fontSize: 7.5, color: BLACK,
      margin: 0, valign: "top", paraSpaceAfter: 2,
    });
    s._svg.push({ k: "notes", x, y, w, h, items });
  }

  // Legend row for classification fills: items = [["Reuse as-is", FILL.white], ...]
  function legend(s, x, y, items, step = 2.3) {
    items.forEach(([t, f], i) => {
      const lx = x + i * step;
      s.addShape(pres.shapes.RECTANGLE, { x: lx, y, w: 0.3, h: 0.18, fill: { color: f }, line: { color: BLACK, width: 0.75 } });
      s._svg.push({ k: "swatch", x: lx, y, fill: f });
      label(s, lx + 0.38, y, step - 0.4, t, 8);
    });
  }

  // Sheet border. Keep drawing content inside x 0.6 to 12.75 in and y 0.4 to 7.1 in.
  function frame(s) {
    s.addShape(pres.shapes.RECTANGLE, {
      x: 0.25, y: 0.25, w: 12.83, h: 7.0, fill: { type: "none" },
      line: { color: BLACK, width: 1.5 },
    });
    s._svg.push({ k: "frame" });
  }

  return { box, container, wire, label, notes, legend, frame };
}

// ---- SVG output: one file per sheet, <dir>/<name>-<n>.svg, 960 x 540 pt ----
const P = 72; // points per inch
const esc = (t) => String(t).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
const r = (v) => Math.round(v * P * 100) / 100;

function html(x, y, w, h, inner, style) {
  return `<foreignObject x="${r(x)}" y="${r(y)}" width="${r(w)}" height="${r(h)}">` +
    `<div xmlns="http://www.w3.org/1999/xhtml" style="width:100%;height:100%;box-sizing:border-box;` +
    `font-family:Arial,Helvetica,sans-serif;color:#000;${style}">${inner}</div></foreignObject>`;
}

function sheetSvg(items) {
  const out = [];
  out.push(`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 960 540" width="960" height="540">`);
  out.push(`<defs><marker id="ah" viewBox="0 0 10 10" refX="10" refY="5" markerUnits="userSpaceOnUse" ` +
    `markerWidth="6" markerHeight="5" orient="auto-start-reverse"><path d="M0,0 L10,5 L0,10 z" fill="#000"/></marker></defs>`);
  out.push(`<rect x="0" y="0" width="960" height="540" fill="#fff"/>`);
  for (const it of items) {
    switch (it.k) {
      case "box": {
        out.push(`<rect x="${r(it.x)}" y="${r(it.y)}" width="${r(it.w)}" height="${r(it.h)}" fill="#${it.fill}" stroke="#000" stroke-width="0.75"/>`);
        const inner = `<div style="font-weight:bold;font-size:9.5px">${esc(it.title)}</div>` +
          it.lines.map((t) => `<div style="font-size:8px">${esc(t)}</div>`).join("");
        out.push(html(it.x, it.y, it.w, it.h, inner,
          "display:flex;flex-direction:column;justify-content:center;align-items:center;text-align:center;padding:2px;line-height:1.2"));
        break;
      }
      case "container":
        out.push(`<rect x="${r(it.x)}" y="${r(it.y)}" width="${r(it.w)}" height="${r(it.h)}" fill="none" stroke="#000" stroke-width="0.75" stroke-dasharray="4 3"/>`);
        out.push(html(it.x + 0.08, it.y + 0.04, 6, 0.22, esc(it.label), "font-size:9px;font-weight:bold;white-space:nowrap"));
        break;
      case "wire": {
        const m = (it.start ? ` marker-start="url(#ah)"` : "") + (it.end ? ` marker-end="url(#ah)"` : "");
        const d = it.dash ? ` stroke-dasharray="4 3"` : "";
        out.push(`<line x1="${r(it.x1)}" y1="${r(it.y1)}" x2="${r(it.x2)}" y2="${r(it.y2)}" stroke="#000" stroke-width="0.75"${d}${m}/>`);
        break;
      }
      case "label":
        out.push(html(it.x, it.y, it.w, 0.18, esc(it.text),
          `font-size:${it.size}px;display:flex;align-items:flex-end;justify-content:${it.align === "center" ? "center" : it.align === "right" ? "flex-end" : "flex-start"};white-space:nowrap`));
        break;
      case "notes": {
        const inner = `<div style="font-weight:bold">NOTES:</div>` +
          it.items.map((t, i) => `<div style="margin-bottom:2px">${i + 1}. ${esc(t)}</div>`).join("");
        out.push(html(it.x, it.y, it.w, it.h, inner, "font-size:7.5px;line-height:1.2"));
        break;
      }
      case "swatch":
        out.push(`<rect x="${r(it.x)}" y="${r(it.y)}" width="${r(0.3)}" height="${r(0.18)}" fill="#${it.fill}" stroke="#000" stroke-width="0.75"/>`);
        break;
      case "frame":
        out.push(`<rect x="${r(0.25)}" y="${r(0.25)}" width="${r(12.83)}" height="${r(7.0)}" fill="none" stroke="#000" stroke-width="1.5"/>`);
        break;
    }
  }
  out.push(`</svg>`);
  return out.join("\n");
}

function writeSvg(pres, dir, name) {
  fs.mkdirSync(dir, { recursive: true });
  return pres._sheets.map((s, i) => {
    const f = path.join(dir, `${name}-${i + 1}.svg`);
    fs.writeFileSync(f, sheetSvg(s._svg) + "\n");
    return f;
  });
}

module.exports = { newDeck, helpers, writeSvg, FILL, FONT, BLACK };
