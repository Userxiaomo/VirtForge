import { NextRequest } from "next/server";
import { masterMutationFetch } from "../../../../lib/api";

export async function POST(request: NextRequest) {
  return masterMutationFetch(request, "/api/admin/tasks/stop-vm", { method: "POST" });
}
