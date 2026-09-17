/** @jsxRuntime automatic */
/** @jsxImportSource @oai/artifact-tool/presentation-jsx */

import fs from "node:fs/promises";
import path from "node:path";
import {
  Presentation,
  PresentationFile,
  row,
  column,
  grid,
  layers,
  panel as rawPanel,
  text,
  image,
  shape as rawShape,
  rule,
  fill,
  hug,
  fixed,
  wrap,
  grow,
  fr,
  auto,
} from "@oai/artifact-tool";
import { paint, stroke } from "@oai/artifact-tool/presentation-jsx";

const OUT = "output/output.pptx";
const ASSET = "scratch/assets/mu2edaq-notify-architecture";
const RENDER = "scratch/render";
const PPTX_RENDER = "scratch/pptx-render";
const LAYOUT = "scratch/layout";

async function loadPngDataUrl(name) {
  const bytes = await fs.readFile(path.join(ASSET, name));
  return `data:image/png;base64,${bytes.toString("base64")}`;
}

const IMG = {
  cover: await loadPngDataUrl("system-cover.png"),
  apns: await loadPngDataUrl("apns-loop.png"),
  appIcon: await loadPngDataUrl("app-icon.png"),
};

const C = {
  canvas: "#F4F7F8",
  white: "#FFFFFF",
  ink: "#102632",
  navy: "#0B1F2B",
  muted: "#526D7A",
  pale: "#E7EFF2",
  line: "#C7D6DC",
  cyan: "#00B8E6",
  cyanDark: "#007FA7",
  cyanPale: "#D9F7FC",
  teal: "#12A6A6",
  orange: "#FF8A1F",
  orangePale: "#FFF1E1",
  bluePale: "#EAF0FF",
  blue: "#486BE8",
  green: "#248B68",
  greenPale: "#E3F5ED",
  red: "#D84B40",
  redPale: "#FBE9E7",
  purple: "#7548B7",
};

const FONT = {
  display: "Futura",
  body: "Gill Sans",
  mono: "Menlo",
};

const style = {
  coverTitle: { fontFamily: FONT.display, fontSize: 72, bold: true, color: C.ink, lineSpacing: 0.95 },
  coverPromise: { fontFamily: FONT.body, fontSize: 28, color: C.muted, lineSpacing: 1.12 },
  title: { fontFamily: FONT.display, fontSize: 48, bold: true, color: C.ink },
  subtitle: { fontFamily: FONT.body, fontSize: 25, color: C.muted },
  body: { fontFamily: FONT.body, fontSize: 24, color: C.ink, lineSpacing: 1.18 },
  small: { fontFamily: FONT.body, fontSize: 18, color: C.muted, lineSpacing: 1.12 },
  label: { fontFamily: FONT.body, fontSize: 17, bold: true, color: C.muted },
  mono: { fontFamily: FONT.mono, fontSize: 18, color: C.ink },
  footer: { fontFamily: FONT.body, fontSize: 11, color: "#71868F" },
};

function panel(options = {}, child) {
  const normalized = { ...options };
  if (typeof normalized.fill === "string") normalized.fill = paint(normalized.fill);
  if (typeof normalized.line === "string") normalized.line = stroke({ color: normalized.line, width: 1 });
  return rawPanel(normalized, child);
}

function shape(options = {}) {
  const normalized = { ...options };
  if (typeof normalized.fill === "string") normalized.fill = paint(normalized.fill);
  if (typeof normalized.line === "string") normalized.line = stroke({ color: normalized.line, width: 1 });
  return rawShape(normalized);
}

function txt(value, opts = {}) {
  return text(value, {
    width: opts.width ?? fill,
    height: opts.height ?? hug,
    name: opts.name,
    columnSpan: opts.columnSpan,
    rowSpan: opts.rowSpan,
    style: { ...style.body, ...(opts.style || {}) },
  });
}

function mono(value, opts = {}) {
  return txt(value, { ...opts, style: { ...style.mono, ...(opts.style || {}) } });
}

function tag(value, color = C.cyanDark, pale = C.cyanPale, tagWidth = hug) {
  const childWidth = tagWidth === hug ? hug : fill;
  return panel(
    { fill: pale, borderRadius: 18, padding: { x: 14, y: 7 }, width: tagWidth, height: hug },
    txt(value, { width: childWidth, style: { ...style.label, color, fontSize: 15, align: "center", alignment: "center" } }),
  );
}

