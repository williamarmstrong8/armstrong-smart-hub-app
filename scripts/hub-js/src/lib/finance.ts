import { CATEGORIES, UNCATEGORIZED, type Category } from "@/lib/categories";
import {
  accountSetErrors,
  institutionName,
  type SimpleFinAccountSet,
} from "@/lib/simplefin";

export { CATEGORIES, UNCATEGORIZED, type Category };

/**
 * Turns a raw SimpleFIN account set into the shapes the dashboard renders.
 * Everything here is pure so the results can be serialized to Client Components.
 */

export type AccountKind = "cash" | "credit" | "loan" | "investment";

export type NormalizedAccount = {
  id: string;
  name: string;
  institution: string;
  currency: string;
  kind: AccountKind;
  /** True when the account represents money owed. */
  isLiability: boolean;
  /** Balance exactly as reported, signed. */
  rawBalance: number;
  /** Always positive: the magnitude of what is held or owed. */
  magnitude: number;
  /** Signed contribution to net worth (negative for debt). */
  contribution: number;
  availableBalance: number | null;
  balanceDate: number;
  transactionCount: number;
};

export type NormalizedTransaction = {
  id: string;
  accountId: string;
  accountName: string;
  institution: string;
  currency: string;
  posted: number;
  /** Signed as reported by the institution. */
  amount: number;
  /** Effect on net worth, sign-corrected for liability accounts. */
  netEffect: number;
  description: string;
  payee: string;
  memo: string | null;
  pending: boolean;
  /** A pending $1 card check (Lyft, gas pumps) that drops off or becomes the real charge. */
  hold: boolean;
  category: Category;
  /** "manual" once the user has picked or confirmed the category. */
  categorySource: "auto" | "manual";
};

/** Dividends aren't counted as income anywhere, even if one lands in checking. */
const DIVIDEND = /\bdividends?\b/i;

/** Categories that are internal money movement, not real income or spending. */
const NEUTRAL_CATEGORIES = new Set<Category>(["Transfers"]);

/**
 * Accounts left out of the dashboard entirely: balances, net worth, spending
 * and transactions. The long-term Wells Fargo brokerage is matched by its
 * masked number so the sweep account beside it ("BROKERAGE CASH ...9770")
 * stays in.
 */
const EXCLUDED_ACCOUNTS = [/^brokerage \.\.\.5639\b/i];

export function isExcludedAccount(name: string): boolean {
  return EXCLUDED_ACCOUNTS.some((pattern) => pattern.test(name.trim()));
}

const LIABILITY_PATTERNS =
  /\b(credit|card|visa|mastercard|amex|american express|discover|loan|mortgage|heloc|line of credit|auto ?loan|student)\b/i;
const INVESTMENT_PATTERNS =
  /\b(brokerage|invest|401k|401\(k\)|ira|roth|hsa|portfolio|vanguard|fidelity|schwab|robinhood|etrade|securities)\b/i;

