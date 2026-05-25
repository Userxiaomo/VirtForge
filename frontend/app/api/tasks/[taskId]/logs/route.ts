import { NextRequest, NextResponse } from "next/server";
import { masterFetch } from "../../../../../lib/api";
import { invalidUuidPathParamMessage, safeUuidPathParam } from "../../../../../lib/route-params";

export async function GET(
  _request: NextRequest,
  context: { params: Promise<{ taskId: string }> },
) {
  const { taskId: rawTaskId } = await context.params;
  const taskId = safeUuidPathParam(rawTaskId);
  if (!taskId) {
    return NextResponse.json({ error: invalidUuidPathParamMessage("taskId") }, { status: 400 });
  }

  return masterFetch(`/api/admin/tasks/${taskId}/logs`);
}