function node(title, body, opts = {}) {
  return panel(
    {
      fill: opts.fill || C.white,
      line: opts.line || C.line,
      borderRadius: opts.radius ?? 16,
      padding: { x: opts.px ?? 22, y: opts.py ?? 18 },
      width: opts.width ?? fill,
      height: opts.height ?? hug,
    },
    column({ name: `${opts.name || title}-stack`, width: fill, height: hug, gap: 5 }, [
      txt(title, {
        name: opts.name,
        style: { fontFamily: FONT.display, fontSize: opts.titleSize || 24, bold: true, color: opts.titleColor || C.ink },
      }),
      ...(body ? [txt(body, { style: { ...style.small, color: opts.bodyColor || C.muted, fontSize: opts.bodySize || 18 } })] : []),
    ]),
  );
}

function arrow(label, color = C.cyanDark, vertical = false, glyph) {
  const hasLabel = Boolean(label);
  return column(
    { name: hasLabel ? `arrow-${label}` : "arrow-mark", width: vertical ? fixed(140) : fixed(150), height: vertical ? fixed(130) : (hasLabel ? fill : hug), gap: 2, align: "center", justify: "center" },
    [
      txt(glyph || (vertical ? "↓" : "→"), { width: fill, style: { fontFamily: FONT.display, fontSize: vertical ? 50 : 58, bold: true, color, align: "center", alignment: "center" } }),
      ...(hasLabel ? [txt(label, { width: fill, style: { fontFamily: FONT.body, fontSize: 14, bold: true, color, align: "center", alignment: "center" } })] : []),
    ],
  );
}

function footer(source, page) {
  return column({ width: fill, height: hug, gap: 8 }, [
    rule({ width: fill, stroke: C.line, weight: 1 }),
    row({ width: fill, height: hug, justify: "between", align: "center" }, [
      txt(source, { name: `source-${page}`, width: wrap(1500), style: style.footer }),
      txt(String(page).padStart(2, "0"), { name: `page-${page}`, width: fixed(36), style: { ...style.footer, fontFamily: FONT.mono, color: C.cyanDark, align: "right", alignment: "right" } }),
    ]),
  ]);
}

function titleStack(title, subtitle) {
  return column({ name: "title-stack", width: fill, height: hug, gap: 10 }, [
    txt(title, { name: "slide-title", style: style.title }),
    ...(subtitle ? [txt(subtitle, { name: "slide-subtitle", width: fill, style: style.subtitle })] : []),
  ]);
}

function standardSlide(pres, title, subtitle, source, page, body) {
  const slide = pres.slides.add();
  slide.compose(
    panel(
      { fill: C.canvas, width: fill, height: fill, padding: { x: 72, y: 58 } },
      grid(
        { name: "slide-root", width: fill, height: fill, columns: [fr(1)], rows: [auto, fr(1), auto], rowGap: 28 },
        [titleStack(title, subtitle), body, footer(source, page)],
      ),
    ),
    { frame: { left: 0, top: 0, width: 1920, height: 1080 }, baseUnit: 8 },
  );
  return slide;
}

function numberedStep(n, title, body, color = C.cyanDark) {
  return row({ width: fill, height: hug, gap: 18, align: "start" }, [
    panel(
      { fill: color, borderRadius: 28, width: fixed(52), height: fixed(52), align: "center", justify: "center" },
      txt(String(n), { width: fixed(44), height: hug, style: { fontFamily: FONT.display, fontSize: 23, bold: true, color: C.white, align: "center", alignment: "center" } }),
    ),
    column({ width: fill, height: hug, gap: 5 }, [
      txt(title, { style: { fontFamily: FONT.display, fontSize: 23, bold: true, color: C.ink } }),
      txt(body, { style: { ...style.small, fontSize: 18 } }),
    ]),
  ]);
}

function laneLabel(title, subtitle, fillColor, accent) {
  return panel(
    { fill: fillColor, borderRadius: 16, padding: { x: 18, y: 14 }, width: fill, height: hug },
    row({ width: fill, height: hug, gap: 14, align: "center" }, [
      shape({ geometry: "rect", fill: accent, width: fixed(8), height: fixed(54) }),
      column({ width: fill, height: hug, gap: 3 }, [
        txt(title, { style: { fontFamily: FONT.display, fontSize: 22, bold: true, color: C.ink } }),
        txt(subtitle, { style: { ...style.small, fontSize: 16 } }),
      ]),
    ]),
  );
}

const presentation = Presentation.create({ slideSize: { width: 1920, height: 1080 } });

