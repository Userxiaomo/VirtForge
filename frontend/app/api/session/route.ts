import { NextRequest, NextResponse } from "next/server";
import { parseAdminLoginBody } from "../../../lib/admin-session";
import {
  clearAdminCookie,
  masterBaseUrl,
  requirePanelMutationRequest,
  setAdminCookie,
} from "../../../lib/api";
import { masterFetchFailureResponse } from "../../../lib/master-fetch-failure";
import { withMasterFetchTimeout } from "../../../lib/master-timeout";
import { applyNoStoreHeaders } from "../../../lib/response-cache";

export async function POST(request: NextRequest) {
  const forbidden = requirePanelMutationRequest(request);
  if (forbidden) {
    applyNoStoreHeaders(forbidden.headers);
    return forbidden;
  }

  const body = await request.json().catch(() => null);
  const parsed = parseAdminLoginBody(body);
  if (!parsed.ok) {
    return sessionJsonResponse({ error: parsed.error }, { status: 400 });
  }

  let verify: Response;
  try {
    verify = await fetch(
      `${masterBaseUrl()}/api/admin/session`,
      withMasterFetchTimeout({
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ username: parsed.username, password: parsed.password }),
        cache: "no-store",
      }),
    );
  } catch (error) {
    const failure = masterFetchFailureResponse(error);
    return sessionJsonResponse(failure.body, { status: failure.status });
  }

  if (!verify.ok) {
    return sessionJsonResponse({ error: "invalid admin credentials" }, { status: 401 });
  }

  const response = sessionJsonResponse({ ok: true });
  setAdminCookie(response, parsed.password);
  return response;
}

export async function DELETE(request: NextRequest) {
  const forbidden = requirePanelMutationRequest(request);
  if (forbidden) {
    applyNoStoreHeaders(forbidden.headers);
    return forbidden;
  }

  const response = sessionJsonResponse({ ok: true });
  clearAdminCookie(response);
  return response;
}

function sessionJsonResponse(body: unknown, init?: ResponseInit) {
  const response = NextResponse.json(body, init);
  applyNoStoreHeaders(response.headers);
  return response;
}
