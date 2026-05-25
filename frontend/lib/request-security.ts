export const panelMutationHeaderName = "X-VPS-Panel-Request";
export const panelMutationHeaderValue = "same-origin";

const allowedFetchSites = new Set(["same-origin", "none"]);

export function isAllowedPanelMutationRequest(request: Pick<Request, "headers" | "url">) {
  if (request.headers.get(panelMutationHeaderName) !== panelMutationHeaderValue) {
    return false;
  }

  const origin = request.headers.get("Origin");
  if (origin) {
    try {
      if (new URL(origin).origin !== new URL(request.url).origin) {
        return false;
      }
    } catch {
      return false;
    }
  }

  const fetchSite = request.headers.get("Sec-Fetch-Site")?.toLowerCase();
  if (fetchSite && !allowedFetchSites.has(fetchSite)) {
    return false;
  }

  return true;
}
