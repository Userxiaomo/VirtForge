import { NextRequest, NextResponse } from "next/server";
import { masterMutationFetch } from "../../../../../lib/api";
import { invalidUuidPathParamMessage, safeUuidPathParam } from "../../../../../lib/route-params";

export async function POST(
  request: NextRequest,
  context: { params: Promise<{ nodeId: string }> },
) {
  const { nodeId: rawNodeId } = await context.params;
  const nodeId = safeUuidPathParam(rawNodeId);
  if (!nodeId) {
    return NextResponse.json({ error: invalidUuidPathParamMessage("nodeId") }, { status: 400 });
  }

  return masterMutationFetch(request, `/api/admin/nodes/${nodeId}/bootstrap-tokens`, {
    method: "POST",
  });
}