// 1 — Cover: dedicated editorial cover, not the normal content scaffold.
{
  const slide = presentation.slides.add();
  slide.compose(
    panel(
      { fill: C.white, width: fill, height: fill },
      grid({ name: "cover-root", width: fill, height: fill, columns: [fr(0.83), fr(1.17)] }, [
        column({ width: fill, height: fill, padding: { left: 84, right: 26, top: 74, bottom: 58 }, justify: "between" }, [
          column({ width: fill, height: hug, gap: 30 }, [
            row({ width: fill, height: hug, gap: 18, align: "center" }, [
              image({ name: "app-icon-cover", dataUrl: IMG.appIcon, width: fixed(86), height: fixed(86), fit: "contain", alt: "Mu2e Notify app icon" }),
              column({ width: fill, height: hug, gap: 5 }, [
                txt("MU2E DAQ", { style: { fontFamily: FONT.mono, fontSize: 18, bold: true, color: C.cyanDark } }),
                txt("PHONE NOTIFICATION SYSTEM", { style: { fontFamily: FONT.body, fontSize: 14, bold: true, color: C.muted } }),
              ]),
            ]),
            column({ width: fill, height: hug, gap: 22 }, [
              txt("From protected\nDAQ to iPhone", { name: "cover-title", style: style.coverTitle }),
              rule({ width: fixed(180), stroke: C.orange, weight: 6 }),
              txt("How events cross the gateway firewall, traverse the public proxy, and reach operators without exposing the DAQ server.", { name: "cover-promise", width: wrap(660), style: style.coverPromise }),
            ]),
          ]),
          row({ width: fill, height: hug, justify: "between", align: "end" }, [
            txt("Architecture & deployment walkthrough", { width: hug, style: { ...style.small, fontSize: 16 } }),
            txt("19 AUG 2026", { name: "cover-date", width: fixed(150), style: { ...style.footer, fontFamily: FONT.mono, fontSize: 13, color: C.orange, align: "right", alignment: "right" } }),
          ]),
        ]),
        panel(
          { fill: "#FAF9F6", width: fill, height: fill, padding: { x: 8, y: 20 } },
          image({ name: "cover-system-illustration", dataUrl: IMG.cover, width: fill, height: fill, fit: "contain", alt: "Illustration of a protected DAQ cluster, external proxy, public cloud, and phone" }),
        ),
      ]),
    ),
    { frame: { left: 0, top: 0, width: 1920, height: 1080 }, baseUnit: 8 },
  );
}

// 2 — Most important overview.
standardSlide(
  presentation,
  "Three zones, two independent paths",
  "The proxy carries public API traffic. Push delivery does not pass through it.",
  "Sources: docs/application-chain.md; server/app.py; server/destinations.py; iOS AppState.swift",
  2,
  column({ name: "architecture-body", width: fill, height: fill, gap: 18 }, [
    grid({ width: fill, height: grow(1), columns: [fr(1.08), fixed(118), fr(0.76), fixed(118), fr(1.0)], columnGap: 10 }, [
      panel({ fill: C.cyanPale, line: C.cyan, borderRadius: 22, padding: { x: 28, y: 26 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 18 }, [
          row({ width: fill, height: hug, justify: "between", align: "center" }, [tag("1  PROTECTED ZONE"), mono("HTTPS :8095", { width: hug, style: { fontSize: 14, color: C.cyanDark } })]),
          node("DAQ publishers", "Python • C++ • CLI • optional ZeroMQ", { fill: C.white, line: C.cyan }),
          arrow("local ingest", C.cyanDark, true),
          node("mu2edaq-notify-server", "Flask API + web UI • SQLite/Postgres • filter + dispatch threads", { fill: C.navy, line: C.navy, titleColor: C.white, bodyColor: "#CFE5EC" }),
        ])),
      arrow("public API", C.cyanDark, false, "⇄"),
      panel({ fill: C.orangePale, line: C.orange, borderRadius: 22, padding: { x: 28, y: 26 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 20, justify: "center" }, [
          tag("2  EXTERNAL PROXY", "#9B5200", C.orangePale),
          node("TLS reverse proxy", "AWS Caddy + reverse tunnel\nor OKD Route + Caddy pod", { fill: C.white, line: C.orange, titleColor: "#7B4206" }),
          txt("The proxy is intentionally stateless.", { style: { ...style.small, fontSize: 17, color: "#7B5A36" } }),
        ])),
      arrow("HTTPS :443", C.cyanDark, false, "⇄"),
      panel({ fill: C.bluePale, line: C.blue, borderRadius: 22, padding: { x: 28, y: 26 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 18 }, [
          row({ width: fill, height: hug, justify: "between", align: "center" }, [tag("3  OUTSIDE WORLD", C.blue, C.bluePale, fixed(220)), image({ name: "app-icon-overview", dataUrl: IMG.appIcon, width: fixed(62), height: fixed(62), fit: "contain", alt: "Mu2e Notify app icon" })]),
          node("iPhone + browser", "Enroll • fetch history • update settings • live web SSE", { fill: C.white, line: C.blue }),
          node("Apple Push Notification service", "Receives provider-authenticated HTTP/2 pushes directly from the DAQ-side server", { fill: C.white, line: C.orange, titleColor: "#7B4206" }),
        ])),
    ]),
    row({ width: fill, height: hug, gap: 18 }, [
      laneLabel("CYAN — public control/data path", "iPhone/browser ⇄ proxy ⇄ DAQ API", C.cyanPale, C.cyan),
      laneLabel("ORANGE — notification delivery path", "DAQ server → APNs → iPhone", C.orangePale, C.orange),
    ]),
  ]),
);

