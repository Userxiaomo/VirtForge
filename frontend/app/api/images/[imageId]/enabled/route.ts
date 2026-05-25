import { NextRequest, NextResponse } from "next/server";
import { masterMutationFetch } from "../../../../../lib/api";
import { invalidUuidPathParamMessage, safeUuidPathParam } from "../../../../../lib/route-params";

export async function POST(
  request: NextRequest,
  context: { params: Promise<{ imageId: string }> },
) {
  const { imageId: rawImageId } = await context.params;
  const imageId = safeUuidPathParam(rawImageId);
  if (!imageId) {
    return NextResponse.json({ error: invalidUuidPathParamMessage("imageId") }, { status: 400 });
  }

  return masterMutationFetch(request, `/api/admin/images/${imageId}/enabled`, {
    method: "POST",
  });
}
