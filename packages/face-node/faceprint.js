import { Faceprint } from "@desert-ant-labs/core";

export { Faceprint, Level, matches } from "@desert-ant-labs/core";

export function reviveFace(json) {
  if (!json) return null;
  const out = { ...json, faceprint: Faceprint.fromJSON(json.faceprint) };
  if (typeof json.date === "number") out.date = new Date(json.date * 1000);
  return out;
}

export function revivePerson(json) {
  return json ? { ...json, keyFace: json.faces[0] } : null;
}

/** `value` as the core reads it: every `Date` in seconds since 1970, a `Faceprint` as its JSON. */
export function toWire(value) {
  if (value instanceof Date) return value.getTime() / 1000;
  if (Array.isArray(value)) return value.map(toWire);
  if (value && typeof value === "object") {
    if (typeof value.toJSON === "function") return toWire(value.toJSON());
    return Object.fromEntries(Object.entries(value).map(([k, v]) => [k, toWire(v)]));
  }
  return value;
}

export function seconds(date) {
  if (date == null) return undefined;
  return date instanceof Date ? date.getTime() / 1000 : Number(date);
}
