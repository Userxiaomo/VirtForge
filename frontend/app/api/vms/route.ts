import { masterFetch } from "../../../lib/api";

export async function GET() {
  return masterFetch("/api/admin/vms");
}