// 3 — Internal components.
standardSlide(
  presentation,
  "Inside the DAQ cluster",
  "Publishers are deliberately lightweight; the server centralizes state, policy, and delivery.",
  "Sources: publisher.py; cpp/notify.cpp; server/cli.py; server/storage.py; server/zmq_listener.py",
  3,
  column({ width: fill, height: fill, gap: 22 }, [
    row({ width: fill, height: hug, gap: 16, align: "center" }, [
      tag("DISCOVERY"),
      mono("UDP multicast 239.255.42.99:28999", { width: hug, style: { fontSize: 17, color: C.cyanDark } }),
      txt("ANNOUNCE advertises the local HTTPS endpoint plus a public fallback URL.", { style: { ...style.small, fontSize: 17 } }),
    ]),
    grid({ width: fill, height: grow(1), columns: [fr(0.88), fixed(120), fr(1.14), fixed(120), fr(1.0)], columnGap: 8 }, [
      column({ width: fill, height: fill, gap: 15, justify: "center" }, [
        node("Python publisher", "stdlib HTTP client • never raises", { fill: C.white, line: C.cyan }),
        node("C++17 publisher", "libcurl • 5 s default timeout", { fill: C.white, line: C.cyan }),
        node("CLI / shell", "mu2edaq-notify send", { fill: C.white, line: C.cyan }),
        node("Legacy ZeroMQ", "SUB connects or PULL binds :8096", { fill: C.white, line: C.teal }),
      ]),
      arrow("Bearer JSON\nor ZMQ", C.cyanDark),
      panel({ fill: C.navy, borderRadius: 24, padding: { x: 30, y: 28 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 18, justify: "center" }, [
          txt("NOTIFICATION SERVER", { style: { fontFamily: FONT.mono, fontSize: 16, bold: true, color: C.cyan } }),
          txt("Normalize → store → publish SSE → queue dispatch", { name: "server-flow", style: { fontFamily: FONT.display, fontSize: 31, bold: true, color: C.white, lineSpacing: 1.05 } }),
          rule({ width: fill, stroke: "#35505C", weight: 2 }),
          txt("Flask runs threaded. Delivery runs on a daemon worker so DAQ ingest is decoupled from APNs/webhook latency.", { style: { ...style.small, color: "#CFE5EC", fontSize: 19 } }),
          row({ width: fill, height: hug, gap: 9 }, [tag("EVENT API", C.cyanDark, C.cyanPale, fixed(118)), tag("SSE STREAM", C.cyanDark, C.cyanPale, fixed(126)), tag("WEB UI", C.cyanDark, C.cyanPale, fixed(100))]),
        ])),
      arrow("policy + state", C.orange),
      column({ width: fill, height: fill, gap: 15, justify: "center" }, [
        node("SQLite / Postgres", "events • devices • filters • destinations • delivery audit", { fill: C.white, line: C.line }),
        node("Filter engine", "severity + source/host/category globs + optional regex", { fill: C.orangePale, line: C.orange }),
        node("Destinations", "APNs • Slack • Discord", { fill: C.greenPale, line: C.green }),
        node("Retention", "30 days by checked-in configuration", { fill: C.white, line: C.line }),
      ]),
    ]),
  ]),
);

