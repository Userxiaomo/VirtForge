type MasterFetchFailureStatus = 502 | 504;

export type MasterFetchFailureResponse = {
  status: MasterFetchFailureStatus;
  body: {
    error: "master unavailable" | "master request timed out";
  };
};

export function masterFetchFailureResponse(error: unknown): MasterFetchFailureResponse {
  if (isMasterFetchTimeout(error)) {
    return {
      status: 504,
      body: { error: "master request timed out" },
    };
  }

  return {
    status: 502,
    body: { error: "master unavailable" },
  };
}

function isMasterFetchTimeout(error: unknown) {
  return error instanceof DOMException && (error.name === "TimeoutError" || error.name === "AbortError");
}
