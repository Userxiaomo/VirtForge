import { NextRequest, NextResponse } from "next/server";
import { masterMutationFetch } from "../../../../../lib/api";
import { invalidUuidPathParamMessage, safeUuidPathParam } from "../../../../../lib/route-params";

export async function POST(
  request: NextRequest,
  context: { params: Promise<{ taskId: string }> },
) {
  const { taskId: rawTaskId } = await context.params;
  const taskId = safeUuidPathParam(rawTaskId);
  if (!taskId) {
    return NextResponse.json({ error: invalidUuidPathParamMessage("taskId") }, { status: 400 });
  }

  return masterMutationFetch(request, `/api/admin/tasks/${taskId}/retry`, {
    method: "POST",
  });
}
