const RENDER_W = 720;
const RENDER_H = 480;
const COVER = 190;
const TEX_SIZE = 256;
const FLOOR_Y = 282;
const CENTER_X = RENDER_W / 2;
const MAX_ALBUMS = 10;
const FEATURE_LIGHTING = 1 << 2;
const FEATURE_SPRING = 1 << 3;
const MODULE_URL = import.meta.url;
const MODULE_BYTES_FALLBACK = 36576;

const albums = [
  { title: "MIDNIGHT RUN", artist: "THE ARCADES", a: [0x13, 0x29, 0x5b, 0xff], b: [0xe7, 0x46, 0x8a, 0xff], c: [0x42, 0xdf, 0xe7, 0xff], motif: 0 },
  { title: "GLASS HOUSES", artist: "NORTH PIER", a: [0xd9, 0xe8, 0xf0, 0xff], b: [0x1e, 0x73, 0x8f, 0xff], c: [0x0f, 0x21, 0x2c, 0xff], motif: 1 },
  { title: "LOW SUN", artist: "JUNE ATLAS", a: [0xf1, 0xb1, 0x49, 0xff], b: [0xd8, 0x42, 0x3b, 0xff], c: [0x39, 0x20, 0x45, 0xff], motif: 2 },
  { title: "TAPE ECHO", artist: "MONO FIELD", a: [0x21, 0x24, 0x26, 0xff], b: [0xdb, 0xd2, 0xb4, 0xff], c: [0x9b, 0xe2, 0x80, 0xff], motif: 3 },
  { title: "OCEAN STATIC", artist: "THE SIGNALS", a: [0x04, 0x3b, 0x53, 0xff], b: [0x11, 0xa6, 0xc7, 0xff], c: [0xee, 0xf6, 0xff, 0xff], motif: 4 },
  { title: "RED LINE", artist: "CITY INDEX", a: [0x24, 0x11, 0x16, 0xff], b: [0xb9, 0x1f, 0x36, 0xff], c: [0xf6, 0xe5, 0xb7, 0xff], motif: 5 },
  { title: "SOFT CIRCUITS", artist: "ADA VIEW", a: [0x61, 0x78, 0x8a, 0xff], b: [0xe7, 0xe0, 0xc4, 0xff], c: [0x1c, 0x32, 0x45, 0xff], motif: 6 },
  { title: "LATE CHECKOUT", artist: "HOTEL MIRROR", a: [0x12, 0x16, 0x1c, 0xff], b: [0xc4, 0xa0, 0x5e, 0xff], c: [0x79, 0xd3, 0xff, 0xff], motif: 7 },
  { title: "BLUEPRINTS", artist: "PAPER TIGER", a: [0xf8, 0xf6, 0xed, 0xff], b: [0x2d, 0x5d, 0x8f, 0xff], c: [0xe2, 0x51, 0x43, 0xff], motif: 8 },
  { title: "AFTER HOURS", artist: "BLACK RAIN", a: [0x08, 0x08, 0x0d, 0xff], b: [0x5e, 0x44, 0x8f, 0xff], c: [0xf1, 0x5a, 0x7b, 0xff], motif: 9 },
];

const quadVS = `#version 300 es
layout(location=0) in vec2 a_pos;
uniform vec4 u_rect;
out vec2 v_pos;
void main() {
  vec2 p = mix(u_rect.xy, u_rect.zw, a_pos);
  v_pos = p;
  gl_Position = vec4((p.x / float(${RENDER_W})) * 2.0 - 1.0, 1.0 - (p.y / float(${RENDER_H})) * 2.0, 0.0, 1.0);
}`;

const textureFS = `#version 300 es
precision highp float;
precision highp int;
uniform sampler2D u_tex;
uniform float u_m[9];
uniform vec3 u_top;
uniform vec3 u_right;
uniform vec3 u_bottom;
uniform vec3 u_left;
uniform int u_reflection;
uniform int u_darken;
uniform int u_light_boost;
uniform int u_alpha;
out vec4 out_color;

bool edgeInside(vec3 e, float x, float y) {
  return e.x * x + e.y * y + e.z >= 0.0;
}

int coverage4(float x, float y) {
  int covered = 0;
  for (int i = 0; i < 4; i++) {
    float ox = (i & 1) == 0 ? 0.25 : 0.75;
    float oy = (i & 2) == 0 ? 0.25 : 0.75;
    float sx = x + ox;
    float sy = y + oy;
    if (edgeInside(u_top, sx, sy) &&
        edgeInside(u_right, sx, sy) &&
        edgeInside(u_bottom, sx, sy) &&
        edgeInside(u_left, sx, sy)) {
      covered++;
    }
  }
  return covered;
}

vec3 texelRGB(int x, int y) {
  return texelFetch(u_tex, ivec2(x, y), 0).rgb * 255.0;
}

vec3 bilinear(float u, float v) {
  int x0 = clamp(int(floor(u)), 0, ${TEX_SIZE - 1});
  int y0 = clamp(int(floor(v)), 0, ${TEX_SIZE - 1});
  int x1 = min(x0 + 1, ${TEX_SIZE - 1});
  int y1 = min(y0 + 1, ${TEX_SIZE - 1});
  float tx = u - float(x0);
  float ty = v - float(y0);
  vec3 top = floor(texelRGB(x0, y0) + (texelRGB(x1, y0) - texelRGB(x0, y0)) * tx + 0.5);
  vec3 bottom = floor(texelRGB(x0, y1) + (texelRGB(x1, y1) - texelRGB(x0, y1)) * tx + 0.5);
  return floor(top + (bottom - top) * ty + 0.5);
}

vec3 shade(vec3 c, float u_mid, int darken) {
  int s = darken + int(abs(u_mid - 128.0)) / 11;
  float factor = float(clamp(255 - s, 0, 255));
  return floor(c * factor / 255.0);
}

vec3 brighten(vec3 c, int boost) {
  float b = float(boost);
  return floor(c + floor((vec3(255.0) - c) * b / 100.0));
}

void main() {
  float px = floor(gl_FragCoord.x);
  float py = floor(float(${RENDER_H}) - gl_FragCoord.y);
  int cov = coverage4(px, py);
  if (cov <= 0) discard;

  float x = px + 0.5;
  float y = py + 0.5;
  float d = u_m[6] * x + u_m[7] * y + u_m[8];
  if (abs(d) < 0.0001) discard;
  float u = (u_m[0] * x + u_m[1] * y + u_m[2]) / d;
  float v = (u_m[3] * x + u_m[4] * y + u_m[5]) / d;
  if (u < -0.002 || u > 1.002 || v < -0.002 || v > 1.002) discard;

  float uf = clamp(u, 0.0, 1.0) * 255.0;
  float vf = clamp(v, 0.0, 1.0) * 255.0;
  if (u_reflection != 0) vf = 255.0 - vf;
  vec3 c = bilinear(uf, vf);
  c = shade(c, floor(uf + 0.5), u_darken);

  float alpha = float(u_alpha * cov) / 4.0;
  if (u_reflection != 0) {
    int fade = clamp(u_alpha - int((py - float(${FLOOR_Y})) * 1.5), 0, u_alpha);
    alpha = float(fade * cov) / 4.0;
    c = shade(c, 0.0, 48);
  } else {
    c = brighten(c, u_light_boost);
  }
  out_color = vec4(c / 255.0, alpha / 255.0);
}`;