// 4 — Reverse tunnel and firewall.
standardSlide(
  presentation,
  "The firewall crossing is outbound-initiated",
  "AWS public requests enter through Caddy, but the tunnel itself is opened from the DAQ side.",
  "Sources: docs/reverse-proxy-setup.md; scripts/start-mu2edaq-notify-proxy.sh; scripts/aws-proxy-user-data.sh",
  4,
  column({ width: fill, height: fill, gap: 20 }, [
    grid({ width: fill, height: grow(1), columns: [fr(1.05), fixed(150), fr(0.95)], columnGap: 18 }, [
      panel({ fill: C.cyanPale, borderRadius: 24, padding: { x: 28, y: 26 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 18 }, [
          tag("BEHIND DAQ GATEWAY"),
          node("Local notify server", "HTTPS 127.0.0.1:8095\nstate and APNs credentials stay here", { fill: C.navy, line: C.navy, titleColor: C.white, bodyColor: "#CFE5EC" }),
          node("Tunnel client", "ssh -N -R 127.0.0.1:18095:127.0.0.1:8095", { fill: C.white, line: C.cyan, bodySize: 16 }),
          laneLabel("Allowed egress", "DAQ host → EC2 TCP/22 using SSH key", C.white, C.cyan),
        ])),
      column({ width: fill, height: fill, gap: 18, align: "center", justify: "center" }, [
        shape({ geometry: "rect", fill: "#AAB9C0", width: fixed(20), height: fixed(430) }),
        txt("GATEWAY\nFIREWALL", { width: fill, style: { fontFamily: FONT.mono, fontSize: 16, bold: true, color: C.muted, align: "center", alignment: "center" } }),
        txt("SSH session opens outward →", { width: fill, style: { fontFamily: FONT.body, fontSize: 16, bold: true, color: C.cyanDark, align: "center", alignment: "center" } }),
        txt("← HTTP response rides the established tunnel", { width: fill, style: { fontFamily: FONT.body, fontSize: 15, bold: true, color: C.orange, align: "center", alignment: "center" } }),
      ]),
      panel({ fill: C.orangePale, borderRadius: 24, padding: { x: 28, y: 26 }, width: fill, height: fill },
        column({ width: fill, height: fill, gap: 18 }, [
          tag("AWS EC2 — PUBLIC", "#9B5200", C.orangePale),
          node("Caddy", "Trusted public TLS on :443\nHTTP :80 for redirect / ACME", { fill: C.white, line: C.orange }),
          arrow("loopback only", C.orange, true),
          node("Reverse port", "127.0.0.1:18095\nnot exposed by the security group", { fill: C.white, line: C.orange }),
          mono("notify.andrewnorman.org", { style: { fontSize: 16, color: "#7B4206", align: "center", alignment: "center" } }),
        ])),
    ]),
    row({ width: fill, height: hug, gap: 16 }, [
      laneLabel("Public edge", "Internet → EC2 :443 only", C.orangePale, C.orange),
      laneLabel("Private backend", "Caddy → loopback :18095 → tunnel → local :8095", C.cyanPale, C.cyan),
      laneLabel("No public :8095", "The DAQ server is not directly exposed", C.greenPale, C.green),
    ]),
  ]),
);

// 5 — Enrollment and phone behavior.
standardSlide(
  presentation,
  "Phone enrollment is a multi-party handshake",
  "The iPhone needs both a server bearer token and an Apple-issued APNs device token.",
  "Sources: server/app.py; server/auth.py; iOS ServerClient.swift; iOS AppState.swift; config/notify-server.yaml",
  5,
  grid({ width: fill, height: fill, columns: [fr(0.92), fr(1.08)], columnGap: 42 }, [
    column({ width: fill, height: fill, gap: 18, justify: "center" }, [
      numberedStep(1, "Operator creates enrollment", "Web UI signs a short-lived HS256 enrollment token and renders a QR containing the public base URL."),
      numberedStep(2, "Phone registers through the proxy", "POST /api/devices/register exchanges the enrollment token for a permanent device bearer token."),
      numberedStep(3, "iOS registers with Apple", "The OS supplies an APNs device token after notification permission is granted."),
      numberedStep(4, "Phone uploads the APNs token", "POST /api/devices/token associates the Apple token with the registered device."),
      numberedStep(5, "The app keeps history fresh", "While active, the SwiftUI dashboard polls GET /api/events every 5 seconds; it does not use SSE."),
    ]),
    panel({ fill: C.white, line: C.line, borderRadius: 24, padding: { x: 18, y: 18 }, width: fill, height: fill },
      column({ width: fill, height: fill, gap: 12 }, [
        image({ name: "apns-loop-illustration", dataUrl: IMG.apns, width: fill, height: grow(1), fit: "contain", alt: "Illustration of server API and push delivery paths to a phone" }),
        row({ width: fill, height: hug, gap: 12 }, [
          laneLabel("CYAN", "HTTPS API + bearer token", C.cyanPale, C.cyan),
          laneLabel("ORANGE", "APNs provider push", C.orangePale, C.orange),
        ]),
      ])),
  ]),
);

