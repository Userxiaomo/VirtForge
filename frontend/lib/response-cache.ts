export function applyNoStoreHeaders(headers: Headers) {
  headers.set("Cache-Control", "no-store, max-age=0");
  headers.set("Pragma", "no-cache");
  headers.set("Expires", "0");
}