const imageFS = `#version 300 es
precision mediump float;
uniform sampler2D u_tex;
in vec2 v_pos;
out vec4 out_color;
void main() {
  out_color = texture(u_tex, vec2(v_pos.x / float(${RENDER_W}), v_pos.y / float(${RENDER_H})));
}`;

const solidFS = `#version 300 es
precision mediump float;
uniform vec4 u_color;
out vec4 out_color;
void main() {
  out_color = u_color;
}`;

const shadowFS = `#version 300 es
precision mediump float;
uniform float u_x0;
uniform float u_x1;
uniform float u_y;
out vec4 out_color;
void main() {
  float x = floor(gl_FragCoord.x);
  float y = floor(float(${RENDER_H}) - gl_FragCoord.y);
  float cx = x < u_x0 ? u_x0 - x : (x > u_x1 ? x - u_x1 : 0.0);
  float cy = abs(y - u_y);
  float a = clamp(42.0 - cx * 2.0 - cy * 4.0, 0.0, 42.0);
  if (a <= 0.0) discard;
  out_color = vec4(0.0, 0.0, 0.0, a / 255.0);
}`;

const circleFS = `#version 300 es
precision mediump float;
uniform vec2 u_center;
uniform float u_radius;
uniform vec4 u_color;
out vec4 out_color;
void main() {
  vec2 p = vec2(floor(gl_FragCoord.x), floor(float(${RENDER_H}) - gl_FragCoord.y));
  vec2 d = p - u_center;
  if (dot(d, d) > u_radius * u_radius) discard;
  out_color = u_color;
}`;

const lineFS = `#version 300 es
precision mediump float;
uniform vec2 u_a;
uniform vec2 u_b;
uniform vec4 u_color;
out vec4 out_color;
void main() {
  vec2 p = vec2(gl_FragCoord.x, float(${RENDER_H}) - gl_FragCoord.y);
  vec2 ab = u_b - u_a;
  float t = clamp(dot(p - u_a, ab) / max(dot(ab, ab), 0.0001), 0.0, 1.0);
  vec2 closest = u_a + ab * t;
  if (distance(p, closest) > 0.85) discard;
  out_color = u_color;
}`;

function clamp(v, lo, hi) {
  return Math.max(lo, Math.min(hi, v));
}

function divTrunc(a, b) {
  return a < 0 ? Math.ceil(a / b) : Math.trunc(a / b);
}

function mod(a, b) {
  return ((a % b) + b) % b;
}

function mix(a, b, t) {
  return a + (b - a) * clamp(t, 0, 1);
}

function smoothstep(edge0, edge1, x) {
  const t = clamp((x - edge0) / (edge1 - edge0), 0, 1);
  return t * t * (3 - 2 * t);
}

function formatBytes(bytes) {
  if (bytes < 1024) return `${bytes} B`;
  return `${(bytes / 1024).toFixed(1)} KB`;
}

function moduleByteSize() {
  const entry = performance.getEntriesByName(MODULE_URL).at(-1);
  if (entry && entry.decodedBodySize > 0) return entry.decodedBodySize;
  return MODULE_BYTES_FALLBACK;
}

function rgba(r, g, b, a = 255) {
  return [clamp(r | 0, 0, 255), clamp(g | 0, 0, 255), clamp(b | 0, 0, 255), clamp(a | 0, 0, 255)];
}

function mixColor(a, b, t) {
  t = clamp(t, 0, 255);
  return rgba(
    a[0] + divTrunc((b[0] - a[0]) * t, 255),
    a[1] + divTrunc((b[1] - a[1]) * t, 255),
    a[2] + divTrunc((b[2] - a[2]) * t, 255),
    255,
  );
}

function addColor(c, delta) {
  return rgba(c[0] + delta, c[1] + delta, c[2] + delta, c[3]);
}

function shadeColor(c, darken) {
  const factor = clamp(255 - darken, 0, 255);
  return rgba(
    divTrunc(c[0] * factor, 255),
    divTrunc(c[1] * factor, 255),
    divTrunc(c[2] * factor, 255),
    c[3],
  );
}

function circle(u, v, cx, cy, r) {
  const dx = u - cx;
  const dy = v - cy;
  return dx * dx + dy * dy <= r * r;
}