// 6 — Processing pipeline.
standardSlide(
  presentation,
  "Each event becomes a durable, auditable decision",
  "Ingest acknowledges quickly; delivery happens asynchronously and every attempt is recorded.",
  "Sources: server/app.py; server/dispatch.py; server/filters.py; server/destinations.py; server/storage.py",
  6,
  column({ width: fill, height: fill, gap: 20, justify: "center" }, [
    row({ width: fill, height: hug, gap: 8, align: "center" }, [
      node("1  NORMALIZE", "Validate title/message; coerce severity; bound field sizes", { fill: C.white, line: C.cyan, width: grow(1), titleSize: 22, bodySize: 16 }),
      arrow("", C.cyanDark),
      node("2  STORE", "Insert event before dispatch; return HTTP 201", { fill: C.cyanPale, line: C.cyan, width: grow(1), titleSize: 22, bodySize: 16 }),
      arrow("", C.cyanDark),
      node("3  FAN OUT", "Publish SSE and enqueue the dispatcher worker", { fill: C.white, line: C.cyan, width: grow(1), titleSize: 22, bodySize: 16 }),
    ]),
    row({ width: fill, height: hug, gap: 8, align: "center" }, [
      node("4  MATCH", "Union destinations from all enabled matching rules", { fill: C.orangePale, line: C.orange, width: grow(1), titleSize: 22, bodySize: 16 }),
      arrow("", C.orange),
      node("5  SUPPRESS", "Deduplicate source + severity + title for 60 s", { fill: C.white, line: C.orange, width: grow(1), titleSize: 22, bodySize: 16 }),
      arrow("", C.orange),
      node("6  DELIVER", "APNs per eligible device; Slack/Discord webhooks", { fill: C.greenPale, line: C.green, width: grow(1), titleSize: 22, bodySize: 16 }),
    ]),
    panel({ fill: C.navy, borderRadius: 20, padding: { x: 28, y: 22 }, width: fill, height: hug },
      row({ width: fill, height: hug, justify: "between", align: "center" }, [
        txt("DELIVERY LEDGER", { width: fixed(250), style: { fontFamily: FONT.mono, fontSize: 16, bold: true, color: C.white } }),
        tag("sent", C.green, C.greenPale, fixed(90)),
        tag("logged", "#8A5A00", C.orangePale, fixed(100)),
        tag("failed", C.red, C.redPale, fixed(90)),
        tag("suppressed", C.purple, "#EFE6FA", fixed(140)),
        txt("Event detail shows the target and reason.", { width: wrap(610), style: { ...style.small, color: "#CFE5EC", fontSize: 18 } }),
      ])),
  ]),
);

// 7 — AWS deployment operations.
standardSlide(
  presentation,
  "Scripted AWS deployment: one command, three health planes",
  "The full-chain script manages EC2, Caddy, the reverse tunnel, and the local server in order.",
  "Sources: scripts/start-mu2edaq-notify-chain.sh; docs/reverse-proxy-operations.md; config/notify-server.yaml",
  7,
  grid({ width: fill, height: fill, columns: [fr(1.08), fr(0.92)], columnGap: 44 }, [
    column({ width: fill, height: fill, gap: 15, justify: "center" }, [
      mono("scripts/start-mu2edaq-notify-chain.sh", { style: { fontSize: 20, bold: true, color: C.cyanDark } }),
      numberedStep(1, "Start / wait for EC2", "Instance running and AWS system checks OK.", C.cyanDark),
      numberedStep(2, "Verify SSH; start Caddy", "Remote listeners on 80/443.", C.cyanDark),
      numberedStep(3, "Open reverse tunnel", "EC2 loopback :18095 → DAQ-local :8095.", C.orange),
      numberedStep(4, "Start notify server", "TLS-enabled Flask process with PID/log files.", C.orange),
      numberedStep(5, "Validate every hop", "Local, tunnel, then public /api/health.", C.green),
    ]),
    column({ width: fill, height: fill, gap: 22, justify: "center" }, [
      txt("HEALTH PLANES", { style: { fontFamily: FONT.mono, fontSize: 16, bold: true, color: C.muted } }),
      node("LOCAL", "https://127.0.0.1:8095/api/health", { fill: C.cyanPale, line: C.cyan, titleColor: C.cyanDark }),
      node("TUNNEL", "https://127.0.0.1:18095/api/health on EC2", { fill: C.orangePale, line: C.orange, titleColor: "#7B4206" }),
      node("PUBLIC", "https://notify.andrewnorman.org/api/health", { fill: C.greenPale, line: C.green, titleColor: C.green }),
      rule({ width: fill, stroke: C.line, weight: 2 }),
      txt("A 502/503 is therefore diagnosable as proxy, tunnel, or local-service failure rather than one opaque outage.", { style: { fontFamily: FONT.display, fontSize: 26, bold: true, color: C.ink } }),
    ]),
  ]),
);