const CATEGORY_PATTERNS: [Category, RegExp][] = [
  [
    // First, so a landlord's ACH ("APF SABET MANAGEMENT ... ACH") isn't read as a transfer.
    "Rent",
    /\b(apf\W*sabet|sabet manage|sabet mgmt|landlord|property (management|mgmt)|rent payment|monthly rent)/i,
  ],
  [
    "Transfers",
    /\b(transfer|xfer|payment thank you|online payment|autopay|auto ?pay|pymt|card payment|credit card|bill ?pay|zelle|venmo|cash app|paypal transfer|ach)\b/i,
  ],
  [
    "Subscriptions & Fees",
    /\b(interest|fee|overdraft|nsf|service charge|atm fee|foreign transaction|late charge|annual fee)\b/i,
  ],
  [
    // "market" is deliberately guarded: brokerages report money market fund
    // activity on every settlement, which otherwise reads as a grocery run.
    "Groceries",
    /\b(grocery|groceries|supermarket|whole foods|trader joe|safeway|kroger|aldi|costco|sam'?s club|publix|wegmans|sprouts|heb|food ?lion|(?<!money )(?<!stock )market)\b/i,
  ],
  [
    "Food & Drinks",
    /\b(restaurant|cafe|coffee|starbucks|dunkin|mcdonald|chipotle|pizza|sushi|bar|pub|tavern|lounge|saloon|cocktail|wine bar|beer hall|doordash|ubereats|uber eats|grubhub|seamless|postmates|deli|bakery|brewing|brewery|taqueria|diner)\b/i,
  ],
  [
    "Transport",
    /\b(uber|lyft|taxi|transit|metro|mta|omny|subway pass|bart|caltrain|parking|gas|shell|chevron|exxon|bp |mobil|fuel|toll|ez ?pass|car wash|auto ?zone|dmv)\b/i,
  ],
  [
    "Travel",
    /\b(airline|airways|air ?lines|delta air|united air|american air|southwest|jetblue|alaska air|hotel|marriott|hilton|hyatt|airbnb|vrbo|expedia|booking\.com|priceline|amtrak|rental car|hertz|avis|enterprise rent)\b/i,
  ],
  [
    // Recurring software and media. Checked before utilities so "internet" or
    // "phone" in a SaaS name doesn't read as a household bill.
    "Subscriptions & Fees",
    /\b(netflix|hulu|spotify|apple music|icloud|disney ?\+?|hbo|max|paramount|peacock|youtube premium|patreon|amazon prime|prime video|squarespace|google workspace|google one|cursor|openai|chatgpt|anthropic|claude\.ai|github|dropbox|notion|figma|adobe|rocket money|vpn|subscription|membership fee)\b/i,
  ],
  [
    "Bills & Utilities",
    /\b(electric|utility|utilities|water|sewer|gas company|comcast|xfinity|spectrum|verizon|at&t|t-?mobile|internet|phone|insurance|rent|mortgage|hoa|storage|waste|energy)\b/i,
  ],
  [
    "Lifestyle",
    /\b(steam|playstation|xbox|nintendo|cinema|theater|theatre|amc|fandango|concert|ticketmaster|stubhub|comedy)\b/i,
  ],
  [
    "Lifestyle",
    /\b(pharmacy|cvs|walgreens|rite aid|doctor|dental|dentist|medical|clinic|hospital|health|vision|optometr|therapy|gym|fitness|peloton|equinox|planet fitness)\b/i,
  ],
  [
    "Lifestyle",
    /\b(amazon|amzn|target|walmart|best buy|home depot|lowe'?s|ikea|etsy|ebay|apple store|nike|zara|h&m|uniqlo|sephora|ulta|macy|nordstrom|wayfair|shop)\b/i,
  ],
  [
    "Income",
    /\b(payroll|direct ?dep|direct deposit|salary|paycheck|employer|refund|reimburse|cashback|cash back|interest earned|tax ref|irs|treas)\b/i,
  ],
  // Last resort: independent merchants rarely match a brand name above, but the
  // payment processor's prefix survives into the statement. Toast ("TST*") sells
  // only to restaurants. Square ("SQ *") is broader — it also serves small
  // retail — so this leans Food & Drinks on the balance of probability rather than
  // certainty, and a wrong guess is one click to fix on the transaction row.
  ["Food & Drinks", /\btst ?\*|\bsq ?\*/i],
];

/**
 * Money arriving through Venmo is mostly friends paying back their share of a
 * meal or round, so it defaults to Food & Drinks, where it offsets spending
 * (see isSpendingOffset). Outgoing Venmo stays a neutral transfer.
 */
const VENMO = /\bvenmo\b/i;

/**
 * Money coming in under Food & Drinks (a Venmo payback, a restaurant refund)
 * reduces that category's spending rather than counting as income.
 */
export function isSpendingOffset(
  transaction: Pick<NormalizedTransaction, "netEffect" | "category">,
): boolean {
  return transaction.netEffect > 0 && transaction.category === "Food & Drinks";
}

/**
 * Payees whose rule is trusted outright: they take their tag without waiting
 * in the review queue.
 */
const TRUSTED_PAYEES: Record<string, RegExp> = {
  Transport: /\b(mta|omny|lyft)\b/i,
  Rent: /\bapf\W*sabet/i,
};

/**
 * A Venmo cash-out landing in the bank is the payback pot arriving. A remembered
 * or hand-picked "Transfers" tag would hide it from the Food & Drinks counter, so
 * incoming Venmo tagged Transfers is counted as an offset there instead.
 */
function venmoPayback(category: Category, netEffect: number, text: string): Category {
  return category === "Transfers" && netEffect > 0 && VENMO.test(text) ? "Food & Drinks" : category;
}

export function categorize(description: string, amount: number): Category {
  const text = description.toLowerCase();

  if (amount > 0 && VENMO.test(text)) return "Food & Drinks";

  for (const [category, pattern] of CATEGORY_PATTERNS) {
    if (pattern.test(text)) {
      // A pattern like "refund" can appear on a charge; trust the sign over the word.
      if (category === "Income" && amount < 0) continue;
      return category;
    }
  }

  return amount > 0 ? "Income" : UNCATEGORIZED;
}

function classifyAccount(name: string, institution: string, balance: number): AccountKind {
  const haystack = `${name} ${institution}`;
  if (INVESTMENT_PATTERNS.test(haystack)) return "investment";
  if (/\b(loan|mortgage|heloc|student)\b/i.test(haystack)) return "loan";
  if (LIABILITY_PATTERNS.test(haystack)) return "credit";
  // No name signal: a persistently negative balance is the only remaining hint.
  return balance < 0 ? "credit" : "cash";
}

function parseAmount(value: string | undefined): number {
  if (value == null) return 0;
  const parsed = Number.parseFloat(String(value).replace(/[^0-9.\-]/g, ""));
  return Number.isFinite(parsed) ? parsed : 0;
}

export type Dashboard = {
  accounts: NormalizedAccount[];
  transactions: NormalizedTransaction[];
  currency: string;
  netWorth: number;
  totalAssets: number;
  totalLiabilities: number;
  errors: string[];
  netWorthSeries: { date: string; value: number }[];
  cashFlow: { month: string; income: number; spending: number; net: number }[];
  spending: {
    windowDays: number;
    total: number;
    byCategory: { category: Category; amount: number; share: number }[];
  };
  /** Spending since the 1st, by category, largest first. */
  monthSpending: {
    total: number;
    /** Spending in the previous month up to the same day of the month. */
    lastMonthToDate: number;
    byCategory: { category: Category; amount: number }[];
  };
  /** Cash sitting in checking and sweep accounts. */
  cash: number;
  /** Newly synced transactions still on their auto-suggested tag, newest first. */
  toReview: NormalizedTransaction[];
  income30d: number;
  spending30d: number;
  netFlow30d: number;
  /** Change in net worth across the loaded history window. */
  netWorthChange: number;
};

export function buildDashboard(
  set: SimpleFinAccountSet,
  historyDays: number,
  categoryOverrides: Map<string, Category> = new Map(),
  reviewQueue: readonly string[] = [],
): Dashboard {
  const connections = set.connections ?? [];
  const included = set.accounts.filter((account) => !isExcludedAccount(account.name));

  const accounts: NormalizedAccount[] = included.map((account) => {
    const institution = institutionName(account, connections);
    const rawBalance = parseAmount(account.balance);
    const kind = classifyAccount(account.name, institution, rawBalance);
    const isLiability = kind === "credit" || kind === "loan";

    // Institutions disagree on sign for debt: some report -500 owed, some +500.
    // Normalize to a magnitude plus an explicit signed contribution.
    const magnitude = Math.abs(rawBalance);
    const contribution = isLiability ? -magnitude : rawBalance;

    return {
      id: account.id,
      name: account.name,
      institution,
      currency: account.currency || "USD",
      kind,
      isLiability,
      rawBalance,
      magnitude,
      contribution,
      availableBalance:
        account["available-balance"] != null
          ? parseAmount(account["available-balance"])
          : null,
      balanceDate: account["balance-date"],
      transactionCount: account.transactions?.length ?? 0,
    };
  });

  const accountsById = new Map(accounts.map((a) => [a.id, a]));
  const remembered = rememberMerchants(included, categoryOverrides);

  /**
   * On a liability reported with positive-owed balances, a purchase raises the
   * balance but lowers net worth, so the sign has to be flipped.
   */
  const netEffectSign = (account: NormalizedAccount) =>
    account.isLiability && account.rawBalance > 0 ? -1 : 1;

  const transactions: NormalizedTransaction[] = [];
  for (const account of included) {
    const normalized = accountsById.get(account.id);
    // Investment accounts only hold dividends, buys and sales: none of it is
    // spending or income, so their balance counts toward net worth and their
    // activity is left out.
    if (!normalized || normalized.kind === "investment") continue;
    const sign = netEffectSign(normalized);

    for (const transaction of account.transactions ?? []) {
      const amount = parseAmount(transaction.amount);
      const description = (transaction.payee || transaction.description || "").trim();
      if (DIVIDEND.test(`${description} ${transaction.description ?? ""} ${transaction.memo ?? ""}`)) {
        continue;
      }
      const id = `${account.id}:${transaction.id}`;
      const override = categoryOverrides.get(id);

      transactions.push({
        id,
        accountId: account.id,
        accountName: normalized.name,
        institution: normalized.institution,
        currency: normalized.currency,
        posted: transaction.transacted_at ?? transaction.posted,
        amount,
        netEffect: amount * sign,
        description: description || "Transaction",
        payee: description || "Transaction",
        memo: transaction.memo?.trim() || null,
        pending: Boolean(transaction.pending),
        hold: Boolean(transaction.pending) && Math.abs(amount) <= 1,
        category: venmoPayback(
          override ??
            remembered.get(merchantKey(description)) ??
            categorize(
              `${description} ${transaction.memo ?? ""} ${transaction.description ?? ""}`,
              amount * sign,
            ),
          amount * sign,
          `${description} ${transaction.description ?? ""}`,
        ),
        categorySource: override ? "manual" : "auto",
      });
    }
  }

  transactions.sort((a, b) => b.posted - a.posted);
  const queued = new Set(reviewQueue);

  const totalAssets = accounts
    .filter((a) => !a.isLiability)
    .reduce((sum, a) => sum + Math.max(a.contribution, 0), 0);
  const totalLiabilities = accounts
    .filter((a) => a.isLiability)
    .reduce((sum, a) => sum + a.magnitude, 0);
  const netWorth = accounts.reduce((sum, a) => sum + a.contribution, 0);

  const netWorthSeries = buildNetWorthSeries(transactions, netWorth, historyDays);

  return {
    accounts: accounts.sort(
      (a, b) => Number(a.isLiability) - Number(b.isLiability) || b.magnitude - a.magnitude,
    ),
    transactions,
    currency: accounts[0]?.currency ?? "USD",
    netWorth,
    totalAssets,
    totalLiabilities,
    errors: accountSetErrors(set),
    netWorthSeries,
    cashFlow: buildCashFlow(transactions),
    spending: buildSpending(transactions, 30),
    monthSpending: buildMonthSpending(transactions),
    cash: accounts
      .filter((a) => a.kind === "cash")
      .reduce((sum, a) => sum + Math.max(a.rawBalance, 0), 0),
    toReview: transactions.filter(
      (t) =>
        !t.hold &&
        t.categorySource === "auto" &&
        queued.has(t.id) &&
        !TRUSTED_PAYEES[t.category]?.test(`${t.payee} ${t.description}`),
    ),
    income30d: sumWindow(transactions, 30, (t) => t.netEffect > 0 && !isSpendingOffset(t)),
    spending30d: Math.max(
      0,
      -sumWindow(transactions, 30, (t) => t.netEffect < 0 || isSpendingOffset(t)),
    ),
    netFlow30d: sumWindow(transactions, 30, () => true),
    netWorthChange: netWorthSeries.length
      ? netWorthSeries[netWorthSeries.length - 1].value - netWorthSeries[0].value
      : 0,
  };
}

/** Payee text with store numbers and punctuation stripped, so "Lsu Von Bar #2" matches "Lsu Von Bar". */
function merchantKey(payee: string): string {
  return payee.toLowerCase().replace(/[^a-z]+/g, " ").trim();
}

/**
 * The category last picked by hand for each merchant. New transactions from a
 * merchant you've tagged before inherit that tag as their suggestion, the way
 * Copilot and Monarch learn from corrections, instead of falling back to the
 * keyword rules every time.
 */
function rememberMerchants(
  accounts: SimpleFinAccountSet["accounts"],
  categoryOverrides: Map<string, Category>,
): Map<string, Category> {
  const latest = new Map<string, { category: Category; posted: number }>();

  for (const account of accounts) {
    for (const transaction of account.transactions ?? []) {
      const category = categoryOverrides.get(`${account.id}:${transaction.id}`);
      if (!category) continue;
      const key = merchantKey((transaction.payee || transaction.description || "").trim());
      if (!key) continue;
      const posted = transaction.transacted_at ?? transaction.posted;
      const seen = latest.get(key);
      if (!seen || posted > seen.posted) latest.set(key, { category, posted });
    }
  }

  return new Map([...latest].map(([key, { category }]) => [key, category]));
}

function dayKey(epochSeconds: number): string {
  return new Date(epochSeconds * 1000).toISOString().slice(0, 10);
}

/**
 * Totals only count settled money. Pending amounts change (tips get added,
 * holds vanish) and the settled version arrives with a new id, so counting
 * both would double up; the settled row is the one that sticks.
 */
export function isCountable(transaction: NormalizedTransaction): boolean {
  return !transaction.pending && !NEUTRAL_CATEGORIES.has(transaction.category);
}

function sumWindow(
  transactions: NormalizedTransaction[],
  days: number,
  predicate: (t: NormalizedTransaction) => boolean,
): number {
  const cutoff = Math.floor(Date.now() / 1000) - days * 86_400;
  return transactions
    .filter((t) => t.posted >= cutoff && isCountable(t) && predicate(t))
    .reduce((sum, t) => sum + t.netEffect, 0);
}

/**
 * SimpleFIN reports current balances, not balance history, so the trend is
 * reconstructed by walking today's net worth backwards through each day's
 * transactions.
 */
function buildNetWorthSeries(
  transactions: NormalizedTransaction[],
  netWorth: number,
  days: number,
): { date: string; value: number }[] {
  const deltaByDay = new Map<string, number>();
  for (const transaction of transactions) {
    const key = dayKey(transaction.posted);
    deltaByDay.set(key, (deltaByDay.get(key) ?? 0) + transaction.netEffect);
  }

  const series: { date: string; value: number }[] = [];
  let running = netWorth;
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);

  for (let offset = 0; offset < days; offset += 1) {
    const day = new Date(today);
    day.setUTCDate(day.getUTCDate() - offset);
    const key = day.toISOString().slice(0, 10);

    series.push({ date: key, value: Number(running.toFixed(2)) });
    // Undo this day's activity to arrive at the previous day's closing balance.
    running -= deltaByDay.get(key) ?? 0;
  }

  return series.reverse();
}

function buildCashFlow(
  transactions: NormalizedTransaction[],
): { month: string; income: number; spending: number; net: number }[] {
  const byMonth = new Map<string, { income: number; spending: number }>();

  for (const transaction of transactions) {
    if (!isCountable(transaction)) continue;
    const date = new Date(transaction.posted * 1000);
    const key = `${date.getUTCFullYear()}-${String(date.getUTCMonth() + 1).padStart(2, "0")}`;
    const bucket = byMonth.get(key) ?? { income: 0, spending: 0 };

    if (isSpendingOffset(transaction)) bucket.spending -= transaction.netEffect;
    else if (transaction.netEffect > 0) bucket.income += transaction.netEffect;
    else bucket.spending += Math.abs(transaction.netEffect);

    byMonth.set(key, bucket);
  }

  return [...byMonth.entries()]
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([month, bucket]) => ({
      month,
      income: Number(bucket.income.toFixed(2)),
      spending: Number(bucket.spending.toFixed(2)),
      net: Number((bucket.income - bucket.spending).toFixed(2)),
    }));
}