function sampleAlbum(albumIndex, u, v) {
  const album = albums[albumIndex];
  let base = mixColor(album.a, album.b, clamp(divTrunc((u + v) * 255, 510), 0, 255));
  const grain = ((u * 17 + v * 29 + album.motif * 37) & 31) - 15;
  base = addColor(base, grain);

  switch (album.motif) {
    case 0:
      if (Math.abs(u - v) < 9 || Math.abs((255 - u) - v) < 8) base = mixColor(base, album.c, 180);
      if (circle(u, v, 128, 116, 42)) base = mixColor(base, [0x10, 0x10, 0x18, 0xff], 130);
      break;
    case 1:
      if (mod(divTrunc(u, 28), 2) === 0 || mod(divTrunc(v, 25), 2) === 0) base = mixColor(base, album.c, 78);
      if (Math.abs(u - 132) < 3) base = mixColor(base, [255, 255, 255, 255], 150);
      break;
    case 2:
      if (circle(u, v, 128, 132, 70)) base = mixColor(base, album.a, 170);
      if (v > 154 && ((u + v) & 18) < 7) base = mixColor(base, album.c, 92);
      break;
    case 3:
      if (circle(u, v, 128, 128, 72) && !circle(u, v, 128, 128, 32)) base = mixColor(base, album.c, 165);
      if (Math.abs(v - 128) < 4 || Math.abs(u - 128) < 4) base = mixColor(base, [0x12, 0x12, 0x12, 0xff], 160);
      break;
    case 4: {
      const wave = mod(u + divTrunc(v * v, 37), 42);
      if (wave < 12) base = mixColor(base, album.c, 130);
      if (v < 52) base = mixColor(base, [0x02, 0x18, 0x2a, 0xff], 120);
      break;
    }
    case 5:
      if (Math.abs(u - 128) < 18 || Math.abs(v - 128) < 18) base = mixColor(base, album.b, 160);
      if (Math.abs(u - v) < 5) base = mixColor(base, album.c, 180);
      break;
    case 6:
      if (mod(divTrunc(u, 32) + divTrunc(v, 32), 2) === 0) base = mixColor(base, album.b, 90);
      if (Math.abs(u - 64) < 4 || Math.abs(u - 192) < 4 || Math.abs(v - 64) < 4 || Math.abs(v - 192) < 4) base = mixColor(base, album.c, 150);
      break;
    case 7:
      if (u > 70 && u < 185 && v > 42 && v < 210) base = mixColor(base, album.b, 105);
      if (Math.abs(u - 128) + Math.abs(v - 126) < 62) base = mixColor(base, album.c, 125);
      break;
    case 8:
      if (mod(u + 2 * v, 47) < 4 || mod(2 * u + v, 53) < 4) base = mixColor(base, album.b, 150);
      if (u > 40 && u < 214 && v > 56 && v < 196 && ((u + v) & 16) === 0) base = mixColor(base, album.c, 80);
      break;
    default:
      if (circle(u, v, 92, 96, 44) || circle(u, v, 164, 160, 52)) base = mixColor(base, album.b, 170);
      if (Math.abs(u - 128) < 5) base = mixColor(base, album.c, 130);
      break;
  }

  if (u < 8 || u > 247 || v < 8 || v > 247) base = shadeColor(base, 58);
  if (v < 62 && u > 18 && u < 237) base = mixColor(base, [255, 255, 255, 255], divTrunc((62 - v) * 90, 62));
  return base;
}

function makeAlbumTextureBytes(albumIndex) {
  const bytes = new Uint8Array(TEX_SIZE * TEX_SIZE * 4);
  let p = 0;
  for (let v = 0; v < TEX_SIZE; v++) {
    for (let u = 0; u < TEX_SIZE; u++) {
      const c = sampleAlbum(albumIndex, u, v);
      bytes[p++] = c[0];
      bytes[p++] = c[1];
      bytes[p++] = c[2];
      bytes[p++] = c[3];
    }
  }
  return bytes;
}

function blendPixel(buf, x, y, c) {
  if (x < 0 || y < 0 || x >= RENDER_W || y >= RENDER_H) return;
  const idx = (y * RENDER_W + x) * 4;
  const a = c[3];
  if (a <= 0) return;
  if (a >= 255) {
    buf[idx] = c[0]; buf[idx + 1] = c[1]; buf[idx + 2] = c[2]; buf[idx + 3] = c[3];
    return;
  }
  buf[idx] = divTrunc(buf[idx] * (255 - a) + c[0] * a, 255);
  buf[idx + 1] = divTrunc(buf[idx + 1] * (255 - a) + c[1] * a, 255);
  buf[idx + 2] = divTrunc(buf[idx + 2] * (255 - a) + c[2] * a, 255);
  buf[idx + 3] = 255;
}

function makeBackgroundBytes() {
  const bytes = new Uint8Array(RENDER_W * RENDER_H * 4);
  for (let y = 0; y < RENDER_H; y++) {
    const t = divTrunc(y * 255, RENDER_H - 1);
    const floorFade = y >= FLOOR_Y ? clamp(170 - (y - FLOOR_Y) * 2, 0, 170) : 0;
    for (let x = 0; x < RENDER_W; x++) {
      const cx = Math.abs(x - CENTER_X);
      const vignette = clamp(divTrunc(cx * 85, CENTER_X) + divTrunc(Math.abs(y - 198) * 34, 240), 0, 105);
      const glow = clamp(78 - divTrunc(cx, 6) - divTrunc(Math.abs(y - 156), 5), 0, 78);
      let r = clamp(6 + divTrunc(t, 18) + divTrunc(glow, 5) - divTrunc(vignette, 6), 0, 255);
      let g = clamp(7 + divTrunc(t, 20) + divTrunc(glow, 4) - divTrunc(vignette, 6), 0, 255);
      let b = clamp(10 + divTrunc(t, 12) + divTrunc(glow, 2) - divTrunc(vignette, 4), 0, 255);
      if (floorFade > 0) {
        const keep = 255 - floorFade;
        r = divTrunc(r * keep, 255);
        g = divTrunc(g * keep, 255);
        b = divTrunc(b * keep, 255);
      }
      const idx = (y * RENDER_W + x) * 4;
      bytes[idx] = r; bytes[idx + 1] = g; bytes[idx + 2] = b; bytes[idx + 3] = 255;
    }
  }

  for (let x = 0; x < RENDER_W; x++) blendPixel(bytes, x, FLOOR_Y - 1, [0xc6, 0xd6, 0xea, 0x30]);
  for (let y = FLOOR_Y; y < FLOOR_Y + 64; y++) {
    const rowAlpha = clamp(42 - (y - FLOOR_Y), 0, 42);
    for (let x = 63; x < RENDER_W - 63; x++) {
      const dx = Math.abs(x - CENTER_X);
      const a = clamp(rowAlpha - divTrunc(dx, 15), 0, 42);
      if (a > 0) blendPixel(bytes, x, y, [0xd8, 0xe9, 0xff, a]);
    }
  }
  return bytes;
}

