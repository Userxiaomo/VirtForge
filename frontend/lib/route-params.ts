const uuidPathParamPattern =
  /^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$/;

export function safeUuidPathParam(value: string) {
  return uuidPathParamPattern.test(value) ? value : null;
}

export function invalidUuidPathParamMessage(name: string) {
  return `${name} must be a UUID`;
}
