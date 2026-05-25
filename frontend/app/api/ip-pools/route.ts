import { NextRequest } from "next/server";
import { masterFetch, masterMutationFetch } from "../../../lib/api";

export async function GET() {
  return masterFetch("/api/admin/ip-pools");
}

export async function POST(request: NextRequest) {
  return masterMutationFetch(request, "/api/admin/ip-pools", { method: "POST" });
}