function projectCoverCorner(localX, localY, xWorld, yCenter, zWorld, cosY, sinY) {
  const rotatedX = localX * cosY;
  const rotatedZ = -localX * sinY;
  const z = zWorld + rotatedZ;
  const perspective = 780 / (780 + z);
  return {
    x: Math.round(CENTER_X + (xWorld + rotatedX) * perspective),
    y: Math.round(yCenter + localY * perspective),
  };
}

function coverQuad(selectedQ8, reflection, index) {
  const dQ8 = index * 256 - selectedQ8;
  const rel = dQ8 / 256;
  const ad = Math.abs(rel);
  const sign = rel < 0 ? -1 : 1;
  const turn = smoothstep(0.18, 0.82, ad);
  const yaw = sign * (turn * 1.08 + (1 - turn) * rel * 0.18);
  const cosY = Math.cos(yaw);
  const sinY = Math.sin(yaw);
  const centerPush = rel * 60;
  const sidePush = sign * (126 + (ad - 1) * 86);
  const xWorld = clamp(mix(centerPush, sidePush, turn), -500, 500);
  const zWorld = clamp(ad * 51, 0, 270);
  const yCenter = 171 + clamp(ad * 6, 0, 36);
  const half = COVER * (1 - clamp(ad * 0.025, 0, 0.12)) * 0.5;
  const q = {
    tl: projectCoverCorner(-half, -half, xWorld, yCenter, zWorld, cosY, sinY),
    tr: projectCoverCorner(half, -half, xWorld, yCenter, zWorld, cosY, sinY),
    br: projectCoverCorner(half, half, xWorld, yCenter, zWorld, cosY, sinY),
    bl: projectCoverCorner(-half, half, xWorld, yCenter, zWorld, cosY, sinY),
  };
  if (!reflection) return q;
  const gap = 4;
  return {
    tl: { x: q.bl.x, y: FLOOR_Y + gap },
    tr: { x: q.br.x, y: FLOOR_Y + gap },
    br: { x: q.tr.x, y: FLOOR_Y + gap + divTrunc((q.br.y - q.tr.y) * 3, 4) },
    bl: { x: q.tl.x, y: FLOOR_Y + gap + divTrunc((q.bl.y - q.tl.y) * 3, 4) },
  };
}

function coverNormal(selectedQ8, index) {
  const rel = (index * 256 - selectedQ8) / 256;
  const ad = Math.abs(rel);
  const sign = rel < 0 ? -1 : 1;
  const turn = smoothstep(0.18, 0.82, ad);
  const yaw = sign * (turn * 1.08 + (1 - turn) * rel * 0.18);
  return { x: Math.sin(yaw), y: 0, z: Math.cos(yaw) };
}

function lightingBoost(normal) {
  const light = normalize3({ x: -0.42, y: -0.22, z: 0.88 });
  const facing = clamp(dot3(normal, { x: 0, y: 0, z: 1 }), 0, 1);
  const diffuse = clamp(dot3(normal, light), 0, 1);
  const rim = clamp(1 - facing, 0, 1);
  return Math.round(diffuse * 34 + rim * 18);
}

function dot3(a, b) {
  return a.x * b.x + a.y * b.y + a.z * b.z;
}

function normalize3(v) {
  const len = Math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z);
  return len <= 0.0001 ? { x: 0, y: 0, z: 1 } : { x: v.x / len, y: v.y / len, z: v.z / len };
}

function quadArea(q) {
  const p = [q.tl, q.tr, q.br, q.bl];
  let area = 0;
  for (let i = 0; i < 4; i++) {
    const a = p[i], b = p[(i + 1) & 3];
    area += a.x * b.y - a.y * b.x;
  }
  return area;
}

function makeEdge(a, b, sign) {
  const edgeX = b.x - a.x;
  const edgeY = b.y - a.y;
  return [-edgeY * sign, edgeX * sign, (edgeY * a.x - edgeX * a.y) * sign];
}

function makeEdges(q) {
  const sign = quadArea(q) >= 0 ? 1 : -1;
  return {
    top: makeEdge(q.tl, q.tr, sign),
    right: makeEdge(q.tr, q.br, sign),
    bottom: makeEdge(q.br, q.bl, sign),
    left: makeEdge(q.bl, q.tl, sign),
  };
}

function inverseHomography(q) {
  const x0 = q.tl.x, y0 = q.tl.y;
  const x1 = q.tr.x, y1 = q.tr.y;
  const x2 = q.br.x, y2 = q.br.y;
  const x3 = q.bl.x, y3 = q.bl.y;
  const dx1 = x1 - x2, dy1 = y1 - y2;
  const dx2 = x3 - x2, dy2 = y3 - y2;
  const dx3 = x0 - x1 + x2 - x3, dy3 = y0 - y1 + y2 - y3;
  let g = 0, h = 0;
  if (Math.abs(dx3) > 0.0001 || Math.abs(dy3) > 0.0001) {
    const det = dx1 * dy2 - dx2 * dy1;
    if (Math.abs(det) < 0.0001) return null;
    g = (dx3 * dy2 - dx2 * dy3) / det;
    h = (dx1 * dy3 - dx3 * dy1) / det;
  }
  return invertMatrix3([
    x1 - x0 + g * x1, x3 - x0 + h * x3, x0,
    y1 - y0 + g * y1, y3 - y0 + h * y3, y0,
    g, h, 1,
  ]);
}

