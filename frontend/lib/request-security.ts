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
      if (new URL(origin).origin !== publicRequestOrigin(request)) {
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

function publicRequestOrigin(request: Pick<Request, "headers" | "url">) {
  const requestUrl = new URL(request.url);
  const forwardedProto = firstForwardedValue(request.headers.get("X-Forwarded-Proto"));
  if (!forwardedProto) {
    return requestUrl.origin;
  }

  const proto = forwardedProto.toLowerCase();
  if (proto !== "http" && proto !== "https") {
    return requestUrl.origin;
  }

  const host = firstForwardedValue(request.headers.get("X-Forwarded-Host")) ?? requestUrl.host;
  if (!isCleanForwardedHost(host)) {
    return requestUrl.origin;
  }

  return new URL(`${proto}://${host}`).origin;
}

function firstForwardedValue(value: string | null) {
  return value
    ?.split(",", 1)[0]
    ?.trim()
    || null;
}

function isCleanForwardedHost(host: string) {
  if (!host) {
    return false;
  }
  if (/[\s/@\\]/.test(host)) {
    return false;
  }

  try {
    return Boolean(new URL(`https://${host}`).hostname);
  } catch {
    return false;
  }
}
