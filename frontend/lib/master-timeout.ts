export const defaultMasterFetchTimeoutMs = 30_000;
const minMasterFetchTimeoutMs = 1_000;
const maxMasterFetchTimeoutMs = 300_000;

export function masterFetchTimeoutMs(raw?: string) {
  const configured = raw ?? process.env.MASTER_FETCH_TIMEOUT_MS;
  if (configured === undefined) {
    return defaultMasterFetchTimeoutMs;
  }
  if (!/^[0-9]+$/.test(configured)) {
    throw new Error(masterFetchTimeoutErrorMessage());
  }

  const timeoutMs = Number(configured);
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < minMasterFetchTimeoutMs ||
    timeoutMs > maxMasterFetchTimeoutMs
  ) {
    throw new Error(masterFetchTimeoutErrorMessage());
  }

  return timeoutMs;
}

export function createMasterFetchAbortSignal(timeoutMs: number) {
  if (
    !Number.isSafeInteger(timeoutMs) ||
    timeoutMs < minMasterFetchTimeoutMs ||
    timeoutMs > maxMasterFetchTimeoutMs
  ) {
    throw new Error(masterFetchTimeoutErrorMessage());
  }

  return AbortSignal.timeout(timeoutMs);
}

export function withMasterFetchTimeout(init: RequestInit = {}, timeoutMs?: number): RequestInit {
  return {
    ...init,
    redirect: "manual",
    signal: init.signal ?? createMasterFetchAbortSignal(timeoutMs ?? masterFetchTimeoutMs()),
  };
}

function masterFetchTimeoutErrorMessage() {
  return `MASTER_FETCH_TIMEOUT_MS must be an integer between ${minMasterFetchTimeoutMs} and ${maxMasterFetchTimeoutMs}`;
}