function invertMatrix3(m) {
  const c00 = m[4] * m[8] - m[5] * m[7];
  const c01 = -(m[3] * m[8] - m[5] * m[6]);
  const c02 = m[3] * m[7] - m[4] * m[6];
  const c10 = -(m[1] * m[8] - m[2] * m[7]);
  const c11 = m[0] * m[8] - m[2] * m[6];
  const c12 = -(m[0] * m[7] - m[1] * m[6]);
  const c20 = m[1] * m[5] - m[2] * m[4];
  const c21 = -(m[0] * m[5] - m[2] * m[3]);
  const c22 = m[0] * m[4] - m[1] * m[3];
  const det = m[0] * c00 + m[1] * c01 + m[2] * c02;
  if (Math.abs(det) < 0.0001) return null;
  const inv = 1 / det;
  return [c00 * inv, c10 * inv, c20 * inv, c01 * inv, c11 * inv, c21 * inv, c02 * inv, c12 * inv, c22 * inv];
}

function min4(a, b, c, d) {
  return Math.min(Math.min(a, b), Math.min(c, d));
}

function max4(a, b, c, d) {
  return Math.max(Math.max(a, b), Math.max(c, d));
}

function createShader(gl, type, source) {
  const shader = gl.createShader(type);
  gl.shaderSource(shader, source);
  gl.compileShader(shader);
  if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
    throw new Error(gl.getShaderInfoLog(shader) || "shader compile failed");
  }
  return shader;
}

function createProgram(gl, vsSource, fsSource) {
  const program = gl.createProgram();
  gl.attachShader(program, createShader(gl, gl.VERTEX_SHADER, vsSource));
  gl.attachShader(program, createShader(gl, gl.FRAGMENT_SHADER, fsSource));
  gl.linkProgram(program);
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) {
    throw new Error(gl.getProgramInfoLog(program) || "program link failed");
  }
  return program;
}

function getUniforms(gl, program, spec) {
  const out = {};
  for (const [key, name] of Object.entries(spec)) out[key] = gl.getUniformLocation(program, name);
  return out;
}

function createTexture(gl, width, height, bytes, filter = gl.NEAREST) {
  const tex = gl.createTexture();
  gl.bindTexture(gl.TEXTURE_2D, tex);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, filter);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
  gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
  gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
  gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, bytes);
  return tex;
}

class CoverFlowWebGL2 extends HTMLElement {
  connectedCallback() {
    this.selectedQ8 = 3 * 256;
    this.targetQ8 = 3 * 256;
    this.velocityQ8 = 0;
    this.springVelocityQ8 = 0;
    this.primaryDown = false;
    this.pressX = 0;
    this.lastX = 0;
    this.lastDX = 0;
    this.pressSelectedQ8 = 0;
    this.featureMask = FEATURE_LIGHTING | FEATURE_SPRING;
    this.renderCount = 0;
    this.lastRenderMs = 0;
    this.lastFrameMs = 0;
    this.sourceBytes = moduleByteSize();
    this.textCache = new Map();

    this.canvas = document.createElement("canvas");
    this.canvas.width = RENDER_W;
    this.canvas.height = RENDER_H;
    this.canvas.tabIndex = 0;
    this.canvas.style.display = "block";
    this.canvas.style.width = `${RENDER_W}px`;
    this.canvas.style.height = "auto";
    this.canvas.style.touchAction = "none";

    this.stats = document.createElement("div");
    this.stats.style.boxSizing = "border-box";
    this.stats.style.marginTop = "6px";
    this.stats.style.maxWidth = `${RENDER_W}px`;
    this.stats.style.font = "11px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace";
    this.stats.style.color = "#666";
    this.stats.style.lineHeight = "1.35";

    this.replaceChildren(this.canvas, this.stats);
    this.initGL();
    this.attachInput();
    this.renderFrame();
  }

  initGL() {
    const gl = this.canvas.getContext("webgl2", { alpha: false, antialias: true, desynchronized: true });
    if (!gl) throw new Error("WebGL2 is unavailable");
    this.gl = gl;
    gl.viewport(0, 0, RENDER_W, RENDER_H);
    gl.disable(gl.DEPTH_TEST);
    gl.enable(gl.BLEND);
    gl.blendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA);

    this.quadProgram = createProgram(gl, quadVS, textureFS);
    this.imageProgram = createProgram(gl, quadVS, imageFS);
    this.solidProgram = createProgram(gl, quadVS, solidFS);
    this.shadowProgram = createProgram(gl, quadVS, shadowFS);
    this.circleProgram = createProgram(gl, quadVS, circleFS);
    this.lineProgram = createProgram(gl, quadVS, lineFS);
    this.uniforms = {
      quad: getUniforms(gl, this.quadProgram, {
        rect: "u_rect",
        tex: "u_tex",
        m: "u_m[0]",
        top: "u_top",
        right: "u_right",
        bottom: "u_bottom",
        left: "u_left",
        reflection: "u_reflection",
        darken: "u_darken",
        lightBoost: "u_light_boost",
        alpha: "u_alpha",
      }),
      image: getUniforms(gl, this.imageProgram, { rect: "u_rect", tex: "u_tex" }),
      solid: getUniforms(gl, this.solidProgram, { rect: "u_rect", color: "u_color" }),
      shadow: getUniforms(gl, this.shadowProgram, { rect: "u_rect", x0: "u_x0", x1: "u_x1", y: "u_y" }),
      circle: getUniforms(gl, this.circleProgram, { rect: "u_rect", center: "u_center", radius: "u_radius", color: "u_color" }),
      line: getUniforms(gl, this.lineProgram, { rect: "u_rect", a: "u_a", b: "u_b", color: "u_color" }),
    };

