import { NextRequest, NextResponse } from "next/server";
import { masterMutationFetch } from "../../../../../lib/api";
import { invalidUuidPathParamMessage, safeUuidPathParam } from "../../../../../lib/route-params";

export async function POST(
  request: NextRequest,
  context: { params: Promise<{ planId: string }> },
) {
  const { planId: rawPlanId } = await context.params;
  const planId = safeUuidPathParam(rawPlanId);
  if (!planId) {
    return NextResponse.json({ error: invalidUuidPathParamMessage("planId") }, { status: 400 });
  }

  return masterMutationFetch(request, `/api/admin/plans/${planId}/enabled`, {
    method: "POST",
  });
}