// 8 — Helm/OKD option.
standardSlide(
  presentation,
  "Helm/OKD changes the firewall contract",
  "The chart is a proxy-only deployment and assumes direct network reachability to the DAQ HTTPS backend.",
  "Sources: helm/values.yaml; helm/templates/{route,service,deployment,configmap}.yaml (current checkout)",
  8,
  column({ width: fill, height: fill, gap: 24 }, [
    row({ width: fill, height: grow(1), gap: 8, align: "center" }, [
      node("PUBLIC CLIENT", "HTTPS :443", { fill: C.bluePale, line: C.blue, width: grow(0.8), titleSize: 21, bodySize: 17 }),
      arrow("edge TLS", C.blue),
      node("OKD ROUTE", "Public router shard\n300 s timeout for SSE", { fill: C.orangePale, line: C.orange, width: grow(1), titleSize: 21, bodySize: 17 }),
      arrow("HTTP", C.orange),
      node("CLUSTERIP SERVICE", ":8080", { fill: C.white, line: C.line, width: grow(0.85), titleSize: 21, bodySize: 17 }),
      arrow("HTTP", C.cyanDark),
      node("CADDY POD", "caddy:2-alpine\nhealth probes → /api/health", { fill: C.cyanPale, line: C.cyan, width: grow(1), titleSize: 21, bodySize: 17 }),
      arrow("HTTPS :8095", C.red),
      node("DAQ BACKEND", "backend.url\nexample: kaon…:8095", { fill: C.redPale, line: C.red, width: grow(1), titleSize: 21, bodySize: 17 }),
    ]),
    grid({ width: fill, height: hug, columns: [fr(1), fr(1), fr(1)], columnGap: 18 }, [
      laneLabel("Proxy only", "No Flask app, database, or APNs key is deployed by the chart.", C.cyanPale, C.cyan),
      laneLabel("Direct backend route", "Unlike AWS, there is no reverse SSH tunnel in this chart.", C.redPale, C.red),
      laneLabel("TLS behavior", "Route terminates public TLS; Caddy skips verification to the backend.", C.orangePale, C.orange),
    ]),
    panel({ fill: C.navy, borderRadius: 18, padding: { x: 26, y: 20 }, width: fill, height: hug },
      row({ width: fill, height: hug, gap: 22, align: "center" }, [
        txt("NETWORK DECISION", { width: fixed(250), style: { fontFamily: FONT.mono, fontSize: 16, bold: true, color: C.white } }),
        txt("Either preserve the outbound-initiated tunnel model, or explicitly authorize OKD-proxy → DAQ-host :8095. The current Helm chart requires the latter.", { style: { ...style.small, color: "#D6E8EE", fontSize: 19 } }),
      ])),
  ]),
);

// 9 — Network contract table.
const interactions = [
  ["DAQ discovery", "DAQ LAN ⇄ multicast", "UDP 239.255.42.99:28999", "Discovery protocol", "Find local :8095 + public fallback"],
  ["Event ingest", "DAQ app → notify server", "HTTPS/TCP :8095", "Publisher bearer token", "POST /api/events"],
  ["Legacy ingest", "DAQ app ⇄ notify server", "ZMQ/TCP :8096 or configured endpoints", "No ZMQ auth in code", "SUB/PULL compatibility"],
  ["AWS tunnel", "DAQ host → EC2", "SSH/TCP :22", "SSH key", "Creates EC2 loopback :18095"],
  ["Public API", "iPhone/browser → proxy", "HTTPS/TCP :443", "Enroll/device token or web session", "Register, history, settings, SSE"],
  ["OKD backend", "Caddy pod → DAQ host", "HTTPS/TCP :8095", "Network allow + API auth by endpoint", "Direct reachability required"],
  ["Apple push", "Notify server → APNs", "HTTP/2 TLS/TCP :443", "ES256 provider JWT + bundle ID", "Push alert to device token"],
  ["Other outputs", "Notify server → Slack/Discord", "HTTPS/TCP :443", "Webhook secret in URL", "Optional destinations"],
];

standardSlide(
  presentation,
  "The required network contract",
  "Directions are from the component that must initiate the connection.",
  "Sources: publisher.py; cpp/notify.cpp; config/notify-server.yaml; proxy scripts; Helm templates; destinations.py",
  9,
  column({ width: fill, height: fill, gap: 0 }, [
    row({ width: fill, height: fixed(54), gap: 0 }, [
      ...[
        ["Interaction", 0.85], ["Initiator → target", 1.2], ["Protocol / port", 1.45], ["Auth / trust", 1.45], ["Purpose", 1.35],
      ].map(([h, w]) => panel({ fill: C.navy, padding: { x: 14, y: 14 }, width: grow(w), height: fill }, txt(h, { style: { fontFamily: FONT.body, fontSize: 15, bold: true, color: C.white } }))),
    ]),
    ...interactions.map((cells, i) => {
      const widths = [0.85, 1.2, 1.45, 1.45, 1.35];
      const cellNodes = cells.map((cell, j) => panel(
        {
          fill: i % 2 === 0 ? C.white : "#EDF3F5",
          line: C.line,
          padding: { x: 14, y: 10 },
          width: grow(widths[j]),
          height: fill,
          align: "center",
        },
        txt(cell, {
          name: `network-r${i + 1}-c${j + 1}`,
          style: {
            fontFamily: j === 2 ? FONT.mono : FONT.body,
            fontSize: j === 2 ? 13 : 14,
            bold: j === 0,
            color: j === 0 ? C.ink : C.muted,
            lineSpacing: 1.08,
          },
        }),
      ));
      return row({ width: fill, height: grow(1), gap: 0 }, cellNodes);
    }),
  ]),
);