    this.rectBuffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, this.rectBuffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([0, 0, 1, 0, 0, 1, 1, 1]), gl.STATIC_DRAW);

    this.backgroundTexture = createTexture(gl, RENDER_W, RENDER_H, makeBackgroundBytes(), gl.NEAREST);
    this.albumTextures = albums.map((_, i) => createTexture(gl, TEX_SIZE, TEX_SIZE, makeAlbumTextureBytes(i), gl.NEAREST));
  }

  attachInput() {
    this.canvas.addEventListener("click", () => this.canvas.focus());
    this.canvas.addEventListener("keydown", (event) => {
      if (event.key === "ArrowLeft" || event.key === "a" || event.key === "A") {
        this.stepSelection(-1);
      } else if (event.key === "ArrowRight" || event.key === "d" || event.key === "D") {
        this.stepSelection(1);
      } else if (event.key === "Home") {
        this.setSelection(0);
      } else if (event.key === "End") {
        this.setSelection(albums.length - 1);
      } else if (event.key === "l" || event.key === "L") {
        this.featureMask ^= FEATURE_LIGHTING;
      } else if (event.key === "s" || event.key === "S") {
        this.featureMask ^= FEATURE_SPRING;
      } else {
        return;
      }
      event.preventDefault();
      this.schedule();
    });
    this.canvas.addEventListener("pointerdown", (event) => {
      this.canvas.setPointerCapture(event.pointerId);
      this.canvas.focus();
      const p = this.canvasPoint(event);
      this.primaryDown = true;
      this.pressX = p.x;
      this.lastX = p.x;
      this.lastDX = 0;
      this.pressSelectedQ8 = this.selectedQ8;
      this.targetQ8 = this.selectedQ8;
      this.velocityQ8 = 0;
      this.springVelocityQ8 = 0;
      this.schedule();
    });
    this.canvas.addEventListener("pointermove", (event) => {
      if (!this.primaryDown) return;
      const p = this.canvasPoint(event);
      const dx = p.x - this.pressX;
      this.lastDX = p.x - this.lastX;
      this.lastX = p.x;
      this.selectedQ8 = this.clampSelected(this.pressSelectedQ8 - divTrunc(dx * 256, 129), true);
      this.targetQ8 = this.selectedQ8;
      this.velocityQ8 = divTrunc(-this.lastDX * 256, 129);
      this.springVelocityQ8 = 0;
      this.schedule();
    });
    const finishPointer = (event) => {
      if (!this.primaryDown) return;
      const p = this.canvasPoint(event);
      if (Math.abs(p.x - this.pressX) < 5) {
        const hit = this.hitAlbum(p.x, p.y);
        if (hit >= 0) this.setSelection(hit);
      }
      this.primaryDown = false;
      this.schedule();
    };
    this.canvas.addEventListener("pointerup", finishPointer);
    this.canvas.addEventListener("pointercancel", finishPointer);
    this.canvas.addEventListener("contextmenu", (event) => event.preventDefault());
  }

  canvasPoint(event) {
    const r = this.canvas.getBoundingClientRect();
    return {
      x: Math.round((event.clientX - r.left) * (RENDER_W / r.width)),
      y: Math.round((event.clientY - r.top) * (RENDER_H / r.height)),
    };
  }

  clampSelected(value, overscroll) {
    const maxQ8 = (albums.length - 1) * 256;
    return overscroll ? clamp(value, -120, maxQ8 + 120) : clamp(value, 0, maxQ8);
  }

  nearestIndex() {
    return clamp(divTrunc(this.selectedQ8 + 128, 256), 0, albums.length - 1);
  }

  targetIndex() {
    return clamp(divTrunc(this.targetQ8 + 128, 256), 0, albums.length - 1);
  }

  setSelection(index) {
    this.targetQ8 = this.clampSelected(index * 256, false);
    this.velocityQ8 = 0;
    this.springVelocityQ8 = 0;
  }

  stepSelection(delta) {
    this.setSelection(this.nearestIndex() + delta);
  }

  tick() {
    let active = this.primaryDown;
    if (!this.primaryDown) {
      if (this.velocityQ8 !== 0) {
        this.selectedQ8 = this.clampSelected(this.selectedQ8 + this.velocityQ8, true);
        this.velocityQ8 = divTrunc(this.velocityQ8 * 88, 100);
        if (Math.abs(this.velocityQ8) < 3) {
          this.velocityQ8 = 0;
          this.targetQ8 = this.nearestIndex() * 256;
          this.springVelocityQ8 = 0;
        }
        active = true;
      } else {
        const delta = this.targetQ8 - this.selectedQ8;
        if ((this.featureMask & FEATURE_SPRING) !== 0) {
          if (Math.abs(delta) > 1 || Math.abs(this.springVelocityQ8) > 2) {
            this.springVelocityQ8 += divTrunc(delta, 7);
            this.springVelocityQ8 = divTrunc(this.springVelocityQ8 * 72, 100);
            if (this.springVelocityQ8 === 0 && delta !== 0) this.springVelocityQ8 = delta < 0 ? -1 : 1;
            this.selectedQ8 += this.springVelocityQ8;
            active = true;
          } else {
            this.selectedQ8 = this.targetQ8;
            this.springVelocityQ8 = 0;
          }
        } else if (Math.abs(delta) > 1) {
          let step = divTrunc(delta, 6);
          if (step === 0) step = delta < 0 ? -1 : 1;
          this.selectedQ8 += step;
          active = true;
        } else {
          this.selectedQ8 = this.targetQ8;
        }
      }
    }
    return active;
  }

  schedule() {
    if (this.raf) return;
    this.raf = requestAnimationFrame(() => {
      this.raf = 0;
      const active = this.tick();
      this.renderFrame();
      if (active) this.schedule();
    });
  }

  useProgram(program) {
    const gl = this.gl;
    gl.useProgram(program);
    gl.bindBuffer(gl.ARRAY_BUFFER, this.rectBuffer);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 2, gl.FLOAT, false, 0, 0);
  }

  setRect(location, x0, y0, x1, y1) {
    this.gl.uniform4f(location, x0, y0, x1, y1);
  }

  drawTexture(tex, x0, y0, x1, y1) {
    const gl = this.gl;
    this.useProgram(this.imageProgram);
    this.setRect(this.uniforms.image.rect, x0, y0, x1, y1);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, tex);
    gl.uniform1i(this.uniforms.image.tex, 0);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawSolidRect(x0, y0, x1, y1, c) {
    const gl = this.gl;
    this.useProgram(this.solidProgram);
    this.setRect(this.uniforms.solid.rect, x0, y0, x1, y1);
    gl.uniform4f(this.uniforms.solid.color, c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawShadow(q) {
    const x0 = min4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const x1 = max4(q.tl.x, q.tr.x, q.br.x, q.bl.x);
    const y = FLOOR_Y - 1;
    const gl = this.gl;
    this.useProgram(this.shadowProgram);
    this.setRect(this.uniforms.shadow.rect, x0 - 12, y - 10, x1 + 12, y + 10);
    gl.uniform1f(this.uniforms.shadow.x0, x0);
    gl.uniform1f(this.uniforms.shadow.x1, x1);
    gl.uniform1f(this.uniforms.shadow.y, y);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawLine(x0, y0, x1, y1, c) {
    const gl = this.gl;
    this.useProgram(this.lineProgram);
    this.setRect(this.uniforms.line.rect, Math.min(x0, x1) - 2, Math.min(y0, y1) - 2, Math.max(x0, x1) + 2, Math.max(y0, y1) + 2);
    gl.uniform2f(this.uniforms.line.a, x0, y0);
    gl.uniform2f(this.uniforms.line.b, x1, y1);
    gl.uniform4f(this.uniforms.line.color, c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawCircle(cx, cy, radius, c) {
    const gl = this.gl;
    this.useProgram(this.circleProgram);
    this.setRect(this.uniforms.circle.rect, cx - radius, cy - radius, cx + radius + 1, cy + radius + 1);
    gl.uniform2f(this.uniforms.circle.center, cx, cy);
    gl.uniform1f(this.uniforms.circle.radius, radius);
    gl.uniform4f(this.uniforms.circle.color, c[0] / 255, c[1] / 255, c[2] / 255, c[3] / 255);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawAlbum(reflection, index) {
    const q = coverQuad(this.selectedQ8, reflection, index);
    const deltaQ8 = index * 256 - this.selectedQ8;
    const dist = Math.abs(deltaQ8);
    const sideDark = clamp(divTrunc(dist, 9), 0, 72);
    const light = reflection || (this.featureMask & FEATURE_LIGHTING) === 0 ? 0 : lightingBoost(coverNormal(this.selectedQ8, index));
    const alpha = reflection ? clamp(88 - divTrunc(dist, 12), 14, 84) : 255;
    if (!reflection) this.drawShadow(q);
    this.drawTexturedQuad(reflection, q, index, sideDark, light, alpha);
    if (!reflection) {
      const a = clamp(84 - divTrunc(dist, 5), 18, 84);
      const y0 = q.tl.y + divTrunc((q.bl.y - q.tl.y) * 38, 255);
      const y1 = q.tr.y + divTrunc((q.br.y - q.tr.y) * 38, 255);
      this.drawLine(q.tl.x + 8, y0, q.tr.x - 8, y1, [255, 255, 255, a]);
    }
  }

  drawTexturedQuad(reflection, q, albumIndex, darken, lightBoost, alpha) {
    const inv = inverseHomography(q);
    if (!inv) return;
    const minX = clamp(min4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, RENDER_W - 1);
    const maxX = clamp(max4(q.tl.x, q.tr.x, q.br.x, q.bl.x), 0, RENDER_W - 1);
    const minY = clamp(min4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, RENDER_H - 1);
    const maxY = clamp(max4(q.tl.y, q.tr.y, q.br.y, q.bl.y), 0, RENDER_H - 1);
    const edges = makeEdges(q);
    const gl = this.gl;
    this.useProgram(this.quadProgram);
    this.setRect(this.uniforms.quad.rect, minX, minY, maxX + 1, maxY + 1);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, this.albumTextures[albumIndex]);
    gl.uniform1i(this.uniforms.quad.tex, 0);
    gl.uniform1fv(this.uniforms.quad.m, inv);
    gl.uniform3fv(this.uniforms.quad.top, edges.top);
    gl.uniform3fv(this.uniforms.quad.right, edges.right);
    gl.uniform3fv(this.uniforms.quad.bottom, edges.bottom);
    gl.uniform3fv(this.uniforms.quad.left, edges.left);
    gl.uniform1i(this.uniforms.quad.reflection, reflection ? 1 : 0);
    gl.uniform1i(this.uniforms.quad.darken, darken);
    gl.uniform1i(this.uniforms.quad.lightBoost, lightBoost);
    gl.uniform1i(this.uniforms.quad.alpha, alpha);
    gl.drawArrays(gl.TRIANGLE_STRIP, 0, 4);
  }

  drawText(x, y, text, color, scale) {
    const size = scale === 3 ? 22 : scale === 2 ? 14 : 10;
    const adv = Math.max(1, Math.ceil(34 * (size / 66)));
    const w = text.length * adv;
    const key = `${text}|${size}|${color.join(",")}`;
    let item = this.textCache.get(key);
    if (!item) {
      const canvas = document.createElement("canvas");
      canvas.width = Math.max(1, w + 2);
      canvas.height = size + 4;
      const ctx = canvas.getContext("2d");
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      ctx.fillStyle = `rgba(${color[0]}, ${color[1]}, ${color[2]}, ${color[3] / 255})`;
      ctx.font = `${size}px ui-monospace, SFMono-Regular, Menlo, Consolas, monospace`;
      ctx.textBaseline = "top";
      for (let i = 0; i < text.length; i++) ctx.fillText(text[i], i * adv, 0);
      item = { tex: createTexture(this.gl, canvas.width, canvas.height, ctx.getImageData(0, 0, canvas.width, canvas.height).data, this.gl.LINEAR), w: canvas.width, h: canvas.height };
      this.textCache.set(key, item);
    }
    this.drawTexture(item.tex, x, y, x + item.w, y + item.h);
  }

  textWidth(text, scale) {
    const size = scale === 3 ? 22 : scale === 2 ? 14 : 10;
    return text.length * Math.max(1, Math.ceil(34 * (size / 66)));
  }

  drawChrome() {
    this.drawSolidRect(0, 0, RENDER_W, 42, [0, 0, 0, 0x8f]);
    this.drawText(27, 15, "COVER FLOW", [0xea, 0xf3, 0xff, 0xff], 3);
    this.drawText(RENDER_W - 213, 18, "DRAG OR ARROWS", [0xa7, 0xb7, 0xc8, 0xff], 2);
    this.drawFlag(28, 54, "L LIGHT", (this.featureMask & FEATURE_LIGHTING) !== 0);
    this.drawFlag(126, 54, "S SPRING", (this.featureMask & FEATURE_SPRING) !== 0);
    const idx = this.targetIndex();
    const album = albums[idx];
    this.drawText(CENTER_X - divTrunc(this.textWidth(album.title, 3), 2), 378, album.title, [0xf8, 0xfa, 0xff, 0xff], 3);
    this.drawText(CENTER_X - divTrunc(this.textWidth(album.artist, 2), 2), 411, album.artist, [0xa9, 0xb5, 0xc3, 0xff], 2);
    const dotsW = albums.length * 15 - 6;
    for (let i = 0; i < albums.length; i++) {
      const x = CENTER_X - divTrunc(dotsW, 2) + i * 15;
      const active = i === idx;
      this.drawCircle(x, 447, active ? 5 : 3, active ? [0xf5, 0xf7, 0xff, 0xff] : [0x78, 0x84, 0x92, 0xc8]);
    }
  }

  drawFlag(x, y, label, enabled) {
    const w = this.textWidth(label, 2) + 12;
    this.drawSolidRect(x, y, x + w, y + 18, enabled ? [0xe8, 0xf1, 0xff, 0x22] : [0, 0, 0, 0x32]);
    this.drawLine(x, y, x + w, y, enabled ? [0xd8, 0xe8, 0xff, 0x92] : [0x7a, 0x86, 0x95, 0x72]);
    this.drawLine(x, y + 17, x + w, y + 17, enabled ? [0xd8, 0xe8, 0xff, 0x92] : [0x7a, 0x86, 0x95, 0x72]);
    this.drawLine(x, y, x, y + 18, enabled ? [0xd8, 0xe8, 0xff, 0x92] : [0x7a, 0x86, 0x95, 0x72]);
    this.drawLine(x + w - 1, y, x + w - 1, y + 18, enabled ? [0xd8, 0xe8, 0xff, 0x92] : [0x7a, 0x86, 0x95, 0x72]);
    this.drawText(x + 6, y + 5, label, enabled ? [0xf2, 0xf7, 0xff, 0xff] : [0x7d, 0x89, 0x97, 0xff], 2);
  }

  hitAlbum(x, y) {
    let best = -1;
    let bestAbs = 100000;
    for (let i = 0; i < albums.length; i++) {
      const dQ8 = i * 256 - this.selectedQ8;
      if (Math.abs(dQ8) > 4 * 256) continue;
      const q = coverQuad(this.selectedQ8, false, i);
      if (x >= min4(q.tl.x, q.tr.x, q.br.x, q.bl.x) &&
          x <= max4(q.tl.x, q.tr.x, q.br.x, q.bl.x) &&
          y >= min4(q.tl.y, q.tr.y, q.br.y, q.bl.y) &&
          y <= max4(q.tl.y, q.tr.y, q.br.y, q.bl.y)) {
        const ad = Math.abs(dQ8);
        if (ad < bestAbs) {
          bestAbs = ad;
          best = i;
        }
      }
    }
    return best;
  }

  renderFrame() {
    const start = performance.now();
    this.drawTexture(this.backgroundTexture, 0, 0, RENDER_W, RENDER_H);
    for (let pass = 5; pass >= -5; pass--) {
      const idx = this.nearestIndex() + pass;
      if (idx >= 0 && idx < albums.length) this.drawAlbum(true, idx);
    }
    for (let pass = 5; pass >= 1; pass--) {
      const left = this.nearestIndex() - pass;
      if (left >= 0) this.drawAlbum(false, left);
      const right = this.nearestIndex() + pass;
      if (right < albums.length) this.drawAlbum(false, right);
    }
    const center = this.nearestIndex();
    if (center >= 0 && center < albums.length) this.drawAlbum(false, center);
    this.drawChrome();
    this.gl.flush();
    this.lastRenderMs = performance.now() - start;
    this.renderCount += 1;
    this.updateStats();
  }

  updateStats() {
    const size = this.sourceBytes > 0 ? ` | JS ${formatBytes(this.sourceBytes)}` : "";
    this.stats.textContent = `WebGL2 render ${this.lastRenderMs.toFixed(3)} ms | frames ${this.renderCount}${size} | canvas ${RENDER_W}x${RENDER_H}`;
  }
}

if (!customElements.get("cover-flow-webgl2")) {
  customElements.define("cover-flow-webgl2", CoverFlowWebGL2);
}
