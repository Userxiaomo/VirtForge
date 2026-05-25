import { NextRequest } from "next/server";
import { masterFetch, masterMutationFetch } from "../../../lib/api";

export async function GET() {
  return masterFetch("/api/admin/nodes");
}

export async function POST(request: NextRequest) {
  return masterMutationFetch(request, "/api/admin/nodes", { method: "POST" });
}