// 10 — Decisions and guardrails.
standardSlide(
  presentation,
  "Operational guardrails",
  "The code is cohesive; reliability now depends on making its trust and deployment assumptions explicit.",
  "Sources: repository review of config, auth, dispatch, iOS client, AWS scripts, and Helm chart; tests: 89 passed",
  10,
  grid({ width: fill, height: fill, columns: [fr(0.74), fr(1.26)], columnGap: 56 }, [
    column({ width: fill, height: fill, gap: 28, justify: "center" }, [
      image({ name: "app-icon-close", dataUrl: IMG.appIcon, width: fixed(190), height: fixed(190), fit: "contain", alt: "Mu2e Notify app icon" }),
      txt("Choose one\nproxy contract.", { name: "closing-claim", width: wrap(560), style: { fontFamily: FONT.display, fontSize: 52, bold: true, color: C.ink, lineSpacing: 1.0 } }),
      txt("AWS reverse tunnel = DAQ-initiated egress.\nOKD chart = proxy-initiated backend access.", { width: wrap(620), style: { ...style.subtitle, color: C.muted } }),
    ]),
    column({ width: fill, height: fill, gap: 24, justify: "center" }, [
      numberedStep(1, "Enforce publisher authentication", "The checked-in YAML list is empty and points at a git-ignored token file. Confirm the effective runtime config before public exposure.", C.red),
      numberedStep(2, "Treat enrollment links as reusable until expiry", "The JWT is signed and time-limited, but the server does not consume or revoke it after first registration.", C.orange),
      numberedStep(3, "Verify APNs environment", "Checked-in config selects sandbox. A missing/unreadable .p8 key silently degrades delivery to logged-only mode.", C.orange),
      numberedStep(4, "Keep public URL canonical", "server.base_url drives QR and autoconfiguration. It must resolve to the proxy hostname phones can reach.", C.cyanDark),
      numberedStep(5, "Monitor all three planes", "Local server, proxy-to-backend, and public health checks distinguish the failure domain quickly.", C.green),
      rule({ width: fill, stroke: C.line, weight: 2 }),
      txt("Verified during this review: 89 Python tests pass; the Helm chart renders successfully with representative backend and route values.", { style: { fontFamily: FONT.display, fontSize: 23, bold: true, color: C.green } }),
    ]),
  ]),
);

await fs.mkdir(path.dirname(OUT), { recursive: true });
await fs.mkdir(RENDER, { recursive: true });
await fs.mkdir(PPTX_RENDER, { recursive: true });
await fs.mkdir(LAYOUT, { recursive: true });

// Source-model renders and inspectable layout exports.
for (let i = 0; i < presentation.slides.count; i += 1) {
  const slide = presentation.slides.getItem(i);
  const png = await slide.export({ format: "png", scale: 1 });
  await fs.writeFile(path.join(RENDER, `slide-${String(i + 1).padStart(2, "0")}.png`), Buffer.from(await png.arrayBuffer()));
  const layout = await slide.export({ format: "layout" });
  await fs.writeFile(path.join(LAYOUT, `slide-${String(i + 1).padStart(2, "0")}.layout.json`), Buffer.from(await layout.arrayBuffer()));
}

const pptx = await PresentationFile.exportPptx(presentation);
await pptx.save(OUT);

// Saved-PPTX parity pass: reopen the exported file and render every slide.
const saved = await fs.readFile(OUT);
const imported = await PresentationFile.importPptx(saved);
for (let i = 0; i < imported.slides.count; i += 1) {
  const png = await imported.slides.getItem(i).export({ format: "png", scale: 1 });
  await fs.writeFile(path.join(PPTX_RENDER, `slide-${String(i + 1).padStart(2, "0")}.png`), Buffer.from(await png.arrayBuffer()));
}

console.log(JSON.stringify({ output: OUT, slides: presentation.slides.count, sourceRender: RENDER, pptxRender: PPTX_RENDER, layout: LAYOUT }, null, 2));