function buildMonthSpending(transactions: NormalizedTransaction[]) {
  const now = new Date();
  const year = now.getUTCFullYear();
  const month = now.getUTCMonth();
  const monthStart = Date.UTC(year, month, 1) / 1000;
  const lastMonthStart = Date.UTC(year, month - 1, 1) / 1000;
  // Clamp so March 31st compares against the end of February, not March 3rd.
  const daysInLastMonth = new Date(Date.UTC(year, month, 0)).getUTCDate();
  const lastMonthCutoff =
    Date.UTC(year, month - 1, Math.min(now.getUTCDate(), daysInLastMonth) + 1) / 1000;

  const byCategory = new Map<Category, number>();
  let lastMonthToDate = 0;

  for (const transaction of transactions) {
    const offset = isSpendingOffset(transaction);
    if (!isCountable(transaction) || (transaction.netEffect >= 0 && !offset)) continue;
    // An offset carries a negative amount so it nets against its category.
    const amount = offset ? -transaction.netEffect : Math.abs(transaction.netEffect);

    if (transaction.posted >= monthStart) {
      byCategory.set(
        transaction.category,
        (byCategory.get(transaction.category) ?? 0) + amount,
      );
    } else if (transaction.posted >= lastMonthStart && transaction.posted < lastMonthCutoff) {
      lastMonthToDate += amount;
    }
  }

  // Paybacks can exceed what was spent in a category; floor it at zero.
  const categories = [...byCategory.entries()]
    .map(([category, amount]) => ({ category, amount: Math.max(0, amount) }))
    .filter((entry) => entry.amount > 0);
  const total = categories.reduce((sum, entry) => sum + entry.amount, 0);

  return {
    total: Number(total.toFixed(2)),
    lastMonthToDate: Number(Math.max(0, lastMonthToDate).toFixed(2)),
    byCategory: categories
      .map(({ category, amount }) => ({ category, amount: Number(amount.toFixed(2)) }))
      .sort((a, b) => b.amount - a.amount),
  };
}

function buildSpending(transactions: NormalizedTransaction[], windowDays: number) {
  const cutoff = Math.floor(Date.now() / 1000) - windowDays * 86_400;
  const byCategory = new Map<Category, number>();

  for (const transaction of transactions) {
    if (transaction.posted < cutoff) continue;
    if (!isCountable(transaction)) continue;
    const offset = isSpendingOffset(transaction);
    if (transaction.netEffect >= 0 && !offset) continue;

    const amount = offset ? -transaction.netEffect : Math.abs(transaction.netEffect);
    byCategory.set(
      transaction.category,
      (byCategory.get(transaction.category) ?? 0) + amount,
    );
  }

  const categories = [...byCategory.entries()]
    .map(([category, amount]) => ({ category, amount: Math.max(0, amount) }))
    .filter((entry) => entry.amount > 0);
  const total = categories.reduce((sum, entry) => sum + entry.amount, 0);

  return {
    windowDays,
    total: Number(total.toFixed(2)),
    byCategory: categories
      .map(({ category, amount }) => ({
        category,
        amount: Number(amount.toFixed(2)),
        share: total > 0 ? amount / total : 0,
      }))
      .sort((a, b) => b.amount - a.amount),
  };
}
