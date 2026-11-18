import "server-only";

/**
 * SimpleFIN Bridge client.
 *
 * Protocol: https://www.simplefin.org/protocol.html
 * A setup token is a base64-encoded claim URL. POSTing to that URL once returns
 * an access URL of the form `https://user:pass@host/path`, which is then used
 * for authenticated `GET {accessUrl}/accounts` requests.
 */

export type SimpleFinOrganization = {
  /** Present on v1 responses from the Bridge. */
  domain?: string;
  name?: string;
  "sfin-url"?: string;
  url?: string;
  id?: string;
};

export type SimpleFinTransaction = {
  id: string;
  /** UNIX epoch seconds. */
  posted: number;
  /** Numeric string, negative for money leaving the account. */
  amount: string;
  description: string;
  /** UNIX epoch seconds. Optional. */
  transacted_at?: number;
  pending?: boolean;
  /** The Bridge adds these beyond the base spec. */
  payee?: string;
  memo?: string;
  extra?: Record<string, unknown>;
};

export type SimpleFinAccount = {
  id: string;
  name: string;
  currency: string;
  /** Numeric string. */
  balance: string;
  "available-balance"?: string;
  /** UNIX epoch seconds. */
  "balance-date": number;
  transactions?: SimpleFinTransaction[];
  /** v1 shape. */
  org?: SimpleFinOrganization;
  /** v2 shape. */
  conn_id?: string;
  extra?: Record<string, unknown>;
};

export type SimpleFinConnection = {
  conn_id: string;
  name?: string;
  org_id?: string;
  org_url?: string;
  sfin_url?: string;
};

export type SimpleFinAccountSet = {
  errors?: string[];
  errlist?: string[];
  connections?: SimpleFinConnection[];
  accounts: SimpleFinAccount[];
};

export class SimpleFinError extends Error {
  constructor(
    message: string,
    readonly status?: number,
  ) {
    super(message);
    this.name = "SimpleFinError";
  }
}

/** Splits `https://user:pass@host/path` into a bare URL plus a Basic auth header. */
function toRequest(accessUrl: string): { baseUrl: string; authorization: string } {
  let parsed: URL;
  try {
    parsed = new URL(accessUrl);
  } catch {
    throw new SimpleFinError("The stored SimpleFIN access URL is malformed.");
  }

  const username = decodeURIComponent(parsed.username);
  const password = decodeURIComponent(parsed.password);
  parsed.username = "";
  parsed.password = "";

  return {
    baseUrl: parsed.toString().replace(/\/$/, ""),
    authorization: `Basic ${Buffer.from(`${username}:${password}`).toString("base64")}`,
  };
}

export type FetchAccountsOptions = {
  /** UNIX epoch seconds. SimpleFIN caps a single request at a 90-day range. */
  startDate?: number;
  endDate?: number;
  includePending?: boolean;
  balancesOnly?: boolean;
};

export async function fetchAccountSet(
  accessUrl: string,
  options: FetchAccountsOptions = {},
): Promise<SimpleFinAccountSet> {
  const { baseUrl, authorization } = toRequest(accessUrl);
  const url = new URL(`${baseUrl}/accounts`);

  if (options.startDate) url.searchParams.set("start-date", String(options.startDate));
  if (options.endDate) url.searchParams.set("end-date", String(options.endDate));
  if (options.includePending) url.searchParams.set("pending", "1");
  if (options.balancesOnly) url.searchParams.set("balances-only", "1");

  const response = await fetch(url, {
    headers: { Authorization: authorization, Accept: "application/json" },
    cache: "no-store",
  });

  if (response.status === 402 || response.status === 429) {
    throw new SimpleFinError(
      "SimpleFIN rate limit reached (24 requests per day). Try again later.",
      response.status,
    );
  }
  if (response.status === 403) {
    throw new SimpleFinError(
      "SimpleFIN rejected these credentials. Reconnect with a new setup token.",
      403,
    );
  }
  if (!response.ok) {
    throw new SimpleFinError(`SimpleFIN request failed (HTTP ${response.status}).`, response.status);
  }

  const data = (await response.json()) as SimpleFinAccountSet;
  if (!data || !Array.isArray(data.accounts)) {
    throw new SimpleFinError("SimpleFIN returned an unexpected response body.");
  }
  return data;
}

/** The spec allows `errors` (v1) or `errlist` (v2); surface whichever is present. */
export function accountSetErrors(set: SimpleFinAccountSet): string[] {
  return [...(set.errors ?? []), ...(set.errlist ?? [])].filter(Boolean);
}

/** Resolves an account's institution name across the v1 (`org`) and v2 (`conn_id`) shapes. */
export function institutionName(
  account: SimpleFinAccount,
  connections: SimpleFinConnection[] = [],
): string {
  const fromOrg = account.org?.name ?? account.org?.domain;
  if (fromOrg) return fromOrg;

  const connection = connections.find((c) => c.conn_id === account.conn_id);
  return connection?.name ?? "Connected account";
}
